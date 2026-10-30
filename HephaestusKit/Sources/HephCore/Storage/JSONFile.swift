import Foundation

/// Reads and writes the JSON files of the Application Support folder (docs/data/app-storage.md, "JSON files").
public enum JSONFile {
    /// Decodes with `WireCoding.makeDecoder()`. nil when the file does not exist; throws
    /// `.io("<file name>: <reason>")` when it cannot be read and `.unreadable("<file name>: <decoding error>")` when it
    /// cannot be decoded.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        } catch {
            throw DataError.io("\(fileName): \(error.localizedDescription)")
        }
        do {
            return try WireCoding.makeDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw DataError.unreadable("\(fileName): \(describe(error))")
        } catch {
            throw DataError.unreadable("\(fileName): \(error.localizedDescription)")
        }
    }

    /// Encodes with `WireCoding.makeEncoder()` plus `.prettyPrinted` and writes with `AtomicFile.write`.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = WireCoding.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw DataError.io("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        try AtomicFile.write(data, to: url)
    }

    /// A decoding error as text: the path of the failing member, then the decoder's description.
    static func describe(_ error: DecodingError) -> String {
        let path = codingPathText(error.failingPath)
        let detail: String
        switch error {
        case .keyNotFound:
            detail = "missing key"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            detail = context.debugDescription
        @unknown default:
            detail = error.localizedDescription
        }
        return path.isEmpty ? detail : "\(path): \(detail)"
    }
}
