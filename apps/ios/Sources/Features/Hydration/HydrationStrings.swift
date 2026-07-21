import Foundation

/// Bilingual (en + ar) copy for the hydration surfaces (EPIC-38). Shared vocabulary (Save, Cancel,
/// Undo, Today, Water, …) comes from `Loc`; these fill the module-specific gaps with real, natural
/// Arabic.
///
/// COPY DISCIPLINE (§7A.1 rejects, imported verbatim into wording): nothing here is prescriptive,
/// urgent, or guilt-laden. There is no "you're behind", no "dehydration", no streak, no percentage
/// of a no-goal day. Goal wording is only ever "your tracking goal". The weekly card is a plain
/// observational count ("logged drinks on 5 of 7 days"), never a score or a judgment. A beverage's
/// caffeine/alcohol/electrolyte metadata is never surfaced as a hydration weight — a logged mL is a
/// logged mL regardless of what was in the cup.
enum HydrationStrings {
    // Module identity. "السوائل" (fluids) reads as neutral fluid-intake tracking in Arabic, avoiding
    // the skincare connotation "ترطيب" carries.
    static let moduleTitle = LocalizedString(en: "Hydration", ar: "السوائل")

    static let ml = LocalizedString(en: "mL", ar: "مل")

    // Logging
    static let addDrink = LocalizedString(en: "Add a drink", ar: "أضف مشروبًا")
    static let editDrinkTitle = LocalizedString(en: "Edit drink", ar: "تعديل المشروب")
    static let custom = LocalizedString(en: "Custom", ar: "مخصّص")
    static let customAmount = LocalizedString(en: "Custom amount", ar: "كمية مخصصة")
    static let amount = LocalizedString(en: "Amount", ar: "الكمية")
    static let drink = LocalizedString(en: "Drink", ar: "المشروب")
    static let time = LocalizedString(en: "Time", ar: "الوقت")
    static let noteOptional = LocalizedString(en: "Note (optional)", ar: "ملاحظة (اختياري)")
    static let noteRedactionHint = LocalizedString(
        en: "Notes stay on your device — they're left out of the default export.",
        ar: "تبقى الملاحظات على جهازك — ولا تُدرج في التصدير الافتراضي.")
    static let saveFailed = LocalizedString(en: "Couldn't save. Try again.", ar: "تعذّر الحفظ. حاول مرة أخرى.")
    // Soft, non-blocking plausibility notice — mirrors WaterQuickSheet/EDGE-15. Never blocks Save.
    static let implausibleNotice = LocalizedString(
        en: "That's a lot for one drink — double-check it.",
        ar: "هذه كمية كبيرة لمشروب واحد — تحقّق منها.")
    static let editedBadge = LocalizedString(en: "Edited", ar: "مُعدّل")

    // Favorites (container presets)
    static let favorites = LocalizedString(en: "Favorites", ar: "المفضّلة")
    static let saveFavorite = LocalizedString(en: "Save as favorite", ar: "حفظ كمفضّلة")
    static let favoriteName = LocalizedString(en: "Favorite name", ar: "اسم المفضّلة")
    static let deleteFavorite = LocalizedString(en: "Delete favorite", ar: "حذف المفضّلة")
    static let defaultGlassName = LocalizedString(en: "Glass", ar: "كوب")
    static let defaultBottleName = LocalizedString(en: "Bottle", ar: "قنينة")

    // Progress
    static let loggedToday = LocalizedString(en: "logged today", ar: "سُجّل اليوم")
    static let seeAll = LocalizedString(en: "See all", ar: "عرض الكل")
    static let todaysDrinks = LocalizedString(en: "Today's drinks", ar: "مشروبات اليوم")
    static let noDrinksYet = LocalizedString(en: "No drinks logged today yet.", ar: "لم تُسجَّل مشروبات اليوم بعد.")
    static let recentDrinks = LocalizedString(en: "Recent", ar: "الأخيرة")
    static let couldntLoad = LocalizedString(
        en: "Couldn't load hydration right now.", ar: "تعذّر تحميل السوائل الآن.")

    // Goal
    static let yourTrackingGoal = LocalizedString(en: "Your tracking goal", ar: "هدف التتبّع")
    static let goalAndSettings = LocalizedString(en: "Goal & settings", ar: "الهدف والإعدادات")
    static let noGoal = LocalizedString(en: "No goal", ar: "بدون هدف")
    static let noGoalDescription = LocalizedString(
        en: "Track your drinks without a target — nothing to reach, nothing to miss.",
        ar: "تتبّع مشروباتك بدون هدف — لا شيء لتبلغه، ولا شيء يفوتك.")
    static let setAGoal = LocalizedString(en: "Set a daily amount", ar: "حدّد كمية يومية")
    static let dailyAmount = LocalizedString(en: "Daily amount", ar: "الكمية اليومية")
    static let goalHelp = LocalizedString(
        en: "A gentle number to track against. You can change or remove it anytime.",
        ar: "رقم لطيف لتتبّع تقدّمك نحوه. يمكنك تغييره أو إزالته في أي وقت.")

    // Day-type schedules (user-authored only; never inferred)
    static let dayTypes = LocalizedString(en: "Day types", ar: "أنواع الأيام")
    static let dayTypesHelp = LocalizedString(
        en: "Optional amounts for your own kinds of day. You choose which one today is — BADAN never guesses.",
        ar: "كميات اختيارية لأنواع أيامك. أنت تختار نوع اليوم — لا يخمّن بدن ذلك أبدًا.")
    static let addDayType = LocalizedString(en: "Add a day type", ar: "أضف نوع يوم")
    static let add = LocalizedString(en: "Add", ar: "إضافة")
    static let dayTypeNamePlaceholder = LocalizedString(en: "Name (e.g. Training)", ar: "الاسم (مثل: تمرين)")
    static let todayIs = LocalizedString(en: "Today is", ar: "اليوم")
    static let defaultDay = LocalizedString(en: "Default", ar: "الافتراضي")

    // Weekly (observational only)
    static let thisWeek = LocalizedString(en: "This week", ar: "هذا الأسبوع")
    static let weekObservationalNote = LocalizedString(
        en: "A plain count of the days you logged — not a score.",
        ar: "عدّ بسيط للأيام التي سجّلت فيها — ليس تقييمًا.")

    // Visibility
    static let hideModule = LocalizedString(en: "Hide hydration", ar: "إخفاء السوائل")
    static let hideModuleNote = LocalizedString(
        en: "Removes hydration from the Log tab. Your logged drinks are kept and come back when you show it again.",
        ar: "يزيل السوائل من تبويب التسجيل. تبقى مشروباتك المسجّلة محفوظة وتعود عند إظهارها مجددًا.")
    static let hiddenChip = LocalizedString(en: "Hydration is hidden", ar: "السوائل مخفية")
    static let showAgain = LocalizedString(en: "Show", ar: "إظهار")

    // MARK: - Composed strings

    /// A formatted volume with its unit, e.g. "500 mL" / "٥٠٠ مل". Integer mL — a drink is not
    /// logged to a decilitre of false precision, and the digits follow the app's Arabic-numeral
    /// preference through the shared `ValueFormatter`.
    static func volume(_ mlValue: Double, formatter: ValueFormatter, language: AppLanguage) -> String {
        "\(formatter.integer(Int(mlValue.rounded()))) \(ml.resolved(language))"
    }

    /// The quick-log confirmation. "Added 500 mL" for an anonymous amount; "Added 500 mL from My
    /// Bottle" when logged from a named favorite (§7A.1). Arabic keeps natural word order.
    static func confirmation(volume: String, favoriteName: String?, language: AppLanguage) -> String {
        switch (language, favoriteName) {
        case (.en, let name?): return "Added \(volume) from \(name)"
        case (.en, nil):       return "Added \(volume)"
        case (.ar, let name?): return "أُضيف \(volume) من \(name)"
        case (.ar, nil):       return "أُضيف \(volume)"
        }
    }

    /// The accessibility action label for a one-tap favorite, always naming the volume (and the
    /// favorite's name when it has one) so a VoiceOver user hears exactly what a tap will log.
    static func logAction(volume: String, favoriteName: String?, language: AppLanguage) -> String {
        switch (language, favoriteName) {
        case (.en, let name?): return "Log \(volume) from \(name)"
        case (.en, nil):       return "Log \(volume)"
        case (.ar, let name?): return "سجّل \(volume) من \(name)"
        case (.ar, nil):       return "سجّل \(volume)"
        }
    }

    /// The short caption under the ring's centre number: "of 2,000 mL" on a goal day. Kept separate
    /// from `progressReadout` (which leads with the current total, for accessibility).
    static func ofTarget(_ target: String, language: AppLanguage) -> String {
        switch language {
        case .en: return "of \(target)"
        case .ar: return "من \(target)"
        }
    }

    /// The calm progress readout. No goal → "1,200 mL logged today". With a goal → "1,200 of 2,000
    /// mL". Never a percentage of nothing, never an "ahead/behind" framing.
    static func progressReadout(current: String, target: String?, language: AppLanguage) -> String {
        guard let target else {
            switch language {
            case .en: return "\(current) \(loggedToday.en)"
            case .ar: return "\(current) \(loggedToday.ar)"
            }
        }
        switch language {
        case .en: return "\(current) of \(target)"
        case .ar: return "\(current) من \(target)"
        }
    }

    /// The weekly observational sentence: "Logged drinks on 5 of 7 days" — a count, never a verdict.
    static func loggedDaysSentence(days: Int, of total: Int, formatter: ValueFormatter, language: AppLanguage) -> String {
        let d = formatter.integer(days)
        let t = formatter.integer(total)
        switch language {
        case .en: return "Logged drinks on \(d) of \(t) days"
        case .ar: return "سجّلت مشروبات في \(d) من \(t) أيام"
        }
    }
}
