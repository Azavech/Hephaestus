#if os(macOS)
import Foundation
import HephCore

/// The user's login environment, captured once when the app launches on macOS (docs/claude/cli.md §1.1); child
/// processes get it.
public actor LoginEnvironment {
    public static let shared = LoginEnvironment()

    private static let marker = "__HEPHAESTUS_ENV__"
    private var capturing: Task<[String: String], Never>?

    /// Starts the capture in a task. Called once at app launch on macOS; later calls do nothing.
    public func capture() {
        _ = startCapture()
    }

    /// The captured environment. Waits for a capture in progress; starts one when none was started.
    public func environment() async -> [String: String] {
        await startCapture().value
    }

    private func startCapture() -> Task<[String: String], Never> {
        if let capturing {
            return capturing
        }
        let task = Task.detached { await Self.run() }
        capturing = task
        return task
    }

    /// `/bin/zsh -lic 'echo __HEPHAESTUS_ENV__; /usr/bin/env -0'`, stdin /dev/null, the app's environment, the home
    /// folder as working directory, timeout 5 s. Failure: the app's environment with the fallback PATH.
    private static func run() async -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var appEnvironment = ProcessInfo.processInfo.environment
        let fallbackPATH = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let configuration = ChildProcessConfiguration(executable: "/bin/zsh",
                                                      arguments: ["-lic", "echo \(marker); /usr/bin/env -0"],
                                                      workingDirectory: home,
                                                      environment: appEnvironment)
        do {
            let output = try await ChildProcess.capture(configuration, timeout: .seconds(5))
            if !output.timedOut, output.termination == .exited(0), var environment = parse(output.standardOutput) {
                if (environment["PATH"] ?? "").isEmpty {
                    environment["PATH"] = fallbackPATH
                }
                Log.host.info("Captured the login environment (\(environment.count, privacy: .public) variables)")
                return environment
            }
            Log.host.error("The login environment could not be captured (timed out: \(output.timedOut, privacy: .public), exit code \(output.termination.exitCode, privacy: .public)); using the fallback PATH")
        } catch {
            Log.host.error("The login shell could not be started: \(String(describing: error)); using the fallback PATH")
        }
        appEnvironment["PATH"] = fallbackPATH
        return appEnvironment
    }

    /// The variables printed after the first line equal to the marker, split on NUL bytes, each at its first `=`;
    /// nil when there is no marker line.
    private static func parse(_ output: Data) -> [String: String]? {
        let markerLine = Array(marker.utf8)
        var lineStart = output.startIndex
        var start: Data.Index?
        while lineStart < output.endIndex {
            let lineEnd = output[lineStart...].firstIndex(of: 0x0A) ?? output.endIndex
            if Array(output[lineStart..<lineEnd]) == markerLine {
                start = lineEnd < output.endIndex ? output.index(after: lineEnd) : output.endIndex
                break
            }
            guard lineEnd < output.endIndex else { break }
            lineStart = output.index(after: lineEnd)
        }
        guard let start else { return nil }
        var environment: [String: String] = [:]
        for item in output[start...].split(separator: 0, omittingEmptySubsequences: true) {
            guard let equals = item.firstIndex(of: UInt8(ascii: "=")), equals != item.startIndex else { continue }
            let name = String(decoding: item[item.startIndex..<equals], as: UTF8.self)
            let value = String(decoding: item[item.index(after: equals)...], as: UTF8.self)
            environment[name] = value
        }
        return environment
    }
}
#endif
