import XCTest
@testable import BADAN

/// EPIC-15 — the iOS automation *surfaces* (the setup wizard's honesty labels + the schedule list on
/// Export & Automation Health), as opposed to `AutomationEngineTests` which pins the engine's
/// decisions. Two load-bearing guarantees are enforced here:
///
///  - `testEveryTierAndCadenceHasBilingualCopyThatIsNeverARawToken` is the §16 rule in test form:
///    the user must never see `opportunisticBackground`/`shortcutDriven`, so every tier and cadence
///    the surfaces render is checked to produce non-empty en+ar copy that is not its own raw case
///    name. A missing/empty label would leave a wizard option or a schedule chip blank.
///  - `testNextRunIsAlwaysEstimateLanguageNeverAWallClockPromise` guards the scheduling-honesty
///    thesis: no "next run" label may be an un-caveated wall-clock time, and the estimate case falls
///    back cleanly when there is no date to anchor.
@MainActor
final class AutomationSurfacesTests: XCTestCase {
    private var tempDir: URL!
    private var env: AppEnvironment!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    private let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-automation-surfaces-\(UUID().uuidString)", isDirectory: true)
        let db = try Database(directory: tempDir)
        env = AppEnvironment(database: db, clock: clock)
    }

    override func tearDownWithError() throws {
        env = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var service: AutomationScheduleService { AutomationScheduleService(env: env) }

    private func schedule(tier: AutomationTier = .opportunisticBackground,
                          cadence: AutomationCadence = .dailyBestEffort,
                          enabled: Bool = true, consecutiveFailures: Int = 0,
                          nextExpectedWindow: Date? = nil) -> AutomationSchedule {
        AutomationSchedule(id: "s", templateId: "t", tier: tier, desiredCadence: cadence,
                           enabled: enabled, consecutiveFailures: consecutiveFailures,
                           nextExpectedWindow: nextExpectedWindow, createdAt: clock.now(),
                           updatedAt: clock.now(), originDeviceId: deviceId)
    }

    // MARK: - Plain-language mapping (§16: never a raw token)

    func testEveryTierAndCadenceHasBilingualCopyThatIsNeverARawToken() {
        for tier in AutomationTier.allCases {
            for label in [AutomationPresentation.tierLabel(tier),
                          AutomationPresentation.tierTitle(tier),
                          AutomationPresentation.tierChip(tier)] {
                XCTAssertFalse(label.en.isEmpty, "\(tier) has empty en copy")
                XCTAssertFalse(label.ar.isEmpty, "\(tier) has empty ar copy")
                XCTAssertNotEqual(label.en, tier.rawValue, "\(tier) leaked its raw token")
            }
            XCTAssertFalse(AutomationPresentation.tierIcon(tier).isEmpty)
        }
        for cadence in AutomationCadence.allCases {
            for label in [AutomationPresentation.cadenceLabel(cadence),
                          AutomationPresentation.cadenceHint(cadence)] {
                XCTAssertFalse(label.en.isEmpty, "\(cadence) has empty en copy")
                XCTAssertFalse(label.ar.isEmpty, "\(cadence) has empty ar copy")
                XCTAssertNotEqual(label.en, cadence.rawValue, "\(cadence) leaked its raw token")
            }
        }
    }

    // MARK: - Scheduling honesty: no banned promise in ANY automation copy, either language

    /// The anti-HAE guard, broadened past the tier labels to EVERY user-facing automation string in
    /// BOTH languages (§13.7 / plan §4.10). A best-effort schedule must never read as an appointment:
    /// no "cron", no un-caveated "guaranteed", and no wall-clock daily promise ("every day at …" /
    /// "كل يوم في …") — on the tier lines, the cadence copy, OR the next-run label. Previously this
    /// only scanned `tierLabel` in English, so a promise slipped into the cadence/next-run strings or
    /// the Arabic side would have gone unnoticed. The shipped copy is already clean; this closes that
    /// gap rather than fixing a leak.
    func testNoAutomationCopyPromisesGuaranteedCronOrWallClock() {
        // Applied to `.en` (lowercased) and `.ar` alike. "cron" is Latin in either language; the two
        // Arabic tokens are the equivalents of the English promises — "مضمون" (guaranteed) and
        // "كل يوم في" (a daily wall-clock time). "مؤكد" is deliberately NOT banned: the Shortcuts
        // line uses it INSIDE an explicit caveat ("a reminder, not a confirmed appointment"), which
        // is the honest wording this guard is meant to protect, not a leak.
        let banned = ["cron", "guaranteed", "every day at", "مضمون", "كل يوم في"]

        var copy: [(label: String, string: LocalizedString)] = []
        for tier in AutomationTier.allCases {
            copy.append(("tierLabel(\(tier))", AutomationPresentation.tierLabel(tier)))
            copy.append(("tierTitle(\(tier))", AutomationPresentation.tierTitle(tier)))
            copy.append(("tierChip(\(tier))", AutomationPresentation.tierChip(tier)))
        }
        for cadence in AutomationCadence.allCases {
            copy.append(("cadenceLabel(\(cadence))", AutomationPresentation.cadenceLabel(cadence)))
            copy.append(("cadenceHint(\(cadence))", AutomationPresentation.cadenceHint(cadence)))
        }
        let nextKinds: [AutomationPresentation.NextWindow] =
            [.onTap, .inShortcuts, .whenNewData, .aroundEstimate, .asBackgroundAllows]
        for kind in nextKinds {
            // With a formatted estimate AND without — the estimate branch embeds a date, which is
            // exactly where a wall-clock phrasing would otherwise sneak in.
            copy.append(("nextWindow(\(kind),date)", AutomationPresentation.nextWindowLabel(kind, dateText: "3 PM")))
            copy.append(("nextWindow(\(kind),nil)", AutomationPresentation.nextWindowLabel(kind, dateText: nil)))
        }
        copy.append(("pausedReason", AutomationPresentation.pausedReason(env.format)))

        for (label, string) in copy {
            let en = string.en.lowercased()
            for token in banned {
                XCTAssertFalse(en.contains(token), "\(label) EN leaked a banned promise: '\(token)'")
                XCTAssertFalse(string.ar.contains(token), "\(label) AR leaked a banned promise: '\(token)'")
            }
        }
    }

    // MARK: - Status

    func testStatusReflectsEnabledAndFailureBudget() {
        XCTAssertEqual(AutomationPresentation.status(schedule()), .active)
        XCTAssertEqual(AutomationPresentation.status(schedule(enabled: false)), .off)
        XCTAssertEqual(AutomationPresentation.status(
            schedule(consecutiveFailures: AutomationSchedule.failureBudget)), .paused)
        // A paused schedule reads as paused even if the user also had it enabled.
        XCTAssertEqual(AutomationPresentation.status(
            schedule(enabled: true, consecutiveFailures: AutomationSchedule.failureBudget)), .paused)
        for status in [AutomationPresentation.StatusKind.active, .paused, .off] {
            let label = AutomationPresentation.statusLabel(status)
            XCTAssertFalse(label.en.isEmpty); XCTAssertFalse(label.ar.isEmpty)
            XCTAssertFalse(status.icon.isEmpty)
        }
        let paused = AutomationPresentation.pausedReason(env.format)
        XCTAssertFalse(paused.en.isEmpty); XCTAssertFalse(paused.ar.isEmpty)
    }

    // MARK: - Next run is always an estimate

    func testNextRunIsAlwaysEstimateLanguageNeverAWallClockPromise() {
        XCTAssertEqual(AutomationPresentation.nextWindow(schedule(tier: .manualOnly)), .onTap)
        XCTAssertEqual(AutomationPresentation.nextWindow(schedule(tier: .shortcutDriven)), .inShortcuts)
        XCTAssertEqual(AutomationPresentation.nextWindow(schedule(cadence: .onNewData)), .whenNewData)
        XCTAssertEqual(AutomationPresentation.nextWindow(
            schedule(cadence: .dailyBestEffort, nextExpectedWindow: clock.now())), .aroundEstimate)
        XCTAssertEqual(AutomationPresentation.nextWindow(
            schedule(cadence: .dailyBestEffort, nextExpectedWindow: nil)), .asBackgroundAllows)

        // Every kind resolves to non-empty bilingual copy.
        let kinds: [AutomationPresentation.NextWindow] =
            [.onTap, .inShortcuts, .whenNewData, .aroundEstimate, .asBackgroundAllows]
        for kind in kinds {
            let label = AutomationPresentation.nextWindowLabel(kind, dateText: "3 PM")
            XCTAssertFalse(label.en.isEmpty); XCTAssertFalse(label.ar.isEmpty)
        }
        // The estimate case embeds the (caveated) date, and falls back cleanly when there is none —
        // never printing a bare "around " with nothing after it.
        XCTAssertTrue(AutomationPresentation.nextWindowLabel(.aroundEstimate, dateText: "3 PM").en.contains("3 PM"))
        let fallback = AutomationPresentation.nextWindowLabel(.aroundEstimate, dateText: nil)
        XCTAssertFalse(fallback.en.isEmpty)
        XCTAssertFalse(fallback.en.hasSuffix("around "))
    }

    // MARK: - Schedule service CRUD

    func testCreateReadToggleResumeDelete() throws {
        let template = try ExportManageService(env: env).createTemplate(
            name: "Weekly vitals", scope: ExportScope(), rangeRule: .lastNDays(7), format: .csv)
        let created = try service.create(templateId: template.id, tier: .opportunisticBackground,
                                         cadence: .dailyBestEffort, quietHours: nil)
        XCTAssertTrue(service.allSchedules().contains { $0.id == created.id })
        XCTAssertTrue(service.hasSchedule(templateId: template.id))

        service.setEnabled(id: created.id, enabled: false)
        XCTAssertEqual(service.schedule(id: created.id)?.enabled, false)

        // Resume is a no-op reset for an unpaused schedule; it must not throw or drop the row.
        service.resume(id: created.id)
        XCTAssertEqual(service.schedule(id: created.id)?.consecutiveFailures, 0)

        service.delete(id: created.id)
        XCTAssertFalse(service.allSchedules().contains { $0.id == created.id })
    }

    func testSchedulableTemplatesExcludesPresets() throws {
        ExportManageService(env: env).ensureSeeded()
        let user = try ExportManageService(env: env).createTemplate(
            name: "Mine", scope: ExportScope(), rangeRule: .allTime, format: .json)
        let schedulable = service.schedulableTemplates()
        XCTAssertTrue(schedulable.contains { $0.id == user.id })
        XCTAssertFalse(schedulable.contains { $0.isPreset }, "a preset was offered as schedulable")
    }
}
