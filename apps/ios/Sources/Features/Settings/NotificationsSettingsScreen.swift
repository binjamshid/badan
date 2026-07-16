import SwiftUI
import UserNotifications

/// Settings -> Notifications. Medication reminders are the only notification BADAN sends; the
/// other three preferences the profile models (morning summary, weekly digest, data-paused
/// alerts) have no delivery mechanism and stay hidden until they do — see `notificationsSection`.
struct NotificationsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var notificationsDeniedAtSystemLevel = false
    @State private var transientNotice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                notificationsSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.notifications.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice = transientNotice { SettingsTransientNotice(notice: notice) }
        }
        .animation(.easeInOut(duration: 0.25), value: transientNotice)
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

    // MARK: Notifications

    // Only medication reminders actually schedule and deliver notifications today. The other
    // three toggles (morning summary, weekly digest, data-paused alerts) persisted a preference
    // but had no delivery mechanism at all — a toggle that silently does nothing — so they're
    // hidden until those features exist (NEW-02/UX-02). Their profile fields are kept.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.notifications))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    SettingsToggleRow(title: SettingsStrings.notifMeds, subtitle: SettingsStrings.notifMedsSubtitle,
                                      isOn: medicationRemindersBinding)
                    // A toggle that's on here but blocked at the OS level would otherwise fail
                    // silently, with no way for the user to tell why from this screen.
                    if notificationsDeniedAtSystemLevel && env.profile.notifications.medicationReminders {
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
        .task { await refreshSystemNotificationAuthorization() }
    }

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

    private func refreshSystemNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDeniedAtSystemLevel = settings.authorizationStatus == .denied
    }
}
