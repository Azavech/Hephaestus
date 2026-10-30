import Foundation
import Security
import Synchronization

/// The credentials of a mesh (docs/devices/mesh.md, "Credentials").
public struct MeshCredentials: Codable, Sendable, Equatable {
    public var meshID: UUID
    /// 32 bytes; JSON base64.
    public var meshKey: Data

    public init(meshID: UUID, meshKey: Data) {
        self.meshID = meshID
        self.meshKey = meshKey
    }
}

/// Where a device keeps its mesh credentials (Credential store).
public protocol MeshCredentialStore: AnyObject, Sendable {
    /// nil when the device has no mesh.
    func load() throws -> MeshCredentials?
    /// Replaces the credentials, then yields them to every changes() stream.
    func save(_ credentials: MeshCredentials) throws
    /// Removes the credentials ("Leave mesh"), then yields nil to every changes() stream.
    func delete() throws
    /// A new stream (unbounded buffer) yielding the credentials after each successful save or delete made through
    /// this instance. It ends when the iterating task is cancelled.
    func changes() -> AsyncStream<MeshCredentials?>
}

/// The continuations of the `changes()` streams of a store.
private struct ChangeStreams {
    var continuations: [UUID: AsyncStream<MeshCredentials?>.Continuation] = [:]

    /// Registers a new stream; `remove` is called with its id when the stream ends.
    mutating func make(remove: @escaping @Sendable (UUID) -> Void) -> AsyncStream<MeshCredentials?> {
        let (stream, continuation) = AsyncStream.makeStream(of: MeshCredentials?.self, bufferingPolicy: .unbounded)
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { _ in remove(id) }
        return stream
    }
}

/// The Keychain calls of a KeychainCredentialStore (Keychain item section): the Security functions in the app, fakes
/// in tests.
public struct KeychainCalls: Sendable {
    /// Called as SecItemCopyMatching(query, result).
    public let copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    /// Called as SecItemAdd(attributes, result).
    public let add: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    /// Called as SecItemDelete(query).
    public let delete: @Sendable (CFDictionary) -> OSStatus

    public init(copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
                add: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
                delete: @escaping @Sendable (CFDictionary) -> OSStatus) {
        self.copyMatching = copyMatching
        self.add = add
        self.delete = delete
    }

    /// SecItemCopyMatching, SecItemAdd and SecItemDelete.
    public static let system = KeychainCalls(copyMatching: { SecItemCopyMatching($0, $1) },
                                             add: { SecItemAdd($0, $1) },
                                             delete: { SecItemDelete($0) })
}

/// The Keychain item of the Keychain section: one generic password item of the service, account `meshID.uuidString`,
/// in the login keychain on macOS. The store keeps its value in memory and reads it only when it does not know it
/// (Value in memory).
public final class KeychainCredentialStore: MeshCredentialStore {
    /// "ca.azavech.hephaestus.mesh"
    public static let defaultService = "ca.azavech.hephaestus.mesh"
    /// KeychainCredentialStore(service: defaultService): the only store the app creates.
    public static let shared = KeychainCredentialStore(service: defaultService)
    /// kSecAttrService of the item.
    public let service: String

    /// The item's value as the store knows it.
    private enum Value {
        case unknown
        /// The credentials, or nil for no item.
        case known(MeshCredentials?)
    }

    /// What the store knows: the value, the number of reads made, and the error of the last read when it threw, which
    /// the loads that waited for that read throw too.
    private struct Memory {
        var value: Value = .unknown
        var reads = 0
        var readError: (any Error)?
    }

    private let keychain: KeychainCalls
    private let streams = Mutex(ChangeStreams())
    private let memory = Mutex(Memory())
    /// Held during each read, save and delete until its result is recorded, so that the store makes one at a time and
    /// the value of a read never replaces the one of a later save or delete.
    private let keychainLock = Mutex(())

    public init(service: String = KeychainCredentialStore.defaultService, keychain: KeychainCalls = .system) {
        self.service = service
        self.keychain = keychain
    }

    /// The value when the store knows it, without a Keychain call; otherwise one read, whose result the concurrent
    /// loads share. A read that throws is not remembered.
    public func load() throws -> MeshCredentials? {
        let before = memory.withLock { $0 }
        if case .known(let credentials) = before.value {
            return credentials
        }
        return try keychainLock.withLock { _ in
            let now = memory.withLock { $0 }
            if case .known(let credentials) = now.value {
                return credentials
            }
            if now.reads != before.reads, let error = now.readError {
                throw error
            }
            do {
                let credentials = try readItem()
                memory.withLock { memory in
                    memory.value = .known(credentials)
                    memory.reads += 1
                    memory.readError = nil
                }
                return credentials
            } catch {
                memory.withLock { memory in
                    memory.reads += 1
                    memory.readError = error
                }
                throw error
            }
        }
    }

    public func save(_ credentials: MeshCredentials) throws {
        try write(credentials) {
            let data: Data
            do {
                data = try WireCoding.makeEncoder().encode(credentials)
            } catch {
                throw DataError.io("Keychain item: \(error.localizedDescription)")
            }
            try deleteItems()
            let attributes: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: credentials.meshID.uuidString,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData: data,
            ]
            let status = keychain.add(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw keychainError(status)
            }
        }
        yield(credentials)
    }

    public func delete() throws {
        try write(nil) {
            try deleteItems()
        }
        yield(nil)
    }

    public func changes() -> AsyncStream<MeshCredentials?> {
        streams.withLock { streams in
            streams.make { [weak self] id in
                self?.streams.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// One read of the item, made while holding the Keychain lock.
    private func readItem() throws -> MeshCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        do {
            return try WireCoding.makeDecoder().decode(MeshCredentials.self, from: data)
        } catch let error as DecodingError {
            throw DataError.unreadable("Keychain item: \(JSONFile.describe(error))")
        } catch {
            throw DataError.unreadable("Keychain item: \(error.localizedDescription)")
        }
    }

    /// Runs a save or a delete while holding the Keychain lock. Then the store knows `value`; when `body` throws, the
    /// value becomes unknown.
    private func write(_ value: MeshCredentials?, _ body: () throws -> Void) throws {
        try keychainLock.withLock { _ in
            do {
                try body()
            } catch {
                memory.withLock { $0.value = .unknown }
                throw error
            }
            memory.withLock { $0.value = .known(value) }
        }
    }

    /// Deletes every item of the service; `errSecItemNotFound` is a success. Repeated until none is left, because a
    /// delete may remove one matching item at a time.
    private func deleteItems() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        for _ in 0..<64 {
            let status = keychain.delete(query as CFDictionary)
            if status == errSecItemNotFound {
                return
            }
            guard status == errSecSuccess else {
                throw keychainError(status)
            }
        }
    }

    private func yield(_ credentials: MeshCredentials?) {
        let continuations = streams.withLock { Array($0.continuations.values) }
        for continuation in continuations {
            continuation.yield(credentials)
        }
    }

    private func keychainError(_ status: OSStatus) -> DataError {
        Log.core.error("Keychain error \(status, privacy: .public)")
        return DataError.io("Keychain error \(status)")
    }
}

/// Tests and previews: the credentials in memory; never throws.
public final class InMemoryCredentialStore: MeshCredentialStore {
    private struct State {
        var credentials: MeshCredentials?
        var streams = ChangeStreams()
    }

    private let state: Mutex<State>

    public init(_ credentials: MeshCredentials? = nil) {
        state = Mutex(State(credentials: credentials))
    }

    public func load() throws -> MeshCredentials? {
        state.withLock { $0.credentials }
    }

    public func save(_ credentials: MeshCredentials) throws {
        let continuations = state.withLock { state in
            state.credentials = credentials
            return Array(state.streams.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(credentials)
        }
    }

    public func delete() throws {
        let continuations = state.withLock { state in
            state.credentials = nil
            return Array(state.streams.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(nil)
        }
    }

    public func changes() -> AsyncStream<MeshCredentials?> {
        state.withLock { state in
            state.streams.make { [weak self] id in
                self?.state.withLock { _ = $0.streams.continuations.removeValue(forKey: id) }
            }
        }
    }
}
