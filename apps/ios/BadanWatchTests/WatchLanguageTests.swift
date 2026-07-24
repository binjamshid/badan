import XCTest
@testable import BadanWatch

/// `WatchLanguage.isArabic` mirrors `BadanWidgets.WidgetLanguage.isArabic` exactly (see that type's
/// own doc for the rationale) — pinned here independently since this target cannot import that
/// file's tests either.
final class WatchLanguageTests: XCTestCase {
    private func snapshot(language: String) -> AmbientSnapshotDto {
        AmbientSnapshotDto(generatedAt: .now, language: language, readiness: nil, sentence: nil,
                           sleep: nil, medsDue: nil, effort: nil)
    }

    func testSnapshotLanguageIsAuthoritativeWhenPresent() {
        XCTAssertTrue(WatchLanguage.isArabic(for: snapshot(language: "ar"), preferredLanguages: ["en-US"]))
        XCTAssertFalse(WatchLanguage.isArabic(for: snapshot(language: "en"), preferredLanguages: ["ar-SA"]))
    }

    func testFallsBackToDeviceLocaleWhenNoSnapshotHasEverBeenReceived() {
        XCTAssertTrue(WatchLanguage.isArabic(for: nil, preferredLanguages: ["ar-SA"]))
        XCTAssertFalse(WatchLanguage.isArabic(for: nil, preferredLanguages: ["en-US"]))
    }

    /// A language code that merely STARTS with "ar" (Mapudungun, "arn") must not false-match a
    /// naive prefix check — only the exact leading subtag counts.
    func testDoesNotFalseMatchALanguageCodeThatMerelyStartsWithAr() {
        XCTAssertFalse(WatchLanguage.isArabic(for: nil, preferredLanguages: ["arn-CL"]))
    }

    func testEmptyPreferredLanguagesDefaultsToNotArabic() {
        XCTAssertFalse(WatchLanguage.isArabic(for: nil, preferredLanguages: []))
    }
}
