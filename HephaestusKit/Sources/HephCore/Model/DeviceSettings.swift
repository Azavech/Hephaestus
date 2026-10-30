import Foundation

/// The settings of this device, `settings.json` (docs/data/app-storage.md). Nested keys are JSON objects:
/// `forge.enabled` is `{"forge": {"enabled": …}}`. "Main" settings are read only when `isMain` is true; on other
/// devices they keep their stored values.
public struct DeviceSettings: Codable, Sendable, Equatable {
    public struct Forge: Codable, Sendable, Equatable {
        public var enabled: Bool = false
        public var sourceProjectID: String = "HEPH"
        public var branch: String = "main"
        public var autoRegenerate: Bool = true

        public init() {}
    }

    public struct Updates: Codable, Sendable, Equatable {
        public var enabled: Bool = true
        public var signingIdentity: String = ""

        public init() {}
    }

    public var isMain: Bool = false
    public var projectsFolder: String = "~/Developer"
    public var listenerPort: Int = 47100
    public var pairingPort: Int = 47101
    public var additionalAddresses: [String] = []
    public var claudePath: String = ""
    public var defaultModel: String = ""
    public var defaultPermissionMode: PermissionMode = .acceptEdits
    public var sessionIdleMinutes: Int = 15
    public var autosave: Bool = true
    public var showHiddenFiles: Bool = false
    public var forge = Forge()
    public var updates = Updates()

    public init() {}

    /// Reads each key on its own; a bad or missing key takes its default. A key whose value breaks its rule after
    /// normalization takes its default too. On iOS and iPadOS `isMain` is read as `false`. `listenerPort` is read
    /// before `pairingPort`; a `pairingPort` read equal to `listenerPort` becomes `47100`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        #if os(macOS)
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .isMain) { isMain = value }
        #endif
        if let value = try? container.decodeIfPresent(String.self, forKey: .projectsFolder) {
            let normalized = Self.trimmed(value)
            if Self.isValidProjectsFolder(normalized) { projectsFolder = normalized }
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: .listenerPort), Self.isValidPort(value) {
            listenerPort = value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: .pairingPort),
           Self.isValidPort(value), value != listenerPort {
            pairingPort = value
        }
        // A stored listenerPort of 47101, the default of pairingPort: pairingPort takes 47100, the default of
        // listenerPort, so the settings read pass their rules.
        if pairingPort == listenerPort {
            pairingPort = 47100
        }
        if let value = try? container.decodeIfPresent([String].self, forKey: .additionalAddresses) {
            let normalized = Self.normalizedAddresses(value)
            if Self.areValidAddresses(normalized) { additionalAddresses = normalized }
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .claudePath) {
            let normalized = Self.trimmed(value)
            if Self.isValidClaudePath(normalized) { claudePath = normalized }
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .defaultModel) {
            let normalized = Self.trimmed(value)
            if !Self.hasLineBreak(normalized) { defaultModel = normalized }
        }
        if let value = try? container.decodeIfPresent(PermissionMode.self, forKey: .defaultPermissionMode) {
            defaultPermissionMode = value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: .sessionIdleMinutes),
           Self.isValidIdleMinutes(value) {
            sessionIdleMinutes = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .autosave) { autosave = value }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) { showHiddenFiles = value }

        if let forgeContainer = try? container.nestedContainer(keyedBy: ForgeKeys.self, forKey: .forge) {
            if let value = try? forgeContainer.decodeIfPresent(Bool.self, forKey: .enabled) { forge.enabled = value }
            if let value = try? forgeContainer.decodeIfPresent(String.self, forKey: .sourceProjectID) {
                let normalized = ProjectIdentifier.normalize(value)
                if ProjectIdentifier.isValid(normalized) { forge.sourceProjectID = normalized }
            }
            if let value = try? forgeContainer.decodeIfPresent(String.self, forKey: .branch) {
                let normalized = Self.trimmed(value)
                if Self.isValidBranch(normalized) { forge.branch = normalized }
            }
            if let value = try? forgeContainer.decodeIfPresent(Bool.self, forKey: .autoRegenerate) {
                forge.autoRegenerate = value
            }
        }
        if let updatesContainer = try? container.nestedContainer(keyedBy: UpdatesKeys.self, forKey: .updates) {
            if let value = try? updatesContainer.decodeIfPresent(Bool.self, forKey: .enabled) { updates.enabled = value }
            if let value = try? updatesContainer.decodeIfPresent(String.self, forKey: .signingIdentity) {
                let normalized = Self.trimmed(value)
                if !Self.hasLineBreak(normalized) { updates.signingIdentity = normalized }
            }
        }
    }

    public mutating func normalize() {
        projectsFolder = Self.trimmed(projectsFolder)
        additionalAddresses = Self.normalizedAddresses(additionalAddresses)
        claudePath = Self.trimmed(claudePath)
        defaultModel = Self.trimmed(defaultModel)
        forge.sourceProjectID = ProjectIdentifier.normalize(forge.sourceProjectID)
        forge.branch = Self.trimmed(forge.branch)
        updates.signingIdentity = Self.trimmed(updates.signingIdentity)
    }

    /// Throws DataError.invalid with the first broken rule's message.
    public func validate() throws {
        #if os(iOS)
        if isMain { throw DataError.invalid("only a Mac can be a Main") }
        #endif
        guard Self.isValidProjectsFolder(projectsFolder) else {
            throw DataError.invalid("the projects folder must be an absolute path")
        }
        guard Self.isValidPort(listenerPort) else {
            throw DataError.invalid("the listener port must be between 1024 and 65535")
        }
        guard Self.isValidPort(pairingPort), pairingPort != listenerPort else {
            throw DataError.invalid("the pairing port must be between 1024 and 65535 and differ from the listener port")
        }
        guard Self.areValidAddresses(additionalAddresses) else {
            throw DataError.invalid("an address must not contain spaces")
        }
        guard Self.isValidClaudePath(claudePath) else {
            throw DataError.invalid("the Claude CLI path must be absolute")
        }
        guard !Self.hasLineBreak(defaultModel) else {
            throw DataError.invalid("the model must be on one line")
        }
        guard Self.isValidIdleMinutes(sessionIdleMinutes) else {
            throw DataError.invalid("the idle timeout must be between 1 and 1440 minutes")
        }
        guard ProjectIdentifier.isValid(forge.sourceProjectID) else {
            throw DataError.invalid("the identifier must be 2 to 8 letters A to Z")
        }
        guard Self.isValidBranch(forge.branch) else {
            throw DataError.invalid("the branch must not be empty or contain spaces")
        }
        guard !Self.hasLineBreak(updates.signingIdentity) else {
            throw DataError.invalid("the signing identity must be on one line")
        }
    }

    /// `projectsFolder` with `~` expanded (`NSString.expandingTildeInPath`).
    public var projectsFolderURL: URL {
        URL(fileURLWithPath: (projectsFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// `claudePath` with `~` expanded; nil when `claudePath` is empty.
    public var claudeURL: URL? {
        guard !claudePath.isEmpty else { return nil }
        return URL(fileURLWithPath: (claudePath as NSString).expandingTildeInPath, isDirectory: false)
    }

    // MARK: - Rules

    private enum ForgeKeys: String, CodingKey {
        case enabled, sourceProjectID, branch, autoRegenerate
    }

    private enum UpdatesKeys: String, CodingKey {
        case enabled, signingIdentity
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasLineBreak(_ value: String) -> Bool {
        value.contains { $0.isNewline }
    }

    /// Starts with `/` or `~/`, or is `~`.
    private static func isValidProjectsFolder(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~/") || value == "~"
    }

    private static func isValidPort(_ value: Int) -> Bool {
        (1024...65535).contains(value)
    }

    /// Each trimmed; empty entries and repeats removed (first kept).
    private static func normalizedAddresses(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let address = trimmed(value)
            if !address.isEmpty, !result.contains(address) {
                result.append(address)
            }
        }
        return result
    }

    /// No whitespace inside an entry.
    private static func areValidAddresses(_ values: [String]) -> Bool {
        values.allSatisfy { address in !address.contains { $0.isWhitespace } }
    }

    /// Empty, or starts with `/` or `~/`.
    private static func isValidClaudePath(_ value: String) -> Bool {
        value.isEmpty || value.hasPrefix("/") || value.hasPrefix("~/")
    }

    private static func isValidIdleMinutes(_ value: Int) -> Bool {
        (1...1440).contains(value)
    }

    /// Not empty, no whitespace.
    private static func isValidBranch(_ value: String) -> Bool {
        !value.isEmpty && !value.contains { $0.isWhitespace }
    }
}
