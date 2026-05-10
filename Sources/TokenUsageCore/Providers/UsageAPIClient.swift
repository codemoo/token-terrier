import Foundation

/// Describes usage fetch failures that are mapped into snapshot state.
public enum UsageAPIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case invalidResponse(String)
    case server(Int, String?)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Provider usage API rejected the access token."
        case let .invalidResponse(message):
            "Provider usage API returned an invalid response: \(message)"
        case let .server(status, message):
            if let message, !message.isEmpty {
                "Provider usage API returned HTTP \(status): \(message)"
            } else {
                "Provider usage API returned HTTP \(status)."
            }
        case let .network(message):
            "Provider usage API network error: \(message)"
        }
    }
}

/// Fetches normalized provider usage snapshots.
public protocol ProviderUsageFetching: Sendable {
    func snapshot(
        for provider: Provider,
        credential: OAuthCredential,
        producer: ProducerInfo,
        seq: Int,
        now: Date) async throws -> UsageSnapshot
}

/// Calls provider usage endpoints and normalizes their responses.
public struct UsageAPIClient: ProviderUsageFetching, Sendable {
    private let transport: HTTPClientTransport

    public init(transport: HTTPClientTransport = URLSessionHTTPClient()) {
        self.transport = transport
    }

    public func snapshot(
        for provider: Provider,
        credential: OAuthCredential,
        producer: ProducerInfo,
        seq: Int,
        now: Date) async throws -> UsageSnapshot
    {
        switch provider {
        case .claude:
            let data = try await fetchClaude(accessToken: credential.accessToken)
            let decoded = try decode(ClaudeUsageResponse.self, from: data)
            return UsageNormalizer.normalizeClaude(decoded, credential: credential, seq: seq, producer: producer, now: now)
        case .codex:
            let data = try await fetchCodex(accessToken: credential.accessToken, accountID: credential.accountID)
            let decoded = try decode(CodexUsageResponse.self, from: data)
            return UsageNormalizer.normalizeCodex(decoded, credential: credential, seq: seq, producer: producer, now: now)
        }
    }

    private func fetchClaude(accessToken: String) async throws -> Data {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw UsageAPIError.invalidResponse("Invalid Claude usage URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await execute(request)
    }

    private func fetchCodex(accessToken: String, accountID: String?) async throws -> Data {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw UsageAPIError.invalidResponse("Invalid Codex usage URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200...299:
                return data
            case 401, 403:
                throw UsageAPIError.unauthorized
            case 408, 425, 429, 500...599:
                // Transient — UsageState.mapError treats `.server` as
                // `.networkError`, which the sticky cache will mask for up
                // to stickyTTL. 408 (Request Timeout) and 425 (Too Early)
                // are transient too; routing them here avoids an immediate
                // "endpoint changed" UI when the upstream is just flaky.
                throw UsageAPIError.server(response.statusCode, String(data: data, encoding: .utf8))
            default:
                // Other 4xx (400/404/410/...) typically mean the endpoint
                // contract changed, not a transient outage. Surface as
                // `invalidResponse` so UsageState.mapError → .quotaEndpointChanged
                // and the user is told to update the app — instead of the
                // sticky cache hiding it for 10 minutes.
                let body = String(data: data, encoding: .utf8) ?? ""
                throw UsageAPIError.invalidResponse("HTTP \(response.statusCode): \(body)")
            }
        } catch let error as UsageAPIError {
            throw error
        } catch {
            throw UsageAPIError.network(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UsageAPIError.invalidResponse(error.localizedDescription)
        }
    }
}
