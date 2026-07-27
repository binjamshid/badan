import SwiftUI

/// HYD-004 / HYD-012. Where a person chooses when (and whether) hydration reminders arrive, and
/// enters a fasting window that silences them completely.
///
/// Tone rules this screen holds to, from §7 and §17 of the hydration research: reminders are OFF
/// until explicitly turned on, the cap is one a day by default, nothing here implies a health
/// consequence for not drinking, and the fasting window is a plain pair of times the user types —
/// BADAN never infers that someone fasts, why they fast, or when their fast begins.
struct HydrationReminderSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var didPrime = false
    @State private var remindersOn = false
    @State private var times: [Int] = []
    @State private var fastingOn = false
    @State private var fastStart = 4 * 60 + 30
    @State private var fastEnd = 18 * 60 + 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                remindersSection
                if remindersOn { timesSection }
                fastingSection
                if remindersOn { previewSection }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(HydrationReminderStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { primeIfNeeded() }
    }

    // MARK: - Sections

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationReminderStrings.title))
            BadanCard {
                Toggle(isOn: Binding(get: { remindersOn }, set: { setRemindersOn($0) })) {
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        LText(HydrationReminderStrings.enableLabel)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(HydrationReminderStrings.enableHelp)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(BadanColor.primary)
            }
        }
    }

    private var timesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationReminderStrings.timesHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    if times.isEmpty {
                        LText(HydrationReminderStrings.noTimesYet)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(times.sorted(), id: \.self) { minute in
                        HStack(spacing: BadanSpace.space3) {
                            timePicker(minute: minute) { updated in replace(minute, with: updated) }
                            Spacer(minLength: BadanSpace.space2)
                            Button { remove(minute) } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(BadanColor.textSecondary)
                                    .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(env.s(HydrationReminderStrings.removeTime))
                        }
                    }
                    Button { addTime() } label: {
                        HStack(spacing: BadanSpace.space2) {
                            Image(systemName: "plus.circle").accessibilityHidden(true)
                            LText(HydrationReminderStrings.addTime)
                        }
                        .font(BadanFont.caption.weight(.medium))
                        .foregroundStyle(BadanColor.primary)
                        .frame(minHeight: BadanSpace.touchMin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fastingSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationReminderStrings.fastingHeader))
            LText(HydrationReminderStrings.fastingHelp)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    Toggle(isOn: Binding(get: { fastingOn }, set: { setFastingOn($0) })) {
                        LText(HydrationReminderStrings.fastingEnableLabel)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    .tint(BadanColor.primary)

                    if fastingOn {
                        HStack(spacing: BadanSpace.space3) {
                            LText(HydrationReminderStrings.fastFrom)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                            timePicker(minute: fastStart) { fastStart = $0; persist() }
                            Spacer(minLength: BadanSpace.space2)
                            LText(HydrationReminderStrings.fastUntil)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                            timePicker(minute: fastEnd) { fastEnd = $0; persist() }
                        }
                        LText(HydrationReminderStrings.fastingNote)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Shows what the settings actually produce. Without this, a schedule fully suppressed by a
    /// fasting window or quiet hours looks identical to one that works — the person would only find
    /// out by waiting for a reminder that never comes.
    private var previewSection: some View {
        let plan = HydrationReminderPolicy.plan(
            after: env.now(), settings: currentSettings(),
            quietHours: env.profile.notifications.quietHours, enabled: true,
            calendar: .current, withinDays: 1)

        return VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(HydrationReminderStrings.previewHeader))
            BadanCard {
                if let next = plan.first {
                    Text(HydrationReminderStrings.nextReminder
                        .filling(["time": timeLabel(HydrationReminderPolicy.minuteOfDay(next, calendar: .current))])
                        .resolved(env.language))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                } else {
                    LText(HydrationReminderStrings.nothingScheduled)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Time picker

    /// A plain hour/minute picker over minutes-from-midnight. `DatePicker` would need a `Date`, and
    /// the stored value is deliberately wall-clock (see `HydrationFastingWindow`), so converting
    /// back and forth would invite exactly the timezone drift that representation avoids.
    private func timePicker(minute: Int, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: BadanSpace.space1) {
            Picker("", selection: Binding(get: { minute / 60 },
                                          set: { onChange($0 * 60 + minute % 60) })) {
                ForEach(0..<24, id: \.self) { Text(env.format.integer($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(":").foregroundStyle(BadanColor.textSecondary)
            Picker("", selection: Binding(get: { minute % 60 },
                                          set: { onChange((minute / 60) * 60 + $0) })) {
                ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        // Clock times read left-to-right in both languages, matching `ProvenanceRow`.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityLabel(timeLabel(minute))
    }

    private func timeLabel(_ minute: Int) -> String {
        "\(env.format.integer(minute / 60)):\(String(format: "%02d", minute % 60))"
    }

    // MARK: - State

    private func primeIfNeeded() {
        guard !didPrime else { return }
        didPrime = true
        let settings = env.profile.hydrationReminders
        remindersOn = env.isNotificationClassEnabled(.hydration)
        times = settings.times
        fastingOn = settings.fasting.enabled
        if let window = settings.fasting.windows.first {
            fastStart = window.startMinute
            fastEnd = window.endMinute
        }
    }

    private func currentSettings() -> HydrationReminderSettings {
        var settings = env.profile.hydrationReminders
        settings.times = times
        settings.fasting = fastingOn
            ? HydrationFastingProfile(enabled: true,
                                      windows: [HydrationFastingWindow(startMinute: fastStart, endMinute: fastEnd)])
            // Turning the fast off keeps nothing stale around, but the user's entered times live in
            // `fastStart`/`fastEnd` for the length of this screen, so flipping it back on restores
            // what they typed instead of resetting to the template.
            : HydrationFastingProfile(enabled: false,
                                      windows: [HydrationFastingWindow(startMinute: fastStart, endMinute: fastEnd)])
        return settings
    }

    private func setRemindersOn(_ on: Bool) {
        remindersOn = on
        if on && times.isEmpty { times = HydrationReminderSettings.legacyDefault.times }
        env.update { profile in
            profile.notifications.classOptIn[NotificationClass.hydration.rawValue] = on
        }
        persist()
    }

    private func setFastingOn(_ on: Bool) {
        fastingOn = on
        persist()
    }

    private func addTime() {
        // Offer a time that isn't already taken, walking forward in whole hours rather than
        // inserting a duplicate the user then has to notice and fix.
        var candidate = 9 * 60
        while times.contains(candidate) && candidate < 23 * 60 { candidate += 60 }
        times.append(candidate)
        persist()
    }

    private func replace(_ old: Int, with new: Int) {
        guard let index = times.firstIndex(of: old), !times.contains(new) else { return }
        times[index] = new
        persist()
    }

    private func remove(_ minute: Int) {
        times.removeAll { $0 == minute }
        persist()
    }

    private func persist() {
        let settings = currentSettings()
        env.update { $0.hydrationReminders = settings }
        // Re-plan immediately so a schedule change takes effect now rather than at the next launch.
        Task { await env.reconcileDecisionNotifications() }
    }
}

// MARK: - Strings

enum HydrationReminderStrings {
    static let title = LocalizedString(en: "Reminders", ar: "التذكيرات")
    static let enableLabel = LocalizedString(en: "Water check-ins", ar: "تذكيرات الماء")
    static let enableHelp = LocalizedString(
        en: "A calm nudge at times you choose. Off unless you turn it on.",
        ar: "تنبيه هادئ في أوقات تختارها. مُطفأ ما لم تُشغّله.")
    static let timesHeader = LocalizedString(en: "Times", ar: "الأوقات")
    static let noTimesYet = LocalizedString(en: "No times chosen — nothing will be sent.",
                                            ar: "لم تختر أي وقت — لن يُرسل شيء.")
    static let addTime = LocalizedString(en: "Add a time", ar: "أضف وقتًا")
    static let removeTime = LocalizedString(en: "Remove this time", ar: "احذف هذا الوقت")

    static let fastingHeader = LocalizedString(en: "Fasting window", ar: "فترة الصيام")
    static let fastingHelp = LocalizedString(
        en: "If you fast, set the hours here and BADAN stays completely silent during them. You enter the times yourself — nothing is assumed about you.",
        ar: "إن كنت تصوم، حدّد الساعات هنا ويلتزم بدن الصمت التام خلالها. أنت من يُدخل الأوقات — لا يُفترض عنك شيء.")
    static let fastingEnableLabel = LocalizedString(en: "Stay silent while I'm fasting",
                                                    ar: "التزم الصمت أثناء صيامي")
    static let fastFrom = LocalizedString(en: "From", ar: "من")
    static let fastUntil = LocalizedString(en: "Until", ar: "إلى")
    static let fastingNote = LocalizedString(
        en: "These hours repeat daily. Adjust them whenever they change.",
        ar: "تتكرر هذه الساعات يوميًا. عدّلها متى تغيّرت.")

    static let previewHeader = LocalizedString(en: "What happens next", ar: "ما سيحدث تاليًا")
    static let nextReminder = LocalizedString(en: "Next check-in at {time}.", ar: "التذكير التالي عند {time}.")
    static let nothingScheduled = LocalizedString(
        en: "Nothing is scheduled — your times fall inside your fasting window or quiet hours.",
        ar: "لا شيء مجدول — أوقاتك تقع ضمن فترة صيامك أو ساعات الهدوء.")

    static let openReminders = LocalizedString(en: "Reminders and fasting", ar: "التذكيرات والصيام")
}
