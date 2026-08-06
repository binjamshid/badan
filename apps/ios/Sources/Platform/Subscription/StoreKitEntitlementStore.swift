import Foundation
import StoreKit
import os

/// The thin StoreKit 2 shell around `SubscriptionPolicy`. Loads products, runs purchases, watches
/// for transaction updates, and answers "is anything active right now?".
///
/// ## Accounts (ADR-0014 / D-44) — and what did NOT change
///
/// This type used to carry a note explaining that BADAN had no accounts by design (D-32). D-44
/// reversed that: there is now an optional Sign in with Apple account whose only jobs are carrying
/// a subscription between iOS and Android and running referrals.
///
/// What did not change is everything StoreKit already did well. A purchase is still bound to the
/// signed-in Apple ID by StoreKit itself, Restore still works with no account, family sharing still
/// works, and a reinstall still recovers the purchase — all without signing in to BADAN. The account
/// is strictly additive: `entitlementSyncHook` reports what this device owns, `syncedSnapshotSource`
/// reads what the account knows, and `EntitlementMerge` combines them under a rule that lets the
/// remote grant access and never revoke it. A user who never signs in sees the behaviour this file
/// had before D-44, exactly.
///
/// ## Offline is not a lock
///
/// `Transaction.currentEntitlements` is served from a signed local cache, so this works on a plane.
/// `storeReachable` is recorded for diagnostics and paywall copy only; `SubscriptionPolicy` never
/// revokes access because a network call failed.
@MainActor
@Observable
final class StoreKitEntitlementStore {
    private static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Subscription")

    /// The date this install was first opened — the trial clock (D-33 pricing).
    ///
    /// `UserDefaults`, not Keychain. Keychain would survive a delete-and-reinstall and so would
    /// resist trial farming, but it also survives a user's deliberate "start clean", which in a
    /// local-first health app with no accounts is a legitimate thing to do and one this codebase
    /// otherwise honours everywhere. Someone determined to reset a 7-day trial can do so; that is a
    /// smaller cost than a reset that silently does not reset.
    private static let firstLaunchKey = "badan.subscription.firstLaunch"

    private(set) var products: [Product] = []
    private(set) var activeProductIds: Set<String> = []
    private(set) var storeReachable = false
    private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let clock: Clock

    /// Where this device reports what it owns (ADR-0014). Set by `AppEnvironment`; `nil` in tests
    /// and in any build where the account surface is not wired, in which case this type behaves
    /// exactly as it did before D-44.
    ///
    /// A closure rather than a stored `AccountController` on purpose: the dependency runs one way
    /// (account knows nothing about StoreKit, StoreKit knows nothing about the account), so neither
    /// type can grow a reference to the other, and every test in `SubscriptionPolicyTests` keeps
    /// working without an account in sight.
    var entitlementSyncHook: (@MainActor ([SyncedEntitlement]) async -> Void)?

    /// Where the account's view of entitlements is read from, for the merge.
    var syncedSnapshotSource: (@MainActor () -> EntitlementSnapshot?)?

    init(defaults: UserDefaults = .standard, clock: Clock = SystemClock()) {
        self.defaults = defaults
        self.clock = clock
        recordFirstLaunchIfNeeded()
    }

    // No `deinit` cancellation: `updatesTask` is main-actor-isolated and `deinit` is not, so
    // touching it there is a concurrency error. This store lives for the process lifetime (one
    // instance on `AppEnvironment`), and `Transaction.updates` must stay subscribed for exactly
    // that long anyway — a cancelled listener silently drops renewals and Ask-to-Buy approvals.
    // `stop()` exists for tests that need to tear one down deterministically.
    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// Begin listening for transactions. Called once at launch, BEFORE any purchase can complete —
    /// StoreKit delivers transactions that finished while the app was closed (an interrupted
    /// purchase, an Ask-to-Buy approval, a renewal) through this stream and nowhere else, so a late
    /// listener silently drops them.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
        Task { await refreshEntitlements() }
    }

    var firstLaunch: Date? {
        defaults.object(forKey: Self.firstLaunchKey) as? Date
    }

    /// The policy input, assembled from what is currently known.
    var policyState: SubscriptionPolicy.State {
        .init(firstLaunch: firstLaunch,
              hasActiveEntitlement: !activeProductIds.isEmpty,
              storeReachable: storeReachable,
              syncedSnapshot: syncedSnapshotSource?())
    }

    /// Where the current entitlement comes from — this device's store, the account, or nothing.
    /// Drives the copy on the paywall and the account screen.
    var entitlementSource: EntitlementMerge.Source {
        policyState.entitlementSource(now: clock.now())
    }

    var access: SubscriptionPolicy.Access {
        SubscriptionPolicy.access(policyState, now: clock.now())
    }

    func allows(_ feature: PremiumFeature) -> Bool {
        SubscriptionPolicy.allows(feature, policyState, now: clock.now())
    }

    /// `nil` = unlimited. The single D-33 gate.
    var exportWindowDays: Int? {
        SubscriptionPolicy.exportWindowDays(policyState, now: clock.now())
    }

    // MARK: - Store

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: SubscriptionProduct.allCases.map(\.rawValue))
            products = SubscriptionProduct.displayOrder.compactMap { wanted in
                loaded.first { $0.id == wanted.rawValue }
            }
            storeReachable = true
            lastError = nil
        } catch {
            // Not fatal and not a lock: a cached entitlement still answers `access`. The paywall
            // shows prices only when it has them, rather than inventing placeholders.
            storeReachable = false
            lastError = String(describing: error)
            Self.logger.error("product load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Returns true when the purchase completed and the entitlement is now active.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // Unverified means the signature did not check out. Never grant on it.
                    lastError = "unverified transaction"
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                return true
            case .userCancelled, .pending:
                // `.pending` is Ask-to-Buy awaiting a parent. Not an error and not a grant — the
                // approval arrives later through `Transaction.updates`, which `start()` is listening
                // to precisely so it is not missed.
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = String(describing: error)
            Self.logger.error("purchase failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Restore. With no accounts this is just a resync against the signed-in Apple ID.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            lastError = String(describing: error)
            Self.logger.error("restore failed: \(String(describing: error), privacy: .public)")
        }
        await refreshEntitlements()
    }

    /// Re-read what the Apple ID currently owns.
    ///
    /// `currentEntitlements` already excludes expired subscriptions and refunded purchases, so an
    /// entitlement that has genuinely lapsed disappears here without this code needing to compare
    /// dates itself — which is the correct division of labour, since the device clock is not
    /// trustworthy for enforcement.
    func refreshEntitlements() async {
        await refreshEntitlements(forcingSync: false)
    }

    /// Re-read the store and push upward unconditionally.
    ///
    /// Called right after a sign-in. The change-detection below is the right default for the
    /// recurring case, but it makes the FIRST push after signing in impossible: a user who already
    /// owned the subscription before they made an account has an `activeProductIds` that has not
    /// changed in a long time and never will, so nothing would ever be reported and their other
    /// platform would stay locked.
    func syncEntitlementsNow() async {
        await refreshEntitlements(forcingSync: true)
    }

    private func refreshEntitlements(forcingSync: Bool) async {
        var active: Set<String> = []
        var synced: [SyncedEntitlement] = []
        let now = clock.now()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard transaction.revocationDate == nil else { continue }
            active.insert(transaction.productID)
            // `expirationDate` is nil for a non-consumable, which is exactly the lifetime tier. The
            // flag is derived from the ABSENCE of an expiry rather than by string-matching the
            // product id, so a future non-consumable does not need this line edited to be handled
            // correctly.
            synced.append(SyncedEntitlement(platform: .ios,
                                            productId: transaction.productID,
                                            isLifetime: transaction.expirationDate == nil,
                                            expiresAt: transaction.expirationDate,
                                            observedAt: now))
        }
        let changed = active != activeProductIds
        activeProductIds = active

        // Pushed only when this device's view actually changed. `refreshEntitlements` runs on every
        // launch, every foreground and every transaction update; pushing unconditionally would put
        // a network call on all of them for a value that almost never moves.
        //
        // The empty list is pushed too — see `AccountClient.pushEntitlement`. "I looked and there
        // is nothing" is the update that lets a cancellation propagate.
        if changed || forcingSync, let hook = entitlementSyncHook {
            await hook(synced)
        }
    }

    private func recordFirstLaunchIfNeeded() {
        guard defaults.object(forKey: Self.firstLaunchKey) == nil else { return }
        defaults.set(clock.now(), forKey: Self.firstLaunchKey)
    }
}
