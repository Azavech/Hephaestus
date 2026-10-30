#if os(macOS)
import Darwin
import Foundation
import HephCore
import os

public struct ChildProcessConfiguration: Sendable {
    public enum StandardInput: Sendable { case pipe, null }
    public var executable: String              // absolute path; also argv[0]
    public var arguments: [String]             // argv[1...]
    public var workingDirectory: String
    public var environment: [String: String]
    public var standardInput: StandardInput    // .pipe: written with write(_:); .null: /dev/null
    public var mergeStandardError: Bool        // true: fd 2 is the stdout pipe (runs)

    public init(executable: String, arguments: [String], workingDirectory: String,
                environment: [String: String], standardInput: StandardInput = .null,
                mergeStandardError: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.mergeStandardError = mergeStandardError
    }
}

public enum ChildTermination: Sendable, Equatable {
    case exited(Int32)      // exit status
    case signaled(Int32)    // terminating signal number

    /// The exit status, or 128 + the signal number.
    public var exitCode: Int32 {
        switch self {
        case .exited(let status): return status
        case .signaled(let signal): return 128 + signal
        }
    }
}

public enum ChildProcessError: Error, Sendable {
    case spawnFailed(errno: Int32)
    case standardInputClosed
    case writeFailed(errno: Int32)
}

public struct CapturedOutput: Sendable {
    public let termination: ChildTermination
    public let standardOutput: Data
    public let standardError: Data
    public let timedOut: Bool
}

/// A child process (docs/claude/cli.md §1.2): spawned with posix_spawn in a new process group, its output read as
/// streams, its exit waited for by one thread. `Sendable` because its mutable state (stdin handle, termination,
/// waiters) is guarded by an `OSAllocatedUnfairLock`.
public final class ChildProcess: Sendable {
    public let pid: Int32                          // also the process group id
    public let standardOutput: AsyncStream<Data>   // chunks in order; finishes at end of file
    public let standardError: AsyncStream<Data>    // finishes at once when merged

    private struct State: Sendable {
        var standardInput: Int32?                  // the parent's write end while it is open
        var standardInputClosed: Bool
        var writing = false
        var termination: ChildTermination?
        var waiters: [CheckedContinuation<ChildTermination, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Serializes the writers of stdin.
    private let writeLock = OSAllocatedUnfairLock()
    /// The read ends of the output pipes, kept while their streams are read.
    private let outputHandles: [FileHandle]

    private init(pid: Int32, standardInput: Int32?, standardOutput: AsyncStream<Data>,
                 standardError: AsyncStream<Data>, outputHandles: [FileHandle]) {
        self.pid = pid
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputHandles = outputHandles
        state = OSAllocatedUnfairLock(initialState: State(standardInput: standardInput,
                                                          standardInputClosed: standardInput == nil))
    }

    // MARK: - Spawning

    public static func spawn(_ configuration: ChildProcessConfiguration) throws -> ChildProcess {
        var opened: [Int32] = []
        func closeAll() {
            for descriptor in opened {
                close(descriptor)
            }
        }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw ChildProcessError.spawnFailed(errno: errno) }
            opened.append(contentsOf: descriptors)
            for descriptor in descriptors {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
            return (descriptors[0], descriptors[1])
        }

        // 1. Pipes.
        let inputPipe: (read: Int32, write: Int32)?
        let outputPipe: (read: Int32, write: Int32)
        let errorPipe: (read: Int32, write: Int32)?
        do {
            inputPipe = configuration.standardInput == .pipe ? try makePipe() : nil
            outputPipe = try makePipe()
            errorPipe = configuration.mergeStandardError ? nil : try makePipe()
        } catch {
            closeAll()
            throw error
        }
        if let inputPipe {
            _ = fcntl(inputPipe.write, F_SETNOSIGPIPE, 1)
        }

        // 2. File actions.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var results: [Int32] = []
        if let inputPipe {
            results.append(posix_spawn_file_actions_adddup2(&actions, inputPipe.read, 0))
        } else {
            results.append(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
        }
        results.append(posix_spawn_file_actions_adddup2(&actions, outputPipe.write, 1))
        results.append(posix_spawn_file_actions_adddup2(&actions, errorPipe?.write ?? outputPipe.write, 2))
        results.append(posix_spawn_file_actions_addchdir_np(&actions, configuration.workingDirectory))

        // 3. Attributes.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        results.append(posix_spawnattr_setflags(&attributes, Int16(flags)))
        results.append(posix_spawnattr_setpgroup(&attributes, 0))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        results.append(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        var mask = sigset_t()
        sigemptyset(&mask)
        results.append(posix_spawnattr_setsigmask(&attributes, &mask))
        if let failure = results.first(where: { $0 != 0 }) {
            closeAll()
            throw ChildProcessError.spawnFailed(errno: failure)
        }

        // 4. posix_spawn.
        let argv: [UnsafeMutablePointer<CChar>?] = ([configuration.executable] + configuration.arguments)
            .map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = configuration.environment
            .map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for pointer in argv + envp {
                free(pointer)
            }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, configuration.executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            closeAll()
            throw ChildProcessError.spawnFailed(errno: result)
        }

        // 5. The child's ends.
        if let inputPipe {
            close(inputPipe.read)
        }
        close(outputPipe.write)
        if let errorPipe {
            close(errorPipe.write)
        }

        var handles: [FileHandle] = []
        let standardOutput = readStream(outputPipe.read, handles: &handles)
        let standardError: AsyncStream<Data>
        if let errorPipe {
            standardError = readStream(errorPipe.read, handles: &handles)
        } else {
            standardError = AsyncStream { $0.finish() }
        }
        let process = ChildProcess(pid: pid, standardInput: inputPipe?.write, standardOutput: standardOutput,
                                   standardError: standardError, outputHandles: handles)
        let waiter = Thread { process.reap() }
        waiter.start()
        return process
    }

    // MARK: - Running

    /// Writes all bytes to stdin (blocking, serialized by a lock).
    public func write(_ data: Data) throws {
        try writeLock.withLock {
            let descriptor = state.withLock { state -> Int32? in
                guard !state.standardInputClosed, let descriptor = state.standardInput else { return nil }
                state.writing = true
                return descriptor
            }
            guard let descriptor else { throw ChildProcessError.standardInputClosed }
            defer { finishWriting() }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw ChildProcessError.writeFailed(errno: errno)
                    }
                    remaining -= written
                    pointer += written
                }
            }
        }
    }

    public func closeStandardInput() {
        let descriptor = state.withLock { state -> Int32? in
            guard !state.standardInputClosed else { return nil }
            state.standardInputClosed = true
            guard !state.writing, let descriptor = state.standardInput else { return nil }
            state.standardInput = nil
            return descriptor
        }
        if let descriptor {
            close(descriptor)
        }
    }

    /// Sends `signal` to the whole process group.
    public func signalGroup(_ signal: Int32) {
        kill(-pid, signal)
    }

    /// The stop sequence: stdin closed and SIGTERM to the group; every 100 ms the group is tested; SIGKILL after 5 s.
    /// Returns when the process has exited.
    public func terminate() async {
        if isFinished { return }
        closeStandardInput()
        signalGroup(SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if isFinished { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        if isFinished { return }
        signalGroup(SIGKILL)
        _ = await waitForExit()
    }

    /// Waits for the exit; every caller gets the same value.
    public func waitForExit() async -> ChildTermination {
        await withCheckedContinuation { (continuation: CheckedContinuation<ChildTermination, Never>) in
            let termination = state.withLock { state -> ChildTermination? in
                if let termination = state.termination { return termination }
                state.waiters.append(continuation)
                return nil
            }
            if let termination {
                continuation.resume(returning: termination)
            }
        }
    }

    // MARK: - Short commands (§1.4)

    /// Runs a short command to completion and collects its output: stdin is a pipe when `input` is given (written,
    /// then closed), else /dev/null. When `timeout` passes first, SIGKILL goes to the group and the result has
    /// `timedOut` true. Spawn errors are thrown.
    public static func capture(_ configuration: ChildProcessConfiguration, input: Data? = nil,
                               timeout: Duration) async throws -> CapturedOutput {
        var configuration = configuration
        configuration.standardInput = input == nil ? .null : .pipe
        let process = try spawn(configuration)
        if let input {
            let writer = Thread {
                try? process.write(input)
                process.closeStandardInput()
            }
            writer.start()
        }

        enum Part: Sendable {
            case output(Data), error(Data), outputEnd, errorEnd, exit(ChildTermination), timeout
        }
        let (parts, continuation) = AsyncStream.makeStream(of: Part.self, bufferingPolicy: .unbounded)
        Task {
            for await chunk in process.standardOutput {
                continuation.yield(.output(chunk))
            }
            continuation.yield(.outputEnd)
        }
        Task {
            for await chunk in process.standardError {
                continuation.yield(.error(chunk))
            }
            continuation.yield(.errorEnd)
        }
        Task {
            continuation.yield(.exit(await process.waitForExit()))
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            continuation.yield(.timeout)
        }
        defer {
            timer.cancel()
            continuation.finish()
        }

        var standardOutput = Data()
        var standardError = Data()
        var outputDone = false
        var errorDone = false
        var termination: ChildTermination?
        var timedOut = false
        for await part in parts {
            switch part {
            case .output(let chunk): standardOutput.append(chunk)
            case .error(let chunk): standardError.append(chunk)
            case .outputEnd: outputDone = true
            case .errorEnd: errorDone = true
            case .exit(let value): termination = value
            case .timeout: timedOut = true
            }
            if timedOut || (outputDone && errorDone && termination != nil) {
                break
            }
        }
        let finished = outputDone && errorDone && termination != nil
        if timedOut || !finished {
            process.signalGroup(SIGKILL)
            termination = await process.waitForExit()
        }
        if !timedOut, !finished {
            // The calling task was cancelled.
            throw CancellationError()
        }
        return CapturedOutput(termination: termination ?? .signaled(SIGKILL), standardOutput: standardOutput,
                              standardError: standardError, timedOut: timedOut)
    }

    // MARK: - Private

    /// The process has been reaped and no process of its group is left.
    private var isFinished: Bool {
        let reaped = state.withLock { $0.termination != nil }
        return reaped && kill(-pid, 0) == -1 && errno == ESRCH
    }

    /// The write ended: closes stdin when it was closed meanwhile.
    private func finishWriting() {
        let descriptor = state.withLock { state -> Int32? in
            state.writing = false
            guard state.standardInputClosed, let descriptor = state.standardInput else { return nil }
            state.standardInput = nil
            return descriptor
        }
        if let descriptor {
            close(descriptor)
        }
    }

    /// The waiting thread: waitpid, retrying EINTR, then the termination for every waiter.
    private func reap() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR
        let termination: ChildTermination
        if result == pid {
            let low = status & 0x7f
            if low == 0 {
                termination = .exited((status >> 8) & 0xff)
            } else {
                termination = .signaled(low)
            }
        } else {
            Log.host.fault("waitpid failed for process \(self.pid, privacy: .public): errno \(errno, privacy: .public)")
            termination = .exited(-1)
        }
        let waiters = state.withLock { state -> [CheckedContinuation<ChildTermination, Never>] in
            state.termination = termination
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: termination)
        }
    }

    /// A stream of the chunks read from `descriptor`; the end of file finishes it and closes the handle.
    private static func readStream(_ descriptor: Int32, handles: inout [FileHandle]) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                try? handle.close()
            } else {
                continuation.yield(data)
            }
        }
        handles.append(handle)
        return stream
    }
}
#endif
