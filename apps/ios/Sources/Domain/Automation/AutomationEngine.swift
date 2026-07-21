import Foundation

// MARK: - Seams
//
// The engine's own logic is the due-gate and the failure budget, both pure (see
// `AutomationSchedule.swift`). Everything with a side effect it depends on goes behind one of these
// three protocols so `AutomationEngineTests` can drive the whole loop against fakes, and so the
// engine never has to import HealthKit, `UserNotifications`, or the export writers to be tested.

/// Whether new measurement data has arrived on the ingested axis since a watermark — the
/// `onNewData` cadence's gate. Deliberately the ingested axis (`ingested_at`), the SAME axis the
/// export cursor advances on (`ExportResult.maxIngestedAt`), so "there is new data to export" here
/// and "the cursor moved" there can never disagree. A late-arriving row (measured last week,
/// ingested today) counts as new, which is correct: it is exactly what a fresh export would pick up.
protocol AutomationDataFreshnessProbing {
    /// True when any raw/interval/session row has `ingested_at` strictly greater than `watermark`
    /// (or any such row exists at all when `watermark` is nil — a never-run schedule).
    func hasDataIngested(after watermark: Date?) -> Bool
}

/// Fires the "an automation was paused" local notification (an allowed notification class, NOT the
/// Phase-3 reminder decision engine). A seam because the engine runs off the main actor and must
/// not itself import `UserNotifications`; the real implementation forwards to the existing
/// `NotificationScheduler`. Best-effort by contract: the load-bearing honesty guarantee is the
/// VISIBLE pause (stored state the UI shows), which holds with no notification permission at all;
/// this is the nudge on top.
protocol AutomationPauseNotifying {
    func automationPaused(scheduleId: String, language: AppLanguage)
}

/// Runs one saved template through the EXISTING Phase-1 runner, unattended. A seam so the engine can
/// be tested against a fake that returns canned outcomes; the real conformance is on `ExportRunner`
/// and calls its `runTemplate` verbatim (cursor two-phase commit, ledger, everything) — the engine
/// composes that path, it does not reimplement any of it.
protocol AutomationTemplateRunning {
    /// Runs `template` unattended and returns only the terminal outcome. Unattended means NO
    /// sensitive consent and NO passphrase are available, so `runTemplate` refuses a sensitive
    /// scope (recording `failedGeneration`/`sensitiveConfirmationMissing`) — a scheduled automation
    /// must never carry standing permission to export meds/symptoms.
    func runScheduledTemplate(_ template: ExportTemplate, trigger: ExportTrigger) async -> ExportOutcome
}

/// `ExportRunner` IS the scheduled-template runner — this conformance is the whole "compose Phase 1,
/// don't rebuild it" of EPIC-15. `runTemplate` already does resolve → generate → deliver → record
/// `ExportRun` with the cursor's two-phase commit; the engine only decides WHEN to call it.
extension ExportRunner: AutomationTemplateRunning {
    func runScheduledTemplate(_ template: ExportTemplate,
                              trigger: ExportTrigger) async -> ExportOutcome {
        // consent: nil / passphrase: nil (the defaults) — an unattended run cannot collect either,
        // so a sensitive template is refused inside `runTemplate` rather than silently narrowed.
        await runTemplate(template, trigger: trigger).run.outcome
    }
}

// MARK: - Engine

/// What one `evaluateDue` pass did, for the substrate's `background_runs` diagnostics and for
/// tests. All counts, never values.
struct AutomationEvaluationSummary: Equatable, Sendable {
    /// Enabled `opportunisticBackground` schedules examined this wake.
    var considered: Int = 0
    /// Schedules that passed every due gate and were actually run through the template runner.
    var ran: Int = 0
    /// Schedules that transitioned INTO the paused state this wake (each fired one notification).
    var pausedThisRun: Int = 0
}

/// EPIC-15 — the scheduling & automation engine. Invoked by the Phase-0 substrate wakeups
/// (`BGAppRefresh` on iOS, the WorkManager sync worker on Android): it reads the enabled
/// background-tier schedules, decides which are due (cadence / quiet hours / data-newness), and
/// runs each due one through the EXISTING `ExportRunner.runTemplate`, then updates the failure
/// budget — pausing and notifying at three consecutive failures.
///
/// It owns neither generation nor delivery nor the cursor (all `runTemplate`'s), and it advances no
/// cursor itself — doing so would risk the exact Android cursor-advance data-loss class Phase 0's
/// audit caught. Its only writes are to `automation_schedules` (the bookkeeping the failure budget
/// needs).
///
/// `@unchecked Sendable` is earned: it holds only immutable references to collaborators that are
/// each independently safe to touch off the main actor — the repositories serialize through
/// `SQLiteConnection`'s lock, the runner and probe are stateless over a locked connection, and the
/// notifier hops to the main actor itself. The engine keeps no mutable state of its own. This lets
/// the iOS substrate bridge into it from a `BGTask` background queue.
final class AutomationEngine: @unchecked Sendable {
    private let schedules: AutomationScheduleRepository
    private let templates: ExportTemplateRepository
    private let runner: AutomationTemplateRunning
    private let freshness: AutomationDataFreshnessProbing
    private let notifier: AutomationPauseNotifying
    private let clock: Clock
    /// Injected so quiet-hours evaluation is deterministic in tests. The real one is device-local,
    /// which is the time zone the user set their quiet hours in.
    private let calendar: Calendar

    init(schedules: AutomationScheduleRepository, templates: ExportTemplateRepository,
         runner: AutomationTemplateRunning, freshness: AutomationDataFreshnessProbing,
         notifier: AutomationPauseNotifying, clock: Clock, calendar: Calendar = .current) {
        self.schedules = schedules
        self.templates = templates
        self.runner = runner
        self.freshness = freshness
        self.notifier = notifier
        self.clock = clock
        self.calendar = calendar
    }

    /// Evaluate every enabled background-tier schedule and run the ones that are due.
    ///
    /// - Parameter trigger: the `ExportTrigger` recorded on each `ExportRun` — `.scheduledOpportunistic`
    ///   for an iOS best-effort wake, `.scheduledWork` for Android's WorkManager. The tier of the
    ///   schedule is `opportunisticBackground` either way; the trigger records which platform's
    ///   mechanism actually fired, so the ledger never claims iOS's substrate ran when WorkManager did.
    ///
    /// Never throws: a schedule whose template was deleted out from under it, or whose read fails,
    /// is skipped rather than aborting the batch — one broken schedule must not stop the others.
    @discardableResult
    func evaluateDue(now: Date, trigger: ExportTrigger) async -> AutomationEvaluationSummary {
        var summary = AutomationEvaluationSummary()
        let candidates = (try? schedules.dueCandidates()) ?? []
        for schedule in candidates {
            summary.considered += 1

            // `hasNewData` is only meaningful for `onNewData`; skip the DB read otherwise. The
            // reference watermark is `lastSuccessAt` (data ingested since we last succeeded) — kept
            // on the schedule itself so the engine never has to reach into the cursor tables, which
            // stay entirely `runTemplate`'s domain.
            let hasNewData = schedule.desiredCadence == .onNewData
                ? freshness.hasDataIngested(after: schedule.lastSuccessAt)
                : false

            guard case .due = AutomationDueEvaluator.verdict(
                for: schedule, now: now, hasNewData: hasNewData, calendar: calendar) else {
                continue
            }

            // A due schedule pointing at a since-deleted template can't run. Skip it (no strike —
            // this is a broken configuration the UI must repair, not a delivery that failed).
            guard let template = try? templates.template(id: schedule.templateId) else { continue }

            let outcome = await runner.runScheduledTemplate(template, trigger: trigger)
            summary.ran += 1

            apply(outcome: outcome, to: schedule, now: now, into: &summary)
        }
        return summary
    }

    /// Fold one run's outcome into the schedule's failure budget and persist it. The pure
    /// `AutomationBudget.applyOutcome` decides the numbers; this method is only the I/O that
    /// commits them and fires the pause notification on the transition into paused.
    private func apply(outcome: ExportOutcome, to schedule: AutomationSchedule, now: Date,
                       into summary: inout AutomationEvaluationSummary) {
        let update = AutomationBudget.applyOutcome(outcome, to: schedule, now: now)
        switch update.kind {
        case .success:
            let estimate = schedule.desiredCadence.estimatedNextWindow(afterLastSuccess: now)
            try? schedules.recordSuccess(id: schedule.id, at: now,
                                         nextExpectedWindow: estimate, now: now)
        case .failure:
            try? schedules.recordFailure(id: schedule.id,
                                         consecutiveFailures: update.consecutiveFailures, now: now)
            if update.didJustPause {
                summary.pausedThisRun += 1
                // NEVER a silent death: the schedule is now visibly paused (derived from the count
                // just written) AND the user is told. Language from the template's own scope,
                // captured config, matching how the medication reminders pick their language.
                let language = (try? templates.template(id: schedule.templateId))?.scope.language ?? .en
                notifier.automationPaused(scheduleId: schedule.id, language: language)
            }
        case .neutral:
            break
        }
    }
}
