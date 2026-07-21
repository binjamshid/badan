import Foundation

/// Ties the pure `ReportBuilder` to the `reports` store: generate a model for a period, persist its
/// metadata (replacing any prior row for the same period+version), and answer the substrate's "is a
/// weekly report due?" question. Rendering the PDF is deliberately NOT here — the weekly trigger
/// runs on a background queue where UIKit's print stack does not belong, so this persists only the
/// model + metadata and the artifact is rendered on demand when the user opens or shares a report.
///
/// `@unchecked Sendable` is earned the same way the background bridge earns it: it is called from
/// the substrate's background queue, holds only value/Sendable dependencies plus repositories whose
/// single `SQLiteConnection` serializes every access through its own recursive lock, and keeps no
/// mutable state of its own.
final class ReportGenerationService: @unchecked Sendable {
    private let builder: ReportBuilder
    private let reports: ReportRepository
    private let clock: Clock
    private let deviceId: String
    private let timezoneProvider: () -> String
    /// Whether to include the medication-adherence roll-up (counts only). The composition root can
    /// turn it off; on by default because a user's own aggregate adherence belongs in their report.
    private let includeAdherence: Bool

    init(builder: ReportBuilder, reports: ReportRepository, clock: Clock, deviceId: String,
                timezone: @escaping () -> String, includeAdherence: Bool = true) {
        self.builder = builder
        self.reports = reports
        self.clock = clock
        self.deviceId = deviceId
        self.timezoneProvider = timezone
        self.includeAdherence = includeAdherence
    }

    /// Generate the report for `periodKey` and persist its metadata, replacing any prior row for the
    /// same (period, algorithm version). Returns the saved record and the freshly-built model. An
    /// empty period is persisted honestly (an `hasSufficientData == false` model), never skipped —
    /// so the trigger won't try to regenerate it every wake.
    @discardableResult
    func generateAndSave(periodKey: String, now: Date) throws -> (record: ReportRecord, model: ReportModel) {
        let tz = timezoneProvider()
        let model = try builder.generate(periodKey: periodKey, tz: tz, now: now, includeAdherence: includeAdherence)
        let record = try reports.save(
            periodKey: model.periodKey, algorithmVersionId: model.algorithmVersionId,
            generatedAt: model.generatedAt, sectionsIncluded: model.sectionsIncluded,
            artifactPath: nil, sha256: model.sha256, now: now, originDeviceId: deviceId)
        return (record, model)
    }

    /// The substrate's weekly entry point: generate and persist every weekly report `ReportTrigger`
    /// says is due — the last completed ISO week, plus any bounded backfill for weeks a run of
    /// missed wakes skipped — and return the period keys actually generated, newest first.
    /// Idempotent across repeated opportunistic wakes (dedup is by existing period key).
    ///
    /// A failure part-way through is NOT swallowed: it throws, and the reports generated before it
    /// stay persisted. That is deliberate — each report is an independent row, so a partial
    /// backfill is a smaller gap rather than a corrupt state, and the next wake resumes from
    /// whatever is still missing.
    @discardableResult
    func generateDueWeekly(now: Date) throws -> [String] {
        let tz = timezoneProvider()
        let existing = try reports.periodKeys(algorithmVersionId: ReportBuilder.algorithm.id)
        let due = ReportTrigger.dueWeeklyPeriodKeys(asOf: now, tz: tz, existingPeriodKeys: existing)
        for periodKey in due {
            _ = try generateAndSave(periodKey: periodKey, now: now)
        }
        return due
    }
}
