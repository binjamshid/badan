import SwiftUI
import UserNotifications

/// Settings -> Notifications. Two sections: the EXISTING medication reminders (the one class BADAN
/// has always delivered), and EPIC-32's budgeted "Summaries & reminders" — whichever classes
/// `NotificationClass.userFacing` currently offers, which is the set that has a real producer, not
/// the set that is registered. (This doc used to list five classes while the screen rendered three.)
/// Every class is individually opt-in and ships OFF (the existing convention); together the non-med
/// classes send at most `profile.notifications.dailyNonMedLimit` a day — a preference the user sets
/// here, clamped to 1…4, no longer the fixed 2 this comment once called a hard invariant — and all
/// of them respect the shared quiet-hours window.
struct NotificationsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notificationsDeniedAtSystemLevel = false
    @State private var transientNotice: LocalizedString?

    /// The individually opt-in decision classes offered here, in display order. Sourced from the
    /// registry (not restated) so this screen and Android's Notifications section cannot drift, and
    /// so the "every toggle has a producer" rule is pinned by a test rather than by a comment.
    /// `meds` is deliberately absent — it has its own section and its own (existing) preference.
    private let decisionClasses: [NotificationClass] = NotificationClass.userFacing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                medicationSection
                summariesSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.notifications.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice = transientNotice { SettingsTransientNotice(notice: notice) }
        }
        .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: transientNotice)
        .task { await refreshSystemNotificationAuthorization() }
    }

    /// (A3) Announced as well as shown — a denied-permission notice that only appears at the
    /// bottom of the screen is invisible to VoiceOver, and it is the whole explanation for why
    /// the toggle just reverted.
    private func showTransientNotice(_ notice: LocalizedString) {
        transientNotice = notice
        Announce.failure(env.s(notice))
        Task {
            try? await Task.sleep(for: .seconds(3))
            if transientNotice == notice { transientNotice = nil }
        }
    }

    // MARK: Medication reminders (existing)

    private var medicationSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.notifications))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    SettingsToggleRow(title: SettingsStrings.notifMeds, subtitle: SettingsStrings.notifMedsSubtitle,
                                      isOn: medicationRemindersBinding)
                    // A toggle that's on here but blocked at the OS level would otherwise fail
                    // silently, with no way for the user to tell why from this screen.
                    if notificationsDeniedAtSystemLevel && env.profile.notifications.medicationReminders {
                        systemOffNote
                    }
                    // (F6) iOS caps an app at 64 pending notifications and drops the rest with no
                    // error, so without this the user's later reminders simply never arrive and
                    // nothing says why. Only shown when it actually bites.
                    if env.remindersTruncatedCount > 0 {
                        HStack(alignment: .top, spacing: BadanSpace.space2) {
                            Image(systemName: "exclamationmark.circle")
                                .imageScale(.small)
                                .foregroundStyle(BadanColor.outOfBand)
                                .accessibilityHidden(true)
                            LText(SettingsStrings.remindersCappedNote(env.remindersTruncatedCount))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Summaries & reminders (EPIC-32)

    private var summariesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(SettingsStrings.notifSummariesHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    ForEach(Array(decisionClasses.enumerated()), id: \.element) { index, cls in
                        let copy = NotificationClassCopy.settingsRow(cls)
                        SettingsToggleRow(title: copy.label, subtitle: copy.hint,
                                          isOn: classBinding(cls))
                        if index < decisionClasses.count - 1 {
                            settingsDivider
                        }
                    }
                    if anyDecisionClassOn {
                        settingsDivider
                        quietHoursRow
                        settingsDivider
                        dailyLimitRow
                        settingsDivider
                        SettingsToggleRow(title: SettingsStrings.notifShowValues,
                                          subtitle: SettingsStrings.notifShowValuesHint,
                                          isOn: showValuesBinding)
                        if notificationsDeniedAtSystemLevel { systemOffNote }
                        // The daily budget, stated as the kindness it is (never alarmist), and
                        // quoting the user's own ceiling rather than a constant.
                        HStack(alignment: .top, spacing: BadanSpace.space2) {
                            Image(systemName: "bell.badge")
                                .imageScale(.small)
                                .foregroundStyle(BadanColor.textSecondary)
                                .accessibilityHidden(true)
                            LText(NotificationClassCopy.dailyBudgetNote(
                                count: env.profile.notifications.dailyNonMedLimit,
                                arabicDigits: env.profile.arabicDigits))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Whether any budgeted class is on — gates the quiet-hours + budget footnote so the section
    /// stays quiet until the user actually opts into something.
    private var anyDecisionClassOn: Bool {
        decisionClasses.contains { env.profile.notifications.classOptIn[$0.rawValue] ?? false }
    }

    private var quietHoursRow: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(SettingsStrings.notifQuietHours, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            LText(SettingsStrings.notifQuietHoursHint)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: BadanSpace.space4) {
                hourPicker(SettingsStrings.notifQuietFrom, selection: quietStartBinding)
                hourPicker(SettingsStrings.notifQuietTo, selection: quietEndBinding)
            }
            .padding(.top, BadanSpace.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The user's daily ceiling on non-medication notifications. `SettingsRadioRows` rather than
    /// `SettingsRadioGroup` because this sits INSIDE the section's existing card and the group would
    /// nest a second one; rather than a `Stepper` because the app has no shared stepper row, and a
    /// four-option single-select is what the radio rows already do — RTL-correct, VoiceOver-correct,
    /// and no new component.
    private var dailyLimitRow: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(SettingsStrings.notifDailyLimit, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            LText(SettingsStrings.notifDailyLimitHint)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                SettingsRadioRows(
                    options: Array(NotificationPreference.dailyNonMedLimitRange),
                    // Arabic-Indic digits follow the user's preference here like every other
                    // numeral in the app — the count is data, not a label.
                    title: { env.format.integer($0) },
                    subtitle: nil,
                    isOn: { $0 == env.profile.notifications.dailyNonMedLimit },
                    onSelect: setDailyLimit)
            }
            .padding(.top, BadanSpace.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Persist a new ceiling and re-reconcile, so raising it can schedule a class that was being
    /// held back and lowering it stops promising one that no longer fits. Clamping is the model's
    /// job (`NotificationPreference.clampDailyNonMedLimit`), not this view's.
    private func setDailyLimit(_ value: Int) {
        guard value != env.profile.notifications.dailyNonMedLimit else { return }
        env.update { $0.notifications.dailyNonMedLimit = value }
        Task { await env.reconcileDecisionNotifications() }
    }

    private func hourPicker(_ label: LocalizedString, selection: Binding<Int>) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Text(label, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Picker("", selection: selection) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(Self.hourLabel(hour)).tag(hour)
                }
            }
            .pickerStyle(.menu)
            .tint(BadanColor.primary)
        }
    }

    private static func hourLabel(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    private var systemOffNote: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "bell.slash")
                .imageScale(.small)
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            LText(SettingsStrings.systemNotificationsOffNote)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bindings

    /// The medication-reminders toggle. Turning ON requests notification authorization
    /// contextually (never at launch): only on a real grant do we persist the preference and
    /// schedule from current regimens; on denial the preference stays off (the toggle reverts,
    /// since its `get` reads the persisted value) and we surface the honest status. Turning OFF
    /// persists and cancels every scheduled reminder.
    private var medicationRemindersBinding: Binding<Bool> {
        Binding(
            get: { env.profile.notifications.medicationReminders },
            set: { newValue in
                if newValue {
                    Task {
                        let granted = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
                        await refreshSystemNotificationAuthorization()
                        if granted {
                            env.update { $0.notifications.medicationReminders = true }
                            let regimens = (try? env.logging.regimens(activeOnly: true)) ?? []
                            await NotificationScheduler.shared.rescheduleMedicationReminders(
                                regimens: regimens, enabled: true, language: env.language)
                        } else {
                            // Keep the preference off (the toggle visibly reverts) and say why.
                            env.update { $0.notifications.medicationReminders = false }
                            showTransientNotice(SettingsStrings.notifPermissionDenied)
                        }
                    }
                } else {
                    env.update { $0.notifications.medicationReminders = false }
                    Task { await NotificationScheduler.shared.cancelAllMedicationReminders() }
                }
            }
        )
    }

    /// A per-class opt-in toggle for a budgeted decision class. Turning ON requests authorization
    /// contextually and, on a grant, reconciles the schedule (which honours the budget, quiet hours
    /// and the 64-cap — a toggle is a request, not a guarantee that a notice fits today). Turning
    /// OFF persists and cancels that class's pending notices, leaving every other class untouched.
    private func classBinding(_ cls: NotificationClass) -> Binding<Bool> {
        Binding(
            get: { env.profile.notifications.classOptIn[cls.rawValue] ?? false },
            set: { newValue in
                if newValue {
                    Task {
                        let granted = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
                        await refreshSystemNotificationAuthorization()
                        if granted {
                            env.update { $0.notifications.classOptIn[cls.rawValue] = true }
                            await env.reconcileDecisionNotifications()
                        } else {
                            env.update { $0.notifications.classOptIn[cls.rawValue] = false }
                            showTransientNotice(SettingsStrings.notifPermissionDenied)
                        }
                    }
                } else {
                    env.update { $0.notifications.classOptIn[cls.rawValue] = false }
                    Task { await NotificationScheduler.shared.cancelDecisionNotifications(cls) }
                }
            }
        )
    }

    /// The lock-screen values choice, offered once in onboarding and changeable here. No reconcile:
    /// this changes what a notification SAYS, not whether or when one is scheduled, and the copy is
    /// resolved at delivery time from the live preference.
    private var showValuesBinding: Binding<Bool> {
        Binding(
            get: { env.profile.notifications.showValuesInNotifications },
            set: { newValue in env.update { $0.notifications.showValuesInNotifications = newValue } }
        )
    }

    private var quietStartBinding: Binding<Int> {
        Binding(
            get: { env.profile.notifications.quietHours.startHour },
            set: { value in
                env.update { $0.notifications.quietHours.startHour = value }
                Task { await env.reconcileDecisionNotifications() }
            }
        )
    }

    private var quietEndBinding: Binding<Int> {
        Binding(
            get: { env.profile.notifications.quietHours.endHour },
            set: { value in
                env.update { $0.notifications.quietHours.endHour = value }
                Task { await env.reconcileDecisionNotifications() }
            }
        )
    }

    private func refreshSystemNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDeniedAtSystemLevel = settings.authorizationStatus == .denied
    }
}
