#if os(macOS)
import Foundation
import HephCore

/// A code signing identity offered in Settings (docs/forge/update.md, "Re-signing").
public struct SigningIdentity: Sendable, Hashable, Identifiable {
    public let sha1: String                                 // 40 uppercase hex characters
    public let name: String                                 // "Apple Development: Jane Appleseed (ABCDE12345)"
    public var id: String { sha1 }

    public init(sha1: String, name: String) {
        self.sha1 = sha1
        self.name = name
    }
}

/// The security and codesign calls of Re-signing and Verification.
public enum CodeSigning {
    /// `/usr/bin/security find-identity -v -p codesigning` (timeout 30 s): in output order, the identities whose
    /// quoted name starts with `Apple Development:` or `Developer ID Application:`; empty when the command fails.
    public static func identities() async -> [SigningIdentity] {
        guard let output = try? await run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"],
                                          timeout: .seconds(30)),
              output.termination == .exited(0), !output.timedOut
        else { return [] }
        return parseIdentities(String(decoding: output.standardOutput, as: UTF8.self))
    }

    /// `/usr/bin/codesign --verify --deep --strict <app>` (timeout 120 s); throws with the last line of its standard
    /// error when it does not exit 0.
    public static func verify(_ app: URL) async throws {
        try await succeed("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    /// `/usr/bin/codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign <identity> <app>`
    /// (timeout 120 s), then `verify`; throws with the last line of the standard error of the command that failed.
    public static func sign(_ app: URL, identity: String) async throws {
        try await succeed("/usr/bin/codesign", ["--force", "--deep", "--preserve-metadata=entitlements,flags,runtime",
                                                "--sign", identity, app.path])
        try await verify(app)
    }

    // MARK: - Helpers

    /// The identities of the lines `  1) <40 hex> "<name>"` whose name starts with `Apple Development:` or
    /// `Developer ID Application:`.
    static func parseIdentities(_ text: String) -> [SigningIdentity] {
        var identities: [SigningIdentity] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[0].hasSuffix(")"), parts[1].count == 40,
                  parts[1].allSatisfy(\.isHexDigit)
            else { continue }
            let quoted = parts[2]
            guard quoted.hasPrefix("\""), let close = quoted.lastIndex(of: "\""), close != quoted.startIndex else {
                continue
            }
            let name = String(quoted[quoted.index(after: quoted.startIndex)..<close])
            guard name.hasPrefix("Apple Development:") || name.hasPrefix("Developer ID Application:") else { continue }
            identities.append(SigningIdentity(sha1: parts[1].uppercased(), name: name))
        }
        return identities
    }

    /// Runs a command that must exit 0 (timeout 120 s).
    private static func succeed(_ executable: String, _ arguments: [String]) async throws {
        let output: CapturedOutput
        do {
            output = try await run(executable, arguments, timeout: .seconds(120))
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CodeSigningError(detail: error.localizedDescription)
        }
        guard !output.timedOut, output.termination == .exited(0) else {
            let detail = ForgeGit.lastLine(output.standardError)
                ?? (output.timedOut ? "timed out" : "exit status \(output.termination.exitCode)")
            throw CodeSigningError(detail: detail)
        }
    }

    /// `ChildProcess.capture` with the login environment, the Updates folder as working directory.
    private static func run(_ executable: String, _ arguments: [String],
                            timeout: Duration) async throws -> CapturedOutput {
        let configuration = ChildProcessConfiguration(executable: executable, arguments: arguments,
                                                      workingDirectory: UpdateService.workingDirectory().path,
                                                      environment: await LoginEnvironment.shared.environment())
        return try await ChildProcess.capture(configuration, timeout: timeout)
    }
}

/// A failed codesign command; its message is the last line of the command's standard error.
struct CodeSigningError: Error, LocalizedError, Sendable {
    let detail: String

    var errorDescription: String? { detail }
}
#endif
