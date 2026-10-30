import HephClient
import HephCore
import SwiftUI

/// Browses the folders of a Main with `listDirectories(path:)` (docs/ui/overview.md, "Remote folder browser"). `path`
/// is the current folder: the absolute path of the last successful listing.
struct RemoteFolderBrowser: View {
    let mainDeviceID: UUID
    @Binding var path: String?

    @Environment(Workspace.self) private var workspace
    /// The Main user's home folder, as the listing of `""` returned it.
    @State private var homePath: String?
    /// The listing of the current folder.
    @State private var listing: HostListDirectoriesResult?
    @State private var isLoading = false
    /// The message of the failed listing and the folder Retry lists again (nil: the first listings).
    @State private var failure: (message: String, target: String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    goUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(isLoading || listing == nil || listing?.path == homePath)
                Text(verbatim: listing?.path ?? "")
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            if let failure {
                HStack(spacing: 8) {
                    Text(verbatim: failure.message)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        retry(failure.target)
                    }
                }
            }
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let listing {
                    List(listing.entries, id: \.path) { entry in
                        Button {
                            open(entry.path)
                        } label: {
                            Label(entry.name, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(minHeight: 220)
        }
        .task {
            await start()
        }
    }

    // MARK: - Listings

    /// Lists `""` and keeps the returned path as the home path, then lists the Main's `projectsFolder`; when that
    /// fails, it stays on the home folder.
    private func start() async {
        guard await list("", retryTarget: nil) else { return }
        homePath = listing?.path
        if let projectsFolder = workspace.connection(mainDeviceID)?.hostInfo?.projectsFolder {
            await list(projectsFolder, retryTarget: nil, showsFailure: false)
        }
    }

    /// Choosing a row lists that folder, which becomes the current folder.
    private func open(_ folder: String) {
        Task {
            await list(folder, retryTarget: folder)
        }
    }

    /// Up lists the current path without its last component.
    private func goUp() {
        guard let current = listing?.path else { return }
        let parent = (current as NSString).deletingLastPathComponent
        Task {
            await list(parent, retryTarget: parent)
        }
    }

    private func retry(_ target: String?) {
        Task {
            if let target {
                await list(target, retryTarget: target)
            } else {
                await start()
            }
        }
    }

    /// A successful listing becomes the current folder; a failed one shows its message and a Retry button, and the
    /// current folder does not change.
    @discardableResult
    private func list(_ folder: String, retryTarget: String?, showsFailure: Bool = true) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let connection = try OverviewScreen.connection(mainDeviceID, workspace: workspace)
            let result = try await connection.listDirectories(path: folder)
            listing = result
            path = result.path
            failure = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            if showsFailure {
                failure = (message: Banner.message(of: error), target: retryTarget)
            }
            return false
        }
    }
}
