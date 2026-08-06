import XCTest
@testable import BADAN

/// `AccountController`'s one promise (ADR-0014 / D-44): **a failure here never reduces what the
/// user can do.**
///
/// Every test below is a way the account surface can break — the service is down, the session was
/// revoked, the sheet was cancelled, the response was nonsense — and every one asserts the same
/// thing: the cached snapshot is still there and still granting. That is the property that makes
/// reversing the no-backend posture survivable, so it is tested from the failure side rather than
/// the happy path.
@MainActor
final class AccountControllerTests: XCTestCase {

    // MARK: - Doubles

    private final class FakeTransport: AccountTransporting, @unchecked Sendable {
        var status = 200
        var body = Data()
        var error: Error?
        private(set) var sentPaths: [String] = []
        private(set) var sentMethods: [String] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sentPaths.append(request.url?.path ?? "")
            sentMethods.append(request.httpMethod ?? "")
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private struct FakeSignIn: AppleSignInProviding {
        let result: Result<AppleSignInResult, Error>
        func signIn() async throws -> AppleSignInResult { try result.get() }
    }

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func responseJSON(referralCode: String = "2F3K9WXY",
                              withToken: Bool = true,
                              claimed: Bool = false,
                              referrals: Int = 0) -> Data {
        let token = withToken ? "\"accountToken\":\"session-token\"," : ""
        return Data("""
        {\(token)
         "accountId":"acc-1",
         "createdAt":"2026-08-01T00:00:00Z",
         "referralCode":"\(referralCode)",
         "successfulReferrals":\(referrals),
         "hasClaimedReferral":\(claimed),
         "referralGrantExpiresAt":null,
         "entitlements":[{"platform":"android","productId":"badan_pro","isLifetime":false,
                          "expiresAt":"2027-01-01T00:00:00Z",
                          "observedAt":"2026-08-01T00:00:00Z"}]}
        """.utf8)
    }

    private func makeController(transport: FakeTransport,
                                signIn: Result<AppleSignInResult, Error> = .success(
                                    AppleSignInResult(identityToken: "jwt", nonce: "nonce")),
                                session: AccountSessionStoring = InMemoryAccountSessionStore(),
                                cache: AccountCacheStoring = InMemoryAccountCacheStore())
        -> AccountController {
        AccountController(
            client: AccountClient(transport: transport, session: session,
                                  baseURL: URL(string: "https://example.invalid")!),
            signInProvider: FakeSignIn(result: signIn),
            cache: cache, session: session, clock: FixedClock(now))
    }

    /// A signed-in install with a live Android subscription already cached.
    private func signedInFixtures() -> (AccountSessionStoring, AccountCacheStoring) {
        let session = InMemoryAccountSessionStore("existing-token")
        let cache = InMemoryAccountCacheStore(
            identity: AccountIdentity(accountId: "acc-1", createdAt: now,
                                      referralCode: "2F3K9WXY"),
            snapshot: EntitlementSnapshot(
                entitlements: [SyncedEntitlement(platform: .android, productId: "badan_pro",
                                                 isLifetime: false,
                                                 expiresAt: now.addingTimeInterval(400 * 86_400),
                                                 observedAt: now)],
                syncedAt: now))
        return (session, cache)
    }

    // MARK: - Sign in

    func testASuccessfulSignInStoresTheSessionAndTheSnapshot() async {
        let transport = FakeTransport()
        transport.body = responseJSON()
        let session = InMemoryAccountSessionStore()
        let cache = InMemoryAccountCacheStore()
        let controller = makeController(transport: transport, session: session, cache: cache)

        let ok = await controller.signIn()

        XCTAssertTrue(ok)
        XCTAssertEqual(session.token(), "session-token")
        XCTAssertEqual(controller.state.identity?.accountId, "acc-1")
        XCTAssertEqual(cache.identity()?.referralCode, "2F3K9WXY")
        XCTAssertEqual(controller.snapshot?.entitlements.count, 1)
    }

    func testTheSnapshotIsStampedWithTheClientsOwnClock() async {
        // Never the server's. `EntitlementSnapshot.syncedAt` bounds the offline grace window, and a
        // server-supplied value would let the server extend the very thing that bounds it.
        let transport = FakeTransport()
        transport.body = responseJSON()
        let controller = makeController(transport: transport)
        await controller.signIn()
        XCTAssertEqual(controller.snapshot?.syncedAt, now)
    }

    func testACancelledSheetIsNotAnError() async {
        let transport = FakeTransport()
        let controller = makeController(transport: transport,
                                        signIn: .failure(AppleSignInError.cancelled))

        let ok = await controller.signIn()

        XCTAssertFalse(ok)
        XCTAssertNil(controller.lastError, "closing a sheet is not a failure to report")
        XCTAssertTrue(transport.sentPaths.isEmpty, "a cancelled sheet must not hit the network")
    }

    func testAMalformedResponseDoesNotSignTheUserIn() async {
        let transport = FakeTransport()
        transport.body = Data("{\"unexpected\":true}".utf8)
        let session = InMemoryAccountSessionStore()
        let controller = makeController(transport: transport, session: session)

        let ok = await controller.signIn()
        XCTAssertFalse(ok)
        XCTAssertNil(session.token())
        XCTAssertFalse(controller.state.isSignedIn)
    }

    // MARK: - Failure never revokes

    func testAFailedRefreshLeavesTheCachedSnapshotIntact() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.error = URLError(.notConnectedToInternet)
        let controller = makeController(transport: transport, session: session, cache: cache)

        let before = controller.snapshot
        let ok = await controller.refresh()

        XCTAssertFalse(ok)
        XCTAssertEqual(controller.snapshot, before)
        XCTAssertTrue(controller.state.isSignedIn)
        XCTAssertTrue(EntitlementMerge.grantsAccess(localEntitlement: false,
                                                    snapshot: controller.snapshot, now: now),
                      "an unreachable service must not cost a paying user their access")
    }

    func testAServerErrorLeavesTheCachedSnapshotIntact() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.status = 500
        let controller = makeController(transport: transport, session: session, cache: cache)

        let before = controller.snapshot
        await controller.refresh()

        XCTAssertEqual(controller.snapshot, before)
        XCTAssertTrue(controller.state.isSignedIn)
    }

    func testARejectedSessionSignsOutLocallyAndOnlyThen() async {
        // 401 is the one terminal case: the account was deleted or the token revoked, and no retry
        // can succeed. Distinguished from every other failure precisely so the others do not
        // trigger this.
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.status = 401
        let controller = makeController(transport: transport, session: session, cache: cache)

        await controller.refresh()

        XCTAssertFalse(controller.state.isSignedIn)
        XCTAssertNil(session.token())
        XCTAssertNil(controller.snapshot)
    }

    // MARK: - Sign out and delete

    func testSigningOutClearsTheSnapshotBecauseThatIsWhatWasAsked() async {
        let (session, cache) = signedInFixtures()
        let controller = makeController(transport: FakeTransport(), session: session, cache: cache)

        controller.signOut()

        XCTAssertNil(session.token())
        XCTAssertNil(cache.identity())
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.state.isSignedIn)
    }

    func testAFailedDeletionLeavesTheUserSignedInRatherThanLyingAboutIt() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.status = 500
        let controller = makeController(transport: transport, session: session, cache: cache)

        let ok = await controller.deleteAccount()

        XCTAssertFalse(ok)
        XCTAssertTrue(controller.state.isSignedIn, "a server failure must not report a deletion")
        XCTAssertNotNil(session.token())
    }

    func testAnAlreadyDeletedAccountStillClearsLocally() async {
        // 401 on delete means it is already gone server-side. The end state the user asked for is
        // the end state they get.
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.status = 401
        let controller = makeController(transport: transport, session: session, cache: cache)

        let deleted = await controller.deleteAccount()
        XCTAssertTrue(deleted)
        XCTAssertFalse(controller.state.isSignedIn)
        XCTAssertNil(session.token())
    }

    // MARK: - Restore from cache

    func testACacheWithoutAKeychainTokenReportsSignedOut() {
        // A restore from a backup that excluded the Keychain looks exactly like this. Reporting
        // signed-in would show an account no request could act on.
        let (_, cache) = signedInFixtures()
        let controller = makeController(transport: FakeTransport(),
                                        session: InMemoryAccountSessionStore(), cache: cache)

        XCTAssertFalse(controller.state.isSignedIn)
        XCTAssertNotNil(controller.snapshot,
                        "the snapshot is kept: a still-paying user must not lose access before "
                            + "they get a chance to sign in again")
    }

    // MARK: - Entitlement push

    func testAnEmptyPushUsesTheDeleteRouteWithAnExplicitPlatform() async {
        // The server cannot guess which platform an empty body refers to, and a wrong guess would
        // revoke the other platform's entitlement — the exact failure this feature exists to
        // prevent.
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.body = responseJSON(withToken: false)
        let controller = makeController(transport: transport, session: session, cache: cache)

        await controller.pushLocalEntitlement([])

        XCTAssertEqual(transport.sentMethods, ["DELETE"])
        XCTAssertEqual(transport.sentPaths, ["/v1/account/entitlement/ios"])
    }

    func testANonEmptyPushUsesThePutRoute() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.body = responseJSON(withToken: false)
        let controller = makeController(transport: transport, session: session, cache: cache)

        await controller.pushLocalEntitlement([
            SyncedEntitlement(platform: .ios, productId: "net.binjamshid.badan.pro.yearly",
                              isLifetime: false, expiresAt: now, observedAt: now)])

        XCTAssertEqual(transport.sentMethods, ["PUT"])
        XCTAssertEqual(transport.sentPaths, ["/v1/account/entitlement"])
    }

    func testASignedOutInstallNeverPushesAnything() async {
        let transport = FakeTransport()
        let controller = makeController(transport: transport)

        await controller.pushLocalEntitlement([])
        await controller.refresh()

        XCTAssertTrue(transport.sentPaths.isEmpty)
    }

    // MARK: - Referrals

    func testAnObviouslyBadCodeIsRefusedWithoutARoundTrip() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        let controller = makeController(transport: transport, session: session, cache: cache)

        let refusal = await controller.claimReferral("2F3K9WXY")

        XCTAssertEqual(refusal, .ownCode)
        XCTAssertTrue(transport.sentPaths.isEmpty)
    }

    func testAServerRefusalIsMappedOntoTheLocalVocabulary() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.status = 409
        transport.body = Data("{\"reason\":\"already_claimed\"}".utf8)
        let controller = makeController(transport: transport, session: session, cache: cache)

        let refusal = await controller.claimReferral("MNPQRSTW")
        XCTAssertEqual(refusal, .alreadyClaimed)
    }

    func testAnUnrecognisedServerReasonFallsBackRatherThanCrashing() async {
        // The server is allowed to be newer than the app.
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.status = 409
        transport.body = Data("{\"reason\":\"some_future_rule\"}".utf8)
        let controller = makeController(transport: transport, session: session, cache: cache)

        let refusal = await controller.claimReferral("MNPQRSTW")
        XCTAssertEqual(refusal, .malformedCode)
    }

    func testASuccessfulClaimAdoptsTheServersAccountState() async {
        let (session, cache) = signedInFixtures()
        let transport = FakeTransport()
        transport.body = responseJSON(withToken: false, claimed: true, referrals: 3)
        let controller = makeController(transport: transport, session: session, cache: cache)

        let refusal = await controller.claimReferral("MNPQRSTW")
        XCTAssertNil(refusal)
        XCTAssertEqual(controller.state.identity?.hasClaimedReferral, true)
        XCTAssertEqual(controller.state.identity?.successfulReferrals, 3)
    }
}
