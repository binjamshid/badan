import XCTest
@testable import BADAN

/// A21/ADR-0010, D-26 — "never for treatment decisions" is mandatory, load-bearing copy on every
/// glucose surface. Mirrors `DeviationEngineTests.testDisclaimerIsThePersistentMedicalFooter`'s
/// shape: the wording is asserted here (bilingual, both surfaces that carry it), and the STRUCTURAL
/// guarantee that it renders wherever a glucose value is shown lives in `GlucoseDisclaimer.applies
/// (to:)`, which `MetricDetailScreen` consults unconditionally (see that screen's own `content(_:)`)
/// — asserted below via the pure gating function rather than by inspecting SwiftUI view bodies,
/// the same boundary every other disclaimer test in this codebase draws.
final class GlucoseDisclaimerTests: XCTestCase {

    // MARK: - The value-surface disclaimer (GlucoseDisclaimer.text, rendered by
    // GlucoseDisclaimerFooter on MetricDetailScreen)

    func testDisclaimerCarriesTheRequiredPhraseInBothLanguages() {
        XCTAssertTrue(GlucoseDisclaimer.text.en.contains("never for treatment decisions"),
                      "the exact required phrase (A21/D-26) is mandatory, not paraphrasable")
        XCTAssertTrue(GlucoseDisclaimer.text.ar.contains("قرار علاجي"),
                      "the Arabic mirror of 'treatment decision' must be present")
        XCTAssertFalse(GlucoseDisclaimer.text.en.isEmpty)
        XCTAssertFalse(GlucoseDisclaimer.text.ar.isEmpty)
        XCTAssertNotEqual(GlucoseDisclaimer.text.en, GlucoseDisclaimer.text.ar,
                          "Arabic must not be a copy of the English string")
        XCTAssertTrue(GlucoseDisclaimer.text.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) })
    }

    /// A copy lint over the disclaimer itself: it must read as wellness-safe, never as clinical
    /// guidance dressed up as a caveat — mirrors `DeviationEngineTests
    /// .testAnnotationsCarryNoAlarmOrDiagnosisFrames`.
    func testDisclaimerCarriesNoDosingOrAlarmLanguage() {
        let en = GlucoseDisclaimer.text.en.lowercased()
        for phrase in ["dose", "dosing", "you should", "abnormal", "danger", "urgent", "warning"] {
            XCTAssertFalse(en.contains(phrase), "disclaimer contains banned frame \"\(phrase)\": \(en)")
        }
    }

    // MARK: - The gating function MetricDetailScreen consults

    func testAppliesToTheGlucoseMetricOnly() {
        XCTAssertTrue(GlucoseDisclaimer.applies(to: MetricID.glucose))
        XCTAssertFalse(GlucoseDisclaimer.applies(to: MetricID.weight),
                       "a non-glucose metric must never pick up glucose's disclaimer")
        XCTAssertFalse(GlucoseDisclaimer.applies(to: MetricID.spo2))
        XCTAssertFalse(GlucoseDisclaimer.applies(to: "unknown.metric"))
    }

    // MARK: - The permission-explainer surface (HealthPermissionBundle.glucose.boundary)

    /// D-26's migration-impact line says the phrase is load-bearing on every glucose surface, not
    /// only where the value itself renders — the permission explainer that names glucose by name
    /// is one such surface, so it carries the identical guarantee.
    func testPermissionBundleBoundaryAlsoCarriesTheRequiredPhrase() {
        XCTAssertTrue(HealthPermissionBundle.glucose.boundary.en.contains("never for treatment decisions"))
        XCTAssertTrue(HealthPermissionBundle.glucose.boundary.ar.contains("قرار علاجي"))
    }

    func testGlucoseBundleReadsNameGlucoseExplicitly() {
        XCTAssertTrue(HealthPermissionBundle.glucose.reads.contains {
            $0.en.localizedCaseInsensitiveContains("glucose")
        })
    }
}
