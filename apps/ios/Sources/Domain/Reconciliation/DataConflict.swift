import Foundation

/// EPIC-43 (plan §7A.6 / §9.19): a detected-but-not-yet-resolved disagreement between two or more
/// sources for the same metric/window — genuinely new, unlike `ReconciliationDecision` (which
/// already exists, backed by `dedup_decisions`, and records a decision ALREADY made).
/// `DataConflict` is the row that exists BEFORE a rule picks a winner, so a conflict can be
/// detected, queried, and shown to the user ("why am I seeing this value?") even before — or
/// without ever — being resolved. Persisted in the main db (`data_conflicts`, migration 10):
/// device/source disagreement is not sensitive-plus (I7 does not apply here).
public enum DataConflictStatus: String, Codable, Hashable, Sendable {
    case unresolved
    case resolved
}

/// What KIND of thing 2+ candidates are disagreeing about. Deliberately a two-case enum rather
/// than a bare metric-id string: `.workoutDuplicate` conflicts (two ingested sessions that look
/// like the same real-world workout) are not metric readings and have no `MetricID` of their own,
/// so folding them into `.metric` would either need a fake sentinel metric id or an optional
/// metric id that is nil "for a reason nothing enforces" — this makes the two cases exhaustive and
/// type-checked at the call site instead.
public enum ConflictScope: Hashable, Sendable {
    /// A canonical metric id (`MetricID.heartRate`, `MetricID.weight`, …), optionally scoped to
    /// "measured during a workout" — the ONE context this slice distinguishes, because it is the
    /// one the plan's own named default (chest-strap-beats-wrist) actually depends on. A richer
    /// covariate model (sleep, illness, travel…) is future work, not a gap in this decision: none
    /// of those contexts change which of THIS slice's four named defaults applies.
    case metric(id: String, inWorkout: Bool = false)
    /// Two or more ingested `sessions` rows that look like the same real-world workout. Session-
    /// overlap detection itself already exists (`DedupLite.reconcileWorkouts`); this scope is for
    /// the case overlap alone doesn't decide — WHICH of two overlapping device recordings is the
    /// richer one (plan's "richest source wins duplicate workouts").
    case workoutDuplicate

    /// Serialized form stored in `data_conflicts.scope_key`. Kept as one TEXT column (rather than
    /// separate metric-id/context columns) so a future third scope case doesn't need its own
    /// migration — the same "store the union as text, let the enum evolve" convention
    /// `sessions.detail` already uses for the same reason.
    public var storageKey: String {
        switch self {
        case .metric(let id, let inWorkout): return inWorkout ? "metric:\(id):workout" : "metric:\(id)"
        case .workoutDuplicate: return "workout_duplicate"
        }
    }

    /// The inverse of `storageKey`. Returns `nil` for anything that doesn't round-trip — a
    /// repository reading a corrupted/future-version row surfaces that as "can't interpret this
    /// conflict" rather than guessing a scope it was never told.
    public init?(storageKey: String) {
        if storageKey == "workout_duplicate" {
            self = .workoutDuplicate
            return
        }
        guard storageKey.hasPrefix("metric:") else { return nil }
        let rest = storageKey.dropFirst("metric:".count)
        if rest.hasSuffix(":workout") {
            self = .metric(id: String(rest.dropLast(":workout".count)), inWorkout: true)
        } else {
            self = .metric(id: String(rest), inWorkout: false)
        }
    }
}

/// One detected disagreement, persisted so it is queryable even before (or without ever) being
/// resolved. Never carries the disagreeing VALUES themselves (I5: raw stays in `raw_samples`/
/// `sessions`; this row only references those records by id) and never merges/averages anything —
/// see `ConflictDecisionEngine` for the decision half.
public struct DataConflict: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var scopeKey: String
    public var windowStart: Date
    public var windowEnd: Date
    /// The disagreeing candidate record ids (`raw_samples.id` / `interval_records.id` /
    /// `sessions.id`, depending on `scope`) — always 2 or more; a single record is never a
    /// conflict (enforced by `init`, not merely documented).
    public var candidateRecordIds: [String]
    public var status: DataConflictStatus
    /// Set only once `status == .resolved` — the `dedup_decisions` row (the EXISTING
    /// `ReconciliationDecision` ledger) that resolved this conflict, so a UI can jump straight from
    /// "why am I seeing this value?" to the recorded rule. `nil` while unresolved, and stays `nil`
    /// forever for a conflict left unresolved by design — that is a legitimate end state (I3/I5),
    /// never treated as "still pending."
    public var resolvedByDecisionId: String?
    public var detectedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, scope: ConflictScope, windowStart: Date, windowEnd: Date,
                candidateRecordIds: [String], status: DataConflictStatus = .unresolved,
                resolvedByDecisionId: String? = nil, detectedAt: Date, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        precondition(candidateRecordIds.count >= 2,
                     "DataConflict always names 2+ disagreeing candidates — a single record is not a conflict")
        self.id = id
        self.scopeKey = scope.storageKey
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.candidateRecordIds = candidateRecordIds
        self.status = status
        self.resolvedByDecisionId = resolvedByDecisionId
        self.detectedAt = detectedAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }

    /// Typed bridge back from the stored `scopeKey`. `nil` only for a corrupted/unrecognized key —
    /// see `ConflictScope.init(storageKey:)`.
    public var scope: ConflictScope? { ConflictScope(storageKey: scopeKey) }
}

/// One source's reading, as fed INTO `ConflictDecisionEngine.decide` — not persisted on its own;
/// the caller resolves these from `raw_samples`/`interval_records`/`sessions` at conflict-decision
/// time. Kept intentionally thin: whatever richer context a future rule needs, the CALLER computes
/// and hands in here (the same "supply, don't infer" boundary `ContextStatus` draws for confidence
/// annotations) — this type never reaches back into a database itself.
public struct CandidateReading: Hashable, Sendable, Identifiable {
    /// The underlying record id this candidate represents (`raw_samples.id` / `sessions.id` / …).
    public var id: String
    public var sourceId: String
    /// Matches a `SourcePriorityRule.priorityOrder` entry or a `SourcePriorityRule.ClassificationKey`
    /// constant. An unrecognized or empty value is valid input — it simply can never WIN a
    /// priority-order or chest-strap rule (those are the only rules that consult it); recency,
    /// richness and manual-wins do not.
    public var classification: String
    public var isManualEntry: Bool
    public var measuredAt: Date
    /// A relative "how complete is this recording" signal (sample density, presence of a route,
    /// field count…) — CALLER-computed; this engine only ever COMPARES it, never derives it.
    public var richnessScore: Int

    public init(id: String, sourceId: String, classification: String = "", isManualEntry: Bool = false,
                measuredAt: Date, richnessScore: Int = 0) {
        self.id = id
        self.sourceId = sourceId
        self.classification = classification
        self.isManualEntry = isManualEntry
        self.measuredAt = measuredAt
        self.richnessScore = richnessScore
    }
}

/// The DECISION half of EPIC-43's reconciliation engine v2: given a conflict's candidate readings
/// (2+) and, where relevant, the applicable `SourcePriorityRule`, decide EXACTLY ONE winner — or
/// leave the conflict unresolved. There is no third outcome. In particular there is NO code path
/// in this file that averages, blends, or otherwise synthesizes a value across candidates — every
/// stored result names an id that was already one of the inputs
/// (`DataConflictTests.testDecideNeverProducesAWinnerOrLoserOutsideTheInputSet` in
/// `Tests/DataConflictTests.swift` asserts this holds for arbitrary candidate sets, not just the
/// examples below).
///
/// Pure and static, mirroring `DedupLite.reconcile`'s own split: `decide` takes no clock and mints
/// no ids, so it is trivially deterministic and testable; `Outcome.makeDecisions` (below) is the
/// one place that stamps a wall-clock time and mints `ReconciliationDecision.id`s, at the actual
/// write boundary — never inside the pure decision itself.
public enum ConflictDecisionEngine {
    static let ruleVersion = "v1"
    public static let manualWinsRuleId = "conflict.manual_wins.v1"
    public static let mostRecentWeightRuleId = "conflict.most_recent_weight.v1"
    public static let richestWorkoutRuleId = "conflict.richest_workout.v1"
    public static let chestStrapRuleId = "conflict.chest_strap_priority.v1"
    public static let priorityOrderRuleId = "conflict.priority_order.v1"

    /// Metric ids where INVARIANT I4 makes a manual entry authoritative over ANY device reading,
    /// full stop — never overridden by recency, richness, or a `SourcePriorityRule`. Blood-
    /// pressure/lab metric ids are not in `MetricID` yet (those surfaces are out of EPIC-43's
    /// scope — see the epic's own do-not-build list for clinically-adjacent BLE); `MetricID.weight`
    /// is the one metric this slice can wire end to end today. Adding a metric here later is
    /// additive and requires no schema change.
    public static let manualWinsMetrics: Set<String> = [MetricID.weight]

    /// A pure decision: which candidate id won, under which named rule, with human-readable
    /// detail for the journal. Carries NO value, NO id, NO timestamp of its own — see
    /// `makeDecisions` for turning this into the actual persisted `ReconciliationDecision` row(s).
    public struct Outcome: Equatable, Sendable {
        public let ruleId: String
        public let ruleVersion: String
        public let winnerId: String
        /// Every OTHER candidate's id, computed from the same candidate list the winner came
        /// from — never a separately-maintained list, so it can never drift from "everyone who
        /// isn't the winner."
        public let loserIds: [String]
        public let detail: [String: String]
    }

    /// Decides a winner for one conflict's candidate set, or `nil` to leave it unresolved.
    /// `nil` is a legitimate, surfaced answer (I3/I5) — NEVER a silently-averaged/blended value,
    /// and never a forced pick when no rule actually applies.
    ///
    /// Rule precedence (first match wins):
    /// 1. `.workoutDuplicate` → richest source wins (§7A.6).
    /// 2. `manualWinsMetrics` (I4) → the most-recently-measured MANUAL candidate wins, whenever at
    ///    least one manual candidate exists — regardless of any device's priority or richness.
    /// 3. `MetricID.weight` with no manual candidate present → most-recent reading wins, full
    ///    stop (§7A.6's "most-recent weight wins for a given day").
    /// 4. Heart rate measured "in a workout" → a BLE chest-strap candidate wins over any other,
    ///    if one is present (§7A.6's "chest strap beats wrist-optical in workouts").
    /// 5. Otherwise, an applicable `SourcePriorityRule` (matched by exact `metricId`) → the
    ///    highest-ranked candidate in `priorityOrder` wins.
    /// 6. No rule applies → `nil` (unresolved; surfaced to the user, never silently decided).
    public static func decide(scope: ConflictScope, candidates: [CandidateReading],
                               priorityRule: SourcePriorityRule?) -> Outcome? {
        guard candidates.count >= 2 else { return nil } // a single reading is not a conflict

        switch scope {
        case .workoutDuplicate:
            return decideRichestWins(candidates)

        case .metric(let metricId, let inWorkout):
            if manualWinsMetrics.contains(metricId),
               let outcome = decideManualWins(candidates: candidates, metricId: metricId) {
                return outcome
            }
            if metricId == MetricID.weight {
                return decideMostRecentWins(candidates: candidates, metricId: metricId)
            }
            if metricId == MetricID.heartRate, inWorkout,
               let outcome = decideChestStrapPriority(candidates: candidates) {
                return outcome
            }
            if let priorityRule, priorityRule.metricId == metricId {
                return decidePriorityOrder(candidates: candidates, rule: priorityRule)
            }
            return nil
        }
    }

    // MARK: - Individual rules

    private static func decideManualWins(candidates: [CandidateReading], metricId: String) -> Outcome? {
        let manual = candidates.filter(\.isManualEntry)
        guard !manual.isEmpty else { return nil }
        let winner = mostRecent(manual)
        return makeOutcome(ruleId: manualWinsRuleId, winner: winner, candidates: candidates,
                            detail: ["metric_id": metricId, "manual_candidate_count": String(manual.count)])
    }

    private static func decideMostRecentWins(candidates: [CandidateReading], metricId: String) -> Outcome? {
        let winner = mostRecent(candidates)
        return makeOutcome(ruleId: mostRecentWeightRuleId, winner: winner, candidates: candidates,
                            detail: ["metric_id": metricId, "reason": "most_recent_measurement_wins"])
    }

    private static func decideChestStrapPriority(candidates: [CandidateReading]) -> Outcome? {
        // Deterministic tie-break when 2+ chest-strap candidates are present: most-recently-
        // measured wins, id breaks a tie — the same `mostRecent` idiom `decideManualWins`/
        // `decideMostRecentWins` already use, never array input order.
        let straps = candidates.filter { $0.classification == SourcePriorityRule.ClassificationKey.bleChestStrapHR }
        guard !straps.isEmpty else { return nil }
        let winner = mostRecent(straps)
        return makeOutcome(ruleId: chestStrapRuleId, winner: winner, candidates: candidates,
                            detail: ["reason": "chest_strap_beats_wrist_optical_in_workout"])
    }

    private static func decideRichestWins(_ candidates: [CandidateReading]) -> Outcome? {
        // Deterministic tie-break: highest richness first, smallest id breaks a tie — mirrors
        // `DedupLite.reconcile`'s own "pick a total order, then take the head" shape.
        guard let winner = candidates.sorted(by: { a, b in
            a.richnessScore != b.richnessScore ? a.richnessScore > b.richnessScore : a.id < b.id
        }).first else { return nil }
        return makeOutcome(ruleId: richestWorkoutRuleId, winner: winner, candidates: candidates,
                            detail: ["reason": "richest_source_wins_duplicate_workout"])
    }

    private static func decidePriorityOrder(candidates: [CandidateReading], rule: SourcePriorityRule) -> Outcome? {
        guard !rule.priorityOrder.isEmpty else { return nil }
        func rank(_ c: CandidateReading) -> Int {
            rule.priorityOrder.firstIndex(of: c.classification) ?? rule.priorityOrder.count
        }
        let ranked = candidates.filter { rank($0) < rule.priorityOrder.count }
        guard let winner = ranked.sorted(by: { rank($0) != rank($1) ? rank($0) < rank($1) : $0.id < $1.id }).first
        else { return nil } // no candidate matches a known classification — genuinely unresolved
        return makeOutcome(ruleId: priorityOrderRuleId, winner: winner, candidates: candidates,
                            detail: ["metric_id": rule.metricId, "priority_order": rule.priorityOrder.joined(separator: ">")])
    }

    // MARK: - Shared helpers

    private static func mostRecent(_ candidates: [CandidateReading]) -> CandidateReading {
        candidates.sorted { a, b in
            a.measuredAt != b.measuredAt ? a.measuredAt > b.measuredAt : a.id < b.id
        }.first! // safe: callers only ever pass a non-empty filtered slice of a 2+ candidate list
    }

    /// The ONE place `loserIds` is computed — always "every candidate that isn't the winner",
    /// never a separately-tracked list, so winner/loser bookkeeping cannot drift apart. Also the
    /// ONE place every rule's `detail` picks up `winner_source`/`loser_source` — matching
    /// `DedupLite.reconcile`'s exact key names/semantics, which `DataConflictsScreen`'s "why am I
    /// seeing this value?" pills already unconditionally read. `loser_source` is a sorted,
    /// deduplicated, comma-joined list rather than a single id: unlike `DedupLite` (strictly
    /// pairwise), a reconciliation-v2 outcome can suppress 2+ losers at once, and
    /// `ReconciliationDecision.detail`'s own doc comment already describes this field as holding
    /// (plural) "source names".
    private static func makeOutcome(ruleId: String, winner: CandidateReading, candidates: [CandidateReading],
                                     detail: [String: String]) -> Outcome {
        let loserCandidates = candidates.filter { $0.id != winner.id }
        let losers = loserCandidates.map(\.id).sorted()
        var fullDetail = detail
        fullDetail["winner_source"] = winner.sourceId
        fullDetail["loser_source"] = Set(loserCandidates.map(\.sourceId)).sorted().joined(separator: ",")
        return Outcome(ruleId: ruleId, ruleVersion: ruleVersion, winnerId: winner.id, loserIds: losers, detail: fullDetail)
    }
}

public extension ConflictDecisionEngine.Outcome {
    /// Turns this pure outcome into the actual, journal-ready `ReconciliationDecision` rows — one
    /// per suppressed candidate, ALL sharing `keptRecordId == winnerId` (I3: every loser is
    /// suppressed, never deleted; a 3+-candidate conflict journals multiple rows here, exactly
    /// like `DedupLite.reconcile`'s own multi-suppression shape). Id minting and the wall clock
    /// live at this write boundary, never inside `ConflictDecisionEngine.decide` — which stays a
    /// pure function of its inputs so it is trivially, deterministically testable.
    func makeDecisions(batchId: String? = nil, clock: Clock = SystemClock()) -> [ReconciliationDecision] {
        let now = clock.now()
        return loserIds.map { loserId in
            ReconciliationDecision(id: ULID.newID(clock: clock), batchId: batchId, rule: ruleId,
                                    ruleVersion: ruleVersion, keptRecordId: winnerId, suppressedRecordId: loserId,
                                    score: nil, reversible: true, decidedAt: now, detail: detail)
        }
    }
}
