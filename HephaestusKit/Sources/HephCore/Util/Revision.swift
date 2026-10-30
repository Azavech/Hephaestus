import CryptoKit
import Foundation

/// The revision of a file's content (docs/services/files.md §3): clients treat it as an opaque string and compare it
/// for equality only.
public enum Revision {
    /// The first 16 characters of the lowercase hexadecimal SHA-256 (CryptoKit) of `data`.
    public static func of(_ data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
