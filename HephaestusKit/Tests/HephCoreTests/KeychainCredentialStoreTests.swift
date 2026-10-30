import Foundation
import Security
import Synchronization
import XCTest
@testable import HephCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testTwoLoadsReadOnce() throws {
        let keychain = try FakeKeychain(testCredentials)
        let store = keychain.makeStore()
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(keychain.reads, 1)
    }

    func testConcurrentLoadsReadOnce() async throws {
        let keychain = try FakeKeychain(testCredentials)
        keychain.holdReads(true)
        let store = keychain.makeStore()
        let loads = Loads()
        for _ in 0..<8 {
            Thread {
                loads.start()
                loads.finish(try? store.load())
            }.start()
        }
        try await waitUntil { keychain.reads == 1 && loads.started == 8 }
        keychain.holdReads(false)
        try await waitUntil { loads.results.count == 8 }
        XCTAssertEqual(loads.results, [MeshCredentials?](repeating: testCredentials, count: 8))
        XCTAssertEqual(keychain.reads, 1)
    }

    func testSaveThenLoad() throws {
        let keychain = try FakeKeychain()
        let store = keychain.makeStore()
        try store.save(testCredentials)
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(keychain.reads, 0)
    }

    func testDeleteThenLoad() throws {
        let keychain = try FakeKeychain(testCredentials)
        let store = keychain.makeStore()
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertEqual(keychain.reads, 0)
    }

    func testFailedReadReadsAgain() throws {
        let keychain = try FakeKeychain(testCredentials)
        let store = keychain.makeStore()
        keychain.failReads(with: errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? DataError, .io("Keychain error -25308"))
        }
        keychain.failReads(with: nil)
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(keychain.reads, 2)
    }

    func testFailedSaveReadsAgain() throws {
        let keychain = try FakeKeychain(testCredentials)
        let store = keychain.makeStore()
        XCTAssertEqual(try store.load(), testCredentials)
        keychain.failAdds(with: errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.save(testCredentials)) { error in
            XCTAssertEqual(error as? DataError, .io("Keychain error -25308"))
        }
        XCTAssertNil(try store.load())
        XCTAssertEqual(keychain.reads, 2)
    }

    func testSaveDuringRead() async throws {
        let keychain = try FakeKeychain()
        keychain.holdReads(true)
        let store = keychain.makeStore()
        let loads = Loads()
        Thread {
            loads.start()
            loads.finish(try? store.load())
        }.start()
        try await waitUntil { keychain.reads == 1 }
        let saves = Loads()
        Thread {
            saves.start()
            try? store.save(testCredentials)
            saves.finish(testCredentials)
        }.start()
        try await waitUntil { saves.started == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(saves.results.count, 0)
        keychain.holdReads(false)
        try await waitUntil { loads.results.count == 1 && saves.results.count == 1 }
        XCTAssertEqual(loads.results, [nil])
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(keychain.reads, 1)
    }

    func testWaitersShareFailedRead() async throws {
        let keychain = try FakeKeychain(testCredentials)
        keychain.failReads(with: errSecInteractionNotAllowed)
        keychain.holdReads(true)
        let store = keychain.makeStore()
        let loads = Loads()
        for _ in 0..<8 {
            Thread {
                loads.start()
                loads.finish(try? store.load())
            }.start()
        }
        try await waitUntil { keychain.reads == 1 && loads.started == 8 }
        try await Task.sleep(for: .milliseconds(100))
        keychain.holdReads(false)
        try await waitUntil { loads.results.count == 8 }
        XCTAssertEqual(loads.results, [MeshCredentials?](repeating: nil, count: 8))
        XCTAssertEqual(keychain.reads, 1)
        keychain.failReads(with: nil)
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(keychain.reads, 2)
    }
}

/// The Keychain of KeychainCredentialStoreTests (docs/testing.md): at most one item, in memory, and the count of its
/// reads; a status set by the test makes the reads or the adds fail; held reads wait until they are released.
private final class FakeKeychain: Sendable {
    private struct State {
        var item: Data?
        var reads = 0
        var readFailure: OSStatus?
        var addFailure: OSStatus?
        var holdsReads = false
    }

    private let state: Mutex<State>

    init(_ credentials: MeshCredentials? = nil) throws {
        let item = try credentials.map { try WireCoding.makeEncoder().encode($0) }
        state = Mutex(State(item: item))
    }

    /// The calls of copyMatching.
    var reads: Int {
        state.withLock { $0.reads }
    }

    /// The status every read returns; nil: the reads do not fail.
    func failReads(with status: OSStatus?) {
        state.withLock { $0.readFailure = status }
    }

    /// The status every add returns; nil: the adds do not fail.
    func failAdds(with status: OSStatus?) {
        state.withLock { $0.addFailure = status }
    }

    /// While true, a read, once counted, waits until the reads are released, polling every 10 ms, at most 5 s.
    func holdReads(_ holds: Bool) {
        state.withLock { $0.holdsReads = holds }
    }

    /// A store of the service "test" that makes its Keychain calls to this fake.
    func makeStore() -> KeychainCredentialStore {
        let calls = KeychainCalls(copyMatching: { _, result in self.copyMatching(result) },
                                  add: { attributes, _ in self.add(attributes) },
                                  delete: { _ in self.delete() })
        return KeychainCredentialStore(service: "test", keychain: calls)
    }

    /// The answer is taken when the read starts, as a real read sees the item as it is then.
    private func copyMatching(_ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let (status, item) = state.withLock { state -> (OSStatus, Data?) in
            state.reads += 1
            if let failure = state.readFailure {
                return (failure, nil)
            }
            guard let item = state.item else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, item)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while state.withLock({ $0.holdsReads }) && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let item {
            result?.pointee = item as CFData
        }
        return status
    }

    private func add(_ attributes: CFDictionary) -> OSStatus {
        state.withLock { state in
            if let failure = state.addFailure {
                return failure
            }
            state.item = (attributes as NSDictionary)[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    private func delete() -> OSStatus {
        state.withLock { state in
            guard state.item != nil else {
                return errSecItemNotFound
            }
            state.item = nil
            return errSecSuccess
        }
    }
}

/// The loads of testConcurrentLoadsReadOnce: how many started, and the results of those that returned.
private final class Loads: Sendable {
    private let state = Mutex((started: 0, results: [MeshCredentials?]()))

    var started: Int {
        state.withLock { $0.started }
    }

    var results: [MeshCredentials?] {
        state.withLock { $0.results }
    }

    func start() {
        state.withLock { $0.started += 1 }
    }

    func finish(_ result: MeshCredentials?) {
        state.withLock { $0.results.append(result) }
    }
}
