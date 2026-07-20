import HealthKit
import XCTest
@testable import BADAN

/// EPIC-01 task 5 / EPIC-03 task 6: the staged-permission bundles, the explainer-before-prompt
/// ordering, and the route-consent store that actually gates ingestion.
///
/// The property most of these protect is a NEGATIVE one — that nothing reaches a system prompt
/// without an explainer, and that routes never ride along with a health family — which is exactly
/// the kind of thing that regresses silently because the happy path keeps working.
final class PermissionStagingTests: XCTestCase {

    /// `HealthPermissionGate` and `RouteConsentStore` both persist to process-global
    /// `UserDefaults`, so each test starts and ends clean — see `LabelingFixTests` for the same
    /// discipline around `SeedController`'s keys.
    override func setUp() {
        super.setUp()
        HealthPermissionGate.clearAll()
        RouteConsentStore.clear()
    }

    override func tearDown() {
        HealthPermissionGate.clearAll()
        RouteConsentStore.clear()
        super.tearDown()
    }

    // MARK: - Bundle coverage

    /// Every ingesting type in `HKTypeMap` must land in exactly one bundle, because a bundle is
    /// what carries the explainer copy. A type in the authorization set but in no bundle is a
    /// type BADAN asks for and never explains, which is precisely what plan §13.1 forbids.
    func testEveryReadTypeBelongsToExactlyOneBundle() {
        for entry in HKTypeMap.table {
            let owners = HealthPermissionBundle.allCases.filter { bundle in
                bundle.quantityTypes.contains { $0.identifier == entry.identifier }
            }
            XCTAssertEqual(owners.count, 1,
                           "\(entry.platformType) belongs to \(owners.count) bundles, expected exactly 1")
        }
    }

    /// The union of every bundle's read types must cover the adapter's authorization set. If the
    /// adapter ever asks for something no bundle names, the explainer understates the ask.
    func testBundlesCoverTheAdapterAuthorizationSet() {
        let bundled = HealthPermissionBundle.allCases.reduce(into: Set<HKObjectType>()) {
            $0.formUnion($1.readTypes)
        }
        let unexplained = HKTypeMap.authorizationReadTypes.subtracting(bundled)
        XCTAssertTrue(unexplained.isEmpty,
                      "These read types have no bundle and therefore no explainer: \(unexplained)")
    }

    /// Routes must never appear in a health family's read set. This is the structural half of
    /// "routes gate independently" (plan §4.11) — copy can promise it, only this can enforce it.
    func testRoutesAreNotInAnyHealthFamilyBundle() {
        let routeTypes = HealthKitAdapter.routeReadTypes
        for bundle in HealthPermissionBundle.allCases where bundle != .routes {
            XCTAssertTrue(bundle.readTypes.isDisjoint(with: routeTypes),
                          "\(bundle.rawValue) would request workout routes without the route explainer")
        }
        XCTAssertFalse(HealthPermissionBundle.routes.requestsPlatformReadTypes,
                       "Routes must never be requested through the family staging path")
    }

    /// Onboarding's connect step covers vitals, sleep and activity — and specifically NOT body or
    /// workouts, which their own surfaces ask for. A regression here silently turns the staged
    /// flow back into the blanket prompt.
    func testOnboardingConnectExcludesBodyAndWorkouts() {
        XCTAssertEqual(Set(HealthPermissionBundle.onboardingConnect), [.coreVitals, .sleep, .activity])
        XCTAssertFalse(HealthPermissionBundle.onboardingConnect.contains(.body))
        XCTAssertFalse(HealthPermissionBundle.onboardingConnect.contains(.workouts))
        XCTAssertFalse(HealthPermissionBundle.onboardingConnect.contains(.routes))
    }

    /// Every bundle's user-facing copy is genuinely bilingual — not English pasted into both
    /// fields, which passes a naive "is it non-empty" check while shipping untranslated Arabic.
    func testEveryBundleIsBilingual() {
        for bundle in HealthPermissionBundle.allCases {
            assertBilingual(bundle.title, label: "\(bundle.rawValue).title")
            assertBilingual(bundle.purpose, label: "\(bundle.rawValue).purpose")
            assertBilingual(bundle.boundary, label: "\(bundle.rawValue).boundary")
            XCTAssertFalse(bundle.reads.isEmpty, "\(bundle.rawValue) lists nothing it reads")
            for (index, line) in bundle.reads.enumerated() {
                assertBilingual(line, label: "\(bundle.rawValue).reads[\(index)]")
            }
        }
    }

    // MARK: - Gate ordering

    /// A stub that records what it was asked for and never touches HealthKit.
    private final class RecordingRequester: HealthPermissionRequesting, @unchecked Sendable {
        private(set) var requested: [Set<HKObjectType>] = []
        func requestReadAccess(_ types: Set<HKObjectType>) async -> Bool {
            requested.append(types)
            return true
        }
    }

    /// The ordering guarantee: staging a bundle puts its explainer on screen and issues NO
    /// platform request until the user confirms.
    @MainActor
    func testRequestShowsExplainerBeforeAnyPlatformRequest() async throws {
        // `HealthPermissionGate.request` deliberately no-ops when the platform is absent, so
        // these ordering assertions only mean anything where HealthKit exists. `try`, not `try?`:
        // swallowing the skip would let the assertions run anyway and fail for the wrong reason.
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let requester = RecordingRequester()
        let gate = HealthPermissionGate(requester: requester)

        gate.request([.body])
        XCTAssertEqual(gate.pendingExplainer, .body)
        XCTAssertTrue(requester.requested.isEmpty,
                      "A platform prompt was issued before the explainer was answered")

        await gate.confirmPending()
        XCTAssertEqual(requester.requested.count, 1)
        XCTAssertNil(gate.pendingExplainer)
        XCTAssertTrue(gate.isIdle)
    }

    /// Declining issues no prompt at all, and — because the bundle is now marked asked — does not
    /// re-present on the next appearance. Declining once is an answer.
    @MainActor
    func testDecliningIssuesNoPromptAndDoesNotRepeat() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let requester = RecordingRequester()
        let gate = HealthPermissionGate(requester: requester)

        gate.request([.body])
        gate.declinePending()
        XCTAssertTrue(requester.requested.isEmpty)
        XCTAssertTrue(HealthPermissionGate.hasBeenAsked(.body))

        gate.request([.body])
        XCTAssertNil(gate.pendingExplainer, "An already-answered bundle re-presented its explainer")
    }

    /// Two bundles are explained one after the other rather than merged into a single screen —
    /// merging is how staged consent quietly becomes the blanket prompt.
    @MainActor
    func testQueuedBundlesAreExplainedOneAtATime() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let requester = RecordingRequester()
        let gate = HealthPermissionGate(requester: requester)

        gate.request([.workouts, .activity])
        XCTAssertEqual(gate.pendingExplainer, .workouts)
        XCTAssertFalse(gate.isIdle)

        await gate.confirmPending()
        XCTAssertEqual(gate.pendingExplainer, .activity, "The second bundle should follow, not appear alongside")

        await gate.confirmPending()
        XCTAssertTrue(gate.isIdle)
        XCTAssertEqual(requester.requested.count, 2)
        XCTAssertEqual(gate.confirmed, [.workouts, .activity])
    }

    /// Re-running a screen's `.task` must not stack duplicate explainers for the same bundle.
    @MainActor
    func testRepeatedRequestDoesNotQueueDuplicates() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let requester = RecordingRequester()
        let gate = HealthPermissionGate(requester: requester)

        gate.request([.workouts, .activity])
        gate.request([.workouts, .activity])
        await gate.confirmPending()
        await gate.confirmPending()

        XCTAssertTrue(gate.isIdle)
        XCTAssertEqual(requester.requested.count, 2, "A repeated request queued the same bundles twice")
    }

    /// Routes are filtered out of family staging entirely: opening a surface can never trigger a
    /// location prompt, however a caller phrases the request.
    @MainActor
    func testStagingIgnoresRoutes() {
        let requester = RecordingRequester()
        let gate = HealthPermissionGate(requester: requester)
        gate.request([.routes])
        XCTAssertNil(gate.pendingExplainer)
        XCTAssertTrue(requester.requested.isEmpty)
    }

    // MARK: - Route consent (EPIC-03 task 6)

    /// Fail-closed with nothing recorded — the state every fresh install is in.
    func testRouteConsentDefaultsToDenied() {
        XCTAssertFalse(RouteConsentStore.current.granted)
        XCTAssertFalse(RouteConsentStore().routeConsent().granted)
    }

    func testRouteConsentRoundTrips() {
        let decidedAt = Date(timeIntervalSince1970: 1_783_000_000)
        RouteConsentStore.record(granted: true, decidedAt: decidedAt)

        let consent = RouteConsentStore.current
        XCTAssertTrue(consent.granted)
        XCTAssertEqual(consent.policyVersion, RouteConsent.currentPolicyVersion)
        XCTAssertEqual(consent.decidedAt?.timeIntervalSince1970 ?? 0, decidedAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertFalse(RouteConsentStore.needsReconsent)
    }

    /// The provider handed to `HealthKitAdapter` must reflect a revocation immediately — this is
    /// the seam that actually stops route ingestion, so "off" has to mean off on the very next
    /// read rather than after a restart.
    func testTurningRouteConsentOffIsImmediatelyVisibleToTheProvider() {
        let provider = RouteConsentStore()
        RouteConsentStore.record(granted: true, decidedAt: Date())
        XCTAssertTrue(provider.routeConsent().granted)

        RouteConsentStore.record(granted: false, decidedAt: Date())
        XCTAssertFalse(provider.routeConsent().granted,
                       "A revoked consent must fail closed on the next read, not the next launch")
    }

    /// A grant recorded against superseded explainer text expires rather than silently covering
    /// wording the user never saw.
    func testConsentAgainstAnOlderPolicyVersionDoesNotGrant() {
        UserDefaults.standard.set(true, forKey: RouteConsentStore.grantedKey)
        UserDefaults.standard.set("route-consent-v0", forKey: RouteConsentStore.policyVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: RouteConsentStore.decidedAtKey)

        XCTAssertFalse(RouteConsentStore.current.granted)
        XCTAssertTrue(RouteConsentStore.needsReconsent,
                      "The route screen needs to explain WHY the switch reset, not just show it off")
    }

    /// "Granted" with no moment attached is not a record anyone could stand behind.
    func testGrantWithNoDecisionDateDoesNotGrant() {
        UserDefaults.standard.set(true, forKey: RouteConsentStore.grantedKey)
        UserDefaults.standard.set(RouteConsent.currentPolicyVersion, forKey: RouteConsentStore.policyVersionKey)
        UserDefaults.standard.removeObject(forKey: RouteConsentStore.decidedAtKey)

        XCTAssertFalse(RouteConsentStore.current.granted)
    }

    func testClearRevokesConsent() {
        RouteConsentStore.record(granted: true, decidedAt: Date())
        RouteConsentStore.clear()
        XCTAssertFalse(RouteConsentStore.current.granted)
        XCTAssertFalse(RouteConsentStore.needsReconsent)
    }

    // MARK: - Helper

    private func assertBilingual(_ value: LocalizedString, label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value.en.trimmingCharacters(in: .whitespaces).isEmpty,
                       "\(label) has no English", file: file, line: line)
        XCTAssertFalse(value.ar.trimmingCharacters(in: .whitespaces).isEmpty,
                       "\(label) has no Arabic", file: file, line: line)
        XCTAssertNotEqual(value.en, value.ar,
                          "\(label) uses the same string for both languages — Arabic is untranslated",
                          file: file, line: line)
        // A real Arabic string contains Arabic-script characters. Catches the specific regression
        // where a placeholder or an English fallback is pasted into the `ar` slot.
        XCTAssertTrue(value.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                      "\(label)'s Arabic contains no Arabic script", file: file, line: line)
    }
}
