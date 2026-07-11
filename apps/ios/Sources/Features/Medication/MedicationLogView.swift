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
    enum DotKind { case taken, skipped, pending, none }

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

    private var tz: String { TimeZone.current.identifier }

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

            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: env.language.localeIdentifier)
            timeFormatter.timeStyle = .short
            timeFormatter.dateStyle = .none

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
                let events = todaysAdherence
                    .filter { $0.regimenId == regimen.id }
                    .sorted { $0.occurredAt > $1.occurredAt }

                // Assign each event to its nearest still-unclaimed slot (latest events claim first).
                var assigned: [Int: AdherenceEvent] = [:]
                for e in events {
                    let emin = Self.minutesOfDay(of: e.scheduledFor ?? e.occurredAt, cal: cal)
                    var best: Int?
                    var bestDist = Int.max
                    for (i, s) in descs.enumerated() where assigned[i] == nil {
                        let dist = abs(s.mins - emin)
                        if dist < bestDist { bestDist = dist; best = i }
                    }
                    if let b = best { assigned[b] = e }
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
            let letterFormatter = DateFormatter()
            letterFormatter.locale = Locale(identifier: env.language.localeIdentifier)
            letterFormatter.setLocalizedDateFormatFromTemplate("EEEEE")
            let weekdayLetters = days.map { letterFormatter.string(from: $0) }

            var strips: [String: [DotKind]] = [:]
            for regimen in regimens {
                strips[regimen.id] = days.map { day in
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
            state = .error(String(describing: error))
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

    private func record(regimenId: String, scheduledFor: Date, time: String,
                        kind: AdherenceKind, reason: SkipReason?, env: AppEnvironment, reload: Bool = true) {
        let now = env.now()
        // Deterministic id per (regimen, day, slot) so changing your mind replaces the row cleanly.
        let dayKey = DayAttribution.localDayKey(scheduledFor, tz: tz)
        let event = AdherenceEvent(
            id: "adh-\(regimenId)-\(dayKey)-\(time)",
            regimenId: regimenId,
            kind: kind,
            scheduledFor: scheduledFor,
            occurredAt: now,
            tzId: tz,
            skipReason: reason,
            updatedAt: now,
            originDeviceId: env.deviceId
        )
        try? env.logging.insertAdherence(event)
        if reload { load(env) }
    }

    func addRegimen(name: String, strength: String?, schedule: MedicationSchedule, env: AppEnvironment) {
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
        try? env.logging.upsertRegimen(regimen)
        load(env)
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
}

// MARK: - Screen

/// The non-punitive medication hub. Today's scheduled doses expand into calm Take / Skip
/// rows; overdue reads as a neutral "Still due" (never red); skips are a first-class,
/// outline-styled choice with an optional reason. Below: your regimens with a 7-day dot
/// strip. A pushed screen (a parent NavigationStack is provided by the app shell).
struct MedicationLogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = MedicationLogViewModel()
    @State private var showingAdd = false
    /// Slot currently showing its skip-reason chips.
    @State private var skippingSlotId: String?
    /// Resolved slot the user re-opened to change their choice.
    @State private var editingSlotId: String?

    var body: some View {
        StatefulContainer(vm.state) { data in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space6) {
                    if data.regimens.isEmpty {
                        emptyState
                    } else {
                        if !data.dueSlots.isEmpty { dueSection(data) }
                        regimensSection(data)
                    }
                    boundaryFooter
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logMedication))
        .navigationBarTitleDisplayMode(.inline)
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
        .task { vm.load(env) }
    }

    // MARK: Due section

    private func dueSection(_ data: MedicationLogViewModel.MedData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(MedStrings.dueToday)) {
                if data.hasPending {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
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
            }
        }
    }

    /// The right-side status marker: a completion chip, a calm skip outline, or a neutral
    /// "still due" — never red, never alarming.
    @ViewBuilder
    private func statusTrailing(for slot: MedicationLogViewModel.DueSlot) -> some View {
        switch slot.status {
        case .taken:
            StatusChip(.inBand, label: env.s(Loc.taken), language: env.language)
        case .skipped:
            skippedPill(reason: slot.skipReason)
        case .pending:
            if slot.isOverdue {
                PillLabel(env.s(Loc.stillDue), systemImage: "clock",
                          tint: BadanColor.textSecondary)
            } else {
                EmptyView()
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    editingSlotId = nil
                    vm.take(slot, env: env)
                }
            } label: {
                Text(env.s(MedStrings.takeAction))
                    .font(BadanFont.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .foregroundStyle(Self.onPrimary)
                    .background(BadanColor.primary,
                                in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { skippingSlotId = slot.id }
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            vm.skip(slot, reason: reason, env: env)
                            skippingSlotId = nil
                            editingSlotId = nil
                        }
                    } label: {
                        Text(env.s(reason.displayLabel))
                            .font(BadanFont.chip)
                            .foregroundStyle(BadanColor.textPrimary)
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
                withAnimation(.easeInOut(duration: 0.2)) { skippingSlotId = nil }
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
                ForEach(data.regimens) { regimen in
                    regimenCard(regimen, data: data)
                }
            }
        }
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

                // Power altitude: name the technical schedule and where the record lives.
                if env.depth.showsPowerDetail {
                    Text("\(scheduleDetail(regimen.schedule)) · \(env.s(MedStrings.addedManually))")
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
            return "weekly(\(days.map(String.init).joined(separator: ",")); \(times.sorted().joined(separator: ",")))"
        }
    }

    /// Foreground for filled primary buttons: legible white/near-black in both themes.
    private static let onPrimary = Color(light: "#FFFFFF", dark: "#08201D")
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
                Circle().fill(BadanColor.textSecondary.opacity(0.22))
            case .none:
                Circle().fill(BadanColor.separator.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Add medication sheet

/// A calm "add medication" flow. Records name, optional strength and a schedule
/// (as-needed or daily times). No dosing guidance — BADAN records, it never prescribes.
private struct AddMedicationSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// (name, strength?, schedule)
    let onSave: (String, String?, MedicationSchedule) -> Void

    private enum Mode: Hashable { case asNeeded, daily }

    @State private var name = ""
    @State private var strength = ""
    @State private var mode: Mode = .daily
    @State private var times: [String] = ["09:00"]
    @State private var pickedTime = AddMedicationSheet.defaultPickerDate

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    field(label: Loc.medicationName) {
                        TextField(env.s(MedStrings.namePlaceholder), text: $name)
                            .textInputAutocapitalization(.words)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                    }

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
                }

                HStack(spacing: BadanSpace.space3) {
                    DatePicker("", selection: $pickedTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
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
            }
        }
    }

    private func modeButton(_ target: Mode, label: LocalizedString) -> some View {
        let isSelected = mode == target
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { mode = target }
        } label: {
            Text(env.s(label))
                .font(BadanFont.body.weight(.medium))
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
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(BadanColor.surface,
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .strokeBorder(BadanColor.separator, lineWidth: 1)
                )
        }
    }

    // MARK: Actions

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mode == .asNeeded || !times.isEmpty
    }

    private func addPickedTime() {
        let key = Self.canonicalTime(from: pickedTime)
        if !times.contains(key) {
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
        onSave(trimmedName, trimmedStrength.isEmpty ? nil : trimmedStrength, schedule)
        dismiss()
    }

    // MARK: Time formatting

    private func displayTime(_ canonical: String) -> String {
        let cal = Calendar.current
        let date = MedicationLogViewModel.slotDate(time: canonical, on: cal.startOfDay(for: env.now()), cal: cal)
        let f = DateFormatter()
        f.locale = Locale(identifier: env.language.localeIdentifier)
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// A stable "HH:mm" in 24h form regardless of display locale.
    private static func canonicalTime(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static var defaultPickerDate: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
