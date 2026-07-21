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
    func automationPaused(scheduleId: String, language: AppLanguage) {
        Task { @MainActor in
            await NotificationScheduler.shared.notifyAutomationPaused(scheduleId: scheduleId,
                                                                      language: language)
        }
    }
}
