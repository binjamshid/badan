import Foundation
import HealthKit
import Observation

/// Issues a read-authorization request for a set of HealthKit types.
///
/// A protocol so the staging logic in `HealthPermissionGate` is testable without a HealthKit
/// store: on a simulator `isHealthDataAvailable()` is true but the sheet never resolves the way a
/// device's does, and in a unit-test process it must not be reachable at all.
protocol HealthPermissionRequesting: Sendable {
    /// `true` means the request completed without error — NOT that every type was granted.
    /// HealthKit never reveals per-type read grants (that is the privacy design, not an
    /// oversight), so no caller may treat this as "we now have data". See
    /// `HealthKitAdapter.requestAuthorization`, which carries the same caveat for the same reason.
    func requestReadAccess(_ types: Set<HKObjectType>) async -> Bool
}

/// The real requester.
///
/// **Why its own `HKHealthStore` rather than the adapter's.** `HealthKitAdapter` exposes exactly
/// two authorization entry points — the whole main read set, and routes — because that is all
/// ingestion ever needed. Staged bundles need a THIRD shape: "ask for just this family". An
/// `HKHealthStore` is a lightweight handle onto app-wide authorization state, not a session, so
/// a second instance asks about the same app and the same grants; nothing is duplicated except
/// the handle itself. The alternative — a per-bundle method on the adapter — is a change to the
/// file stage 2 just landed ingestion in, for a purely presentational concern.
///
/// The cost of this split is that "what BADAN can ask for" now has two callers. It does NOT have
/// two definitions: both resolve their types from `HKTypeMap`, and
/// `PermissionStagingTests.testEveryReadTypeBelongsToExactlyOneBundle` fails the build if a
/// type ever reaches the adapter's set without reaching a bundle's explainer.
struct HealthKitPermissionRequester: HealthPermissionRequesting {
    private let store = HKHealthStore()

    func requestReadAccess(_ types: Set<HKObjectType>) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), !types.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: types) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// Presents each staged permission bundle's explainer BEFORE its system prompt, and remembers
/// which bundles have already been through that (plan §13.1, EPIC-01 task 5).
///
/// The type's whole reason to exist is the ordering guarantee: `request(_:)` never calls the
/// platform. It parks the bundle in `pendingExplainer`, the screen renders
/// `PermissionExplainerSheet`, and only the user's own "Continue" reaches
/// `HealthPermissionRequesting`. There is no code path from a screen's `.task` to a system dialog
/// that skips the explainer, which is the property plan §13.1 asks for in as many words ("the
/// system dialog is never the first explanation").
///
/// Decisions persist in `UserDefaults` rather than on `CustomizationProfile`: this is not a user
/// preference anybody would want to see in Settings or carry through a profile reset, it is a
/// record of "we already asked, don't nag" — the same category as `badan.onboardingComplete`, and
/// stored the same way. A user who declines is asked again only if they open the surface after
/// explicitly re-requesting from Sources, never automatically.
@Observable
@MainActor
final class HealthPermissionGate {
    /// The bundle whose explainer is on screen, if any. Screens bind a sheet to this.
    private(set) var pendingExplainer: HealthPermissionBundle?
    /// True while the system sheet is up, so the explainer's Continue button can't be tapped
    /// twice into two overlapping `requestAuthorization` calls.
    private(set) var isRequesting = false
    /// Bundles the user pressed Continue on during THIS gate's lifetime (not persisted — the
    /// durable record is the per-bundle "asked" key, and "asked" is all HealthKit lets anyone
    /// know for certain).
    ///
    /// Onboarding reads this to decide whether a connect actually happened: if every explainer
    /// was dismissed with "Not now", nothing was requested and marking the app as connected would
    /// be a claim about the user's choice that they did not make.
    private(set) var confirmed: Set<HealthPermissionBundle> = []
    /// Nothing on screen and nothing waiting. A staged flow (onboarding) watches this to know the
    /// sequence has finished.
    var isIdle: Bool { pendingExplainer == nil && queue.isEmpty }

    /// Bundles queued behind `pendingExplainer`. A workout surface asks for two
    /// (`workouts` + `activity`) and they are explained one after another rather than merged
    /// into a single "and also…" screen — merging is how a staged ask quietly becomes the blanket
    /// prompt this design exists to avoid.
    private var queue: [HealthPermissionBundle] = []

    private let requester: HealthPermissionRequesting

    init(requester: HealthPermissionRequesting = HealthKitPermissionRequester()) {
        self.requester = requester
    }

    // MARK: - Decision memory

    // `nonisolated` because these touch nothing but `UserDefaults`, which is thread-safe. The
    // isolation the enclosing `@MainActor` would otherwise impose is not just unnecessary, it is
    // wrong: the decision memory is plain persisted state, and forcing an actor hop to read it
    // would stop a nonisolated caller (a test, or a future background purge) from asking a
    // question that needs no UI at all.
    private nonisolated static func decidedKey(_ bundle: HealthPermissionBundle) -> String {
        "badan.permissionBundle.\(bundle.rawValue).decidedAt"
    }

    /// Whether this bundle's explainer has already been answered (either way).
    nonisolated static func hasBeenAsked(_ bundle: HealthPermissionBundle) -> Bool {
        UserDefaults.standard.object(forKey: decidedKey(bundle)) != nil
    }

    nonisolated static func markAsked(_ bundle: HealthPermissionBundle, at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: decidedKey(bundle))
    }

    /// Forget every bundle decision — for "delete all data", which otherwise leaves the app
    /// silently believing it has already explained itself to a user who is starting over.
    nonisolated static func clearAll() {
        for bundle in HealthPermissionBundle.allCases {
            UserDefaults.standard.removeObject(forKey: decidedKey(bundle))
        }
    }

    // MARK: - Staging

    /// Queue any of `bundles` that hasn't been asked yet and show the first one's explainer.
    ///
    /// Safe to call from a screen's `.task` on every appearance: already-answered bundles are
    /// filtered out, so a returning user sees nothing. `routes` is filtered out unconditionally —
    /// location consent is never triggered by opening a surface, only by the user walking into
    /// `RouteConsentScreen` and turning it on themselves (plan §4.11).
    func request(_ bundles: [HealthPermissionBundle]) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let due = bundles.filter { $0.requestsPlatformReadTypes && !Self.hasBeenAsked($0) }
        guard !due.isEmpty else { return }

        // Preserve caller order, drop anything already queued or on screen, so a screen that
        // re-runs its `.task` cannot stack the same explainer twice.
        for bundle in due where bundle != pendingExplainer && !queue.contains(bundle) {
            queue.append(bundle)
        }
        advanceIfIdle()
    }

    private func advanceIfIdle() {
        guard pendingExplainer == nil, !queue.isEmpty else { return }
        pendingExplainer = queue.removeFirst()
    }

    /// The user tapped Continue on the explainer: NOW the system sheet may appear.
    ///
    /// The bundle is marked asked regardless of outcome. A "false" result means the sheet failed
    /// or HealthKit is unavailable, not that the user said no — and re-showing the explainer on
    /// the next appearance in that case would be a loop the user cannot escape, since HealthKit
    /// will not re-present a sheet for types it has already decided.
    func confirmPending() async {
        guard let bundle = pendingExplainer, !isRequesting else { return }
        isRequesting = true
        _ = await requester.requestReadAccess(bundle.readTypes)
        isRequesting = false
        confirmed.insert(bundle)
        Self.markAsked(bundle, at: Date())
        pendingExplainer = nil
        advanceIfIdle()
    }

    /// The user dismissed the explainer without continuing. No system prompt is issued, and the
    /// bundle is marked asked so the app does not re-present the same screen every time they come
    /// back — declining once is an answer, and repeating the question is how an explainer turns
    /// into a nag.
    func declinePending() {
        guard let bundle = pendingExplainer else { return }
        Self.markAsked(bundle, at: Date())
        pendingExplainer = nil
        advanceIfIdle()
    }

    /// Ask for one bundle again from a deliberate user action (the Sources screen's per-family
    /// row), bypassing the already-asked filter. Note that HealthKit will not re-present a sheet
    /// for types the user has already decided on — `SourcesScreen` says so in plain language
    /// rather than letting a tap appear to do nothing.
    func requestAgain(_ bundle: HealthPermissionBundle) {
        guard bundle.requestsPlatformReadTypes, HKHealthStore.isHealthDataAvailable() else { return }
        guard pendingExplainer != bundle, !queue.contains(bundle) else { return }
        queue.append(bundle)
        advanceIfIdle()
    }
}
