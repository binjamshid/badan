import Foundation
import XCTest
@testable import BADAN

/// EPIC-29 correlation SURFACES — the iOS list over the Stage-2 engine.
///
/// The engine's own suite proves the statistics; this proves the SCREEN cannot undo them. The four
/// properties asserted here are the ones a UI layer is capable of breaking on its own:
///
/// 1. **One computation, two altitudes (D-5).** The casual sentence, the confidence word and the
///    power numbers all read the same `CorrelationFinding` — there is no second path for the
///    detailed view to disagree with.
/// 2. **A below-gate pair shows a shortfall, never a teaser.** No effect size, no interval, no
///    direction — because none was computed.
/// 3. **"No clear association" is a finding**, listed with the others rather than filtered out.
/// 4. **"Association, not cause" is on every card**, in both languages, including the shortfalls.
final class CorrelationSurfacesTests: XCTestCase {
    private let templates = InsightTemplateStore.shared
    private let registry = MetricRegistry.shared
    private let behaviors = BehaviorDictionary.shared
    private var params: CorrelationSpec.Params { CorrelationSpec.defaultShared.params }

    // MARK: - Fixtures

    private func finding(behaviorId: String = "caffeine", scoreId: String = MetricID.readinessScore,
                         n: Int = 20, nWith: Int = 9, nWithout: Int = 11,
                         delta: Double = 0.5, ciLow: Double = 0.2, ciHigh: Double = 0.8,
                         confidence: Double = 0.5, contextDays: Int = 0) -> CorrelationFinding {
        CorrelationFinding(
            behaviorId: behaviorId, scoreId: scoreId, nObserved: n, nWith: nWith, nWithout: nWithout,
            delta: delta, ciLow: ciLow, ciHigh: ciHigh, medianWith: 70, medianWithout: 60,
            contextDays: contextDays, confidence: confidence, provisional: true,
            firstDayKey: "2026-03-01", lastDayKey: "2026-03-20")
    }

    private func model(_ outcomes: [CorrelationOutcome]) -> CorrelationsReadModel {
        CorrelationsPresentation.build(outcomes: outcomes, behaviors: behaviors, registry: registry,
                                       templates: templates, params: params)
    }

    private func row(_ outcome: CorrelationOutcome) throws -> CorrelationRow {
        let built = model([outcome])
        return try XCTUnwrap(built.findings.first ?? built.notYet.first)
    }

    // MARK: - D-5: one computation, two altitudes

    /// The load-bearing assertion of the whole surface: every number a power reader sees, and the
    /// word a casual reader sees, come from the SAME finding object. Nothing on the card is
    /// recomputed, re-rounded or re-derived for the second altitude.
    func testBothAltitudesRenderTheSameComputation() throws {
        let f = finding(n: 23, nWith: 11, nWithout: 12, delta: 0.42, ciLow: 0.11, ciHigh: 0.71,
                        confidence: 0.61)
        let row = try row(.finding(f))
        let casual = row.card.casualText.en
        let power = try XCTUnwrap(row.card.powerText).en

        for altitude in [casual, power] {
            XCTAssertTrue(altitude.contains("23"), "both altitudes state the same n: \(altitude)")
            XCTAssertTrue(altitude.contains("11"), "both altitudes state the same with-arm count")
            XCTAssertTrue(altitude.contains("12"), "both altitudes state the same without-arm count")
        }
        // The power line's numbers are the finding's, formatted once.
        XCTAssertTrue(power.contains(CorrelationRenderer.twoDecimals(f.delta)))
        XCTAssertTrue(power.contains(CorrelationRenderer.twoDecimals(f.ciLow)))
        XCTAssertTrue(power.contains(CorrelationRenderer.twoDecimals(f.ciHigh)))
        XCTAssertTrue(power.contains(CorrelationRenderer.twoDecimals(f.confidence)),
                      "the confidence the casual word reads is the confidence the power line prints")
        // And the casual word is a reading of that same confidence, not a second judgement.
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(try XCTUnwrap(row.finding).confidence),
                       CorrelationsPresentation.confidenceWord(f.confidence))
        XCTAssertEqual(row.finding, f, "the row carries the finding itself, not a copy of its summary")
    }

    func testConfidenceWordIsAReadingOfTheConfidenceNumber() {
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(0), .early)
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(0.32), .early)
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(0.5), .moderate)
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(0.66), .moderate)
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(0.9), .established)
        XCTAssertEqual(CorrelationsPresentation.confidenceWord(1), .established)
        // Never worded as a statistical test — this number is sample size x interval precision.
        for word in CorrelationsPresentation.ConfidenceWord.allCases {
            let en = word.label.en.lowercased()
            XCTAssertFalse(en.contains("significan"), "\(word.rawValue) claims significance testing")
            XCTAssertFalse(en.contains("p ="), "\(word.rawValue) reads as a p-value")
        }
    }

    // MARK: - Suppression shows a shortfall, never a teaser

    func testABelowGatePairShowsHowManyMoreDaysAndNoStatistics() throws {
        let suppression = CorrelationSuppression(
            behaviorId: "alcohol", scoreId: MetricID.sleepPerformance, nObserved: 9, nWith: 4,
            nWithout: 5, reason: .tooFewObservedDays(moreDaysNeeded: 5))
        let built = model([.suppressed(suppression)])
        XCTAssertTrue(built.findings.isEmpty, "a suppressed pair is never listed as a finding")
        let row = try XCTUnwrap(built.notYet.first)

        XCTAssertNil(row.finding, "there is no finding below the gate — not a hidden one, none")
        XCTAssertNil(row.card.powerText, "power mode has no numbers to show for a comparison never made")
        XCTAssertTrue(row.card.casualText.en.contains("5"), "the shortfall is named: about 5 more days")
        for text in [row.card.casualText.en, row.card.casualText.ar] {
            XCTAssertFalse(text.contains("0.0"), "no effect size leaks into a shortfall card: \(text)")
            XCTAssertFalse(text.lowercased().contains("ci "), "no interval leaks into a shortfall card")
        }
    }

    func testEachShortfallNamesItsOwnMissingArm() throws {
        let withArm = try row(.suppressed(.init(behaviorId: "caffeine", scoreId: MetricID.readinessScore,
                                                nObserved: 16, nWith: 3, nWithout: 13,
                                                reason: .tooFewDaysWithBehavior(moreDaysNeeded: 2))))
        let withoutArm = try row(.suppressed(.init(behaviorId: "caffeine", scoreId: MetricID.readinessScore,
                                                   nObserved: 16, nWith: 14, nWithout: 2,
                                                   reason: .tooFewDaysWithoutBehavior(moreDaysNeeded: 3))))
        XCTAssertNotEqual(withArm.card.templateId, withoutArm.card.templateId,
                          "\"keep journaling\" is the wrong instruction when what's missing is days it happened")
        XCTAssertTrue(withArm.card.casualText.en.contains("3"), "names how many days actually included it")
        XCTAssertTrue(withoutArm.card.casualText.en.contains("3"), "names how many more days without it are needed")
    }

    func testTheGateNumbersShownToTheUserAreTheContractsOwn() {
        let built = model([])
        XCTAssertEqual(built.minObservedDays, 14, "plan §11's mandatory minimum observed days")
        XCTAssertEqual(built.minDaysPerArm, 5, "plan §11's mandatory minimum per arm")
        let note = CorrelationsStrings.gateNote.filling([
            "n": "\(built.minObservedDays)", "arm": "\(built.minDaysPerArm)"])
        XCTAssertTrue(note.en.contains("14") && note.en.contains("5"))
        XCTAssertTrue(note.ar.contains("14") && note.ar.contains("5"))
    }

    // MARK: - A null result is a result

    func testNoClearAssociationIsListedAsAFindingNotFilteredOut() throws {
        // A wide interval straddling zero — the comparison ran, cleared both gates, and found
        // nothing clear.
        let null = finding(delta: 0.02, ciLow: -0.4, ciHigh: 0.45, confidence: 0.2)
        XCTAssertEqual(null.direction, .noClearAssociation)
        let built = model([.finding(null)])

        XCTAssertEqual(built.notYet.count, 0)
        let row = try XCTUnwrap(built.findings.first)
        XCTAssertEqual(row.card.templateId, "journal_correlation_none")
        XCTAssertTrue(row.card.casualText.en.lowercased().contains("no clear association"),
                      "a list that only ever contains hits is a slot machine")
        XCTAssertNotNil(row.card.powerText, "a null result still shows its numbers at power depth")
    }

    // MARK: - The locked line

    func testEveryRowCarriesTheAssociationNotCauseLineInBothLanguages() throws {
        let outcomes: [CorrelationOutcome] = [
            .finding(finding()),
            .finding(finding(delta: -0.5, ciLow: -0.8, ciHigh: -0.2)),
            .finding(finding(delta: 0.02, ciLow: -0.4, ciHigh: 0.45)),
            .suppressed(.init(behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 9,
                              nWith: 4, nWithout: 5, reason: .tooFewObservedDays(moreDaysNeeded: 5))),
            .suppressed(.init(behaviorId: "alcohol", scoreId: MetricID.readinessScore, nObserved: 16,
                              nWith: 3, nWithout: 13, reason: .tooFewDaysWithBehavior(moreDaysNeeded: 2))),
            .suppressed(.init(behaviorId: "nap", scoreId: MetricID.effortDay, nObserved: 16,
                              nWith: 14, nWithout: 2, reason: .tooFewDaysWithoutBehavior(moreDaysNeeded: 3))),
        ]
        let built = model(outcomes)
        let rows = built.findings + built.notYet
        XCTAssertEqual(rows.count, outcomes.count)
        for row in rows {
            XCTAssertFalse(row.card.associationNotCause.en.isEmpty, "\(row.metricId) lost the locked line")
            XCTAssertFalse(row.card.associationNotCause.ar.isEmpty, "\(row.metricId) lost the Arabic locked line")
            // And it is inside the spoken label, so a VoiceOver reader cannot swipe past it.
            for depth in [DepthPolicy.casual, .power] {
                for language in [AppLanguage.en, .ar] {
                    let spoken = CorrelationsPresentation.spokenCard(row, depth: depth, language: language)
                    XCTAssertTrue(spoken.contains(row.card.associationNotCause.resolved(language)),
                                  "\(row.metricId) spoken at \(depth.rawValue)/\(language.rawValue) drops the locked line")
                }
            }
        }
    }

    // MARK: - Ordering

    /// Alphabetical by behaviour, never by effect size. A leaderboard of whichever comparison landed
    /// hardest this week is exactly the reading this epic refuses, and a stable order also stops a
    /// finding from moving under the reader's thumb between opens.
    func testOrderingIsStableAndNotRankedByEffectSize() {
        let weakButAlphabeticallyFirst = finding(behaviorId: "alcohol", delta: 0.16, ciLow: 0.01, ciHigh: 0.3)
        let strongButLater = finding(behaviorId: "nicotine", delta: 0.9, ciLow: 0.7, ciHigh: 0.99)
        let built = model([.finding(strongButLater), .finding(weakButAlphabeticallyFirst)])
        XCTAssertEqual(built.findings.map(\.behaviorId), ["alcohol", "nicotine"])
    }

    func testTheSameBehaviorAcrossScoresStaysGroupedInAFixedOrder() {
        let built = model([
            .finding(finding(scoreId: MetricID.sleepPerformance)),
            .finding(finding(scoreId: MetricID.readinessScore)),
            .finding(finding(scoreId: MetricID.effortDay)),
        ])
        XCTAssertEqual(built.findings.map(\.scoreId).sorted(), built.findings.map(\.scoreId),
                       "one behaviour's three scores appear in a fixed, repeatable order")
    }

    // MARK: - Accessibility (§16: "numbers spelled out for VO")

    func testSpokenPowerDetailReadsTheNumbersAsSentences() throws {
        let f = finding(n: 23, nWith: 11, nWithout: 12, delta: -0.42, ciLow: -0.71, ciHigh: -0.11,
                        confidence: 0.61)
        for language in [AppLanguage.en, .ar] {
            let spoken = CorrelationsPresentation.spokenPowerDetail(f, language: language)
            XCTAssertTrue(spoken.contains("23"))
            XCTAssertTrue(spoken.contains("11") && spoken.contains("12"))
            XCTAssertTrue(spoken.contains("0.61"))
            XCTAssertFalse(spoken.contains("·"), "the interpunct in the visual line is not spoken")
            XCTAssertFalse(spoken.contains("["), "brackets are not spoken as an interval")
            // A real minus sign: VoiceOver reads U+2212 as "minus", where a hyphen can be dropped —
            // on the one character that carries the direction of the finding.
            XCTAssertTrue(spoken.contains("\u{2212}0.42"), "the sign is spoken, not swallowed: \(spoken)")
            XCTAssertFalse(spoken.contains("-0.42"))
        }
    }

    func testTheCasualSpokenCardCarriesNoStatistics() throws {
        let row = try row(.finding(finding(n: 23, delta: 0.42, ciLow: 0.11, ciHigh: 0.71)))
        let casual = CorrelationsPresentation.spokenCard(row, depth: .casual, language: .en)
        let power = CorrelationsPresentation.spokenCard(row, depth: .power, language: .en)
        XCTAssertFalse(casual.contains("0.42"), "casual is one sentence plus a confidence word")
        XCTAssertTrue(power.contains("0.42"), "power spells the same numbers out")
        XCTAssertTrue(casual.contains(CorrelationsPresentation.ConfidenceWord.moderate.label.en)
                        || casual.contains(CorrelationsPresentation.ConfidenceWord.early.label.en)
                        || casual.contains(CorrelationsPresentation.ConfidenceWord.established.label.en))
    }

    // MARK: - Context disclosure

    func testContextDaysAreDisclosedOnTheCardRatherThanDroppedSilently() throws {
        let row = try row(.finding(finding(confidence: 0.4, contextDays: 3)))
        let note = try XCTUnwrap(row.card.contextNote, "a window overlapping a declared period says so")
        XCTAssertTrue(note.en.contains("3"))
        XCTAssertFalse(note.ar.isEmpty)
        for language in [AppLanguage.en, .ar] {
            XCTAssertTrue(CorrelationsPresentation.spokenCard(row, depth: .casual, language: language)
                .contains(note.resolved(language)))
        }
    }

    // MARK: - Copy

    func testCorrelationSurfaceCopyIsBilingualAndMakesNoCausalClaim() {
        var strings: [(String, LocalizedString)] = [
            ("title", CorrelationsStrings.title), ("subtitle", CorrelationsStrings.subtitle),
            ("findingsHeader", CorrelationsStrings.findingsHeader),
            ("notYetHeader", CorrelationsStrings.notYetHeader),
            ("gateNote", CorrelationsStrings.gateNote), ("emptyTitle", CorrelationsStrings.emptyTitle),
            ("emptyMessage", CorrelationsStrings.emptyMessage),
            ("methodNote", CorrelationsStrings.methodNote),
            ("sensitiveOffMessage", CorrelationsStrings.sensitiveOffMessage),
            ("openSubtitle", CorrelationsStrings.openSubtitle),
        ]
        for word in CorrelationsPresentation.ConfidenceWord.allCases {
            strings.append(("confidence.\(word.rawValue)", word.label))
        }
        let bannedEn = ["causes", "caused by", "because of", "proves", "leads to", "you should",
                        "you must", "avoid ", "risk", "danger", "abnormal", "diagnos", "significant"]
        let bannedAr = ["يسبب", "بسبب", "يثبت", "يؤدي إلى", "خطر", "مرض", "تشخيص", "تجنب"]
        for (name, text) in strings {
            XCTAssertFalse(text.en.isEmpty, "\(name) has no English")
            XCTAssertFalse(text.ar.isEmpty, "\(name) has no Arabic")
            XCTAssertNotEqual(text.en, text.ar, "\(name) is untranslated")
            XCTAssertTrue(text.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(name)'s Arabic is not in Arabic script")
            let en = text.en.lowercased()
            for phrase in bannedEn {
                XCTAssertFalse(en.contains(phrase), "\(name) contains the banned frame \"\(phrase)\"")
            }
            for phrase in bannedAr {
                XCTAssertFalse(text.ar.contains(phrase), "\(name) Arabic contains the banned frame \"\(phrase)\"")
            }
        }
    }
}

// MARK: - The screen's read path, against a real database

/// `CorrelationsViewModel.fetch` end to end: journal rows and next-day scores in, rendered cards out,
/// findings in the sensitive database and nowhere else.
final class CorrelationsFetchTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-correlation-surface-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func inputs() -> CorrelationsFetchInputs {
        CorrelationsFetchInputs(
            journal: JournalRepository(sensitive: db.sensitive),
            derivation: DerivationRepository(db.main),
            correlations: CorrelationRepository(sensitive: db.sensitive),
            behaviors: .shared, registry: .shared, templates: .shared,
            clock: clock, deviceId: device, now: clock.now(), tz: "UTC")
    }

    /// `days` journaled days ending the day before `now`, alternating caffeine present/absent, each
    /// followed by a readiness score that runs clearly lower after a caffeine day.
    private func seed(days: Int) throws {
        let journal = JournalRepository(sensitive: db.sensitive)
        let derivation = DerivationRepository(db.main)
        let dayEnd = DayAttribution.addingDays(1, to: DayAttribution.startOfDay(clock.now(), tz: "UTC"), tz: "UTC")
        for offset in stride(from: days, through: 1, by: -1) {
            let dayStart = DayAttribution.addingDays(-offset, to: dayEnd, tz: "UTC")
            let dayKey = DayAttribution.localDayKey(dayStart, tz: "UTC")
            let present = offset % 2 == 0
            let occurredAt = dayStart.addingTimeInterval(9 * 3600)
            try journal.insertEntry(JournalLog.entry(
                id: ULID.newID(), behaviorId: "caffeine", valueKind: .count, value: present ? 2 : 0,
                occurredAt: occurredAt, tzId: "UTC", sourceId: "manual",
                now: occurredAt, originDeviceId: device))
            let nextKey = CorrelationEngine.nextDayKey(dayKey, tz: "UTC")
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: MetricID.readinessScore,
                value: present ? Double(58 + offset % 3) : Double(76 + offset % 3),
                unit: "score_0_100", periodKey: "day:" + nextKey, confidence: 0.9, provisional: false,
                algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
                computedAt: occurredAt, updatedAt: occurredAt, originDeviceId: device))
        }
    }

    func testAnEligibleBehaviorRendersACardAndIsStoredInTheSensitiveDatabaseOnly() throws {
        try seed(days: 24)
        let inputs = inputs()
        let model = try CorrelationsViewModel.fetch(inputs).get()

        let row = try XCTUnwrap(model.findings.first { $0.behaviorId == "caffeine" && $0.scoreId == MetricID.readinessScore })
        XCTAssertEqual(row.behaviorName.en, "Caffeine", "the dictionary label, not the raw id")
        XCTAssertEqual(row.scoreName.en, "Readiness")
        XCTAssertFalse(row.card.casualText.en.isEmpty)
        XCTAssertFalse(row.card.casualText.ar.isEmpty)
        XCTAssertEqual(row.finding?.direction, .lower, "the seeded data runs lower after a caffeine day")

        // The finding is in the sensitive store, and not in `badan.db`: the metric id names the
        // behaviour, so a main-DB row would survive the sensitive purge and keep disclosing it.
        let stored = try inputs.correlations.latestFindings()
        XCTAssertTrue(stored.contains { $0.metricId == row.metricId })
        XCTAssertNil(try inputs.derivation.latestDerived(metricId: row.metricId, periodKey: row.finding!.periodKey))
    }

    func testAThinJournalProducesShortfallsAndPersistsNothing() throws {
        try seed(days: 6)
        let inputs = inputs()
        let model = try CorrelationsViewModel.fetch(inputs).get()

        XCTAssertTrue(model.findings.isEmpty, "nothing clears a 14-day gate on 6 journaled days")
        XCTAssertFalse(model.notYet.isEmpty, "the pairs are still reported, as shortfalls")
        XCTAssertTrue(model.notYet.allSatisfy { $0.finding == nil && $0.card.powerText == nil })
        XCTAssertTrue(try inputs.correlations.latestFindings().isEmpty,
                      "a suppressed pair leaves no row a later read path could render")
    }

    func testAnEmptyJournalProducesAnEmptyModelRatherThanFabricatedRows() throws {
        let model = try CorrelationsViewModel.fetch(inputs()).get()
        XCTAssertTrue(model.isEmpty, "no journal, no comparisons — and no placeholder cards")
    }
}
