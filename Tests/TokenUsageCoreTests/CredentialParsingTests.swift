import Foundation
import Testing
@testable import TokenUsageCore

@Suite("credential parsing")
struct CredentialParsingTests {
    @Test("parses Claude Code credentials")
    func parsesClaudeCredentials() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "claude-access",
            "refreshToken": "claude-refresh",
            "expiresAt": 1777284095000,
            "scopes": ["user:profile"],
            "rateLimitTier": "max"
          }
        }
        """
        let credential = try CredentialFiles.parseClaude(data: Data(json.utf8))
        #expect(credential.provider == .claude)
        #expect(credential.accessToken == "claude-access")
        #expect(credential.refreshToken == "claude-refresh")
        #expect(credential.scopes == ["user:profile"])
        #expect(credential.rateLimitTier == "max")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_777_284_095))
    }

    @Test("parses Codex auth.json snake_case tokens")
    func parsesCodexSnakeCaseCredentials() throws {
        let json = """
        {
          "tokens": {
            "access_token": "codex-access",
            "refresh_token": "codex-refresh",
            "id_token": "id",
            "account_id": "account"
          },
          "last_refresh": "2026-04-20T00:00:00Z"
        }
        """
        let credential = try CredentialFiles.parseCodex(data: Data(json.utf8))
        #expect(credential.provider == .codex)
        #expect(credential.accessToken == "codex-access")
        #expect(credential.refreshToken == "codex-refresh")
        #expect(credential.idToken == "id")
        #expect(credential.accountID == "account")
        #expect(credential.lastRefresh == SnapshotDateFormatter.date(from: "2026-04-20T00:00:00Z"))
    }

    @Test("parses Codex auth.json camelCase tokens")
    func parsesCodexCamelCaseCredentials() throws {
        let json = """
        {
          "tokens": {
            "accessToken": "codex-access",
            "refreshToken": "codex-refresh",
            "accountEmail": "person@example.com"
          }
        }
        """
        let credential = try CredentialFiles.parseCodex(data: Data(json.utf8))
        #expect(credential.accessToken == "codex-access")
        #expect(credential.refreshToken == "codex-refresh")
        #expect(credential.accountEmail == "person@example.com")
    }
}
