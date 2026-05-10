import Foundation
import Testing
@testable import TokenUsageCore

@Suite("sse and state")
struct SSEAndStateTests {
    @Test("SSEHub sends latest snapshot immediately and heartbeats")
    func sseHubSnapshotAndHeartbeat() async throws {
        let hub = SSEHub(heartbeatInterval: .milliseconds(40))
        let snapshot = UsageSnapshot.degraded(
            provider: .claude,
            seq: 1,
            producer: ProducerInfo(id: "test-producer", timeZone: "Asia/Seoul"),
            now: Date(timeIntervalSince1970: 1_777_264_400),
            state: .authExpired)
        try await hub.publishSnapshot(snapshot)
        let stream = await hub.subscribe(lastEventID: "1")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.text.contains("event: snapshot") == true)
        #expect(first?.text.contains("id: 1") == true)
        let heartbeat = await iterator.next()
        #expect(heartbeat?.text == ":\n\n")
    }

    @Test("auth helper validates provider bearer token")
    func bearerAuthHelper() {
        #expect(BearerTokenStore.isAuthorized(authorizationHeader: "Bearer abc", expectedToken: "abc"))
        #expect(!BearerTokenStore.isAuthorized(authorizationHeader: "Bearer abc", expectedToken: "def"))
        #expect(!BearerTokenStore.isAuthorized(authorizationHeader: nil, expectedToken: "abc"))
    }

    @Test("UsageState emits degraded snapshot on auth failure")
    func usageStateDegradedSnapshotOnAuthFailure() async throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-terrier-test-state-\(UUID().uuidString).lock")
        let manager = CredentialManager(
            provider: .claude,
            loader: {
                OAuthCredential(
                    provider: .claude,
                    accessToken: "access",
                    refreshToken: "refresh",
                    expiresAt: Date(timeIntervalSince1970: 9_999_999_999))
            },
            saver: { _ in },
            // Status-400 refresh response surfaces as `CredentialRefreshError.rejected`.
            // After the fetcher's 401, `UsageState` calls `forceRefresh` (because
            // the on-disk token still matches what we sent), the refresher sees
            // 400 and rejects, and the outer catch maps that to `.authExpired`.
            refresher: OAuthTokenRefresher(transport: StaticTransport(status: 400, body: "{}")),
            refreshLock: CredentialRefreshLock(url: lockURL, timeout: 10))
        let state = UsageState(
            provider: .claude,
            credentials: manager,
            fetcher: FailingFetcher(error: UsageAPIError.unauthorized),
            producer: ProducerInfo(id: "test-producer", timeZone: "Asia/Seoul"))
        let update = await state.refreshSnapshot(now: Date(timeIntervalSince1970: 1_777_264_400))
        #expect(update.snapshot.status.state == .authExpired)
        #expect(update.snapshot.status.stale)
        #expect(update.emitAuthExpired)
        #expect(update.snapshot.burnRatePerMinute == 0)
        #expect(update.snapshot.todayTotalTokens == 0)
        try? FileManager.default.removeItem(at: lockURL)
    }
}

private struct FailingFetcher: ProviderUsageFetching {
    let error: Error

    func snapshot(
        for provider: Provider,
        credential: OAuthCredential,
        producer: ProducerInfo,
        seq: Int,
        now: Date) async throws -> UsageSnapshot
    {
        throw error
    }
}

private struct StaticTransport: HTTPClientTransport {
    let status: Int
    let body: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil))
        return (Data(body.utf8), response)
    }
}
