import UIKit
import XCTest
@testable import BADAN

/// The guard that would have caught the v0.2.0 family drift on arrival.
///
/// `MetricFamily.init(rawValueOrOther:)` falls back to `.other` for an unrecognised family string,
/// which is the right *runtime* behaviour — the registry is allowed to describe families a given
/// build has not enumerated yet, and an unknown family must never crash a browse screen. But the
/// fallback is silent, and it hid a real regression: registry v0.2.0 introduced seven families at
/// once (workout, readiness, effort, hydration, stress, cycle, lab) and 22 of the 72 metrics — a
/// third of the catalogue — rendered under a single "Other" pillar with the generic grid glyph.
/// Nothing failed. The build was green, the tests passed, and the only symptom was on screen.
///
/// So the fallback stays, and these tests assert separately that nothing is *currently* using it.
/// The distinction matters: this is a contract-mirror check, not a behavioural one. When the
/// registry next adds a family, this fails and names it, instead of the app quietly filing it
/// under "Other" until somebody happens to look at the Body screen.
///
/// The Android mirror is `MetricFamilyParityTest.kt`. Each side checks its own platform only —
/// nothing here can see the Kotlin enum, so the two case lists are kept in step by the note on
/// each enum, not by an assertion.
final class MetricFamilyParityTests: XCTestCase {

    private var registryFamilies: Set<String> {
        Set(MetricRegistry.shared.all.map(\.family))
    }

    func testEveryRegistryFamilyHasAnEnumCase() {
        let unmapped = registryFamilies
            .filter { MetricFamily(rawValueOrOther: $0) == .other && $0 != "other" }
            .sorted()

        XCTAssertTrue(unmapped.isEmpty,
                      """
                      registry.json declares \(unmapped.count) family/families with no MetricFamily \
                      case: \(unmapped) — each one's metrics collapse into the 'Other' pillar with a \
                      generic icon. Add the case (name in en AND ar, plus an SF Symbol) rather than \
                      deleting this assertion.
                      """)
    }

    /// The registry is the reason the enum exists; an empty read would make the test vacuous, and
    /// a registry that failed to load reads as "no unmapped families" to the assertion above.
    func testTheRegistryActuallyDeclaresFamilies() {
        XCTAssertGreaterThan(registryFamilies.count, 5, "sanity: registry.json declared no families")
    }

    /// A bad SF Symbol name is not a build error — `Image(systemName:)` renders an empty frame, so
    /// the icon silently vanishes in shipped UI. This resolves each one the way UIKit will, which
    /// also pins the names to what actually exists at the iOS 17 deployment target rather than to
    /// whatever the authoring machine's SF Symbols version happened to have.
    func testEveryFamilySymbolResolves() {
        for family in MetricFamily.allCases {
            XCTAssertNotNil(UIImage(systemName: family.symbolName),
                            "\(family.rawValue) uses SF Symbol '\(family.symbolName)', which does not resolve")
        }
    }

    /// Family labels are group headers on the Body screen, so an untranslated one is visible to an
    /// Arabic reader on the first surface they open. Same completeness bar
    /// `WorkoutSurfaceTests.testFamilyExplainersAreCompleteAndBilingual` holds family copy to.
    func testEveryFamilyNameIsBilingual() {
        for family in MetricFamily.allCases {
            let name = family.displayName
            XCTAssertFalse(name.en.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(family.rawValue) has no English name")
            XCTAssertFalse(name.ar.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(family.rawValue) has no Arabic name")
            XCTAssertNotEqual(name.en, name.ar, "\(family.rawValue) is untranslated")
            XCTAssertTrue(name.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(family.rawValue)'s Arabic name has no Arabic script")
        }
    }

    /// `.other` must stay last: `BodyScreen.orderIndex` sorts pillars by `allCases` position and
    /// treats the unknown bucket as the tail. If someone appends a real family after it, that
    /// family sorts *below* "Other", which reads as a rendering bug rather than an ordering one.
    func testOtherSortsLast() {
        XCTAssertEqual(MetricFamily.allCases.last, .other)
    }
}
