import Foundation

/// How a local store entitlement and a synced cross-platform one combine (ADR-0014 / D-44).
///
/// Pure: no StoreKit, no network, no clock. The entire cross-platform sync feature reduces to this
/// function, which is the point — the interesting rules are testable without an account, a sandbox
/// or a second device.
///
/// ## The one invariant
///
/// **The remote may GRANT access. It may never REVOKE it.**
///
/// `StoreKit.Transaction.currentEntitlements` is answered from a cryptographically signed local
/// cache that Apple maintains; the server's word is an unsigned relay of what some other device
/// claimed. Letting the weaker source overrule the stronger one would mean a server outage, a
/// bad deploy, or a bug in a route added years from now could lock a paying user out of their own
/// health app — the exact failure `SubscriptionPolicy` already refuses to allow for a failed
/// network call. So the merge is a union, never an intersection, and there is deliberately no code
/// path here that can turn `local == true` into "locked".
public enum EntitlementMerge {

    /// How long a synced entitlement keeps granting after the last SUCCESSFUL read of the server.
    ///
    /// This bound exists because a synced entitlement is categorically weaker than a local one. A
    /// StoreKit cache is signed by Apple and cannot be extended by anyone; a cached JSON snapshot on
    /// disk can be. Without a bound, a snapshot fetched once and then kept offline forever would be
    /// a permanent unlock — not a theoretical concern, since it needs no jailbreak, only airplane
    /// mode.
    ///
    /// 30 days is chosen to be far longer than any honest offline stretch (a trip, a dead router, a
    /// month abroad) and far shorter than "indefinitely". It never applies to a locally-owned
    /// entitlement, so the plane scenario `SubscriptionPolicy` was written for is untouched: a user
    /// who bought on THIS device is unaffected by this constant existing.
    public static let offlineGraceDays = 30

    /// Where the current access came from. Named rather than boolean so the UI can say the true
    /// thing — "your subscription is on your Android device" is a materially different sentence
    /// from "you're subscribed", and a user who cancels on the wrong platform because we blurred
    /// them has been failed by the copy, not by billing.
    public enum Source: Equatable, Sendable {
        /// This device's own store cache. The strongest evidence available.
        case localStore
        /// Another platform's purchase, relayed through the account.
        case synced(SyncedEntitlement.Platform)
        /// Premium time earned through referrals (`ReferralPolicy`). Not a purchase, and reported
        /// separately so the UI never tells someone to "manage your subscription" for something
        /// that has no subscription to manage.
        case referralGrant
        /// The snapshot holds something live, but this device has not reached the server inside
        /// `offlineGraceDays`, so it is no longer trusted on its own. Distinct from `.none` so the
        /// UI can tell someone to reconnect rather than to buy something they already own.
        case syncedButStale(SyncedEntitlement.Platform)
        case referralGrantButStale
        /// Nothing grants right now.
        case none

        public var grantsAccess: Bool {
            switch self {
            case .localStore, .synced, .referralGrant: return true
            case .syncedButStale, .referralGrantButStale, .none: return false
            }
        }

        /// True when access is withheld only because the snapshot went stale. The paywall uses this
        /// to lead with "reconnect" instead of with a price.
        public var isStale: Bool {
            switch self {
            case .syncedButStale, .referralGrantButStale: return true
            case .localStore, .synced, .referralGrant, .none: return false
            }
        }
    }

    /// The whole decision.
    ///
    /// - Parameters:
    ///   - localEntitlement: what this device's own store reports right now.
    ///   - snapshot: the last successfully-read server state, or `nil` if this install has never
    ///     signed in or never completed a read.
    public static func resolve(localEntitlement: Bool,
                               snapshot: EntitlementSnapshot?,
                               now: Date,
                               offlineGraceDays: Int = offlineGraceDays) -> Source {
        // Checked FIRST and returned unconditionally. Every line below this one is unreachable for
        // a user who owns the product on this device, which is how the invariant above is enforced
        // structurally rather than by careful reading.
        if localEntitlement { return .localStore }

        guard let snapshot else { return .none }

        // Prefer a lifetime entitlement, then the one that expires furthest out — a user who has a
        // monthly on iOS and a lifetime on Android should be told about the lifetime.
        let live = snapshot.entitlements.filter { $0.isLive(now: now) }
        let best = live.max(by: Self.isWeaker)
        let referral = snapshot.hasLiveReferralGrant(now: now)
        guard best != nil || referral else { return .none }

        // A `syncedAt` in the FUTURE means the device clock moved backwards since the read. Treated
        // as "just synced" rather than as an expired grace window: the same generous-but-bounded
        // choice `SubscriptionPolicy.access` makes for a future `firstLaunch`, and for the same
        // reason — a clock change is not evidence of fraud, and locking someone out over one is a
        // support ticket they cannot resolve.
        let elapsed = max(0, now.timeIntervalSince(snapshot.syncedAt))
        let isStale = elapsed > Double(offlineGraceDays) * 86_400

        // A real purchase is reported ahead of a referral grant even when the grant runs longer:
        // the purchase is the thing the user can manage, cancel and be billed for, so it is the
        // thing they need told about.
        if let best {
            return isStale ? .syncedButStale(best.platform) : .synced(best.platform)
        }
        return isStale ? .referralGrantButStale : .referralGrant
    }

    /// Convenience for the common question.
    public static func grantsAccess(localEntitlement: Bool,
                                    snapshot: EntitlementSnapshot?,
                                    now: Date) -> Bool {
        resolve(localEntitlement: localEntitlement, snapshot: snapshot, now: now).grantsAccess
    }

    /// Ordering for "which entitlement should we tell the user about": lifetime beats dated, and a
    /// later expiry beats an earlier one.
    private static func isWeaker(_ lhs: SyncedEntitlement, _ rhs: SyncedEntitlement) -> Bool {
        if lhs.isLifetime != rhs.isLifetime { return rhs.isLifetime }
        return (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
    }
}
