import Foundation

/// Loads and saves provider OAuth credential files.
public enum CredentialFiles {
    /// Returns the default Claude Code credential path.
    public static func claudeCredentialsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
        -> URL
    {
        homeURL(environment: environment, fileManager: fileManager)
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    /// Returns the default Codex credential path.
    public static func codexAuthURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
        -> URL
    {
        homeURL(environment: environment, fileManager: fileManager)
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
    }

    /// Returns the lock-file path used to serialize OAuth refresh across
    /// processes (TokenTerrier menubar, daemon, future helper executables).
    /// Sits next to the credential JSON it protects.
    public static func credentialLockURL(
        for provider: Provider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
        -> URL
    {
        let home = homeURL(environment: environment, fileManager: fileManager)
        switch provider {
        case .claude:
            return home.appendingPathComponent(".claude").appendingPathComponent(".credentials.lock")
        case .codex:
            return home.appendingPathComponent(".codex").appendingPathComponent("auth.lock")
        }
    }

    /// Loads Claude credentials from disk.
    public static func loadClaude(url: URL? = nil) throws -> OAuthCredential {
        let resolvedURL = url ?? claudeCredentialsURL()
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw CredentialFileError.notFound(resolvedURL.path)
        }
        let data = try Data(contentsOf: resolvedURL)
        return try parseClaude(data: data)
    }

    /// Loads Codex credentials from disk.
    public static func loadCodex(url: URL? = nil) throws -> OAuthCredential {
        let resolvedURL = url ?? codexAuthURL()
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw CredentialFileError.notFound(resolvedURL.path)
        }
        let data = try Data(contentsOf: resolvedURL)
        return try parseCodex(data: data)
    }

    /// Parses Claude Code's `~/.claude/.credentials.json` OAuth block.
    public static func parseClaude(data: Data) throws -> OAuthCredential {
        let decoder = JSONDecoder()
        let root: ClaudeRoot
        do {
            root = try decoder.decode(ClaudeRoot.self, from: data)
        } catch {
            throw CredentialFileError.invalidJSON(error.localizedDescription)
        }
        guard let oauth = root.claudeAiOauth else {
            throw CredentialFileError.missingToken("claudeAiOauth")
        }
        let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw CredentialFileError.missingToken("claudeAiOauth.accessToken")
        }
        return OAuthCredential(
            provider: .claude,
            accessToken: accessToken,
            refreshToken: trimmed(oauth.refreshToken),
            scopes: oauth.scopes ?? [],
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            rateLimitTier: trimmed(oauth.rateLimitTier))
    }

    /// Parses Codex CLI's `~/.codex/auth.json` token block.
    public static func parseCodex(data: Data) throws -> OAuthCredential {
        let json = try jsonObject(data: data)
        if let apiKey = trimmed(json["OPENAI_API_KEY"] as? String), !apiKey.isEmpty {
            return OAuthCredential(provider: .codex, accessToken: apiKey, refreshToken: nil)
        }
        guard let tokens = json["tokens"] as? [String: Any] else {
            throw CredentialFileError.missingToken("tokens")
        }
        guard let accessToken = stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken"),
              !accessToken.isEmpty
        else {
            throw CredentialFileError.missingToken("tokens.access_token")
        }
        let refreshToken = stringValue(in: tokens, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken")
        return OAuthCredential(
            provider: .codex,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken"),
            accountID: stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
            accountEmail: stringValue(in: tokens, snakeCaseKey: "account_email", camelCaseKey: "accountEmail"),
            lastRefresh: parseDate(from: json["last_refresh"]))
    }

    /// Saves refreshed Claude credentials back to the Claude credential JSON.
    public static func saveClaude(_ credential: OAuthCredential, url: URL? = nil) throws {
        guard credential.provider == .claude else {
            throw CredentialFileError.unsupportedProvider("Expected claude credential")
        }
        let resolvedURL = url ?? claudeCredentialsURL()
        var json = try existingJSONObject(at: resolvedURL)
        var oauth = (json["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = credential.accessToken
        if let refreshToken = credential.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = credential.expiresAt {
            oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        }
        oauth["scopes"] = credential.scopes
        if let tier = credential.rateLimitTier {
            oauth["rateLimitTier"] = tier
        }
        json["claudeAiOauth"] = oauth
        try writeJSONObject(json, to: resolvedURL)
    }

    /// Saves refreshed Codex credentials back to the Codex auth JSON.
    public static func saveCodex(_ credential: OAuthCredential, url: URL? = nil) throws {
        guard credential.provider == .codex else {
            throw CredentialFileError.unsupportedProvider("Expected codex credential")
        }
        let resolvedURL = url ?? codexAuthURL()
        var json = try existingJSONObject(at: resolvedURL)
        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credential.accessToken
        if let refreshToken = credential.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credential.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credential.accountID {
            tokens["account_id"] = accountID
        }
        if let accountEmail = credential.accountEmail {
            tokens["account_email"] = accountEmail
        }
        json["tokens"] = tokens
        json["last_refresh"] = SnapshotDateFormatter.string(from: credential.lastRefresh ?? Date())
        try writeJSONObject(json, to: resolvedURL)
    }

    private struct ClaudeRoot: Decodable {
        let claudeAiOauth: ClaudeOAuth?
    }

    private struct ClaudeOAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let rateLimitTier: String?
    }

    private static func homeURL(
        environment: [String: String],
        fileManager: FileManager)
        -> URL
    {
        if let home = environment["HOME"], !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: home)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private static func existingJSONObject(at url: URL) throws -> [String: Any] {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try jsonObject(data: data)
        }
        return [:]
    }

    private static func jsonObject(data: Data) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CredentialFileError.invalidJSON("Root is not an object")
            }
            return json
        } catch let error as CredentialFileError {
            throw error
        } catch {
            throw CredentialFileError.invalidJSON(error.localizedDescription)
        }
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        // `.atomic` writes a temp file with default umask (typically 0644),
        // then renames over the credential file. Restore `0600` so an
        // OAuth credential isn't world/group-readable on shared machines.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
        -> String?
    {
        if let value = trimmed(dictionary[snakeCaseKey] as? String), !value.isEmpty {
            return value
        }
        if let value = trimmed(dictionary[camelCaseKey] as? String), !value.isEmpty {
            return value
        }
        return nil
    }

    private static func parseDate(from raw: Any?) -> Date? {
        if let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SnapshotDateFormatter.date(from: value)
        }
        if let value = raw as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
