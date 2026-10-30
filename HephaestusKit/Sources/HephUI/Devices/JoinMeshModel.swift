import Foundation
import HephClient
import HephCore
import HephNet
import Observation

/// The state of the join flow: choose a Main, then enter the code shown on it (docs/ui/devices.md, "Join flow").
@MainActor @Observable
final class JoinMeshModel {
    enum Step: Equatable { case chooseMain, enterCode }

    struct Target: Equatable {
        var name: String?
        var host: String
        var port: Int
    }

    var step: Step = .chooseMain
    var target: Target?
    /// The manual address field.
    var address = ""
    var code = ""
    var deviceName: String
    private(set) var isJoining = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private var joinTask: Task<Void, Never>?
    /// Identifies the running join; a join that Back cancelled changes nothing afterwards.
    @ObservationIgnored private var joinID: UUID?

    /// The pairing port of an address without port and of an advert without one.
    private static let defaultPairingPort = 47101

    init(appModel: AppModel) {
        self.appModel = appModel
        deviceName = appModel.identity.name
    }

    // MARK: - Step 1

    /// Parses `address` with the rule of step 1: `host`, `host:port`, `[ipv6]` or `[ipv6]:port`, trimmed; a text with
    /// more than one `:` and no brackets is an IPv6 host without port. nil when invalid.
    static func parseAddress(_ text: String) -> Target? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        var portText: Substring?
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.firstIndex(of: ":") {
            host = trimmed[..<colon]
            portText = trimmed[trimmed.index(after: colon)...]
        } else {
            host = Substring(trimmed)
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        var port = defaultPairingPort
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(portText), (1...65535).contains(value) else { return nil }
            port = value
        }
        return Target(name: nil, host: String(host), port: port)
    }

    /// A Main seen by Bonjour with an open pairing window.
    func choose(_ advert: BonjourAdvert) {
        enterCodeStep(with: Target(name: advert.name, host: advert.host,
                                   port: advert.pairingPort ?? Self.defaultPairingPort))
    }

    /// Continue with the manual address; nothing happens while it is invalid.
    func continueWithAddress() {
        guard let parsed = Self.parseAddress(address) else { return }
        enterCodeStep(with: parsed)
    }

    private func enterCodeStep(with target: Target) {
        self.target = target
        code = ""
        errorMessage = nil
        step = .enterCode
    }

    // MARK: - Step 2

    /// "Enter a device name." or "Claude is a reserved name." while the name breaks the name rule.
    var nameError: String? {
        do {
            _ = try DeviceIdentityStore.validateName(deviceName)
            return nil
        } catch {
            return Banner.message(of: error)
        }
    }

    /// The code has 6 digits, the name is valid and no join runs.
    var canJoin: Bool {
        code.count == 6 && code.allSatisfy { ("0"..."9").contains($0) } && nameError == nil && !isJoining
    }

    /// Back to step 1; cancels a running join.
    func back() {
        joinTask?.cancel()
        joinTask = nil
        joinID = nil
        isJoining = false
        errorMessage = nil
        step = .chooseMain
    }

    /// Starts the join task: saves the name, pairs with the Main, then lets every window show the shell.
    func join() {
        guard canJoin, let target else { return }
        let name = deviceName
        let code = code
        let id = UUID()
        joinID = id
        isJoining = true
        errorMessage = nil
        joinTask = Task { [appModel] in
            do {
                try appModel.setLocalName(name)
                _ = try await PairingClient.join(host: target.host, port: target.port, code: code,
                                                 device: appModel.identity.deviceInfo,
                                                 credentialStore: KeychainCredentialStore.shared,
                                                 appSupport: appModel.appSupport)
                appModel.didJoinMesh()
                finishJoin(id)
            } catch {
                guard joinID == id, !(error is CancellationError) else { return }
                finishJoin(id)
                errorMessage = Banner.message(of: error)
                if let pairingError = error as? PairingError, pairingError == .rejected || pairingError == .invalidCode {
                    self.code = ""
                }
            }
        }
    }

    private func finishJoin(_ id: UUID) {
        guard joinID == id else { return }
        joinID = nil
        joinTask = nil
        isJoining = false
    }
}
