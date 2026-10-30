import Foundation
import HephClient
import HephCore
import HephNet
import SwiftUI

/// The join flow, pushed by onboarding: choose a Main, then enter the code it shows (docs/ui/devices.md,
/// "Join flow").
public struct JoinMeshView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: JoinMeshModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                JoinMeshForm(model: model)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Join a Mesh")
        .onAppear {
            if model == nil {
                model = JoinMeshModel(appModel: appModel)
            }
        }
    }
}

/// The two steps of the join flow in a grouped form.
private struct JoinMeshForm: View {
    @Bindable var model: JoinMeshModel
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Form {
            switch model.step {
            case .chooseMain:
                chooseMain
            case .enterCode:
                enterCode
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Step 1

    @ViewBuilder
    private var chooseMain: some View {
        Section {
            let adverts = readyMains
            if adverts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for Mains…")
                }
            } else {
                ForEach(adverts, id: \.id) { advert in
                    Button {
                        model.choose(advert)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(advert.name)
                                    .font(.headline)
                                Text(advert.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Mains Ready to Pair")
        } footer: {
            Text("On a Main, open Devices and choose Pair a New Device. A Main on another network can be reached by its "
                + "address.")
        }
        Section("Enter an Address") {
            HStack {
                TextField("Address", text: $model.address, prompt: Text("Sams-Mac-mini.local or 192.0.2.10:47101"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit {
                        model.continueWithAddress()
                    }
                Button("Continue") {
                    model.continueWithAddress()
                }
                .disabled(JoinMeshModel.parseAddress(model.address) == nil)
            }
            if !model.address.isEmpty, JoinMeshModel.parseAddress(model.address) == nil {
                Text("Enter a host name or an IP address, optionally followed by :port.")
                    .foregroundStyle(.red)
            }
        }
    }

    /// The Mains seen by Bonjour with an open pairing window, by name.
    private var readyMains: [BonjourAdvert] {
        workspace.seenHosts.values
            .filter(\.pairingOpen)
            .sorted { lhs, rhs in
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
    }

    // MARK: - Step 2

    @ViewBuilder
    private var enterCode: some View {
        Section {
            Text(verbatim: "Enter the 6-digit code shown on \(targetName).")
            PairingCodeField(code: $model.code)
                .disabled(model.isJoining)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        Section {
            TextField("Device name", text: $model.deviceName)
                .disabled(model.isJoining)
            if let nameError = model.nameError {
                Text(nameError)
                    .foregroundStyle(.red)
            }
        }
        Section {
            HStack {
                Button("Back") {
                    model.back()
                }
                Spacer()
                if model.isJoining {
                    ProgressView()
                        .controlSize(.small)
                    Text("Joining…")
                } else {
                    Button("Join") {
                        model.join()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canJoin)
                }
            }
        }
    }

    /// The target's name, else its host.
    private var targetName: String {
        guard let target = model.target else { return "" }
        return target.name ?? target.host
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    NavigationStack {
        JoinMeshView()
    }
    .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
