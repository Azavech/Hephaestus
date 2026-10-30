import Foundation
import HephCore
import Observation

// The client models of run output (docs/ui/runs.md, "RunOutputModel"): `RunOutputModel` (one console),
// `RunOutputCenter` (delivers the `run.output` payloads and the reconnections) and `ANSIStripper`.

// MARK: - RunOutputCenter

/// Delivers the `run.output` payloads and the reconnections of their Main to the live `RunOutputModel`s. One per
/// Workspace, fed by its calls.
@MainActor
public final class RunOutputCenter {
    private weak var workspace: Workspace?
    /// The registered models by (Main, run), weakly.
    private var models: [RunKey: [WeakRunOutputModel]] = [:]

    /// By `Workspace.init`; weak reference to it.
    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Every `run.output` of a Main: the models of that Main and run get the payload.
    public func handleRunOutput(mainDeviceID: UUID, projectID: String, runID: UUID, text: String, seq: Int) {
        let key = RunKey(mainID: mainDeviceID, runID: runID)
        for model in liveModels(key) {
            model.receive(RunOutputPayload(projectID: projectID, runID: runID, text: text, seq: seq))
        }
    }

    /// After each handshake with a Main: every model of that Main loads again.
    public func mainDidConnect(_ mainDeviceID: UUID) {
        for key in models.keys where key.mainID == mainDeviceID {
            for model in liveModels(key) {
                model.mainDidConnect()
            }
        }
    }

    /// `RunOutputModel.appear()`
    func register(_ model: RunOutputModel) {
        let key = RunKey(mainID: model.mainID, runID: model.runID)
        var list = models[key, default: []].filter { $0.model != nil && $0.model !== model }
        list.append(WeakRunOutputModel(model: model))
        models[key] = list
    }

    /// `RunOutputModel.disappear()`
    func unregister(_ model: RunOutputModel) {
        let key = RunKey(mainID: model.mainID, runID: model.runID)
        let list = models[key, default: []].filter { $0.model != nil && $0.model !== model }
        models[key] = list.isEmpty ? nil : list
    }

    private func liveModels(_ key: RunKey) -> [RunOutputModel] {
        let list = models[key, default: []].filter { $0.model != nil }
        models[key] = list.isEmpty ? nil : list
        return list.compactMap(\.model)
    }
}

private struct RunKey: Hashable {
    let mainID: UUID
    let runID: UUID
}

@MainActor
private struct WeakRunOutputModel {
    weak var model: RunOutputModel?
}

// MARK: - RunOutputModel

/// The output of one run, for one console view (docs/ui/runs.md, "RunOutputModel").
@MainActor @Observable
public final class RunOutputModel {
    public enum Phase: Equatable, Sendable {
        case idle, loading, loaded, failed(String)
    }

    public let mainID: UUID
    public let projectID: String
    public let runID: UUID
    public private(set) var text = ""
    /// Incremented when `text` is replaced rather than appended to.
    public private(set) var generation = 0
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private var stripper = ANSIStripper()
    /// The highest `seq` applied.
    @ObservationIgnored private var lastSeq = 0
    /// The payloads received outside phase `loaded`, for the next load.
    @ObservationIgnored private var kept: [RunOutputPayload] = []
    /// The number of line feeds in `text`.
    @ObservationIgnored private var lineFeeds = 0
    @ObservationIgnored private var isAppeared = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var subscription: TopicSubscription?
    @ObservationIgnored private var loadGeneration = 0

    public init(workspace: Workspace, mainID: UUID, projectID: String, runID: UUID) {
        self.workspace = workspace
        self.mainID = mainID
        self.projectID = projectID
        self.runID = runID
    }

    /// Registers with the center, subscribes to the run, then loads; once until `disappear()`.
    public func appear() {
        guard !isAppeared else { return }
        isAppeared = true
        workspace.runOutputCenter.register(self)
        let workspace = workspace
        let mainID = mainID
        let runID = runID
        task = Task { [weak self] in
            let subscription = await workspace.subscribe(.run(runID), on: mainID)
            guard let self, !Task.isCancelled else {
                subscription.cancel()
                return
            }
            self.subscription = subscription
            await self.load()
        }
    }

    /// Cancels the task and the subscription; unregisters from the center.
    public func disappear() {
        guard isAppeared else { return }
        isAppeared = false
        task?.cancel()
        task = nil
        subscription?.cancel()
        subscription = nil
        workspace.runOutputCenter.unregister(self)
    }

    /// Loads the output again.
    public func reload() async {
        await load()
    }

    /// Empties this view only; later output is appended.
    public func clear() {
        text = ""
        lineFeeds = 0
        generation += 1
    }

    // MARK: Center

    /// A `run.output` payload of this run.
    func receive(_ payload: RunOutputPayload) {
        guard phase == .loaded else {
            kept.append(payload)
            return
        }
        guard payload.seq > lastSeq else { return }
        append(stripper.strip(payload.text))
        lastSeq = payload.seq
    }

    /// The run's Main completed a handshake: load again.
    func mainDidConnect() {
        Task { [weak self] in
            await self?.load()
        }
    }

    // MARK: Loading

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        do {
            guard let connection = workspace.connection(mainID) else {
                throw ProtocolError(.unavailable, "\(workspace.mainName(mainID)) is offline.")
            }
            let result = try await connection.runOutput(projectID: projectID, runID: runID)
            guard generation == loadGeneration else { return }
            stripper = ANSIStripper()
            text = ""
            lineFeeds = 0
            self.generation += 1
            append(stripper.strip(result.text))
            lastSeq = result.seq
            for payload in kept.sorted(by: { $0.seq < $1.seq }) where payload.seq > lastSeq {
                append(stripper.strip(payload.text))
                lastSeq = payload.seq
            }
            kept = []
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            if (error as? ProtocolError)?.code == .notFound {
                phase = .failed("This run is no longer available.")
            } else {
                phase = .failed(Workspace.message(of: error))
            }
        }
    }

    /// Appends text; beyond 5,500 lines, the first lines are removed to keep the last 5,000.
    private func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        lineFeeds += chunk.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        let lines = lineCount
        guard lines > Self.maximumLines else { return }
        let removed = lines - Self.keptLines
        var dropped = 0
        var cut = text.utf8.startIndex
        for index in text.utf8.indices where text.utf8[index] == UInt8(ascii: "\n") {
            dropped += 1
            if dropped == removed {
                cut = text.utf8.index(after: index)
                break
            }
        }
        text = String(text[cut...])
        lineFeeds -= removed
        generation += 1
    }

    /// The lines of `text`: its line feeds, plus one for a last line without a line feed.
    private var lineCount: Int {
        lineFeeds + (text.isEmpty || text.hasSuffix("\n") ? 0 : 1)
    }

    private static let maximumLines = 5_500
    private static let keptLines = 5_000
}

// MARK: - ANSIStripper

/// Removes terminal escape sequences and control characters from run output, chunk by chunk (docs/ui/runs.md, "ANSI
/// stripping"). CR LF and a lone CR become LF. A sequence, or a CR, cut by the end of a chunk stays pending and is
/// completed with the next chunk; a pending sequence longer than 256 characters is dropped.
public struct ANSIStripper: Sendable {
    private enum State: Sendable {
        case text
        /// After ESC.
        case escape
        /// After ESC and intermediate bytes, waiting for the final byte.
        case escapeIntermediate
        /// A CSI: `sawIntermediate` once an intermediate byte was read.
        case csi(sawIntermediate: Bool)
        /// An OSC, DCS, SOS, PM or APC string; `afterEscape` right after an ESC inside it.
        case string(endsWithBell: Bool, afterEscape: Bool)
    }

    private var state: State = .text
    /// The characters of the pending sequence.
    private var pendingLength = 0
    /// A CR ended the previous chunk.
    private var pendingCR = false

    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let maximumPending = 256

    public init() {}

    public mutating func strip(_ chunk: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in chunk.unicodeScalars {
            if pendingCR {
                pendingCR = false
                output.append("\n")
                if scalar == "\n" {
                    continue
                }
            }
            consume(scalar, into: &output)
        }
        if isInSequence, pendingLength > Self.maximumPending {
            state = .text
            pendingLength = 0
        }
        return String(output)
    }

    private var isInSequence: Bool {
        if case .text = state {
            return false
        }
        return true
    }

    private mutating func consume(_ scalar: Unicode.Scalar, into output: inout String.UnicodeScalarView) {
        let value = scalar.value
        switch state {
        case .text:
            switch value {
            case 0x1B:
                state = .escape
                pendingLength = 1
            case 0x0D:
                pendingCR = true
            case 0x09, 0x0A:
                output.append(scalar)
            case 0x00...0x1F, 0x7F:
                break
            default:
                output.append(scalar)
            }
        case .escape:
            pendingLength += 1
            switch value {
            case 0x5B: // [
                state = .csi(sawIntermediate: false)
            case 0x5D: // ]
                state = .string(endsWithBell: true, afterEscape: false)
            case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _
                state = .string(endsWithBell: false, afterEscape: false)
            case 0x20...0x2F:
                state = .escapeIntermediate
            case 0x30...0x7E:
                endSequence()
            default:
                abandon(scalar, into: &output)
            }
        case .escapeIntermediate:
            pendingLength += 1
            switch value {
            case 0x20...0x2F:
                break
            case 0x30...0x7E:
                endSequence()
            default:
                abandon(scalar, into: &output)
            }
        case .csi(let sawIntermediate):
            pendingLength += 1
            switch value {
            case 0x30...0x3F where !sawIntermediate:
                break
            case 0x20...0x2F:
                state = .csi(sawIntermediate: true)
            case 0x40...0x7E:
                endSequence()
            default:
                abandon(scalar, into: &output)
            }
        case .string(let endsWithBell, let afterEscape):
            pendingLength += 1
            if afterEscape {
                if value == 0x5C { // \ : ESC \ ends the string
                    endSequence()
                } else {
                    state = .string(endsWithBell: endsWithBell, afterEscape: value == 0x1B)
                }
            } else if value == 0x1B {
                state = .string(endsWithBell: endsWithBell, afterEscape: true)
            } else if value == 0x07, endsWithBell {
                endSequence()
            }
        }
    }

    private mutating func endSequence() {
        state = .text
        pendingLength = 0
    }

    /// A character that cannot continue the sequence: the sequence is dropped and the character is read as text.
    private mutating func abandon(_ scalar: Unicode.Scalar, into output: inout String.UnicodeScalarView) {
        endSequence()
        consume(scalar, into: &output)
    }
}
