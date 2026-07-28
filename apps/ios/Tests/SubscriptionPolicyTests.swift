import XCTest
@testable import BADAN

/// The entitlement rule. Two things here would fail silently in production if they broke: the trial
/// boundary (off by one day either way is invisible until someone complains) and the offline rule
/// (locking a paying user out on a plane looks exactly like a bug in something else).
final class SubscriptionPolicyTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_770_000_000)
    private func days(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

    private func state(firstLaunch: Date? = nil, entitled: Bool = false,
                       reachable: Bool = true) -> SubscriptionPolicy.State {
        .init(firstLaunch: firstLaunch, hasActiveEntitlement: entitled, storeReachable: reachable)
    }

    // MARK: - Trial boundary

    func testTrialRunsForExactlySevenDays() {
        XCTAssertEqual(SubscriptionPolicy.access(state(firstLaunch: start), now: start),
                       .trial(daysRemaining: 7))
        XCTAssertEqual(SubscriptionPolicy.access(state(firstLaunch: start), now: days(6.99)),
                       .trial(daysRemaining: 1))
        XCTAssertEqual(SubscriptionPolicy.access(state(firstLaunch: start), now: days(7)),
                       .trialExpired)
        XCTAssertEqual(SubscriptionPolicy.access(state(firstLaunch: start), now: days(30)),
                       .trialExpired)
    }

    func testTrialIsUnlockedAndExpiryIsNot() {
        XCTAssertTrue(SubscriptionPolicy.access(state(firstLaunch: start), now: days(3)).isUnlocked)
        XCTAssertFalse(SubscriptionPolicy.access(state(firstLaunch: start), now: days(8)).isUnlocked)
    }

    /// A first-launch date in the future means the clock moved backwards — travel, a manual change,
    /// a restore. Generous (a fresh trial) but bounded, never an unlimited one.
    func testAClockMovedBackwardsDoesNotGrantAnInfiniteTrial() {
        let access = SubscriptionPolicy.access(state(firstLaunch: days(10)), now: start)
        XCTAssertEqual(access, .trial(daysRemaining: SubscriptionPolicy.trialDays))
        XCTAssertTrue(access.isUnlocked)
    }

    /// A first-run race must never lock someone out of an app they just installed.
    func testNoRecordedFirstLaunchIsUnlocked() {
        XCTAssertEqual(SubscriptionPolicy.access(state(firstLaunch: nil), now: start), .notYetStarted)
        XCTAssertTrue(SubscriptionPolicy.access(state(firstLaunch: nil), now: start).isUnlocked)
    }

    // MARK: - Subscription outranks the trial

    func testAnActiveEntitlementOutranksAnExpiredTrial() {
        XCTAssertEqual(SubscriptionPolicy.access(state(firstLaunch: start, entitled: true), now: days(999)),
                       .subscribed)
    }

    // MARK: - Offline

    /// Offline means "we learned nothing new", not "you stopped paying". StoreKit 2 answers from a
    /// signed local cache, so an unreachable store must not revoke anything — and locking a
    /// subscriber out of their own health app mid-flight would be both wrong and unrecoverable
    /// without the network they do not have.
    func testAnUnreachableStoreNeverRevokesAccess() {
        let subscribed = state(firstLaunch: start, entitled: true, reachable: false)
        XCTAssertEqual(SubscriptionPolicy.access(subscribed, now: days(400)), .subscribed)

        let inTrial = state(firstLaunch: start, entitled: false, reachable: false)
        XCTAssertTrue(SubscriptionPolicy.access(inTrial, now: days(2)).isUnlocked)
    }

    // MARK: - What is gated, and what can never be

    func testEveryPremiumFeatureFollowsTheSameAccessDecision() {
        let locked = state(firstLaunch: start)
        let unlocked = state(firstLaunch: start, entitled: true)
        for feature in PremiumFeature.allCases {
            XCTAssertFalse(SubscriptionPolicy.allows(feature, locked, now: days(30)))
            XCTAssertTrue(SubscriptionPolicy.allows(feature, unlocked, now: days(30)))
        }
    }

    /// D-33 narrowed "raw data is not paywalled" to exactly one thing: bulk export beyond 7 days.
    /// If a future change adds a case that gates viewing, logging or deleting records, this fails —
    /// which is the point, because that narrowing was explicitly not to be widened.
    func testTheOnlyRawDataGateIsTheExportWindow() {
        XCTAssertEqual(Set(PremiumFeature.allCases.map(\.rawValue)),
                       ["derivedData", "extendedExport", "exportAutomation", "alternateIcons"],
                       "a new gate must be a deliberate decision, not a quiet addition")
    }

    func testExportWindowIsCappedOnlyWhenLocked() {
        XCTAssertNil(SubscriptionPolicy.exportWindowDays(state(firstLaunch: start, entitled: true),
                                                         now: days(400)))
        XCTAssertNil(SubscriptionPolicy.exportWindowDays(state(firstLaunch: start), now: days(2)),
                     "the trial is full access, including export")
        XCTAssertEqual(SubscriptionPolicy.exportWindowDays(state(firstLaunch: start), now: days(30)),
                       SubscriptionPolicy.freeExportDays)
    }

    // MARK: - The export clamp (D-33 applied)

    func testAnUnlockedUserIsNeverClamped() {
        let scope = ExportScope(startDate: days(-400))
        let out = SubscriptionPolicy.clampExportScope(scope, state: state(firstLaunch: start, entitled: true),
                                                      now: start)
        XCTAssertFalse(out.wasNarrowed)
        XCTAssertEqual(out.scope.startDate, days(-400))
    }

    func testALockedUserIsClampedToTheFreeWindow() {
        let scope = ExportScope(startDate: days(-400))
        let out = SubscriptionPolicy.clampExportScope(scope, state: state(firstLaunch: start),
                                                      now: days(30))
        XCTAssertTrue(out.wasNarrowed)
        XCTAssertEqual(out.scope.startDate,
                       days(30).addingTimeInterval(-Double(SubscriptionPolicy.freeExportDays) * 86_400))
    }

    /// Asking for less than the free window is not a restriction and must not be reported as one.
    func testAShortRequestInsideTheWindowIsNotReportedAsNarrowed() {
        let now = days(30)
        let scope = ExportScope(startDate: now.addingTimeInterval(-2 * 86_400))
        let out = SubscriptionPolicy.clampExportScope(scope, state: state(firstLaunch: start), now: now)
        XCTAssertFalse(out.wasNarrowed)
    }

    /// D-33 narrowed exactly one dimension. A clamped export is still COMPLETE for the days it
    /// covers — same metrics, same sources, same raw and derived rows, same sensitive records. A
    /// locked user gets a shorter export, never a lesser one.
    func testTheClampTouchesNothingButTheStartDate() {
        let scope = ExportScope(metricIds: ["heart.rhr"], families: ["sleep"],
                                startDate: days(-400), endDate: days(30),
                                sourceIds: ["s1"], includeRaw: true, includeDerived: true,
                                includeSuppressed: true, includeSensitive: true)
        let out = SubscriptionPolicy.clampExportScope(scope, state: state(firstLaunch: start),
                                                      now: days(30)).scope
        XCTAssertEqual(out.metricIds, scope.metricIds)
        XCTAssertEqual(out.families, scope.families)
        XCTAssertEqual(out.endDate, scope.endDate)
        XCTAssertEqual(out.sourceIds, scope.sourceIds)
        XCTAssertEqual(out.includeRaw, scope.includeRaw)
        XCTAssertEqual(out.includeDerived, scope.includeDerived)
        XCTAssertEqual(out.includeSuppressed, scope.includeSuppressed)
        XCTAssertEqual(out.includeSensitive, scope.includeSensitive)
        XCTAssertNotEqual(out.startDate, scope.startDate)
    }

    // MARK: - Product identifiers are a contract

    /// Once a product id has been submitted to App Store Connect it can never be reused or renamed.
    /// Pinning the literals makes a rename a visible, deliberate act rather than a silent break that
    /// only shows up as "purchases stopped working".
    func testProductIdentifiersArePinned() {
        XCTAssertEqual(SubscriptionProduct.monthly.rawValue, "net.binjamshid.badan.pro.monthly")
        XCTAssertEqual(SubscriptionProduct.yearly.rawValue, "net.binjamshid.badan.pro.yearly")
        XCTAssertEqual(SubscriptionProduct.lifetime.rawValue, "net.binjamshid.badan.pro.lifetime")
    }

    /// Lifetime is a non-consumable and must never be put in a subscription group; the other two
    /// must share one, or a monthly→yearly move bills both at once instead of upgrading.
    func testLifetimeIsNotASubscription() {
        XCTAssertFalse(SubscriptionProduct.lifetime.isSubscription)
        XCTAssertTrue(SubscriptionProduct.monthly.isSubscription)
        XCTAssertTrue(SubscriptionProduct.yearly.isSubscription)
    }
}
