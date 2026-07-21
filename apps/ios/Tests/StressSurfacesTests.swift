import Foundation
import XCTest
@testable import BADAN

/// EPIC-34 stress SURFACE — the Health Monitor card over the Stage-2 engine.
///
/// The engine's suite proves the gate; this proves the card cannot talk its way around it. Three
/// properties, each of which a UI layer could break on its own:
///
/// 1. **A hidden surface renders a fact about the DEVICE** — never user failure, never a BADAN
///    error, and with no number of any kind.
/// 2. **Every rendered trend carries the window it describes**, so a daily value can never be read
///    as a live one.
/// 3. **The number is power-only.** A 0–100 index printed large next to sparse sampling is the
///    false precision this epic exists to refuse; casual gets a direction and a sentence.
final class StressSurfacesTests: XCTestCase {
    private let format = ValueFormatter(profile: CustomizationProfile(), registry: .shared)

    private func trend(value: Double = 62, band: StressTrendBand = .higherThanUsual,
                       state: StressDensityState = .moderate, confidence: Double = 0.4,
                       provisional: Bool = true, daysPresent: Int = 5,
                       windowDays: Int = 7) -> StressTrend {
        StressTrend(
            dayKey: "2026-07-21", value: value, band: band, confidence: confidence,
            provisional: provisional, densityState: state,
            density: StressDensity(samplesPerHour: 0.62, daytimeSamples: 44, daytimeHours: 71,
                                   daysWithSamples: 6, windowDays: 7),
            daysPresent: daysPresent, windowDays: windowDays, contributions: [])
    }

    // MARK: - The hidden state

    /// Every absence reason is a statement about the data or the device. The engine owns the
    /// sentence (`StressAbsenceReason.explanation`) so an absence has no code path that reaches the
    /// screen unexplained; this asserts the card actually speaks it, in both languages.
    func testEveryHiddenReasonSpeaksTheDeviceFactualExplanation() {
        for reason in StressAbsenceReason.allCases {
            for language in [AppLanguage.en, .ar] {
                let spoken = StressPresentation.spokenLabel(.hidden(reason: reason), depth: .power,
                                                            language: language, format: format)
                XCTAssertTrue(spoken.contains(reason.explanation.resolved(language)),
                              "\(reason.rawValue) is hidden without saying why in \(language.rawValue)")
            }
        }
    }

    /// A hidden card shows NO number, at either altitude. `.hidden` carries only the reason — it
    /// holds no `StressDensity` — so there is nothing for a surface to rebuild a reading out of.
    func testAHiddenCardShowsNoNumberAtEitherAltitude() {
        for reason in StressAbsenceReason.allCases {
            for depth in [DepthPolicy.casual, .power] {
                let spoken = StressPresentation.spokenLabel(.hidden(reason: reason), depth: depth,
                                                            language: .en, format: format)
                XCTAssertFalse(spoken.contains(where: \.isNumber),
                               "\(reason.rawValue) at \(depth.rawValue) leaked a number: \(spoken)")
            }
        }
    }

    /// The insufficient state must read as a fact about the device, never as user failure and never
    /// as a BADAN error. These are the frames that would break that.
    func testAbsenceCopyBlamesNeitherTheUserNorTheApp() {
        let bannedEn = ["you didn't", "you did not", "you failed", "you need to wear", "error",
                        "sorry", "something went wrong", "unavailable right now", "try again",
                        "not supported", "unsupported"]
        let bannedAr = ["خطأ", "فشل", "عذراً", "حاول مرة أخرى", "غير مدعوم"]
        for reason in StressAbsenceReason.allCases {
            let en = reason.explanation.en.lowercased()
            for phrase in bannedEn {
                XCTAssertFalse(en.contains(phrase),
                               "\(reason.rawValue) contains the banned frame \"\(phrase)\": \(reason.explanation.en)")
            }
            for phrase in bannedAr {
                XCTAssertFalse(reason.explanation.ar.contains(phrase),
                               "\(reason.rawValue) Arabic contains the banned frame \"\(phrase)\"")
            }
            XCTAssertFalse(reason.explanation.ar.isEmpty)
            XCTAssertNotEqual(reason.explanation.en, reason.explanation.ar, "\(reason.rawValue) is untranslated")
        }
    }

    /// The default for Apple-Watch-only data names the device's sampling, which is the whole reason
    /// this epic is a gate before it is a score.
    func testTheDefaultSparseReasonNamesTheDeviceNotTheUser() {
        let text = StressAbsenceReason.daytimeHrvTooSparse.explanation.en
        XCTAssertTrue(text.lowercased().contains("your device"), text)
    }

    // MARK: - The window, on every rendered trend

    func testEveryRenderedTrendStatesItsWindowAndDisclaimsBeingLive() {
        for language in [AppLanguage.en, .ar] {
            let note = StressPresentation.windowNote(trend(), language: language, format: format)
            XCTAssertTrue(note.contains(StressPresentation.dayCount(7, language: language, format: format)),
                          "the window length travels with the value: \(note)")
            let disclaimer = language == .en ? "not a reading for right now" : "وليست قراءة للحظة الحالية"
            XCTAssertTrue(note.contains(disclaimer), "a daily trend must never read as \"now\": \(note)")
        }
    }

    func testTheWindowNoteIsPresentInBothSurfaceStatesThatRenderAValue() {
        for surface in [StressSurface.moderate(trend: trend()), .dense(trend: trend(state: .dense))] {
            for depth in [DepthPolicy.casual, .power] {
                let spoken = StressPresentation.spokenLabel(surface, depth: depth, language: .en, format: format)
                XCTAssertTrue(spoken.contains("not a reading for right now"),
                              "\(depth.rawValue) dropped the window disclosure")
            }
        }
    }

    /// Arabic count agreement for the contract-driven window length (1 singular · 2 dual · 3–10
    /// plural · 11+ indeclinable) — the copy cannot hardcode "week" because `trendWindowDays` is
    /// contract data.
    func testDayCountAgreesInArabic() {
        XCTAssertEqual(StressPresentation.dayCount(1, language: .ar, format: format), "يوم واحد")
        XCTAssertEqual(StressPresentation.dayCount(2, language: .ar, format: format), "يومان")
        XCTAssertEqual(StressPresentation.dayCount(7, language: .ar, format: format), "7 أيام")
        XCTAssertEqual(StressPresentation.dayCount(14, language: .ar, format: format), "14 يوماً")
        XCTAssertEqual(StressPresentation.dayCount(7, language: .en, format: format), "7 days")
    }

    // MARK: - Two altitudes

    func testTheNumberIsPowerOnly() {
        let surface = StressSurface.moderate(trend: trend(value: 62))
        let casual = StressPresentation.spokenLabel(surface, depth: .casual, language: .en, format: format)
        let power = StressPresentation.spokenLabel(surface, depth: .power, language: .en, format: format)
        XCTAssertFalse(casual.contains("62"), "casual gets a direction and a sentence, not an index")
        XCTAssertTrue(power.contains("62"))
        XCTAssertTrue(power.contains("0.40"), "power states the confidence it was capped to")
        XCTAssertTrue(casual.contains(StressStrings.sentenceHigher.en))
    }

    func testPowerLineStatesTheNeutralPointAndTheDaysItUsed() {
        let line = StressPresentation.powerLine(trend(daysPresent: 5, windowDays: 7), language: .en, format: format)
        XCTAssertTrue(line.contains("50 is your own usual"), "the scale's meaning travels with the number")
        XCTAssertTrue(line.contains("5") && line.contains("7"), "coverage is shown, not hidden: \(line)")
    }

    func testDensityLineReportsTheEvidenceTheGateRuledOn() {
        let line = StressPresentation.densityLine(trend().density, language: .en, format: format)
        XCTAssertTrue(line.contains("44"))
        XCTAssertTrue(line.contains("71"))
        XCTAssertTrue(line.contains("0.62"), "the samples-per-hour rate the gate actually compares")
    }

    // MARK: - Bands

    func testBandsAreDirectionalAgainstThePersonsOwnUsualAndNeverAVerdict() {
        XCTAssertEqual(StressPresentation.chipSpec(.higherThanUsual).status, .above)
        XCTAssertEqual(StressPresentation.chipSpec(.aboutUsual).status, .inBand)
        XCTAssertEqual(StressPresentation.chipSpec(.lowerThanUsual).status, .below)
        for band in [StressTrendBand.higherThanUsual, .aboutUsual, .lowerThanUsual] {
            let en = (StressPresentation.chipSpec(band).label.en + " " + StressPresentation.sentence(band).en).lowercased()
            XCTAssertFalse(en.contains("high stress"), "\(band.rawValue) states a level rather than a direction")
            XCTAssertFalse(en.contains("stressed"), "\(band.rawValue) tells the reader how they feel")
            XCTAssertTrue(en.contains("usual"), "\(band.rawValue) is relative to the person's own pattern")
        }
    }

    // MARK: - The dense state is honest about what it doesn't compute

    func testTheDenseStateSaysTheIntradayViewIsNotComputedYet() {
        XCTAssertFalse(StressEngine.intradayIndexImplemented,
                       "this build computes no intraday index — the note below is what says so on screen")
        XCTAssertTrue(StressStrings.intradayNote.en.lowercased().contains("doesn’t compute one yet")
                        || StressStrings.intradayNote.en.lowercased().contains("doesn't compute one yet"),
                      StressStrings.intradayNote.en)
        XCTAssertTrue(StressStrings.intradayNote.en.lowercased().contains("daily trend"))
    }

    // MARK: - Copy

    func testStressSurfaceCopyIsBilingualAndClaimsNoLiveReading() {
        let strings: [(String, LocalizedString)] = [
            ("title", StressStrings.title),
            ("bandHigher", StressStrings.bandHigher), ("bandAbout", StressStrings.bandAbout),
            ("bandLower", StressStrings.bandLower),
            ("sentenceHigher", StressStrings.sentenceHigher), ("sentenceAbout", StressStrings.sentenceAbout),
            ("sentenceLower", StressStrings.sentenceLower),
            ("windowNote", StressStrings.windowNote), ("powerLine", StressStrings.powerLine),
            ("densityLine", StressStrings.densityLine), ("intradayNote", StressStrings.intradayNote),
        ]
        // "Right now", "live" and "current" are the words that would turn a windowed trend into a
        // claim the data cannot support — the one exception is the window note, which uses "right
        // now" precisely to deny it.
        let bannedEn = ["live ", "real-time", "realtime", "current stress", "stress level",
                        "you are stressed", "anxiety", "diagnos"]
        let bannedAr = ["مباشر", "لحظي", "مستوى التوتر لديك", "قلق", "تشخيص"]
        for (name, text) in strings {
            XCTAssertFalse(text.en.isEmpty, "\(name) has no English")
            XCTAssertFalse(text.ar.isEmpty, "\(name) has no Arabic")
            XCTAssertNotEqual(text.en, text.ar, "\(name) is untranslated")
            XCTAssertTrue(text.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(name)'s Arabic is not in Arabic script")
            let en = text.en.lowercased()
            for phrase in bannedEn {
                XCTAssertFalse(en.contains(phrase), "\(name) contains the banned frame \"\(phrase)\": \(text.en)")
            }
            for phrase in bannedAr {
                XCTAssertFalse(text.ar.contains(phrase), "\(name) Arabic contains the banned frame \"\(phrase)\"")
            }
        }
    }
}

// MARK: - The card's read path, against a real database

/// `StressSurfaceViewModel.fetch` end to end. The point is the common case: a store with no daytime
/// HRV must produce a hidden surface with an explanation and write nothing at all.
final class StressSurfaceFetchTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-stress-surface-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    func testAnEmptyStoreHidesTheSurfaceAndWritesNothing() throws {
        let derivation = DerivationRepository(db.main)
        let inputs = StressFetchInputs(
            derivation: derivation, measurements: MeasurementRepository(db.main), registry: .shared,
            contextAnnotations: { _, _ in .none }, sensitiveModulesEnabled: true,
            clock: clock, deviceId: "test-device", now: clock.now(), tz: "UTC")

        let data = try StressSurfaceViewModel.fetch(inputs).get()
        let reason = try XCTUnwrap(data.surface.absenceReason, "no daytime HRV can only mean hidden")
        XCTAssertEqual(reason, .noDaytimeHrv)
        XCTAssertNil(data.surface.trend)
        XCTAssertTrue(data.history.isEmpty, "no persisted rows means no history line")
        XCTAssertTrue(data.caveats.isEmpty, "a hidden day frames nothing, so it carries no caveat")
        XCTAssertTrue(try derivation.latestDerivedSeries(metricId: MetricID.stressDayTrend).isEmpty,
                      "the read path writes nothing — an absence is not stored as a zero or a sentinel")
    }
}
