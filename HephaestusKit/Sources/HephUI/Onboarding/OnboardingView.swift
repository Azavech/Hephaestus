import HephClient
import HephCore
import SwiftUI

/// First launch, and again after the device left its mesh: become a Main or join a mesh (docs/ui/onboarding.md).
public struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var name = ""
    @State private var isNamePrefilled = false
    /// The message of the last failed save of the name.
    @State private var saveError: String?
    @State private var isBecomingMain = false
    @State private var isJoinPushed = false
    @State private var becomeMainError: String?
    @State private var isBecomeMainErrorPresented = false

    public init() {}

    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    welcome
                        .frame(maxWidth: 520)
                        .padding(32)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            .disabled(isBecomingMain)
            .navigationDestination(isPresented: $isJoinPushed) {
                JoinMeshView()
                    .navigationTitle("Join a Mesh")
            }
            .alert("This Mac could not become a Main", isPresented: $isBecomeMainErrorPresented,
                   presenting: becomeMainError) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
        .onAppear {
            guard !isNamePrefilled else { return }
            isNamePrefilled = true
            name = appModel.identity.name
        }
    }

    // MARK: - Welcome screen

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Hephaestus")
                .font(.largeTitle)
                .bold()
            Text("Your projects live on Macs set as Mains. Every device of your mesh can see and control them.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            nameField
            VStack(spacing: 12) {
                #if os(macOS)
                OnboardingChoiceButton(
                    symbol: "desktopcomputer",
                    title: "Use this Mac as a Main",
                    text: "Projects live on this Mac and Claude runs here. Creates a new mesh that your other devices "
                        + "join.",
                    isBusy: isBecomingMain,
                    action: useThisMacAsMain
                )
                OnboardingChoiceButton(
                    symbol: "link",
                    title: "Join a Mesh",
                    text: "Connect this Mac to the Mains you already use.",
                    isBusy: false,
                    action: joinMesh
                )
                #else
                OnboardingChoiceButton(
                    symbol: "link",
                    title: "Join a Mesh",
                    text: "Connect to the Mains of your mesh. On a Main, open Devices and choose Pair a New Device.",
                    isBusy: false,
                    action: joinMesh
                )
                #endif
            }
            .disabled(nameProblem != nil)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Device name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) {
                    saveError = nil
                }
            if let message = nameProblem ?? saveError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    /// "Enter a device name." or "Claude is a reserved name." while the field breaks the name rule.
    private var nameProblem: String? {
        do {
            _ = try DeviceIdentityStore.validateName(name)
            return nil
        } catch {
            return Banner.message(of: error)
        }
    }

    // MARK: - Choices

    /// Saves the name; on a failure its message shows under the field.
    private func saveName() -> Bool {
        do {
            try appModel.setLocalName(name)
            saveError = nil
            return true
        } catch {
            saveError = Banner.message(of: error)
            return false
        }
    }

    #if os(macOS)
    /// Makes this Mac the Forge of the mesh it creates (`forge.enabled`), then starts the host, which creates the mesh
    /// and enables the Forge; the phase then becomes `.ready` and every window shows the shell. When this Mac cannot
    /// become a Main, `forge.enabled` gets back the value it had.
    private func useThisMacAsMain() {
        guard saveName() else { return }
        let wasForge = appModel.settings.settings.forge.enabled
        do {
            try appModel.settings.update { $0.forge.enabled = true }
        } catch {
            saveError = Banner.message(of: error)
            return
        }
        isBecomingMain = true
        Task {
            do {
                try await appModel.becomeMain()
            } catch {
                try? appModel.settings.update { $0.forge.enabled = wasForge }
                becomeMainError = Banner.message(of: error)
                isBecomeMainErrorPresented = true
            }
            isBecomingMain = false
        }
    }
    #endif

    private func joinMesh() {
        guard saveName() else { return }
        isJoinPushed = true
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    OnboardingView()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
