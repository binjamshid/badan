import XCTest
@testable import BADAN

final class SettingsLegalLinksTests: XCTestCase {
    func testSettingsLinksToTheExistingTermsAndPrivacyDocuments() {
        XCTAssertEqual(SettingsStrings.termsURL.absoluteString,
                       "https://badan.binjamshid.com/eula.html")
        XCTAssertEqual(SettingsStrings.privacyURL.absoluteString,
                       "https://badan.binjamshid.com/privacy.html")
    }

    func testLegacyBillingLinkOpensAppleSubscriptions() {
        XCTAssertEqual(SettingsStrings.manageSubscriptionsURL.absoluteString,
                       "https://apps.apple.com/account/subscriptions")
    }

    func testSettingsLinksHaveBilingualLabels() {
        for label in [SettingsStrings.termsTitle, SettingsStrings.privacyWebsiteTitle,
                      SettingsStrings.manageSubscriptionsTitle] {
            XCTAssertFalse(label.en.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(label.ar.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertNotEqual(label.en, label.ar)
        }
    }
}
