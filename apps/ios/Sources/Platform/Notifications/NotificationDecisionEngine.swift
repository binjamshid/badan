import Foundation

// MARK: - Class registry (EPIC-32)

/// The notification classes BADAN can raise. This is the registry the whole decision layer is
/// built around: budget, opt-in, quiet hours and the 64-pending cap all reason in terms of a
/// `NotificationClass`, and the storage ledger (`notification_deliveries`) records one row per
/// class per delivery.
///
/// The raw values are the STORAGE CODES — byte-identical to the strings migration v8 documents
/// (`readiness|windDown|deviation|exportHealth|hydration|meds`) and to the Android
/// `NotificationClass` enum. They are the ledger's `notification_class` values, so renaming a case
/// is a schema-visible change, not a refactor.
///
/// `meds` is a first-class member of the registry even though the EXISTING `NotificationScheduler`
/// med-reminder path — not this engine — actually schedules medication reminders. It is registered
/// so the budget/cap accounting can see it (a med reminder occupies a pending slot like any other),
/// and so a single vocabulary covers every notification BADAN sends. EPIC-32 EXTENDS the med
/// scheduler; it never replaces it.
enum NotificationClass: String, CaseIterable, Sendable {
    case morningReadinessSummary = "readiness"
    case eveningWindDown = "windDown"
    case deviationNotice = "deviation"
    case exportHealthAlert = "exportHealth"
    case hydration = "hydration"
    case meds = "meds"

    /// Medication reminders are exempt from the ≤2/day non-med budget AND are never evicted to make
    /// room for a score/hydration notice. A med reminder is a safety-relevant thing the user
    /// explicitly set up, not an ambient nudge — the whole point of the budget is to protect the
    /// user from ambient-nudge fatigue, which meds are not.
    var isMedication: Bool { self == .meds }

    /// Whether a delivery of this class consumes one unit of the daily non-med budget. Everything
    /// except meds does; this is the single predicate the ≤2/day invariant is stated against, so a
    /// future class is budgeted by default the moment it is added.
    var countsAgainstDailyBudget: Bool { !isMedication }

    /// The pending-request identifier prefix for this class. Meds reuse the EXISTING
    /// `MedicationReminderPlan.identifierPrefix` (so the med scheduler stays the single owner of med
    /// request identifiers); every other class shares `decision.` so the engine can find, count and
    /// cancel its own requests by prefix without ever touching a med reminder or the EPIC-15
    /// automation-pause notice.
    var identifierPrefix: String {
        isMedication ? MedicationReminderPlan.identifierPrefix : "\(Self.decisionPrefix)\(rawValue)."
    }

    /// Shared prefix for every non-med decision-engine request. A pending request with this prefix
    /// is one this engine scheduled; anything without it (med reminders, automation-pause notices)
    /// belongs to another owner and is left alone.
    static let decisionPrefix = "decision."

    /// The classes the Notifications settings surface offers, in display order — exactly those a
    /// producer in the app can actually schedule. A toggle is a promise, so a class earns a row here
    /// only once something raises it. Mirrors Android's `NotificationClass.userFacing`.
    ///
    /// Three classes are registered but deliberately NOT offered:
    /// - `meds` — medication reminders keep their own preference and their own section, owned by the
    ///   EXISTING `NotificationScheduler` med path rather than by this engine.
    /// - `deviationNotice` and `exportHealthAlert` — registered for the ledger/budget vocabulary and
    ///   for their deep links, but no code path raises either yet. They are event-driven by design
    ///   and `AppEnvironment.raiseDecisionNotification` is the seam waiting for a producer; until a
    ///   detector calls it, a toggle would promise a notice that never arrives. The automation-pause
    ///   notice is NOT that producer — it is unbudgeted and ungated, and merely borrows
    ///   `exportHealthAlert`'s deep link (see `NotificationScheduler.notifyAutomationPaused`).
    ///
    /// Add a class here in the same change that gives it a producer, never before.
    static let userFacing: [NotificationClass] = [.morningReadinessSummary, .eveningWindDown, .hydration]

    /// The evidence surface a tap opens (plan §12 EPIC-32 task 4: "deep links to evidence screens").
    var deepLink: NotificationDeepLink {
        switch self {
        case .morningReadinessSummary: return .readiness
        case .eveningWindDown: return .sleep
        case .deviationNotice: return .healthMonitor
        case .exportHealthAlert: return .exportHealth
        case .hydration: return .hydration
        case .meds: return .meds
        }
    }
}

// MARK: - Deep links

/// Where tapping a notification takes the user. Kept deliberately coarse — a destination the app
/// can always honour (a top-level surface) — and stamped into every request's `userInfo` so the
/// notification-response handler can route without parsing copy. The raw value is a stable token
/// (it rides in `userInfo`, so it is a small contract with the delegate, not free text).
enum NotificationDeepLink: String, Sendable, Equatable, CaseIterable {
    case readiness
    case sleep
    case healthMonitor
    case exportHealth
    case hydration
    case meds

    /// The `userInfo` key the request carries and the response handler reads.
    static let userInfoKey = "badan.deeplink"

    /// The tab the deep link resolves to. Routing is at TAB granularity: every destination here is
    /// a top-level surface that always exists, so a tap always lands somewhere meaningful even
    /// before EPIC-33 introduces the shared navigation-path plumbing that would let a tap push the
    /// exact detail screen (readiness detail, the Health Monitor, the Export & Automation Health
    /// screen). This is stated plainly rather than a comment promising a push the code does not do.
    var tab: MainTab {
        switch self {
        case .readiness, .sleep: return .today
        case .healthMonitor: return .body
        case .exportHealth: return .today   // Export Center is reached from Home (Today).
        case .hydration, .meds: return .log
        }
    }
}

/// The five root destinations, in `MainTabView` order. An enum (rather than a bare `Int`) so a
/// deep link resolves to a named tab and the tag on each tab is type-checked against it.
enum MainTab: Int, Sendable, CaseIterable {
    case today = 0
    case body = 1
    case log = 2
    case insights = 3
    case settings = 4
}

// MARK: - Quiet hours evaluation

extension NotificationQuietHours {
    /// Whether `date`'s local hour falls inside this quiet window. A window where
    /// `startHour == endHour` is empty (never quiet); a window that wraps midnight
    /// (`startHour > endHour`, e.g. 22→07) is handled explicitly.
    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour   // wraps past midnight
    }
}

// MARK: - Budget constants

/// The hard limits the decision engine enforces. `dailyNonMedLimit` is the anti-fatigue budget
/// (plan §12 EPIC-32: "Default ≤2/day … budget is a hard invariant, not a preference");
/// `systemPendingLimit` is iOS's 64-pending ceiling, shared verbatim with the med scheduler so the
/// two never double-count a slot.
enum NotificationBudget {
    /// At most this many NON-medication notifications may be scheduled/delivered per local day,
    /// across ALL non-med classes combined. Not a preference — the user can turn classes off, but
    /// cannot raise this ceiling.
    static let dailyNonMedLimit = 2

    /// The OS keeps at most this many pending requests per app and silently drops the rest. Shared
    /// with `MedicationReminderPlan.systemPendingLimit` (the single source of truth) so meds and
    /// decision notices are always counted against ONE ceiling.
    static var systemPendingLimit: Int { MedicationReminderPlan.systemPendingLimit }
}

// MARK: - The pure decision engine

/// The side-effect-free core of EPIC-32: given a candidate notification and a snapshot of the
/// current state (opt-in, quiet hours, today's non-med ledger count, pending med/non-med counts),
/// it decides whether the candidate may be scheduled and, if not, WHY. It touches no
/// `UNUserNotificationCenter`, no database and no clock — everything it needs is passed in — so the
/// budget, the opt-in matrix and the 64-cap interplay are all unit-testable without a device.
///
/// The scheduler adapter (`NotificationScheduler`) is the thin I/O shell that gathers the inputs,
/// asks this engine, and turns a `.scheduled` verdict into a real request plus a ledger row — the
/// same pure-core / thin-adapter split `MedicationReminderPlan` / `NotificationScheduler` already use.
enum NotificationDecisionEngine {

    /// The verdict for one candidate. Every non-`scheduled` case names the specific reason so the
    /// scheduler can record it and tests can assert the *why*, not just the *whether*.
    enum Decision: Equatable {
        case scheduled
        /// The user has not opted this class in (all classes default OFF).
        case suppressedOptedOut
        /// The candidate's fire time falls inside this class's quiet-hours window.
        case suppressedQuietHours
        /// The ≤2/day non-med budget for the candidate's day is already spent.
        case suppressedDailyBudget
        /// Scheduling would exceed the 64-pending ceiling shared with med reminders. Meds win.
        case suppressedSystemCap
        /// Notifications are not authorized, so nothing would arrive. Raised by the SCHEDULER
        /// ADAPTER, never by `decide` — authorization is an I/O fact the pure engine cannot see, and
        /// reporting it as "opted out" would name the wrong reason for a caller or a test.
        case suppressedNotAuthorized
        /// The budget ledger could not reserve a slot (the `notification_deliveries` insert failed),
        /// so nothing was handed to the OS. Also an ADAPTER verdict, for the same reason as
        /// `suppressedNotAuthorized`: storage is an I/O fact `decide` is never handed.
        ///
        /// This exists because the ≤2/day ceiling is a HARD invariant (plan §12 EPIC-32) and the
        /// ledger is the only thing that remembers it across process death. A notification that
        /// fired without a ledger row would let the next evaluation read a lower count and push the
        /// day past 2 — so the adapter reserves the slot FIRST and, if it cannot, declines to
        /// schedule rather than degrading the budget open. Failing closed loses at most one
        /// wellness nudge; failing open breaks the invariant the user cannot see being broken.
        case suppressedLedgerUnavailable

        var didSchedule: Bool { self == .scheduled }
    }

    /// One notification the engine is asked to consider.
    struct Candidate: Equatable {
        let notificationClass: NotificationClass
        /// When the notification would fire. Both the quiet-hours check and the day the daily
        /// budget is measured over are taken from this instant, in the provided calendar.
        let fireDate: Date

        init(_ notificationClass: NotificationClass, fireDate: Date) {
            self.notificationClass = notificationClass
            self.fireDate = fireDate
        }
    }

    /// The state the decision is made against. The three count fields are what the scheduler reads
    /// from the ledger and the notification center immediately before deciding; `decideBatch`
    /// advances them as it accepts candidates so a single evaluation cannot blow the budget.
    struct Context {
        var calendar: Calendar
        /// Whether the user has enabled a given class. Meds map to the existing
        /// `medicationReminders` preference; the rest to the per-class opt-in map.
        var optedIn: (NotificationClass) -> Bool
        /// The quiet-hours window for a given class, or `nil` for "no quiet hours".
        var quietHours: (NotificationClass) -> NotificationQuietHours?
        /// How many budgeted (non-med) notifications are already scheduled/delivered for the
        /// candidate day, read from the `notification_deliveries` ledger.
        var nonMedScheduledToday: Int
        /// Pending med reminders right now. Meds are never evicted for a non-med notice, so a
        /// non-med candidate only takes a slot the meds are not using.
        var pendingMedCount: Int
        /// Pending non-med (decision-engine) requests right now.
        var pendingNonMedCount: Int
        var dailyNonMedLimit: Int = NotificationBudget.dailyNonMedLimit
        var systemPendingLimit: Int = NotificationBudget.systemPendingLimit
    }

    /// Decide a single candidate. Order matters: opt-in first (a class the user turned off is never
    /// even considered), then quiet hours, then the daily budget, then the shared system cap.
    static func decide(_ candidate: Candidate, in context: Context) -> Decision {
        let cls = candidate.notificationClass

        guard context.optedIn(cls) else { return .suppressedOptedOut }

        if let window = context.quietHours(cls), window.contains(candidate.fireDate, calendar: context.calendar) {
            return .suppressedQuietHours
        }

        // The ≤2/day invariant applies only to budgeted (non-med) classes.
        if cls.countsAgainstDailyBudget, context.nonMedScheduledToday >= context.dailyNonMedLimit {
            return .suppressedDailyBudget
        }

        // 64-cap interplay. A non-med notice may only take a slot the meds are not already using:
        // meds + non-med together must never exceed the ceiling, and meds are never pushed out to
        // fit a non-med one. Meds themselves never fail this check (they are scheduled by the med
        // path, which caps ITSELF against the same ceiling — see `medPendingLimit`).
        if cls.countsAgainstDailyBudget,
           context.pendingMedCount + context.pendingNonMedCount >= context.systemPendingLimit {
            return .suppressedSystemCap
        }

        return .scheduled
    }

    /// Decide a batch in one pass, advancing the running counts as candidates are accepted so the
    /// budget holds even when many candidates arrive at once (the "≤2/day under load" acceptance
    /// case). Candidates are assumed to target the SAME budget day — the caller builds one batch
    /// per day/evaluation — so `nonMedScheduledToday` is a single counter.
    static func decideBatch(_ candidates: [Candidate], in context: Context) -> [(Candidate, Decision)] {
        var ctx = context
        var results: [(Candidate, Decision)] = []
        for candidate in candidates {
            let decision = decide(candidate, in: ctx)
            if decision == .scheduled, candidate.notificationClass.countsAgainstDailyBudget {
                ctx.nonMedScheduledToday += 1
                ctx.pendingNonMedCount += 1
            }
            results.append((candidate, decision))
        }
        return results
    }

    // MARK: - 64-cap interplay (the med side)

    /// The number of pending slots medication reminders may claim, after reserving room for the
    /// non-med notices currently pending. Called by `NotificationScheduler.rescheduleMedicationReminders`
    /// so meds + decision notices together never exceed the ceiling.
    ///
    /// Because non-med notices are capped at ≤2/day and are one-shots that clear as they fire, this
    /// reservation is at most a couple of slots — meds keep ≥62 of 64 in the worst case, and the
    /// full 64 whenever no non-med notice is pending (the default, since every non-med class ships
    /// OFF). So this is NOT starvation: the med cap keeps the SOONEST reminders and rolls the window
    /// forward on every reschedule (see `MedicationReminderPlan.capped`), and losing at most two of
    /// the furthest-out repeating slots to a notice the user explicitly opted into is the correct
    /// trade — the alternative is the OS silently dropping meds when the total crosses 64.
    static func medPendingLimit(nonMedPending: Int,
                                systemLimit: Int = NotificationBudget.systemPendingLimit) -> Int {
        max(0, systemLimit - nonMedPending)
    }
}

// MARK: - Copy (bilingual, wellness-safe, privacy-first)

/// Every string a decision-engine notification or its settings row shows. Two rules govern all of
/// it: the delivered BODY names no health value (nothing legible on a lock screen — the same
/// discipline `MedicationReminderCopy` follows), and the register is calm and never alarmist
/// (D-11 wellness language) — a shifted reading is "a little different", never "abnormal". Copy is
/// hand-written in both languages, not machine-literal.
enum NotificationClassCopy {
    /// The lock-screen content (title + body) for a delivered notification of `cls`. `meds` is
    /// handled by the existing `MedicationReminderCopy`; asking here returns it so callers have one
    /// entry point.
    static func content(_ cls: NotificationClass) -> (title: LocalizedString, body: LocalizedString) {
        let title = LocalizedString(en: "BADAN", ar: "بدن")
        switch cls {
        case .morningReadinessSummary:
            return (title, LocalizedString(
                en: "Your morning check-in is ready whenever you are.",
                ar: "ملخّص صباحك جاهز متى شئت."))
        case .eveningWindDown:
            return (title, LocalizedString(
                en: "A calm moment to start winding down for the night.",
                ar: "لحظة هادئة لتبدأ الاستعداد للنوم."))
        case .deviationNotice:
            return (title, LocalizedString(
                en: "A recent reading looks a little different from your usual. Open BADAN when it suits you.",
                ar: "بدت إحدى قراءاتك الأخيرة مختلفة قليلاً عن معتادك. افتح «بدن» متى ناسبك."))
        case .exportHealthAlert:
            return (title, LocalizedString(
                en: "One of your automatic exports could use a quick look.",
                ar: "يحتاج أحد تصديراتك التلقائية إلى نظرة سريعة."))
        case .hydration:
            return (title, LocalizedString(
                en: "A gentle reminder to have some water.",
                ar: "تذكير لطيف لشرب بعض الماء."))
        case .meds:
            return (MedicationReminderCopy.title, MedicationReminderCopy.body)
        }
    }

    /// The Settings → Notifications row (label + hint) for `cls`. `meds` reuses the existing
    /// `SettingsStrings.notifMeds`/`notifMedsSubtitle` at the call site, so it is not duplicated here.
    static func settingsRow(_ cls: NotificationClass) -> (label: LocalizedString, hint: LocalizedString) {
        switch cls {
        case .morningReadinessSummary:
            return (LocalizedString(en: "Morning summary", ar: "ملخّص الصباح"),
                    LocalizedString(en: "A short check-in each morning. No readings shown on the lock screen.",
                                    ar: "ملخّص قصير كل صباح. لا تظهر أي قراءات على شاشة القفل."))
        case .eveningWindDown:
            return (LocalizedString(en: "Evening wind-down", ar: "استرخاء المساء"),
                    LocalizedString(en: "A calm nudge to ease into the evening.",
                                    ar: "تذكير هادئ للاستعداد لأمسيتك."))
        case .deviationNotice:
            return (LocalizedString(en: "Gentle change notices", ar: "تنبيهات لطيفة للتغيّرات"),
                    LocalizedString(en: "An occasional heads-up when a reading drifts from your usual.",
                                    ar: "تنبيه من حين لآخر عندما تبتعد قراءة عن معتادك."))
        case .exportHealthAlert:
            return (LocalizedString(en: "Export health alerts", ar: "تنبيهات حالة التصدير"),
                    LocalizedString(en: "A heads-up if an automatic export needs your attention.",
                                    ar: "تنبيه إذا احتاج تصدير تلقائي إلى انتباهك."))
        case .hydration:
            return (LocalizedString(en: "Water reminders", ar: "تذكيرات شرب الماء"),
                    LocalizedString(en: "A gentle, occasional nudge to drink some water.",
                                    ar: "تذكير لطيف من حين لآخر لشرب بعض الماء."))
        case .meds:
            return (LocalizedString(en: "Medication reminders", ar: "تذكيرات الأدوية"),
                    LocalizedString(en: "A gentle nudge at your usual times. No names appear on the lock screen.",
                                    ar: "تذكير لطيف في أوقاتك المعتادة. لا تظهر أي أسماء على شاشة القفل."))
        }
    }

    /// The daily-budget explanation shown in Settings when a class is on but the ≤2/day ceiling
    /// held a notice back. Wellness-safe: a budget is a kindness, not a failure.
    ///
    /// The count goes through `ReportPresentation.countedNoun` rather than being interpolated
    /// straight into the sentence, because Arabic does not simply pluralise: at the current limit of
    /// 2 the noun takes the DUAL ("إشعارين", which carries the two by itself and wants no numeral in
    /// front of it), and a bare "\(n) إشعارات" is wrong at every count below 3. That is the same
    /// agreement rule the reports surface already applies, so it is reused rather than re-derived —
    /// and `arabicDigits` is threaded through for the same reason every other number in the app is:
    /// the digit shapes follow the user's preference, not this call site.
    static func dailyBudgetNote(arabicDigits: Bool) -> LocalizedString {
        func notices(_ language: AppLanguage) -> String {
            ReportPresentation.countedNoun(
                NotificationBudget.dailyNonMedLimit, language: language, arabicDigits: arabicDigits,
                enSingular: "notification", enPlural: "notifications",
                arOne: "إشعاراً واحداً", arTwo: "إشعارين", arFew: "إشعارات", arMany: "إشعاراً")
        }
        return LocalizedString(
            en: "BADAN sends at most \(notices(.en)) of this kind a day, so it never crowds your lock screen.",
            ar: "يرسل «بدن» \(notices(.ar)) من هذا النوع في اليوم كحدّ أقصى، حتى لا يزدحم قفل شاشتك.")
    }
}
