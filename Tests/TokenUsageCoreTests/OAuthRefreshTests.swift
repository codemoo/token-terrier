import Foundation
import Testing
@testable import TokenUsageCore

@Suite("oauth refresh", .serialized)
struct OAuthRefreshTests {
    @Test("Codex refresh uses exact JSON parameters")
    func codexRefreshUsesExactParameters() async throws {
        let session = makeMockSession { request in
            #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(requestBodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["grant_type"] == "refresh_token")
            #expect(json["refresh_token"] == "refresh")
            #expect(json["client_id"] == OAuthTokenRefresher.codexClientID)
            #expect(json["scope"] == "openid profile email")
            return (200, #"{"access_token":"new-access","refresh_token":"new-refresh","id_token":"new-id"}"#)
        }
        let refresher = OAuthTokenRefresher(transport: URLSessionHTTPClient(session: session))
        let credential = OAuthCredential(provider: .codex, accessToken: "old", refreshToken: "refresh")
        let refreshed = try await refresher.refresh(credential)
        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "new-refresh")
        #expect(refreshed.idToken == "new-id")
        #expect(refreshed.lastRefresh != nil)
    }

    @Test("Claude refresh keeps existing refresh token when response omits it")
    func claudeRefreshKeepsExistingRefreshToken() async throws {
        let session = makeMockSession { request in
            #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let body = String(data: try #require(requestBodyData(from: request)), encoding: .utf8)
            #expect(body?.contains("grant_type=refresh_token") == true)
            #expect(body?.contains("refresh_token=old-refresh") == true)
            return (200, #"{"access_token":"new-access","expires_in":3600}"#)
        }
        let refresher = OAuthTokenRefresher(transport: URLSessionHTTPClient(session: session))
        let credential = OAuthCredential(
            provider: .claude,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            scopes: ["user:profile"],
            rateLimitTier: "max")
        let refreshed = try await refresher.refresh(credential)
        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "old-refresh")
        #expect(refreshed.scopes == ["user:profile"])
        #expect(refreshed.rateLimitTier == "max")
    }

    @Test("CredentialManager coalesces concurrent refreshes")
    func credentialManagerSingleflight() async throws {
        let transport = CountingRefreshTransport()
        let refresher = OAuthTokenRefresher(transport: transport)
        let old = OAuthCredential(
            provider: .codex,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            lastRefresh: Date(timeIntervalSince1970: 0))
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-terrier-test-singleflight-\(UUID().uuidString).lock")
        let manager = CredentialManager(
            provider: .codex,
            loader: { old },
            saver: { _ in },
            refresher: refresher,
            refreshLock: CredentialRefreshLock(url: lockURL, timeout: 10))

        async let first = manager.validCredential(now: Date(timeIntervalSince1970: 1_777_264_400))
        async let second = manager.validCredential(now: Date(timeIntervalSince1970: 1_777_264_400))
        let results = try await [first, second]
        #expect(results[0].accessToken == "singleflight-access")
        #expect(results[1].accessToken == "singleflight-access")
        #expect(await transport.callCount() == 1)
        try? FileManager.default.removeItem(at: lockURL)
    }

    @Test("Cross-process refresh lock prevents duplicate refreshes across managers")
    func credentialManagersShareRefreshLock() async throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-terrier-test-shared-lock-\(UUID().uuidString).lock")
        let disk = SharedDisk(initial: OAuthCredential(
            provider: .codex,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            lastRefresh: Date(timeIntervalSince1970: 0)))
        let transport = CountingRefreshTransport()
        let refresher = OAuthTokenRefresher(transport: transport)
        let lock = CredentialRefreshLock(url: lockURL, timeout: 30, pollInterval: .milliseconds(20))
        let managerA = CredentialManager(
            provider: .codex,
            loader: { await disk.load() },
            saver: { credential in await disk.save(credential) },
            refresher: refresher,
            refreshLock: lock)
        let managerB = CredentialManager(
            provider: .codex,
            loader: { await disk.load() },
            saver: { credential in await disk.save(credential) },
            refresher: refresher,
            refreshLock: lock)

        // `now` close to "real now" so the refreshed credential (which gets
        // `lastRefresh = Date()` set inside `OAuthTokenRefresher`) is fresh
        // when manager B re-checks `needsRefresh` after winning the lock.
        let now = Date()
        async let resultA = managerA.validCredential(now: now)
        async let resultB = managerB.validCredential(now: now)
        let results = try await [resultA, resultB]
        #expect(results[0].accessToken == "singleflight-access")
        #expect(results[1].accessToken == "singleflight-access")
        // Manager A wins the lock, refreshes, saves to shared disk. Manager
        // B waits for the lock, re-reads disk inside the lock, finds the
        // freshly saved credential, and adopts it without making its own
        // refresh call. So the upstream transport sees exactly one refresh.
        #expect(await transport.callCount() == 1)
        try? FileManager.default.removeItem(at: lockURL)
    }

    private func makeMockSession(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, String))
        -> URLSession
    {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, body) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Type": "application/json"])
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Shared in-memory credential "disk" for cross-manager tests. Both managers
/// in the cross-process lock test load and save through this same actor so
/// that manager B sees manager A's freshly saved credential after the lock
/// hand-off.
private actor SharedDisk {
    private var current: OAuthCredential
    init(initial: OAuthCredential) { self.current = initial }
    func load() -> OAuthCredential { current }
    func save(_ credential: OAuthCredential) { current = credential }
}

private actor CountingRefreshTransport: HTTPClientTransport {
    private var calls = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        try await Task.sleep(for: .milliseconds(50))
        let data = Data(#"{"access_token":"singleflight-access","refresh_token":"singleflight-refresh"}"#.utf8)
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        return (data, response)
    }

    func callCount() -> Int {
        calls
    }
}
