import Foundation

/// One platform's report of what an account currently owns, as it travels between devices
/// (ADR-0014 / D-44).
///
/// ## What this is NOT
///
/// This is not a health record and it is not a receipt. It carries a product id, a platform, an
/// expiry and the moment the ORIGINATING store confirmed it — nothing else. No reading, no
/// derivation, no date that says anything about the user's body. The account surface introduced by
/// ADR-0014 reverses BADAN's no-accounts posture; it does not reverse
/// **"send no health data off device"**, which survives intact and is still the thing
/// `AccountPayloadShapeTests` fails loudly over.
///
/// ## Why `observedAt` is the originating store's clock, not the server's
///
/// The server never talks to Apple's or Google's billing APIs — there is no server-side receipt
/// validation, because that would mean BADAN holding purchase history for people it deliberately
/// knows almost nothing about. Each platform reports what its own signed local cache says, and the
/// server relays it. `observedAt` is therefore "when a device with a real StoreKit/Play cache last
/// looked", which is exactly the provenance a consumer needs to judge staleness — and pretending
/// the server verified anything would be the dishonest version of this field.
public struct SyncedEntitlement: Equatable, Sendable, Codable {

    /// Which store the entitlement came from. Deliberately closed: a third platform is a product
    /// decision, not a string someone can post.
    public enum Platform: String, Codable, Sendable, CaseIterable {
        case ios
        case android
    }

    public var platform: Platform
    /// The store product id, verbatim. iOS sends `net.binjamshid.badan.pro.*`; Android sends the
    /// D-40 shape (`badan_pro` with a base plan, or `pro.lifetime`). Not normalised into a shared
    /// tier enum on the wire, because the two product spaces are genuinely different and flattening
    /// them would lose the ability to tell a user WHERE their subscription lives.
    public var productId: String
    /// A one-time purchase that never lapses. `expiresAt` is `nil` exactly when this is true.
    public var isLifetime: Bool
    /// When the originating store says the entitlement lapses. `nil` for lifetime.
    public var expiresAt: Date?
    /// When the originating platform's signed local cache last confirmed this.
    public var observedAt: Date

    public init(platform: Platform, productId: String, isLifetime: Bool,
                expiresAt: Date?, observedAt: Date) {
        self.platform = platform
        self.productId = productId
        self.isLifetime = isLifetime
        self.expiresAt = expiresAt
        self.observedAt = observedAt
    }

    /// Whether this entitlement is still live on its own terms, ignoring how stale the snapshot is.
    public func isLive(now: Date) -> Bool {
        if isLifetime { return true }
        guard let expiresAt else { return false }
        return expiresAt > now
    }
}

/// Everything the server said about an account, plus when this device last managed to ask.
///
/// Cached to disk so the merge below works offline. `syncedAt` is recorded by the CLIENT on a
/// successful read, not taken from the server body — a server-supplied timestamp would let a
/// compromised or simply wrong server extend the offline grace window indefinitely, and this value
/// exists precisely to bound that.
public struct EntitlementSnapshot: Equatable, Sendable, Codable {
    public var entitlements: [SyncedEntitlement]

    /// When premium earned through referrals runs out, or `nil` if none has been earned
    /// (`ReferralPolicy`). The server computes and owns this; the client only reads it.
    ///
    /// A first-class field rather than a `SyncedEntitlement` with a reserved product id. A referral
    /// grant did not come from a store, has no product, and cannot be managed or cancelled in
    /// Settings — encoding it as a fake purchase would make every consumer that shows "where your
    /// subscription lives" quietly wrong, and would put a string BADAN invented into a field whose
    /// documented meaning is "the store's own identifier".
    public var referralGrantExpiresAt: Date?

    /// How many claims of this account's code have been rewarded so far. Display only — the
    /// referral screen shows progress toward `ReferralPolicy.maxRewardedReferrals`.
    public var successfulReferrals: Int

    public var syncedAt: Date

    public init(entitlements: [SyncedEntitlement],
                referralGrantExpiresAt: Date? = nil,
                successfulReferrals: Int = 0,
                syncedAt: Date) {
        self.entitlements = entitlements
        self.referralGrantExpiresAt = referralGrantExpiresAt
        self.successfulReferrals = successfulReferrals
        self.syncedAt = syncedAt
    }

    public static func empty(syncedAt: Date) -> EntitlementSnapshot {
        .init(entitlements: [], syncedAt: syncedAt)
    }

    public func hasLiveReferralGrant(now: Date) -> Bool {
        guard let referralGrantExpiresAt else { return false }
        return referralGrantExpiresAt > now
    }
}
