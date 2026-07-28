import Foundation

/// The pure entitlement rule: given what the store says and when the app was first opened, may this
/// feature be used?
///
/// No StoreKit, no clock, no storage — every input is passed in, which is what lets the trial
/// boundary and the expiry behaviour be tested without a sandbox account or a device.
public enum SubscriptionPolicy {

    /// Days of full access from FIRST APP LAUNCH, before anything has been bought.
    ///
    /// Note what this is not: it is not an App Store introductory offer. Apple's free trial begins
    /// when a subscription is purchased and requires payment details up front. This one begins when
    /// the app is first opened and asks for nothing — a genuinely try-before-you-decide window. The
    /// two can coexist later; this is the one D-33's pricing was specified against.
    public static let trialDays = 7

    /// Days of export available without a subscription (D-33). Beyond this is `extendedExport`.
    public static let freeExportDays = 7

    /// Everything the policy needs to decide.
    public struct State: Equatable, Sendable {
        /// When the app was first launched on this device, or nil if that has not been recorded yet
        /// (in which case the caller is expected to record `now` and re-ask).
        public var firstLaunch: Date?
        /// Whether the store reports an active, unexpired entitlement to any tier.
        public var hasActiveEntitlement: Bool
        /// Whether the store could be reached. `false` does NOT revoke access — see `isUnlocked`.
        public var storeReachable: Bool

        public init(firstLaunch: Date?, hasActiveEntitlement: Bool, storeReachable: Bool) {
            self.firstLaunch = firstLaunch
            self.hasActiveEntitlement = hasActiveEntitlement
            self.storeReachable = storeReachable
        }
    }

    /// Why access is granted or withheld. Named rather than boolean so the paywall can say the true
    /// thing ("4 days left in your trial" vs "your subscription ended") instead of one generic line.
    public enum Access: Equatable, Sendable {
        case subscribed
        case trial(daysRemaining: Int)
        case trialExpired
        /// No first-launch date recorded yet. The caller records one and re-asks; treated as
        /// unlocked for this single evaluation so a first-run race can never lock someone out of an
        /// app they just installed.
        case notYetStarted

        public var isUnlocked: Bool {
            switch self {
            case .subscribed, .trial, .notYetStarted: return true
            case .trialExpired: return false
            }
        }
    }

    /// The whole decision.
    ///
    /// Offline is deliberately NOT a lock. StoreKit 2 answers `currentEntitlements` from a cached,
    /// signed local copy, so an unreachable store means "we learned nothing new", not "you stopped
    /// paying" — and locking a paying user out of their own health app on a plane would be both
    /// wrong and unrecoverable without network. An entitlement that has genuinely lapsed is reported
    /// by the cache too, so this costs nothing in enforcement.
    public static func access(_ state: State, now: Date,
                              trialDays: Int = trialDays) -> Access {
        if state.hasActiveEntitlement { return .subscribed }
        guard let firstLaunch = state.firstLaunch else { return .notYetStarted }

        let elapsed = now.timeIntervalSince(firstLaunch)
        // A first-launch date in the FUTURE means the device clock moved backwards (travel, manual
        // change, a restore). Treated as day zero rather than as an infinite trial: generous to the
        // user, but not unboundedly so.
        guard elapsed >= 0 else { return .trial(daysRemaining: trialDays) }

        let daysUsed = Int(elapsed / 86_400)
        let remaining = trialDays - daysUsed
        return remaining > 0 ? .trial(daysRemaining: remaining) : .trialExpired
    }

    /// Whether a specific feature may be used. Every gate in the app routes through here, so the
    /// list of what is gated is enumerable from one place rather than scattered across call sites.
    public static func allows(_ feature: PremiumFeature, _ state: State, now: Date) -> Bool {
        access(state, now: now).isUnlocked
    }

    /// The export cut-off for a given access state: `nil` means unlimited.
    ///
    /// The only place the D-33 narrowing bites. Everything else about a user's records —
    /// viewing, keeping, logging, deleting — is free at every access level, and there is
    /// deliberately no code path here that could change that.
    public static func exportWindowDays(_ state: State, now: Date) -> Int? {
        access(state, now: now).isUnlocked ? nil : freeExportDays
    }

    /// The D-33 gate, applied. Returns the scope actually permitted, and whether it was narrowed.
    ///
    /// Narrows only `startDate`. Every other dimension of an export — which metrics, which sources,
    /// raw vs derived, sensitive records, checksums, the manifest — is untouched at every access
    /// level, because D-33 narrowed exactly one thing and explicitly forbade widening it. A locked
    /// user still exports *everything about* the last 7 days, at full resolution, with full
    /// provenance; they do not get a lesser export of a longer period.
    ///
    /// `wasNarrowed` is returned rather than inferred so the caller can TELL the user their export
    /// was clipped. Silently handing back 7 days when someone asked for a year would be the
    /// dishonest version of this gate, and worse than not having it.
    public static func clampExportScope(_ scope: ExportScope, state: State,
                                        now: Date) -> (scope: ExportScope, wasNarrowed: Bool) {
        guard let windowDays = exportWindowDays(state, now: now) else { return (scope, false) }
        let earliest = now.addingTimeInterval(-Double(windowDays) * 86_400)
        // A request that already starts inside the window is not narrowed — asking for 3 days when
        // 7 are allowed must not be reported as a restriction.
        if let requested = scope.startDate, requested >= earliest { return (scope, false) }
        var clamped = scope
        clamped.startDate = earliest
        return (clamped, true)
    }
}
