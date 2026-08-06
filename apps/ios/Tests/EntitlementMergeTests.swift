import XCTest
@testable import BADAN

/// How a local store entitlement and a synced cross-platform one combine (ADR-0014 / D-44).
///
/// The load-bearing test in this file is `testARemoteThatSaysNothingCanNeverRevokeALocalPurchase`.
/// D-44 introduced a server that can influence entitlement, and the single rule protecting a paying
/// user from every bug, outage and bad deploy in that server is that the remote may grant and never
/// revoke. Everything else here is a boundary; that one is the invariant.
final class EntitlementMergeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

    private func entitlement(_ platform: SyncedEntitlement.Platform = .android,
                             lifetime: Bool = false,
                             expiresIn: Double? = 30) -> SyncedEntitlement {
        .init(platform: platform, productId: "badan_pro", isLifetime: lifetime,
              expiresAt: lifetime ? nil : expiresIn.map { days($0) }, observedAt: now)
    }

    private func snapshot(_ entitlements: [SyncedEntitlement] = [],
                          referralExpiresIn: Double? = nil,
                          syncedDaysAgo: Double = 0) -> EntitlementSnapshot {
        .init(entitlements: entitlements,
              referralGrantExpiresAt: referralExpiresIn.map { days($0) },
              syncedAt: days(-syncedDaysAgo))
    }

    // MARK: - The invariant

    func testARemoteThatSaysNothingCanNeverRevokeALocalPurchase() {
        // Every shape of "the account is useless or hostile" the server could produce.
        let hostile: [EntitlementSnapshot?] = [
            nil,
            snapshot(),
            snapshot(syncedDaysAgo: 3650),
            snapshot([entitlement(expiresIn: -400)]),
        ]
        for snapshot in hostile {
            XCTAssertEqual(
                EntitlementMerge.resolve(localEntitlement: true, snapshot: snapshot, now: now),
                .localStore,
                "a local purchase must survive anything the account says")
        }
    }

    func testTheLocalStoreIsReportedEvenWhenTheAccountAlsoHasOne() {
        // Not a tie-break for its own sake: the user needs to be told where the subscription they
        // can actually cancel lives, and that is the local one.
        let source = EntitlementMerge.resolve(
            localEntitlement: true, snapshot: snapshot([entitlement(.android)]), now: now)
        XCTAssertEqual(source, .localStore)
    }

    // MARK: - Granting from the account

    func testALiveEntitlementOnAnotherPlatformGrantsAccess() {
        let source = EntitlementMerge.resolve(
            localEntitlement: false, snapshot: snapshot([entitlement(.android)]), now: now)
        XCTAssertEqual(source, .synced(.android))
        XCTAssertTrue(source.grantsAccess)
    }

    func testALifetimePurchaseNeverExpires() {
        let far = now.addingTimeInterval(100 * 365 * 86_400)
        let source = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: .init(entitlements: [entitlement(.ios, lifetime: true)], syncedAt: far),
            now: far)
        XCTAssertEqual(source, .synced(.ios))
    }

    func testAnExpiredRemoteEntitlementDoesNotGrant() {
        let source = EntitlementMerge.resolve(
            localEntitlement: false, snapshot: snapshot([entitlement(expiresIn: -1)]), now: now)
        XCTAssertEqual(source, .none)
    }

    func testTheLongestRunningEntitlementIsTheOneReported() {
        let source = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: snapshot([entitlement(.android, expiresIn: 5),
                                entitlement(.ios, expiresIn: 400)]),
            now: now)
        XCTAssertEqual(source, .synced(.ios))
    }

    func testALifetimeBeatsALongerDatedSubscription() {
        let source = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: snapshot([entitlement(.ios, expiresIn: 3650),
                                entitlement(.android, lifetime: true)]),
            now: now)
        XCTAssertEqual(source, .synced(.android))
    }

    // MARK: - Staleness

    func testASnapshotGoesStaleAfterTheGraceWindow() {
        let inside = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: snapshot([entitlement(expiresIn: 400)],
                               syncedDaysAgo: Double(EntitlementMerge.offlineGraceDays) - 1),
            now: now)
        XCTAssertTrue(inside.grantsAccess)

        let outside = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: snapshot([entitlement(expiresIn: 400)],
                               syncedDaysAgo: Double(EntitlementMerge.offlineGraceDays) + 1),
            now: now)
        XCTAssertEqual(outside, .syncedButStale(.android))
        XCTAssertFalse(outside.grantsAccess)
        // Distinct from `.none` so the paywall leads with "reconnect" rather than a price.
        XCTAssertTrue(outside.isStale)
    }

    func testStalenessNeverAppliesToALocalPurchase() {
        // The plane case `SubscriptionPolicy` was written for. A user who bought on THIS device is
        // unaffected by the grace window existing at all, no matter how long they stay offline.
        let source = EntitlementMerge.resolve(
            localEntitlement: true,
            snapshot: snapshot([entitlement()], syncedDaysAgo: 9_999),
            now: now)
        XCTAssertEqual(source, .localStore)
    }

    func testAClockThatMovedBackwardsIsTreatedAsJustSynced() {
        // A `syncedAt` in the future means travel, a manual change, or a restore — not fraud, and
        // not something a user can resolve from a locked app.
        let source = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: snapshot([entitlement(expiresIn: 400)], syncedDaysAgo: -90),
            now: now)
        XCTAssertEqual(source, .synced(.android))
    }

    // MARK: - Referral grants

    func testALiveReferralGrantGrantsAccess() {
        let source = EntitlementMerge.resolve(
            localEntitlement: false, snapshot: snapshot(referralExpiresIn: 10), now: now)
        XCTAssertEqual(source, .referralGrant)
        XCTAssertTrue(source.grantsAccess)
    }

    func testAnExpiredReferralGrantDoesNot() {
        let source = EntitlementMerge.resolve(
            localEntitlement: false, snapshot: snapshot(referralExpiresIn: -1), now: now)
        XCTAssertEqual(source, .none)
    }

    func testAPurchaseIsReportedAheadOfAReferralGrant() {
        // Even when the grant runs longer. The purchase is the thing that bills the user and the
        // thing they can cancel, so it is the thing they need told about.
        let source = EntitlementMerge.resolve(
            localEntitlement: false,
            snapshot: snapshot([entitlement(.ios, expiresIn: 5)], referralExpiresIn: 500),
            now: now)
        XCTAssertEqual(source, .synced(.ios))
    }

    // MARK: - Through SubscriptionPolicy

    func testAnAccountEntitlementUnlocksTheAppThroughTheRealPolicy() {
        // The merge is only worth anything if `SubscriptionPolicy` actually consults it. A trial
        // that expired months ago, no local purchase, and a live Android subscription.
        let state = SubscriptionPolicy.State(
            firstLaunch: days(-365), hasActiveEntitlement: false, storeReachable: true,
            syncedSnapshot: snapshot([entitlement(.android)]))
        XCTAssertEqual(SubscriptionPolicy.access(state, now: now), .subscribed)
        XCTAssertNil(SubscriptionPolicy.exportWindowDays(state, now: now))
    }

    func testASignedOutInstallBehavesExactlyAsItDidBeforeAccountsExisted() {
        // `syncedSnapshot` defaults to nil, and a nil snapshot cannot change any answer. This is
        // what lets every call site written before D-44 keep meaning what it meant.
        let expired = SubscriptionPolicy.State(
            firstLaunch: days(-365), hasActiveEntitlement: false, storeReachable: true)
        XCTAssertEqual(SubscriptionPolicy.access(expired, now: now), .trialExpired)
        XCTAssertEqual(SubscriptionPolicy.exportWindowDays(expired, now: now),
                       SubscriptionPolicy.freeExportDays)
    }
}
