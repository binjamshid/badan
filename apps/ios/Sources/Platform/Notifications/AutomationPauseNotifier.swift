import Foundation

/// The real `AutomationPauseNotifying`, forwarding to the existing `NotificationScheduler`.
///
/// The engine runs off the main actor (a `BGTask` background queue), so this adapter accepts the
/// call there and hops to the main actor — where `NotificationScheduler` lives — to actually
/// deliver. Fire-and-forget: the pause itself is already durably recorded in `automation_schedules`
/// by the time this is called, so a dropped or delayed notification never loses the honesty
/// guarantee, and blocking a background wake on a notification round-trip would be the wrong
/// trade.
struct AutomationPauseNotifier: AutomationPauseNotifying {
    /// The profile store the `exportHealthAlert` opt-in is read from, at DELIVERY time rather than
    /// at construction — so turning the toggle off silences the very next notice, not merely those
    /// raised after the next launch. This is the composition root's own repository instance, not a
    /// fresh one: `ProfileRepository` caches, and a second instance's cache would never see the
    /// preference being written through the first.
    let profiles: ProfileRepository

    func automationPaused(scheduleId: String, language: AppLanguage) {
        // Read off the main actor, before the hop: this is a plain storage read, and the profile is
        // not main-actor state — `AppEnvironment` merely observes it.
        let optedIn = (try? profiles.load())?
            .notifications.classOptIn[NotificationClass.exportHealthAlert.rawValue] ?? false
        Task { @MainActor in
            await NotificationScheduler.shared.notifyAutomationPaused(scheduleId: scheduleId,
                                                                      language: language,
                                                                      optedIn: optedIn)
        }
    }
}
