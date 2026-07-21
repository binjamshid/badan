import Foundation

// MARK: - Behavior value kind

/// The shape of the answer a behavior tag carries (plan §9.9). Storing the KIND alongside the
/// value is what lets one table hold "did it happen" and "how many" and "how long" without any
/// reader having to guess from a nullable column: a `boolean` row has no value at all, and a
/// `count` row's 3 means three servings, not three minutes.
///
/// The correlation engine (a separate module, not this one) splits a behavior's days into a
/// with/without pair; `isPresent` below is the ONE place that split's meaning is defined, so a
/// count of 0 and an unset boolean can never disagree about whether the behavior happened.
public enum BehaviorValueKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Did it happen at all. Carries no `value` and no `unit` — the row's existence is the fact.
    case boolean
    /// How many times/servings. An integer count of the behavior itself, so it carries no
    /// physical unit (2 coffees is 2, not 2 of anything convertible).
    case count
    /// A measured amount in a canonical unit (`min` for a nap, etc.).
    case quantity

    public var displayLabel: LocalizedString {
        switch self {
        case .boolean: return LocalizedString(en: "Happened", ar: "حدث")
        case .count: return LocalizedString(en: "Count", ar: "العدد")
        case .quantity: return LocalizedString(en: "Amount", ar: "المقدار")
        }
    }
}

// MARK: - Journal entry

/// One logged behavior tag — the raw user assertion the correlation engine later reads (§9.9).
///
/// Sensitive-plus (I7). This type's rows live ONLY in `badan_sensitive.db`: a caffeine / alcohol /
/// screen-in-bed pattern is lifestyle-revealing in a way a step count is not, so it must be
/// removable by the file-deletion purge rather than a best-effort row sweep, and must never appear
/// in an export that did not explicitly ask for sensitive data. `JournalRepository` is the only
/// writer and it holds the sensitive connection alone — see its doc for why that is structural.
///
/// `behaviorId` (a `behaviors.json` key) and `customLabel` (the user's own words) are mutually
/// exclusive: exactly one is set. Storing the KEY rather than a rendered label is what keeps
/// Arabic/RTL first-order — a journal written in Arabic exports readably in English and back.
///
/// Carries full embedded provenance (I1) with `ingestionPath == .manual`. A manually asserted fact
/// is still a fact with an origin, and the provenance is what makes backdating honest: `occurredAt`
/// is when the behavior happened, `provenance.recordedAt` is when the user said so, and the gap
/// between them is `isRecalled` (see below) rather than an invisible fudge.
public struct JournalEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Dictionary key from `behaviors.json`. Nil exactly when `customLabel` is set.
    public var behaviorId: String?
    /// Free text, for a behavior the dictionary doesn't list. Nil exactly when `behaviorId` is set.
    public var customLabel: String?
    public var valueKind: BehaviorValueKind
    /// Nil for `.boolean` (the row's existence is the fact); the count/amount otherwise.
    public var value: Double?
    /// Canonical unit for `.quantity` only; nil for `.boolean` and `.count`.
    public var unit: String?
    /// When the behavior happened — the axis every correlation and day-bucketing reads.
    public var occurredAt: Date
    public var tzId: String
    public var note: String?
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, behaviorId: String? = nil, customLabel: String? = nil,
                valueKind: BehaviorValueKind, value: Double? = nil, unit: String? = nil,
                occurredAt: Date, tzId: String, note: String? = nil, provenance: Provenance,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.behaviorId = behaviorId; self.customLabel = customLabel
        self.valueKind = valueKind; self.value = value; self.unit = unit
        self.occurredAt = occurredAt; self.tzId = tzId; self.note = note
        self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// Whether this tag asserts the behavior happened. The one definition of the with/without
    /// split: a `.boolean` row's existence IS the assertion, while a `.count`/`.quantity` row with
    /// an explicit 0 is an assertion that it did NOT — "I had no coffee today" is real information
    /// a user can enter, and silently counting it in the "with" arm would poison every finding
    /// built on top of it.
    public var isPresent: Bool {
        switch valueKind {
        case .boolean: return true
        case .count, .quantity: return (value ?? 0) > 0
        }
    }

    /// True when the user logged this after the fact — the yesterday-recall path, which is a
    /// first-class way to use the journal and not an edge case (§11: "chips, yesterday recall").
    ///
    /// Derived from provenance rather than stored as a column: `recordedAt` already records when
    /// the user said it and `occurredAt` when it happened, so a stored flag would be a second copy
    /// of a fact the row already carries — and one that could drift. The one-hour threshold keeps
    /// "logged it a few minutes later" out of the recall bucket; anything beyond that (including
    /// every yesterday entry) reads as recalled.
    ///
    /// Nothing downstream may treat a recalled entry as less true. It is disclosure, not a
    /// discount: the entry counts exactly like a live one, and this exists so a reader can SEE
    /// that recall was involved rather than being told a same-day story that isn't so.
    public var isRecalled: Bool {
        provenance.recordedAt.timeIntervalSince(occurredAt) > 3_600
    }

    /// The local calendar day this entry belongs to, in the entry's own recorded time zone —
    /// the bucket key the correlation engine's day arms are built from. An unresolvable `tzId`
    /// falls back to UTC, matching how `TimestampFormatting` renders such a row, so the key and
    /// the printed timestamp never disagree about which day it was.
    public func dayKey(calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: occurredAt)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Construction

/// Builders for the two ways a journal entry is created. Both are plain functions returning a
/// value — there is deliberately no mutating "edit" here: a correction is a new row plus a
/// tombstone on the old one (`JournalRepository.deleteEntry`), so what the user originally said
/// stays recoverable.
public enum JournalLog {

    /// A tag logged as it happens. `recordedAt == occurredAt`, so `isRecalled` is false.
    public static func entry(id: String, behaviorId: String? = nil, customLabel: String? = nil,
                             valueKind: BehaviorValueKind, value: Double? = nil, unit: String? = nil,
                             occurredAt: Date, tzId: String, note: String? = nil,
                             sourceId: String, deviceId: String? = nil,
                             now: Date, originDeviceId: String) -> JournalEntry {
        JournalEntry(
            id: id, behaviorId: behaviorId, customLabel: customLabel, valueKind: valueKind,
            value: value, unit: unit, occurredAt: occurredAt, tzId: tzId, note: note,
            provenance: Provenance(sourceId: sourceId, deviceId: deviceId, ingestionPath: .manual,
                                   measuredAt: occurredAt, measuredTimezone: tzId,
                                   recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: originDeviceId)
    }

    /// A tag the user is entering for an earlier moment — the yesterday-recall path.
    ///
    /// Identical to `entry` except that the caller names the past instant explicitly, which is the
    /// point: the timestamp the correlation engine buckets on is the one the user says the
    /// behavior happened at (`occurredAt`), while `recordedAt`/`ingestedAt` stay honest about when
    /// it was typed. Backdating is therefore recorded, never disguised — the resulting entry
    /// reports `isRecalled == true` and exports with both instants intact.
    ///
    /// A separate entry point rather than a flag on `entry` so the two intents read differently at
    /// the call site; the stored row differs only in its timestamps, exactly as it should.
    public static func recalledEntry(id: String, behaviorId: String? = nil, customLabel: String? = nil,
                                     valueKind: BehaviorValueKind, value: Double? = nil, unit: String? = nil,
                                     occurredAt: Date, tzId: String, note: String? = nil,
                                     sourceId: String, deviceId: String? = nil,
                                     now: Date, originDeviceId: String) -> JournalEntry {
        entry(id: id, behaviorId: behaviorId, customLabel: customLabel, valueKind: valueKind,
              value: value, unit: unit, occurredAt: occurredAt, tzId: tzId, note: note,
              sourceId: sourceId, deviceId: deviceId, now: now, originDeviceId: originDeviceId)
    }

    /// The same wall-clock time as `reference` on the previous local day, in `tzId` — the instant
    /// the "yesterday" chip logs at when the user doesn't pick a time.
    ///
    /// Calendar arithmetic (`byAdding: .day, value: -1`), never `-86_400` seconds: across a DST
    /// boundary a fixed 24-hour subtraction lands an hour off and silently files the entry under
    /// the wrong local day, which is exactly the bucket the correlation arms are built from.
    public static func yesterday(_ reference: Date, tzId: String,
                                 calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
        return cal.date(byAdding: .day, value: -1, to: reference) ?? reference.addingTimeInterval(-86_400)
    }
}
