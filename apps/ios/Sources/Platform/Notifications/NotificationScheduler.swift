import Foundation
import UserNotifications

// MARK: - Reminder copy (bilingual; wellness-safe; privacy-first)

/// The *only* text a medication reminder ever shows. Deliberately generic: it names no
/// medication, dose, strength or schedule, so nothing sensitive is legible on a lock screen
/// (the notification body is what leaks). It also gives no dosing guidance — BADAN records,
/// it never prescribes (`Loc.medsBoundary`). Hand-written in both languages to match the
/// app's calm register, not machine-literal.
enum MedicationReminderCopy {
    static let title = LocalizedString(en: "BADAN", ar: "بدن")
    static let body = LocalizedString(
        en: "It's about the time you usually take a medication.",
        ar: "اقترب وقتك المعتاد لأحد أدويتك.")
}

// MARK: - Pure plan builder (testable; no UNUserNotificationCenter)

/// One local notification to be scheduled: a repeating calendar trigger at `hour`/`minute`,
/// optionally pinned to a `weekday` (Calendar's 1 = Sunday … 7 = Saturday) for weekly
/// regimens, or `nil` for a daily one. `bodyLanguage` is captured at schedule time because a
/// scheduled notification's text is static — see `MedicationReminderPlan`.
struct MedicationReminderPlanItem: Equatable, Hashable {
    let identifier: String
    let weekday: Int?      // Calendar weekday (1 = Sun … 7 = Sat); nil == every day
    let hour: Int
    let minute: Int
    let bodyLanguage: AppLanguage
}

/// Turns the live regimen list into a flat, deterministic list of reminders to schedule. Pure
/// and side-effect-free so it can be unit-tested without touching `UNUserNotificationCenter`;
/// `NotificationScheduler` is the thin adapter that turns each item into a real request.
enum MedicationReminderPlan {
    /// Identifier prefix shared by every medication reminder, so all of them (and only them)
    /// can be cancelled by prefix without disturbing any future non-medication notification.
    static let identifierPrefix = "med-reminder."

    /// Build the reminder plan.
    ///
    /// - `enabled == false` → empty plan (the master preference is off).
    /// - Only *active* regimens count: `endedAt == nil` and `deletedAt == nil` (an ended or
    ///   soft-deleted regimen must never keep firing).
    /// - `.asNeeded` regimens produce nothing (no fixed time to remind at).
    /// - `.daily(times)` → one item per time, every day (`weekday == nil`).
    /// - `.weekly(days, times)` → one item per (day, time) pair.
    /// - The final list is de-duplicated by identifier and sorted, so a regimen that somehow
    ///   carries the same time twice yields a single request and ordering is stable.
    static func build(regimens: [MedicationRegimen], enabled: Bool, language: AppLanguage) -> [MedicationReminderPlanItem] {
        guard enabled else { return [] }

        var seen = Set<String>()
        var items: [MedicationReminderPlanItem] = []

        for regimen in regimens where regimen.endedAt == nil && regimen.deletedAt == nil {
            switch regimen.schedule {
            case .asNeeded:
                continue
            case .daily(let times):
                for time in times {
                    guard let (h, m) = parse(time) else { continue }
                    append(&items, &seen, regimenId: regimen.id, weekday: nil, hour: h, minute: m, language: language)
                }
            case .weekly(let days, let times):
                for isoDay in days {
                    for time in times {
                        guard let (h, m) = parse(time) else { continue }
                        append(&items, &seen, regimenId: regimen.id, weekday: calendarWeekday(fromISO: isoDay),
                               hour: h, minute: m, language: language)
                    }
                }
            }
        }

        return items.sorted { $0.identifier < $1.identifier }
    }

    private static func append(_ items: inout [MedicationReminderPlanItem], _ seen: inout Set<String>,
                               regimenId: String, weekday: Int?, hour: Int, minute: Int, language: AppLanguage) {
        let hhmm = String(format: "%02d%02d", hour, minute)
        // Daily: "med-reminder.<id>.<HHmm>". Weekly: "med-reminder.<id>.d<isoWeekday>.<HHmm>"
        // (the weekday keeps otherwise-identical times on different days distinct, since one
        // UNCalendarNotificationTrigger encodes at most one weekday). Both share the prefix.
        let identifier: String
        if let weekday {
            identifier = "\(identifierPrefix)\(regimenId).w\(weekday).\(hhmm)"
        } else {
            identifier = "\(identifierPrefix)\(regimenId).\(hhmm)"
        }
        guard !seen.contains(identifier) else { return }
        seen.insert(identifier)
        items.append(MedicationReminderPlanItem(identifier: identifier, weekday: weekday,
                                                hour: hour, minute: minute, bodyLanguage: language))
    }

    /// Parse a canonical "HH:mm" into (hour, minute), rejecting out-of-range values.
    static func parse(_ time: String) -> (Int, Int)? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// Convert the domain's ISO weekday (1 = Mon … 7 = Sun) to `Calendar`'s (1 = Sun … 7 = Sat),
    /// which is what `UNCalendarNotificationTrigger`'s `DateComponents.weekday` expects.
    static func calendarWeekday(fromISO iso: Int) -> Int { (iso % 7) + 1 }
}

// MARK: - Scheduler (the UNUserNotificationCenter adapter)

/// The only place that talks to `UNUserNotificationCenter` for medication reminders. Kept off
/// the pure plan builder so scheduling logic is testable and this stays a thin I/O shell.
///
/// Notification *content* is captured at schedule time and never updated afterwards, so a
/// language change re-schedules from the live preference/regimen state (Settings toggle and the
/// launch/regimen-change hooks in `AppEnvironment`) rather than mutating already-queued
/// requests. There is no cheap "language changed" observer today, so switching language won't
/// retranslate already-scheduled reminders until the next reschedule trigger — an accepted,
/// documented limitation for static local notifications.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Authorization *only if the user hasn't been asked yet*. Returns `true` when already
    /// authorized (or provisional/ephemeral), prompts once when undetermined, and returns
    /// `false` when denied — never re-prompting a user who said no. Call this from an explicit,
    /// contextual user action (the Settings toggle), never at launch.
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    /// Whether notifications are already authorized, *without* ever prompting. Used by the
    /// launch/regimen-change self-heal paths so they can reschedule silently but never trigger
    /// the system permission dialog outside an explicit user action.
    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Cancel every previously-scheduled reminder that carries our prefix, then schedule fresh
    /// requests from the current plan. A no-op net effect (still cancels) when `enabled` is
    /// false or no active regimen has a fixed time.
    func rescheduleMedicationReminders(regimens: [MedicationRegimen], enabled: Bool, language: AppLanguage) async {
        await cancelAllMedicationReminders()

        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: enabled, language: language)
        guard !plan.isEmpty else { return }

        for item in plan {
            var components = DateComponents()
            components.hour = item.hour
            components.minute = item.minute
            if let weekday = item.weekday { components.weekday = weekday }

            let content = UNMutableNotificationContent()
            content.title = MedicationReminderCopy.title.resolved(item.bodyLanguage)
            content.body = MedicationReminderCopy.body.resolved(item.bodyLanguage)
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// Remove only pending medication reminders (matched by prefix), leaving any other
    /// scheduled notification untouched.
    func cancelAllMedicationReminders() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(MedicationReminderPlan.identifierPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - Foreground presentation

/// Presents medication reminders as a banner + sound even while BADAN is in the foreground
/// (the default is to suppress foreground notifications entirely). Wired as the notification
/// center's delegate in `BADANApp`.
final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
