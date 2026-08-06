import XCTest
@testable import BADAN

/// What may leave the device on the account wire (ADR-0014 / D-44).
///
/// ADR-0014 reversed BADAN's no-accounts posture. It did **not** reverse
/// **"send no health data off device"**, and this file is what keeps the second Never true now that
/// the first one is gone. `FootprintPayloadTests` does the same job for methodology telemetry; the
/// account surface needs its own because it is a second, differently-shaped wire.
///
/// The method is the same as the telemetry one: encode every request type this client can produce
/// and assert the resulting JSON key set EXACTLY. Not a substring search for suspicious words — a
/// closed set, so a field added to any of these types fails here whatever it is called.
final class AccountPayloadShapeTests: XCTestCase {

    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - The closed shapes

    func testTheSignInRequestCarriesOnlyAnAppleTokenAndANonce() throws {
        let body = AccountClient.SignInRequest(identityToken: "jwt", nonce: "nonce")
        XCTAssertEqual(try keys(body), ["identityToken", "nonce"])
    }

    func testTheReferralClaimCarriesOnlyACode() throws {
        XCTAssertEqual(try keys(AccountClient.ReferralClaimRequest(code: "2F3K9WXY")), ["code"])
    }

    func testTheEntitlementPushCarriesOnlyAnEntitlementList() throws {
        let body = AccountClient.EntitlementPushRequest(entitlements: [Self.entitlement])
        XCTAssertEqual(try keys(body), ["entitlements"])
    }

    func testAnEntitlementCarriesOnlyPurchaseFacts() throws {
        // Read this list and notice what a purchase fact is: a store, a product, a date it lapses.
        // There is no metric, no reading, no score, no source and no period key — and there is no
        // field here into which one could be smuggled without this assertion failing.
        XCTAssertEqual(try keys(Self.entitlement),
                       ["platform", "productId", "isLifetime", "expiresAt", "observedAt"])
    }

    // MARK: - What must never appear

    func testNoAccountRequestBodyContainsAnythingHealthShaped() throws {
        // A second, cruder net under the exact-key assertions above, aimed at the failure mode
        // they cannot catch: a field whose NAME is innocuous carrying a value that is not. Every
        // request this client can build is encoded and searched for the vocabulary of the health
        // domain.
        let bodies: [Data] = [
            try JSONEncoder().encode(AccountClient.SignInRequest(identityToken: "jwt", nonce: "n")),
            try JSONEncoder().encode(AccountClient.ReferralClaimRequest(code: "2F3K9WXY")),
            try JSONEncoder().encode(
                AccountClient.EntitlementPushRequest(entitlements: [Self.entitlement])),
        ]
        let forbidden = ["metric", "reading", "value", "score", "readiness", "sleep", "hrv",
                         "weight", "glucose", "steps", "baseline", "confidence", "periodKey",
                         "recordedAt", "deviceId", "source", "manifest", "dose", "symptom"]
        for body in bodies {
            let json = try XCTUnwrap(String(data: body, encoding: .utf8)).lowercased()
            for term in forbidden {
                XCTAssertFalse(json.contains(term.lowercased()),
                               "an account request body mentions '\(term)': \(json)")
            }
        }
    }

    func testTheAccountIdentityHoldsNoNameOrEmail() throws {
        // The client requests no Apple scopes, so neither ever arrives — but this is the type that
        // would have to grow a field for one to be stored, and growing it is what this catches.
        let identity = AccountIdentity(accountId: "a", createdAt: .distantPast,
                                       referralCode: "2F3K9WXY")
        XCTAssertEqual(try keys(identity),
                       ["accountId", "createdAt", "referralCode", "successfulReferrals",
                        "hasClaimedReferral"])
    }

    // MARK: - The snapshot cached on disk

    func testTheCachedSnapshotRoundTripsWithoutGainingFields() throws {
        let snapshot = EntitlementSnapshot(entitlements: [Self.entitlement],
                                           referralGrantExpiresAt: Date(timeIntervalSince1970: 1),
                                           successfulReferrals: 2,
                                           syncedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try keys(snapshot),
                       ["entitlements", "referralGrantExpiresAt", "successfulReferrals", "syncedAt"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(EntitlementSnapshot.self,
                                          from: encoder.encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }

    private static let entitlement = SyncedEntitlement(
        platform: .ios, productId: "net.binjamshid.badan.pro.yearly", isLifetime: false,
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        observedAt: Date(timeIntervalSince1970: 1_770_000_000))
}
