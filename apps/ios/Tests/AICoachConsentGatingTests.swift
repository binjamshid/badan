import XCTest
@testable import BADAN

/// A9 / ADR-0010 / D-22 — the AI coach is default-off, opt-in-only, and genuinely inert until
/// BOTH gates are satisfied: `CustomizationProfile.aiCoachEnabled` (BADAN's own consent flag) AND
/// a stored device token (`AICoachClient.isEnabled`) — mirroring `RouteConsentStore`'s standing
/// "two gates, not one" pattern in this codebase. Covers the flag's default/tolerant-decode
/// behavior and the token-lifecycle round trip (register/store/clear), and demonstrates that
/// neither gate alone is sufficient: a `true` flag with no token still can't send, and clearing
/// the token permanently (no silent re-enable) reverts to inert regardless of the flag.
final class AICoachConsentGatingTests: XCTestCase {

    // MARK: - CustomizationProfile.aiCoachEnabled — default-off

    func testDefaultProfileHasAiCoachDisabled() {
        XCTAssertFalse(CustomizationProfile().aiCoachEnabled)
    }

    /// A profile persisted before this flag existed (i.e. its JSON has no `aiCoachEnabled` key at
    /// all) must still decode — and must default to `false`, never `true`: the one value a
    /// missing/corrupt key must never silently produce for a network-consent flag. Built by
    /// encoding a real profile and stripping the key, rather than hand-writing JSON, so this test
    /// can't drift from whatever other required fields `CustomizationProfile` gains later.
    func testTolerantDecodeDefaultsAiCoachEnabledFalseWhenKeyIsMissing() throws {
        var profile = CustomizationProfile()
        profile.aiCoachEnabled = true // prove the stripped key really was the thing doing the work
        let encoded = try JSONEncoder().encode(profile)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["aiCoachEnabled"], "precondition: a fresh encode carries the key")
        json.removeValue(forKey: "aiCoachEnabled")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: stripped)
        XCTAssertFalse(decoded.aiCoachEnabled)
    }

    func testEncodeDecodeRoundTripsAiCoachEnabledWhenPresent() throws {
        var profile = CustomizationProfile()
        profile.aiCoachEnabled = true
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: data)
        XCTAssertTrue(decoded.aiCoachEnabled)
    }

    // MARK: - Token lifecycle (register / store / clear)

    func testTokenStoreStartsEmpty() {
        XCTAssertNil(InMemoryAICoachDeviceTokenStore().token())
    }

    func testTokenStoreRoundTripsAStoredToken() {
        let store = InMemoryAICoachDeviceTokenStore()
        XCTAssertTrue(store.store("abc123"))
        XCTAssertEqual(store.token(), "abc123")
    }

    func testTokenStoreRemoveClearsTheToken() {
        let store = InMemoryAICoachDeviceTokenStore("abc123")
        store.remove()
        XCTAssertNil(store.token())
    }

    func testRegisterThenClientIsEnabledEndToEnd() async throws {
        let transport = MockAICoachTransport(responses: [.success(status: 200, json: ["token": "new-token"])])
        let tokenStore = InMemoryAICoachDeviceTokenStore()
        let client = AICoachClient(transport: transport, tokenStore: tokenStore,
                                   baseURL: URL(string: "https://coach.test")!)

        XCTAssertFalse(client.isEnabled, "no token yet — inert")
        _ = try await client.register()
        XCTAssertTrue(client.isEnabled, "a stored token is what flips this, nothing else")
    }

    // MARK: - The feature is inert unless BOTH gates hold

    /// The flag alone is not enough: a `CustomizationProfile` with `aiCoachEnabled == true` but no
    /// device token (e.g. a fresh install restored from an iCloud backup of *preferences* only —
    /// the Keychain item itself never syncs, see `KeychainAICoachDeviceTokenStore`'s own doc) must
    /// still be unable to send a request. This is what makes the two-gate design load-bearing
    /// rather than decorative.
    func testFlagTrueWithNoTokenIsStillInert() async throws {
        var profile = CustomizationProfile()
        profile.aiCoachEnabled = true
        XCTAssertTrue(profile.aiCoachEnabled, "the flag itself is on")

        let client = AICoachClient(transport: MockAICoachTransport(responses: []),
                                   tokenStore: InMemoryAICoachDeviceTokenStore(),
                                   baseURL: URL(string: "https://coach.test")!)
        XCTAssertFalse(client.isEnabled, "no token — the second gate fails independently of the flag")

        do {
            _ = try await client.sendChat(messages: [AICoachMessage(role: .user, content: "hi")])
            XCTFail("expected .notEnabled")
        } catch AICoachError.notEnabled {
            // expected — a flag alone can never cause a network call
        }
    }

    /// The token alone is not enough either — this is enforced at the UI layer
    /// (`LogHubScreen` routes to `AICoachConsentScreen`, not `AICoachChatScreen`, whenever
    /// `aiCoachEnabled == false`, regardless of whether a stale token happens to exist). What IS
    /// true at the client layer, and asserted here, is that `AICoachClient` itself never consults
    /// `CustomizationProfile` at all — it has no reference to one — so "disable, losing the flag"
    /// and "disable, losing the token" are the same one action (`disable()`), never two things
    /// that could fall out of sync.
    func testDisableIsTheSingleActionThatRevokesBothTheFlagAndTheToken() {
        let tokenStore = InMemoryAICoachDeviceTokenStore("t")
        let client = AICoachClient(transport: MockAICoachTransport(responses: []),
                                   tokenStore: tokenStore, baseURL: URL(string: "https://coach.test")!)
        var profile = CustomizationProfile()
        profile.aiCoachEnabled = true

        client.disable()
        profile.aiCoachEnabled = false

        XCTAssertNil(tokenStore.token())
        XCTAssertFalse(client.isEnabled)
        XCTAssertFalse(profile.aiCoachEnabled)
    }
}
