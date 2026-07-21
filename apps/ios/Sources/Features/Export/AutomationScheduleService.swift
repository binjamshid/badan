import Foundation

/// The read/write path the two automation surfaces (setup wizard + Export & Automation Health) sit
/// on, in the shape of `ExportManageService`: a thin, main-actor struct that composes the existing
/// `AutomationScheduleRepository` over the one `env.database.main` connection every other repository
/// holds — not a second write lock. It owns no scheduling logic; the failure budget, the due gate
/// and the pause threshold all live in the engine and the domain (which this file never touches,
/// per the lane boundary). This is only the CRUD the UI needs.
///
/// It deliberately does NOT run schedules. A background schedule fires from the substrate wake
/// (`AutomationEngine.evaluateDue`); a Shortcuts schedule fires from the App Intent; a "run now" tap
/// runs the schedule's *template* through the existing attended path (`TemplateRunModel`), which is
/// the same thing the templates section already does. So creating a schedule here never implies this
/// service will run it — the honesty the tier label promises holds because nothing here can break it.
@MainActor
struct AutomationScheduleService {
    let env: AppEnvironment

    private var repo: AutomationScheduleRepository { AutomationScheduleRepository(env.database.main) }
    private var templatesRepo: ExportTemplateRepository { ExportTemplateRepository(env.database.main) }

    // MARK: - Reads

    /// Every live schedule, including paused and disabled ones — the dashboard MUST show a paused
    /// schedule so the pause is never invisible (the repository returns them for exactly this).
    func allSchedules() -> [AutomationSchedule] { (try? repo.all()) ?? [] }

    func schedule(id: String) -> AutomationSchedule? { try? repo.schedule(id: id) }

    func template(id: String) -> ExportTemplate? { try? templatesRepo.template(id: id) }

    /// The user's own templates — the ones the wizard offers to schedule. Presets are excluded on
    /// purpose: they are share-sheet-destined Quick Export shapes, and a background schedule can only
    /// actually *deliver* to a folder destination, so offering to schedule a preset would set an
    /// expectation the delivery can't meet.
    func schedulableTemplates() -> [ExportTemplate] {
        ((try? templatesRepo.all()) ?? []).filter { !$0.isPreset }
    }

    /// Whether a template already has a live schedule — so the wizard doesn't silently create a
    /// second one for the same template and the health screen can annotate it.
    func hasSchedule(templateId: String) -> Bool {
        allSchedules().contains { $0.templateId == templateId }
    }

    // MARK: - Writes

    /// Create a schedule for an existing template. Enabled on creation (the wizard's final step is a
    /// deliberate "enable"), `consecutiveFailures` at 0 and no success yet — a fresh schedule that
    /// the engine will consider on its next wake if it is background-tier.
    @discardableResult
    func create(templateId: String, tier: AutomationTier, cadence: AutomationCadence,
                quietHours: QuietHours?) throws -> AutomationSchedule {
        let now = env.now()
        let schedule = AutomationSchedule(
            id: ULID.newID(), templateId: templateId, tier: tier, desiredCadence: cadence,
            quietHours: quietHours, enabled: true, createdAt: now, updatedAt: now,
            originDeviceId: env.deviceId)
        try repo.upsert(schedule)
        return schedule
    }

    /// Enable/disable without deleting — the module is hideable-without-deletion.
    func setEnabled(id: String, enabled: Bool) { try? repo.setEnabled(id: id, enabled: enabled, now: env.now()) }

    /// Resume a schedule the failure budget paused: resets the strike counter, which flips the
    /// derived `isPaused` back to false so the engine reconsiders it on the next wake.
    func resume(id: String) { try? repo.resume(id: id, now: env.now()) }

    func delete(id: String) { try? repo.softDelete(id: id, at: env.now()) }
}
