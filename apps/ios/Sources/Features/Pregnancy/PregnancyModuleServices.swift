import Foundation

// MARK: - A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice) — composition layer.
//
// Mirrors `CycleModuleServices`'s pattern exactly: a `@MainActor` struct constructed once per
// top-level screen instance from `AppEnvironment`, NOT added to `AppEnvironment` itself (same
// "small, closed set of owned files" reasoning that type's own header gives).
//
// Every repository below is constructed against `env.database.sensitive` ONLY — never
// `env.database.main` — per I7 and this module's own sharper sensitivity framing
// (`Domain/Pregnancy/PregnancyModels.swift`'s file header).
@MainActor
struct PregnancyModuleServices {
    let pregnancyRecords: PregnancyRecordRepository
    let dueDateSourceEntries: DueDateSourceEntryRepository
    let dueDateEstimates: DueDateEstimateRepository
    let lossDeclarations: LossDeclarationRecordRepository
    let deviceId: String

    private let env: AppEnvironment

    static let dueDateAlgorithmVersion = "pregnancy.due_date_estimate@1.0.0"

    init(env: AppEnvironment) {
        let sensitive = env.database.sensitive
        pregnancyRecords = PregnancyRecordRepository(sensitive: sensitive)
        dueDateSourceEntries = DueDateSourceEntryRepository(sensitive: sensitive)
        dueDateEstimates = DueDateEstimateRepository(sensitive: sensitive)
        lossDeclarations = LossDeclarationRecordRepository(sensitive: sensitive)
        deviceId = env.deviceId
        self.env = env
    }

    // MARK: - Provenance helper (mirrors HydrationViewModel/PeriodLogScreen's own manualProvenance shape)

    private func manualProvenance(measuredAt: Date, recordedAt: Date,
                                  tz: String = TimeZone.current.identifier) -> Provenance {
        Provenance(sourceId: deviceId, deviceId: deviceId, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: tz, recordedAt: recordedAt, ingestedAt: recordedAt)
    }

    // MARK: - Journey read

    /// The current live journey, if any. `nil` means no journey has been started (or the prior one
    /// was fully purged) — the module can be `pregnancyModuleMode == .on` with no live journey yet,
    /// exactly as `cycleModuleEnabled == true` can have zero logged periods.
    func liveJourney() throws -> PregnancyRecord? {
        try pregnancyRecords.liveRecords().first
    }

    // MARK: - Mode transitions (PREG-01) — the ONLY write path for `PregnancyRecord.mode`

    /// Starts a brand-new journey. Throws `PregnancyModeController.TransitionError.liveJourneyAlreadyExists`
    /// if one is already live — this never silently overwrites an existing journey.
    @discardableResult
    func beginJourney(_ request: PregnancyModeTransitionRequest, multiplesFlag: Bool = false,
                      fertilityTreatmentContext: Bool = false, asOf: Date) throws -> PregnancyRecord {
        let current = try liveJourney()
        let record = try PregnancyModeController.beginJourney(
            request: request, currentLiveRecord: current, id: ULID.newID(clock: env.clock),
            multiplesFlag: multiplesFlag, fertilityTreatmentContext: fertilityTreatmentContext,
            provenance: manualProvenance(measuredAt: asOf, recordedAt: asOf), asOf: asOf,
            originDeviceId: deviceId)
        try pregnancyRecords.insertRecord(record)
        return record
    }

    /// Applies a mode transition to the current live journey (every case except `declareLoss`, which
    /// has its own dedicated `declareLoss` entry point below carrying the suppression cascade).
    /// Throws `PregnancyModeController.TransitionError.noActiveJourney` if none is live, or
    /// `.illegalTransition` if the request is not legal from the current mode.
    @discardableResult
    func applyTransition(_ request: PregnancyModeTransitionRequest, asOf: Date) throws -> PregnancyRecord {
        guard let current = try liveJourney() else {
            throw PregnancyModeController.TransitionError.noActiveJourney
        }
        let next = try PregnancyModeController.applyTransition(
            current: current, request: request, newId: ULID.newID(clock: env.clock),
            provenance: manualProvenance(measuredAt: asOf, recordedAt: asOf), asOf: asOf,
            originDeviceId: deviceId)
        try pregnancyRecords.insertRecord(next)
        return next
    }

    // MARK: - Due-date sources + estimate (PREG-02)

    /// Records ONE user-entered due-date input and immediately recomputes the estimate (mirrors
    /// `CycleModuleServices.refreshAll`'s own "recompute after every write action" posture).
    @discardableResult
    func recordDueDateSource(sourceType: DueDateSourceType, enteredDate: Date, asOf: Date) throws -> DueDateEstimate {
        guard let journey = try liveJourney() else {
            throw PregnancyModeController.TransitionError.noActiveJourney
        }
        let entry = DueDateSourceEntry(
            id: ULID.newID(clock: env.clock), pregnancyRecordOriginalId: journey.originalId,
            sourceType: sourceType, enteredDate: enteredDate,
            provenance: manualProvenance(measuredAt: enteredDate, recordedAt: asOf), updatedAt: asOf,
            originDeviceId: deviceId)
        try dueDateSourceEntries.insertEntry(entry)
        return try refreshDueDateEstimate(asOf: asOf)
    }

    /// Recomputes and appends a fresh `DueDateEstimate` from the current live source entries —
    /// always an append (I2), mirroring `CycleModuleServices.refreshAll`'s prediction step.
    @discardableResult
    func refreshDueDateEstimate(asOf: Date) throws -> DueDateEstimate {
        guard let journey = try liveJourney() else {
            throw PregnancyModeController.TransitionError.noActiveJourney
        }
        let byType = try dueDateSourceEntries.currentEntriesByType(pregnancyRecordOriginalId: journey.originalId)
        var estimate = DueDateEstimator.estimate(
            pregnancyRecordOriginalId: journey.originalId, liveEntriesByType: byType, asOf: asOf,
            algorithmVersion: Self.dueDateAlgorithmVersion)
        estimate.originDeviceId = deviceId
        try dueDateEstimates.appendEstimate(estimate)
        return estimate
    }

    /// The current due-date estimate for the live journey, or `nil` if there is none (no journey, or
    /// no estimate has ever been computed).
    func currentDueDateEstimate() throws -> DueDateEstimate? {
        guard let journey = try liveJourney() else { return nil }
        return try dueDateEstimates.latestEstimate(pregnancyRecordOriginalId: journey.originalId)
    }

    // MARK: - declareLoss (PREG-04) — the non-negotiable, real suppression cascade
    //
    // Six steps, in order, every one documented here so a future reader can verify nothing was
    // skipped — mirrors `CycleModuleServices.refreshAll`'s own "numbered, exhaustively documented"
    // convention:
    //
    // 1. Validate a live journey exists and its CURRENT mode allows a loss declaration
    //    (`PregnancyJourneyMode.canDeclareLossFromThisMode` / `PregnancyModeController
    //    .legalTransitions`). Never inferred, never silently no-op'd — an illegal call throws.
    // 2. Append the NEXT `PregnancyRecord` revision with `mode = .lossDeclared`, via
    //    `PregnancyModeController.applyTransition` (I2 — the prior mode's row is NEVER mutated or
    //    deleted; it stays in `history(originalId:)` forever). THE MOMENT this row is appended,
    //    `PregnancyContentGate.visibleForwardLookingSections(for:)` structurally returns the empty
    //    set for this journey — see that gate's own doc for why this is enforced by the mode value
    //    itself, not a separate flag a future screen could forget to check.
    // 3. Insert the `LossDeclarationRecord` itself (minimal fields — see that type's own doc).
    // 4. SAME-SESSION, ZERO-DELAY notification suppression: cancel every pending `.pregnancy`-class
    //    local notification via `NotificationScheduler.cancelDecisionNotifications(.pregnancy)` —
    //    an UNCONDITIONAL identifier-prefix cancel that does NOT consult the EPIC-32 daily budget
    //    engine at all (that engine decides whether to SCHEDULE a notification; cancellation here
    //    bypasses it entirely, so a loss declaration can never be rate-limited or delayed). This is
    //    awaited before this function returns — "same session" means the caller's own `await`
    //    completes before any other code runs, not a `Task { }` fired and forgotten. No producer
    //    schedules a `.pregnancy` notification in this P0 slice (see `NotificationClass.pregnancy`'s
    //    own doc), so this call is a real, working no-op today — the cancellation path is exercised
    //    and tested regardless, so the moment a future slice adds a producer, suppression is already
    //    wired and already covered by `PregnancyModuleServicesTests`'s suppression-cascade test.
    // 5. If (and only if) `dataDisposition == .delete`: run the REAL erasure the on-screen promise
    //    ("Nothing is erased unless you choose Delete") makes — `purgeJourneyData(originalId:)`,
    //    scoped to THIS journey only. Fixes general audit finding 1: `dataDisposition` was
    //    previously stored as an inert label nothing ever read. `.keep`/`.archive` do nothing here
    //    (by design — I2, nothing is erased for those two choices).
    // 6. Return the created `LossDeclarationRecord` (its in-memory fields are still valid to read
    //    even when step 5 just hard-deleted its own row — the caller uses the returned value only
    //    for its own post-declare notice/UI state, never a second storage read).
    //
    // AMBIENT/WIDGET SURFACES: per this module's own non-negotiable requirement, this method's own
    // doc records the check performed at build time — `Platform/Ambient/` has no pregnancy-specific
    // snapshot field or widget today (confirmed by grep across `AmbientSnapshotDto.swift`/
    // `AmbientSnapshotWriter.swift`/`BadanWidgets/` — none exist), so there is nothing there to gate
    // yet. The moment a pregnancy ambient/widget surface is ever added, it MUST consult
    // `PregnancyContentGate.visibleForwardLookingSections(for:)` before rendering anything
    // forward-looking, exactly like any future in-module screen must.
    @discardableResult
    func declareLoss(approximateDate: Date, gestationalStage: LossGestationalStage? = nil,
                     freeTextNote: String? = nil, dataDisposition: LossDataDisposition,
                     asOf: Date) async throws -> LossDeclarationRecord {
        // Step 1.
        guard let current = try liveJourney(), current.mode.canDeclareLossFromThisMode else {
            throw PregnancyModeController.TransitionError.noActiveJourney
        }

        // Step 2. I2 — appends, never mutates. Reuses the same validated transition path every
        // other mode change goes through (`PregnancyModeController.legalTransitions`), so
        // `.declareLoss` can never bypass the state machine's own legality check.
        let lossRecord = try PregnancyModeController.applyTransition(
            current: current, request: .declareLoss, newId: ULID.newID(clock: env.clock),
            provenance: manualProvenance(measuredAt: asOf, recordedAt: asOf), asOf: asOf,
            originDeviceId: deviceId)
        try pregnancyRecords.insertRecord(lossRecord)

        // Step 3.
        let declaration = LossDeclarationRecord(
            id: ULID.newID(clock: env.clock), pregnancyRecordOriginalId: current.originalId,
            declaredAt: asOf, approximateDate: approximateDate, gestationalStage: gestationalStage,
            freeTextNote: freeTextNote, dataDisposition: dataDisposition,
            fertilityTreatmentContext: current.fertilityTreatmentContext,
            provenance: manualProvenance(measuredAt: asOf, recordedAt: asOf), updatedAt: asOf,
            originDeviceId: deviceId)
        try lossDeclarations.insertDeclaration(declaration)

        // Step 4. Same-session, zero-delay, unconditional — see this method's own doc above.
        await NotificationScheduler.shared.cancelDecisionNotifications(.pregnancy)

        // Step 5. See this method's own doc above — the real "Delete" erasure, scoped to this
        // journey only.
        if dataDisposition == .delete {
            try purgeJourneyData(originalId: current.originalId)
        }

        // Step 6.
        return declaration
    }

    /// CYCLE-08-style "revisitable, not one-time-forced" data-disposition change (research doc §9
    /// line 132; loss-handling audit finding 2) — updates `data_disposition` in place for
    /// `.keep`/`.archive`; every other field of the declaration stays frozen
    /// (`LossDeclarationRecordRepository.updateDataDisposition`'s own doc). Changing TO `.delete`
    /// later is different in kind, not just another value: it runs the SAME real, scoped erasure
    /// `declareLoss` runs when `.delete` is chosen at declaration time
    /// (`purgeJourneyData(originalId:)`, general audit finding 1) — after which there is no row left
    /// to hold a `data_disposition` column, so the plain UPDATE never runs for that case. A
    /// nonexistent/already-purged `id` is a silent no-op, matching `updateDataDisposition`'s and
    /// `deleteRecord`'s own "no matching row" behavior.
    func updateLossDataDisposition(id: String, disposition: LossDataDisposition, asOf: Date) throws {
        guard disposition == .delete else {
            try lossDeclarations.updateDataDisposition(id: id, disposition: disposition, at: asOf)
            return
        }
        guard let existing = try lossDeclarations.declaration(id: id) else { return }
        try purgeJourneyData(originalId: existing.pregnancyRecordOriginalId)
    }

    /// Independent deletion of ONE loss declaration (research doc §9: "independently deletable") —
    /// does NOT touch the `PregnancyRecord` chain it references; the journey's `.lossDeclared` mode
    /// (and every prior revision) survives untouched.
    func deleteLossDeclaration(id: String, asOf: Date) throws {
        try lossDeclarations.deleteRecord(id: id, at: asOf)
    }

    /// Every live loss declaration across every journey this profile has ever recorded — what the
    /// consent screen's revisit UI lists (loss-handling audit finding 2: the disposition choice must
    /// be reachable again after the sheet that created it closes, not a one-time forced decision).
    func allLossDeclarations() throws -> [LossDeclarationRecord] {
        try lossDeclarations.allLiveDeclarations()
    }

    // MARK: - purgeJourneyData (scoped, one-journey purge — the real "Delete" data-disposition erasure)

    /// Scoped purge for exactly ONE journey (`originalId`) — the actual erasure the loss-declaration
    /// "Delete" data-disposition choice promises (general audit finding 1: previously stored as an
    /// inert label nothing read; loss-handling audit finding 2: reachable again later, not only at
    /// declaration time — both are satisfied by this SAME real, transactional purge, invoked from
    /// `declareLoss` and from `updateLossDataDisposition`). Deletes every row across all FOUR
    /// pregnancy tables that belongs to this ONE journey's `originalId` — every revision of the
    /// `PregnancyRecord` chain (not just the live head), every due-date source entry, every due-date
    /// estimate, and every loss declaration tied to it — in one transaction, mirroring
    /// `purgePregnancyData()`'s "fully lands or fully doesn't" contract but scoped to this journey
    /// only. A DIFFERENT, still-live journey (a new `originalId` started after this one, per
    /// `PregnancyJourneyMode.blocksNewJourney`'s own doc) is left completely untouched.
    func purgeJourneyData(originalId: String) throws {
        let sensitive = env.database.sensitive
        try sensitive.transaction {
            try pregnancyRecords.purgeChain(originalId: originalId)
            try dueDateSourceEntries.purgeChain(pregnancyRecordOriginalId: originalId)
            try dueDateEstimates.purgeChain(pregnancyRecordOriginalId: originalId)
            try lossDeclarations.purgeChain(pregnancyRecordOriginalId: originalId)
        }
    }

    // MARK: - purgePregnancyData (whole-module purge, mirrors CycleModuleServices.purgeCycleData)

    /// A real per-module purge of the user's own pregnancy-family rows, distinct from the whole-
    /// `badan_sensitive.db`-file deletion `Database.purgeSensitiveNamespace()` performs for "disable
    /// all sensitive modules." Deletes every row in all FOUR pregnancy tables (`pregnancy_records`,
    /// `due_date_source_entries`, `due_date_estimates`, `loss_declaration_records`) in one
    /// transaction — a purge either fully lands or fully doesn't.
    func purgePregnancyData() throws {
        let sensitive = env.database.sensitive
        try sensitive.transaction {
            for table in ["pregnancy_records", "due_date_source_entries", "due_date_estimates",
                          "loss_declaration_records"] {
                try sensitive.execute("DELETE FROM \"\(table)\";")
            }
        }
    }
}
