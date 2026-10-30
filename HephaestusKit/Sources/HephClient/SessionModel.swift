import Foundation
import HephCore
import Observation

// The client models of Claude sessions (docs/ui/sessions.md, "Session models"): `SessionCenter` (pending permissions
// across the app), `SessionModel` (one transcript), `TranscriptItem` and its payloads, `TranscriptBuilder` and
// `PendingPermission`.

// MARK: - SessionCenter

/// The permission requests waiting for an answer on the connected Mains, the permission banner, the visible sessions
/// and the requests to reveal. One per Workspace, fed by its calls.
@MainActor @Observable
public final class SessionCenter {
    /// Oldest first (by `receivedAt`).
    public private(set) var pendingPermissions: [PendingPermission] = []
    public private(set) var bannerPermission: PendingPermission?

    @ObservationIgnored private weak var workspace: Workspace?
    /// Visible `SessionModel`s per (Main, session).
    @ObservationIgnored private var visibleCounts: [SessionKey: Int] = [:]
    private var reveals: [SessionKey: String] = [:]

    /// By `Workspace.init`; weak reference to it.
    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// `respondToPermission` on the request's Main; `conflict` and `notFound` remove the request, then every error is
    /// rethrown.
    public func respond(to pending: PendingPermission, decision: PermissionDecision, message: String?) async throws {
        do {
            guard let connection = workspace?.connection(pending.mainID) else {
                throw ProtocolError(.unavailable, "\(workspace?.mainName(pending.mainID) ?? "Main") is offline.")
            }
            try await connection.respondToPermission(projectID: pending.projectID, sessionID: pending.sessionID,
                                                     requestID: pending.request.requestID, decision: decision,
                                                     message: message)
        } catch {
            if let error = error as? ProtocolError, error.code == .conflict || error.code == .notFound {
                remove { $0.id == pending.id }
            }
            throw error
        }
    }

    public func dismissBanner() {
        bannerPermission = nil
    }

    // MARK: Called by the Workspace

    /// The listed requests of that Main and project become the `pendingPermissions` of `sessions`.
    public func handleSessions(mainDeviceID: UUID, projectID: String, sessions: [SessionInfo]) {
        let incoming = sessions.flatMap { session in
            session.pendingPermissions.map { (sessionID: session.id, request: $0) }
        }
        become(incoming, mainID: mainDeviceID, projectID: projectID) { pending in
            pending.mainID == mainDeviceID && pending.projectID == projectID
        }
    }

    /// The listed requests of that Main and session become `session.pendingPermissions`.
    public func handleSessionChanged(mainDeviceID: UUID, projectID: String, session: SessionInfo) {
        let incoming = session.pendingPermissions.map { (sessionID: session.id, request: $0) }
        become(incoming, mainID: mainDeviceID, projectID: projectID) { pending in
            pending.mainID == mainDeviceID && pending.sessionID == session.id
        }
    }

    /// The requests of that session are removed.
    public func handleSessionRemoved(mainDeviceID: UUID, projectID: String, sessionID: UUID) {
        remove { $0.mainID == mainDeviceID && $0.sessionID == sessionID }
    }

    public func handleSessionEvent(mainDeviceID: UUID, projectID: String, sessionID: UUID, event: SessionEvent) {}

    public func handleSessionDelta(mainDeviceID: UUID, projectID: String, sessionID: UUID, messageID: String,
                                   index: Int, kind: SessionDeltaKind, text: String) {}

    /// The request is added unless the same Main and `requestID` are listed. When no `SessionModel` of that session
    /// is visible, `bannerPermission` becomes that request.
    public func handlePermissionRequested(mainDeviceID: UUID, projectID: String, sessionID: UUID,
                                          request: PermissionRequest) {
        let id = PendingPermission.id(mainID: mainDeviceID, requestID: request.requestID)
        let pending: PendingPermission
        if let listed = pendingPermissions.first(where: { $0.id == id }) {
            pending = listed
        } else {
            pending = PendingPermission(mainID: mainDeviceID, projectID: projectID, sessionID: sessionID,
                                        request: request, receivedAt: now())
            pendingPermissions.append(pending)
        }
        if visibleCounts[SessionKey(mainID: mainDeviceID, sessionID: sessionID), default: 0] == 0 {
            bannerPermission = pending
        }
    }

    /// The request with that Main and `requestID` is removed.
    public func handlePermissionResolved(mainDeviceID: UUID, projectID: String, sessionID: UUID, requestID: String,
                                         decision: PermissionDecision, deviceID: UUID) {
        let id = PendingPermission.id(mainID: mainDeviceID, requestID: requestID)
        remove { $0.id == id }
    }

    /// Nothing: the stores of that Main reload and call `handleSessions`.
    public func mainDidConnect(_ mainDeviceID: UUID) {}

    /// The requests of that Main are removed.
    public func mainDidDisconnect(_ mainDeviceID: UUID) {
        remove { $0.mainID == mainDeviceID }
    }

    // MARK: Visibility and reveal

    public func sessionDidAppear(mainID: UUID, sessionID: UUID) {
        visibleCounts[SessionKey(mainID: mainID, sessionID: sessionID), default: 0] += 1
    }

    public func sessionDidDisappear(mainID: UUID, sessionID: UUID) {
        let key = SessionKey(mainID: mainID, sessionID: sessionID)
        let count = visibleCounts[key, default: 0] - 1
        visibleCounts[key] = count > 0 ? count : nil
    }

    /// Records the request to scroll to.
    public func reveal(mainID: UUID, sessionID: UUID, requestID: String) {
        reveals[SessionKey(mainID: mainID, sessionID: sessionID)] = requestID
    }

    public func revealRequestID(mainID: UUID, sessionID: UUID) -> String? {
        reveals[SessionKey(mainID: mainID, sessionID: sessionID)]
    }

    public func clearReveal(mainID: UUID, sessionID: UUID) {
        reveals[SessionKey(mainID: mainID, sessionID: sessionID)] = nil
    }

    // MARK: Private

    /// The listed requests in the scope become `incoming`: a listed request keeps its entry and `receivedAt`, a new
    /// one gets the current time, in the order of the list; the listed requests of the scope that are not in the list
    /// are removed.
    private func become(_ incoming: [(sessionID: UUID, request: PermissionRequest)], mainID: UUID, projectID: String,
                        inScope: (PendingPermission) -> Bool) {
        let incomingIDs = Set(incoming.map { PendingPermission.id(mainID: mainID, requestID: $0.request.requestID) })
        var list = pendingPermissions.filter { !inScope($0) || incomingIDs.contains($0.id) }
        let receivedAt = now()
        for (sessionID, request) in incoming {
            let id = PendingPermission.id(mainID: mainID, requestID: request.requestID)
            if let index = list.firstIndex(where: { $0.id == id }) {
                let listed = list[index]
                list[index] = PendingPermission(mainID: mainID, projectID: projectID, sessionID: sessionID,
                                                request: request, receivedAt: listed.receivedAt)
            } else {
                list.append(PendingPermission(mainID: mainID, projectID: projectID, sessionID: sessionID,
                                              request: request, receivedAt: receivedAt))
            }
        }
        if list != pendingPermissions {
            pendingPermissions = list
        }
        clearBannerIfGone()
    }

    private func remove(where shouldRemove: (PendingPermission) -> Bool) {
        let list = pendingPermissions.filter { !shouldRemove($0) }
        if list.count != pendingPermissions.count {
            pendingPermissions = list
        }
        clearBannerIfGone()
    }

    /// `bannerPermission` becomes nil when its request leaves `pendingPermissions`.
    private func clearBannerIfGone() {
        if let banner = bannerPermission, !pendingPermissions.contains(where: { $0.id == banner.id }) {
            bannerPermission = nil
        }
    }

    private func now() -> Date {
        workspace?.environment.now() ?? Date()
    }
}

/// A session of a Main.
private struct SessionKey: Hashable {
    let mainID: UUID
    let sessionID: UUID
}

// MARK: - SessionModel

/// One transcript, for one `SessionView`: the session `sessionID` of the project of `store` (docs/ui/sessions.md,
/// "SessionModel").
@MainActor @Observable
public final class SessionModel {
    public enum Phase: Equatable, Sendable {
        case idle, loading, loaded, failed(String)
    }

    public let sessionID: UUID
    public private(set) var items: [TranscriptItem] = []
    public private(set) var phase: Phase = .idle
    /// Log index of the first loaded event.
    public private(set) var firstIndex = 0
    public private(set) var isLoadingEarlier = false

    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var builder = TranscriptBuilder()
    /// The events of the pages loaded, then every `session.event` applied since.
    @ObservationIgnored private var loadedEvents: [SessionEvent] = []
    @ObservationIgnored private var isAppeared = false
    /// While true, the events that concern the session are buffered until the load ends.
    @ObservationIgnored private var isBuffering = false
    @ObservationIgnored private var buffer: [(event: ServerEvent, receivedAt: Date)] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var subscription: TopicSubscription?
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    public init(workspace: Workspace, store: ProjectStore, sessionID: UUID) {
        self.workspace = workspace
        self.store = store
        self.sessionID = sessionID
    }

    /// `store.mainDeviceID`
    public var mainID: UUID {
        store.mainDeviceID
    }

    /// `store.projectID`
    public var projectID: String {
        store.projectID
    }

    /// `store.session(sessionID)`, kept current by the Workspace.
    public var info: SessionInfo? {
        store.session(sessionID)
    }

    /// The store was removed, or it is loaded and has no session `sessionID`.
    public var isRemoved: Bool {
        store.isRemoved || (store.phase == .loaded && store.session(sessionID) == nil)
    }

    /// `firstIndex > 0`
    public var hasEarlier: Bool {
        firstIndex > 0
    }

    /// Takes the events, subscribes to the session, then loads; once until `disappear()`.
    public func appear() {
        guard !isAppeared else { return }
        isAppeared = true
        workspace.sessionCenter.sessionDidAppear(mainID: mainID, sessionID: sessionID)
        isBuffering = true
        buffer = []
        let events = workspace.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }
        let workspace = workspace
        let mainID = mainID
        let sessionID = sessionID
        subscriptionTask = Task { [weak self] in
            let subscription = await workspace.subscribe(.session(sessionID), on: mainID)
            guard let self, !Task.isCancelled else {
                subscription.cancel()
                return
            }
            self.subscription = subscription
            await self.load()
        }
    }

    /// Cancels the tasks and the subscription.
    public func disappear() {
        guard isAppeared else { return }
        isAppeared = false
        eventsTask?.cancel()
        eventsTask = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscription?.cancel()
        subscription = nil
        publishTask?.cancel()
        publishTask = nil
        isBuffering = false
        buffer = []
        workspace.sessionCenter.sessionDidDisappear(mainID: mainID, sessionID: sessionID)
    }

    /// Loads the latest page again, buffering events meanwhile.
    public func reload() async {
        await load()
    }

    /// Loads the previous page when there is one and none is loading. A failure is thrown and changes nothing.
    public func loadEarlier() async throws {
        guard hasEarlier, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        let generation = loadGeneration
        let result = try await requireConnection().sessionHistory(projectID: projectID, sessionID: sessionID,
                                                                  before: firstIndex, limit: nil)
        guard generation == loadGeneration else { return }
        let known = Set(loadedEvents.map(\.id))
        loadedEvents = result.events.filter { !known.contains($0.id) } + loadedEvents
        firstIndex = result.firstIndex
        let streaming = builder.streamingItems
        rebuild()
        builder.restoreStreaming(streaming)
        items = builder.items
    }

    public func send(text: String, attachments: [UploadRef]) async throws {
        try await requireConnection().sendMessage(projectID: projectID, sessionID: sessionID, text: text,
                                                  attachments: attachments)
    }

    public func interrupt() async throws {
        try await requireConnection().interruptSession(projectID: projectID, sessionID: sessionID)
    }

    public func stop() async throws {
        try await requireConnection().stopSession(projectID: projectID, sessionID: sessionID)
    }

    public func respond(requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await requireConnection().respondToPermission(projectID: projectID, sessionID: sessionID,
                                                          requestID: requestID, decision: decision, message: message)
    }

    /// `update(model: "")` clears the session's model.
    public func update(title: String? = nil, permissionMode: PermissionMode? = nil, model: String? = nil) async throws {
        _ = try await requireConnection().updateSession(projectID: projectID, sessionID: sessionID,
                                                        patch: SessionPatch(title: title,
                                                                            permissionMode: permissionMode,
                                                                            model: model))
    }

    public func delete() async throws {
        try await requireConnection().deleteSession(projectID: projectID, sessionID: sessionID)
    }

    // MARK: Loading

    /// Phase `loading` (items stay visible), then the latest page: the builder is rebuilt from it, then the buffered
    /// events are applied in order. A failure leaves the events applied as they come.
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isBuffering = true
        phase = .loading
        do {
            let result = try await requireConnection().sessionHistory(projectID: projectID, sessionID: sessionID,
                                                                      before: nil, limit: nil)
            guard generation == loadGeneration, isAppeared else { return }
            loadedEvents = result.events
            firstIndex = result.firstIndex
            rebuild()
            phase = .loaded
        } catch {
            guard generation == loadGeneration, isAppeared else { return }
            phase = .failed(Workspace.message(of: error))
        }
        isBuffering = false
        let buffered = buffer
        buffer = []
        for item in buffered {
            apply(item.event, receivedAt: item.receivedAt)
        }
        items = builder.items
    }

    /// A new builder with `loadedEvents` applied in order.
    private func rebuild() {
        var rebuilt = TranscriptBuilder()
        for event in loadedEvents {
            rebuilt.apply(event)
        }
        builder = rebuilt
        items = builder.items
    }

    // MARK: Events

    private func receive(_ event: WorkspaceEvent) {
        switch event {
        case .connected(let mainDeviceID):
            guard mainDeviceID == mainID, isAppeared else { return }
            Task { [weak self] in
                await self?.load()
            }
        case .event(let mainDeviceID, let serverEvent):
            guard mainDeviceID == mainID, concerns(serverEvent) else { return }
            let receivedAt = workspace.environment.now()
            if isBuffering {
                buffer.append((serverEvent, receivedAt))
            } else {
                apply(serverEvent, receivedAt: receivedAt)
            }
        case .disconnected:
            return
        }
    }

    private func concerns(_ event: ServerEvent) -> Bool {
        switch event {
        case .sessionEvent(let payload):
            return payload.sessionID == sessionID && payload.projectID == projectID
        case .sessionDelta(let payload):
            return payload.sessionID == sessionID && payload.projectID == projectID
        case .permissionRequested(let payload):
            return payload.sessionID == sessionID && payload.projectID == projectID
        case .permissionResolved(let payload):
            return payload.sessionID == sessionID && payload.projectID == projectID
        case .sessionChanged(let payload):
            return payload.session.id == sessionID && payload.projectID == projectID
        default:
            return false
        }
    }

    /// Event effects update `items` at once; deltas update the builder at once and `items` at most every 100 ms.
    private func apply(_ event: ServerEvent, receivedAt: Date) {
        switch event {
        case .sessionEvent(let payload):
            if !loadedEvents.contains(where: { $0.id == payload.event.id }) {
                loadedEvents.append(payload.event)
            }
            builder.apply(payload.event)
            publish()
        case .sessionDelta(let payload):
            builder.applyDelta(messageID: payload.messageID, index: payload.index, kind: payload.kind,
                               text: payload.text)
            schedulePublish()
        case .permissionRequested(let payload):
            builder.applyPermissionRequest(payload.request, at: receivedAt)
            publish()
        case .permissionResolved(let payload):
            builder.applyPermissionDecision(requestID: payload.requestID, decision: payload.decision,
                                            deviceID: payload.deviceID, at: receivedAt)
            publish()
        case .sessionChanged(let payload):
            switch payload.session.status {
            case .starting, .running, .waitingPermission:
                return
            case .idle, .stopped, .failed:
                builder.clearStreaming()
                publish()
            }
        default:
            return
        }
    }

    private func publish() {
        publishTask?.cancel()
        publishTask = nil
        if items != builder.items {
            items = builder.items
        }
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self else { return }
            self.publishTask = nil
            self.items = self.builder.items
        }
    }

    private func requireConnection() throws -> MainConnection {
        guard let connection = store.connection else {
            throw ProtocolError(.unavailable, "\(workspace.mainName(mainID)) is offline.")
        }
        return connection
    }
}

// MARK: - PendingPermission

/// A permission request waiting for an answer, with where it comes from.
public struct PendingPermission: Identifiable, Equatable, Sendable {
    public let mainID: UUID
    public let projectID: String
    public let sessionID: UUID
    public let request: PermissionRequest
    public let receivedAt: Date

    /// "<mainID>/<requestID>"
    public var id: String {
        Self.id(mainID: mainID, requestID: request.requestID)
    }

    static func id(mainID: UUID, requestID: String) -> String {
        "\(mainID.uuidString)/\(requestID)"
    }
}

// MARK: - Transcript items

/// One row of a transcript.
public enum TranscriptItem: Identifiable, Equatable, Sendable {
    case user(UserMessageItem)
    case assistant(TextItem)
    case thinking(TextItem)
    case tool(ToolItem)
    case permission(PermissionItem)
    case turnEnd(TurnEndItem)
    case system(TextItem)
    case error(TextItem)
    case streaming(StreamingItem)

    /// Event items: the event id; `.tool`: `tool:<toolUseID>`; `.permission`: `permission:<requestID>`;
    /// `.streaming`: `stream:<messageID>:<index>`.
    public var id: String {
        switch self {
        case .user(let item): return item.id
        case .assistant(let item), .thinking(let item), .system(let item), .error(let item): return item.id
        case .tool(let item): return "tool:\(item.toolUseID)"
        case .permission(let item): return "permission:\(item.requestID)"
        case .turnEnd(let item): return item.id
        case .streaming(let item): return TranscriptBuilder.streamingID(messageID: item.messageID, index: item.index)
        }
    }
}

public struct TextItem: Equatable, Sendable {
    public let id: String
    public let at: Date
    public let text: String
}

public struct UserMessageItem: Equatable, Sendable {
    public let id: String
    public let at: Date
    public let text: String
    /// Files of .hephaestus/sessions/<session id>/.
    public let attachments: [TaskAttachment]
    public let deviceID: UUID?
}

public struct ToolItem: Equatable, Sendable {
    public let toolUseID: String
    public let at: Date
    public let name: String
    /// JSON text.
    public let input: String
    public var result: ToolResultItem?
}

public struct ToolResultItem: Equatable, Sendable {
    public let text: String
    public let isError: Bool
}

public struct PermissionItem: Equatable, Sendable {
    public let requestID: String
    public let at: Date
    public let toolName: String
    /// JSON text.
    public let input: String
    public let description: String?
    /// JSON text.
    public let suggestions: String?
    public let blockedPath: String?
    public var decision: PermissionDecisionItem?
}

public struct PermissionDecisionItem: Equatable, Sendable {
    public let decision: PermissionDecision
    public let deviceID: UUID?
    public let at: Date
}

public struct TurnEndItem: Equatable, Sendable {
    public let id: String
    public let at: Date
    public let isError: Bool
    public let durationMS: Int?
    public let costUSD: Double?
    public let stopReason: String?
}

public struct StreamingItem: Equatable, Sendable {
    public let messageID: String
    public let index: Int
    public let kind: SessionDeltaKind
    public var text: String
}

// MARK: - TranscriptBuilder

/// Turns session events and deltas into transcript items, following the client rules of docs/protocol/events.md.
/// "Append" inserts before the first `.streaming` item, or at the end when there is none.
public struct TranscriptBuilder: Sendable {
    public private(set) var items: [TranscriptItem] = []
    /// The ids of the events applied.
    private var appliedIDs: Set<String> = []

    public init() {}

    public mutating func apply(_ event: SessionEvent) {
        // The streaming effect applies to every event, already applied or not.
        switch event.type {
        case .assistant, .thinking, .toolUse:
            if let messageID = event.messageID, let index = event.index {
                let id = Self.streamingID(messageID: messageID, index: index)
                items.removeAll { $0.id == id }
            }
        case .result, .error:
            clearStreaming()
        default:
            break
        }
        guard appliedIDs.insert(event.id).inserted else { return }

        switch event.type {
        case .user:
            append(.user(UserMessageItem(id: event.id, at: event.at, text: event.text ?? "",
                                         attachments: event.attachments ?? [], deviceID: event.deviceID)))
        case .assistant:
            append(.assistant(TextItem(id: event.id, at: event.at, text: event.text ?? "")))
        case .thinking:
            let text = event.text ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(.thinking(TextItem(id: event.id, at: event.at, text: text)))
            }
        case .toolUse:
            let toolUseID = event.toolUseID ?? ""
            let tool = ToolItem(toolUseID: toolUseID, at: event.at, name: event.name ?? "",
                                input: event.input ?? "", result: nil)
            if let index = toolIndex(toolUseID) {
                // A result arrived before its call: the call fills the item, keeping the result.
                if case .tool(let existing) = items[index] {
                    var filled = tool
                    filled.result = existing.result
                    items[index] = .tool(filled)
                }
            } else {
                append(.tool(tool))
            }
        case .toolResult:
            let toolUseID = event.toolUseID ?? ""
            let result = ToolResultItem(text: event.text ?? "", isError: event.isError ?? false)
            if let index = toolIndex(toolUseID), case .tool(var tool) = items[index] {
                tool.result = result
                items[index] = .tool(tool)
            } else {
                append(.tool(ToolItem(toolUseID: toolUseID, at: event.at, name: "", input: "", result: result)))
            }
        case .permission:
            let requestID = event.requestID ?? ""
            if permissionIndex(requestID) == nil {
                append(.permission(PermissionItem(requestID: requestID, at: event.at, toolName: event.toolName ?? "",
                                                  input: event.input ?? "", description: event.description,
                                                  suggestions: event.suggestions, blockedPath: event.blockedPath,
                                                  decision: nil)))
            }
        case .permissionDecision:
            if let decision = event.decision {
                setDecision(requestID: event.requestID ?? "",
                            PermissionDecisionItem(decision: decision, deviceID: event.deviceID, at: event.at))
            }
        case .result:
            append(.turnEnd(TurnEndItem(id: event.id, at: event.at, isError: event.isError ?? false,
                                        durationMS: event.durationMS, costUSD: event.costUSD,
                                        stopReason: event.stopReason)))
        case .system:
            append(.system(TextItem(id: event.id, at: event.at, text: event.text ?? "")))
        case .error:
            append(.error(TextItem(id: event.id, at: event.at, text: event.text ?? "")))
        }
    }

    /// Appends `text` to the streaming item `stream:<messageID>:<index>`, created at the end with that kind when
    /// missing.
    public mutating func applyDelta(messageID: String, index: Int, kind: SessionDeltaKind, text: String) {
        let id = Self.streamingID(messageID: messageID, index: index)
        if let position = items.firstIndex(where: { $0.id == id }), case .streaming(var item) = items[position] {
            item.text += text
            items[position] = .streaming(item)
        } else {
            items.append(.streaming(StreamingItem(messageID: messageID, index: index, kind: kind, text: text)))
        }
    }

    /// Appends `.permission` unless that `requestID` exists.
    public mutating func applyPermissionRequest(_ request: PermissionRequest, at: Date) {
        guard permissionIndex(request.requestID) == nil else { return }
        append(.permission(PermissionItem(requestID: request.requestID, at: at, toolName: request.toolName,
                                          input: request.input, description: request.description,
                                          suggestions: request.suggestions, blockedPath: request.blockedPath,
                                          decision: nil)))
    }

    /// Sets the decision of the `.permission` item with that `requestID`; ignored when there is none.
    public mutating func applyPermissionDecision(requestID: String, decision: PermissionDecision, deviceID: UUID?,
                                                 at: Date) {
        setDecision(requestID: requestID, PermissionDecisionItem(decision: decision, deviceID: deviceID, at: at))
    }

    /// Removes every `.streaming` item.
    public mutating func clearStreaming() {
        items.removeAll {
            if case .streaming = $0 {
                return true
            }
            return false
        }
    }

    // MARK: Internal

    /// `stream:<messageID>:<index>`
    static func streamingID(messageID: String, index: Int) -> String {
        "stream:\(messageID):\(index)"
    }

    /// The `.streaming` items, in order.
    var streamingItems: [TranscriptItem] {
        items.filter {
            if case .streaming = $0 {
                return true
            }
            return false
        }
    }

    /// Puts back, at the end, streaming items of a builder that was rebuilt.
    mutating func restoreStreaming(_ streaming: [TranscriptItem]) {
        for item in streaming where !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
    }

    private mutating func append(_ item: TranscriptItem) {
        if let index = items.firstIndex(where: {
            if case .streaming = $0 {
                return true
            }
            return false
        }) {
            items.insert(item, at: index)
        } else {
            items.append(item)
        }
    }

    private func toolIndex(_ toolUseID: String) -> Int? {
        items.firstIndex {
            if case .tool(let tool) = $0 {
                return tool.toolUseID == toolUseID
            }
            return false
        }
    }

    private func permissionIndex(_ requestID: String) -> Int? {
        items.firstIndex {
            if case .permission(let permission) = $0 {
                return permission.requestID == requestID
            }
            return false
        }
    }

    private mutating func setDecision(requestID: String, _ decision: PermissionDecisionItem) {
        guard let index = permissionIndex(requestID), case .permission(var permission) = items[index] else { return }
        permission.decision = decision
        items[index] = .permission(permission)
    }
}
