import os

/// The loggers of Hephaestus: subsystem `ca.azavech.hephaestus`, one category per module.
public enum Log {
    public static let subsystem = "ca.azavech.hephaestus"

    public static let core = Logger(subsystem: subsystem, category: "HephCore")
    public static let net = Logger(subsystem: subsystem, category: "HephNet")
    public static let host = Logger(subsystem: subsystem, category: "HephHost")
    public static let client = Logger(subsystem: subsystem, category: "HephClient")
    public static let editor = Logger(subsystem: subsystem, category: "HephEditor")
    public static let markdown = Logger(subsystem: subsystem, category: "HephMarkdown")
    public static let ui = Logger(subsystem: subsystem, category: "HephUI")
}
