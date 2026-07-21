import Foundation

/// The attended counterpart to `IntentExportService` (EPIC-19). Where that service runs a template
/// **unattended** (a Shortcut fired, nobody is looking) and therefore *refuses* anything sensitive,
/// this one is driven by a person standing in the Export Center, so it can collect the run-time
/// sensitive confirmation and passphrase a template needs and actually run it.
///
/// It also owns the read + CRUD paths the three new surfaces sit on:
///   • Template manager (EPIC-09): create / update / soft-delete, with the same name-collision
///     rule the repository enforces surfaced as an answerable error.
///   • Export & Automation Health (EPIC-16): the run ledger, per-template last-success, and the
///     background-substrate summary.
///   • Quick Export (EPIC-10): running a seeded preset template.
///
/// Like `IntentExportService`, the four repositories are built on demand over `env.database.main`
/// (the composition root doesn't expose them yet) — they wrap the one connection every other
/// repository holds, so this is a struct, not a second write lock. It does **not** touch
/// `ExportRunner`, the writers or the repositories themselves; it only composes them.
///
/// **Every run path writes an `ExportRun`.** A refusal before generation writes one too, with the
/// matching `ExportErrorCode` — the anti-HAE thesis is that an export that did not happen leaves
/// evidence it did not happen, and the Export Health dashboard is that evidence made visible.
@MainActor
struct ExportManageService {
    let env: AppEnvironment

    private var templatesRepo: ExportTemplateRepository { ExportTemplateRepository(env.database.main) }
    private var runsRepo: ExportRunRepository { ExportRunRepository(env.database.main) }
    private var destinationsRepo: ExportDestinationRepository { ExportDestinationRepository(env.database.main) }
    private var cursorsRepo: ExportCursorRepository { ExportCursorRepository(env.database.main) }

    // MARK: - Seeding

    /// Ensure the Quick Export presets and the share-sheet destination exist. Idempotent
    /// (`INSERT OR IGNORE` under the hood) and cheap, so it's safe to call on every appearance of
    /// a surface that needs them.
    ///
    /// This lives here, called lazily from the UI, rather than in `AppEnvironment.bootstrap`
    /// because seeding an export preset is not on the app's first-frame critical path and nothing
    /// else needs presets before the Export Center is opened. `seedPresets`/`seedShareSheet` were
    /// written for exactly this call and had no caller until now.
    func ensureSeeded() {
        let now = env.now()
        _ = try? destinationsRepo.seedShareSheet(now: now, originDeviceId: env.deviceId)
        _ = try? templatesRepo.seedPresets(now: now, originDeviceId: env.deviceId)
    }

    // MARK: - Template reads

    func allTemplates() -> [ExportTemplate] { (try? templatesRepo.all()) ?? [] }

    /// Read-only presets first, then the user's own — the order the Template Manager renders in.
    func presets() -> [ExportTemplate] { allTemplates().filter { $0.isPreset } }
    func userTemplates() -> [ExportTemplate] { allTemplates().filter { !$0.isPreset } }

    func template(id: String) -> ExportTemplate? { try? templatesRepo.template(id: id) }

    /// Mirrors `idx_export_templates_name`'s partial-unique rule, for inline "that name is taken"
    /// validation before the user commits (§16 friction note: name collisions → inline validation).
    func isNameAvailable(_ name: String, excludingId: String?) -> Bool {
        (try? templatesRepo.isNameAvailable(name, excludingId: excludingId)) ?? true
    }

    // MARK: - Template CRUD

    /// Create a user template from a builder configuration. Returns the persisted row (with its
    /// freshly minted ULID) so the caller can select it.
    ///
    /// `includeSchemaDocs`/`aggregation`/`layout` are captured verbatim; note that **no run path
    /// applies `aggregation`/`layout` yet** (the runner takes only scope + format — EPIC-13/15
    /// own aggregated and scheduled runs), so callers must not present them as changing today's
    /// output. They round-trip honestly as saved configuration.
    @discardableResult
    func createTemplate(name: String, scope: ExportScope, rangeRule: ExportRangeRule,
                        format: ExportFormat, aggregation: ExportAggregation = .raw,
                        layout: ExportLayout = .tidy, includeSchemaDocs: Bool = false,
                        destinationId: String? = ExportDestination.shareSheetId) throws -> ExportTemplate {
        let now = env.now()
        let template = ExportTemplate(
            id: ULID.newID(), name: name, scope: scope, rangeRule: rangeRule, format: format,
            aggregation: aggregation, layout: layout, includeSchemaDocs: includeSchemaDocs,
            destinationId: destinationId, createdAt: now, updatedAt: now, originDeviceId: env.deviceId)
        try templatesRepo.insert(template)
        return template
    }

    /// Update a user template. The repository refuses presets and enforces the name rule; both
    /// surface here as `ExportTemplateError` the manager can turn into a sentence.
    func updateTemplate(_ template: ExportTemplate) throws {
        var updated = template
        updated.updatedAt = env.now()
        try templatesRepo.update(updated)
    }

    func deleteTemplate(id: String) throws {
        try templatesRepo.softDelete(id: id, at: env.now())
    }

    // MARK: - Run ledger reads (Export Health)

    func recentRuns(limit: Int = 50) -> [ExportRun] { (try? runsRepo.recent(limit: limit)) ?? [] }
    func recentRuns(templateId: String, limit: Int = 20) -> [ExportRun] {
        (try? runsRepo.recent(templateId: templateId, limit: limit)) ?? []
    }
    func lastRun(templateId: String) -> ExportRun? { try? runsRepo.lastRun(templateId: templateId) }
    func lastSuccess(templateId: String, destinationId: String) -> ExportRun? {
        try? runsRepo.lastSuccess(templateId: templateId, destinationId: destinationId)
    }
    func outcomeCounts(since: Date) -> [(outcome: ExportOutcome, count: Int)] {
        (try? runsRepo.outcomeCounts(since: since)) ?? []
    }
    /// Jobs that started and left no ledger row — the completeness check on the ledger itself
    /// (§9.5). A non-empty result means a run died between creating a job and recording its
    /// outcome; Export Health names that count rather than letting it stay invisible.
    func jobsWithoutRunCount() -> Int { ((try? runsRepo.jobIdsWithoutRun()) ?? []).count }

    func cursor(templateId: String, destinationId: String) -> ExportCursor? {
        try? cursorsRepo.cursor(templateId: templateId, destinationId: destinationId)
    }

    // MARK: - Window resolution

    /// The concrete window a template's `rangeRule` resolves to for a run starting `now`.
    ///
    /// **`sinceLastRun` on this path is a window, never a delta, and that is a limit of this path
    /// alone.** `ExportRunner.run` does take an `ingestedSince` watermark — it is an optional
    /// parameter of the very overload called below — and both `ExportRunner.runTemplate` and
    /// `IntentExportService` now pass one, resolving the rule through the shared, pure
    /// `ExportRunner.resolveRange` and advancing the cursor under the two-phase commit. This service
    /// does neither yet: it still takes §12 EPIC-09's bounded window, and it discloses which of the
    /// two situations the user is in rather than reporting "no checkpoint yet" when there is one.
    ///
    /// So the Export Center button and a Shortcut running the SAME `sinceLastRun` template do not
    /// currently export the same rows — the Shortcut takes the delta, this takes 30 days and leaves
    /// the checkpoint untouched. `sinceLastRunIgnoredNotice` is what keeps that from being silent;
    /// closing it means routing this path through `ExportRunner.resolveRange` the way the other two
    /// already do, which is a change this lane did not make.
    struct ResolvedWindow {
        let start: Date?
        let end: Date?
        let notice: LocalizedString?
    }

    func resolvedWindow(for template: ExportTemplate, now: Date) -> ResolvedWindow {
        let tz = TimeZone.current.identifier
        switch template.rangeRule {
        case .fixed:
            return ResolvedWindow(start: template.scope.startDate, end: template.scope.endDate, notice: nil)
        case .lastNDays(let days):
            return ResolvedWindow(start: DayAttribution.addingDays(-max(1, days), to: now, tz: tz),
                                  end: now, notice: nil)
        case .allTime:
            return ResolvedWindow(start: nil, end: nil, notice: nil)
        case .sinceLastRun:
            let destinationId = template.destinationId ?? ExportDestination.shareSheetId
            let hasCursor = cursor(templateId: template.id, destinationId: destinationId) != nil
            return ResolvedWindow(
                start: DayAttribution.addingDays(-Self.sinceLastRunFallbackDays, to: now, tz: tz),
                end: now,
                notice: hasCursor ? Self.sinceLastRunIgnoredNotice : Self.sinceLastRunFallbackNotice)
        }
    }

    static let sinceLastRunFallbackDays = 30
    /// No cursor exists — the template has never had a delivered delta run. The honest report is
    /// that there was nothing to resume from.
    static let sinceLastRunFallbackNotice = LocalizedString(
        en: "No checkpoint yet, so this covered the last 30 days.",
        ar: "لا نقطة مرجعية بعد، لذا شمل هذا آخر 30 يوماً.")
    /// A cursor DOES exist, and this run neither used nor moved it (see `resolvedWindow`). Saying
    /// "no checkpoint yet" here would be a plain lie to the one user who has a checkpoint, and
    /// leaving the run silent would let them believe they had just exported their delta.
    static let sinceLastRunIgnoredNotice = LocalizedString(
        en: "This covered the last 30 days. Running from here doesn't use or move this template's "
            + "checkpoint.",
        ar: "شمل هذا آخر 30 يوماً. التشغيل من هنا لا يستخدم النقطة المرجعية لهذا القالب ولا يحرّكها.")

    // MARK: - Running

    /// What one attended run produced.
    struct RunResult {
        let files: [URL]
        let rowCount: Int
        let outcome: ExportOutcome
        /// Non-nil when the run happened but the user should know *how* — today only the
        /// `sinceLastRun` fallback.
        let notice: LocalizedString?
    }

    /// Run a template now, on behalf of a person in the app.
    ///
    /// A sensitive template needs both a fresh `SensitiveRunConsent` (§9.3) and a passphrase
    /// (ADR-0008); the caller collects both. A missing/expired confirmation is a thrown refusal
    /// *and* a recorded `failedGeneration`, never a silent narrowing to non-sensitive.
    ///
    /// `async` because the heavy work — `ExportRunner.run` over a possibly all-time scope — is
    /// dispatched off the main actor (the runner is synchronous, offline and thread-safe, exactly
    /// as `ExportCenterViewModel.run` relies on) so a large export never freezes the UI or trips
    /// the iOS watchdog. The light ledger write happens back on the main actor once it returns.
    func run(template: ExportTemplate, passphrase: String?, consent: SensitiveRunConsent?,
             trigger: ExportTrigger = .manual) async throws -> RunResult {
        let startedAt = env.now()

        let baseScope: ExportScope
        do {
            baseScope = try template.scopeForRun(consent: consent, now: startedAt)
        } catch {
            record(templateId: template.id, startedAt: startedAt, outcome: .failedGeneration,
                   errorCode: .sensitiveConfirmationMissing, stage: .gathering,
                   destinationId: template.destinationId, trigger: trigger)
            throw error
        }

        let window = resolvedWindow(for: template, now: startedAt)
        var scope = baseScope
        scope.startDate = window.start
        scope.endDate = window.end
        scope.language = env.language

        return try await runResolved(scope: scope, format: template.format, passphrase: passphrase,
                                     templateId: template.id, destinationId: template.destinationId,
                                     startedAt: startedAt, trigger: trigger, notice: window.notice)
    }

    /// Shared tail for a run whose scope is already fully resolved (dates + language set). Used by
    /// `run(template:)` and by Quick Export, which builds its scope from a preset. Records exactly
    /// one `ExportRun` and returns the artifacts.
    func runResolved(scope: ExportScope, format: ExportFormat, passphrase: String?,
                     templateId: String?, destinationId: String?, startedAt: Date,
                     trigger: ExportTrigger, notice: LocalizedString?) async throws -> RunResult {
        // Capture the (non-isolated) runner so the generation runs off the main actor; only the
        // ledger write below touches main-actor state.
        let exporter = env.exporter
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try exporter.run(scope: scope, format: format, passphrase: passphrase)
            }.value
            let outcome: ExportOutcome = result.rowCount == 0 ? .skippedNoData : .success
            record(templateId: templateId, startedAt: startedAt, outcome: outcome,
                   jobId: result.job.id, bytesWritten: Self.totalBytes(result.fileURLs),
                   destinationId: destinationId, trigger: trigger)
            return RunResult(files: result.fileURLs, rowCount: result.rowCount, outcome: outcome,
                             notice: notice)
        } catch {
            record(templateId: templateId, startedAt: startedAt, outcome: .failedGeneration,
                   errorCode: Self.errorCode(for: error), stage: .writing,
                   destinationId: destinationId, trigger: trigger)
            throw error
        }
    }

    // MARK: - Ledger writes

    /// Append one `ExportRun`. `rowCounts` is left `nil` (matching `IntentExportService`):
    /// `ExportRunner` reports one total, and dropping that total into any single `ExportRowCounts`
    /// bucket would be a fabricated per-class breakdown in the one table that exists to be trusted.
    private func record(templateId: String?, startedAt: Date, outcome: ExportOutcome,
                        errorCode: ExportErrorCode? = nil, stage: ExportStage? = nil,
                        jobId: String? = nil, bytesWritten: Int? = nil,
                        destinationId: String?, trigger: ExportTrigger) {
        let run = ExportRun(
            id: ULID.newID(), templateId: templateId, jobId: jobId, trigger: trigger,
            startedAt: startedAt, finishedAt: env.now(), outcome: outcome, errorCode: errorCode,
            errorDetail: stage.map { ExportErrorDetail(stage: $0) },
            bytesWritten: bytesWritten, rowCounts: nil, destinationId: destinationId)
        // A failing ledger write must not turn a successful export into a failed one: the file
        // exists either way. The gap this leaves is the one `jobIdsWithoutRun` already surfaces.
        try? runsRepo.insert(run)
    }

    private static func errorCode(for error: Error) -> ExportErrorCode {
        switch error {
        case ExportRunError.sensitiveExportRequiresPassphrase: return .passphraseMissing
        default: return .writeFailed
        }
    }

    private static func totalBytes(_ urls: [URL]) -> Int? {
        var total = 0
        var sawAny = false
        for url in urls {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += size
            sawAny = true
        }
        return sawAny ? total : nil
    }
}
