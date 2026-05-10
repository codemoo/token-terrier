import Foundation

/// Represents one serialized server-sent event frame.
public struct SSEEvent: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    /// Builds a heartbeat comment frame.
    public static func heartbeat() -> SSEEvent {
        SSEEvent(text: ":\n\n")
    }

    /// Builds a snapshot event frame.
    public static func snapshot(_ snapshot: UsageSnapshot, encoder: JSONEncoder = .tokenUsage) throws -> SSEEvent {
        let data = try encoder.encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SSEEventError.invalidUTF8
        }
        return SSEEvent(text: "id: \(snapshot.seq)\nevent: snapshot\ndata: \(json)\n\n")
    }

    /// Builds an auth-expired event frame.
    public static func authExpired(provider: Provider, seq: Int, state: ProviderState) -> SSEEvent {
        let json = #"{"provider":"\#(provider.rawValue)","state":"\#(state.rawValue)"}"#
        return SSEEvent(text: "id: \(seq)\nevent: auth_expired\ndata: \(json)\n\n")
    }
}

/// Describes SSE frame serialization failures.
public enum SSEEventError: Error, Equatable, Sendable {
    case invalidUTF8
}

extension JSONEncoder {
    /// Encoder configured for stable daemon JSON output.
    public static var tokenUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
