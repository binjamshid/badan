import StoreKit
import XCTest
@testable import BADAN

/// App Store Review Guideline 3.1.2(c) — the information an app offering auto-renewable
/// subscriptions MUST show inside the app itself.
///
/// 1.1(4) was rejected for exactly one of these: no functional link to the Terms of Use. These
/// tests exist because that requirement is invisible at compile time — a paywall with no EULA link
/// builds, runs, looks fine, and gets rejected a week later.
final class PaywallRequiredInfoTests: XCTestCase {

    /// The rejection reason, pinned. Both links are required; only the EULA was cited, and fixing
    /// only what was cited is how an app gets rejected twice.
    func testThePaywallLinksToBothTheTermsOfUseAndThePrivacyPolicy() {
        XCTAssertEqual(PaywallCopy.termsURL.absoluteString,
                       "https://badan.binjamshid.com/eula.html")
        XCTAssertEqual(PaywallCopy.privacyURL.absoluteString,
                       "https://badan.binjamshid.com/privacy.html")
    }

    /// The links must be HTTPS and absolute, or they are not "functional links" — a relative path
    /// or a bare host would open nothing.
    func testTheLegalLinksAreAbsoluteHttpsURLs() {
        for url in [PaywallCopy.termsURL, PaywallCopy.privacyURL] {
            XCTAssertEqual(url.scheme, "https", "\(url) must be HTTPS")
            XCTAssertNotNil(url.host, "\(url) must be absolute")
            XCTAssertFalse(url.path.isEmpty, "\(url) must point at a document")
        }
    }

    /// Both links must carry visible, translated labels. An unlabelled or English-only link is not
    /// a functional link for an Arabic reader, and Arabic is a first-order concern here.
    func testTheLegalLinksHaveRealBilingualLabels() {
        for label in [PaywallCopy.termsLink, PaywallCopy.privacyLink] {
            XCTAssertFalse(label.en.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(label.ar.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertNotEqual(label.en, label.ar, "the Arabic label must be translated, not copied")
        }
    }

    /// The renewal disclosure has to say it renews automatically and can be cancelled — the other
    /// half of what 3.1.2(c) expects the purchase flow to state.
    func testTheRenewalDisclosureStatesAutomaticRenewalAndCancellation() {
        let english = PaywallCopy.legalNote.en.lowercased()
        XCTAssertTrue(english.contains("renew"), "must say the subscription renews")
        XCTAssertTrue(english.contains("cancel"), "must say it can be cancelled")
        XCTAssertFalse(PaywallCopy.legalNote.ar.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Subscription length

    /// Length must be stated for every unit StoreKit can return, in both languages, and must never
    /// fall back to something that reads as a placeholder.
    func testEverySubscriptionPeriodRendersARealBilingualLabel() {
        let units: [Product.SubscriptionPeriod.Unit] = [.day, .week, .month, .year]
        for unit in units {
            for count in [1, 3] {
                let label = PaywallCopy.periodLabel(unit: unit, value: count)
                XCTAssertFalse(label.en.isEmpty, "\(unit) x\(count) has no English label")
                XCTAssertFalse(label.ar.isEmpty, "\(unit) x\(count) has no Arabic label")
                XCTAssertNotEqual(label.en, "period",
                                  "\(unit) x\(count) fell through to the unknown-unit fallback")
            }
        }
    }

    /// A one-month subscription reads "month", not "1 months" — the singular case is the one that
    /// actually ships, so it is the one most worth getting right.
    func testTheSingularPeriodReadsNaturally() {
        XCTAssertEqual(PaywallCopy.periodLabel(unit: .month, value: 1).en, "month")
        XCTAssertEqual(PaywallCopy.periodLabel(unit: .year, value: 1).en, "year")
        XCTAssertEqual(PaywallCopy.periodLabel(unit: .month, value: 3).en, "3 months")
    }
}
