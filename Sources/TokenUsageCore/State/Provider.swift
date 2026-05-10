import Foundation

/// Identifies a quota provider exposed by the daemon.
public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

/// Describes the provider's current fetch/auth state.
public enum ProviderState: String, Codable, Sendable {
    case ok
    case refreshing
    case authExpired
    case networkError
    case codexLoggedOut
    case quotaEndpointChanged
}

/// Identifies how the snapshot was produced.
public enum SnapshotDataSource: String, Codable, Sendable {
    case apiOnly = "api_only"
    case apiAndJsonl = "api+jsonl"
    case jsonlOnly = "jsonl_only"
}

/// Captures stable producer metadata included in every snapshot.
public struct ProducerInfo: Codable, Equatable, Sendable {
    public let id: String
    public let timeZone: String

    public init(id: String, timeZone: String) {
        self.id = id
        self.timeZone = timeZone
    }

    /// Builds producer metadata from process environment and host defaults.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProducerInfo {
        let id = environment["TOKEN_USAGE_PRODUCER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeZone = environment["TOKEN_USAGE_TZ"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProducerInfo(
            id: id?.isEmpty == false ? id ?? "unknown-producer" : ProcessInfo.processInfo.hostName,
            timeZone: timeZone?.isEmpty == false ? timeZone ?? TimeZone.current.identifier : TimeZone.current.identifier)
    }
}
