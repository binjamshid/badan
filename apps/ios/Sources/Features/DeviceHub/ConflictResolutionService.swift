import Foundation

/// Loads the readings behind an open `DataConflict` and applies the user's pick (EPIC-43 debt
/// closeout — see `ConflictResolution` for why a user choice gets its own rule id).
///
/// A `DataConflict` row stores candidate RECORD IDS and nothing else, on purpose (I5: the raw
/// values stay in `raw_samples`/`interval_records`/`sessions`, never copied into the conflict row).
/// That is the right storage shape and it is also why this type has to exist: a person cannot pick
/// between two readings they cannot see, so the ids have to be resolved back into real values
/// before the screen can offer a choice.
enum ConflictResolutionService {
    /// One candidate, resolved far enough to render and choose between.
    struct Candidate: Identifiable, Hashable {
        let id: String
        let sourceId: String
        let sourceName: String
        let value: Double
        let unit: String
        let measuredAt: Date
        let isManualEntry: Bool
        /// True when this row is currently suppressed — i.e. it lost an earlier decision. Rendered
        /// so reopening a resolved conflict shows what was set aside rather than hiding it.
        let isSuppressed: Bool
    }

    /// Which table a conflict's candidates live in.
    ///
    /// Read straight off `IngestionPipeline`'s own detection sets — the code that WROTE the
    /// conflict — rather than re-derived from the registry's `kind`. An earlier draft did derive it
    /// from `kind` and was wrong in the worst possible way: `heart.rhr` and `heart.hrv` are
    /// `kind: derived` in `registry.json` but are detected out of `interval_records`, so the
    /// registry-driven version returned "no table" for the two metrics that produce most real
    /// conflicts. It compiled, it shipped a visible "Choose which to keep" affordance, and it would
    /// have done nothing — the same build-it-twice-and-drift failure that already cost this
    /// codebase a Source Priority Editor with no effect. A test now pins each of the four detected
    /// metrics to its real table.
    ///
    /// The `registry` parameter is kept for the unknown-metric case, which must still refuse rather
    /// than guess.
    static func table(for scope: ConflictScope, registry: MetricRegistry) -> String? {
        switch scope {
        case .workoutDuplicate:
            return "sessions"
        case .metric(let id, _):
            if IngestionPipeline.intervalConflictMetrics.contains(id) { return "interval_records" }
            if IngestionPipeline.sampleConflictMetrics.contains(id) { return "raw_samples" }
            // Not a metric anything detects conflicts for. The screen then offers no resolve
            // action, rather than aiming a suppression at a guessed table.
            return nil
        }
    }

    /// Resolves every candidate id into a renderable reading. Ids that no longer resolve (a row
    /// removed by an import undo, say) are dropped rather than rendered as blanks — and the caller
    /// checks the surviving count before offering a choice, since a conflict with one readable side
    /// is no longer a conflict the user can meaningfully settle.
    static func candidates(for conflict: DataConflict, table: String,
                           measurements: MeasurementRepository,
                           sourceNames: [String: String]) throws -> [Candidate] {
        try conflict.candidateRecordIds.compactMap { id -> Candidate? in
            switch table {
            case "raw_samples":
                guard let row = try measurements.rawSample(id: id) else { return nil }
                return Candidate(id: row.id, sourceId: row.provenance.sourceId,
                                 sourceName: sourceNames[row.provenance.sourceId] ?? row.provenance.sourceId,
                                 value: row.value, unit: row.unit, measuredAt: row.provenance.measuredAt,
                                 isManualEntry: row.provenance.ingestionPath == .manual,
                                 isSuppressed: row.provenance.isSuppressed)
            case "interval_records":
                guard let row = try measurements.intervalRecord(id: id) else { return nil }
                return Candidate(id: row.id, sourceId: row.provenance.sourceId,
                                 sourceName: sourceNames[row.provenance.sourceId] ?? row.provenance.sourceId,
                                 value: row.value, unit: row.unit, measuredAt: row.provenance.measuredAt,
                                 isManualEntry: row.provenance.ingestionPath == .manual,
                                 isSuppressed: row.provenance.isSuppressed)
            default:
                return nil
            }
        }
        .sorted { $0.measuredAt > $1.measuredAt }
    }

    /// Applies the user's choice: suppress every loser, journal one `ReconciliationDecision` per
    /// loser, and mark the conflict resolved against the first of those decisions.
    ///
    /// Nothing is deleted — losers are suppressed (I3), so the whole thing stays reversible through
    /// the same `dedup_decisions` ledger every automatic decision already uses. The write order is
    /// suppress → journal → mark resolved, so an interruption can leave a suppression journaled but
    /// the conflict still flagged open (the user sees it again and re-picks, idempotently), never a
    /// conflict marked settled while the rows it settled are untouched.
    @discardableResult
    static func apply(conflict: DataConflict, table: String, winnerId: String,
                      candidates: [Candidate], measurements: MeasurementRepository,
                      reconciliation: ReconciliationRepository, dataConflicts: DataConflictRepository,
                      clock: Clock) throws -> Bool {
        guard let scope = conflict.scope else { return false }
        let readings = candidates.map {
            CandidateReading(id: $0.id, sourceId: $0.sourceId, classification: "",
                             isManualEntry: $0.isManualEntry, measuredAt: $0.measuredAt)
        }
        guard let outcome = ConflictResolution.resolve(scope: scope, candidates: readings, winnerId: winnerId)
        else { return false }

        let now = clock.now()
        var firstDecisionId: String?
        for decision in outcome.makeDecisions(clock: clock) {
            // Idempotent in the same shape `IngestionPipeline.reconcileConflictWindow` uses: if this
            // exact loser is already suppressed in favour of this exact winner, don't journal a
            // second identical row.
            if try reconciliation.forSuppressed(decision.suppressedRecordId)?.keptRecordId == decision.keptRecordId {
                firstDecisionId = firstDecisionId ?? decision.id
                continue
            }
            try measurements.setSuppressed(table: table, recordId: decision.suppressedRecordId,
                                           by: decision.keptRecordId, updatedAt: now)
            try reconciliation.insert(decision)
            firstDecisionId = firstDecisionId ?? decision.id
        }
        // Also clear any suppression on the winner itself: the person may be OVERTURNING an earlier
        // automatic decision that suppressed the row they just chose to keep. Without this the
        // screen would report the conflict settled while the chosen reading stayed hidden from
        // every other surface in the app.
        try measurements.setSuppressed(table: table, recordId: outcome.winnerId, by: nil, updatedAt: now)
        if let priorDecision = try reconciliation.forSuppressed(outcome.winnerId) {
            try reconciliation.markReversed(id: priorDecision.id, at: now)
        }

        guard let decisionId = firstDecisionId else { return false }
        try dataConflicts.markResolved(id: conflict.id, decisionId: decisionId, at: now)
        return true
    }
}
