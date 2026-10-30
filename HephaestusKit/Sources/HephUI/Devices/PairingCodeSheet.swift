import Foundation
import HephClient
import HephCore
import HephNet
import SwiftUI

/// Opens a pairing window on a Main and shows its code until a device joins, the code expires or the Main goes
/// offline (docs/ui/devices.md, "Pairing code sheet").
struct PairingCodeSheet: View {
    private let mainDeviceID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .opening
    @State private var isClosing = false

    /// What the sheet shows.
    private enum Phase: Equatable {
        case opening
        case failed(String)
        case code(PairingOpenResult)
        case joined(String)
        case expired
        case offline
    }

    init(mainDeviceID: UUID) {
        self.mainDeviceID = mainDeviceID
    }

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 420)
        #else
        .presentationDetents([.medium])
        #endif
        .task {
            await open()
        }
        .task(id: expiresAt) {
            await waitForExpiry()
        }
        .onChange(of: workspace.mesh) {
            checkJoined()
        }
        .onChange(of: connection?.isConnected) {
            checkOffline()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .opening:
            ProgressView()
            Text("Opening a pairing window…")
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    Task {
                        await open()
                    }
                }
            }
        case .code(let result):
            codeContent(result)
        case .joined(let name):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(verbatim: "\(name) joined the mesh.")
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        case .expired:
            Text("The code has expired.")
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("New Code") {
                    Task {
                        await open()
                    }
                }
            }
        case .offline:
            Text(verbatim: "\(mainName) went offline.")
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func codeContent(_ result: PairingOpenResult) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Pair a New Device")
                    .font(.headline)
                Text(verbatim: "On \(mainName)")
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: Self.formatted(result.code))
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(verbatim: "Expires in \(Self.countdown(until: result.expiresAt, now: timeline.date))")
                    .foregroundStyle(.secondary)
            }
            Text(instructions(port: result.port))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel") {
                cancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isClosing)
        }
    }

    // MARK: - Values

    private var connection: MainConnection? {
        workspace.connection(mainDeviceID)
    }

    private var record: DeviceRecord? {
        workspace.mesh?.devices.first { $0.id == mainDeviceID }
    }

    private var mainName: String {
        connection?.name ?? record?.name ?? "Main"
    }

    private var expiresAt: Date? {
        if case .code(let result) = phase {
            return result.expiresAt
        }
        return nil
    }

    /// The sentence that tells the new device what to do; without an address it omits the address part.
    private func instructions(port: Int) -> String {
        guard let address = record?.addresses.first else {
            return "On the new device, open Hephaestus and choose Join a Mesh. Select \(mainName), then type this code."
        }
        let host = address.contains(":") ? "[\(address)]" : address
        return "On the new device, open Hephaestus and choose Join a Mesh. Select \(mainName), or enter "
            + "\(host):\(port), then type this code."
    }

    /// "123 456": the six digits with a space after the third.
    private static func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    /// The time left as m:ss.
    private static func countdown(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        let remainder = seconds % 60
        return "\(seconds / 60):" + (remainder < 10 ? "0\(remainder)" : "\(remainder)")
    }

    // MARK: - Steps

    /// Step 1: opens the pairing window on the Main.
    private func open() async {
        phase = .opening
        do {
            guard let connection else {
                throw ProtocolError(.unavailable, "\(mainName) is offline.")
            }
            let result = try await connection.openPairing()
            phase = .code(result)
            checkJoined()
            checkOffline()
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(Banner.message(of: error))
        }
    }

    /// Success: a non-revoked device other than the Main paired since the window opened.
    private func checkJoined() {
        guard case .code(let result) = phase, let mesh = workspace.mesh else { return }
        let window = TimeInterval(MeshConstants.pairingWindowDuration.components.seconds)
        let openedAt = result.expiresAt.addingTimeInterval(-window)
        let joined = mesh.devices.filter { !$0.revoked && $0.id != mainDeviceID && $0.pairedAt >= openedAt }
        if let device = joined.max(by: { $0.pairedAt < $1.pairedAt }) {
            phase = .joined(device.name)
        }
    }

    /// The Main's connection left `connected` while the code is shown.
    private func checkOffline() {
        guard case .code = phase, connection?.isConnected != true else { return }
        phase = .offline
    }

    /// Expiry: the countdown reached 0 without success.
    private func waitForExpiry() async {
        guard let expiresAt else { return }
        let delay = expiresAt.timeIntervalSinceNow
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
        if case .code = phase {
            phase = .expired
        }
    }

    /// Cancel: closes the pairing window (a failure is ignored), then dismisses the sheet.
    private func cancel() {
        isClosing = true
        Task {
            try? await connection?.closePairing()
            isClosing = false
            dismiss()
        }
    }
}
