import Foundation
import Observation

/// The daily journal's state and writes (EPIC-29).
///
/// Reads and writes go through `env.journal` — the repository that holds the SENSITIVE connection
/// and nothing else (I7). Nothing here opens a store of its own, so a behaviour tag has no code path
/// to `badan.db` even by accident.
///
/// Every mutation follows one shape: **write, then reload the day.** The chips are derived from
/// stored rows rather than from a selection set the view keeps alongside them, so a failed write
/// leaves the chip visibly unchanged instead of showing a tag that was never saved.
///
/// Loads are synchronous on the main actor, unlike the score surfaces' detached fetches. That is a
/// deliberate difference: a day of journal rows is a single indexed query returning tens of rows,
/// and a spinner between tapping "Yesterday" and seeing the chips would cost more than the query
/// does — this screen's entire premise is a ten-second flow (plan §16: "chore fatigue → 10-second
/// flow").
@Observable
@MainActor
final class JournalViewModel {
    /// Which day the chips describe. Changing it re-keys the screen's `.task(id:)` and reloads.
    var day: JournalDayChoice = .today

    private(set) var chips: [JournalChip] = []
    private(set) var groups: [JournalChipGroup] = []
    private(set) var customEntries: [JournalEntry] = []
    /// True when the day's read threw. Rendered as one calm line, never as a blank screen that
    /// looks like "you logged nothing".
    private(set) var loadFailed = false
    /// True when the most recent write threw. Cleared by the next successful one.
    private(set) var saveFailed = false

    private let dictionary: BehaviorDictionary

    init(dictionary: BehaviorDictionary = .shared) {
        self.dictionary = dictionary
    }

    var taggedCount: Int { JournalDayBuilder.taggedCount(chips: chips, customEntries: customEntries) }

    private var tz: String { TimeZone.current.identifier }

    // MARK: - Load

    /// Read the selected day's live entries and rebuild the chips.
    ///
    /// The window query is widened to the whole local day and then filtered on each row's own
    /// `dayKey()`. Both steps are needed: the query is what an index can serve, and the filter is
    /// what makes the day boundary agree with the correlation engine's — an entry carries the
    /// timezone it was recorded in, so a row logged in Riyadh and read in London belongs to the
    /// Riyadh day, exactly as `CorrelationEngine` buckets it.
    func load(_ env: AppEnvironment) {
        let reference = day.occurredAt(now: env.now(), tzId: tz)
        let dayStart = DayAttribution.startOfDay(reference, tz: tz)
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
        let dayKey = DayAttribution.localDayKey(dayStart, tz: tz)
        do {
            let rows = try env.journal.entries(from: dayStart, to: dayEnd).filter { $0.dayKey() == dayKey }
            chips = JournalDayBuilder.chips(dictionary: dictionary.all, entries: rows)
            groups = JournalDayBuilder.groups(chips)
            customEntries = JournalDayBuilder.customEntries(rows)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    // MARK: - Chip mutations

    /// Tap a chip: tag the behaviour, or take the tag back.
    ///
    /// **A plain tap stores `.boolean`, even for a behaviour the dictionary calls `count` or
    /// `quantity`.** Storing the dictionary's shape would mean inventing the number — a tapped "Nap"
    /// chip does not tell BADAN the nap was twenty minutes, and writing twenty would put a
    /// fabricated value into the user's own exportable record. `.boolean` is the honest shape for a
    /// tap: the row's existence IS the fact, `isPresent` is true, and the correlation engine (which
    /// reads only `isPresent`) treats it identically to a counted one. Power depth is where a real
    /// number gets attached — see `setAmount`.
    ///
    /// Untagging is a tombstone, not a hard delete: what the user first said stays recoverable, and
    /// a synced peer learns the tag went away rather than inferring it from absence.
    func toggle(_ chip: JournalChip, env: AppEnvironment) {
        if let entry = chip.entry {
            remove(entryId: entry.id, name: chip.behavior.displayName, env: env)
        } else {
            insert(behaviorId: chip.behavior.id, customLabel: nil, valueKind: .boolean,
                   value: nil, unit: nil, name: chip.behavior.displayName, env: env)
        }
    }

    /// Set (or clear) the amount on a count/quantity chip — the power-depth affordance.
    ///
    /// A correction is a new row plus a tombstone on the old one, never an in-place edit, so "the
    /// user first said two, then said three" stays inspectable. An amount at or below zero clears
    /// the tag entirely rather than storing a zero: an explicit zero is a real assertion in this
    /// model ("no coffee today", which lands in the *without* arm), and a stepper bottoming out is
    /// not the same statement as making it — so the honest result of stepping to nothing is no tag.
    func setAmount(_ chip: JournalChip, to amount: Double?, env: AppEnvironment) {
        guard chip.offersAmount else { return }
        let now = env.now()
        guard let amount, amount > 0 else {
            if let entry = chip.entry { remove(entryId: entry.id, name: chip.behavior.displayName, env: env) }
            return
        }
        do {
            try env.journal.transaction {
                if let existing = chip.entry {
                    try env.journal.deleteEntry(id: existing.id, at: now)
                }
                try env.journal.insertEntry(makeEntry(
                    behaviorId: chip.behavior.id, customLabel: nil,
                    valueKind: chip.behavior.valueKind, value: amount,
                    unit: chip.behavior.valueKind == .quantity ? chip.behavior.unit : nil,
                    env: env, now: now))
            }
        } catch {
            saveFailed = true
            Announce.failure(env.s(JournalStrings.saveFailed))
            return
        }
        saveFailed = false
        env.bumpDataGeneration()
        load(env)
    }

    // MARK: - Free-text tags (power depth)

    /// Log a behaviour the dictionary doesn't name. Stored as `customLabel` with no `behaviorId` —
    /// the two are mutually exclusive on the entity, and keeping the user's own words out of the
    /// dictionary key space is what stops a free-text tag from ever being mistaken for a curated one.
    @discardableResult
    func addCustomTag(_ raw: String, env: AppEnvironment) -> Bool {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        return insert(behaviorId: nil, customLabel: label, valueKind: .boolean, value: nil, unit: nil,
                      name: LocalizedString(en: label, ar: label), env: env)
    }

    func removeCustomTag(_ entry: JournalEntry, env: AppEnvironment) {
        let label = entry.customLabel ?? ""
        remove(entryId: entry.id, name: LocalizedString(en: label, ar: label), env: env)
    }

    // MARK: - Write helpers

    @discardableResult
    private func insert(behaviorId: String?, customLabel: String?, valueKind: BehaviorValueKind,
                        value: Double?, unit: String?, name: LocalizedString,
                        env: AppEnvironment) -> Bool {
        do {
            try env.journal.insertEntry(makeEntry(behaviorId: behaviorId, customLabel: customLabel,
                                                  valueKind: valueKind, value: value, unit: unit,
                                                  env: env, now: env.now()))
        } catch {
            saveFailed = true
            Announce.failure(env.s(JournalStrings.saveFailed))
            return false
        }
        saveFailed = false
        env.bumpDataGeneration()
        load(env)
        // (A3) A chip filling in is a purely visual confirmation; without this a VoiceOver user
        // taps and hears nothing, which is indistinguishable from a no-op.
        Announce.status(env.s(JournalStrings.addedAnnouncement.filling(["name": env.s(name)])))
        return true
    }

    private func remove(entryId: String, name: LocalizedString, env: AppEnvironment) {
        do {
            try env.journal.deleteEntry(id: entryId, at: env.now())
        } catch {
            saveFailed = true
            Announce.failure(env.s(JournalStrings.saveFailed))
            return
        }
        saveFailed = false
        env.bumpDataGeneration()
        load(env)
        Announce.status(env.s(JournalStrings.removedAnnouncement.filling(["name": env.s(name)])))
    }

    /// Build the row. The recall path goes through `JournalLog.recalledEntry` so the two intents
    /// read differently at the call site; the stored row differs only in its timestamps, which is
    /// exactly what makes backdating recorded rather than disguised.
    private func makeEntry(behaviorId: String?, customLabel: String?, valueKind: BehaviorValueKind,
                           value: Double?, unit: String?, env: AppEnvironment, now: Date) -> JournalEntry {
        let occurredAt = day.occurredAt(now: now, tzId: tz)
        if day.isRecall {
            return JournalLog.recalledEntry(
                id: ULID.newID(), behaviorId: behaviorId, customLabel: customLabel,
                valueKind: valueKind, value: value, unit: unit,
                occurredAt: occurredAt, tzId: tz, note: nil,
                sourceId: env.deviceId, deviceId: env.deviceId,
                now: now, originDeviceId: env.deviceId)
        }
        return JournalLog.entry(
            id: ULID.newID(), behaviorId: behaviorId, customLabel: customLabel,
            valueKind: valueKind, value: value, unit: unit,
            occurredAt: occurredAt, tzId: tz, note: nil,
            sourceId: env.deviceId, deviceId: env.deviceId,
            now: now, originDeviceId: env.deviceId)
    }
}
