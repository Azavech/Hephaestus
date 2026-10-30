#if os(macOS)
import Foundation
import HephCore

/// The script, pending.json and the after-restart steps (docs/forge/update.md, "Installing", "After a restart").
public enum UpdateInstaller {
    /// install-update.sh, exact content of docs/forge/update.md.
    public static let script: String = """
        #!/bin/sh
        # Installs a downloaded Hephaestus update once the running app has quit. Written by UpdateService.
        # Arguments: <app pid> <installed app> <new app> <previous app> <log file>
        pid="$1"
        target="$2"
        new="$3"
        previous="$4"
        log="$5"
        exec >>"$log" 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') waiting for $pid to quit"
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.5
        done
        rm -rf "$previous"
        mkdir -p "$(dirname "$previous")"
        if mv "$target" "$previous"; then
          if mv "$new" "$target"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') installed $target"
          else
            echo "$(date '+%Y-%m-%d %H:%M:%S') could not move $new; restoring the previous app"
            mv "$previous" "$target"
          fi
        else
          echo "$(date '+%Y-%m-%d %H:%M:%S') could not move $target aside"
        fi
        open "$target"

        """

    /// `Updates/pending.json`.
    struct Pending: Codable, Sendable {
        var build: Int
    }

    /// Installing steps 2 to 4; step 5 (terminate) is UpdateService's.
    public static func install(newApp: URL, build: Int, updatesFolder: URL) async throws {
        let installed = UpdateService.installedAppURL()
        // 2. The installed app's parent folder is writable.
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Cannot replace \(installed.path): the folder is not writable.")
        }
        // 3. The script and pending.json.
        let scriptURL = updatesFolder.appendingPathComponent("install-update.sh", isDirectory: false)
        try AtomicFile.write(Data(script.utf8), to: scriptURL)
        try JSONFile.write(Pending(build: build), to: updatesFolder.appendingPathComponent("pending.json",
                                                                                          isDirectory: false))
        // 4. The script, in the background.
        let arguments = [
            "-c", "nohup /bin/sh \"$0\" \"$@\" >/dev/null 2>&1 &",
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            installed.path,
            newApp.path,
            updatesFolder.appendingPathComponent("previous", isDirectory: true)
                .appendingPathComponent("Hephaestus.app", isDirectory: true).path,
            updatesFolder.appendingPathComponent("install.log", isDirectory: false).path,
        ]
        let configuration = ChildProcessConfiguration(executable: "/bin/sh", arguments: arguments,
                                                      workingDirectory: updatesFolder.path,
                                                      environment: await LoginEnvironment.shared.environment())
        let output = try await ChildProcess.capture(configuration, timeout: .seconds(10))
        guard !output.timedOut, output.termination == .exited(0) else {
            throw UpdateError(ForgeGit.lastLine(output.standardError)
                              ?? (output.timedOut ? "timed out" : "exit status \(output.termination.exitCode)"))
        }
    }

    /// The steps of After a restart; returns the failure message of step 2, if any.
    public static func afterRestart(currentBuild: Int, updatesFolder: URL) -> String? {
        let fileManager = FileManager.default
        // 1. The previous app goes to the Trash.
        let previous = updatesFolder.appendingPathComponent("previous", isDirectory: true)
            .appendingPathComponent("Hephaestus.app", isDirectory: true)
        if fileManager.fileExists(atPath: previous.path) {
            do {
                try fileManager.trashItem(at: previous, resultingItemURL: nil)
            } catch {
                Log.host.error("Could not move the previous app to the Trash: \(error.localizedDescription)")
            }
        }
        // 2. A pending install of another build failed.
        var message: String?
        let pendingURL = updatesFolder.appendingPathComponent("pending.json", isDirectory: false)
        if fileManager.fileExists(atPath: pendingURL.path) {
            do {
                if let pending = try JSONFile.read(Pending.self, from: pendingURL), pending.build != currentBuild {
                    message = "The update to build \(pending.build) was not installed. See "
                        + "~/Library/Application Support/Hephaestus/Updates/install.log."
                }
            } catch {
                Log.host.error("Unreadable pending.json: \((error as? DataError)?.message ?? error.localizedDescription)")
            }
            do {
                try fileManager.removeItem(at: pendingURL)
            } catch {
                Log.host.error("Could not delete pending.json: \(error.localizedDescription)")
            }
        }
        // 3. Every build-* folder.
        removeBuildFolders(in: updatesFolder)
        return message
    }

    /// Deletes every `Updates/build-*` folder.
    static func removeBuildFolders(in updatesFolder: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: updatesFolder.path) else { return }
        for name in names where name.hasPrefix("build-") {
            do {
                try fileManager.removeItem(at: updatesFolder.appendingPathComponent(name, isDirectory: true))
            } catch {
                Log.host.error("Could not delete Updates/\(name, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}

/// A failure of the self-update whose message is shown as the `failed` status.
struct UpdateError: Error, LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
#endif
