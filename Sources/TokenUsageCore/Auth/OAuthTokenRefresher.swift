import Foundation

/// Sends HTTP requests for OAuth refresh and usage fetching.
public protocol HTTPClientTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Adapts `URLSession` to the package's small HTTP transport protocol.
public struct URLSessionHTTPClient: HTTPClientTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CredentialRefreshError.invalidResponse("No HTTPURLResponse")
        }
        return (data, http)
    }
}

/// Refreshes provider OAuth credentials.
public struct OAuthTokenRefresher: Sendable {
    public static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let transport: HTTPClientTransport

    public init(transport: HTTPClientTransport = URLSessionHTTPClient()) {
        self.transport = transport
    }

    /// Refreshes a credential according to provider-specific OAuth rules.
    public func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            if credential.provider == .codex {
                throw CredentialRefreshError.codexLoginRequired
            }
            throw CredentialRefreshError.noRefreshToken(credential.provider)
        }
        switch credential.provider {
        case .claude:
            return try await refreshClaude(credential: credential, refreshToken: refreshToken)
        case .codex:
            return try await refreshCodex(credential: credential, refreshToken: refreshToken)
        }
    }

    private func refreshClaude(credential: OAuthCredential, refreshToken: String) async throws -> OAuthCredential {
        guard let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            throw CredentialRefreshError.invalidResponse("Invalid Claude refresh URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)
        let (data, response) = try await execute(request)
        guard response.statusCode == 200 else {
            throw CredentialRefreshError.rejected(response.statusCode, String(data: data, encoding: .utf8))
        }
        let decoded: ClaudeRefreshResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: data)
        } catch {
            throw CredentialRefreshError.invalidResponse(error.localizedDescription)
        }
        return OAuthCredential(
            provider: .claude,
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? credential.refreshToken,
            idToken: credential.idToken,
            accountID: credential.accountID,
            accountEmail: credential.accountEmail,
            scopes: credential.scopes,
            expiresAt: Date(timeIntervalSinceNow: TimeInterval(decoded.expiresIn)),
            lastRefresh: credential.lastRefresh,
            rateLimitTier: credential.rateLimitTier)
    }

    private func refreshCodex(credential: OAuthCredential, refreshToken: String) async throws -> OAuthCredential {
        guard let url = URL(string: "https://auth.openai.com/oauth/token") else {
            throw CredentialRefreshError.invalidResponse("Invalid Codex refresh URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.codexClientID,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await execute(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CredentialRefreshError.codexLoginRequired
        }
        guard response.statusCode == 200 else {
            throw CredentialRefreshError.rejected(response.statusCode, String(data: data, encoding: .utf8))
        }
        let decoded: CodexRefreshResponse
        do {
            decoded = try JSONDecoder().decode(CodexRefreshResponse.self, from: data)
        } catch {
            throw CredentialRefreshError.invalidResponse(error.localizedDescription)
        }
        return OAuthCredential(
            provider: .codex,
            accessToken: decoded.accessToken ?? credential.accessToken,
            refreshToken: decoded.refreshToken ?? credential.refreshToken,
            idToken: decoded.idToken ?? credential.idToken,
            accountID: credential.accountID,
            accountEmail: credential.accountEmail,
            scopes: credential.scopes,
            expiresAt: credential.expiresAt,
            lastRefresh: Date(),
            rateLimitTier: credential.rateLimitTier)
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as CredentialRefreshError {
            throw error
        } catch {
            throw CredentialRefreshError.network(error.localizedDescription)
        }
    }

    private struct ClaudeRefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct CodexRefreshResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }
}
