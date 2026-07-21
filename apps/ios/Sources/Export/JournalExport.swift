import Foundation

/// The journal slice of an export: the behavior tags and the declared context intervals
/// (EPIC-29, plan §9.9/§9.10). Assembled by `ExportRunner` (or a test) and handed to
/// `JSONBundleWriter` as `logs.journal[]` / `logs.context_statuses[]`.
///
/// **Sensitive-plus, both families (I7).** A payload is only ever built for a scope whose
/// `includeSensitive` is set; the runner's gather is what enforces that, and
/// `JournalTests.testDefaultExportExcludesJournalAndContextStatuses` drives the real export path to
/// prove a default export carries neither array (with
/// `testSensitiveJSONExportCarriesJournalAndContextStatuses` as its other half, so the gate is shown
/// to open as well as to hold).
/// Nothing in this file re-checks consent — a writer that quietly re-derived the gate would
/// be a second, drifting copy of it.
struct JournalExportPayload {
    var entries: [JournalEntry]
    var statuses: [ContextStatus]

    var isEmpty: Bool { entries.isEmpty && statuses.isEmpty }

    init(entries: [JournalEntry] = [], statuses: [ContextStatus] = []) {
        self.entries = entries
        self.statuses = statuses
    }
}

/// Serializes the journal payload into the bundle's canonical JSON. Kept beside
/// `JSONBundleWriter` (the way `HydrationExportJSON` is) so the two log families render timestamps
/// and provenance through exactly the same helpers as every other record in the file.
enum JournalExportJSON {

    /// One behavior tag.
    ///
    /// `value`/`unit` are null for a `boolean` tag rather than being coerced to 1/"bool": the
    /// bundle should say what the row says, and a boolean tag asserts "this happened", not "this
    /// happened once". `value_kind` is what tells a reader which of the three shapes to expect.
    ///
    /// `recalled` is emitted as a derived boolean beside the two timestamps it comes from, so a
    /// consumer can see that an entry was logged after the fact without having to re-implement the
    /// comparison — and can still check it, because `occurred_at` and the full provenance (which
    /// carries `recorded_at`) are both right there.
    static func entry(_ e: JournalEntry) -> CanonicalJSON {
        .object([
            "record_id": .string(e.id),
            "behavior_id": .string(nullable: e.behaviorId),
            "custom_label": .string(nullable: e.customLabel),
            "value_kind": .string(e.valueKind.rawValue),
            "value": .number(nullable: e.value),
            "unit": .string(nullable: e.unit),
            "occurred_at": .string(TimestampFormatting.string(e.occurredAt, tzId: e.tzId)),
            "timezone": .string(e.tzId),
            "recalled": .bool(e.isRecalled),
            "note": .string(nullable: e.note),
            "provenance": JSONBundleWriter.provenance(e.provenance, tzId: e.tzId),
            "value_type": .string("raw"),
            "is_derived": .bool(false),
            "updated_at": .string(TimestampFormatting.string(e.updatedAt, tzId: e.tzId)),
            "origin_device_id": .string(e.originDeviceId),
            "deleted_at": e.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: e.tzId)) } ?? .null
        ])
    }

    /// One declared interval.
    ///
    /// `end_at` is null exactly when the status is still open, and that null is the fact — an
    /// export must not close an interval the user never closed by substituting "now" or the export
    /// timestamp, which would put an end date the user never declared into a file they may hand to
    /// a clinician.
    ///
    /// No confidence, ceiling or adjustment is serialized here, and that is deliberate: a status
    /// annotates how a value should be READ (§9.10) and never alters one, so the artifact carries
    /// the user's declaration and nothing computed from it. A reader wanting the caveat gets it
    /// from the app, against whatever the current annotation rules are.
    static func status(_ s: ContextStatus) -> CanonicalJSON {
        .object([
            "record_id": .string(s.id),
            "status_id": .string(nullable: s.statusId),
            "custom_label": .string(nullable: s.customLabel),
            "start_at": .string(TimestampFormatting.string(s.startAt, tzId: s.tzId)),
            "end_at": s.endAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: s.tzId)) } ?? .null,
            "open_ended": .bool(s.isOpenEnded),
            "timezone": .string(s.tzId),
            "note": .string(nullable: s.note),
            "provenance": JSONBundleWriter.provenance(s.provenance, tzId: s.tzId),
            "value_type": .string("raw"),
            "is_derived": .bool(false),
            "updated_at": .string(TimestampFormatting.string(s.updatedAt, tzId: s.tzId)),
            "origin_device_id": .string(s.originDeviceId),
            "deleted_at": s.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: s.tzId)) } ?? .null
        ])
    }
}
