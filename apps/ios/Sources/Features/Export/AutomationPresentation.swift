import SwiftUI

/// EPIC-15 — the one place a raw `AutomationTier`/`AutomationCadence`/schedule state becomes
/// something a person reads. The sibling of `ExportRunPresentation`, held to the same three rules:
///
///  1. **Never a raw token.** `opportunisticBackground` / `shortcutDriven` must never reach the
///     user — every enum resolves to a calm, bilingual sentence here (asserted total in
///     `AutomationSurfacesTests`).
///  2. **Scheduling honesty (§13.7 / plan §4.10).** The tier labels are the sanctioned wording,
///     verbatim where the plan pins it. No label promises a wall-clock time, uses the word "cron",
///     or says "guaranteed" un-caveated — a best-effort tier reads as best-effort, and the next
///     run is always ESTIMATE language ("around", "as soon as…"), never an appointment.
///  3. **Status is never colour-only (§16 a11y).** Every tier and every schedule state resolves to
///     an SF Symbol + a tint + text, so a chip built from this map carries its meaning three ways.
///
/// Kept as pure functions (no `View`, no `AppEnvironment`) so the mapping can be tested exhaustively
/// and the same copy can never drift between the wizard and the health dashboard.
enum AutomationPresentation {

    // MARK: - Tier

    /// The full, honest reliability promise — the mandatory expectation-setting the wizard shows
    /// BEFORE the user enables anything, and the detail line on a schedule row. The background and
    /// Shortcuts lines are the §13.7 sanctioned wording (the Shortcuts one verbatim, matching
    /// `IntentStrings.guideUnlockRule`); `manualOnly` makes no timing promise at all.
    static func tierLabel(_ tier: AutomationTier) -> LocalizedString {
        switch tier {
        case .opportunisticBackground:
            return LocalizedString(
                en: "Best-effort background — typically runs when your phone is active and charging. "
                    + "iOS decides when, and sometimes it doesn't.",
                ar: "في الخلفية بأفضل جهد — يعمل عادةً حين يكون هاتفك نشطاً وقيد الشحن. "
                    + "يقرّر iOS متى، وأحياناً لا يفعل.")
        case .shortcutDriven:
            return LocalizedString(
                en: "Runs at your chosen time via Shortcuts; iPhone must be unlocked. "
                    + "You set the time in the Shortcuts app — treat it as a reminder, not an appointment.",
                ar: "يعمل في الوقت الذي تختاره عبر الاختصارات؛ ويجب أن يكون الآيفون غير مقفل. "
                    + "تحدّد الوقت في تطبيق الاختصارات — اعتبره تذكيراً لا موعداً مؤكداً.")
        case .manualOnly:
            return LocalizedString(
                en: "Runs only when you tap Run now. Nothing happens on its own — you are always the trigger.",
                ar: "يعمل فقط عند ضغطك «التشغيل الآن». لا يحدث شيء من تلقاء نفسه — أنت المُشغِّل دائماً.")
        }
    }

    /// A one-word title for the tier, for the wizard's option list and card headers.
    static func tierTitle(_ tier: AutomationTier) -> LocalizedString {
        switch tier {
        case .opportunisticBackground: return LocalizedString(en: "Best-effort background", ar: "الخلفية بأفضل جهد")
        case .shortcutDriven: return LocalizedString(en: "At a set time (Shortcuts)", ar: "في وقت محدّد (الاختصارات)")
        case .manualOnly: return LocalizedString(en: "Only when I tap", ar: "فقط عند ضغطي")
        }
    }

    /// The compact chip label on a schedule row.
    static func tierChip(_ tier: AutomationTier) -> LocalizedString {
        switch tier {
        case .opportunisticBackground: return LocalizedString(en: "Best-effort", ar: "أفضل جهد")
        case .shortcutDriven: return LocalizedString(en: "Shortcuts", ar: "الاختصارات")
        case .manualOnly: return LocalizedString(en: "Manual", ar: "يدوي")
        }
    }

    /// SF Symbol for the tier — never a bare colour.
    static func tierIcon(_ tier: AutomationTier) -> String {
        switch tier {
        case .opportunisticBackground: return "arrow.triangle.2.circlepath"
        case .shortcutDriven: return "clock.badge.questionmark"
        case .manualOnly: return "hand.tap"
        }
    }

    // MARK: - Cadence

    /// How often, in ESTIMATE language. "About every…" and "when new data arrives" — never a
    /// wall-clock claim; the tier already carries the truth about whether a wake happens at all.
    static func cadenceLabel(_ cadence: AutomationCadence) -> LocalizedString {
        switch cadence {
        case .onNewData: return LocalizedString(en: "When new data arrives", ar: "عند وصول بيانات جديدة")
        case .hourlyBestEffort: return LocalizedString(en: "About every hour", ar: "كل ساعة تقريباً")
        case .dailyBestEffort: return LocalizedString(en: "About every day", ar: "كل يوم تقريباً")
        case .weeklyBestEffort: return LocalizedString(en: "About every week", ar: "كل أسبوع تقريباً")
        }
    }

    /// A short helper sentence for each cadence in the wizard's picker.
    static func cadenceHint(_ cadence: AutomationCadence) -> LocalizedString {
        switch cadence {
        case .onNewData:
            return LocalizedString(en: "Runs after your sources bring in something new to export.",
                                   ar: "يعمل بعد أن تجلب مصادرك شيئاً جديداً للتصدير.")
        case .hourlyBestEffort:
            return LocalizedString(en: "At most once an hour, when a background moment allows.",
                                   ar: "مرة كل ساعة على الأكثر، حين تسمح لحظة في الخلفية.")
        case .dailyBestEffort:
            return LocalizedString(en: "At most once a day, when a background moment allows.",
                                   ar: "مرة كل يوم على الأكثر، حين تسمح لحظة في الخلفية.")
        case .weeklyBestEffort:
            return LocalizedString(en: "At most once a week, when a background moment allows.",
                                   ar: "مرة كل أسبوع على الأكثر، حين تسمح لحظة في الخلفية.")
        }
    }

    // MARK: - Schedule status (active / paused / off)

    /// The three states a schedule can be in on the dashboard. Deliberately distinct: `paused` is
    /// the failure-budget stop (the anti-HAE visible-failure state), `off` is the user's own
    /// disable — conflating them would hide which one the user is looking at.
    enum StatusKind: Equatable {
        case active
        case paused
        case off

        var tint: Color {
            switch self {
            case .active: return BadanColor.primary
            case .paused: return BadanColor.outOfBand
            case .off: return BadanColor.textSecondary
            }
        }

        var icon: String {
            switch self {
            case .active: return "checkmark.circle.fill"
            case .paused: return "pause.circle.fill"
            case .off: return "moon.zzz.fill"
            }
        }
    }

    static func status(_ schedule: AutomationSchedule) -> StatusKind {
        if schedule.isPaused { return .paused }
        return schedule.enabled ? .active : .off
    }

    static func statusLabel(_ status: StatusKind) -> LocalizedString {
        switch status {
        case .active: return LocalizedString(en: "On", ar: "مُفعّل")
        case .paused: return LocalizedString(en: "Paused", ar: "متوقّف مؤقتاً")
        case .off: return LocalizedString(en: "Off", ar: "متوقّف")
        }
    }

    /// The VISIBLE reason a schedule paused itself — the exact never-silent-failure sentence
    /// EPIC-15 exists to guarantee. The strike count is rendered through `ValueFormatter` so the
    /// digit follows the Arabic-Indic numeral rule.
    static func pausedReason(_ format: ValueFormatter) -> LocalizedString {
        let n = format.integer(AutomationSchedule.failureBudget)
        return LocalizedString(
            en: "Paused after \(n) exports failed in a row. It won't try again on its own — resume it to let it retry.",
            ar: "توقّف بعد فشل \(n) تصديرات متتالية. لن يحاول مجدداً من تلقاء نفسه — استأنفه ليعيد المحاولة.")
    }

    // MARK: - Next expected window (always an ESTIMATE)

    /// What "next run" reads as. A closed vocabulary so the view formats a date only in the one
    /// case that has one, and so the mapping is testable without a clock. NONE of these is a
    /// promise: the time-driven case is the EARLIEST the schedule becomes eligible (a floor), not
    /// an appointment, which is why its label says "no earlier than around…".
    enum NextWindow: Equatable {
        /// `manualOnly` — there is no next time; the user is the trigger.
        case onTap
        /// `shortcutDriven` — the time lives in the user's Shortcuts automation, not here.
        case inShortcuts
        /// Background + `onNewData` — gated on data, not the clock.
        case whenNewData
        /// Background + time-driven, with a stored estimate to anchor from.
        case aroundEstimate
        /// Background + time-driven, no prior success yet — nothing to anchor an estimate to.
        case asBackgroundAllows
    }

    static func nextWindow(_ schedule: AutomationSchedule) -> NextWindow {
        switch schedule.tier {
        case .manualOnly: return .onTap
        case .shortcutDriven: return .inShortcuts
        case .opportunisticBackground:
            switch schedule.desiredCadence {
            case .onNewData:
                return .whenNewData
            case .hourlyBestEffort, .dailyBestEffort, .weeklyBestEffort:
                return schedule.nextExpectedWindow != nil ? .aroundEstimate : .asBackgroundAllows
            }
        }
    }

    /// The label for a `NextWindow`. `dateText` is the pre-formatted, localized estimate and is used
    /// ONLY by `.aroundEstimate`; passing `nil` there falls back to the un-anchored phrasing rather
    /// than printing an empty date, so a caller can never accidentally show "around ".
    static func nextWindowLabel(_ kind: NextWindow, dateText: String?) -> LocalizedString {
        switch kind {
        case .onTap:
            return LocalizedString(en: "Runs when you tap Run now", ar: "يعمل عند ضغطك «التشغيل الآن»")
        case .inShortcuts:
            return LocalizedString(en: "At the time you set in Shortcuts", ar: "في الوقت الذي تحدّده في الاختصارات")
        case .whenNewData:
            return LocalizedString(en: "Soon after new data arrives", ar: "بُعيد وصول بيانات جديدة")
        case .asBackgroundAllows:
            return LocalizedString(en: "As soon as a background moment allows",
                                   ar: "حالما تسمح لحظة في الخلفية")
        case .aroundEstimate:
            guard let dateText else {
                return LocalizedString(en: "As soon as a background moment allows",
                                       ar: "حالما تسمح لحظة في الخلفية")
            }
            return LocalizedString(en: "No earlier than around \(dateText)",
                                   ar: "ليس قبل نحو \(dateText)")
        }
    }
}
