import Foundation

/// The three things BADAN sells, and the App Store product identifiers they map to.
///
/// The identifiers are a CONTRACT with App Store Connect: once a product is created there and has
/// ever been submitted, its id can never be reused or renamed. Treat these strings the way the
/// storage codes in `NotificationClass` are treated — renaming one is not a refactor.
public enum SubscriptionProduct: String, CaseIterable, Sendable {
    case monthly = "net.binjamshid.badan.pro.monthly"
    case yearly = "net.binjamshid.badan.pro.yearly"
    case lifetime = "net.binjamshid.badan.pro.lifetime"

    /// `lifetime` is a non-consumable, the other two are auto-renewable subscriptions. They cannot
    /// share a subscription group, and the non-consumable must not be put in one at all.
    public var isSubscription: Bool { self != .lifetime }

    /// The subscription group every renewable tier must share, so a user moving monthly↔yearly is
    /// an upgrade/downgrade rather than two concurrent subscriptions billed at once.
    public static let subscriptionGroupId = "badan.pro"

    /// Display order in the paywall: yearly first because it is the best value, then lifetime, then
    /// monthly. Not a dark pattern — every price is shown plainly next to the others.
    public static let displayOrder: [SubscriptionProduct] = [.yearly, .lifetime, .monthly]
}

/// What a subscription unlocks. Each case is a gate the app checks; nothing else may gate.
///
/// Bounded deliberately, and the boundary is the product's founding promise as amended by D-33:
/// **you never pay to see, keep, log or delete your own records.** Viewing every reading at full
/// resolution, provenance, the metric browser, manual logging, deletion and the privacy guarantees
/// are free forever and are not represented here at all — there is no enum case that could be used
/// to gate them.
public enum PremiumFeature: String, CaseIterable, Sendable {
    /// Everything BADAN computes ABOUT the data: scores, baselines, trends, insights. The raw
    /// readings those are computed from stay free.
    case derivedData

    /// Export beyond the free window (D-33). See `SubscriptionPolicy.freeExportDays`.
    case extendedExport

    /// Scheduled/automated exports and custom templates. Distinct from `extendedExport`: this is
    /// convenience on top of export, which `docs/MONETIZATION.md` §B4 already judged defensible.
    case exportAutomation

    /// Alternate app icons. Purely cosmetic — the one gate here that costs a non-subscriber nothing
    /// but decoration.
    case alternateIcons
}
