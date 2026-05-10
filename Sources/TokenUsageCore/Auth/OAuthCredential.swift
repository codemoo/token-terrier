import Foundation

/// Holds OAuth tokens loaded from provider CLI credential files.
public struct OAuthCredential: Equatable, Sendable {
    public let provider: Provider
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String?
    public let accountEmail: String?
    public let scopes: [String]
    public let expiresAt: Date?
    public let lastRefresh: Date?
    public let rateLimitTier: String?

    public init(
        provider: Provider,
        accessToken: String,
        refreshToken: String?,
        idToken: String? = nil,
        accountID: String? = nil,
        accountEmail: String? = nil,
        scopes: [String] = [],
        expiresAt: Date? = nil,
        lastRefresh: Date? = nil,
        rateLimitTier: String? = nil)
    {
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.lastRefresh = lastRefresh
        self.rateLimitTier = rateLimitTier
    }

    /// A short, stable identifier for the account this credential authorizes.
    /// Used to detect login / account switches so cached snapshots from a
    /// previous account aren't served to the new one. Prefers explicit
    /// account fields when present; falls back to the access-token tail
    /// (which rotates on every refresh, but identical-account refreshes
    /// don't matter for this — we re-key on successful fetch anyway).
    public var accountKey: String {
        if let accountID, !accountID.isEmpty { return "id:\(accountID)" }
        if let accountEmail, !accountEmail.isEmpty { return "em:\(accountEmail)" }
        let tail = String(accessToken.suffix(8))
        return "tk:\(tail)"
    }

    /// Returns whether this credential should be refreshed before use.
    public func needsRefresh(now: Date, skew: TimeInterval = 300) -> Bool {
        switch self.provider {
        case .claude:
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSince(now) <= skew
        case .codex:
            guard let lastRefresh else { return true }
            let freshnessWindow: TimeInterval = 8 * 24 * 60 * 60
            return lastRefresh.addingTimeInterval(freshnessWindow).timeIntervalSince(now) <= skew
        }
    }
}

/// Describes credential file parsing and persistence failures.
public enum CredentialFileError: LocalizedError, Equatable, Sendable {
    case notFound(String)
    case invalidJSON(String)
    case missingToken(String)
    case unsupportedProvider(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "Credential file not found: \(path)"
        case let .invalidJSON(message):
            "Credential JSON is invalid: \(message)"
        case let .missingToken(message):
            "Credential JSON is missing a token: \(message)"
        case let .unsupportedProvider(message):
            "Unsupported credential provider: \(message)"
        }
    }
}

/// Describes refresh failures that should map into provider state.
public enum CredentialRefreshError: LocalizedError, Equatable, Sendable {
    case noRefreshToken(Provider)
    case codexLoginRequired
    case invalidResponse(String)
    case rejected(Int, String?)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .noRefreshToken(provider):
            "No refresh token available for \(provider.rawValue)."
        case .codexLoginRequired:
            "Run 'codex login' to refresh."
        case let .invalidResponse(message):
            "Invalid OAuth refresh response: \(message)"
        case let .rejected(status, message):
            if let message, !message.isEmpty {
                "OAuth refresh rejected with HTTP \(status): \(message)"
            } else {
                "OAuth refresh rejected with HTTP \(status)."
            }
        case let .network(message):
            "OAuth refresh network error: \(message)"
        }
    }
}
