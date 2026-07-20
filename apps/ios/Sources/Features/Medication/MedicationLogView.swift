import SwiftUI

// MARK: - File-local strings (bilingual; wellness-safe; not in the shared catalog)

private enum MedStrings {
    static let dueToday = LocalizedString(en: "Due today", ar: "مستحق اليوم")
    static let takeAction = LocalizedString(en: "Take", ar: "تناول")
    static let yourMedications = LocalizedString(en: "Your medications", ar: "أدويتك")
    static let last7Days = LocalizedString(en: "Last 7 days", ar: "آخر ٧ أيام")
    static let asNeeded = LocalizedString(en: "As needed", ar: "عند الحاجة")
    static let daily = LocalizedString(en: "Daily", ar: "يومياً")
    static let weekly = LocalizedString(en: "Weekly", ar: "أسبوعياً")
    static let change = LocalizedString(en: "Change", ar: "تغيير")
    static let skipPrompt = LocalizedString(en: "No problem — pick a reason if you'd like.",
                                            ar: "لا بأس — اختر سبباً إن أردت.")
    static let emptyTitle = LocalizedString(en: "No medications yet", ar: "لا أدوية بعد")
    static let emptyBody = LocalizedString(en: "Add one to keep a calm record here. No pressure — skips count too.",
                                           ar: "أضِف دواءً لتحتفظ بسجلّ هادئ هنا. دون ضغط — التخطّي يُحسب أيضاً.")
    static let addTime = LocalizedString(en: "Add a time", ar: "إضافة وقت")
    static let scheduleAsNeeded = LocalizedString(en: "As needed", ar: "عند الحاجة")
    static let scheduleDaily = LocalizedString(en: "Daily", ar: "يومياً")
    static let timesLabel = LocalizedString(en: "Times", ar: "الأوقات")
    static let namePlaceholder = LocalizedString(en: "e.g. Vitamin D", ar: "مثال: فيتامين د")
    static let strengthPlaceholder = LocalizedString(en: "e.g. 1000 IU", ar: "مثال: ١٠٠٠ وحدة")
    static let noneScheduled = LocalizedString(en: "Nothing scheduled for today", ar: "لا شيء مجدول لليوم")
    static let addedManually = LocalizedString(en: "Recorded by you", ar: "مسجَّل بواسطتك")

    // Added while executing the medication audit bundle:
    static let upcoming = LocalizedString(en: "Upcoming", ar: "قادم")
    static let saveFailed = LocalizedString(en: "Couldn't save — try again", ar: "تعذّر الحفظ — حاول مرة أخرى")
    static let someNotSaved = LocalizedString(en: "Some updates couldn't be saved — try again",
                                              ar: "تعذّر حفظ بعض التحديثات — حاول مرة أخرى")
    static let addTimeHint = LocalizedString(en: "Add at least one time to save", ar: "أضِف وقتاً واحداً على الأقل للحفظ")
    static let timeAlreadyAdded = LocalizedString(en: "Already added", ar: "أُضيف بالفعل")
    static let searchMedications = LocalizedString(en: "Search medications", ar: "البحث في الأدوية")
    static let viewHistory = LocalizedString(en: "View history", ar: "عرض السجلّ")
    static let logNow = LocalizedString(en: "Log now", ar: "تسجيل الآن")
    static let last30Days = LocalizedString(en: "Last 30 days", ar: "آخر ٣٠ يوماً")
    static let last90Days = LocalizedString(en: "Last 90 days", ar: "آخر ٩٠ يوماً")
    static let takenPercentLabel = LocalizedString(en: "Taken", ar: "نسبة التناول")
    static let longestStreakLabel = LocalizedString(en: "Longest streak", ar: "أطول تتابع")
    static let streakDaysUnit = LocalizedString(en: "days", ar: "أيام")
    static let totalRecordedLabel = LocalizedString(en: "Total recorded", ar: "إجمالي المسجَّل")
    static let noHistoryYet = LocalizedString(en: "No history in this range yet", ar: "لا سجلّ بعد ضمن هذا النطاق")
}

// MARK: - View model

@Observable
@MainActor
final class MedicationLogViewModel {

    enum SlotStatus { case taken, skipped, pending }

    /// One expanded scheduled dose for today.
    struct DueSlot: Identifiable {
        let id: String
        let regimen: MedicationRegimen
        let time: String          // canonical "HH:mm"
        let displayTime: String   // localized clock string
        let scheduledFor: Date
        let minutesOfDay: Int
        var status: SlotStatus
        var skipReason: SkipReason?
        var isOverdue: Bool
    }

    /// A single dot in a regimen's 7-day adherence strip.
    enum DotKind { case taken, skipped, pending, none, notStarted }

    struct MedData {
        var regimens: [MedicationRegimen]
        var dueSlots: [DueSlot]
        var strips: [String: [DotKind]]     // regimenId -> 7 dots (oldest first)
        var weekdayLetters: [String]        // 7 narrow weekday letters (oldest first)
        var todayIndex: Int                 // index of today within the strip (== 6)
        var hasPending: Bool
        var allResolved: Bool               // there were slots and none pending
    }

    var state: LoadState<MedData> = .loading

    /// Slot ids ("regimenId|HH:mm") whose most recent write to storage failed. Cleared on the
    /// next successful write for that slot. Not reset by `load()` so a failure stays visible
    /// even though the slot's status silently reverts to whatever's actually in the DB.
    private(set) var errorSlotIds: Set<String> = []

    private var tz: String { TimeZone.current.identifier }

    // Cached once per view-model lifetime instead of allocated on every `load()` call (every
    // load runs after every single take/skip tap).
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private let letterFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()

    /// Beyond this many minutes, a same-day adherence event is treated as unmatched to its
    /// nearest scheduled slot rather than force-assigned (avoids misattributing a late dose to
    /// the wrong closely-spaced slot).
    private static let maxAssignDistanceMinutes = 360

    // MARK: Load

    func load(_ env: AppEnvironment) {
        do {
            let now = env.now()
            let cal = DayAttribution.calendar(tz: tz)
            let startOfToday = cal.startOfDay(for: now)
            let weekStart = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

            let regimens = try env.logging.regimens(activeOnly: true)
            let todaysAdherence = try env.logging.adherence(from: startOfToday, to: now)
            let weekAdherence = try env.logging.adherence(from: weekStart, to: now)

            timeFormatter.locale = Locale(identifier: env.language.localeIdentifier)

            // Pre-grouped once so both today's slot assignment and any future consumer share
            // one source of truth for "this regimen's events today" instead of each re-scanning
            // the full list with an ad-hoc filter.
            let todaysByRegimen = Dictionary(grouping: todaysAdherence, by: \.regimenId)

            // --- Today's due slots (expanded per active regimen) ---
            var slots: [DueSlot] = []
            let isoToday = Self.isoWeekday(now, cal: cal)
            for regimen in regimens {
                let times = regimen.schedule.dueTimes(onWeekday: isoToday).sorted()
                guard !times.isEmpty else { continue }

                // Descriptors for each slot, and this regimen's events for today (latest first).
                let descs = times.map { t -> (time: String, date: Date, mins: Int) in
                    (t, Self.slotDate(time: t, on: startOfToday, cal: cal), Self.minutesOfDay(t))
                }
                let events = (todaysByRegimen[regimen.id] ?? [])
                    .sorted { $0.occurredAt > $1.occurredAt }

                // Assign each event to its nearest still-unclaimed slot (latest events claim
                // first), but never across a gap wider than `maxAssignDistanceMinutes`.
                var assigned: [Int: AdherenceEvent] = [:]
                for e in events {
                    let emin = Self.minutesOfDay(of: e.scheduledFor ?? e.occurredAt, cal: cal)
                    var best: Int?
                    var bestDist = Int.max
                    for (i, s) in descs.enumerated() where assigned[i] == nil {
                        let dist = abs(s.mins - emin)
                        if dist < bestDist { bestDist = dist; best = i }
                    }
                    if let b = best, bestDist <= Self.maxAssignDistanceMinutes {
                        assigned[b] = e
                    }
                    if assigned.count == descs.count { break }
                }

                for (i, s) in descs.enumerated() {
                    let ev = assigned[i]
                    let status: SlotStatus
                    switch ev?.kind {
                    case .some(.taken), .some(.late): status = .taken
                    case .some(.skipped): status = .skipped
                    default: status = .pending
                    }
                    slots.append(DueSlot(
                        id: "\(regimen.id)|\(s.time)",
                        regimen: regimen,
                        time: s.time,
                        displayTime: timeFormatter.string(from: s.date),
                        scheduledFor: s.date,
                        minutesOfDay: s.mins,
                        status: status,
                        skipReason: ev?.skipReason,
                        isOverdue: status == .pending && s.date < now
                    ))
                }
            }
            slots.sort { $0.minutesOfDay < $1.minutesOfDay }

            // --- 7-day adherence strip per regimen ---
            var counts: [String: [String: (taken: Int, skipped: Int)]] = [:]
            for e in weekAdherence {
                let key = DayAttribution.localDayKey(e.scheduledFor ?? e.occurredAt, tz: tz)
                var byDay = counts[e.regimenId] ?? [:]
                var cell = byDay[key] ?? (0, 0)
                switch e.kind {
                case .taken, .late: cell.taken += 1
                case .skipped: cell.skipped += 1
                }
                byDay[key] = cell
                counts[e.regimenId] = byDay
            }

            let days: [Date] = (0..<7).map {
                cal.date(byAdding: .day, value: -(6 - $0), to: startOfToday) ?? startOfToday
            }
            letterFormatter.locale = Locale(identifier: env.language.localeIdentifier)
            let weekdayLetters = days.map { letterFormatter.string(from: $0) }

            var strips: [String: [DotKind]] = [:]
            for regimen in regimens {
                let regimenStartDay = DayAttribution.startOfDay(regimen.startedAt, tz: tz)
                strips[regimen.id] = days.map { day in
                    // Before the regimen existed, a blank dot reads as "not started" rather than
                    // a false "missed/no dose" signal.
                    guard day >= regimenStartDay else { return .notStarted }
                    let key = DayAttribution.localDayKey(day, tz: tz)
                    let scheduled = regimen.schedule.dueTimes(onWeekday: Self.isoWeekday(day, cal: cal)).count
                    let cell = counts[regimen.id]?[key] ?? (0, 0)
                    if cell.taken > 0 { return .taken }
                    if cell.skipped > 0 { return .skipped }
                    if scheduled > 0 { return .pending }
                    return .none
                }
            }

            let hasPending = slots.contains { $0.status == .pending }
            let data = MedData(
                regimens: regimens,
                dueSlots: slots,
                strips: strips,
                weekdayLetters: weekdayLetters,
                todayIndex: 6,
                hasPending: hasPending,
                allResolved: !slots.isEmpty && !hasPending
            )
            state = .loaded(data)
        } catch {
            // (C2) The raw error goes to the debug log, not the UI (BUG-14) — this screen was
            // missed by that sweep and still put a Swift error description on screen: English-only
            // in an Arabic-first app, robotic, and leaking internals to whoever is holding the
            // phone. Same two lines every other data-backed screen already uses.
            LoadErrorLog.log(error, screen: "Medication")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Mutations (non-punitive; a slot always reflects the latest choice)

    func take(_ slot: DueSlot, env: AppEnvironment) {
        record(regimenId: slot.regimen.id, scheduledFor: slot.scheduledFor, time: slot.time,
               kind: .taken, reason: nil, env: env)
    }

    func skip(_ slot: DueSlot, reason: SkipReason, env: AppEnvironment) {
        record(regimenId: slot.regimen.id, scheduledFor: slot.scheduledFor, time: slot.time,
               kind: .skipped, reason: reason, env: env)
    }

    func takeAll(env: AppEnvironment) {
        guard case .loaded(let data) = state else { return }
        for slot in data.dueSlots where slot.status == .pending {
            record(regimenId: slot.regimen.id, scheduledFor: slot.scheduledFor, time: slot.time,
                   kind: .taken, reason: nil, env: env, reload: false)
        }
        load(env)
    }

    /// Records a dose right now for a regimen with no fixed schedule slot (as-needed
    /// medications never appear in `dueSlots`, so this is their only quick-log path).
    func logNow(_ regimen: MedicationRegimen, env: AppEnvironment) {
        let now = env.now()
        record(regimenId: regimen.id, scheduledFor: now, time: Self.canonicalTime(now, tz: tz),
               kind: .taken, reason: nil, env: env, isAsNeeded: true)
    }

    private func record(regimenId: String, scheduledFor: Date, time: String,
                        kind: AdherenceKind, reason: SkipReason?, env: AppEnvironment, reload: Bool = true,
                        isAsNeeded: Bool = false) {
        let now = env.now()
        // Scheduled slots keep a deterministic id per (regimen, day, slot) so changing your mind
        // (take -> skip -> take) replaces the same row instead of accumulating duplicates. As-
        // needed doses have no fixed slot to replace-on-correction — two doses logged in the same
        // minute are two genuinely distinct events, so each gets its own ULID identity instead of
        // colliding on the same deterministic id and silently `INSERT OR REPLACE`-ing one another
        // away (EDGE-11).
        let dayKey = DayAttribution.localDayKey(scheduledFor, tz: tz)
        let slotId = "\(regimenId)|\(time)"
        let eventId = isAsNeeded ? ULID.newID() : "adh-\(regimenId)-\(dayKey)-\(time)"
        let event = AdherenceEvent(
            id: eventId,
            regimenId: regimenId,
            kind: kind,
            scheduledFor: scheduledFor,
            occurredAt: now,
            tzId: tz,
            skipReason: reason,
            updatedAt: now,
            originDeviceId: env.deviceId
        )
        do {
            try env.logging.insertAdherence(event)
            errorSlotIds.remove(slotId)
            // (F5) Home's medications module counts what's still due — a take/skip here changes
            // that count, so it has to invalidate beyond this screen.
            env.bumpDataGeneration()
        } catch {
            // Surfaced via `errorSlotIds` instead of swallowed: `load(env)` below will re-derive
            // this slot's status from the DB (i.e. it reverts to pending), so without this the
            // tap would look like it silently did nothing.
            errorSlotIds.insert(slotId)
        }
        if reload { load(env) }
    }

    @discardableResult
    func addRegimen(name: String, strength: String?, schedule: MedicationSchedule, env: AppEnvironment) -> Bool {
        let now = env.now()
        let regimen = MedicationRegimen(
            id: ULID.newID(),
            name: name,
            strength: strength,
            schedule: schedule,
            startedAt: now,
            updatedAt: now,
            originDeviceId: env.deviceId
        )
        do {
            try env.logging.upsertRegimen(regimen)
            // (F5) A new regimen adds due slots to Home's medications module.
            env.bumpDataGeneration()
            load(env)
            // NEW-02/UX-02: a new regimen changes what's due, so refresh scheduled reminders.
            // No-op unless the pref is on and notifications are authorized; never prompts.
            // (Regimen edit/delete have no UI path in this view today; when one is added, it
            // should call the same hook.)
            Task { await env.refreshMedicationReminders() }
            return true
        } catch {
            return false
        }
    }

    // MARK: Calendar helpers

    /// ISO weekday (1 = Monday ... 7 = Sunday) from a `Calendar`'s 1 = Sunday component.
    static func isoWeekday(_ date: Date, cal: Calendar) -> Int {
        let w = cal.component(.weekday, from: date)
        return ((w + 5) % 7) + 1
    }

    static func minutesOfDay(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let h = parts.first ?? 0
        let m = parts.count > 1 ? parts[1] : 0
        return h * 60 + m
    }

    static func minutesOfDay(of date: Date, cal: Calendar) -> Int {
        cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    static func slotDate(time: String, on day: Date, cal: Calendar) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let h = parts.first ?? 0
        let m = parts.count > 1 ? parts[1] : 0
        return cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
    }

    /// A stable "HH:mm" for `date` in `tz`, used to key an unscheduled (as-needed) dose.
    private static func canonicalTime(_ date: Date, tz: String) -> String {
        let cal = DayAttribution.calendar(tz: tz)
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return String(format: "%02d:%02d", h, m)
    }
}

// MARK: - Screen

/// The non-punitive medication hub. Today's scheduled doses expand into calm Take / Skip
/// rows; overdue reads as a neutral "Still due" (never red); skips are a first-class,
/// outline-styled choice with an optional reason. Below: your regimens with a 7-day dot
/// strip. A pushed screen (a parent NavigationStack is provided by the app shell).
struct MedicationLogView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = MedicationLogViewModel()
    @State private var showingAdd = false
    @State private var searchQuery = ""
    /// Slot currently showing its skip-reason chips.
    @State private var skippingSlotId: String?
    /// Resolved slot the user re-opened to change their choice.
    @State private var editingSlotId: String?
    /// Regimen whose full adherence history is being viewed.
    @State private var historyRegimen: MedicationRegimen?

    var body: some View {
        StatefulContainer(vm.state) { data in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space6) {
                    if data.regimens.isEmpty {
                        emptyState
                    } else {
                        if !data.dueSlots.isEmpty { dueSection(data) }
                        regimensSection(data)
                        boundaryFooter
                    }
                }
                .padding(BadanSpace.space4)
            }
            .refreshable { vm.load(env) }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logMedication))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: env.s(MedStrings.searchMedications))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label(env.s(Loc.addMedication), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddMedicationSheet { name, strength, schedule in
                vm.addRegimen(name: name, strength: strength, schedule: schedule, env: env)
            }
        }
        .sheet(item: $historyRegimen) { regimen in
            MedicationHistorySheet(regimen: regimen)
        }
        .task { vm.load(env) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { vm.load(env) }
        }
    }

    // MARK: Due section

    private func dueSection(_ data: MedicationLogViewModel.MedData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(MedStrings.dueToday)) {
                if data.hasPending {
                    Button {
                        withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                            skippingSlotId = nil
                            editingSlotId = nil
                            vm.takeAll(env: env)
                        }
                    } label: {
                        Text(env.s(Loc.takeAll))
                            .font(BadanFont.bodyCompact.weight(.semibold))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !vm.errorSlotIds.isEmpty {
                HStack(spacing: BadanSpace.space1) {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(env.s(MedStrings.someNotSaved))
                        .font(BadanFont.caption)
                }
                .foregroundStyle(BadanColor.outOfBand)
            }

            if data.allResolved {
                allDoneBanner
            }

            VStack(spacing: BadanSpace.space3) {
                ForEach(data.dueSlots) { slot in
                    dueSlotCard(slot)
                }
            }
        }
    }

    private var allDoneBanner: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(BadanColor.inBand)
                    .accessibilityHidden(true)
                Text(env.s(Loc.allDone))
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func dueSlotCard(_ slot: MedicationLogViewModel.DueSlot) -> some View {
        let showActions = slot.status == .pending || editingSlotId == slot.id
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(slot.regimen.name)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        HStack(spacing: BadanSpace.space2) {
                            if let strength = slot.regimen.strength, !strength.isEmpty {
                                Text(strength)
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                            Label(slot.displayTime, systemImage: "clock")
                                .labelStyle(.titleAndIcon)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                    Spacer(minLength: BadanSpace.space2)
                    statusTrailing(for: slot)
                }

                if showActions {
                    if skippingSlotId == slot.id {
                        skipReasonPicker(for: slot)
                    } else {
                        actionRow(for: slot)
                    }
                }

                if vm.errorSlotIds.contains(slot.id) {
                    HStack(spacing: BadanSpace.space1) {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(env.s(MedStrings.saveFailed))
                            .font(BadanFont.caption)
                    }
                    .foregroundStyle(BadanColor.outOfBand)
                }
            }
        }
    }

    /// The right-side status marker: a completion chip, a calm skip outline, or a neutral
    /// "still due"/"upcoming" — never red, never alarming. Taken/skipped chips are tappable so
    /// a mis-tap can always be corrected (reopens `actionRow`/`skipReasonPicker`).
    @ViewBuilder
    private func statusTrailing(for slot: MedicationLogViewModel.DueSlot) -> some View {
        switch slot.status {
        case .taken:
            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) { editingSlotId = slot.id }
            } label: {
                StatusChip(.inBand, label: env.s(Loc.taken), language: env.language)
            }
            .buttonStyle(.plain)
        case .skipped:
            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) { editingSlotId = slot.id }
            } label: {
                skippedPill(reason: slot.skipReason)
            }
            .buttonStyle(.plain)
        case .pending:
            if slot.isOverdue {
                PillLabel(env.s(Loc.stillDue), systemImage: "clock",
                          tint: BadanColor.textSecondary)
            } else {
                PillLabel("\(env.s(MedStrings.upcoming)) · \(slot.displayTime)", systemImage: "clock",
                          tint: BadanColor.textSecondary, filled: false)
            }
        }
    }

    private func skippedPill(reason: SkipReason?) -> some View {
        let text: String = {
            if let reason { return "\(env.s(Loc.skipped)) · \(env.s(reason.displayLabel))" }
            return env.s(Loc.skipped)
        }()
        return HStack(spacing: BadanSpace.space1) {
            Image(systemName: "arrow.uturn.forward")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .font(BadanFont.chip)
        }
        .foregroundStyle(BadanColor.textSecondary)
        .padding(.horizontal, BadanSpace.space2)
        .padding(.vertical, BadanSpace.space1)
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1)
        )
    }

    private func actionRow(for slot: MedicationLogViewModel.DueSlot) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                    editingSlotId = nil
                    vm.take(slot, env: env)
                }
            } label: {
                Text(env.s(MedStrings.takeAction))
                    .font(BadanFont.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .foregroundStyle(BadanColor.onPrimary)
                    .background(BadanColor.primary,
                                in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) { skippingSlotId = slot.id }
            } label: {
                Text(env.s(Loc.skip_))
                    .font(BadanFont.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .foregroundStyle(BadanColor.textSecondary)
                    .background(BadanColor.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                            .strokeBorder(BadanColor.separator, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func skipReasonPicker(for slot: MedicationLogViewModel.DueSlot) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(MedStrings.skipPrompt))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: BadanSpace.space2)],
                      alignment: .leading, spacing: BadanSpace.space2) {
                ForEach(SkipReason.allCases, id: \.self) { reason in
                    Button {
                        withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                            vm.skip(slot, reason: reason, env: env)
                            skippingSlotId = nil
                            editingSlotId = nil
                        }
                    } label: {
                        Text(env.s(reason.displayLabel))
                            .font(BadanFont.chip)
                            .foregroundStyle(BadanColor.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                            .padding(.horizontal, BadanSpace.space2)
                            .background(BadanColor.surfaceElevated,
                                        in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                                    .strokeBorder(BadanColor.separator, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) { skippingSlotId = nil }
            } label: {
                Text(env.s(Loc.cancel))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                    .frame(minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Regimens section

    private func regimensSection(_ data: MedicationLogViewModel.MedData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(MedStrings.yourMedications))
            VStack(spacing: BadanSpace.space3) {
                ForEach(filteredRegimens(data)) { regimen in
                    regimenCard(regimen, data: data)
                }
            }
        }
    }

    /// Client-side filter over the already-loaded regimen list; a search field only meaningfully
    /// matters once someone has several medications, but filtering an empty/short query is a
    /// no-op so it's harmless to keep the search field always available.
    private func filteredRegimens(_ data: MedicationLogViewModel.MedData) -> [MedicationRegimen] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return data.regimens }
        return data.regimens.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func regimenCard(_ regimen: MedicationRegimen,
                            data: MedicationLogViewModel.MedData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "pills.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(BadanColor.primary)
                        .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                        .background(BadanColor.primary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(regimen.name)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        HStack(spacing: BadanSpace.space2) {
                            if let strength = regimen.strength, !strength.isEmpty {
                                Text(strength)
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                            Text(scheduleText(regimen.schedule))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                adherenceStrip(regimenId: regimen.id, data: data)

                HStack(spacing: BadanSpace.space4) {
                    Button {
                        historyRegimen = regimen
                    } label: {
                        Text(env.s(MedStrings.viewHistory))
                            .font(BadanFont.bodyCompact.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                    .buttonStyle(.plain)

                    if case .asNeeded = regimen.schedule {
                        Button {
                            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) { vm.logNow(regimen, env: env) }
                        } label: {
                            Text(env.s(MedStrings.logNow))
                                .font(BadanFont.bodyCompact.weight(.medium))
                                .foregroundStyle(BadanColor.primary)
                                .frame(minHeight: BadanSpace.touchMin)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }

                // Power altitude: name the technical schedule and where the record lives.
                if env.depth.showsPowerDetail {
                    HStack(spacing: BadanSpace.space1) {
                        Text(scheduleDetail(regimen.schedule))
                            .environment(\.layoutDirection, .leftToRight)
                        Text("· \(env.s(MedStrings.addedManually))")
                    }
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private func adherenceStrip(regimenId: String,
                               data: MedicationLogViewModel.MedData) -> some View {
        let dots = data.strips[regimenId] ?? Array(repeating: MedicationLogViewModel.DotKind.none, count: 7)
        return VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(env.s(MedStrings.last7Days))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            HStack(spacing: BadanSpace.space2) {
                ForEach(Array(dots.enumerated()), id: \.offset) { index, kind in
                    VStack(spacing: BadanSpace.space1) {
                        AdherenceDot(kind: kind)
                        if env.depth.showsPowerDetail, index < data.weekdayLetters.count {
                            Text(data.weekdayLetters[index])
                                .font(.system(size: 10, weight: index == data.todayIndex ? .bold : .regular))
                                .foregroundStyle(index == data.todayIndex
                                                 ? BadanColor.primary : BadanColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Empty & footer

    private var emptyState: some View {
        EmptyStateView(
            icon: "pills",
            title: env.s(MedStrings.emptyTitle),
            message: env.s(MedStrings.emptyBody),
            actionTitle: env.s(Loc.addMedication),
            action: { showingAdd = true }
        )
    }

    private var boundaryFooter: some View {
        Text(env.s(Loc.medsBoundary))
            .font(BadanFont.caption)
            .foregroundStyle(BadanColor.textSecondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BadanSpace.space2)
    }

    // MARK: Schedule text

    private func scheduleText(_ schedule: MedicationSchedule) -> String {
        switch schedule {
        case .asNeeded:
            return env.s(MedStrings.asNeeded)
        case .daily(let times):
            return "\(env.s(MedStrings.daily)) · \(times.sorted().joined(separator: ", "))"
        case .weekly(_, let times):
            return "\(env.s(MedStrings.weekly)) · \(times.sorted().joined(separator: ", "))"
        }
    }

    private func scheduleDetail(_ schedule: MedicationSchedule) -> String {
        switch schedule {
        case .asNeeded: return "asNeeded"
        case .daily(let times): return "daily(\(times.sorted().joined(separator: ",")))"
        case .weekly(let days, let times):
            let dayLabels = days.sorted().map(shortWeekdayLabel(iso:))
            return "weekly(\(dayLabels.joined(separator: ",")); \(times.sorted().joined(separator: ",")))"
        }
    }

    /// Localized abbreviated weekday name for an ISO weekday (1=Mon...7=Sun) — used only in the
    /// power-mode technical detail line so it names actual weekdays instead of raw integers.
    private func shortWeekdayLabel(iso: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: env.language.localeIdentifier)
        let symbols = cal.shortWeekdaySymbols // index 0 = Sunday ... 6 = Saturday
        let calWeekday = iso == 7 ? 1 : iso + 1
        let idx = calWeekday - 1
        guard symbols.indices.contains(idx) else { return String(iso) }
        return symbols[idx]
    }

    /// Foreground for filled primary buttons: legible white/near-black in both themes.
}

// MARK: - Adherence dot

private struct AdherenceDot: View {
    let kind: MedicationLogViewModel.DotKind
    private let size: CGFloat = 11

    var body: some View {
        Group {
            switch kind {
            case .taken:
                Circle().fill(BadanColor.primary)
            case .skipped:
                Circle().strokeBorder(BadanColor.textSecondary, lineWidth: 1.5)
            case .pending:
                Circle().fill(BadanColor.textSecondary.opacity(0.3))
            case .none:
                // Dashed, unfilled: visually distinct from the solid-fill `.pending` dot so
                // "nothing was ever scheduled" doesn't read the same as "scheduled, unresolved."
                Circle().strokeBorder(BadanColor.separator, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            case .notStarted:
                // Blank: the regimen didn't exist yet on this day, so there's nothing to show —
                // deliberately distinct from both `.pending` and `.none`.
                Circle().fill(Color.clear)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Medication history sheet

/// Full-range adherence report for one regimen (30/90 days), beyond the fixed 7-day strip.
/// Read-only, non-punitive framing — same "taken/skipped" vocabulary as the rest of the screen.
private struct MedicationHistorySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let regimen: MedicationRegimen

    private enum RangeOption: Int, CaseIterable {
        case d30 = 30
        case d90 = 90
    }

    @State private var range: RangeOption = .d30
    @State private var takenCount = 0
    @State private var skippedCount = 0
    @State private var longestStreak = 0
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                Picker("", selection: $range) {
                    Text(env.s(MedStrings.last30Days)).tag(RangeOption.d30)
                    Text(env.s(MedStrings.last90Days)).tag(RangeOption.d90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, BadanSpace.space6)
                } else if takenCount + skippedCount == 0 {
                    Text(env.s(MedStrings.noHistoryYet))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        historyRow(label: MedStrings.takenPercentLabel, value: percentText)
                        historyRow(label: MedStrings.longestStreakLabel,
                                   value: "\(env.format.integer(longestStreak)) \(env.s(MedStrings.streakDaysUnit))")
                        historyRow(label: MedStrings.totalRecordedLabel,
                                   value: env.format.integer(takenCount + skippedCount))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(BadanSpace.space4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BadanColor.background)
            .navigationTitle(regimen.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.done)) { dismiss() }
                }
            }
            .task(id: range) { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func historyRow(label: LocalizedString, value: String) -> some View {
        HStack {
            Text(env.s(label))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.textPrimary)
        }
    }

    private var percentText: String {
        let total = takenCount + skippedCount
        guard total > 0 else { return "—" }
        let pct = Int((Double(takenCount) / Double(total) * 100).rounded())
        return "\(env.format.integer(pct))%"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let tz = TimeZone.current.identifier
        let cal = DayAttribution.calendar(tz: tz)
        let now = env.now()
        let startOfToday = cal.startOfDay(for: now)
        let from = cal.date(byAdding: .day, value: -(range.rawValue - 1), to: startOfToday) ?? startOfToday

        guard let events = try? env.logging.adherence(regimenId: regimen.id, from: from, to: now) else {
            takenCount = 0
            skippedCount = 0
            longestStreak = 0
            return
        }

        var taken = 0
        var skipped = 0
        var takenDayKeys: Set<String> = []
        for e in events {
            switch e.kind {
            case .taken, .late:
                taken += 1
                takenDayKeys.insert(DayAttribution.localDayKey(e.scheduledFor ?? e.occurredAt, tz: tz))
            case .skipped:
                skipped += 1
            }
        }
        takenCount = taken
        skippedCount = skipped
        longestStreak = Self.longestConsecutiveStreak(dayKeys: takenDayKeys, tz: tz)
    }

    /// Longest run of consecutive calendar days present in `dayKeys`.
    private static func longestConsecutiveStreak(dayKeys: Set<String>, tz: String) -> Int {
        let days = dayKeys.compactMap { DayAttribution.date(fromDayKey: $0, tz: tz) }.sorted()
        guard !days.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<days.count {
            let expected = DayAttribution.addingDays(1, to: days[i - 1], tz: tz)
            if DayAttribution.localDayKey(expected, tz: tz) == DayAttribution.localDayKey(days[i], tz: tz) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }
}

// MARK: - Add medication sheet

/// A calm "add medication" flow. Records name, optional strength and a schedule
/// (as-needed or daily times). No dosing guidance — BADAN records, it never prescribes.
private struct AddMedicationSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// (name, strength?, schedule) -> whether the save actually succeeded.
    let onSave: (String, String?, MedicationSchedule) -> Bool

    private enum Mode: Hashable { case asNeeded, daily }

    @State private var name = ""
    @State private var strength = ""
    @State private var mode: Mode = .daily
    @State private var times: [String] = ["09:00"]
    @State private var pickedTime = AddMedicationSheet.defaultPickerDate
    @State private var duplicateTimeNotice = false
    @State private var saveFailed = false
    @State private var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    if saveFailed {
                        HStack(spacing: BadanSpace.space1) {
                            Image(systemName: "arrow.clockwise")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                            Text(env.s(MedStrings.saveFailed))
                                .font(BadanFont.caption)
                        }
                        .foregroundStyle(BadanColor.outOfBand)
                    }

                    field(label: Loc.medicationName) {
                        TextField(env.s(MedStrings.namePlaceholder), text: $name)
                            .textInputAutocapitalization(.words)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    .onChange(of: name) { _, newValue in
                        prefillStrengthIfNeeded(for: newValue)
                    }

                    // Strength is intentionally free text (e.g. "1000 IU", "50mg") — dose and
                    // unit vary too much across medications to force a single numeric+unit split.
                    field(label: Loc.strength) {
                        TextField(env.s(MedStrings.strengthPlaceholder), text: $strength)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                    }

                    scheduleSection
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.addMedication))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    // MARK: Schedule editor

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            Text(env.s(Loc.schedule))
                .font(BadanFont.chip)
                .foregroundStyle(BadanColor.textSecondary)

            HStack(spacing: BadanSpace.space2) {
                modeButton(.daily, label: MedStrings.scheduleDaily)
                modeButton(.asNeeded, label: MedStrings.scheduleAsNeeded)
            }

            if mode == .daily {
                Text(env.s(MedStrings.timesLabel))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)

                if !times.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: BadanSpace.space2)],
                              alignment: .leading, spacing: BadanSpace.space2) {
                        ForEach(times, id: \.self) { t in
                            timeChip(t)
                        }
                    }
                } else {
                    Text(env.s(MedStrings.addTimeHint))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                HStack(spacing: BadanSpace.space3) {
                    DatePicker("", selection: $pickedTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .onChange(of: pickedTime) { _, _ in duplicateTimeNotice = false }
                    Button {
                        addPickedTime()
                    } label: {
                        Label(env.s(MedStrings.addTime), systemImage: "plus.circle")
                            .font(BadanFont.bodyCompact.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }

                if duplicateTimeNotice {
                    Text(env.s(MedStrings.timeAlreadyAdded))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private func modeButton(_ target: Mode, label: LocalizedString) -> some View {
        let isSelected = mode == target
        return Button {
            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) { mode = target }
        } label: {
            HStack(spacing: BadanSpace.space1) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(env.s(label))
                    .font(BadanFont.body.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.textSecondary)
            .background((isSelected ? BadanColor.primary.opacity(0.14) : BadanColor.surface),
                       in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                    .strokeBorder(isSelected ? BadanColor.primary : BadanColor.separator,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func timeChip(_ time: String) -> some View {
        HStack(spacing: BadanSpace.space1) {
            Text(displayTime(time))
                .font(BadanFont.chip)
                .foregroundStyle(BadanColor.textPrimary)
                .lineLimit(1)
            Button {
                times.removeAll { $0 == time }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(env.s(Loc.delete))
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(BadanColor.separator, lineWidth: 1))
    }

    private func field<Content: View>(label: LocalizedString,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(label))
                .font(BadanFont.chip)
                .foregroundStyle(BadanColor.textSecondary)
            content()
                .padding(.horizontal, BadanSpace.space4)
                .frame(maxWidth: .infinity, minHeight: Self.fieldMinHeight, alignment: .leading)
                .background(BadanColor.surface,
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .strokeBorder(BadanColor.separator, lineWidth: 1)
                )
        }
    }

    /// Input-field height for this sheet's `field(...)` wrapper. Named so it's not a bare
    /// magic number, kept file-local since it's specific to this sheet's layout.
    private static let fieldMinHeight: CGFloat = 52

    // MARK: Actions

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(where: \.isLetter) else { return false }
        return mode == .asNeeded || !times.isEmpty
    }

    private func addPickedTime() {
        let key = Self.canonicalTime(from: Self.roundedToNearestFiveMinutes(pickedTime))
        if times.contains(key) {
            duplicateTimeNotice = true
        } else {
            duplicateTimeNotice = false
            times.append(key)
            times.sort()
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedStrength = strength.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule: MedicationSchedule = (mode == .daily && !times.isEmpty)
            ? .daily(times: times.sorted())
            : .asNeeded
        if onSave(trimmedName, trimmedStrength.isEmpty ? nil : trimmedStrength, schedule) {
            dismiss()
        } else {
            saveFailed = true
        }
    }

    /// If the typed name exactly matches a previously-added regimen (active or ended) and
    /// strength hasn't been touched yet, quietly pre-fill it from that regimen's last known
    /// strength. Still fully editable — never forced.
    private func prefillStrengthIfNeeded(for typedName: String) {
        guard strength.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let trimmed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        guard let regimens = try? env.logging.regimens(activeOnly: false) else { return }
        guard let match = regimens
            .filter({ $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first,
            let matchedStrength = match.strength, !matchedStrength.isEmpty
        else { return }
        strength = matchedStrength
    }

    // MARK: Time formatting

    private func displayTime(_ canonical: String) -> String {
        let cal = Calendar.current
        let date = MedicationLogViewModel.slotDate(time: canonical, on: cal.startOfDay(for: env.now()), cal: cal)
        timeFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return timeFormatter.string(from: date)
    }

    /// A stable "HH:mm" in 24h form regardless of display locale.
    private static let canonicalTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func canonicalTime(from date: Date) -> String {
        canonicalTimeFormatter.string(from: date)
    }

    /// Snaps a picked time to the nearest 5 minutes so imprecise drags don't create
    /// near-duplicate entries (e.g. "9:00 AM" vs "9:01 AM").
    private static func roundedToNearestFiveMinutes(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let minute = comps.minute, let hour = comps.hour else { return date }
        let rounded = Int((Double(minute) / 5.0).rounded()) * 5
        if rounded >= 60 {
            comps.minute = 0
            comps.hour = (hour + 1) % 24
        } else {
            comps.minute = rounded
        }
        return cal.date(from: comps) ?? date
    }

    private static var defaultPickerDate: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
