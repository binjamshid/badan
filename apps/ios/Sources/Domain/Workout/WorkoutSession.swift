import Foundation

/// Denormalized presence/counts for migration 9's child tables (`strength_sets`,
/// `workout_intervals`, `workout_quality`), all of which key off ONE column — the parent
/// session's own id (`session_id`) — so there is no separate foreign id to store per child table,
/// only a cheap display cache of how many rows exist. Stored rather than counted-on-read for the
/// same reason `WorkoutRoute.pointCount` is stored (Measurements.swift): a workout list can show
/// "5 sets logged" without loading 5 rows per workout. Never a substitute for reading the child
/// table itself for anything but display — a PR/volume computation reads `strength_sets` directly.
///
/// The three child-table TYPES themselves (`StrengthSet`, `WorkoutInterval`, `WorkoutQuality`) are
/// intentionally not modeled here — they belong to the parallel lane that owns
/// `StrengthSessionRunner.swift`/`WorkoutQuality.swift`/`IntervalEngine.swift`. This is the minimal
/// shared shape this slice needs (a count, not a domain model), so the two lanes don't collide on
/// the same file.
public struct WorkoutChildTableRefs: Codable, Hashable, Sendable {
    public var hasCheckpoint: Bool
    public var strengthSetCount: Int
    public var intervalCount: Int
    public var qualityRecordCount: Int

    public init(hasCheckpoint: Bool = false, strengthSetCount: Int = 0, intervalCount: Int = 0,
                qualityRecordCount: Int = 0) {
        self.hasCheckpoint = hasCheckpoint
        self.strengthSetCount = strengthSetCount
        self.intervalCount = intervalCount
        self.qualityRecordCount = qualityRecordCount
    }
}

/// The workout OS's "detail_version 2" payload (EPIC-42, plan §9.18): the richer, versioned
/// session detail the plan describes as staying inside `sessions(kind=workout)` rather than a new
/// top-level table — "state history, source profile, quality summary, refs" laid on top of the
/// EXISTING v1 `WorkoutDetail` (Measurements.swift), never replacing it.
///
/// **Why this is its own type instead of a new field on `WorkoutDetail` itself.** `WorkoutDetail`
/// is `sessions.detail`'s `schemaVersion == 1` shape, and its own doc comment is explicit that the
/// contract keeping it readable is "additive-optional only" — but actually widening
/// `sessions.detail` requires `JSONBundleWriter`/`CSVWriter` (the readers of `SessionDetail.
/// workout`) to also learn the new shape, or a reader that doesn't would need to keep decoding the
/// OLD shape while a writer emits the NEW one, silently disagreeing about what a workout session
/// even contains. Export-writer changes are explicitly out of scope for this slice, so folding
/// this payload into `WorkoutDetail`/`SessionDetail` for real — bumping `WorkoutDetail.
/// schemaVersion` to 2 — is deferred to the slice that also updates those readers. Until then,
/// this type is where the v1.1 shape lives: additive, testable, and ready to be composed in
/// without this file changing when that slice arrives.
public struct WorkoutSessionDetail: Codable, Hashable, Sendable {
    /// The detail_version this payload represents, once it is folded into `sessions.detail`
    /// (plan §9.18). Not `WorkoutDetail.currentSchemaVersion` — that constant belongs to
    /// Measurements.swift and is untouched by this slice.
    public static let detailVersion = 2

    /// The existing v1 payload, embedded rather than duplicated: activity type, totals,
    /// route/HR refs. Reusing `WorkoutDetail.activityType` (a stable BADAN slug, never a
    /// platform's numeric enum value) keeps ONE definition of what an activity type IS, matching
    /// this same field's own doc in Measurements.swift.
    public var base: WorkoutDetail
    /// Every lifecycle transition `WorkoutStateMachine` recorded for this session — the audit
    /// trail a post-workout notebook renders as "auto-paused at 12:03, resumed at 12:05" (plan
    /// §7A.5), rather than just a final duration with no story behind it.
    public var stateHistory: [WorkoutStateTransition]
    /// `workout_quality.id` of this session's SESSION-LEVEL summary row (a `metric_family`
    /// value reserved for "overall", by convention of whichever engine computes it — not modeled
    /// in this slice), when one has been computed. Nil is the honest default: quality
    /// summarization is later Phase-3/4 work this slice does not compute, and per-metric-family
    /// rows (HR, GPS, cadence…) are read separately through `childRefs` — never blended into one
    /// number here (I5: raw and derived, and here, good-metric vs. bad-metric, stay separable).
    public var qualitySummaryRef: String?
    /// Denormalized presence/counts for the child tables migration 9 added, all scoped to this
    /// session's own id.
    public var childRefs: WorkoutChildTableRefs

    public init(base: WorkoutDetail, stateHistory: [WorkoutStateTransition] = [],
                qualitySummaryRef: String? = nil, childRefs: WorkoutChildTableRefs = WorkoutChildTableRefs()) {
        self.base = base
        self.stateHistory = stateHistory
        self.qualitySummaryRef = qualitySummaryRef
        self.childRefs = childRefs
    }
}

/// The workout OS's session aggregate (EPIC-42, plan §9.18). Domain-only for this slice: no
/// storage wiring (there is no `WorkoutSessionRepository` — a finalized session is still written
/// as an ordinary `sessions(kind=workout)` row, which `MeasurementRepository` already owns), no
/// export-writer wiring, no UI. This type exists so the pieces this slice DOES own —
/// `WorkoutStateMachine`'s lifecycle and `WorkoutSessionDetail`'s extended payload — have one
/// place to compose into the shape a later finalize step will actually persist.
///
/// `id` is the same ULID as `WorkoutStateMachine.sessionId` throughout a session's life, and
/// becomes `sessions.id` verbatim once finalized (I8) — there is exactly one id for a workout
/// from the moment recording starts to the moment it is a durable row, never a second id minted
/// at finalize time that would need reconciling with the first.
public struct WorkoutSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The stable BADAN slug (see `activities.json` / `WorkoutDetail.activityType`'s doc),
    /// carried at the aggregate level too so a live-session UI can read it without decoding
    /// `detail.base` first.
    public var activityType: String
    public var startAt: Date
    /// Nil while still live; set once the session reaches `.persisted`.
    public var endAt: Date?
    public var detail: WorkoutSessionDetail

    public var isLive: Bool { endAt == nil }

    public init(id: String, activityType: String, startAt: Date, endAt: Date? = nil,
                detail: WorkoutSessionDetail) {
        self.id = id
        self.activityType = activityType
        self.startAt = startAt
        self.endAt = endAt
        self.detail = detail
    }
}

public extension WorkoutSessionDetail {
    /// Builds the v1.1 extended detail payload from a state machine's final snapshot plus the v1
    /// totals a platform adapter already assembled. This is the pure seam a later slice's
    /// finalize step calls once `machine.state == .persisted`: it composes the payload, but never
    /// itself touches a repository or `sessions` — owning that write is finalize/export-writer
    /// territory, out of scope here (same boundary `WorkoutCheckpointRepository.clear` respects
    /// from the other side).
    static func finalizing(from machine: WorkoutStateMachine, base: WorkoutDetail,
                          qualitySummaryRef: String? = nil,
                          childRefs: WorkoutChildTableRefs = WorkoutChildTableRefs()) -> WorkoutSessionDetail {
        WorkoutSessionDetail(base: base, stateHistory: machine.stateHistory,
                            qualitySummaryRef: qualitySummaryRef, childRefs: childRefs)
    }
}
