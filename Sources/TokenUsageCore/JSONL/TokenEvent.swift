import Foundation

/// One token-counted activity observed in a provider's local JSONL log.
public struct TokenEvent: Equatable, Sendable {
    public let provider: Provider
    public let timestamp: Date
    public let tokens: Int
    public let model: String?
    public let sessionKey: String

    public init(
        provider: Provider,
        timestamp: Date,
        tokens: Int,
        model: String?,
        sessionKey: String)
    {
        self.provider = provider
        self.timestamp = timestamp
        self.tokens = tokens
        self.model = model
        self.sessionKey = sessionKey
    }
}
