import Foundation
import HephClient
import HephCore
import Observation

/// The text of one file of a skill (docs/ui/skills.md, "File view"): loaded with `readSkillFile`, edited, saved with
/// ⌘S or autosave, and read again when `skills.changed` gives its skill a new `modified`.
@MainActor @Observable
final class SkillFileDocument {
    enum Content: Equatable {
        case loading
        /// Data that decodes as UTF-8: `text` holds it.
        case text
        /// Any other data: it cannot be edited.
        case binary(size: Int)
        case failed(String)
    }

    let mainDeviceID: UUID
    let skillName: String
    let path: String
    private(set) var content: Content = .loading
    private(set) var text = ""
    private(set) var isModified = false
    /// A read answered `notFound`: "This file was deleted." shows above the content; editing is disabled.
    private(set) var isDeleted = false
    /// The Main's text changed while the document was modified: the banner "Changed on the Main" shows.
    private(set) var hasMainChange = false
    /// From the moment the screen starts deleting the file or its skill: nothing saves the document, neither its view
    /// going away nor ⌘S nor autosave. `restore()` ends it when that deletion fails.
    @ObservationIgnored private(set) var isDiscarded = false

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let autosaveBanners: AppBannerRouter
    /// The text last read from or written to the Main.
    @ObservationIgnored private var baseText = ""
    /// The Main's text when it changed while the document was modified (Reload takes it).
    @ObservationIgnored private var mainText: String?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var isSaving = false
    /// The saves waiting for the save in flight to end.
    @ObservationIgnored private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    /// Autosave starts this long after the last edit.
    private static let autosaveDelay: Duration = .milliseconds(1500)

    init(workspace: Workspace, settings: SettingsStore, autosaveBanners: AppBannerRouter, mainDeviceID: UUID,
         skillName: String, path: String) {
        self.workspace = workspace
        self.settings = settings
        self.autosaveBanners = autosaveBanners
        self.mainDeviceID = mainDeviceID
        self.skillName = skillName
        self.path = path
    }

    /// Text that can be edited: loaded as text, and not deleted.
    var isEditable: Bool {
        content == .text && !isDeleted
    }

    /// Load: the document holds the text and is not modified.
    func load() async {
        do {
            let data = try await connection().readSkillFile(name: skillName, path: path)
            apply(data)
            isModified = false
        } catch let error as ProtocolError where error.code == .notFound {
            isDeleted = true
        } catch {
            if content == .loading {
                content = .failed(Banner.message(of: error))
            }
        }
    }

    /// An edit: the document is modified; with autosave on, the 1.5 s delay restarts.
    func edit(_ newText: String) {
        guard isEditable, newText != text else { return }
        text = newText
        isModified = true
        scheduleAutosave()
    }

    /// ⌘S or autosave: `save()`; a failure goes to `report`.
    func save(reporting report: @escaping @MainActor (any Error) -> Void) async {
        do {
            try await save()
        } catch {
            report(error)
        }
    }

    /// Waits for a save in flight to end, then, while the document is modified, `writeSkillFile` with the UTF-8 text.
    /// Success: not modified, unless the text changed during the request. Failure: the error is thrown; still
    /// modified. Does nothing while the document is discarded.
    func save() async throws {
        while isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
        }
        guard !isDiscarded, isEditable, isModified else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        isSaving = true
        defer {
            isSaving = false
            let waiters = saveWaiters
            saveWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        let saving = text
        try await connection().writeSkillFile(name: skillName, path: path, data: Data(saving.utf8))
        baseText = saving
        if text == saving {
            isModified = false
        }
    }

    /// The screen starts deleting the file or its skill: nothing saves the document any more, and its autosave is
    /// cancelled.
    func discard() {
        isDiscarded = true
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// The deletion failed: the document is no longer discarded.
    func restore() {
        isDiscarded = false
    }

    /// `skills.changed` gave the skill a new `modified`: the file is read again. Equal to the text, or to the text this
    /// device last read or wrote (this device's own save): nothing. Not modified: the text is replaced. Modified: the
    /// banner "Changed on the Main".
    func mainDidChange() async {
        do {
            let data = try await connection().readSkillFile(name: skillName, path: path)
            isDeleted = false
            guard let mainText = String(data: data, encoding: .utf8), content == .text else {
                apply(data)
                return
            }
            if mainText == text {
                baseText = mainText
                hasMainChange = false
                return
            }
            // The text this device last read or wrote: the change is this device's own save.
            if mainText == baseText {
                return
            }
            if isModified {
                self.mainText = mainText
                hasMainChange = true
            } else {
                text = mainText
                baseText = mainText
            }
        } catch let error as ProtocolError where error.code == .notFound {
            isDeleted = true
            autosaveTask?.cancel()
            autosaveTask = nil
        } catch {
            autosaveBanners.post(Banner(style: .error, message: Banner.message(of: error)))
        }
    }

    /// Reload: takes the Main's text.
    func reloadFromMain() {
        guard let mainText else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        text = mainText
        baseText = mainText
        isModified = false
        hasMainChange = false
        self.mainText = nil
    }

    /// Keep Mine: closes the banner; the next save overwrites.
    func keepMine() {
        if let mainText {
            baseText = mainText
        }
        hasMainChange = false
        mainText = nil
    }

    // MARK: Private

    private func apply(_ data: Data) {
        if let string = String(data: data, encoding: .utf8) {
            text = string
            baseText = string
            content = .text
        } else {
            content = .binary(size: data.count)
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard settings.settings.autosave, !isDiscarded else { return }
        let banners = autosaveBanners
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.autosaveDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // The delay is over: the save starts and is no longer the pending autosave, which a save or the next
            // edit cancels; cancelling it now would cancel its request.
            self.autosaveTask = nil
            await self.save { error in
                banners.post(Banner(style: .error, message: Banner.message(of: error)))
            }
        }
    }

    private func connection() throws -> MainConnection {
        guard let workspace else {
            throw ProtocolError(.unavailable, "Main is offline.")
        }
        guard let connection = workspace.connection(mainDeviceID) else {
            throw ProtocolError(.unavailable, "\(ClaudeNames.mainName(mainDeviceID, in: workspace)) is offline.")
        }
        return connection
    }
}
