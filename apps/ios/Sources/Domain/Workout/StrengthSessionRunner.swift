import Foundation

// MARK: - Weight unit

/// Kilograms per international avoirdupois pound (exact, by definition). The one conversion
/// constant strength logging needs, and the reason it exists at all: every weight COMPARISON in
/// this module (PR detection in `WorkoutQuality.swift`, e1RM) happens in canonical kilograms,
/// never on the raw logged number. Comparing "220" (lb) against "100" (kg) as bare doubles is
/// exactly how a unit switch fabricates a false PR — see `WorkoutQualityTests.
/// testUnitSwitchDoesNotFabricateAFalsePR`.
private let kilogramsPerPound = 0.45359237

/// The unit a set's weight was actually logged in, matching `strength_sets.weight_unit`.
/// `canonicalUnit` (kg) is what every stored `DerivedValue` in this module is expressed in —
/// this enum is the one and only place that conversion happens.
public enum WeightUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case kg, lb

    /// `value`, given in this unit, expressed in canonical kilograms.
    public func toKilograms(_ value: Double) -> Double {
        switch self {
        case .kg: return value
        case .lb: return value * kilogramsPerPound
        }
    }
}

// MARK: - Set kind

/// The role a logged set plays, matching `strength_sets.set_kind` (migration 9). A closed enum —
/// unlike `WorkoutEntry.activityType`'s deliberately open string — because these kinds gate real
/// downstream behavior (PR eligibility, volume-load inclusion) rather than being purely
/// descriptive, so an unrecognized kind is a decoding bug, not a display gap.
///
/// `warmUp` is the only kind excluded from PR/volume math BY DEFAULT (plan §7A.5/§9.18) — a
/// drop/back-off/assisted/timed set is still a genuine effort against a working weight and stays
/// eligible unless the caller says otherwise.
public enum StrengthSetKind: String, Codable, Hashable, Sendable, CaseIterable {
    case warmUp = "warm_up"
    case working
    case drop
    case failure
    case backOff = "back_off"
    case assisted
    case timed

    /// Arabic/RTL readiness is a first-order concern (CLAUDE.md) — every kind a lifter can tag a
    /// set with gets bilingual copy from day one, matching `WorkoutLifecycleState.displayLabel`'s
    /// sibling convention, even though no screen renders this yet in this domain-only slice.
    public var displayLabel: LocalizedString {
        switch self {
        case .warmUp: return LocalizedString(en: "Warm-up", ar: "إحماء")
        case .working: return LocalizedString(en: "Working set", ar: "مجموعة عمل")
        case .drop: return LocalizedString(en: "Drop set", ar: "مجموعة تنازلية")
        case .failure: return LocalizedString(en: "To failure", ar: "حتى الفشل")
        case .backOff: return LocalizedString(en: "Back-off set", ar: "مجموعة تراجعية")
        case .assisted: return LocalizedString(en: "Assisted", ar: "بمساعدة")
        case .timed: return LocalizedString(en: "Timed", ar: "بالوقت")
        }
    }
}

// MARK: - Strength set (append-first ledger row)

/// One logged set, mirroring `strength_sets` (migration 9). Append-first with an auditable
/// revision chain — EXACTLY `HydrationEntry`'s shape and for the identical reason (§9.18 / plan's
/// hydration precedent): a corrected set (wrong weight logged) APPENDS a new revision, it never
/// UPDATEs the row, so what the lifter actually logged — and how they later corrected it — stays
/// recoverable (I2-flavored).
///
/// **No embedded provenance columns**, unlike `RawSample`/`IntervalRecord`. A logged set has no
/// upstream device or ingestion path to preserve lineage for — a lifted weight is definitionally
/// something the lifter reports about themselves, not a HealthKit/BLE reading BADAN received from
/// somewhere. This mirrors why `route_points`/`session_stages` also carry no provenance (migration
/// 4's comment block): the parent `sessions` row already carries the one provenance that matters
/// (that this workout happened, and how BADAN learned about it), and `session_id` is the join.
public struct StrengthSet: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var originalId: String
    public var supersedes: String?
    public var revision: Int
    /// A dictionary movement id (`packages/contracts/dictionaries/movements.json`), when the set
    /// is for a recognized movement.
    public var movementId: String?
    /// A free-text label, when the movement isn't in the dictionary — same dictionary-vs-custom
    /// split `BeverageDefinition`/`SymptomEntry` already use. At least one of `movementId`/
    /// `customLabel` should be present for a set to be nameable; neither is enforced NOT NULL at
    /// the schema level (mirrors `WorkoutEntry.activityType`'s open-vocabulary posture).
    public var customLabel: String?
    public var setKind: StrengthSetKind
    /// Groups sets performed back-to-back across (possibly different) movements as one superset —
    /// e.g. every set tagged with the same group id is "superset A" regardless of which movement
    /// each individual set names. Nil for a standalone set.
    public var supersetGroup: String?
    /// Position within the SESSION (not within the movement) — see `StrengthSetLedger.nextSeq`'s
    /// doc for why this must stay session-scoped: a movement-scoped counter is exactly what an
    /// exercise swap could collide or renumber on.
    public var seq: Int
    public var reps: Int?
    public var weightValue: Double?
    public var weightUnit: WeightUnit?
    /// When the set was actually performed (or logged, for a manually backfilled entry) — the
    /// ledger's chronological anchor, distinct from `updatedAt`'s row-bookkeeping timestamp.
    public var recordedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isOriginal: Bool { supersedes == nil }
    public var isRevised: Bool { revision > 1 }

    /// Denormalized onto `strength_sets.is_warm_up` for fast filtering (`WHERE is_warm_up = 0`)
    /// without a query needing to know which `set_kind` values count as warm-up (migration 9's own
    /// comment on the column). Computed here — never independently settable — so the stored flag
    /// can never drift from the kind that defines it; `StrengthSetRepository.insertSet` writes
    /// this value verbatim rather than accepting a caller-supplied bool.
    public var isWarmUp: Bool { setKind == .warmUp }

    /// A set is COMPLETE only when it names a movement (or a custom label) AND both reps and
    /// weight (with a unit) were recorded. A partial set — abandoned mid-entry, interrupted by a
    /// crash, or missing weight/reps — is real data (the row itself, and its `recordedAt`), but
    /// must never feed e1RM or PR math: the plan's named risk is exactly a "PR caveat engine
    /// [that] disallows false PRs on partial data," and guessing a missing number to complete the
    /// picture would be the opposite of that.
    public var isComplete: Bool {
        (movementId != nil || customLabel != nil) && reps != nil && weightValue != nil && weightUnit != nil
    }

    /// The logged weight in canonical kilograms, or nil for a partial set with no weight/unit.
    public var weightKg: Double? {
        guard let weightValue, let weightUnit else { return nil }
        return weightUnit.toKilograms(weightValue)
    }

    public init(id: String, sessionId: String, originalId: String? = nil, supersedes: String? = nil,
                revision: Int = 1, movementId: String? = nil, customLabel: String? = nil,
                setKind: StrengthSetKind, supersetGroup: String? = nil, seq: Int, reps: Int? = nil,
                weightValue: Double? = nil, weightUnit: WeightUnit? = nil, recordedAt: Date,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.originalId = originalId ?? id
        self.supersedes = supersedes
        self.revision = revision
        self.movementId = movementId
        self.customLabel = customLabel
        self.setKind = setKind
        self.supersetGroup = supersetGroup
        self.seq = seq
        self.reps = reps
        self.weightValue = weightValue
        self.weightUnit = weightUnit
        self.recordedAt = recordedAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

// MARK: - Ledger logic (pure)

/// Pure, storage-free logic for the strength-set ledger — building originals and revisions, and
/// computing the LIVE set. Mirrors `HydrationLedger` field for field: the repository's SQL
/// (`StrengthSetRepository.liveSets`) implements the identical rule, and a divergence between the
/// two is a bug on one side, not an acceptable difference.
public enum StrengthSetLedger {

    /// The next `seq` for a NEW set in a session — one past the highest `seq` already used,
    /// SESSION-WIDE, never scoped per movement. Scoping this per-movement is the exact bug an
    /// exercise swap must not trigger: if `seq` restarted at 1 for a newly-swapped-to movement, two
    /// different sets in the same session could collide on `(session_id, seq)`, and resolving that
    /// collision later would renumber — and by extension appear to reorder — sets that were never
    /// touched, which is precisely what "preserves already-completed sets" forbids (plan §9.18).
    public static func nextSeq(existing: [StrengthSet]) -> Int {
        (existing.map(\.seq).max() ?? 0) + 1
    }

    /// Builds an original (first-time) set: `originalId == id`, no `supersedes`, revision 1.
    public static func makeSet(id: String, sessionId: String, movementId: String? = nil,
                              customLabel: String? = nil, kind: StrengthSetKind,
                              supersetGroup: String? = nil, seq: Int, reps: Int? = nil,
                              weightValue: Double? = nil, weightUnit: WeightUnit? = nil,
                              recordedAt: Date, updatedAt: Date, originDeviceId: String) -> StrengthSet {
        StrengthSet(id: id, sessionId: sessionId, originalId: id, supersedes: nil, revision: 1,
                   movementId: movementId, customLabel: customLabel, setKind: kind,
                   supersetGroup: supersetGroup, seq: seq, reps: reps, weightValue: weightValue,
                   weightUnit: weightUnit, recordedAt: recordedAt, updatedAt: updatedAt,
                   originDeviceId: originDeviceId)
    }

    /// Builds a revision that supersedes `live` — an APPEND, never a mutation of `live` (I2),
    /// exactly mirroring `HydrationLedger.makeRevision`. `sessionId` and `seq` always carry over
    /// unconditionally (not defaulted-and-overridable): a correction fixes what was logged, never
    /// where it sat in the session or which session it belonged to.
    public static func makeRevision(of live: StrengthSet, id: String, movementId: String?? = nil,
                                    customLabel: String?? = nil, kind: StrengthSetKind? = nil,
                                    supersetGroup: String?? = nil, reps: Int?? = nil,
                                    weightValue: Double?? = nil, weightUnit: WeightUnit?? = nil,
                                    recordedAt: Date? = nil, updatedAt: Date,
                                    originDeviceId: String) -> StrengthSet {
        StrengthSet(
            id: id, sessionId: live.sessionId, originalId: live.originalId, supersedes: live.id,
            revision: live.revision + 1,
            movementId: movementId ?? live.movementId,
            customLabel: customLabel ?? live.customLabel,
            setKind: kind ?? live.setKind,
            supersetGroup: supersetGroup ?? live.supersetGroup,
            seq: live.seq,
            reps: reps ?? live.reps,
            weightValue: weightValue ?? live.weightValue,
            weightUnit: weightUnit ?? live.weightUnit,
            recordedAt: recordedAt ?? live.recordedAt,
            updatedAt: updatedAt, originDeviceId: originDeviceId)
    }

    /// The LIVE set over a group of rows (any mix of chains): a row is live iff it is not
    /// tombstoned AND no *non-deleted* row supersedes it. Identical rule to
    /// `HydrationLedger.liveEntries` — see that doc for why this one rule covers both undo
    /// (tombstone a revision -> the prior version becomes live again) and delete (tombstone the
    /// whole chain -> nothing is live).
    public static func liveSets(_ all: [StrengthSet]) -> [StrengthSet] {
        let supersededByLive = Set(all.compactMap { $0.deletedAt == nil ? $0.supersedes : nil })
        return all.filter { $0.deletedAt == nil && !supersededByLive.contains($0.id) }
    }
}

// MARK: - Rest timer (pure duration/state)

/// A rest-timer's state as pure duration arithmetic — no `Timer`, no UI, no wall-clock read. The
/// caller supplies `now`; everything here is a total function over `(targetSeconds, startedAt,
/// now)`, so it is exactly as unit-testable as `HydrationLedger` without a device or a run loop.
public struct RestTimer: Sendable, Hashable {
    public var targetSeconds: Double
    public var startedAt: Date?

    public init(targetSeconds: Double, startedAt: Date? = nil) {
        self.targetSeconds = targetSeconds
        self.startedAt = startedAt
    }

    public var isRunning: Bool { startedAt != nil }

    /// A copy of this timer started at `now`. Starting an already-running timer restarts it from
    /// `now` rather than accumulating — a rest timer has one countdown, not a stopwatch.
    public func started(at now: Date) -> RestTimer {
        RestTimer(targetSeconds: targetSeconds, startedAt: now)
    }

    /// A copy of this timer stopped (cleared) — e.g. the lifter begins their next set early.
    public func stopped() -> RestTimer {
        RestTimer(targetSeconds: targetSeconds, startedAt: nil)
    }

    public func elapsed(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Seconds remaining, clamped to zero (never negative — "done" is zero, not a negative
    /// overrun number that would read as a countUP once the countdown passes).
    public func remaining(at now: Date) -> Double {
        guard isRunning else { return targetSeconds }
        return max(0, targetSeconds - elapsed(at: now))
    }

    public func isComplete(at now: Date) -> Bool {
        isRunning && remaining(at: now) <= 0
    }
}

// MARK: - Session runner

public enum StrengthSessionError: Error, Equatable {
    /// `reviseSet`/`swapMovement` was asked to act on a chain with nothing currently live —
    /// already deleted, or the id was never a set in this session.
    case noLiveSet(originalId: String)
}

/// Orchestrates a live strength-training session's SET log: recording, correcting, and swapping
/// exercises mid-session. Every write goes through `StrengthSetRepository` IMMEDIATELY after each
/// set — never batched into one transaction spanning multiple sets — because a live session is
/// exactly the case a crash (app killed, phone locked, low battery) can interrupt between any two
/// sets, and losing an already-completed set to an un-flushed batch is a materially worse failure
/// than one extra fsync per set. This is a stricter posture than
/// `HydrationRepository.transaction`'s batched writes: a hydration log's worst case is losing a
/// still-in-progress edit, a strength session's worst case is losing a rep count nobody can
/// reconstruct after the fact.
final class StrengthSessionRunner {
    private let repository: StrengthSetRepository
    private let clock: Clock
    private let deviceId: String

    init(repository: StrengthSetRepository, clock: Clock, deviceId: String) {
        self.repository = repository
        self.clock = clock
        self.deviceId = deviceId
    }

    /// A fresh superset-group id. Recording several sets (across however many movements) with the
    /// same returned id groups them as one superset for display; a standalone set passes `nil`.
    func startSuperset() -> String { ULID.newID(clock: clock) }

    /// Records a brand-new set and persists it immediately (crash-safe: see the type doc).
    /// `seq` is resolved from every set already in the session — see `StrengthSetLedger.nextSeq`
    /// for why this is session-scoped rather than movement-scoped, which is what makes an exercise
    /// swap (simply passing a different `movementId` to the next call) safe by construction: nothing
    /// about a prior set — its id, its seq, its movementId — is touched by a later call naming a
    /// different movement.
    @discardableResult
    func recordSet(sessionId: String, movementId: String? = nil, customLabel: String? = nil,
                   kind: StrengthSetKind, supersetGroup: String? = nil, reps: Int? = nil,
                   weightValue: Double? = nil, weightUnit: WeightUnit? = nil,
                   recordedAt: Date? = nil) throws -> StrengthSet {
        let existing = try repository.sets(sessionId: sessionId)
        let seq = StrengthSetLedger.nextSeq(existing: existing)
        let now = clock.now()
        let set = StrengthSetLedger.makeSet(
            id: ULID.newID(clock: clock), sessionId: sessionId, movementId: movementId,
            customLabel: customLabel, kind: kind, supersetGroup: supersetGroup, seq: seq,
            reps: reps, weightValue: weightValue, weightUnit: weightUnit,
            recordedAt: recordedAt ?? now, updatedAt: now, originDeviceId: deviceId)
        try repository.insertSet(set)
        return set
    }

    /// Corrects the LIVE set at `originalId` (wrong weight, wrong reps, mislabeled movement) by
    /// APPENDING a revision — never mutating the logged row (I2). `seq` always carries over from
    /// the live row (see `StrengthSetLedger.makeRevision`).
    @discardableResult
    func reviseSet(originalId: String, movementId: String?? = nil, customLabel: String?? = nil,
                  kind: StrengthSetKind? = nil, supersetGroup: String?? = nil, reps: Int?? = nil,
                  weightValue: Double?? = nil, weightUnit: WeightUnit?? = nil,
                  recordedAt: Date? = nil) throws -> StrengthSet {
        guard let live = try repository.liveSet(originalId: originalId) else {
            throw StrengthSessionError.noLiveSet(originalId: originalId)
        }
        let now = clock.now()
        let revision = StrengthSetLedger.makeRevision(
            of: live, id: ULID.newID(clock: clock), movementId: movementId, customLabel: customLabel,
            kind: kind, supersetGroup: supersetGroup, reps: reps, weightValue: weightValue,
            weightUnit: weightUnit, recordedAt: recordedAt, updatedAt: now, originDeviceId: deviceId)
        try repository.insertSet(revision)
        return revision
    }
}
