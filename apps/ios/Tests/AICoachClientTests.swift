import XCTest
@testable import BADAN

/// A9 / ADR-0010 / D-22 — `AICoachClient`'s request/response handling, exercised entirely against
/// a stub transport (`MockAICoachTransport`) so no test here ever touches a real socket, matching
/// the client task's own instruction ("mock the network layer — do not make real network calls in
/// tests").
final class AICoachClientTests: XCTestCase {

    // MARK: - register()

    func testRegisterStoresTheReturnedTokenAndPostsToTheRegisterEndpoint() async throws {
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["token": "fresh-token-abc"]),
        ])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        let token = try await client.register()

        XCTAssertEqual(token, "fresh-token-abc")
        XCTAssertEqual(tokenStore.token(), "fresh-token-abc")
        XCTAssertEqual(transport.captured.count, 1)
        XCTAssertEqual(transport.captured[0].url?.absoluteString, "https://coach.test/v1/register")
        XCTAssertEqual(transport.captured[0].httpMethod, "POST")
        XCTAssertNil(transport.captured[0].value(forHTTPHeaderField: "Authorization"),
                    "registration itself carries no bearer token — there isn't one yet")
    }

    func testRegisterDoesNotStoreAnythingOnServerError() async throws {
        let transport = MockAICoachTransport(responses: [.success(status: 500, json: [:])])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected register() to throw on a 500")
        } catch AICoachError.serverError(let status) {
            XCTAssertEqual(status, 500)
        }
        XCTAssertNil(tokenStore.token(), "a failed registration must never leave a token stored")
    }

    func testRegisterThrowsDecodingErrorOnMalformedBody() async throws {
        let transport = MockAICoachTransport(responses: [.raw(status: 200, data: Data("not json".utf8))])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected register() to throw on a malformed body")
        } catch AICoachError.decodingError {
            // expected
        }
        XCTAssertNil(tokenStore.token())
    }

    // MARK: - sendChat()

    func testSendChatThrowsNotEnabledAndNeverTouchesTheNetworkWithNoStoredToken() async throws {
        let transport = MockAICoachTransport(responses: [])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.sendChat(messages: [AICoachMessage(role: .user, content: "hi")])
            XCTFail("expected .notEnabled")
        } catch AICoachError.notEnabled {
            // expected
        }
        XCTAssertEqual(transport.captured.count, 0, "no request should ever be built with no token")
    }

    func testSendChatSendsBearerTokenAndMessagesAndReturnsTheReply() async throws {
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["reply": "Your readiness looks steady today."]),
        ])
        let tokenStore = InMemoryAICoachDeviceTokenStore("stored-token-xyz")
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        let messages = [
            AICoachMessage(role: .system, content: "context here"),
            AICoachMessage(role: .user, content: "how am I doing?"),
        ]
        let reply = try await client.sendChat(messages: messages)

        XCTAssertEqual(reply, "Your readiness looks steady today.")
        XCTAssertEqual(transport.captured.count, 1)
        let request = transport.captured[0]
        XCTAssertEqual(request.url?.absoluteString, "https://coach.test/v1/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stored-token-xyz")

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode([String: [AICoachMessage]].self, from: body)
        XCTAssertEqual(decoded["messages"], messages)
    }

    func testSendChatMapsA429ToServerErrorWithTheStatusPreserved() async throws {
        let transport = MockAICoachTransport(responses: [.success(status: 429, json: ["detail": "rate limit exceeded"])])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore("t"),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.sendChat(messages: [AICoachMessage(role: .user, content: "hi")])
            XCTFail("expected .serverError(429)")
        } catch AICoachError.serverError(let status) {
            XCTAssertEqual(status, 429)
        }
    }

    func testSendChatMapsA401ToServerErrorRatherThanCrashing() async throws {
        let transport = MockAICoachTransport(responses: [.success(status: 401, json: ["detail": "unauthorized"])])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore("stale-token"),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.sendChat(messages: [AICoachMessage(role: .user, content: "hi")])
            XCTFail("expected .serverError(401)")
        } catch AICoachError.serverError(let status) {
            XCTAssertEqual(status, 401)
        }
    }

    func testSendChatWrapsATransportFailureAsTransportError() async throws {
        let transport = MockAICoachTransport(responses: [.throwing])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore("t"),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.sendChat(messages: [AICoachMessage(role: .user, content: "hi")])
            XCTFail("expected .transportError")
        } catch AICoachError.transportError {
            // expected
        }
    }

    // MARK: - isEnabled / disable()

    func testIsEnabledReflectsTokenPresenceOnly() {
        let empty = AICoachClient(transport: MockAICoachTransport(responses: []),
                                  tokenStore: InMemoryAICoachDeviceTokenStore(),
                                  baseURL: URL(string: "https://coach.test")!)
        XCTAssertFalse(empty.isEnabled)

        let populated = AICoachClient(transport: MockAICoachTransport(responses: []),
                                      tokenStore: InMemoryAICoachDeviceTokenStore("t"),
                                      baseURL: URL(string: "https://coach.test")!)
        XCTAssertTrue(populated.isEnabled)
    }

    func testDisableDeletesTheTokenSoTheClientImmediatelyReturnsToNotEnabled() async throws {
        let tokenStore = InMemoryAICoachDeviceTokenStore("t")
        let client = AICoachClient(transport: MockAICoachTransport(responses: [
            .success(status: 200, json: ["status": "revoked"]),
        ]), tokenStore: tokenStore, baseURL: URL(string: "https://coach.test")!)
        XCTAssertTrue(client.isEnabled)

        // The local delete (and everything `isEnabled`/`sendChat` depend on) is synchronous —
        // it must not wait on the fire-and-forget server revoke call below.
        let revokeTask = client.disable()

        XCTAssertFalse(client.isEnabled)
        XCTAssertNil(tokenStore.token())
        do {
            _ = try await client.sendChat(messages: [AICoachMessage(role: .user, content: "hi")])
            XCTFail("expected .notEnabled after disable()")
        } catch AICoachError.notEnabled {
            // expected — no silent re-enable, no stale credential still working
        }
        await revokeTask.value
    }

    // MARK: - disable() server-side revoke (independent audit finding, 2026-07-23: previously
    // disable() only ever forgot the local Keychain credential — a token exfiltrated from the
    // device before disabling kept authenticating /v1/chat forever, since nothing told the server
    // that token should stop working).

    func testDisableSendsABestEffortRevokeRequestWithTheJustDeletedTokenAsBearerAuth() async throws {
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["status": "revoked"]),
        ])
        let tokenStore = InMemoryAICoachDeviceTokenStore("captured-before-disable")
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        await client.disable().value

        XCTAssertNil(tokenStore.token(), "the local Keychain copy is still deleted, same as before")
        XCTAssertEqual(transport.captured.count, 1)
        XCTAssertEqual(transport.captured[0].url?.absoluteString, "https://coach.test/v1/revoke")
        XCTAssertEqual(transport.captured[0].httpMethod, "POST")
        XCTAssertEqual(transport.captured[0].value(forHTTPHeaderField: "Authorization"),
                       "Bearer captured-before-disable",
                       "the server needs the token itself to know which one to revoke")
    }

    func testDisableWithNoStoredTokenNeverTouchesTheNetwork() async throws {
        let transport = MockAICoachTransport(responses: [])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        await client.disable().value

        XCTAssertEqual(transport.captured.count, 0, "nothing to revoke when there was never a token")
    }

    func testDisableSwallowsARevokeTransportFailureRatherThanThrowing() async throws {
        // `disable()` returns `Task<Void, Never>` precisely so a dropped/offline revoke call has
        // nowhere to surface as a thrown error — the local state is already correct by the time
        // this task even starts.
        let transport = MockAICoachTransport(responses: [.throwing])
        let tokenStore = InMemoryAICoachDeviceTokenStore("t")
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        await client.disable().value

        XCTAssertNil(tokenStore.token())
    }
}

// MARK: - Test doubles

/// A canned, ordered response queue — one entry consumed per `send(_:)` call, so a test can pin
/// exactly what each request in a sequence gets back. Also records every `URLRequest` it was
/// asked to send, so tests can assert on method/URL/headers/body without ever opening a socket.
final class MockAICoachTransport: AICoachTransporting {
    enum Response {
        case success(status: Int, json: [String: Any])
        case raw(status: Int, data: Data)
        case throwing
    }

    private var responses: [Response]
    private(set) var captured: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else {
            throw AICoachError.transportError
        }
        let response = responses.removeFirst()
        switch response {
        case .success(let status, let json):
            let data = try JSONSerialization.data(withJSONObject: json)
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, http)
        case .raw(let status, let data):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, http)
        case .throwing:
            throw URLError(.notConnectedToInternet)
        }
    }
}
