import CryptoKit
import DeviceCheck
import XCTest
@testable import BADAN

/// A9 / ADR-0010 / D-22 — `AICoachClient`'s request/response handling, exercised entirely against
/// a stub transport (`MockAICoachTransport`) so no test here ever touches a real socket, matching
/// the client task's own instruction ("mock the network layer — do not make real network calls in
/// tests").
final class AICoachClientTests: XCTestCase {

    // MARK: - register()
    //
    // Registration is App Attest-gated (2026-07-28): challenge → attest → /v2/register. The
    // server will not mint a token without a verifying attestation, so these tests always
    // supply a `MockAICoachAttestor` — the real `DCAppAttestService` reports unsupported on
    // the simulator, which is exactly why the seam exists.

    /// A real `DCError` of a given code — the errors `DCAppAttestService` itself throws, which is
    /// what `register()` classifies. Built from `DCErrorDomain` rather than faked with a
    /// look-alike, so these tests fail if the classification ever stops recognising the real
    /// thing.
    private func dcError(_ code: DCError.Code) -> DCError {
        DCError(_nsError: NSError(domain: DCErrorDomain, code: code.rawValue, userInfo: nil))
    }

    /// The canned two-response sequence a successful registration consumes.
    private func registerResponses(token: String = "fresh-token-abc",
                                   challenge: String = "Y2hhbGxlbmdlLWJ5dGVz") -> [MockAICoachTransport.Response] {
        [
            .success(status: 200, json: ["challenge": challenge]),
            .success(status: 200, json: ["token": token]),
        ]
    }

    func testRegisterAttestsAgainstAServerChallengeAndPostsToTheAttestedEndpoint() async throws {
        let transport = MockAICoachTransport(responses: registerResponses())
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let attestor = MockAICoachAttestor(keyId: "a2V5LWlkLWJ5dGVz")
        let client = AICoachClient(transport: transport, tokenStore: tokenStore, attestor: attestor,
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        let token = try await client.register()

        XCTAssertEqual(token, "fresh-token-abc")
        XCTAssertEqual(tokenStore.token(), "fresh-token-abc")
        XCTAssertEqual(transport.captured.count, 2)
        XCTAssertEqual(transport.captured[0].url?.absoluteString, "https://coach.test/v1/attest/challenge")
        XCTAssertEqual(transport.captured[1].url?.absoluteString, "https://coach.test/v2/register")
        XCTAssertNil(transport.captured[1].value(forHTTPHeaderField: "Authorization"),
                    "registration itself carries no bearer token — there isn't one yet")

        let body = try XCTUnwrap(transport.captured[1].httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded["key_id"], "a2V5LWlkLWJ5dGVz",
                       "DeviceCheck's key id is already base64 — it goes through unchanged")
        XCTAssertEqual(decoded["challenge"], "Y2hhbGxlbmdlLWJ5dGVz",
                       "the challenge must return in exactly the form the server issued it")
        XCTAssertEqual(decoded["attestation"], attestor.stubAttestation.base64EncodedString())
    }

    func testRegisterHashesTheChallengeTheSameWayTheServerDoes() async throws {
        // The server computes `clientDataHash = SHA256(challenge)` and expects that hash inside
        // the attestation nonce. If this ever drifts, every attestation is rejected server-side
        // with no clue why, so pin it here rather than discovering it on a device.
        let challengeBase64 = "Y2hhbGxlbmdlLWJ5dGVz"
        let transport = MockAICoachTransport(responses: registerResponses(challenge: challengeBase64))
        let attestor = MockAICoachAttestor(keyId: "k")
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: attestor, attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        _ = try await client.register()

        let rawChallenge = try XCTUnwrap(Data(base64Encoded: challengeBase64))
        XCTAssertEqual(attestor.capturedClientDataHash, Data(SHA256.hash(data: rawChallenge)))
    }

    func testRegisterReusesAnExistingKeyIdRatherThanGeneratingANewOne() async throws {
        // A fresh key per opt-in would make the server's per-key token budget meaningless.
        let transport = MockAICoachTransport(responses: registerResponses())
        let attestor = MockAICoachAttestor(keyId: "newly-generated")
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: attestor,
                                   attestKeyStore: InMemoryAICoachAttestKeyStore("already-known"),
                                   baseURL: URL(string: "https://coach.test")!)

        _ = try await client.register()

        XCTAssertEqual(attestor.generateKeyCallCount, 0)
        XCTAssertEqual(attestor.capturedKeyId, "already-known")
    }

    func testRegisterPersistsAFreshlyGeneratedKeyId() async throws {
        let transport = MockAICoachTransport(responses: registerResponses())
        let keyStore = InMemoryAICoachAttestKeyStore()
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "generated-once"),
                                   attestKeyStore: keyStore,
                                   baseURL: URL(string: "https://coach.test")!)

        _ = try await client.register()

        XCTAssertEqual(keyStore.keyId(), "generated-once")
    }

    func testRegisterThrowsAttestationUnavailableAndNeverTouchesTheNetworkOnAnUnsupportedDevice() async throws {
        // The simulator case. It must fail fast and distinctly — not as a server error the user
        // is invited to retry, and without burning a challenge.
        let transport = MockAICoachTransport(responses: registerResponses())
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "k", isSupported: false),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .attestationUnavailable")
        } catch AICoachError.attestationUnavailable {
            // expected
        }
        XCTAssertEqual(transport.captured.count, 0)
    }

    func testRegisterMapsAnAttestationFailureToAttestationUnavailable() async throws {
        let transport = MockAICoachTransport(responses: registerResponses())
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   attestor: MockAICoachAttestor(keyId: "k", attestThrows: true),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .attestationUnavailable")
        } catch AICoachError.attestationUnavailable {
            // expected
        }
        XCTAssertNil(tokenStore.token())
    }

    func testRegisterDoesNotPersistAKeyIdThatNeverAttested() async throws {
        // The key id used to be stored the instant `generateKey()` returned, before anything had
        // attested with it — and `disable()` deliberately never clears that store, so one failed
        // opt-in pinned a dead key id for the life of the install.
        let transport = MockAICoachTransport(responses: registerResponses())
        let keyStore = InMemoryAICoachAttestKeyStore()
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "never-attested", attestThrows: true),
                                   attestKeyStore: keyStore,
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected the attestation failure to propagate")
        } catch AICoachError.attestationUnavailable {
            // expected
        }
        XCTAssertNil(keyStore.keyId(), "a key that never attested must not be remembered")
    }

    func testRegisterFailsRetryablyWhenTheKeyIdCannotBePersistedAndNeverMintsAToken() async throws {
        // A silently failing Keychain write meant every later `register()` found no stored key
        // and generated a NEW one, each with its own server-side `MAX_TOKENS_PER_KEY` budget —
        // exactly the multi-key minting per-key budgets exist to bound. So the write result is
        // checked, and `/v2/register` is never reached: no token is spent against a key this
        // device cannot remember.
        let transport = MockAICoachTransport(responses: registerResponses())
        let keyStore = FailingAICoachAttestKeyStore()
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   attestor: MockAICoachAttestor(keyId: "unstorable"),
                                   attestKeyStore: keyStore,
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .attestationFailedTransiently")
        } catch AICoachError.attestationFailedTransiently {
            // expected — retrying is the right advice for a Keychain write
        }
        XCTAssertEqual(keyStore.storeCallCount, 1)
        XCTAssertNil(tokenStore.token())
        XCTAssertEqual(transport.captured.count, 1, "only the challenge — /v2/register is never reached")
        XCTAssertEqual(transport.captured[0].url?.absoluteString, "https://coach.test/v1/attest/challenge")
    }

    func testRegisterMapsAServerUnavailableAttestationToTheRetryableCase() async throws {
        // `DCAppAttestService.attestKey` needs a live round trip to Apple and reports a failed
        // one as `DCError.serverUnavailable`. That used to arrive at the consent screen as
        // `.attestationUnavailable` — "this device can't verify the app", with no retry offered
        // — to a user who was merely offline for a moment.
        let transport = MockAICoachTransport(responses: registerResponses())
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "k", attestError: dcError(.serverUnavailable)),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .attestationFailedTransiently")
        } catch AICoachError.attestationFailedTransiently {
            // expected
        }
    }

    func testRegisterMapsAServerUnavailableKeyGenerationToTheRetryableCase() async throws {
        let transport = MockAICoachTransport(responses: registerResponses())
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "k",
                                                                 generateKeyError: dcError(.serverUnavailable)),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .attestationFailedTransiently")
        } catch AICoachError.attestationFailedTransiently {
            // expected
        }
    }

    func testRegisterKeepsNonRetryableDeviceCheckFailuresAsAttestationUnavailable() async throws {
        // The other half of the split, and the reason it is a narrowing rather than a rename:
        // an unsupported feature fails identically on every retry, so it must NOT acquire retry
        // copy just because `serverUnavailable` did.
        let transport = MockAICoachTransport(responses: registerResponses())
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "k", attestError: dcError(.featureUnsupported)),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .attestationUnavailable")
        } catch AICoachError.attestationUnavailable {
            // expected
        }
    }

    func testRegisterSurfacesAChallengeStage429AsARateLimitTheCallerCanRecognize() async throws {
        // One opt-in attempt spends TWO of the server's 5-per-hour per-IP registration budget,
        // because `/v1/attest/challenge` and `/v2/register` share `register_rate_limiter`
        // (`backend/api/main.py`). So the 429 a user actually hits arrives at the CHALLENGE
        // stage, before any attestation — the status has to survive to the consent screen so it
        // can say "wait" rather than "check your connection".
        let transport = MockAICoachTransport(responses: [
            .success(status: 429, json: ["detail": "rate limit exceeded"]),
        ])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "k"),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .serverError(429)")
        } catch AICoachError.serverError(let status) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(transport.captured.count, 1)
    }

    func testRegisterDoesNotStoreAnythingOnServerError() async throws {
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["challenge": "Y2hhbGxlbmdl"]),
            .success(status: 500, json: [:]),
        ])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   attestor: MockAICoachAttestor(keyId: "k"),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected register() to throw on a 500")
        } catch AICoachError.serverError(let status) {
            XCTAssertEqual(status, 500)
        }
        XCTAssertNil(tokenStore.token(), "a failed registration must never leave a token stored")
    }

    func testRegisterSurfacesARejectedAttestationAsA401() async throws {
        // What a tampered build, a wrong-environment build, or a spent challenge looks like from
        // the client's side. It must stay a plain server error, not be mistaken for success.
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["challenge": "Y2hhbGxlbmdl"]),
            .success(status: 401, json: ["detail": "unauthorized"]),
        ])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   attestor: MockAICoachAttestor(keyId: "k"),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .serverError(401)")
        } catch AICoachError.serverError(let status) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertNil(tokenStore.token())
    }

    func testRegisterThrowsDecodingErrorOnMalformedBody() async throws {
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["challenge": "Y2hhbGxlbmdl"]),
            .raw(status: 200, data: Data("not json".utf8)),
        ])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   attestor: MockAICoachAttestor(keyId: "k"),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected register() to throw on a malformed body")
        } catch AICoachError.decodingError {
            // expected
        }
        XCTAssertNil(tokenStore.token())
    }

    func testRegisterThrowsDecodingErrorOnAMalformedChallenge() async throws {
        let transport = MockAICoachTransport(responses: [
            .success(status: 200, json: ["challenge": "!!! not base64 !!!"]),
        ])
        let client = AICoachClient(transport: transport, tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   attestor: MockAICoachAttestor(keyId: "k"),
                                   attestKeyStore: InMemoryAICoachAttestKeyStore(),
                                   baseURL: URL(string: "https://coach.test")!)

        do {
            _ = try await client.register()
            XCTFail("expected .decodingError")
        } catch AICoachError.decodingError {
            // expected
        }
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

/// Stands in for `DCAppAttestService`, which only works on physical hardware — without this
/// every registration test would have to be skipped on the simulator and in CI. Records what
/// it was asked to attest so tests can assert the client hashed the challenge the way the
/// server will.
final class MockAICoachAttestor: AICoachAttesting {
    let isSupported: Bool
    let stubAttestation = Data("stub-attestation-blob".utf8)

    private let stubKeyId: String
    private let attestThrows: Bool
    /// Throw a SPECIFIC error rather than the generic `attestThrows` one, so a test can pin how
    /// `register()` classifies a real `DCError` — the whole point of the retryable/non-retryable
    /// split is that those two must not land in the same case.
    private let attestError: Error?
    private let generateKeyError: Error?
    private(set) var generateKeyCallCount = 0
    private(set) var capturedKeyId: String?
    private(set) var capturedClientDataHash: Data?

    init(keyId: String, isSupported: Bool = true, attestThrows: Bool = false,
         attestError: Error? = nil, generateKeyError: Error? = nil) {
        self.stubKeyId = keyId
        self.isSupported = isSupported
        self.attestThrows = attestThrows
        self.attestError = attestError
        self.generateKeyError = generateKeyError
    }

    func generateKey() async throws -> String {
        generateKeyCallCount += 1
        if let generateKeyError { throw generateKeyError }
        return stubKeyId
    }

    // D-37. Counts up so a test can assert the counter advances per submission, which is
    // the property that makes a replayed assertion rejectable.
    let stubAssertion = Data("stub-assertion-blob".utf8)
    private(set) var assertionCallCount = 0

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertionCallCount += 1
        capturedKeyId = keyId
        capturedClientDataHash = clientDataHash
        if attestThrows { throw AICoachError.attestationUnavailable }
        return stubAssertion
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        capturedKeyId = keyId
        capturedClientDataHash = clientDataHash
        if let attestError { throw attestError }
        if attestThrows { throw AICoachError.attestationUnavailable }
        return stubAttestation
    }
}

/// An attest-key store whose Keychain write always fails — `KeychainAICoachAttestKeyStore.store`
/// returns `false` on any non-`errSecSuccess` status, and that `Bool` used to be discarded. The
/// only way to exercise that path is a double that reports the failure.
final class FailingAICoachAttestKeyStore: AICoachAttestKeyStoring {
    private(set) var storeCallCount = 0
    func keyId() -> String? { nil }
    @discardableResult
    func store(_ keyId: String) -> Bool {
        storeCallCount += 1
        return false
    }
}

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
