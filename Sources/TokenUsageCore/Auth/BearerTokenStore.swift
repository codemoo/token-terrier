import Foundation
#if os(macOS)
import Security
#endif

/// Holds daemon bearer tokens used to protect local HTTP routes.
public struct BearerTokens: Codable, Equatable, Sendable {
    public let claude: String
    public let codex: String

    public init(claude: String, codex: String) {
        self.claude = claude
        self.codex = codex
    }

    /// Returns the token for a provider.
    public func token(for provider: Provider) -> String {
        switch provider {
        case .claude:
            claude
        case .codex:
            codex
        }
    }
}

/// Result of loading or creating route bearer tokens.
public struct BearerTokenLoadResult: Equatable, Sendable {
    public let tokens: BearerTokens
    public let createdFile: Bool
    public let url: URL

    public init(tokens: BearerTokens, createdFile: Bool, url: URL) {
        self.tokens = tokens
        self.createdFile = createdFile
        self.url = url
    }
}

/// Loads bearer tokens from environment or `~/.config/token-usage/tokens.json`.
public struct BearerTokenStore: @unchecked Sendable {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let url: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        url: URL? = nil)
    {
        self.environment = environment
        self.fileManager = fileManager
        self.url = url ?? Self.defaultURL(environment: environment, fileManager: fileManager)
    }

    /// Loads route tokens, creating a random token file when no file exists.
    public func loadOrCreate() throws -> BearerTokenLoadResult {
        let fileExisted = fileManager.fileExists(atPath: url.path)
        let fileTokens = fileExisted ? try loadFileTokens() : try createFileTokens()
        let tokens = BearerTokens(
            claude: envToken("TOKEN_USAGE_CLAUDE_TOKEN") ?? fileTokens.claude,
            codex: envToken("TOKEN_USAGE_CODEX_TOKEN") ?? fileTokens.codex)
        return BearerTokenLoadResult(tokens: tokens, createdFile: !fileExisted, url: url)
    }

    /// Checks an Authorization header against the configured provider token.
    public static func isAuthorized(authorizationHeader: String?, expectedToken: String) -> Bool {
        guard let authorizationHeader else { return false }
        let prefix = "Bearer "
        guard authorizationHeader.hasPrefix(prefix) else { return false }
        let token = String(authorizationHeader.dropFirst(prefix.count))
        return token == expectedToken
    }

    private func loadFileTokens() throws -> BearerTokens {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BearerTokens.self, from: data)
    }

    private func createFileTokens() throws -> BearerTokens {
        let tokens = BearerTokens(claude: try randomToken(), codex: try randomToken())
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.tokenUsage.encode(tokens)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return tokens
    }

    private func envToken(_ key: String) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if os(macOS)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CredentialRefreshError.invalidResponse("SecRandomCopyBytes failed: \(status)")
        }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultURL(environment: [String: String], fileManager: FileManager) -> URL {
        let home: URL
        if let value = environment["HOME"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            home = URL(fileURLWithPath: value)
        } else {
            home = fileManager.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("token-usage")
            .appendingPathComponent("tokens.json")
    }
}
