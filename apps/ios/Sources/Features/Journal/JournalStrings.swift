import Foundation

/// Copy for the daily journal and the context-status manager (EPIC-29, plan §16 rows "Journal" and
/// the context intervals under it).
///
/// Internal rather than file-private because
/// `JournalSurfacesTests.testJournalCopyIsBilingualAndWellnessSafe` walks these to assert every one
/// carries real Arabic — the journal names habits (caffeine, alcohol, screen in bed) and a
/// half-translated screen here would be the surface where a user's Arabic reading experience breaks
/// first. The register is the same one the behaviour dictionary is authored in: **records what
/// happened, never grades it**. No entry here says "too much", "should", "avoid" or "better".
enum JournalStrings {
    static let title = LocalizedString(en: "Daily journal", ar: "المفكرة اليومية")
    static let logTile = LocalizedString(en: "Journal", ar: "المفكرة")

    /// Plan §16's locked trust line for this surface.
    static let trust = LocalizedString(
        en: "Used only on your device to find your patterns.",
        ar: "تُستخدم على جهازك فقط لاكتشاف أنماطك.")

    static let today = LocalizedString(en: "Today", ar: "اليوم")
    static let yesterday = LocalizedString(en: "Yesterday", ar: "أمس")
    static let dayPickerLabel = LocalizedString(en: "Day being logged", ar: "اليوم الذي تسجّله")

    /// The arm rule, said plainly. The correlation engine treats a behaviour with no tag on a day
    /// the user journaled as a day it did NOT happen, so what the user leaves untapped is evidence
    /// too — that has to be visible on the screen where the tapping happens, not only in a doc.
    static let untappedNote = LocalizedString(
        en: "Tap what happened. On a day you log, anything you leave untapped counts as “didn’t happen”.",
        ar: "اضغط ما حدث فعلاً. وفي أي يوم تسجّل فيه، يُحتسب ما تتركه دون ضغط أنه لم يحدث.")

    /// Shown while the day selector sits on Yesterday. Names both instants rather than hiding the
    /// backdating — `JournalEntry.isRecalled` is disclosure, never a discount.
    static let recallNote = LocalizedString(
        en: "Logging for yesterday. BADAN records both when it happened and when you entered it.",
        ar: "أنت تسجّل ليوم أمس. يحفظ بدن وقت حدوث الأمر ووقت إدخالك له معاً.")

    static let taggedCount = LocalizedString(en: "Tagged: {n}", ar: "عدد العلامات: {n}")
    static let nothingTaggedYet = LocalizedString(en: "Nothing tagged yet", ar: "لا توجد علامات بعد")

    static let amount = LocalizedString(en: "Amount", ar: "المقدار")
    static let amountNotSet = LocalizedString(en: "Not set", ar: "غير محدد")
    /// The only quantity unit the dictionary uses today (`nap`, `mindfulness`). A count carries no
    /// unit at all — 2 coffees is 2, not 2 of anything convertible — so there is deliberately no
    /// "times" string here to pair with one.
    static let minutes = LocalizedString(en: "min", ar: "دقيقة")
    static let decreaseAmount = LocalizedString(en: "Decrease", ar: "إنقاص")
    static let increaseAmount = LocalizedString(en: "Increase", ar: "زيادة")

    static let ownTagsTitle = LocalizedString(en: "Your own tags", ar: "علاماتك الخاصة")
    static let ownTagPlaceholder = LocalizedString(en: "Add your own tag", ar: "أضف علامة خاصة بك")
    static let addTag = LocalizedString(en: "Add", ar: "إضافة")
    /// Says out loud what the engine does with free text, so a power user is never surprised that
    /// their own tags produced no findings.
    static let ownTagsNote = LocalizedString(
        en: "Saved and exported with everything else. Your own tags aren’t compared against your scores — two spellings of one habit would split the evidence in half.",
        ar: "تُحفظ وتُصدَّر مع بقية بياناتك. لكن علاماتك الخاصة لا تُقارَن بمؤشراتك، لأن كتابة العادة نفسها بصيغتين تقسّم الأدلة إلى نصفين.")

    static let logged = LocalizedString(en: "Logged", ar: "مُسجَّل")
    static let notLogged = LocalizedString(en: "Not logged", ar: "غير مُسجَّل")
    static let addedAnnouncement = LocalizedString(en: "{name} logged", ar: "تم تسجيل {name}")
    static let removedAnnouncement = LocalizedString(en: "{name} removed", ar: "تمت إزالة {name}")

    static let saveFailed = LocalizedString(
        en: "Couldn’t save that — try again.",
        ar: "تعذّر الحفظ — حاول مرة أخرى.")
    static let loadFailed = LocalizedString(
        en: "Couldn’t load today’s tags — try again.",
        ar: "تعذّر تحميل علامات اليوم — حاول مرة أخرى.")

    /// The journal is sensitive-plus (I7): when sensitive records are off it is not shown at all,
    /// and the reason is named rather than left as a missing tile.
    static let sensitiveOffTitle = LocalizedString(
        en: "The journal is part of sensitive records",
        ar: "المفكرة ضمن السجلات الحساسة")
    static let sensitiveOffMessage = LocalizedString(
        en: "Behaviour tags stay in the separate, purgeable store with medications and symptoms. Turn on Sensitive records in Settings to log them.",
        ar: "تبقى علامات السلوك في المخزن المنفصل القابل للحذف مع الأدوية والأعراض. فعّل السجلات الحساسة من الإعدادات لتسجيلها.")

    // MARK: - Context statuses

    static let contextTitle = LocalizedString(en: "Periods you’ve marked", ar: "فترات وصفتها")
    static let contextLinkSubtitle = LocalizedString(
        en: "Travel, feeling unwell, fasting, altitude, injury",
        ar: "سفر، توعّك، صيام، ارتفاع عالٍ، إصابة")
    /// The whole behavioural contract of `ContextStatus`, in one sentence: it conditions how a value
    /// is READ and never what the value is.
    static let contextExplainer = LocalizedString(
        en: "Marking a period changes no number. It tells BADAN to read those days less confidently and adds a note beside them.",
        ar: "وصف فترة لا يغيّر أي رقم. فهو يجعل بدن يقرأ تلك الأيام بثقة أقل ويضيف ملاحظة بجانبها.")
    static let contextStart = LocalizedString(en: "Start a period", ar: "ابدأ فترة")
    static let contextOngoing = LocalizedString(en: "Ongoing", ar: "مستمرة")
    static let contextEndNow = LocalizedString(en: "End now", ar: "أنهِ الآن")
    static let contextStarted = LocalizedString(en: "Started {date}", ar: "بدأت في {date}")
    static let contextRange = LocalizedString(en: "{start} to {end}", ar: "من {start} إلى {end}")
    static let contextEarlier = LocalizedString(en: "Earlier", ar: "سابقة")
    static let contextNoneTitle = LocalizedString(en: "Nothing marked", ar: "لا توجد فترات موصوفة")
    static let contextNoneMessage = LocalizedString(
        en: "That’s the normal state. Mark a period only when a stretch of days genuinely didn’t look like your usual ones.",
        ar: "وهذه هي الحالة المعتادة. صِف فترة فقط حين تكون أيامٌ متتالية مختلفة فعلاً عن أيامك المعتادة.")
    static let contextCustomPlaceholder = LocalizedString(
        en: "Describe it in your own words",
        ar: "صِفها بكلماتك")
    static let contextRemoved = LocalizedString(en: "Period removed", ar: "أُزيلت الفترة")
    static let contextStartedAnnouncement = LocalizedString(en: "{name} started", ar: "بدأت فترة {name}")
    static let contextEndedAnnouncement = LocalizedString(en: "{name} ended", ar: "انتهت فترة {name}")
    static let contextDelete = LocalizedString(en: "Remove", ar: "إزالة")
}

/// Display names for the behaviour dictionary's category keys — the chip-group headings.
///
/// A table rather than a `nameEn`/`nameAr` pair on each dictionary row: a category is a UI grouping,
/// not a piece of the shared contract, and adding two localized fields per behaviour to `behaviors.json`
/// would put ten strings in the contract twenty-eight times over. `JournalSurfacesTests` asserts every
/// category the shipped dictionary uses resolves HERE rather than falling back, so a new category in
/// the contract fails the suite instead of shipping as a raw key.
enum JournalCategory {
    static func displayName(_ category: String) -> LocalizedString? {
        switch category {
        case "stimulants": return LocalizedString(en: "Stimulants", ar: "منبّهات")
        case "alcohol": return LocalizedString(en: "Alcohol", ar: "الكحول")
        case "food": return LocalizedString(en: "Food", ar: "الطعام")
        case "hydration": return LocalizedString(en: "Water", ar: "الماء")
        case "evening": return LocalizedString(en: "Evening", ar: "المساء")
        case "sleep": return LocalizedString(en: "Sleep", ar: "النوم")
        case "movement": return LocalizedString(en: "Movement", ar: "الحركة")
        case "recovery": return LocalizedString(en: "Recovery", ar: "الاستشفاء")
        case "supplements": return LocalizedString(en: "Supplements", ar: "المكمّلات")
        case "circumstance": return LocalizedString(en: "The day itself", ar: "طبيعة اليوم")
        default: return nil
        }
    }

    /// The heading actually rendered. An unknown category (a dictionary row added ahead of this
    /// table) falls back to its raw key rather than disappearing — a chip with no group would be a
    /// behaviour the user can never tap.
    static func heading(_ category: String) -> LocalizedString {
        displayName(category) ?? LocalizedString(en: category, ar: category)
    }
}
