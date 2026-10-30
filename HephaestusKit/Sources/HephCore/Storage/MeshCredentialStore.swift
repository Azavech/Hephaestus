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

/// The Keychain item of the Keychain section: one generic password item of the service, account `meshID.uuidString`,
/// in the login keychain on macOS.
public final class KeychainCredentialStore: MeshCredentialStore {
    /// "ca.azavech.hephaestus.mesh"
    public static let defaultService = "ca.azavech.hephaestus.mesh"
    /// KeychainCredentialStore(service: defaultService): the only store the app creates.
    public static let shared = KeychainCredentialStore(service: defaultService)
    /// kSecAttrService of the item.
    public let service: String

    private let streams = Mutex(ChangeStreams())

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func load() throws -> MeshCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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

    public func save(_ credentials: MeshCredentials) throws {
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
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        yield(credentials)
    }

    public func delete() throws {
        try deleteItems()
        yield(nil)
    }

    public func changes() -> AsyncStream<MeshCredentials?> {
        streams.withLock { streams in
            streams.make { [weak self] id in
                self?.streams.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
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
            let status = SecItemDelete(query as CFDictionary)
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
