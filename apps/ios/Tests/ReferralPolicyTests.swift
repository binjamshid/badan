import XCTest
@testable import BADAN

/// The referral rules (ADR-0014 / D-44).
///
/// These are pre-flight checks — the server re-checks every one and owns the real answer — so what
/// is being tested here is that an obviously-wrong code fails instantly and offline, and that the
/// normalisation is forgiving enough that a code shared by voice, screenshot or paste all land in
/// the same place.
final class ReferralPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

    private func context(own: String? = "2F3K9WXY", createdDaysAgo: Double = 1,
                         claimed: Bool = false) -> ReferralPolicy.ClaimContext {
        .init(ownCode: own, accountCreatedAt: days(-createdDaysAgo), hasAlreadyClaimed: claimed)
    }

    private func refusal(_ raw: String,
                         _ context: ReferralPolicy.ClaimContext) -> ReferralPolicy.ClaimRefusal? {
        switch ReferralPolicy.validateClaim(raw, context: context, now: now) {
        case .failure(let refusal): return refusal
        case .success: return nil
        }
    }

    // MARK: - Normalisation

    func testACodeSurvivesLowercaseHyphensAndSurroundingText() {
        // All the ways a code actually arrives: typed lowercase, pasted with the display hyphen,
        // copied out of a URL.
        for raw in ["2F3K9WXY", "2f3k9wxy", "2F3K-9WXY", "  2f3k-9wxy  ",
                    "badan.app/r/2F3K-9WXY", "Your code: 2F3K-9WXY", "2F3K-9WXY is my code"] {
            XCTAssertNil(refusal(raw, context(own: nil)), "rejected: \(raw)")
            XCTAssertEqual(ReferralPolicy.normalise(raw), "2F3K9WXY", "mis-extracted: \(raw)")
        }
    }

    func testTextWithNoCodeInItIsStillMalformed() {
        // The fallback must not turn arbitrary prose into a code by finding some fragment of it.
        for raw in ["", "hello", "no code here at all", "2F3K"] {
            XCTAssertEqual(refusal(raw, context(own: nil)), .malformedCode, "accepted: \(raw)")
        }
    }

    func testTheAlphabetExcludesEveryAmbiguousCharacter() {
        // 0/O, 1/I/L and U/V are the pairs that get transcribed wrong when a code is read aloud or
        // copied off a screenshot, which is most of how a referral code travels.
        for character in "01OILUV" {
            XCTAssertFalse(ReferralPolicy.alphabet.contains(character),
                           "\(character) is ambiguous and must not be in the alphabet")
        }
    }

    func testFormattingIsPresentationOnlyAndRoundTrips() {
        let code = "2F3K9WXY"
        XCTAssertEqual(ReferralPolicy.formatted(code), "2F3K-9WXY")
        XCTAssertEqual(ReferralPolicy.normalise(ReferralPolicy.formatted(code)), code)
    }

    // MARK: - Refusals

    func testACodeOfTheWrongLengthIsRefused() {
        XCTAssertEqual(refusal("2F3K", context()), .malformedCode)
        XCTAssertEqual(refusal("2F3K9WXY2", context()), .malformedCode)
    }

    func testACodeContainingOnlyAmbiguousCharactersIsRefused() {
        // Filtered to empty by `normalise`, which must read as malformed rather than as valid.
        XCTAssertEqual(refusal("OOOOIIII", context()), .malformedCode)
    }

    func testAnAccountCannotClaimItsOwnCode() {
        XCTAssertEqual(refusal("2F3K9WXY", context(own: "2F3K9WXY")), .ownCode)
    }

    func testOwnCodeIsCaughtRegardlessOfHowItWasTyped() {
        // Compared after normalisation on both sides, so this fails locally rather than costing a
        // round trip to be told something the client already knew.
        XCTAssertEqual(refusal("2f3k-9wxy", context(own: "2F3K9WXY")), .ownCode)
    }

    func testASecondClaimIsRefused() {
        XCTAssertEqual(refusal("MNPQRSTW", context(claimed: true)), .alreadyClaimed)
    }

    func testTheClaimWindowClosesAfterThirtyDays() {
        XCTAssertNil(refusal("MNPQRSTW",
                             context(createdDaysAgo: Double(ReferralPolicy.claimWindowDays) - 1)))
        XCTAssertEqual(refusal("MNPQRSTW",
                               context(createdDaysAgo: Double(ReferralPolicy.claimWindowDays))),
                       .windowClosed(daysAgo: ReferralPolicy.claimWindowDays))
    }

    func testAnAccountCreatedInTheFutureIsTreatedAsBrandNew() {
        // A backwards clock is not evidence of anything, and locking someone out of a referral over
        // one is a support ticket they cannot resolve.
        XCTAssertNil(refusal("MNPQRSTW", context(createdDaysAgo: -400)))
    }

    // MARK: - Rewards

    func testTheReferrerRewardIsCapped() {
        XCTAssertEqual(ReferralPolicy.referrerGrantDays(successfulReferrals: 0), 0)
        XCTAssertEqual(ReferralPolicy.referrerGrantDays(successfulReferrals: 3),
                       3 * ReferralPolicy.grantDays)
        XCTAssertEqual(
            ReferralPolicy.referrerGrantDays(successfulReferrals: ReferralPolicy.maxRewardedReferrals + 50),
            ReferralPolicy.maxRewardedReferrals * ReferralPolicy.grantDays)
    }

    func testANegativeCountCannotProduceNegativeDays() {
        XCTAssertEqual(ReferralPolicy.referrerGrantDays(successfulReferrals: -5), 0)
    }

    // MARK: - Constants shared with the server

    func testTheConstantsMatchTheServersOwn() {
        // Mirrored by hand in `backend/api/accounts.py` and in the Kotlin port. A drift here is a
        // code one platform mints and another refuses, which is invisible until a user reports it.
        XCTAssertEqual(ReferralPolicy.codeLength, 8)
        XCTAssertEqual(ReferralPolicy.grantDays, 30)
        XCTAssertEqual(ReferralPolicy.maxRewardedReferrals, 10)
        XCTAssertEqual(ReferralPolicy.claimWindowDays, 30)
        XCTAssertEqual(String(ReferralPolicy.alphabet), "23456789ABCDEFGHJKMNPQRSTWXYZ")
    }
}
