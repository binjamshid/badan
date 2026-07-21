import Foundation
import XCTest
@testable import BADAN

/// EPIC-29 journal SURFACES — the iOS UI layer over the Stage-1 entities and repository.
///
/// Two halves, matching `HydrationSurfacesTests`: the pure day-model builder and copy, then the view
/// models exercised end-to-end against a real database. The second half is where the rules that
/// actually matter live — a casual tap must not invent a number, a correction must be an append plus
/// a tombstone rather than an edit, and a yesterday tag must land on yesterday and say it was
/// recalled.
final class JournalSurfacesTests: XCTestCase {
    private let device = "test-device"
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Fixtures

    private func behavior(_ id: String, kind: BehaviorValueKind = .boolean, unit: String? = nil,
                          category: String = "stimulants") -> BehaviorDefinition {
        BehaviorDefinition(id: id, nameEn: id, nameAr: id, valueKind: kind, unit: unit,
                           category: category, sensitiveClass: .sensitivePlus)
    }

    private func entry(_ behaviorId: String?, customLabel: String? = nil,
                       kind: BehaviorValueKind = .boolean, value: Double? = nil,
                       at occurredAt: Date? = nil, deleted: Bool = false) -> JournalEntry {
        let when = occurredAt ?? now
        return JournalEntry(
            id: ULID.newID(), behaviorId: behaviorId, customLabel: customLabel, valueKind: kind,
            value: value, unit: nil, occurredAt: when, tzId: "UTC",
            provenance: Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                                   measuredAt: when, measuredTimezone: "UTC",
                                   recordedAt: when, ingestedAt: when),
            updatedAt: when, originDeviceId: device, deletedAt: deleted ? when : nil)
    }

    // MARK: - Chip building

    func testEveryDictionaryBehaviorGetsAChipWhetherTaggedOrNot() {
        let dictionary = [behavior("caffeine"), behavior("alcohol"), behavior("nap")]
        let chips = JournalDayBuilder.chips(dictionary: dictionary, entries: [entry("alcohol")])
        XCTAssertEqual(chips.map(\.id), ["caffeine", "alcohol", "nap"],
                       "the vocabulary is the surface — a chip never disappears because it wasn't tapped")
        XCTAssertEqual(chips.filter(\.isOn).map(\.id), ["alcohol"])
    }

    func testNewestRowWinsWhenADayCarriesTwoTagsForOneBehavior() {
        // Two rows for one behaviour can only arrive from a sync peer or an import; the repository
        // returns newest-first, so the newest assertion is the one the chip reflects.
        let newest = entry("caffeine", kind: .count, value: 3)
        let older = entry("caffeine", kind: .count, value: 1)
        let chips = JournalDayBuilder.chips(dictionary: [behavior("caffeine", kind: .count)],
                                            entries: [newest, older])
        XCTAssertEqual(chips.first?.entry?.id, newest.id)
        XCTAssertEqual(chips.first?.amount, 3)
    }

    func testTombstonedTagsNeverLightAChip() {
        let chips = JournalDayBuilder.chips(dictionary: [behavior("caffeine")],
                                            entries: [entry("caffeine", deleted: true)])
        XCTAssertFalse(chips[0].isOn, "an untagged behaviour reads as 'didn't happen', not as tagged")
    }

    func testGroupsFollowTheDictionaryOrderRatherThanAlphabet() {
        let dictionary = [
            behavior("caffeine", category: "stimulants"),
            behavior("late_meal", category: "food"),
            behavior("nicotine", category: "stimulants"),
        ]
        let groups = JournalDayBuilder.groups(JournalDayBuilder.chips(dictionary: dictionary, entries: []))
        XCTAssertEqual(groups.map(\.category), ["stimulants", "food"],
                       "the file is authored in a deliberate order; the screen does not re-sort it")
        XCTAssertEqual(groups[0].chips.map(\.id), ["caffeine", "nicotine"])
    }

    func testFreeTextTagsAreListedApartFromTheChips() {
        let rows = [entry("caffeine"), entry(nil, customLabel: "long drive"),
                    entry(nil, customLabel: "gone", deleted: true)]
        let chips = JournalDayBuilder.chips(dictionary: [behavior("caffeine")], entries: rows)
        let custom = JournalDayBuilder.customEntries(rows)
        XCTAssertEqual(custom.map(\.customLabel), ["long drive"])
        XCTAssertEqual(JournalDayBuilder.taggedCount(chips: chips, customEntries: custom), 2)
    }

    func testAmountIsOnlyReadFromARowThatActuallyCarriesOne() {
        let booleanRow = JournalDayBuilder.chips(dictionary: [behavior("caffeine", kind: .count)],
                                                 entries: [entry("caffeine", kind: .boolean)])[0]
        XCTAssertTrue(booleanRow.isOn)
        XCTAssertNil(booleanRow.amount, "a plain tap records no number, so none is shown")
        XCTAssertTrue(booleanRow.offersAmount, "power depth may still attach one")
    }

    func testAmountStepMatchesTheShapeOfTheBehavior() {
        XCTAssertEqual(JournalChip(behavior: behavior("caffeine", kind: .count), entry: nil).amountStep, 1)
        XCTAssertEqual(JournalChip(behavior: behavior("nap", kind: .quantity, unit: "min"), entry: nil).amountStep, 5,
                       "a nap is not timed to the minute")
        XCTAssertNil(JournalChip(behavior: behavior("caffeine", kind: .count), entry: nil).amountUnit,
                     "a count counts the behaviour itself and carries no physical unit")
    }

    // MARK: - Day choice

    func testYesterdayIsTheSameWallClockTimeOnThePreviousLocalDay() {
        let tz = "Asia/Riyadh"
        let today = JournalDayChoice.today.occurredAt(now: now, tzId: tz)
        let yesterday = JournalDayChoice.yesterday.occurredAt(now: now, tzId: tz)
        XCTAssertEqual(today, now)
        XCTAssertEqual(DayAttribution.localDayKey(yesterday, tz: tz),
                       DayAttribution.localDayKey(DayAttribution.addingDays(-1, to: now, tz: tz), tz: tz))
        XCTAssertTrue(JournalDayChoice.yesterday.isRecall)
        XCTAssertFalse(JournalDayChoice.today.isRecall)
    }

    /// The DST case the calendar arithmetic exists for: subtracting a fixed 86 400 seconds across a
    /// spring-forward boundary lands an hour off and files the tag under the wrong local day, which
    /// is the exact bucket every correlation arm is built from.
    func testYesterdayCrossesADSTBoundaryWithoutSlippingADay() {
        let tz = "America/New_York"
        // 2026-03-09 00:30 local — just after midnight following US spring-forward (2026-03-08 is a
        // 23-hour day), which is exactly where the two arithmetics diverge.
        let reference = DayAttribution.date(fromDayKey: "2026-03-09", tz: tz)!.addingTimeInterval(30 * 60)
        let yesterday = JournalDayChoice.yesterday.occurredAt(now: reference, tzId: tz)
        XCTAssertEqual(DayAttribution.localDayKey(yesterday, tz: tz), "2026-03-08")
        XCTAssertEqual(DayAttribution.localDayKey(reference.addingTimeInterval(-86_400), tz: tz), "2026-03-07",
                       "the fixed-seconds form lands a day early here — that is why the calendar form is used")
    }

    // MARK: - Context status list

    func testAnOpenEndedStatusReadsAsActiveRatherThanMalformed() {
        let open = status(id: "open", start: now.addingTimeInterval(-3600), end: nil)
        let closed = status(id: "closed", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        let removed = status(id: "gone", start: now.addingTimeInterval(-100), end: nil, deleted: true)
        let list = ContextStatusList.from([open, closed, removed], now: now)
        XCTAssertEqual(list.active.map(\.id), ["open"])
        XCTAssertEqual(list.past.map(\.id), ["closed"])
    }

    private func status(id: String, start: Date, end: Date?, deleted: Bool = false) -> ContextStatus {
        ContextStatus(id: id, statusId: ContextStatusKind.travel.rawValue, startAt: start, endAt: end,
                      tzId: "UTC",
                      provenance: Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                                             measuredAt: start, measuredTimezone: "UTC",
                                             recordedAt: start, ingestedAt: start),
                      updatedAt: start, originDeviceId: device, deletedAt: deleted ? start : nil)
    }

    // MARK: - Copy

    /// Every category the SHIPPED dictionary uses must have a heading here, or the screen renders a
    /// raw key like "supplements" as a section title.
    func testEveryShippedCategoryHasABilingualHeading() {
        let categories = BehaviorDictionary.shared.categories
        XCTAssertFalse(categories.isEmpty, "the bundled dictionary failed to load")
        for category in categories {
            let name = JournalCategory.displayName(category)
            XCTAssertNotNil(name, "category \"\(category)\" has no heading — it would render as its raw key")
            XCTAssertNotEqual(name?.en, name?.ar, "category \"\(category)\" is untranslated")
        }
    }

    func testJournalCopyIsBilingualAndWellnessSafe() {
        let strings: [(String, LocalizedString)] = [
            ("title", JournalStrings.title), ("logTile", JournalStrings.logTile),
            ("trust", JournalStrings.trust), ("today", JournalStrings.today),
            ("yesterday", JournalStrings.yesterday), ("dayPickerLabel", JournalStrings.dayPickerLabel),
            ("untappedNote", JournalStrings.untappedNote), ("recallNote", JournalStrings.recallNote),
            ("taggedCount", JournalStrings.taggedCount), ("nothingTaggedYet", JournalStrings.nothingTaggedYet),
            ("amount", JournalStrings.amount), ("amountNotSet", JournalStrings.amountNotSet),
            ("minutes", JournalStrings.minutes),
            ("decreaseAmount", JournalStrings.decreaseAmount), ("increaseAmount", JournalStrings.increaseAmount),
            ("ownTagsTitle", JournalStrings.ownTagsTitle), ("ownTagPlaceholder", JournalStrings.ownTagPlaceholder),
            ("addTag", JournalStrings.addTag), ("ownTagsNote", JournalStrings.ownTagsNote),
            ("logged", JournalStrings.logged), ("notLogged", JournalStrings.notLogged),
            ("addedAnnouncement", JournalStrings.addedAnnouncement),
            ("removedAnnouncement", JournalStrings.removedAnnouncement),
            ("saveFailed", JournalStrings.saveFailed), ("loadFailed", JournalStrings.loadFailed),
            ("sensitiveOffTitle", JournalStrings.sensitiveOffTitle),
            ("sensitiveOffMessage", JournalStrings.sensitiveOffMessage),
            ("contextTitle", JournalStrings.contextTitle),
            ("contextLinkSubtitle", JournalStrings.contextLinkSubtitle),
            ("contextExplainer", JournalStrings.contextExplainer),
            ("contextStart", JournalStrings.contextStart), ("contextOngoing", JournalStrings.contextOngoing),
            ("contextEndNow", JournalStrings.contextEndNow), ("contextStarted", JournalStrings.contextStarted),
            ("contextRange", JournalStrings.contextRange), ("contextEarlier", JournalStrings.contextEarlier),
            ("contextNoneTitle", JournalStrings.contextNoneTitle),
            ("contextNoneMessage", JournalStrings.contextNoneMessage),
            ("contextCustomPlaceholder", JournalStrings.contextCustomPlaceholder),
            ("contextRemoved", JournalStrings.contextRemoved),
            ("contextStartedAnnouncement", JournalStrings.contextStartedAnnouncement),
            ("contextEndedAnnouncement", JournalStrings.contextEndedAnnouncement),
            ("contextDelete", JournalStrings.contextDelete),
        ]
        // The journal records what happened; it never grades it. These are the frames that would
        // turn a log into a scold.
        let bannedEn = ["you should", "you must", "too much", "avoid ", "unhealthy", "bad ", "poor ",
                        "failed", "cheat", "guilt", "excess"]
        let bannedAr = ["يجب عليك", "تجنب", "مفرط", "سيئ", "فشل"]
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

    /// Plan §16 fixes this line for the Journal row. It is a promise about where the data goes, so
    /// it is asserted verbatim rather than left to drift.
    func testTrustLineIsTheOneThePlanSpecifies() {
        XCTAssertEqual(JournalStrings.trust.en, "Used only on your device to find your patterns.")
    }
}

// MARK: - View models, exercised against a real database

@MainActor
final class JournalViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var env: AppEnvironment!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private var tz: String { TimeZone.current.identifier }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-journal-vm-\(UUID().uuidString)", isDirectory: true)
        env = AppEnvironment(database: try Database(directory: tempDir), clock: clock)
    }

    override func tearDownWithError() throws {
        env = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func makeVM() -> JournalViewModel {
        JournalViewModel(dictionary: BehaviorDictionary(behaviors: [
            BehaviorDefinition(id: "caffeine", nameEn: "Caffeine", nameAr: "الكافيين", valueKind: .count,
                               unit: nil, category: "stimulants", sensitiveClass: .sensitivePlus),
            BehaviorDefinition(id: "nap", nameEn: "Nap", nameAr: "قيلولة", valueKind: .quantity,
                               unit: "min", category: "sleep", sensitiveClass: .sensitivePlus),
            BehaviorDefinition(id: "cool_room", nameEn: "Cool bedroom", nameAr: "غرفة نوم باردة",
                               valueKind: .boolean, unit: nil, category: "sleep",
                               sensitiveClass: .sensitivePlus),
        ]))
    }

    private func chip(_ vm: JournalViewModel, _ id: String) throws -> JournalChip {
        try XCTUnwrap(vm.chips.first { $0.id == id })
    }

    /// A casual tap asserts that the behaviour happened and stores NO number — writing "1 coffee"
    /// for a tap would put a value the user never gave into their own exportable record.
    func testACasualTapStoresABooleanAssertionWithNoInventedNumber() throws {
        let vm = makeVM()
        vm.load(env)
        XCTAssertEqual(vm.taggedCount, 0)

        vm.toggle(try chip(vm, "caffeine"), env: env)
        let tagged = try chip(vm, "caffeine")
        XCTAssertTrue(tagged.isOn)
        XCTAssertNil(tagged.amount, "no amount was given, so none is stored")
        let row = try XCTUnwrap(tagged.entry)
        XCTAssertEqual(row.valueKind, .boolean, "the row's existence is the fact")
        XCTAssertNil(row.value)
        XCTAssertTrue(row.isPresent, "the correlation engine reads this as a with-behaviour day")
        XCTAssertEqual(vm.taggedCount, 1)
    }

    func testTappingAgainTombstonesRatherThanDeletes() throws {
        let vm = makeVM()
        vm.load(env)
        vm.toggle(try chip(vm, "caffeine"), env: env)
        let id = try XCTUnwrap(try chip(vm, "caffeine").entry?.id)

        vm.toggle(try chip(vm, "caffeine"), env: env)
        XCTAssertFalse(try chip(vm, "caffeine").isOn)
        let stored = try XCTUnwrap(try env.journal.entry(id: id))
        XCTAssertNotNil(stored.deletedAt, "what the user first said stays recoverable")
    }

    /// A correction is a new row plus a tombstone on the old one, never an in-place edit — so "first
    /// said two, then said three" stays inspectable.
    func testSettingAnAmountSupersedesTheRowInsteadOfEditingIt() throws {
        let vm = makeVM()
        vm.load(env)
        vm.toggle(try chip(vm, "caffeine"), env: env)
        let first = try XCTUnwrap(try chip(vm, "caffeine").entry?.id)

        vm.setAmount(try chip(vm, "caffeine"), to: 3, env: env)
        let updated = try chip(vm, "caffeine")
        XCTAssertEqual(updated.amount, 3)
        XCTAssertEqual(updated.entry?.valueKind, .count)
        XCTAssertNotEqual(updated.entry?.id, first)
        XCTAssertNotNil(try env.journal.entry(id: first)?.deletedAt, "the superseded row is tombstoned, not gone")
        XCTAssertEqual(try env.journal.allEntries().filter { $0.behaviorId == "caffeine" }.count, 1,
                       "exactly one live row per behaviour per day")
    }

    func testAQuantityAmountCarriesTheDictionarysCanonicalUnit() throws {
        let vm = makeVM()
        vm.load(env)
        vm.toggle(try chip(vm, "nap"), env: env)
        vm.setAmount(try chip(vm, "nap"), to: 25, env: env)
        let row = try XCTUnwrap(try chip(vm, "nap").entry)
        XCTAssertEqual(row.valueKind, .quantity)
        XCTAssertEqual(row.unit, "min")
        XCTAssertEqual(row.value, 25)
    }

    /// Stepping an amount down to nothing removes the tag. It does NOT store an explicit zero: a
    /// zero is a real assertion in this model ("it did not happen"), and a stepper bottoming out is
    /// not the same statement as making it.
    func testSteppingAnAmountToZeroClearsTheTagRatherThanStoringAZero() throws {
        let vm = makeVM()
        vm.load(env)
        vm.toggle(try chip(vm, "caffeine"), env: env)
        vm.setAmount(try chip(vm, "caffeine"), to: 1, env: env)
        vm.setAmount(try chip(vm, "caffeine"), to: 0, env: env)

        XCTAssertFalse(try chip(vm, "caffeine").isOn)
        XCTAssertTrue(try env.journal.allEntries().isEmpty, "no live row is left holding a zero")
    }

    /// Yesterday-recall: the tag belongs to yesterday (the axis every correlation buckets on) while
    /// the provenance stays honest about when it was typed.
    func testYesterdayRecallLandsOnYesterdayAndReportsItselfAsRecalled() throws {
        let vm = makeVM()
        vm.day = .yesterday
        vm.load(env)
        vm.toggle(try chip(vm, "cool_room"), env: env)

        let row = try XCTUnwrap(try chip(vm, "cool_room").entry)
        let yesterdayKey = DayAttribution.localDayKey(
            DayAttribution.addingDays(-1, to: clock.now(), tz: tz), tz: tz)
        XCTAssertEqual(row.dayKey(), yesterdayKey)
        XCTAssertTrue(row.isRecalled, "backdating is recorded, never disguised")
        XCTAssertEqual(row.provenance.recordedAt, clock.now(), "recorded when the user said it")

        // And today's chips are unaffected — the two days are separate surfaces over one store.
        vm.day = .today
        vm.load(env)
        XCTAssertFalse(try chip(vm, "cool_room").isOn)
    }

    func testAFreeTextTagIsStoredWithNoBehaviorId() throws {
        let vm = makeVM()
        vm.load(env)
        XCTAssertTrue(vm.addCustomTag("  long drive  ", env: env))
        XCTAssertFalse(vm.addCustomTag("   ", env: env), "an empty tag is not a tag")

        let row = try XCTUnwrap(vm.customEntries.first)
        XCTAssertEqual(row.customLabel, "long drive", "trimmed, and stored in the user's own words")
        XCTAssertNil(row.behaviorId, "free text never enters the dictionary key space")
        XCTAssertEqual(vm.taggedCount, 1)

        vm.removeCustomTag(row, env: env)
        XCTAssertTrue(vm.customEntries.isEmpty)
    }

    /// I7 at the surface: every write this screen makes is readable through the sensitive-connection
    /// repository and disappears with the sensitive purge, which is a file deletion.
    func testEveryJournalWriteIsRemovedByTheSensitivePurge() throws {
        let vm = makeVM()
        vm.load(env)
        vm.toggle(try chip(vm, "caffeine"), env: env)
        vm.addCustomTag("long drive", env: env)
        XCTAssertEqual(try env.journal.allEntries().count, 2)

        try env.database.purgeSensitiveNamespace()
        XCTAssertTrue(try env.journal.allEntries().isEmpty)
    }

    // MARK: - Context statuses

    func testAStatusStartsOpenEndedAndClosesInPlace() throws {
        let vm = ContextStatusViewModel()
        vm.load(env)
        vm.start(kind: .travel, env: env)

        let active = try XCTUnwrap(vm.list.active.first)
        XCTAssertEqual(active.kind, .travel)
        XCTAssertTrue(active.isOpenEnded, "a period is declared when it starts and closed later")

        vm.end(active, env: env)
        XCTAssertTrue(vm.list.active.isEmpty)
        let closed = try XCTUnwrap(vm.list.past.first)
        XCTAssertEqual(closed.id, active.id, "closing sets end_at on the same row — one fact, one row")
        XCTAssertNotNil(closed.endAt)
        XCTAssertEqual(try env.journal.allStatuses().count, 1)
    }

    func testRemovingAPastPeriodIsUndoable() throws {
        let vm = ContextStatusViewModel()
        vm.load(env)
        vm.start(kind: .illness, env: env)
        vm.end(try XCTUnwrap(vm.list.active.first), env: env)
        let closed = try XCTUnwrap(vm.list.past.first)

        vm.remove(closed, env: env)
        XCTAssertTrue(vm.list.isEmpty)
        XCTAssertEqual(vm.pendingUndo?.id, closed.id)

        vm.undoRemove(env)
        XCTAssertEqual(vm.list.past.first?.id, closed.id, "undo restores exactly what the user had declared")
        XCTAssertNil(vm.pendingUndo)
    }

    func testACustomPeriodAnnotatesWithTheUsersOwnWords() throws {
        let vm = ContextStatusViewModel()
        vm.load(env)
        vm.start(kind: nil, customLabel: "exam week", env: env)

        let status = try XCTUnwrap(vm.list.active.first)
        XCTAssertNil(status.kind)
        XCTAssertEqual(status.displayLabel.en, "exam week")
        XCTAssertTrue(status.caveat.en.contains("exam week"),
                      "a custom period gets the generic caveat naming what the user wrote")
        XCTAssertTrue(status.caveat.ar.contains("exam week"))
    }
}
