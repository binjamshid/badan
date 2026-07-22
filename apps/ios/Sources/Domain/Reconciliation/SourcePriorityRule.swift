import Foundation

/// EPIC-43 (plan §7A.6 / §9.19): the per-metric default priority order `ConflictDecisionEngine`
/// (see `DataConflict.swift`) falls back to once a conflict isn't decided by one of the named
/// dynamic defaults (manual-wins, most-recent-weight, richest-workout). `isUserOverride`
/// distinguishes a BADAN-shipped default from a choice the person actually made in the future
/// Device Hub / Source Priority Editor (a UI lane this slice does not build) — the "defaults,
/// user-overridable, default visible" requirement §7A.6 states for the reconciliation engine.
///
/// Reuses NOTHING from `dedup_decisions`/`ReconciliationDecision` — this is the RULE a decision is
/// made *from*, not the decision itself (which is always the existing `ReconciliationDecision`
/// type; see that type's own doc and `ConflictDecisionEngine.Outcome.makeDecisions`).
public struct SourcePriorityRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// A canonical metric id (`MetricID.heartRate`), never a metric-family wildcard in this
    /// slice — `ConflictDecisionEngine` matches a candidate's `metricId` against this field by
    /// exact equality. (A family-wildcard scope, e.g. "workout.*", is a documented future
    /// extension, not something this schema or engine silently half-supports today.)
    public var metricId: String
    /// Ordered classification keys, HIGHEST priority first. A classification key is a short,
    /// stable string describing WHAT KIND of source/device produced a reading — never a specific
    /// device instance — e.g. `ClassificationKey.bleChestStrapHR`, `ClassificationKey.wristOptical`,
    /// `ClassificationKey.manual`. `ConflictDecisionEngine` matches a `CandidateReading.classification`
    /// against this list positionally; a classification absent from the list never wins this rule
    /// (it sorts last, "unranked" — never "wins by omission").
    public var priorityOrder: [String]
    /// `false` = a BADAN-shipped default (see `SourcePriorityRule.defaultHeartRateDuringWorkout`);
    /// `true` = the person picked this order themselves. Never inferred from `priorityOrder`'s
    /// contents — only ever set by whichever code path WROTE the row.
    public var isUserOverride: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, metricId: String, priorityOrder: [String], isUserOverride: Bool = false,
                createdAt: Date, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id
        self.metricId = metricId
        self.priorityOrder = priorityOrder
        self.isUserOverride = isUserOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

extension SourcePriorityRule {
    /// Stable classification-key vocabulary a `CandidateReading.classification` is expected to use
    /// so it can be matched against a `priorityOrder`. Deliberately a short, closed set for this
    /// slice — one entry per default rule this epic actually ships, not a speculative taxonomy of
    /// every device kind BADAN might ever support.
    public enum ClassificationKey {
        /// A BLE-direct chest-strap heart-rate sensor (`GattServiceUUID.heartRate` conformant,
        /// `DeviceCapability.heartRateChestStrap`).
        public static let bleChestStrapHR = "ble_direct.heart_rate_chest_strap"
        /// A wrist-worn optical heart-rate sensor, however it reached BADAN (HealthKit/Health
        /// Connect from a watch — this slice does not build a BLE-direct wrist-optical path).
        public static let wristOpticalHR = "platform.heart_rate_wrist_optical"
        /// A manually-typed entry. Mirrors `IngestionPath.manual`, kept as its own string constant
        /// (rather than importing `IngestionPath` here) so this file's classification vocabulary
        /// stays self-contained and independent of the ingestion enum's own evolution.
        public static let manual = "manual"
    }

    /// BADAN's one shipped default for THIS slice: chest strap beats wrist-optical HR during a
    /// workout (plan §7A.6 / §9.19's named rule). Pure data — persisting it (and seeding it once)
    /// is a future settings/seed-path concern, not this struct's job.
    public static func defaultHeartRateDuringWorkout(id: String, now: Date, originDeviceId: String) -> SourcePriorityRule {
        SourcePriorityRule(id: id, metricId: MetricID.heartRate,
                            priorityOrder: [ClassificationKey.bleChestStrapHR, ClassificationKey.wristOpticalHR],
                            isUserOverride: false, createdAt: now, updatedAt: now, originDeviceId: originDeviceId)
    }
}
