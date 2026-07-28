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
    /// A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice). Registered for the ledger/budget
    /// vocabulary and — critically — so `NotificationScheduler.cancelDecisionNotifications(.pregnancy)`
    /// has a real identifier prefix to cancel by, per this module's own non-negotiable loss-
    /// suppression requirement: the moment a loss is declared, every locally scheduled pregnancy
    /// notification must be cancelled synchronously, in the same session, independent of the daily
    /// budget engine (`PregnancyModuleServices.declareLoss` is the caller). No producer schedules a
    /// `.pregnancy` notification in THIS P0 slice (PREG-03 ships a content shell, not real
    /// week-by-week/countdown content, so there is nothing to notify about yet) — this case exists
    /// so the cancellation plumbing is real and ready the moment a future slice adds one, per the
    /// SAME "registered for the vocabulary before a producer exists" posture `deviationNotice`/
    /// `exportHealthAlert` already establish above. Deliberately NOT in `userFacing` for the
    /// identical reason those two are absent from it.
    case pregnancy = "pregnancy"
    /// A goal the user set has been reached. Additive: `notification_deliveries.notification_class`
    /// is bare `TEXT NOT NULL` with no CHECK constraint (migration v8), so a new code needs no
    /// migration.
    ///
    /// There is deliberately no `goalAtRisk` sibling. `GoalEvaluation`'s own doc states the rule
    /// this module is held to — "There is no scoring, no streak and no judgement here by design:
    /// BADAN describes, it doesn't grade" — and telling someone they are behind while there is still
    /// time is a nudge, not a description. Reaching a goal is a fact that happened; being behind one
    /// is a verdict on the day so far.
    case goalReached = "goalReached"

    /// Medication reminders are exempt from the daily non-med budget AND are never evicted to make
    /// room for a score/hydration notice. A med reminder is a safety-relevant thing the user
    /// explicitly set up, not an ambient nudge — the whole point of the budget is to protect the
    /// user from ambient-nudge fatigue, which meds are not.
    var isMedication: Bool { self == .meds }

    /// Whether a delivery of this class consumes one unit of the daily non-med budget. Everything
    /// except meds does; this is the single predicate the daily invariant is stated against, so a
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
    /// Two classes are registered but deliberately NOT offered:
    /// - `meds` — medication reminders keep their own preference and their own section, owned by the
    ///   EXISTING `NotificationScheduler` med path rather than by this engine.
    /// - `pregnancy` — registered for the ledger vocabulary and, critically, for its cancellation
    ///   prefix, but no producer schedules it in this slice. See its own doc.
    ///
    /// `deviationNotice`, `goalReached` and `exportHealthAlert` were in that list until they gained
    /// producers — `AppEnvironment.evaluateDeviationNotice`, `evaluateGoalReached`, and the
    /// now-opt-in-gated `NotificationScheduler.notifyAutomationPaused` respectively. Note the last
    /// of those still bypasses this engine entirely and stays unbudgeted; the toggle it gained
    /// silences it, and nothing more.
    ///
    /// Add a class here in the same change that gives it a producer, never before.
    static let userFacing: [NotificationClass] = [
        .morningReadinessSummary, .eveningWindDown, .hydration,
        .deviationNotice, .goalReached, .exportHealthAlert,
    ]

    // MARK: Producer categories
    //
    // Every class BADAN offers is raised by exactly one KIND of producer, and which kind it is
    // changes how the budget must treat it. These three lists say which is which, and
    // `NotificationDecisionEngineTests` pins that they partition `userFacing` — so a class can no
    // longer be given a toggle without also being given a producer, and a producer can no longer be
    // added without the budget accounting for it. Before this, `AppEnvironment.timeBasedClasses`
    // restated the first list as a second, independent literal with nothing tying the two together.

    /// Classes reconcile pre-schedules on a daily cadence, hours before they fire.
    /// `AppEnvironment.timeBasedClasses` reads this rather than restating it.
    static let timeBased: [NotificationClass] = [.morningReadinessSummary, .eveningWindDown, .hydration]

    /// Classes raised through `AppEnvironment.raiseDecisionNotification` at the moment the thing
    /// they describe actually happens, and budgeted like any other non-med notice.
    static let eventDriven: [NotificationClass] = [.deviationNotice, .goalReached]

    /// Classes whose producer deliberately bypasses this engine and is NOT budgeted. Only
    /// `exportHealthAlert`: `NotificationScheduler.notifyAutomationPaused` raises it directly,
    /// because a paused export is a direct consequence of the user's own configuration failing —
    /// not an ambient nudge — and silently rationing it behind a wellness budget would hide a
    /// breakage the user needs to know about. It still gets an opt-in so it can be silenced.
    static let unbudgetedProducers: [NotificationClass] = [.exportHealthAlert]

    /// Which class wins a contested budget slot: LOWER goes first. This exists because the budget
    /// was previously first-come, and "first" meant nothing more principled than the order of an
    /// array literal — which is why `hydration`, always last in that literal, was starved first
    /// whenever the ceiling bound.
    ///
    /// The order runs: things that report a breakage, then the two daily anchors, then observations,
    /// then ambient nudges. `meds` sorts first and is a formality — medication reminders are exempt
    /// from the budget entirely and are never evicted — but giving it a real value keeps any sort
    /// over `allCases` total and honest rather than arbitrary.
    var priority: Int {
        switch self {
        case .meds: return 0
        case .exportHealthAlert: return 1
        case .morningReadinessSummary: return 2
        case .eveningWindDown: return 3
        case .deviationNotice: return 4
        case .goalReached: return 5
        case .hydration: return 6
        case .pregnancy: return 7
        }
    }

    /// The evidence surface a tap opens (plan §12 EPIC-32 task 4: "deep links to evidence screens").
    var deepLink: NotificationDeepLink {
        switch self {
        case .morningReadinessSummary: return .readiness
        case .eveningWindDown: return .sleep
        case .deviationNotice: return .healthMonitor
        case .exportHealthAlert: return .exportHealth
        case .hydration: return .hydration
        case .meds: return .meds
        case .pregnancy: return .pregnancy
        case .goalReached: return .goals
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
    /// Goals live on the Settings surface (`GoalsSettingsScreen`), so this resolves to that tab.
    case goals
    /// A18/ADR-0010/D-25 (EPIC-40). See `NotificationClass.pregnancy`'s own doc — no producer opens
    /// this deep link yet in this P0 slice; it exists so `NotificationClass.pregnancy.deepLink`
    /// resolves to something real.
    case pregnancy

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
        case .hydration, .meds, .pregnancy: return .log   // the pregnancy tile lives on Log, like cycle's.
        case .goals: return .settings   // `GoalsSettingsScreen` is reached from Settings.
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

/// The limits the decision engine enforces. `systemPendingLimit` is iOS's 64-pending ceiling,
/// shared verbatim with the med scheduler so the two never double-count a slot.
///
/// The daily anti-fatigue budget used to live here as a fixed `dailyNonMedLimit = 2`, described in
/// this file and two others as "a hard invariant, not a preference". It is now a user preference —
/// `NotificationPreference.dailyNonMedLimit`, clamped to `dailyNonMedLimitRange` (1…4) — and only
/// its DEFAULT survives here. The reason is stated in full on that property: a fixed 2 stopped being
/// an anti-fatigue measure and became a two-class ceiling the moment there were more than two
/// classes to spend it on. What still makes the budget safe is the clamp plus
/// `NotificationClass.priority`, so the ceiling is never merely first-come.
enum NotificationBudget {
    /// The DEFAULT daily ceiling on non-medication notifications, forwarded from the preference
    /// that owns it (single source of truth, the same way `systemPendingLimit` forwards to
    /// `MedicationReminderPlan`). The effective limit for a real decision is
    /// `Context.dailyNonMedLimit`, which the adapter fills from the user's profile.
    static var defaultDailyNonMedLimit: Int { NotificationPreference.defaultDailyNonMedLimit }

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
        /// The daily non-med budget for the candidate's day is already spent.
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
        /// This exists because the daily ceiling is a HARD invariant (plan §12 EPIC-32) and the
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
        /// The ceiling this decision is measured against. Defaults to the shipped default, but the
        /// adapter fills it from `profile.notifications.dailyNonMedLimit` — and passes a value one
        /// LOWER than that for a time-based class when an event-driven class is also enabled (see
        /// `timeBasedLimit`).
        var dailyNonMedLimit: Int = NotificationBudget.defaultDailyNonMedLimit
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

        // The daily invariant applies only to budgeted (non-med) classes.
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
    /// budget holds even when many candidates arrive at once (the "budget holds under load"
    /// acceptance case). Candidates are assumed to target the SAME budget day — the caller builds one batch
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

    // MARK: - The floating slot

    /// The ceiling the TIME-BASED classes may consume, given the user's full daily limit.
    ///
    /// Pre-scheduled classes reserve their ledger row hours before an event-driven class can
    /// possibly fire — the morning summary claims tomorrow's slot tonight — so on a plain
    /// first-come budget an event-driven class never gets a slot at all and its toggle is a dead
    /// switch. `NotificationClass.userFacing`'s own doc forbids exactly that: "a toggle is a
    /// promise". So when any event-driven class is enabled, one slot floats: the time-based classes
    /// may take at most `dailyLimit - 1`, and the last one is held for whatever actually happens
    /// that day. If nothing happens, one nudge is skipped — the conservative failure, and the same
    /// trade the ledger-reservation ordering already makes.
    ///
    /// Never returns less than 1: reserving a floating slot must not silence the time-based classes
    /// outright for a user who set the ceiling to 1.
    static func timeBasedLimit(dailyLimit: Int, reserveFloatingSlot: Bool) -> Int {
        guard reserveFloatingSlot else { return dailyLimit }
        return max(1, dailyLimit - 1)
    }

    // MARK: - 64-cap interplay (the med side)

    /// The number of pending slots medication reminders may claim, after reserving room for the
    /// non-med notices currently pending. Called by `NotificationScheduler.rescheduleMedicationReminders`
    /// so meds + decision notices together never exceed the ceiling.
    ///
    /// Because non-med notices are capped per day by `Context.dailyNonMedLimit` and are one-shots
    /// that clear as they fire, this reservation is a handful of slots at most — meds keep ≥60 of 64
    /// even at the widest ceiling the user can set (`NotificationPreference.dailyNonMedLimitRange`'s
    /// upper bound of 4; it was ≥62 when that ceiling was a fixed 2), and the full 64 whenever no
    /// non-med notice is pending, which is the default since every non-med class ships OFF. So this
    /// is NOT starvation: the med cap keeps the SOONEST reminders and rolls the window forward on
    /// every reschedule (see `MedicationReminderPlan.capped`), and losing a few of the furthest-out
    /// repeating slots to a notice the user explicitly opted into is the correct trade — the
    /// alternative is the OS silently dropping meds when the total crosses 64.
    ///
    /// That the reservation is bounded at all is exactly why the daily ceiling stayed clamped when
    /// it became a preference: an unbounded limit here would be an unbounded bite out of meds.
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
/// The readings a notification may name on the lock screen, when — and only when — the user has
/// turned `NotificationPreference.showValuesInNotifications` on.
///
/// Every field arrives ALREADY FORMATTED in both languages. The producer builds them, because it is
/// the only layer that knows the user's numeral shapes and unit preferences (`ValueFormatter`);
/// this copy layer never formats a number itself, so there is no second, drifting implementation of
/// how BADAN renders one.
///
/// Naming discipline, which is the whole reason these fields are spelled out rather than lumped
/// into one "score": there is NO 0–100 sleep score in this app. `SleepIntelligenceEngine` produces
/// `sleep.performance` (actual ÷ need, a percentage) and `sleep.consistency` (0–100 timing
/// regularity) as separate outputs, and `registry.json` reserves a `sleep.score` id that has no
/// algorithm entry and no producer at all. Copy that said "sleep score" would name a metric this
/// app does not compute.
struct NotificationValues: Equatable, Sendable {
    /// Readiness, already rendered (e.g. "Readiness 68" / "الجاهزية ٦٨").
    var readiness: LocalizedString?
    /// Sleep performance against need, already rendered — never called a score.
    var sleepPerformance: LocalizedString?
    /// A reached goal, already rendered.
    var goal: LocalizedString?

    var isEmpty: Bool { readiness == nil && sleepPerformance == nil && goal == nil }

    /// The value phrase that prefixes `cls`'s body, or `nil` when this class has nothing to say —
    /// in which case the caller falls back to the value-free copy rather than emitting a dangling
    /// separator or an empty sentence.
    ///
    /// Only the classes that genuinely have a reading behind them appear here. A class absent from
    /// this switch stays value-free even for an opted-in user, which is the honest outcome: opting
    /// in is permission to show a number, not a promise that one exists.
    ///
    func lead(for cls: NotificationClass) -> LocalizedString? {
        switch cls {
        case .morningReadinessSummary:
            return Self.join([readiness, sleepPerformance])
        case .goalReached:
            return goal
        default:
            return nil
        }
    }

    /// Join the present phrases with a middot, per language, ending in a full stop.
    private static func join(_ parts: [LocalizedString?]) -> LocalizedString? {
        let present = parts.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return LocalizedString(en: present.map(\.en).joined(separator: " · ") + ".",
                               ar: present.map(\.ar).joined(separator: " · ") + ".")
    }
}

enum NotificationClassCopy {
    /// The lock-screen content (title + body) for a delivered notification of `cls`. `meds` is
    /// handled by the existing `MedicationReminderCopy`; asking here returns it so callers have one
    /// entry point.
    /// - Parameter values: the readings the user has explicitly opted to see on the lock screen
    ///   (`NotificationPreference.showValuesInNotifications`). `nil` — the default, and the only
    ///   thing every existing caller passes — returns the value-free copy BYTE-FOR-BYTE, because
    ///   this function delegates straight to `valueFreeContent` in that case rather than
    ///   re-deriving the strings. That is a structural guarantee, not a promise to keep two copies
    ///   of the wording in step.
    static func content(_ cls: NotificationClass,
                        values: NotificationValues? = nil) -> (title: LocalizedString, body: LocalizedString) {
        let base = valueFreeContent(cls)
        guard let values, let lead = values.lead(for: cls) else { return base }
        // The value line PREFIXES the existing sentence rather than replacing it, so the calm
        // register is inherited instead of re-invented for the opted-in variant.
        return (base.title, LocalizedString(en: "\(lead.en) \(base.body.en)",
                                            ar: "\(lead.ar) \(base.body.ar)"))
    }

    /// The lock-screen content that names no reading. This is what the app has always sent and what
    /// every opted-out user keeps receiving.
    static func valueFreeContent(_ cls: NotificationClass) -> (title: LocalizedString, body: LocalizedString) {
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
        case .pregnancy:
            // No producer schedules this class in the P0 slice (see `NotificationClass.pregnancy`'s
            // own doc) — copy exists so the class is fully wired and this switch stays exhaustive.
            // Deliberately generic and calm, never assuming a mode (never "your baby" / week-number
            // language that could be stale or wrong the instant a loss is declared) — the same
            // register discipline the rest of this enum already follows.
            return (title, LocalizedString(
                en: "There's an update in your pregnancy tracking.",
                ar: "هناك تحديث في متابعة حملك."))
        case .goalReached:
            // States the fact and stops. No "Well done", no "Congratulations", no streak, no badge,
            // no emoji — `GoalEvaluation`'s doc is explicit that BADAN describes rather than grades,
            // and praise for hitting a number is grading with a friendlier face. It also implies the
            // inverse on every day the goal is missed, which is the part that does the damage.
            return (title, LocalizedString(
                en: "You reached a goal you set today.",
                ar: "بلغت اليوم هدفاً حدّدته."))
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
        case .pregnancy:
            return (LocalizedString(en: "Pregnancy tracking updates", ar: "تحديثات متابعة الحمل"),
                    LocalizedString(en: "Not available in this version yet.",
                                    ar: "غير متاحة في هذا الإصدار بعد."))
        case .goalReached:
            // The hint used to end "Never a score or a streak." — reassuring, but it named the two
            // things this class exists to avoid, and `testGoalCopyDoesNotCongratulateOrScore`
            // rightly failed on it. Stating what BADAN does, without planting what it doesn't, is
            // the better copy and keeps the test's ban absolute rather than carved out.
            return (LocalizedString(en: "Goal reached", ar: "بلوغ الهدف"),
                    LocalizedString(en: "A note when you reach a goal you set. Nothing is ranked or compared.",
                                    ar: "ملاحظة عند بلوغك هدفاً حدّدته. دون ترتيب أو مقارنة."))
        }
    }

    /// The daily-budget explanation shown in Settings when a class is on but the ceiling held a
    /// notice back. Wellness-safe: a budget is a kindness, not a failure.
    ///
    /// `count` is the user's own `NotificationPreference.dailyNonMedLimit`, passed in rather than
    /// read from a constant here — the ceiling is a preference now, and a sentence that quoted a
    /// fixed 2 while the engine enforced the user's 4 would be a lie in the one place the user goes
    /// to understand the rule.
    ///
    /// The count goes through `ReportPresentation.countedNoun` rather than being interpolated
    /// straight into the sentence, because Arabic does not simply pluralise: at 1 the noun takes the
    /// singular accusative, at 2 the DUAL ("إشعارين", which carries the two by itself and wants no
    /// numeral in front of it), and a bare "\(n) إشعارات" is wrong at every count below 3. The 1…4
    /// range this is now called with is exactly the range that rule already covers correctly. It is
    /// the same agreement rule the reports surface applies, so it is reused rather than re-derived —
    /// and `arabicDigits` is threaded through for the same reason every other number in the app is:
    /// the digit shapes follow the user's preference, not this call site.
    static func dailyBudgetNote(count: Int, arabicDigits: Bool) -> LocalizedString {
        func notices(_ language: AppLanguage) -> String {
            ReportPresentation.countedNoun(
                count, language: language, arabicDigits: arabicDigits,
                enSingular: "notification", enPlural: "notifications",
                arOne: "إشعاراً واحداً", arTwo: "إشعارين", arFew: "إشعارات", arMany: "إشعاراً")
        }
        return LocalizedString(
            en: "BADAN sends at most \(notices(.en)) of this kind a day, so it never crowds your lock screen.",
            ar: "يرسل «بدن» \(notices(.ar)) من هذا النوع في اليوم كحدّ أقصى، حتى لا يزدحم قفل شاشتك.")
    }
}
