#if os(macOS)
import Darwin
import Foundation
import HephCore

/// Run configurations executed on the Main (docs/services/runs.md): `runs.start`, `runs.stop` and `runs.output`, the
/// runs kept in memory with their output, and the events `run.changed` and `run.output`.
actor RunService: HostMethodHandler {
    /// The Main keeps at most 20 runs per project (§7).
    static let maxRunsPerProject = 20
    /// A flush happens this long after pending text first arrives (§5).
    static let flushDelay: Duration = .milliseconds(100)
    /// A flush happens at once when the pending text reaches 64 KiB of UTF-8 (§5).
    static let flushSize = 65_536

    private let host: HostService
    /// Every kept run, running and ended, by run id.
    private var runs: [UUID: RunRecord] = [:]
    /// The events of the runs, emitted one after the other by `emitter` in the order they were produced, so that the
    /// `seq` of `run.output` grows on every connection and the last `run.output` of a run comes before its final
    /// `run.changed` (§5, §6).
    private var pendingEvents: AsyncStream<ServerEvent>.Continuation?
    private var emitter: Task<Void, Never>?

    init(host: HostService) {
        self.host = host
    }

    // MARK: - Methods

    /// runs.start (§3).
    func start(projectID: String, name: String) async throws -> RunInfo {
        // 1. The project, not migrating.
        let project = try await host.registry.hosted(projectID)
        try await host.registry.checkWritable(projectID)

        // 2. The configuration, in the cached project.yml.
        guard let configuration = project.file.runs.first(where: { $0.name == name }) else {
            throw ProtocolError(.notFound, "No run configuration named \(name).")
        }

        // The environment of §4 is read before step 3, so that steps 3 to 6 run without suspension on the actor.
        let environment = await LoginEnvironment.shared.environment()

        // 3. One running run per configuration.
        if runs.values.contains(where: {
            $0.info.projectID == projectID && $0.info.name == name && $0.info.state == .running
        }) {
            throw ProtocolError(.conflict, "\(name) is already running.")
        }

        // 4. Working folder.
        let folder = try Self.workingFolder(cwd: configuration.cwd, realRoot: project.realRoot)

        // 5. Spawn (§4).
        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(ChildProcessConfiguration(
                executable: "/bin/zsh",
                arguments: ["-lc", configuration.command],
                workingDirectory: folder.path,
                environment: environment,
                standardInput: .null,
                mergeStandardError: true))
        } catch {
            throw ProtocolError(.internal, "Could not start \(name): \(Self.describe(error))")
        }

        // 6. Recorded, history limit, run.changed; output and end follow in the background.
        let info = RunInfo(id: UUID(), projectID: projectID, name: name, command: configuration.command,
                           startedAt: Date(), state: .running)
        let run = RunRecord(info: info, process: process)
        runs[info.id] = run
        applyHistoryLimit(projectID: projectID)
        enqueue(.runChanged(RunChangedPayload(projectID: projectID, run: info)))
        run.reader = Task {
            await self.readOutput(of: info.id, process: process)
        }
        Log.host.info("Run \(info.id.uuidString, privacy: .public) of \(projectID, privacy: .public) started (process \(process.pid, privacy: .public))")
        return info
    }

    /// runs.stop (§6): returns without waiting for the end.
    func stop(projectID: String, runID: UUID) async throws {
        _ = try await host.registry.hosted(projectID)
        guard let run = runs[runID], run.info.projectID == projectID else { throw Self.noRun(runID) }
        guard run.info.state == .running else { return }
        requestStop(run)
    }

    /// runs.output (§8): flushes the pending text, then returns the kept text and the seq of the last batch emitted.
    func output(projectID: String, runID: UUID) async throws -> RunsOutputResult {
        _ = try await host.registry.hosted(projectID)
        guard let run = runs[runID], run.info.projectID == projectID else { throw Self.noRun(runID) }
        flush(run)
        return RunsOutputResult(text: run.buffer.text, seq: run.seq)
    }

    /// Kept runs, by startedAt ascending.
    func list(projectID: String) -> [RunInfo] {
        runs.values
            .filter { $0.info.projectID == projectID }
            .map(\.info)
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Running runs of a project; of every project when nil.
    func activeRunCount(projectID: String?) -> Int {
        runs.values.filter { Self.belongs($0, to: projectID) && $0.info.state == .running }.count
    }

    /// Stops, waits for the exits, then forgets the runs (of every project when nil).
    func stopAll(projectID: String?) async {
        // A run started while the others are stopping is stopped too.
        while true {
            let running = runs.values.filter { Self.belongs($0, to: projectID) && $0.info.state == .running }
            guard !running.isEmpty else { break }
            for run in running {
                requestStop(run)
            }
            for run in running {
                await run.reader?.value
            }
        }
        for (id, run) in runs where Self.belongs(run, to: projectID) {
            run.flushTimer?.cancel()
            runs[id] = nil
        }
        if projectID == nil {
            // HostService.stop(): the events already produced are still emitted, then the emitter ends.
            pendingEvents?.finish()
            pendingEvents = nil
            emitter = nil
        }
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .runsStart:
                let request = try Self.decode(RunsStartParams.self, params, method)
                return try WireCoding.encodeJSON(try await start(projectID: request.projectID, name: request.name))
            case .runsStop:
                let request = try Self.decode(RunsStopParams.self, params, method)
                try await stop(projectID: request.projectID, runID: request.runID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .runsOutput:
                let request = try Self.decode(RunsOutputParams.self, params, method)
                return try WireCoding.encodeJSON(try await output(projectID: request.projectID, runID: request.runID))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Output (§5)

    /// Reads the merged output until it finishes, then waits for the exit (§4, §6).
    private func readOutput(of runID: UUID, process: ChildProcess) async {
        for await chunk in process.standardOutput {
            received(chunk, runID: runID)
        }
        let termination = await process.waitForExit()
        ended(runID: runID, termination: termination)
    }

    /// A chunk of output: decoded and added to the pending text, which is flushed 100 ms after it first arrives, or at
    /// once when it reaches 64 KiB.
    private func received(_ chunk: Data, runID: UUID) {
        guard let run = runs[runID] else { return }
        let text = run.decoder.decode(chunk)
        guard !text.isEmpty else { return }
        run.pending += text
        run.pendingBytes += text.utf8.count
        if run.pendingBytes >= Self.flushSize {
            flush(run)
        } else if run.flushTimer == nil {
            run.flushTimerID += 1
            let timerID = run.flushTimerID
            run.flushTimer = Task.detached { [weak self] in
                try? await Task.sleep(for: RunService.flushDelay)
                guard !Task.isCancelled else { return }
                await self?.flushTimerFired(runID: runID, timerID: timerID)
            }
        }
    }

    private func flushTimerFired(runID: UUID, timerID: Int) {
        guard let run = runs[runID], run.flushTimer != nil, run.flushTimerID == timerID else { return }
        flush(run)
    }

    /// The pending text goes through the output buffer; the text as stored is emitted as `run.output` with the next seq.
    private func flush(_ run: RunRecord) {
        run.flushTimer?.cancel()
        run.flushTimer = nil
        guard !run.pending.isEmpty else { return }
        let text = run.buffer.append(run.pending)
        run.pending = ""
        run.pendingBytes = 0
        run.seq += 1
        enqueue(.runOutput(RunOutputPayload(projectID: run.info.projectID, runID: run.info.id, text: text,
                                            seq: run.seq)))
    }

    // MARK: - Stop and end (§6)

    private func requestStop(_ run: RunRecord) {
        guard !run.stopRequested else { return }
        run.stopRequested = true
        let process = run.process
        Task.detached {
            await process.terminate()
        }
        Log.host.info("Stopping run \(run.info.id.uuidString, privacy: .public) of \(run.info.projectID, privacy: .public)")
    }

    /// The output finished and the process exited: the rest is flushed, then the run's end is recorded and emitted.
    private func ended(runID: UUID, termination: ChildTermination) {
        guard let run = runs[runID] else { return }
        let rest = run.decoder.finish()
        run.pending += rest
        run.pendingBytes += rest.utf8.count
        flush(run)
        run.info.endedAt = Date()
        run.info.exitCode = Int(termination.exitCode)
        if run.stopRequested {
            run.info.state = .stopped
        } else if termination == .exited(0) {
            run.info.state = .succeeded
        } else {
            run.info.state = .failed
        }
        enqueue(.runChanged(RunChangedPayload(projectID: run.info.projectID, run: run.info)))
        Log.host.info("Run \(runID.uuidString, privacy: .public) of \(run.info.projectID, privacy: .public) ended: \(run.info.state.rawValue, privacy: .public), exit code \(termination.exitCode, privacy: .public)")
    }

    // MARK: - History (§7)

    /// When the project has more than 20 runs, its oldest ended runs are dropped until 20 remain; running runs are
    /// never dropped. Dropping emits nothing.
    private func applyHistoryLimit(projectID: String) {
        let kept = runs.values.filter { $0.info.projectID == projectID }
        var excess = kept.count - Self.maxRunsPerProject
        guard excess > 0 else { return }
        let ended = kept
            .filter { $0.info.state != .running }
            .sorted { $0.info.startedAt < $1.info.startedAt }
        for run in ended where excess > 0 {
            runs[run.info.id] = nil
            excess -= 1
        }
    }

    // MARK: - Events

    /// Queues an event for the emitter, which emits the events one after the other through `HostService.emit`.
    private func enqueue(_ event: ServerEvent) {
        if pendingEvents == nil {
            let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self, bufferingPolicy: .unbounded)
            pendingEvents = continuation
            let host = self.host
            emitter = Task.detached {
                for await event in stream {
                    await host.emit(event)
                }
            }
        }
        pendingEvents?.yield(event)
    }

    // MARK: - Helpers

    /// The configuration's `cwd` (absent: the project root) resolved like a project path (services/files.md §2); it
    /// must be an existing folder.
    private static func workingFolder(cwd: String?, realRoot: URL) throws -> URL {
        let shown = cwd ?? "."
        let url: URL
        do {
            url = try PathResolver(root: realRoot).resolve(cwd ?? "")
        } catch {
            throw ProtocolError(.badRequest, "Invalid working folder \(shown).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProtocolError(.notFound, "No folder at \(shown).")
        }
        return url
    }

    /// The error of a failed spawn as text.
    private static func describe(_ error: any Error) -> String {
        if case ChildProcessError.spawnFailed(let code) = error {
            return String(cString: strerror(code))
        }
        return error.localizedDescription
    }

    private static func belongs(_ run: RunRecord, to projectID: String?) -> Bool {
        projectID == nil || run.info.projectID == projectID
    }

    private static func noRun(_ runID: UUID) -> ProtocolError {
        ProtocolError(.notFound, "Run \(runID.uuidString) does not exist.")
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}

/// One kept run with its process and output; used only on the RunService actor.
private final class RunRecord {
    var info: RunInfo
    let process: ChildProcess
    var decoder = UTF8StreamDecoder()
    var buffer = RunOutputBuffer()
    /// Decoded text not flushed yet, and its size in UTF-8 bytes.
    var pending = ""
    var pendingBytes = 0
    /// The seq of the last `run.output` batch; 0 before any output.
    var seq = 0
    var stopRequested = false
    var flushTimer: Task<Void, Never>?
    var flushTimerID = 0
    /// Reads the output and records the end; done once the run has ended.
    var reader: Task<Void, Never>?

    init(info: RunInfo, process: ChildProcess) {
        self.info = info
        self.process = process
    }
}
#endif
