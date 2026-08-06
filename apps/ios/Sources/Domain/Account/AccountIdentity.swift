import Foundation

/// Everything BADAN knows about an account (ADR-0014 / D-44).
///
/// Read the field list, because it is the whole argument for why this reversal is survivable: an
/// account id, when it was made, a referral code, a count. There is no name, no email, no Apple
/// identifier, no device list, no health datum, and no field into which one could be smuggled
/// without changing this type and failing `AccountPayloadShapeTests`.
///
/// Sign in with Apple returns a name and an email on first authorisation. BADAN asks for neither
/// scope and discards what arrives anyway — see `AppleSignInController`. The server stores a salted
/// hash of Apple's subject claim purely so a second sign-in resolves to the same account, and never
/// the claim itself.
public struct AccountIdentity: Equatable, Sendable, Codable {
    /// Server-minted, opaque, and unrelated to anything Apple issued.
    public var accountId: String
    public var createdAt: Date
    /// This account's own referral code (`ReferralPolicy`).
    public var referralCode: String
    /// How many claims of `referralCode` have been rewarded.
    public var successfulReferrals: Int
    /// Whether this account has already redeemed someone else's code. One per account, forever.
    public var hasClaimedReferral: Bool

    public init(accountId: String, createdAt: Date, referralCode: String,
                successfulReferrals: Int = 0, hasClaimedReferral: Bool = false) {
        self.accountId = accountId
        self.createdAt = createdAt
        self.referralCode = referralCode
        self.successfulReferrals = successfulReferrals
        self.hasClaimedReferral = hasClaimedReferral
    }

    public var claimContext: ReferralPolicy.ClaimContext {
        .init(ownCode: referralCode, accountCreatedAt: createdAt,
              hasAlreadyClaimed: hasClaimedReferral)
    }
}

/// Whether this install is signed in, and what it last learned.
///
/// `signedOut` is a first-class, fully-functional state, not an error and not a wall. BADAN works
/// exactly as it did before ADR-0014 when signed out: every reading, every derivation, every export
/// within the D-33 window, every log. Signing in buys precisely two things — a subscription that
/// follows you to another platform, and referrals. Nothing else in the app may ever require it, and
/// there is no case here that could express "blocked until you sign in".
public enum AccountState: Equatable, Sendable {
    case signedOut
    case signedIn(AccountIdentity)

    public var identity: AccountIdentity? {
        if case .signedIn(let identity) = self { return identity }
        return nil
    }

    public var isSignedIn: Bool { identity != nil }
}
