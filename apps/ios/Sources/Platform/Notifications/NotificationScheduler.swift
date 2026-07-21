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

/// The copy for the "an automation was paused" notification (EPIC-15 failure budget). Generic on
/// purpose: it names no template and no destination, so nothing a user chose to label revealingly
/// leaks onto a lock screen, and the tone is calm — a paused automation is a thing to review, not
/// an emergency. This is an ALLOWED notification class (a direct consequence of the user's own 3
/// failed runs), not the Phase-3 reminder decision engine.
enum AutomationPausedCopy {
    static let title = LocalizedString(en: "BADAN", ar: "بدن")
    static let body = LocalizedString(
        en: "An automatic export was paused after a few failed attempts. Open BADAN to review it.",
        ar: "أُوقف تصدير تلقائي مؤقتاً بعد عدّة محاولات فاشلة. افتح «بدن» لمراجعته.")
    /// Identifier prefix so an automation-paused notice is distinguishable from — and never
    /// cancelled alongside — the medication reminders (`MedicationReminderPlan.identifierPrefix`).
    static let identifierPrefix = "automation-paused."
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

    // MARK: - (F6) The 64-request ceiling

    /// iOS keeps at most this many *pending* notification requests per app. Every request past it
    /// is silently dropped by the OS — `center.add` reports no error, so nothing in the app can
    /// tell. BADAN schedules nothing but medication reminders, so the whole budget is ours.
    static let systemPendingLimit = 64

    /// Trim a plan to the requests that will actually fire soonest.
    ///
    /// (F6) A plan can exceed the ceiling easily: five regimens × three times a day × seven
    /// weekly slots is 105 requests. The OS silently kept whichever 64 it saw first — insertion
    /// order, not time order — and dropped the rest, so a user could lose the reminder for their
    /// evening medication and never learn it wasn't scheduled. In a medication app, a reminder
    /// that silently never arrives is the most consequential failure this file can have.
    ///
    /// Sorting by next fire time makes the truncation principled rather than arbitrary: the
    /// reminders nearest in time survive, and because `rescheduleMedicationReminders` re-runs on
    /// every relevant change (a take, a skip, an app foreground, a regimen edit), the window
    /// rolls forward continuously — the dropped tail keeps getting rescheduled as it approaches.
    /// Callers surface `truncated` so the user is told rather than left to discover it.
    static func capped(_ items: [MedicationReminderPlanItem], limit: Int = systemPendingLimit,
                       now: Date, calendar: Calendar) -> (items: [MedicationReminderPlanItem], truncated: Int) {
        guard items.count > limit else { return (items, 0) }

        // An item whose components can't produce a next date (shouldn't happen — `parse` already
        // range-checks) sorts last rather than crashing or silently vanishing first.
        let byNextFire = items
            .map { (item: $0, fire: nextFireDate(for: $0, after: now, calendar: calendar) ?? .distantFuture) }
            .sorted { ($0.fire, $0.item.identifier) < ($1.fire, $1.item.identifier) }

        let kept = byNextFire.prefix(limit).map(\.item)
        // Re-sorted by identifier so the returned plan keeps `build`'s stable ordering contract.
        return (kept.sorted { $0.identifier < $1.identifier }, items.count - limit)
    }

    /// When `item` would next fire — the same calendar matching `UNCalendarNotificationTrigger`
    /// performs, computed here so the cap can reason about it without scheduling anything.
    static func nextFireDate(for item: MedicationReminderPlanItem, after now: Date,
                             calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = item.hour
        components.minute = item.minute
        if let weekday = item.weekday { components.weekday = weekday }
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }
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
    ///
    /// Returns how many reminders the OS ceiling forced out of the plan (F6) — 0 in the ordinary
    /// case. Callers surface it; see `MedicationReminderPlan.capped`.
    @discardableResult
    func rescheduleMedicationReminders(regimens: [MedicationRegimen], enabled: Bool,
                                       language: AppLanguage, now: Date = Date(),
                                       calendar: Calendar = .current) async -> Int {
        await cancelAllMedicationReminders()

        let full = MedicationReminderPlan.build(regimens: regimens, enabled: enabled, language: language)
        guard !full.isEmpty else { return 0 }
        // (F6 + EPIC-32) Cap before scheduling. Without this the OS drops the overflow itself,
        // silently and in insertion order rather than by time. The ceiling meds may claim is the
        // 64-pending limit MINUS whatever non-med notices are currently pending, so meds + decision
        // notices together never exceed 64 and the OS never silently drops a med reminder to fit a
        // score/hydration notice. When nothing non-med is pending — the default, since every
        // decision class ships OFF — this is the full 64 and behaviour is unchanged. See
        // `NotificationDecisionEngine.medPendingLimit`.
        let nonMedPending = await pendingNonMedRequestCount()
        let medLimit = NotificationDecisionEngine.medPendingLimit(nonMedPending: nonMedPending)
        let (plan, truncated) = MedicationReminderPlan.capped(full, limit: medLimit, now: now, calendar: calendar)

        for item in plan {
            var components = DateComponents()
            components.hour = item.hour
            components.minute = item.minute
            if let weekday = item.weekday { components.weekday = weekday }

            let content = UNMutableNotificationContent()
            content.title = MedicationReminderCopy.title.resolved(item.bodyLanguage)
            content.body = MedicationReminderCopy.body.resolved(item.bodyLanguage)
            content.sound = .default
            // EPIC-32: a med reminder deep-links to the meds surface like every other class.
            content.userInfo[NotificationDeepLink.userInfoKey] = NotificationClass.meds.deepLink.rawValue

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
        return truncated
    }

    /// Deliver the "an automation was paused" notice for `scheduleId` (EPIC-15). One request per
    /// schedule id, so re-pausing the same schedule replaces its notice rather than stacking a
    /// second one. Silent no-op when notifications are not authorized — this method never prompts
    /// (the authorization prompt is an explicit-user-action concern, not something a background
    /// failure may trigger). The VISIBLE pause in `automation_schedules` is the guarantee; this is
    /// the best-effort nudge on top.
    ///
    /// `trigger: nil` delivers as soon as the system allows. Content language is captured now
    /// because a scheduled notification's text is static (same limitation, and same reasoning, as
    /// the medication reminders above).
    func notifyAutomationPaused(scheduleId: String, language: AppLanguage) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = AutomationPausedCopy.title.resolved(language)
        content.body = AutomationPausedCopy.body.resolved(language)
        content.sound = .default
        // EPIC-32: an automation-pause notice belongs to the export-health surface — deep-link there.
        content.userInfo[NotificationDeepLink.userInfoKey] = NotificationClass.exportHealthAlert.deepLink.rawValue
        let request = UNNotificationRequest(
            identifier: AutomationPausedCopy.identifierPrefix + scheduleId,
            content: content, trigger: nil)
        try? await center.add(request)
    }

    /// Remove only pending medication reminders (matched by prefix), leaving any other
    /// scheduled notification untouched.
    func cancelAllMedicationReminders() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(MedicationReminderPlan.identifierPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Decision-engine notifications (EPIC-32)

    /// Pending-request counts split into meds vs. everything-else. `med` is what a med reminder
    /// occupies; `nonMed` is every other pending request (decision notices AND the EPIC-15
    /// automation-pause notice) — so `med + nonMed` is the true total against the 64 ceiling. This
    /// is what the decision engine reads for its `pendingMedCount`/`pendingNonMedCount` cap check.
    func pendingCounts() async -> (med: Int, nonMed: Int) {
        let pending = await center.pendingNotificationRequests()
        var med = 0, nonMed = 0
        for request in pending {
            if request.identifier.hasPrefix(MedicationReminderPlan.identifierPrefix) { med += 1 }
            else { nonMed += 1 }
        }
        return (med, nonMed)
    }

    /// Everything currently pending that is NOT a med reminder — the room meds must reserve so the
    /// two never exceed the 64 ceiling together (see `rescheduleMedicationReminders`).
    private func pendingNonMedRequestCount() async -> Int {
        await pendingCounts().nonMed
    }

    /// Schedule one decision-engine notification for `cls` at `fireDate`. Content is generic and
    /// value-free (`NotificationClassCopy`), captured now in `language` because a scheduled
    /// notification's text is static (same limitation as med reminders). The request carries its
    /// deep link and its ledger row id in `userInfo`. `identifier` is deterministic per class+day at
    /// the call site so re-scheduling replaces rather than stacks. This method does NO
    /// budget/cap/opt-in checking — that is the caller's job via `NotificationDecisionEngine`; this
    /// is the thin I/O shell.
    ///
    /// `ledgerRowId` is the `notification_deliveries` row the caller already reserved for this
    /// notification. It rides along so the delegate can close that row out on delivery without
    /// guessing which row a fired notification belonged to.
    func scheduleDecisionNotification(_ cls: NotificationClass, identifier: String, fireDate: Date,
                                      ledgerRowId: String, language: AppLanguage,
                                      calendar: Calendar = .current) async {
        let (title, body) = NotificationClassCopy.content(cls)
        let content = UNMutableNotificationContent()
        content.title = title.resolved(language)
        content.body = body.resolved(language)
        content.sound = .default
        content.userInfo[NotificationDeepLink.userInfoKey] = cls.deepLink.rawValue
        content.userInfo[NotificationDelivery.ledgerRowIdUserInfoKey] = ledgerRowId

        // A future fire date gets a one-shot calendar trigger (the morning summary / wind-down /
        // hydration classes). An event-driven notice (deviation, export-health) passes a fire date
        // of "now" and is delivered as soon as the system allows — a calendar trigger for the
        // current minute may never fire, so `trigger: nil` is used for anything at or in the past.
        let trigger: UNNotificationTrigger?
        if fireDate.timeIntervalSinceNow > 1 {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = nil
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// Cancel every pending decision notification for one class (matched by its prefix) — used when
    /// the user turns that class off. Never touches meds or the automation-pause notice.
    func cancelDecisionNotifications(_ cls: NotificationClass) async {
        guard !cls.isMedication else { return }
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(cls.identifierPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Cancel every pending decision notification across all non-med classes.
    func cancelAllDecisionNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(NotificationClass.decisionPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - Foreground presentation

/// Presents notifications as a banner + sound even while BADAN is in the foreground (the default
/// is to suppress foreground notifications entirely), routes a tap to the notification's evidence
/// surface (EPIC-32 deep links), and closes out the ledger row of any decision notification the app
/// actually observes. Wired as the notification center's delegate in `BADANApp`.
final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main actor with the deep link when the user taps a notification. Set by
    /// `BADANApp` to hand the target to `AppEnvironment`. A closure rather than a hard reference to
    /// the environment so the delegate stays constructible before the environment exists.
    var onOpen: (@MainActor (NotificationDeepLink) -> Void)?

    /// Called on the main actor with a decision notification's ledger row id the moment the app
    /// observes that notification — a foreground presentation or a tap. Set by `BADANApp` to
    /// `AppEnvironment.markNotificationDelivered`, for the same reason `onOpen` is a closure.
    ///
    /// These two moments are all iOS gives an app: a notification delivered to a lock screen while
    /// BADAN is not running, and never tapped, is simply not observable, so its row stays
    /// `scheduled`. Budget accounting is unaffected — `scheduled` and `delivered` both count.
    var onDelivered: (@MainActor (String) -> Void)?

    /// A notification arrived while BADAN was in the foreground. That IS an observed delivery, so
    /// the ledger row is closed out here as well as on a tap.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await Self.reportDelivery(notification, to: onDelivered)
        return [.banner, .sound]
    }

    /// The user tapped (or otherwise acted on) a notification. Record the delivery, then resolve its
    /// stamped deep link and hand it to `onOpen`; a notification with no/unknown deep link is
    /// dismissed without routing (the delivery is still recorded — it did arrive).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await Self.reportDelivery(response.notification, to: onDelivered)
        let info = response.notification.request.content.userInfo
        guard let raw = info[NotificationDeepLink.userInfoKey] as? String,
              let link = NotificationDeepLink(rawValue: raw) else { return }
        await onOpen?(link)
    }

    /// Hand the notification's reserved ledger row id to `sink`, if it carries one. Med reminders
    /// and the EPIC-15 automation-pause notice carry no row id (neither reserves a ledger slot), so
    /// they fall through silently rather than being attributed to some other class's row.
    private static func reportDelivery(_ notification: UNNotification,
                                       to sink: (@MainActor (String) -> Void)?) async {
        let info = notification.request.content.userInfo
        guard let rowId = info[NotificationDelivery.ledgerRowIdUserInfoKey] as? String else { return }
        await sink?(rowId)
    }
}
