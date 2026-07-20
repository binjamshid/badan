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
        remindersTruncatedCount: Int = 0
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            appVersion: "0.1.0", deviceId: "device-abc", language: "en", depth: "casual",
            schemaVersion: 3, mainBytes: 5_242_880, sensitiveBytes: 32_768,
            isStorageFallback: isStorageFallback, isBackupHardened: isBackupHardened,
            isHealthKitConnected: true,
            lastSyncAt: lastSyncAt, isSampleDataActive: isSampleDataActive,
            remindersTruncatedCount: remindersTruncatedCount)
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
    func testPlainTextContainsNoHealthData() {
        let text = report(isSampleDataActive: true, remindersTruncatedCount: 3)
            .plainText(dateFormatter: formatter).lowercased()

        for leak in ["bpm", "kg", "heart", "sleep", "weight", "medication", "symptom", "steps"] {
            XCTAssertFalse(text.contains(leak),
                           "diagnostics must carry no health data — found \"\(leak)\"")
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
