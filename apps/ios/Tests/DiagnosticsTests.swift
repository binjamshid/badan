import XCTest
@testable import BADAN

/// (G2) BADAN ships no crash or analytics SDK — a deliberate local-first decision that also means
/// a beta user's "my sleep stopped showing up" is otherwise unanswerable. `DiagnosticsReport` is
/// the observability that posture requires, so it has to be both accurate and safe to share.
final class DiagnosticsTests: XCTestCase {

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func report(
        isStorageFallback: Bool = false,
        isBackupHardened: Bool? = true,
        lastSyncAt: Date? = Date(timeIntervalSince1970: 1_783_000_000),
        isSampleDataActive: Bool = false,
        remindersTruncatedCount: Int = 0,
        backgroundHealth: BackgroundHealthSummary? = DiagnosticsTests.backgroundHealth()
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            appVersion: "0.1.0", deviceId: "device-abc", language: "en", depth: "casual",
            schemaVersion: 3, mainBytes: 5_242_880, sensitiveBytes: 32_768,
            isStorageFallback: isStorageFallback, isBackupHardened: isBackupHardened,
            isHealthKitConnected: true,
            lastSyncAt: lastSyncAt, isSampleDataActive: isSampleDataActive,
            remindersTruncatedCount: remindersTruncatedCount,
            backgroundHealth: backgroundHealth)
    }

    /// (EPIC-04) A representative background rollup: some wakes completed, a couple landed while
    /// the device was locked, one ran out of time. All three are ordinary.
    ///
    /// Outcomes are listed in `BackgroundRunOutcome.allCases` order because that is the order
    /// `BackgroundRunRepository.summary` emits them in, and the copied text renders the array as
    /// given — a fixture in a different order would assert a string the app never produces.
    static func backgroundHealth() -> BackgroundHealthSummary {
        BackgroundHealthSummary(
            windowDays: 14, totalRuns: 41,
            lastRunAt: Date(timeIntervalSince1970: 1_783_000_000),
            lastRunKind: .hkObserverWake, lastRunOutcome: .completed,
            outcomeCounts: [.init(outcome: .completed, count: 38),
                            .init(outcome: .expired, count: 1),
                            .init(outcome: .storeLocked, count: 2)],
            handlerLatencyP50Ms: 3, handlerLatencyP99Ms: 11, handlerLatencyMaxMs: 14)
    }

    // MARK: - The report answers the questions support actually asks

    func testPlainTextCarriesTheFactsThatExplainCommonFailures() {
        let text = report().plainText(dateFormatter: formatter)

        for expected in ["app_version: 0.1.0", "schema_version: 3", "healthkit_connected: true",
                         "storage_mode: normal", "sample_data_active: false"] {
            XCTAssertTrue(text.contains(expected), "diagnostics must state \"\(expected)\"")
        }
    }

    /// The single most important line: a store that fell back to scratch/in-memory (EDGE-05) is
    /// losing everything on quit, and "my data keeps disappearing" is exactly the report it
    /// explains. It must be unmissable in pasted text, not a subtle flag.
    func testTemporaryStorageModeIsStatedLoudly() {
        let text = report(isStorageFallback: true).plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("storage_mode: TEMPORARY (not persisting)"))
    }

    func testNeverSyncedIsStatedRatherThanLeftBlank() {
        let text = report(lastSyncAt: nil).plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("last_sync_attempt: none this session"),
                      "an absent sync must be an explicit fact, not an empty value that reads "
                          + "like a bug in the report itself")
    }

    func testSampleDataAndReminderCapAreReported() {
        let text = report(isSampleDataActive: true, remindersTruncatedCount: 41)
            .plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("sample_data_active: true"),
                      "\"my numbers look wrong\" is usually this")
        XCTAssertTrue(text.contains("reminders_dropped_by_os_cap: 41"),
                      "\"a reminder never arrived\" is usually this (F6)")
    }

    /// Sharing this must be a safe act rather than one the user has to weigh: it describes the
    /// shape of the install, never the health data inside it.
    ///
    /// (EPIC-04) The background section is the newest way this could go wrong: `background_runs`
    /// carries a `work_done` payload, and the day someone widens it from counts to "what changed"
    /// this report starts leaking through a column nobody thought of as health data. The
    /// value-freeness rule is enforced at the storage layer too
    /// (`BackgroundSubstrateTests.testWorkDoneJSONContainsOnlyIntegerCounts`); this asserts it
    /// where the leak would actually reach a support inbox.
    func testPlainTextContainsNoHealthData() {
        let text = report(isSampleDataActive: true, remindersTruncatedCount: 3)
            .plainText(dateFormatter: formatter).lowercased()

        for leak in ["bpm", "heart", "sleep", "weight", "medication", "symptom", "steps"] {
            XCTAssertFalse(text.contains(leak),
                           "diagnostics must carry no health data — found \"\(leak)\"")
        }
        // "kg" is checked with a leading-boundary rule rather than as a bare substring. It is the
        // only term in this list short enough to occur inside an ordinary English word, and it
        // does — "ba(ckg)round" — so once EPIC-04 added `background_*` lines a plain
        // `contains("kg")` failed on text containing no health data at all. A check that cries
        // wolf is a check someone eventually deletes, which would cost the real guarantee. Every
        // shape a genuine leak takes still matches: "80 kg", "weight_kg", "mass=kg".
        XCTAssertFalse(Self.containsUnitToken(text, "kg"),
                       "diagnostics must carry no health data — found a \"kg\" unit token")
    }

    /// `term` occurring somewhere it is not merely the tail of a longer word.
    private static func containsUnitToken(_ text: String, _ term: String) -> Bool {
        var from = text.startIndex
        while let range = text.range(of: term, range: from..<text.endIndex) {
            let precededByLetter = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)].isLetter
            if !precededByLetter { return true }
            from = range.upperBound
        }
        return false
    }

    // MARK: - Background health (EPIC-04)

    /// "Background sync never happens on my phone" is otherwise unanswerable: BADAN ships no
    /// analytics, so if the run log is not in the paste there is nothing to look at.
    func testBackgroundActivityIsReported() {
        let text = report().plainText(dateFormatter: formatter)

        XCTAssertTrue(text.contains("background_runs_14d: 41"))
        XCTAssertTrue(text.contains("background_last_kind: hkObserverWake"))
        XCTAssertTrue(text.contains("background_outcomes_14d: completed=38,expired=1,storeLocked=2"),
                      "the outcome mix is what distinguishes \"wakes never arrive\" from \"wakes "
                          + "arrive and find the device locked\"")
    }

    /// The handler-latency lines are the only evidence anywhere that HealthKit's three-strikes
    /// budget is being respected on a real device — the failure they guard against is silent by
    /// design, so a soak that cannot read these numbers cannot be judged.
    func testHandlerLatencyIsReportedSoTheThreeStrikesBudgetIsMeasurable() {
        let text = report().plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("background_handler_ms_p50: 3"))
        XCTAssertTrue(text.contains("background_handler_ms_p99: 11"))
        XCTAssertTrue(text.contains("background_handler_ms_max: 14"))
    }

    func testAbsentBackgroundHistoryIsStatedRatherThanLeftBlank() {
        let text = report(backgroundHealth: BackgroundHealthSummary(
            windowDays: 14, totalRuns: 0, lastRunAt: nil, lastRunKind: nil, lastRunOutcome: nil,
            outcomeCounts: [], handlerLatencyP50Ms: nil, handlerLatencyP99Ms: nil,
            handlerLatencyMaxMs: nil)).plainText(dateFormatter: formatter)

        XCTAssertTrue(text.contains("background_last_run: none"))
        XCTAssertTrue(text.contains("background_outcomes_14d: none"))
        XCTAssertTrue(text.contains("background_handler_ms_p99: n/a"),
                      "an absent measurement must be an explicit fact, not an empty value that "
                          + "reads like a bug in the report itself")
    }

    /// A locked device shows up in the run log constantly and is entirely normal
    /// (`BackgroundRunOutcome.storeLocked`). Nothing in the shareable text may frame it as a
    /// failure, or every support conversation starts with a false alarm.
    func testLockedDeviceOutcomeIsNotDescribedAsAnError() {
        let text = report().plainText(dateFormatter: formatter).lowercased()
        for alarm in ["fail", "error:", "problem", "broken"] {
            XCTAssertFalse(text.contains(alarm),
                           "background diagnostics must stay non-alarmist — found \"\(alarm)\"")
        }
    }

    /// Plan §13.7 / §4.10: no surface driven by the background substrate may promise a wall-clock
    /// time, and "cron" never appears on-device.
    func testBackgroundCopyPromisesNoSchedule() {
        let strings = BackgroundRunOutcome.allCases.map { DiagnosticsScreen.label(for: $0) }
        for string in strings {
            for banned in ["cron", "every day at", "guaranteed", "each hour"] {
                XCTAssertFalse(string.en.lowercased().contains(banned),
                               "\"\(string.en)\" promises a schedule iOS does not honour")
            }
            XCTAssertFalse(string.ar.isEmpty, "every user-facing string needs en AND ar")
        }
    }

    // MARK: - Backup hardening read-back (ledger #20)

    func testBackupHardeningConfirmedIsStatedExplicitly() {
        let text = report(isBackupHardened: true).plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("backup_excluded_and_protected: true"))
    }

    /// The whole point of the read-back (see `DatabaseHardeningTests`): if it ever disagrees
    /// with `docs/PRIVACY_POLICY.md` §3's unconditional claim, that has to be a fact someone can
    /// see, not a silent `false` indistinguishable from "field not populated".
    func testBackupHardeningNotConfirmedIsStatedExplicitly() {
        let text = report(isBackupHardened: false).plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("backup_excluded_and_protected: false"))
    }

    func testBackupHardeningInapplicableIsStatedAsNotApplicable() {
        let text = report(isBackupHardened: nil).plainText(dateFormatter: formatter)
        XCTAssertTrue(text.contains("backup_excluded_and_protected: n/a"))
    }

    // MARK: - Byte formatting

    func testFormatBytesIsReadableAcrossMagnitudes() {
        XCTAssertEqual(DiagnosticsScreen.formatBytes(0), "0 B")
        XCTAssertEqual(DiagnosticsScreen.formatBytes(512), "512 B")
        XCTAssertEqual(DiagnosticsScreen.formatBytes(1024), "1.0 KB")
        XCTAssertEqual(DiagnosticsScreen.formatBytes(5_242_880), "5.0 MB")
        XCTAssertEqual(DiagnosticsScreen.formatBytes(2_147_483_648), "2.0 GB")
    }
}
