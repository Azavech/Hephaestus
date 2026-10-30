import Foundation
import HephClient
import HephCore
import SwiftUI

/// Edits `additionalAddresses` and sends them to this Mac's record (docs/ui/settings.md, "Additional addresses").
struct AddressListEditor: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Workspace.self) private var workspace
    @State private var newAddress = ""
    @State private var isChanging = false
    /// The failure of the settings write.
    @State private var errorMessage: String?
    /// The failure of `mesh.setAddresses` after a successful write.
    @State private var updateError: String?

    init() {}

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(settings.settings.additionalAddresses, id: \.self) { address in
                    HStack(spacing: 8) {
                        Text(address)
                            .font(.body.monospaced())
                        Spacer(minLength: 0)
                        Button {
                            remove(address)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack(spacing: 8) {
                    TextField("Host name or IP address", text: $newAddress,
                              prompt: Text("Host name or IP address"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .onSubmit {
                            add()
                        }
                    Button("Add") {
                        add()
                    }
                    .disabled(!canAdd)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let updateError {
                    Text(updateError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Additional addresses")
            Text("Other devices also try these addresses to reach this Mac, for example a VPN address. The .local "
                + "name and the IPv4 addresses of this Mac are added automatically.")
        }
        .disabled(isChanging)
    }

    /// The trimmed text is not empty, holds no whitespace and is not in the list yet.
    private var canAdd: Bool {
        let address = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return !address.isEmpty && !address.contains(where: \.isWhitespace)
            && !settings.settings.additionalAddresses.contains(address)
    }

    private func add() {
        guard canAdd, !isChanging else { return }
        let address = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if apply(settings.settings.additionalAddresses + [address]) {
            newAddress = ""
        }
    }

    private func remove(_ address: String) {
        guard !isChanging else { return }
        apply(settings.settings.additionalAddresses.filter { $0 != address })
    }

    /// Writes the list, then sends it to this Mac's record with `mesh.setAddresses`; returns whether the write
    /// succeeded.
    @discardableResult
    private func apply(_ addresses: [String]) -> Bool {
        errorMessage = nil
        updateError = nil
        do {
            try settings.update { $0.additionalAddresses = addresses }
        } catch {
            errorMessage = Banner.message(of: error)
            return false
        }
        let saved = settings.settings.additionalAddresses
        let connection = workspace.localConnection
        isChanging = true
        Task {
            do {
                _ = try await connection?.setAddresses(saved)
            } catch {
                updateError = "The addresses are saved but the other devices were not updated: "
                    + Banner.message(of: error)
            }
            isChanging = false
        }
        return true
    }
}
