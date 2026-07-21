import Foundation
import XCTest
@testable import BADAN

/// EPIC-29 data + logic core: the behavior dictionary, the journal/context entities and their
/// repository, the interval semantics of a `ContextStatus`, and the I7 sensitivity contract
/// (sensitive-DB-only placement, default-export exclusion, purge removal).
///
/// The sensitivity cases deliberately drive the REAL export path (`ExportRunner.run`) rather than
/// the writers alone. A writer test proves the serializer behaves; only the runner proves the
/// consent gate is actually wired, which is where a sensitive family leaks in practice — see
/// `HydrationExportWiringTests` for the same reasoning applied to the opposite classification.
final class JournalTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"
    /// Long enough for `ExportPassphrasePolicy` (a sensitive export refuses to run without one).
    private let passphrase = "journal-export-passphrase"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-journal-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func repo() -> JournalRepository { JournalRepository(sensitive: db.sensitive) }

    private func provenance(occurredAt: Date, recordedAt: Date? = nil, tzId: String = "UTC") -> Provenance {
        let recorded = recordedAt ?? occurredAt
        return Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                          measuredAt: occurredAt, measuredTimezone: tzId,
                          recordedAt: recorded, ingestedAt: recorded)
    }

    // MARK: - Behavior dictionary

    /// The dictionary as authored in `packages/` — the file both platforms mirror. Read from the
    /// repo rather than the app bundle so a sync-script regression can't make this pass against a
    /// stale copy (same approach as `HydrationTests`' beverage check).
    func testBehaviorDictionaryIsBilingualSensitivePlusAndWellFormed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("packages/contracts/dictionaries/behaviors.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let behaviors = try XCTUnwrap(json?["behaviors"] as? [[String: Any]])

        XCTAssertGreaterThanOrEqual(behaviors.count, 20, "the journal needs a usable chip vocabulary")
        var ids = Set<String>()
        for b in behaviors {
            let id = try XCTUnwrap(b["id"] as? String)
            XCTAssertTrue(ids.insert(id).inserted, "duplicate behavior id \(id) — ids are the join key")
            XCTAssertFalse((b["nameEn"] as? String ?? "").isEmpty, "\(id) carries English")
            XCTAssertFalse((b["nameAr"] as? String ?? "").isEmpty, "\(id) carries Arabic")
            XCTAssertNotEqual(b["nameEn"] as? String, b["nameAr"] as? String,
                              "\(id): the Arabic name must be real Arabic, not the English string copied over")
            XCTAssertFalse((b["category"] as? String ?? "").isEmpty, "\(id) carries a category")
            XCTAssertEqual(b["sensitiveClass"] as? String, "sensitivePlus",
                           "\(id): every behavior is sensitive-plus (I7) — the file states it per row "
                               + "so no entry can be added at a lower class")
            let kind = try XCTUnwrap(BehaviorValueKind(rawValue: try XCTUnwrap(b["valueKind"] as? String)))
            switch kind {
            case .quantity:
                XCTAssertFalse((b["unit"] as? String ?? "").isEmpty,
                               "\(id): a quantity behavior must name its unit — an amount with no unit is unreadable")
            case .boolean, .count:
                XCTAssertNil(b["unit"], "\(id): \(kind.rawValue) carries no physical unit")
            }
        }
        // The behaviors named in the plan's own examples, so the shipped vocabulary can't quietly
        // drop the cases the correlation feature was specified around.
        for expected in ["caffeine", "alcohol", "late_meal", "screen_in_bed", "nap", "intense_training"] {
            XCTAssertTrue(ids.contains(expected), "behaviors.json must offer \(expected)")
        }
    }

    /// The loader both platforms read through, against the bundled copy the sync script produced.
    func testBehaviorDictionaryLoadsFromTheAppBundle() throws {
        let dictionary = BehaviorDictionary.shared
        XCTAssertFalse(dictionary.all.isEmpty, "behaviors.json must be present in the app bundle")
        XCTAssertTrue(dictionary.allAreSensitivePlus)
        let caffeine = try XCTUnwrap(dictionary.definition("caffeine"))
        XCTAssertEqual(caffeine.displayName.resolved(.en), "Caffeine")
        XCTAssertFalse(caffeine.displayName.resolved(.ar).isEmpty)
        XCTAssertEqual(dictionary.valueKind(forId: "nap"), .quantity)
        // An id the dictionary doesn't know must not render blank or crash — a journal row written
        // by a newer build still has to display.
        XCTAssertEqual(dictionary.displayName(forId: "not-a-behavior", customLabel: nil).resolved(.en),
                       "not-a-behavior")
        XCTAssertEqual(dictionary.valueKind(forId: "not-a-behavior"), .boolean)
    }

    // MARK: - Journal entries: round-trip and backdating

    func testJournalEntryRoundTripsThroughTheRepository() throws {
        let occurred = clock.now().addingTimeInterval(-7_200)
        let entry = JournalLog.entry(id: "J-1", behaviorId: "caffeine", valueKind: .count, value: 3,
                                     occurredAt: occurred, tzId: "Asia/Riyadh", note: "afternoon",
                                     sourceId: device, deviceId: device, now: clock.now(),
                                     originDeviceId: device)
        try repo().insertEntry(entry)

        let read = try XCTUnwrap(try repo().entry(id: "J-1"))
        XCTAssertEqual(read.behaviorId, "caffeine")
        XCTAssertNil(read.customLabel)
        XCTAssertEqual(read.valueKind, .count)
        XCTAssertEqual(read.value, 3)
        XCTAssertNil(read.unit)
        XCTAssertEqual(read.tzId, "Asia/Riyadh")
        XCTAssertEqual(read.note, "afternoon")
        XCTAssertEqual(read.occurredAt.epochMillis, occurred.epochMillis)
        XCTAssertEqual(read.provenance.ingestionPath, .manual, "I1: a manual assertion is still provenanced")
        XCTAssertEqual(read.provenance.sourceId, device)
        XCTAssertTrue(read.isPresent)
    }

    /// A count of zero is an assertion that the behavior did NOT happen — real information the
    /// user can enter. Folding it into the "with" arm would poison every correlation built on it.
    func testExplicitZeroCountIsAnAbsenceNotAPresence() {
        let now = clock.now()
        let none = JournalLog.entry(id: "J-0", behaviorId: "caffeine", valueKind: .count, value: 0,
                                    occurredAt: now, tzId: "UTC", sourceId: device, now: now,
                                    originDeviceId: device)
        let some = JournalLog.entry(id: "J-2", behaviorId: "caffeine", valueKind: .count, value: 2,
                                    occurredAt: now, tzId: "UTC", sourceId: device, now: now,
                                    originDeviceId: device)
        let tag = JournalLog.entry(id: "J-3", behaviorId: "screen_in_bed", valueKind: .boolean,
                                   occurredAt: now, tzId: "UTC", sourceId: device, now: now,
                                   originDeviceId: device)
        XCTAssertFalse(none.isPresent)
        XCTAssertTrue(some.isPresent)
        XCTAssertTrue(tag.isPresent, "a boolean tag's existence IS the assertion")
    }

    /// Yesterday-recall is a first-class path: the entry files under the day it HAPPENED, while
    /// provenance keeps the truth about when it was typed.
    func testYesterdayRecallFilesUnderTheDayItHappenedAndDisclosesTheRecall() throws {
        let now = clock.now()
        let yesterday = JournalLog.yesterday(now, tzId: "UTC")
        let entry = JournalLog.recalledEntry(id: "J-RECALL", behaviorId: "alcohol", valueKind: .count,
                                             value: 2, occurredAt: yesterday, tzId: "UTC",
                                             sourceId: device, now: now, originDeviceId: device)
        try repo().insertEntry(entry)

        XCTAssertTrue(entry.isRecalled, "an entry logged a day later must disclose that it was recalled")
        XCTAssertEqual(entry.provenance.recordedAt.epochMillis, now.epochMillis,
                       "I1: `recorded_at` stays honest about when the user typed it")
        XCTAssertEqual(entry.occurredAt.epochMillis, yesterday.epochMillis)
        XCTAssertNotEqual(entry.dayKey(), JournalLog.entry(
            id: "x", behaviorId: "alcohol", valueKind: .boolean, occurredAt: now, tzId: "UTC",
            sourceId: device, now: now, originDeviceId: device).dayKey(),
            "a recalled entry belongs to yesterday's bucket, not today's")

        // The window read is on `occurred_at` — the property the correlation arms depend on.
        let yesterdayWindow = try repo().entries(from: yesterday.addingTimeInterval(-3_600),
                                                 to: yesterday.addingTimeInterval(3_600))
        XCTAssertEqual(yesterdayWindow.map(\.id), ["J-RECALL"])
        let todayWindow = try repo().entries(from: now.addingTimeInterval(-3_600),
                                             to: now.addingTimeInterval(3_600))
        XCTAssertTrue(todayWindow.isEmpty,
                      "filtering on when it was typed would file a recalled entry under today")
    }

    /// Calendar arithmetic, not a fixed 86 400 seconds: across a DST boundary the naive
    /// subtraction lands an hour off and files the entry under the wrong local day.
    func testYesterdayCrossesADSTBoundaryByCalendarNotBySeconds() throws {
        // 2026-03-29 09:00 Europe/London — the morning BST begins (clocks go forward at 01:00), so
        // the previous local day is still on GMT and "same time yesterday" is 23 hours back, not 24.
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 29
        components.hour = 9; components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        calendar.timeZone = london
        let reference = try XCTUnwrap(calendar.date(from: components))

        let yesterday = JournalLog.yesterday(reference, tzId: "Europe/London")
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: yesterday)
        XCTAssertEqual(parts.day, 28)
        XCTAssertEqual(parts.hour, 9, "same wall-clock time on the previous local day, DST included")
        XCTAssertNotEqual(yesterday.epochMillis, reference.addingTimeInterval(-86_400).epochMillis,
                          "a fixed 24h subtraction is exactly the bug this guards")
    }

    func testDeletingAnEntryIsATombstoneNotAHardDelete() throws {
        let now = clock.now()
        try repo().insertEntry(JournalLog.entry(id: "J-DEL", behaviorId: "nap", valueKind: .quantity,
                                                value: 25, unit: "min", occurredAt: now, tzId: "UTC",
                                                sourceId: device, now: now, originDeviceId: device))
        try repo().deleteEntry(id: "J-DEL", at: now)

        XCTAssertTrue(try repo().allEntries().isEmpty, "a tombstoned entry is out of every live read")
        let raw = try XCTUnwrap(try repo().entry(id: "J-DEL"))
        XCTAssertNotNil(raw.deletedAt, "the row itself stays — a removal is a recorded event")
    }

    // MARK: - Context statuses: interval semantics

    func testOpenEndedStatusIsActiveUntilItIsClosed() throws {
        let start = clock.now().addingTimeInterval(-86_400)
        let status = ContextStatus(id: "C-TRAVEL", statusId: ContextStatusKind.travel.rawValue,
                                   startAt: start, tzId: "UTC", provenance: provenance(occurredAt: start),
                                   updatedAt: start, originDeviceId: device)
        try repo().upsertStatus(status)

        XCTAssertTrue(status.isOpenEnded)
        XCTAssertTrue(status.isActive(at: clock.now()))
        XCTAssertFalse(status.isActive(at: start.addingTimeInterval(-1)))
        // The SQL must find it too: `end_at > ?` alone silently returns none of the open-ended
        // rows, which is the failure mode where "I'm travelling right now" annotates nothing.
        XCTAssertEqual(try repo().activeStatuses(at: clock.now()).map(\.id), ["C-TRAVEL"])

        let end = clock.now()
        try repo().closeStatus(id: "C-TRAVEL", endAt: end, updatedAt: end)
        let closed = try XCTUnwrap(try repo().status(id: "C-TRAVEL"))
        XCTAssertEqual(closed.endAt?.epochMillis, end.epochMillis)
        XCTAssertEqual(closed.startAt.epochMillis, start.epochMillis, "closing must not move the start")
        XCTAssertFalse(closed.isActive(at: end), "membership is half-open — the end instant is outside")
        XCTAssertTrue(closed.isActive(at: end.addingTimeInterval(-1)))
        XCTAssertTrue(try repo().activeStatuses(at: end).isEmpty)
    }

    func testBackToBackStatusesDoNotBothClaimTheSharedInstant() {
        let boundary = clock.now()
        let first = ContextStatus(id: "C-1", statusId: ContextStatusKind.travel.rawValue,
                                  startAt: boundary.addingTimeInterval(-3_600), endAt: boundary,
                                  tzId: "UTC", provenance: provenance(occurredAt: boundary),
                                  updatedAt: boundary, originDeviceId: device)
        let second = ContextStatus(id: "C-2", statusId: ContextStatusKind.illness.rawValue,
                                   startAt: boundary, tzId: "UTC",
                                   provenance: provenance(occurredAt: boundary),
                                   updatedAt: boundary, originDeviceId: device)
        XCTAssertFalse(first.isActive(at: boundary))
        XCTAssertTrue(second.isActive(at: boundary))
    }

    func testOverlapAnswersTheWindowQuestionANightlyScoreAsks() {
        let night = clock.now()
        let status = ContextStatus(id: "C-3", statusId: ContextStatusKind.altitude.rawValue,
                                   startAt: night.addingTimeInterval(-1_800),
                                   endAt: night.addingTimeInterval(1_800), tzId: "UTC",
                                   provenance: provenance(occurredAt: night), updatedAt: night,
                                   originDeviceId: device)
        XCTAssertTrue(status.overlaps(from: night.addingTimeInterval(-7_200), to: night),
                      "a status covering half the window still means the window wasn't ordinary")
        XCTAssertFalse(status.overlaps(from: night.addingTimeInterval(7_200),
                                       to: night.addingTimeInterval(10_800)))
    }

    /// §9.10's behavioural rule. A status may annotate confidence and copy; it may never alter a
    /// stored value — and this type gives no way to try.
    func testAContextStatusCanOnlyLowerConfidenceAndNeverTouchesAValue() {
        let now = clock.now()
        let travel = ContextStatus(id: "C-4", statusId: ContextStatusKind.travel.rawValue,
                                   startAt: now.addingTimeInterval(-3_600), tzId: "UTC",
                                   provenance: provenance(occurredAt: now), updatedAt: now,
                                   originDeviceId: device)
        let annotation = ContextAnnotator.annotation(at: now, statuses: [travel])
        XCTAssertFalse(annotation.isEmpty)
        XCTAssertEqual(annotation.caveats.count, 1)
        XCTAssertFalse(annotation.caveats[0].resolved(.en).isEmpty)
        XCTAssertFalse(annotation.caveats[0].resolved(.ar).isEmpty)
        XCTAssertNotEqual(annotation.caveats[0].resolved(.en), annotation.caveats[0].resolved(.ar))

        // Only ever downward, and never above what was already claimed.
        XCTAssertEqual(annotation.applying(to: 0.95), ContextAnnotator.activeContextConfidenceCeiling)
        XCTAssertEqual(annotation.applying(to: 0.2), 0.2, "an already-low confidence is not raised")
        XCTAssertNil(annotation.applying(to: nil))

        // A score computed during the status keeps its value untouched: the annotation carries a
        // confidence ceiling and sentences, and nothing else exists on it to apply to a number.
        let score = DerivedValue(id: "D-1", metricId: "readiness.score", value: 71, unit: "score_0_100",
                                 periodKey: "day:2026-07-21", confidence: 0.9, provisional: false,
                                 algorithmId: "readiness", algorithmVersion: "1.0.0",
                                 computedAt: now, updatedAt: now, originDeviceId: device)
        let annotated = DerivedValue(id: score.id, metricId: score.metricId, value: score.value,
                                     unit: score.unit, periodKey: score.periodKey,
                                     confidence: annotation.applying(to: score.confidence),
                                     provisional: score.provisional, algorithmId: score.algorithmId,
                                     algorithmVersion: score.algorithmVersion,
                                     computedAt: score.computedAt, updatedAt: score.updatedAt,
                                     originDeviceId: score.originDeviceId)
        XCTAssertEqual(annotated.value, 71, "a context annotates interpretation, never the value")
        XCTAssertEqual(annotated.confidence, ContextAnnotator.activeContextConfidenceCeiling)
    }

    /// Two active statuses are one reason to read the day carefully, not twice the uncertainty.
    /// A compounding ceiling would invent a number nothing supports.
    func testCeilingsDoNotCompoundAcrossStatuses() {
        let now = clock.now()
        func status(_ id: String, _ kind: ContextStatusKind) -> ContextStatus {
            ContextStatus(id: id, statusId: kind.rawValue, startAt: now.addingTimeInterval(-60),
                          tzId: "UTC", provenance: provenance(occurredAt: now), updatedAt: now,
                          originDeviceId: device)
        }
        let one = ContextAnnotator.annotation(at: now, statuses: [status("a", .travel)])
        let two = ContextAnnotator.annotation(at: now, statuses: [status("a", .travel), status("b", .illness)])
        XCTAssertEqual(one.confidenceCeiling, two.confidenceCeiling)
        XCTAssertEqual(two.caveats.count, 2, "each active status still contributes its own sentence")
    }

    func testACustomStatusStillAnnotatesAndNamesItself() {
        let now = clock.now()
        let custom = ContextStatus(id: "C-5", customLabel: "Ramadan night shift", startAt: now.addingTimeInterval(-60),
                                   tzId: "UTC", provenance: provenance(occurredAt: now), updatedAt: now,
                                   originDeviceId: device)
        XCTAssertNil(custom.kind)
        XCTAssertEqual(custom.displayLabel.resolved(.en), "Ramadan night shift")
        let annotation = ContextAnnotator.annotation(at: now, statuses: [custom])
        XCTAssertTrue(annotation.caveats[0].resolved(.en).contains("Ramadan night shift"))
        XCTAssertTrue(annotation.caveats[0].resolved(.ar).contains("Ramadan night shift"))
        XCTAssertEqual(annotation.confidenceCeiling, ContextAnnotator.activeContextConfidenceCeiling)
    }

    /// Pins the ceiling to its LITERAL value, which every other assertion here deliberately does not.
    ///
    /// The rest of this suite compares against `ContextAnnotator.activeContextConfidenceCeiling`
    /// symbolically — correct for testing the annotator's behaviour, and useless for parity: editing
    /// the constant to 0.6 keeps every one of those assertions green while silently diverging from
    /// Android, whose `JournalTest`/`CorrelationEngineGoldenTest` pin 0.7 as a literal. A cross-
    /// platform constant is only pinned if BOTH ends refuse to move, so this is the iOS half of that
    /// pair. Changing the ceiling is a deliberate act that must edit this line and its Kotlin mirror
    /// together.
    func testTheActiveContextConfidenceCeilingMatchesTheAndroidConstant() {
        XCTAssertEqual(ContextAnnotator.activeContextConfidenceCeiling, 0.7, accuracy: 1e-12)
    }

    // MARK: - I7: sensitive placement, purge, export gating

    /// The structural half of I7: neither table exists in `badan.db`, so a journal row cannot be
    /// written there — and `purgeSensitiveNamespace()` (a file deletion) therefore covers both
    /// families by construction, with no per-table purge list to keep in sync.
    func testJournalTablesExistOnlyInTheSensitiveDatabase() throws {
        for table in ["journal_entries", "context_statuses"] {
            let inMain = try db.main.query(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';")
                .first?.int("c") ?? 0
            XCTAssertEqual(inMain, 0, "\(table) is sensitive-plus (I7) and must not exist in badan.db")
            let inSensitive = try db.sensitive.query(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';")
                .first?.int("c") ?? 0
            XCTAssertEqual(inSensitive, 1, "\(table) must live in badan_sensitive.db")
        }
        // The write path can only reach the sensitive connection, so a main-DB insert is not
        // merely discouraged — the statement fails outright.
        XCTAssertThrowsError(try db.main.run(
            "INSERT INTO journal_entries (id, value_kind, occurred_at, tz_id) VALUES ('x','boolean',0,'UTC');"),
            "writing a journal row to the main DB must be impossible, not just unconventional")
    }

    func testSensitivePurgeRemovesJournalAndContextRows() throws {
        let now = clock.now()
        try repo().insertEntry(JournalLog.entry(id: "J-PURGE", behaviorId: "alcohol", valueKind: .count,
                                                value: 1, occurredAt: now, tzId: "UTC",
                                                sourceId: device, now: now, originDeviceId: device))
        try repo().upsertStatus(ContextStatus(id: "C-PURGE", statusId: ContextStatusKind.illness.rawValue,
                                              startAt: now, tzId: "UTC",
                                              provenance: provenance(occurredAt: now), updatedAt: now,
                                              originDeviceId: device))
        XCTAssertEqual(try repo().allEntries().count, 1)
        XCTAssertEqual(try repo().allStatuses().count, 1)

        try db.purgeSensitiveNamespace()

        XCTAssertTrue(try repo().allEntries().isEmpty, "I7: a purge is a file deletion — nothing survives")
        XCTAssertTrue(try repo().allStatuses().isEmpty)
    }

    // MARK: - Export gating (driven through the real runner)

    private func makeRunner() -> ExportRunner {
        ExportRunner(measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
                     logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                     exportJobs: ExportJobRepository(db.main), registry: .shared, clock: clock,
                     appVersion: "test", deviceId: device, journal: repo())
    }

    @discardableResult
    private func seedJournal() throws -> Date {
        let now = clock.now()
        let occurred = now.addingTimeInterval(-3_600)
        try repo().insertEntry(JournalLog.entry(id: "J-EXPORT", behaviorId: "caffeine", valueKind: .count,
                                                value: 2, occurredAt: occurred, tzId: "UTC",
                                                note: "JOURNAL-NOTE-TRIPWIRE", sourceId: device,
                                                now: now, originDeviceId: device))
        try repo().upsertStatus(ContextStatus(id: "C-EXPORT", statusId: ContextStatusKind.travel.rawValue,
                                              startAt: occurred, tzId: "UTC",
                                              provenance: provenance(occurredAt: occurred, recordedAt: now),
                                              updatedAt: now, originDeviceId: device))
        return occurred
    }

    private func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    /// A default (non-sensitive) export must carry neither family — and must not even hint that a
    /// journal exists, which is why the keys are absent rather than empty.
    func testDefaultExportExcludesJournalAndContextStatuses() throws {
        try seedJournal()
        let result = try makeRunner().run(scope: .everything, format: .json)

        let bundle = try read(try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "bundle.json" }))
        XCTAssertFalse(bundle.contains("J-EXPORT"), "a default export must not carry journal rows")
        XCTAssertFalse(bundle.contains("C-EXPORT"), "a default export must not carry context statuses")
        XCTAssertFalse(bundle.contains("JOURNAL-NOTE-TRIPWIRE"))
        XCTAssertFalse(bundle.contains("\"journal\""),
                       "absent, not empty: an empty array would disclose that the journal was read")
        XCTAssertFalse(bundle.contains("\"context_statuses\""))

        let csvResult = try makeRunner().run(scope: .everything, format: .csv)
        let events = try read(try XCTUnwrap(csvResult.fileURLs.first { $0.lastPathComponent == "events.csv" }))
        XCTAssertFalse(events.contains("journal.entry"))
        XCTAssertFalse(events.contains("context.status"))
        XCTAssertFalse(events.contains("JOURNAL-NOTE-TRIPWIRE"))
    }

    /// The other half: with `includeSensitive`, both families are actually delivered. Without this
    /// the Sensitive toggle's own copy would be promising records nothing ships.
    func testSensitiveJSONExportCarriesJournalAndContextStatuses() throws {
        try seedJournal()
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let result = try makeRunner().run(scope: scope, format: .json, passphrase: passphrase)

        // A sensitive export is always encrypted (ADR-0008), so the bundle is inside the container.
        let containerURL = try XCTUnwrap(result.fileURLs.first {
            $0.lastPathComponent == ExportEncryptor.containerFileName
        })
        let files = try ExportEncryptor.decrypt(try Data(contentsOf: containerURL), passphrase: passphrase)
        let bundle = String(decoding: try XCTUnwrap(files.first { $0.name == "bundle.json" }).data, as: UTF8.self)

        XCTAssertTrue(bundle.contains("\"journal\""))
        XCTAssertTrue(bundle.contains("\"context_statuses\""))
        XCTAssertTrue(bundle.contains("J-EXPORT"))
        XCTAssertTrue(bundle.contains("C-EXPORT"))
        XCTAssertTrue(bundle.contains("\"behavior_id\":\"caffeine\""))
        XCTAssertTrue(bundle.contains("\"value_kind\":\"count\""))
        XCTAssertTrue(bundle.contains("\"open_ended\":true"),
                      "an ongoing status exports with a null end — never a fabricated one")
        XCTAssertTrue(bundle.contains("\"logs.journal\":1"))
        XCTAssertTrue(bundle.contains("\"logs.context_statuses\":1"))
    }

    func testSensitiveCSVExportProjectsJournalRowsOntoEventsCSV() throws {
        try seedJournal()
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let result = try makeRunner().run(scope: scope, format: .csv, passphrase: passphrase)

        let containerURL = try XCTUnwrap(result.fileURLs.first {
            $0.lastPathComponent == ExportEncryptor.containerFileName
        })
        let files = try ExportEncryptor.decrypt(try Data(contentsOf: containerURL), passphrase: passphrase)
        let events = String(decoding: try XCTUnwrap(files.first { $0.name == "events.csv" }).data, as: UTF8.self)

        XCTAssertTrue(events.contains("journal.entry"))
        XCTAssertTrue(events.contains("context.status"))
        XCTAssertTrue(events.contains("value_kind:count"))
        XCTAssertTrue(events.contains("open_ended"))
        // The count exports as its own number in its own row — never silently converted.
        let journalLine = try XCTUnwrap(events.split(separator: "\r\n").first { $0.contains("journal.entry") })
        XCTAssertTrue(journalLine.contains("J-EXPORT"))
        XCTAssertTrue(journalLine.contains(",2,"), "a count of 2 exports as 2")
    }

    /// A backup whose ONLY sensitive content is a behavior journal must still make the restore
    /// screen ask. Before EPIC-29 `sensitivePresent` was `symptoms > 0 || adherence > 0`, so such a
    /// bundle would have restored its journal without the receiving device ever offering the
    /// consent toggle (§12 EPIC-18 requirement 5).
    func testRestorePreviewTreatsAJournalOnlyBundleAsSensitive() throws {
        let now = clock.now()
        let entry = JournalLog.entry(id: "J-BACKUP", behaviorId: "nap", valueKind: .quantity, value: 30,
                                     unit: "min", occurredAt: now, tzId: "UTC", sourceId: device,
                                     now: now, originDeviceId: device)
        let logs: [String: Any] = ["symptoms": [], "adherence": [], "workouts": [], "nutrition": [],
                                   "journal": [["record_id": entry.id]],
                                   "context_statuses": [["record_id": "C-BACKUP"]]]
        let restore = BackupBundle.RestoreBundle(
            schemaVersion: ExportSchema.version, createdAt: "2026-07-21T00:00:00+00:00",
            originPlatform: "ios", originAppVersion: "test", encrypted: false,
            logicalFiles: [], bundle: ["logs": logs])
        let preview = BackupBundle.preview(restore)

        XCTAssertEqual(preview.namespaceCounts["logs.journal"], 1)
        XCTAssertEqual(preview.namespaceCounts["logs.context_statuses"], 1)
        XCTAssertTrue(preview.sensitivePresent,
                      "a journal-only backup is still an I7 bundle — the restore must re-ask")

        let denied = BackupBundle.plan(preview, consent: .init(includeSensitive: false),
                                       batchId: "B-1", fileName: "b.json", now: now)
        XCTAssertEqual(denied.counts["logs.journal"], 0, "default deny zeroes the journal namespace")
        XCTAssertEqual(denied.counts["logs.context_statuses"], 0)
        XCTAssertFalse(denied.includesSensitive)

        let granted = BackupBundle.plan(preview, consent: .init(includeSensitive: true),
                                        batchId: "B-2", fileName: "b.json", now: now)
        XCTAssertEqual(granted.counts["logs.journal"], 1)
        XCTAssertTrue(granted.includesSensitive)
    }

    /// A runner built WITHOUT the journal repository (every pre-EPIC-29 construction, and the
    /// aggregated/route paths) must behave exactly as before rather than fail.
    func testARunnerWithoutTheJournalRepositoryStillExportsCleanly() throws {
        try seedJournal()
        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main),
                                  logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: device)
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let result = try runner.run(scope: scope, format: .json, passphrase: passphrase)

        let containerURL = try XCTUnwrap(result.fileURLs.first {
            $0.lastPathComponent == ExportEncryptor.containerFileName
        })
        let files = try ExportEncryptor.decrypt(try Data(contentsOf: containerURL), passphrase: passphrase)
        let bundle = String(decoding: try XCTUnwrap(files.first { $0.name == "bundle.json" }).data, as: UTF8.self)
        XCTAssertFalse(bundle.contains("\"journal\""), "no repository wired in means no block, not an empty one")
        XCTAssertFalse(bundle.contains("J-EXPORT"))
    }
}
