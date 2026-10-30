import Foundation

/// The errors of the data code (docs/data/app-storage.md, "Errors"). Its message is shown to the user as it is.
///
/// | Case          | Meaning                                                              | Protocol error code |
/// |---------------|----------------------------------------------------------------------|---------------------|
/// | `.notFound`   | the file or item does not exist                                      | `notFound`          |
/// | `.invalid`    | a value breaks a rule, in a request or in a file                     | `badRequest`        |
/// | `.refused`    | the app does not write over an invalid file                          | `conflict`          |
/// | `.unreadable` | a file is not valid UTF-8, YAML or JSON, or not of the expected form | `unavailable`       |
/// | `.io`         | a file system or Keychain operation failed                           | `internal`          |
public enum DataError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalid(String)
    case refused(String)
    case unreadable(String)
    case io(String)

    /// The associated message.
    public var message: String {
        switch self {
        case .notFound(let message), .invalid(let message), .refused(let message), .unreadable(let message),
             .io(let message):
            return message
        }
    }

    /// The message.
    public var description: String { message }
}
