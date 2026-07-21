import Foundation

// MARK: - Which day is being logged

/// The two days the journal offers. Deliberately two and not a date picker: plan §11 names chore
/// fatigue as this epic's main risk, and "today" plus "the day I forgot" is the whole realistic
/// range of a ten-second flow. Anything older is a correction, not journaling, and belongs on the
/// entry itself (`JournalRepository.deleteEntry` + a fresh row) rather than in the daily surface.
enum JournalDayChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case today, yesterday

    var id: String { rawValue }

    var displayName: LocalizedString {
        switch self {
        case .today: return JournalStrings.today
        case .yesterday: return JournalStrings.yesterday
        }
    }

    /// The instant an entry logged on this screen carries as `occurredAt`.
    ///
    /// Yesterday goes through `JournalLog.yesterday`, which does calendar arithmetic rather than
    /// subtracting 86 400 seconds — across a DST boundary the fixed-seconds form lands an hour off
    /// and files the entry under the wrong local day, and the local day IS the bucket every
    /// correlation arm is built from.
    func occurredAt(now: Date, tzId: String) -> Date {
        switch self {
        case .today: return now
        case .yesterday: return JournalLog.yesterday(now, tzId: tzId)
        }
    }

    /// `true` for the recall path, which routes through `JournalLog.recalledEntry` so the stored row
    /// reports `isRecalled` instead of pretending it was typed as it happened.
    var isRecall: Bool { self == .yesterday }
}

// MARK: - One chip

/// A behaviour chip's state for the day on screen: the dictionary row, and the live entry for it if
/// the user has tagged it.
///
/// `entry` is the ONLY source of "is this on" — there is no separate selected-set the view keeps in
/// parallel, so the chips cannot drift from what is actually stored. A toggle writes, reloads, and
/// the chips re-derive.
struct JournalChip: Identifiable, Hashable {
    let behavior: BehaviorDefinition
    let entry: JournalEntry?

    var id: String { behavior.id }
    var isOn: Bool { entry != nil }

    /// The amount the user recorded, when they recorded one. Nil for a plain tap — see
    /// `JournalViewModel.toggle` for why a casual tap stores no number at all.
    var amount: Double? {
        guard let entry, entry.valueKind != .boolean else { return nil }
        return entry.value
    }

    /// Whether power depth may offer a count/duration for this behaviour. Read from the dictionary
    /// (the shape the contract says this behaviour has), never from the stored row.
    var offersAmount: Bool { behavior.valueKind != .boolean }

    /// The step a `+`/`−` tap moves by: minutes go in fives (a nap is not timed to the minute),
    /// counts in ones.
    var amountStep: Double { behavior.valueKind == .quantity ? 5 : 1 }

    /// The unit label beside a power-depth amount, or nil for a count (which counts the behaviour
    /// itself and so has no physical unit — 2 coffees is 2, not 2 of anything convertible).
    var amountUnit: LocalizedString? {
        guard behavior.valueKind == .quantity else { return nil }
        return behavior.unit == "min" ? JournalStrings.minutes : nil
    }
}

/// One category's chips, in dictionary order.
struct JournalChipGroup: Identifiable, Hashable {
    let category: String
    let chips: [JournalChip]

    var id: String { category }
    var heading: LocalizedString { JournalCategory.heading(category) }
}

// MARK: - Building the day

/// The pure day-model builder. Everything the journal screen renders comes from here, so the rules
/// that matter — one chip per dictionary behaviour, newest row wins, custom tags listed separately —
/// are unit-testable without a database or a view.
enum JournalDayBuilder {

    /// Chips for every dictionary behaviour, paired with the day's live entry where one exists.
    ///
    /// **Every behaviour always gets a chip**, tagged or not: the vocabulary is the surface, and a
    /// disappearing chip would make the screen's shape depend on what was logged. Duplicate rows for
    /// one behaviour on one day (possible from a sync peer or an import, never from this screen)
    /// resolve to the FIRST — `JournalRepository` returns newest-first, so the newest assertion wins
    /// and the older one stays in the store, readable and exportable.
    static func chips(dictionary: [BehaviorDefinition], entries: [JournalEntry]) -> [JournalChip] {
        var byBehavior: [String: JournalEntry] = [:]
        for entry in entries {
            guard let behaviorId = entry.behaviorId, entry.deletedAt == nil else { continue }
            if byBehavior[behaviorId] == nil { byBehavior[behaviorId] = entry }
        }
        return dictionary.map { JournalChip(behavior: $0, entry: byBehavior[$0.id]) }
    }

    /// Group chips by category, preserving the dictionary's own order for both the groups and the
    /// chips inside them — the file is authored in a deliberate order (stimulants first, the day
    /// itself last) and re-sorting it here would silently override that editorial decision.
    static func groups(_ chips: [JournalChip]) -> [JournalChipGroup] {
        var order: [String] = []
        var buckets: [String: [JournalChip]] = [:]
        for chip in chips {
            let category = chip.behavior.category
            if buckets[category] == nil { order.append(category) }
            buckets[category, default: []].append(chip)
        }
        return order.map { JournalChipGroup(category: $0, chips: buckets[$0] ?? []) }
    }

    /// The day's free-text tags, newest first. Kept apart from the chips because they behave
    /// differently in one visible way — they are not correlated (see `JournalStrings.ownTagsNote`) —
    /// and mixing them into the chip grid would imply otherwise.
    static func customEntries(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.filter { $0.deletedAt == nil && $0.behaviorId == nil && !($0.customLabel ?? "").isEmpty }
    }

    /// How many things the user tagged on this day — chips plus free-text tags. Shown as a plain
    /// count with no target and no streak: the journal records, it does not score the journaling.
    static func taggedCount(chips: [JournalChip], customEntries: [JournalEntry]) -> Int {
        chips.filter(\.isOn).count + customEntries.count
    }
}

// MARK: - Context statuses

/// The declared-interval list, split the way the manager screen renders it.
struct ContextStatusList: Hashable {
    /// Open-ended or still running as of `now`, most recently started first.
    var active: [ContextStatus]
    /// Closed intervals, most recently started first.
    var past: [ContextStatus]

    var isEmpty: Bool { active.isEmpty && past.isEmpty }

    /// Splits live statuses into the two sections. `nil` `endAt` is the NORMAL case (a status is
    /// declared when it starts and closed later), so it must read as active rather than malformed —
    /// the same rule `ContextStatus.isActive(at:)` encodes.
    static func from(_ statuses: [ContextStatus], now: Date) -> ContextStatusList {
        let live = statuses.filter { $0.deletedAt == nil }.sorted { $0.startAt > $1.startAt }
        return ContextStatusList(
            active: live.filter { $0.isActive(at: now) },
            past: live.filter { !$0.isActive(at: now) })
    }
}
