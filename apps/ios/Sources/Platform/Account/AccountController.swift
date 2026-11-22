import Foundation
import os

/// Ties Sign in with Apple, the account service, and the local cache together (ADR-0014 / D-44).
/// Cached account state supports referrals even if a refresh fails.
@MainActor
@Observable
final class AccountController {
    private static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Account")

    private(set) var state: AccountState = .signedOut
    private(set) var snapshot: EntitlementSnapshot?
    private(set) var isBusy = false
    /// Set for the UI when something failed. Never contains a server body or an identifier.
    private(set) var lastError: AccountClientError?

    private let client: AccountClient
    private let signInProvider: AppleSignInProviding
    private let cache: AccountCacheStoring
    private let session: AccountSessionStoring
    private let clock: Clock

    init(client: AccountClient = AccountClient(),
         signInProvider: AppleSignInProviding? = nil,
         cache: AccountCacheStoring = DefaultsAccountCacheStore(),
         session: AccountSessionStoring = KeychainAccountSessionStore(),
         clock: Clock = SystemClock()) {
        self.client = client
        // Built lazily on the main actor rather than as a default argument, because
        // `AppleSignInController` is `@MainActor` and a default argument is evaluated at the call
        // site, which need not be.
        self.signInProvider = signInProvider ?? AppleSignInController()
        self.cache = cache
        self.session = session
        self.clock = clock
        restoreFromCache()
    }

    /// Load what the last launch knew, before any network call.
    ///
    /// A signed-in state requires BOTH a cached identity and a session token. If the Keychain item
    /// is gone but the defaults cache survives — a restore from a backup that excluded the Keychain
    /// is exactly this — the app reports signed out rather than showing an account it cannot act on.
    private func restoreFromCache() {
        snapshot = cache.snapshot()
        if let identity = cache.identity(), session.token() != nil {
            state = .signedIn(identity)
        } else {
            state = .signedOut
            // The snapshot is kept deliberately. It still grants inside `offlineGraceDays`, and a
            // user whose Keychain did not survive a restore should not lose a subscription they are
            // still paying for on another platform before they get a chance to sign in again.
        }
    }

    // MARK: - Sign in / out

    @discardableResult
    func signIn() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let apple = try await signInProvider.signIn()
            let response = try await client.signIn(apple)
            apply(response)
            return true
        } catch AppleSignInError.cancelled {
            // Not an error. The user closed a sheet.
            return false
        } catch let error as AccountClientError {
            lastError = error
            Self.logger.error("sign-in failed: \(String(describing: error), privacy: .public)")
            return false
        } catch {
            lastError = .transportError
            Self.logger.error("sign-in failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Sign out on this device. The account is untouched server-side, and
    /// signing in again restores them.
    ///
    /// Clears the cached snapshot as well as the credential. Keeping a snapshot after a deliberate
    /// sign-out would mean the user's stated intent ("stop using the account on this device") left
    /// an entitlement quietly granting for up to `offlineGraceDays` — the one case where dropping
    /// access is what was actually asked for.
    func signOut() {
        client.signOutLocally()
        cache.clear()
        state = .signedOut
        snapshot = nil
        lastError = nil
    }

    /// Delete the account server-side, then clear everything local.
    ///
    /// Ordered so a server failure leaves the user signed in and told, rather than signed out and
    /// believing their data is gone when it is not (App Review 5.1.1(v) wants the deletion to be
    /// real, and a local-only clear that reports success would be the dishonest version of it).
    @discardableResult
    func deleteAccount() async -> Bool {
        guard !isBusy, state.isSignedIn else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            try await client.deleteAccount()
        } catch AccountClientError.unauthorized {
            // Already gone server-side. Falling through to the local clear is correct: the end
            // state the user asked for is the end state they get.
        } catch let error as AccountClientError {
            lastError = error
            return false
        } catch {
            lastError = .transportError
            return false
        }
        signOut()
        return true
    }

    // MARK: - Sync

    /// Pull the latest account state. Safe to call on every foreground.
    @discardableResult
    func refresh() async -> Bool {
        guard state.isSignedIn else { return false }
        do {
            apply(try await client.refresh())
            return true
        } catch AccountClientError.unauthorized {
            // The session is dead — deleted elsewhere, or revoked. Signing out locally is the only
            // correct response; retrying cannot succeed.
            Self.logger.notice("account session rejected; signing out locally")
            signOut()
            return false
        } catch {
            // Everything else is left alone on purpose. The cached snapshot keeps answering.
            lastError = error as? AccountClientError ?? .transportError
            return false
        }
    }

    // MARK: - Referrals

    /// Redeem a code. Returns the refusal when one applies, `nil` on success.
    func claimReferral(_ raw: String) async -> ReferralPolicy.ClaimRefusal? {
        guard let identity = state.identity else { return .malformedCode }

        // Local pre-flight first: an obviously-bad code should fail instantly and offline. The
        // server re-checks all of it and is authoritative — this only avoids a round trip.
        switch ReferralPolicy.validateClaim(raw, context: identity.claimContext, now: clock.now()) {
        case .failure(let refusal):
            return refusal
        case .success(let code):
            do {
                apply(try await client.claimReferral(code: code))
                return nil
            } catch AccountClientError.referralRefused(let reason) {
                return Self.refusal(fromServer: reason)
            } catch AccountClientError.unauthorized {
                signOut()
                return .malformedCode
            } catch {
                lastError = error as? AccountClientError ?? .transportError
                return nil
            }
        }
    }

    /// Map the server's closed reason set onto the local one, so the UI has a single vocabulary.
    /// An unrecognised reason falls back to `malformedCode` rather than crashing or inventing a
    /// case — the server is allowed to be newer than the app.
    private static func refusal(fromServer reason: String) -> ReferralPolicy.ClaimRefusal {
        switch reason {
        case "own_code": return .ownCode
        case "already_claimed": return .alreadyClaimed
        case "window_closed": return .windowClosed(daysAgo: ReferralPolicy.claimWindowDays)
        default: return .malformedCode
        }
    }

    // MARK: -

    private func apply(_ response: AccountStateResponse) {
        let identity = response.identity
        let fresh = response.snapshot(syncedAt: clock.now())
        state = .signedIn(identity)
        snapshot = fresh
        cache.store(identity: identity, snapshot: fresh)
        lastError = nil
    }
}
