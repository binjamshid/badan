import Foundation

/// The one workout history: ingested sessions and hand-logged entries in a single list, with the
/// dedup relationship between them visible rather than resolved away (EPIC-03 task 5/§9.1).
///
/// **The problem this exists to solve.** `IngestionPipeline.dedupWorkouts`' own doc states it
/// plainly: "Any surface listing manual workouts must consult `forSuppressed` — a unified workout
/// list that reads `LoggingRepository.workouts` alone will show both the ingested workout and its
/// manual twin, which is the duplicate this rule exists to remove." But the opposite failure is
/// just as real and worse for trust: quietly filtering the manual entry out makes the user's own
/// typed record vanish with no explanation, which looks exactly like BADAN deleting it. I3 says
/// suppression is never deletion, and a UI that renders suppression as absence has broken that
/// invariant at the only layer the user can actually see.
///
/// So a suppressed manual entry is neither shown as a peer nor hidden: it is **attached to the
/// twin that suppressed it**, as a child row carrying the rule, the overlap and the "nothing was
/// deleted" statement.
///
/// Pure and store-free — the caller supplies the rows and a suppression lookup — so the assembly
/// rules are unit-testable without a database.
enum UnifiedWorkoutList {

    /// Why a manual entry is attached to an ingested one, in the terms the journal recorded it.
    ///
    /// Built from the `ReconciliationDecision` rather than recomputed, so what the UI explains is
    /// literally the decision that was made, not a plausible reconstruction of it. `detail` keys
    /// are the ones `DedupLite.reconcileWorkouts` writes.
    struct Lineage: Equatable, Sendable {
        let decisionId: String
        let keptSessionId: String
        let rule: String
        let ruleVersion: String
        let decidedAt: Date
        let reversible: Bool
        /// Overlap as a percentage, when the journal recorded a score.
        let overlapPercent: Double?
        /// What each side called the activity. Both are journaled precisely because the rule
        /// deliberately does NOT require them to match (see `DedupLite.reconcileWorkouts`), so a
        /// wrong pairing is visible to the user rather than silent.
        let keptActivity: String?
        let suppressedActivity: String?

        init(decision: ReconciliationDecision) {
            self.decisionId = decision.id
            self.keptSessionId = decision.keptRecordId
            self.rule = decision.rule
            self.ruleVersion = decision.ruleVersion
            self.decidedAt = decision.decidedAt
            self.reversible = decision.reversible
            self.overlapPercent = decision.score.map { $0 * 100 }
            self.keptActivity = decision.detail["kept_activity"]
            self.suppressedActivity = decision.detail["suppressed_activity"]
        }
    }

    /// One entry in the list, from either store.
    struct Item: Identifiable, Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            /// A `sessions` row with `kind == .workout`.
            case ingested(sessionId: String, sourceId: String, sourceWorkoutUUID: String?, hasRoute: Bool)
            /// A `workout_entries` row.
            case manual(entryId: String)
        }

        let id: String
        let origin: Origin
        let startAt: Date
        let endAt: Date
        /// The activity as its own store spells it — a `HKTypeMap.activitySlug` for ingested
        /// rows, free text from the quick-add form for manual ones. Never normalized across the
        /// two here: the row should show what its own source recorded, and
        /// `WorkoutActivity.label(forStored:)` handles the display of both shapes.
        let activityType: String
        let energyKcal: Double?
        let distanceMeters: Double?
        let avgHeartRateBpm: Double?
        let maxHeartRateBpm: Double?
        let perceivedEffort: Int?
        let ingestionPath: IngestionPath
        /// Manual entries this ingested row suppressed, rendered beneath it.
        let suppressedChildren: [Child]

        var durationSeconds: Double { endAt.timeIntervalSince(startAt) }
    }

    /// A manual entry currently set aside by the ingested row it hangs under.
    struct Child: Identifiable, Equatable, Sendable {
        let entry: WorkoutEntry
        let lineage: Lineage
        var id: String { entry.id }
    }

    /// Build the list.
    ///
    /// - Parameters:
    ///   - ingested: `kind == .workout` sessions in range.
    ///   - manual: `workout_entries` in range.
    ///   - lineage: the live suppression lookup — `ReconciliationRepository.forSuppressed`, which
    ///     already excludes reversed decisions, so a reversed entry comes back through this
    ///     function as an ordinary peer row with no caller-side special case.
    /// - Returns: newest first.
    static func assemble(ingested: [Session],
                         manual: [WorkoutEntry],
                         lineage: (String) -> ReconciliationDecision?) -> [Item] {
        var childrenBySession: [String: [Child]] = [:]
        var suppressedIds = Set<String>()

        for entry in manual where entry.deletedAt == nil {
            guard let decision = lineage(entry.id), decision.reversedAt == nil else { continue }
            childrenBySession[decision.keptRecordId, default: []]
                .append(Child(entry: entry, lineage: Lineage(decision: decision)))
            suppressedIds.insert(entry.id)
        }

        var items: [Item] = ingested
            .filter { $0.kind == .workout && $0.deletedAt == nil }
            .map { session in
                let detail = session.detail.workout
                let children = (childrenBySession[session.id] ?? []).sorted { $0.entry.startAt > $1.entry.startAt }
                return Item(
                    id: session.id,
                    origin: .ingested(sessionId: session.id,
                                      sourceId: session.provenance.sourceId,
                                      sourceWorkoutUUID: detail?.sourceWorkoutUUID,
                                      // `routeRef` is nil both when no route exists upstream and
                                      // when BADAN wasn't permitted to read one — the detail
                                      // screen distinguishes the two by consent state, this flag
                                      // only says whether a trace is on disk.
                                      hasRoute: detail?.routeRef != nil),
                    startAt: session.startAt, endAt: session.endAt,
                    activityType: detail?.activityType ?? "other",
                    energyKcal: detail?.totals.energyKcal,
                    distanceMeters: detail?.totals.distanceMeters,
                    avgHeartRateBpm: detail?.totals.avgHeartRateBpm,
                    maxHeartRateBpm: detail?.totals.maxHeartRateBpm,
                    perceivedEffort: nil,
                    ingestionPath: session.provenance.ingestionPath,
                    suppressedChildren: children)
            }

        // A suppressed entry whose winner isn't in this window (a manual entry near the edge of
        // the range, paired with a session just outside it) would otherwise disappear entirely —
        // the exact "looks deleted" outcome this type exists to prevent. Promote it back to a
        // peer row instead; it carries no lineage banner because its twin isn't on screen to
        // point at.
        let visibleSessionIds = Set(items.map(\.id))
        items += manual
            .filter { $0.deletedAt == nil }
            .filter { entry in
                guard suppressedIds.contains(entry.id) else { return true }
                guard let decision = lineage(entry.id) else { return true }
                return !visibleSessionIds.contains(decision.keptRecordId)
            }
            .map { entry in
                Item(id: entry.id, origin: .manual(entryId: entry.id),
                     startAt: entry.startAt, endAt: entry.endAt,
                     activityType: entry.activityType,
                     energyKcal: entry.energyKcal, distanceMeters: entry.distanceM,
                     avgHeartRateBpm: entry.avgHr, maxHeartRateBpm: entry.maxHr,
                     perceivedEffort: entry.perceivedEffort,
                     ingestionPath: entry.ingestionPath,
                     suppressedChildren: [])
            }

        // Ties broken by id so two workouts starting in the same second keep a stable order
        // across reloads instead of swapping places on every refresh.
        return items.sorted { a, b in
            if a.startAt != b.startAt { return a.startAt > b.startAt }
            return a.id > b.id
        }
    }
}
