import Foundation

/// The referral rules, as pure functions (ADR-0014 / D-44).
///
/// A referral grants premium *time*. It never grants data, never unlocks anything a subscription
/// would not, and — importantly — never gates anything new: the D-33 boundary is unchanged, so the
/// worst case for someone who refuses to participate is that they pay for what a referrer got free.
/// Referrals cannot become a mechanism for withholding a user's own records, because there is no
/// enum case here that could express that.
public enum ReferralPolicy {

    /// Characters a code may contain. `0/O`, `1/I/L` and `U/V` are omitted: codes get read aloud,
    /// typed from a screenshot, and passed between people who do not share a first language, and a
    /// code that is ambiguous in any of those settings generates support mail rather than signups.
    public static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTWXYZ")

    public static let codeLength = 8

    /// Premium time each side receives when a claim succeeds.
    public static let grantDays = 30

    /// How many referrals earn the referrer a reward. Beyond this the code still works for new
    /// users — they get their side — but the referrer stops accruing.
    ///
    /// A cap exists because the reward is real money and the cost of minting accounts is a Sign in
    /// with Apple tap. Uncapped, this is a self-service coupon printer; the cap turns the worst case
    /// into a bounded 10 months rather than an unbounded one, and the server enforces it too, since
    /// nothing a client computes about its own reward can be trusted.
    public static let maxRewardedReferrals = 10

    /// How long after account creation a code may still be claimed.
    ///
    /// A referral is an invitation to try BADAN, so it belongs near the start of the relationship. A
    /// year-old account claiming a code is not being referred; it is applying a discount. That may
    /// be a fine thing to sell later, but it is a different product and should be decided as one
    /// rather than arriving as a side effect of the referral window being unbounded.
    public static let claimWindowDays = 30

    /// Why a claim was refused. Every case is something the UI can say plainly — there is no
    /// generic failure, because "that didn't work" is the message that makes people email you.
    /// `Error` so `validateClaim` can return a `Result` — a refusal is the expected outcome of a
    /// mistyped code, not an exceptional one, and nothing here is ever thrown.
    public enum ClaimRefusal: Equatable, Sendable, Error {
        case malformedCode
        case ownCode
        case alreadyClaimed
        case windowClosed(daysAgo: Int)
    }

    /// What the client knows when someone taps Redeem.
    public struct ClaimContext: Equatable, Sendable {
        public var ownCode: String?
        public var accountCreatedAt: Date
        public var hasAlreadyClaimed: Bool

        public init(ownCode: String?, accountCreatedAt: Date, hasAlreadyClaimed: Bool) {
            self.ownCode = ownCode
            self.accountCreatedAt = accountCreatedAt
            self.hasAlreadyClaimed = hasAlreadyClaimed
        }
    }

    /// Client-side pre-flight. The server re-checks every one of these and owns the real answer —
    /// this exists so an obviously-wrong code fails instantly and offline, not so the client can be
    /// believed. Anything this permits may still be refused by the server; nothing this refuses is
    /// worth a round trip.
    public static func validateClaim(_ raw: String, context: ClaimContext,
                                     now: Date) -> Result<String, ClaimRefusal> {
        let code = normalise(raw)
        guard isWellFormed(code) else { return .failure(.malformedCode) }
        // Compared after normalisation on both sides, so `badan-2f3k` pasted with the user's own
        // code in a different case is still caught here rather than by a server round trip.
        if let own = context.ownCode, normalise(own) == code { return .failure(.ownCode) }
        if context.hasAlreadyClaimed { return .failure(.alreadyClaimed) }

        let elapsed = now.timeIntervalSince(context.accountCreatedAt)
        // Treat a device clock behind the server as a newly created account.
        let daysOld = Int(max(0, elapsed) / 86_400)
        guard daysOld < claimWindowDays else { return .failure(.windowClosed(daysAgo: daysOld)) }

        return .success(code)
    }

    /// Pull the code out of whatever the user pasted.
    ///
    /// A plain strip-and-uppercase is not enough, and the test that caught it is
    /// `testACodeSurvivesLowercaseHyphensAndSurroundingText`. Stripping every non-alphabet
    /// character from `badan.app/r/2F3K-9WXY` yields `BADANAPPR2F3K9WXY` — seventeen characters,
    /// reported as malformed, for an input that plainly contains a valid code. The same happens to
    /// `Your code: 2F3K-9WXY` pasted out of a message, which is most of how a code actually
    /// travels.
    ///
    /// So: split on anything that is neither an alphabet character nor the display hyphen, drop
    /// the hyphens, and take the FIRST run of exactly `codeLength`. First rather than last because
    /// a code leads its sentence at least as often as it trails one (`2F3K-9WXY is my code`), and
    /// deterministic beats clever.
    ///
    /// Falls back to the plain strip when no run is the right length, so a bare `2F3K9WXY` still
    /// works and genuinely wrong input still reports as malformed rather than silently matching
    /// some fragment of itself.
    public static func normalise(_ raw: String) -> String {
        let allowed = Set(alphabet)
        let upper = raw.uppercased()
        let candidates = upper
            .split(whereSeparator: { !allowed.contains($0) && $0 != "-" })
            .map { String($0.filter { allowed.contains($0) }) }
        if let match = candidates.first(where: { $0.count == codeLength }) { return match }
        return String(upper.filter { allowed.contains($0) })
    }

    public static func isWellFormed(_ normalised: String) -> Bool {
        normalised.count == codeLength && normalised.allSatisfy(Set(alphabet).contains)
    }

    /// Display form: `2F3K-9WXY`. Grouping is presentation only — `normalise` removes it again, so
    /// nothing downstream ever has to know about the hyphen.
    public static func formatted(_ code: String) -> String {
        let c = normalise(code)
        guard c.count == codeLength else { return c }
        let mid = c.index(c.startIndex, offsetBy: codeLength / 2)
        return "\(c[c.startIndex..<mid])-\(c[mid...])"
    }

    /// How much premium time a referrer has actually earned, given how many claims landed.
    ///
    /// Mirrored exactly by the server, which is authoritative. Duplicated here only so the referral
    /// screen can show "3 of 10 rewarded" without a round trip.
    public static func referrerGrantDays(successfulReferrals: Int) -> Int {
        max(0, min(successfulReferrals, maxRewardedReferrals)) * grantDays
    }
}
