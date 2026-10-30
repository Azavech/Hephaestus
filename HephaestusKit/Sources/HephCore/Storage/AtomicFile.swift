import Foundation

/// The atomic writes of docs/data/app-storage.md: a temporary file in the destination's folder, renamed over the
/// destination with `rename(2)`. The data is not flushed with `fsync`.
public enum AtomicFile {
    /// Writes `data` to `url`, through its symlinks; creates the missing parent folders. Throws
    /// `DataError.io("<file name>: <reason>")`.
    public static func write(_ data: Data, to url: URL) throws {
        let fileName = url.lastPathComponent
        let destination = url.resolvingSymlinksInPath()
        let folder = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DataError.io("\(fileName): \(error.localizedDescription)")
        }

        // The permissions of the destination when it exists, else 0644.
        var permissions: mode_t = 0o644
        var info = stat()
        if stat(destination.path, &info) == 0 {
            permissions = info.st_mode & 0o7777
        }

        let temporaryName = "." + destination.lastPathComponent + "." + randomHex() + ".tmp"
        let temporaryPath = folder.appendingPathComponent(temporaryName).path
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else {
            throw DataError.io("\(fileName): \(errorText(errno))")
        }
        var failure: String?
        if fchmod(descriptor, permissions) != 0 {
            failure = errorText(errno)
        }
        if failure == nil {
            failure = writeAll(data, to: descriptor)
        }
        if close(descriptor) != 0, failure == nil {
            failure = errorText(errno)
        }
        if failure == nil, rename(temporaryPath, destination.path) != 0 {
            failure = errorText(errno)
        }
        if let failure {
            unlink(temporaryPath)
            throw DataError.io("\(fileName): \(failure)")
        }
    }

    /// True for names of the form `^\..+\.[0-9a-f]{8}\.tmp$`, the temporary files of `write`.
    public static func isTemporaryName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        // "." + at least one character + "." + 8 hex digits + ".tmp"
        guard bytes.count >= 15, bytes[0] == UInt8(ascii: "."), name.hasSuffix(".tmp") else { return false }
        let hexStart = bytes.count - 12
        guard bytes[hexStart - 1] == UInt8(ascii: ".") else { return false }
        for byte in bytes[hexStart..<(hexStart + 8)] {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"): continue
            default: return false
            }
        }
        // `.` of the pattern matches any character except a line break.
        return !bytes[1..<(hexStart - 1)].contains { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }
    }

    private static func randomHex() -> String {
        String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
    }

    /// Writes every byte; returns the failure's text, nil on success.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> String? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            guard var pointer = buffer.baseAddress else { return nil }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errorText(errno)
                }
                remaining -= written
                pointer += written
            }
            return nil
        }
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
