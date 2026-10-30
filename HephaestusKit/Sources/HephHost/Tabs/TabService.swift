#if os(macOS)
import Foundation
import HephCore

/// The web tabs of the hosted projects (docs/services/host.md §9): the `webTabs` of project.yml.
actor TabService: HostMethodHandler {
    private let host: HostService

    init(host: HostService) {
        self.host = host
    }

    /// From the cached file, in tab strip order.
    func list(projectID: String) async throws -> [WebTab] {
        try await host.registry.hosted(projectID).file.webTabValues
    }

    func open(projectID: String, url: String, title: String?, locked: Bool?) async throws -> WebTab {
        let url = try Self.validatedURL(url)
        let tab = WebTab(id: UUID(), title: Self.title(title, url: url), url: url, locked: locked ?? false)
        try await change(projectID) { file in
            file.webTabs.append(ProjectFile.WebTabEntry(id: tab.id, title: tab.title, url: tab.url, locked: tab.locked))
        }
        return tab
    }

    func update(projectID: String, tabID: UUID, patch: WebTabPatch) async throws -> WebTab {
        let newURL = try patch.url.map(Self.validatedURL)
        let file = try await change(projectID) { file in
            let index = try Self.index(of: tabID, in: file)
            if let newURL {
                file.webTabs[index].url = newURL
            }
            if let title = patch.title {
                file.webTabs[index].title = Self.title(title, url: file.webTabs[index].url)
            }
            if let locked = patch.locked {
                file.webTabs[index].locked = locked
            }
        }
        guard let entry = file.webTabs.first(where: { $0.id == tabID }) else { throw Self.noTab(tabID) }
        return WebTab(id: entry.id, title: entry.title, url: entry.url, locked: entry.locked)
    }

    func close(projectID: String, tabID: UUID) async throws {
        try await change(projectID) { file in
            let index = try Self.index(of: tabID, in: file)
            guard !file.webTabs[index].locked else {
                throw ProtocolError(.locked, "This tab is locked.")
            }
            file.webTabs.remove(at: index)
        }
    }

    func move(projectID: String, tabID: UUID, toIndex: Int) async throws {
        try await change(projectID) { file in
            let index = try Self.index(of: tabID, in: file)
            let tab = file.webTabs.remove(at: index)
            let destination = min(max(toIndex, 0), file.webTabs.count)
            file.webTabs.insert(tab, at: destination)
        }
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .tabsOpen:
                let request = try Self.decode(TabsOpenParams.self, params, method)
                return try WireCoding.encodeJSON(try await open(projectID: request.projectID, url: request.url,
                                                                title: request.title, locked: request.locked))
            case .tabsUpdate:
                let request = try Self.decode(TabsUpdateParams.self, params, method)
                return try WireCoding.encodeJSON(try await update(projectID: request.projectID, tabID: request.tabID,
                                                                  patch: request.patch))
            case .tabsClose:
                let request = try Self.decode(TabsCloseParams.self, params, method)
                try await close(projectID: request.projectID, tabID: request.tabID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .tabsMove:
                let request = try Self.decode(TabsMoveParams.self, params, method)
                try await move(projectID: request.projectID, tabID: request.tabID, toIndex: request.toIndex)
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Private

    /// One ProjectFile.update inside registry.write, then registry.reloaded (which emits project.changed).
    @discardableResult
    private func change(_ projectID: String,
                        _ edit: @escaping @Sendable (inout ProjectFile) throws -> Void) async throws -> ProjectFile {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let file: ProjectFile
            do {
                file = try ProjectFile.update(projectRoot: project.root, edit)
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
            let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: project.root))
            await host.registry.reloaded(projectID, file: file, modified: modified)
            return file
        }
    }

    /// Trimmed; `about:blank`, or an absolute http or https URL with a host.
    private static func validatedURL(_ raw: String) throws -> String {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url == "about:blank" {
            return url
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parsed.host, !host.isEmpty
        else {
            throw ProtocolError(.badRequest, "Only http and https addresses can be opened")
        }
        return url
    }

    /// The given title; the URL's host when it is empty or absent, or the URL itself when it has no host.
    private static func title(_ title: String?, url: String) -> String {
        if let title, !title.isEmpty {
            return title
        }
        return URL(string: url)?.host ?? url
    }

    private static func index(of tabID: UUID, in file: ProjectFile) throws -> Int {
        guard let index = file.webTabs.firstIndex(where: { $0.id == tabID }) else { throw noTab(tabID) }
        return index
    }

    private static func noTab(_ tabID: UUID) -> ProtocolError {
        ProtocolError(.notFound, "Tab \(tabID.uuidString) does not exist.")
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
