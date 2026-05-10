import Foundation

/// Minimal workspace-local logger compatible with the swift-log API used here.
public struct Logger: Sendable {
    public typealias Metadata = [String: String]

    private let label: String

    public init(label: String) {
        self.label = label
    }

    public func info(_ message: @autoclosure () -> String, metadata: Metadata? = nil) {
        write(level: "info", message: message(), metadata: metadata)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: Metadata? = nil) {
        write(level: "warning", message: message(), metadata: metadata)
    }

    public func error(_ message: @autoclosure () -> String, metadata: Metadata? = nil) {
        write(level: "error", message: message(), metadata: metadata)
    }

    private func write(level: String, message: String, metadata: Metadata?) {
        let meta = metadata?.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ") ?? ""
        let line = meta.isEmpty ? "[\(level)] \(label): \(message)\n" : "[\(level)] \(label): \(message) \(meta)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

/// Minimal logging bootstrap facade compatible with swift-log usage in this package.
public enum LoggingSystem {
    public static func bootstrap(_ factory: @escaping @Sendable (String) -> Logger) {
        _ = factory
    }
}

/// Minimal stream log handler factory compatible with swift-log usage in this package.
public enum StreamLogHandler {
    public static func standardError(label: String) -> Logger {
        Logger(label: label)
    }
}
