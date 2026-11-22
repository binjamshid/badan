import SwiftUI

/// Settings' seven top-level categories.
///
/// Settings had grown to eleven flat sections on one scroll — every control the app has, stacked,
/// so finding one meant scrolling past ten you didn't want. Categories give each area a page of
/// its own and room to grow (goals and backup/restore had nowhere to live before this).
///
/// One enum rather than seven hand-written rows so the root list, the search index and the
/// destinations can't drift apart: adding a category here makes it appear, be searchable, and be
/// routable in one edit. `CaseIterable` order IS the display order — most-used first, and the
/// destructive/rarely-touched ones last.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case account
    case goals
    case notifications
    case privacy
    case personalization
    case backup
    case support

    var id: String { rawValue }

    var title: LocalizedString {
        switch self {
        case .account: return LocalizedString(en: "Account", ar: "الحساب")
        case .goals: return LocalizedString(en: "Health goals", ar: "أهدافك الصحية")
        case .notifications: return LocalizedString(en: "Notifications", ar: "الإشعارات")
        case .privacy: return LocalizedString(en: "Privacy & security", ar: "الخصوصية والأمان")
        case .personalization: return LocalizedString(en: "Personalization", ar: "التخصيص")
        case .backup: return LocalizedString(en: "Backup & restore", ar: "النسخ والاستعادة")
        case .support: return LocalizedString(en: "Support", ar: "الدعم")
        }
    }

    /// One line saying what's inside — so the root list is navigable without opening each page.
    var subtitle: LocalizedString {
        switch self {
        case .account:
            return LocalizedString(en: "Sign in, referral codes, App Store billing",
                                   ar: "تسجيل الدخول، رموز الإحالة، فوترة App Store")
        case .goals:
            return LocalizedString(en: "Targets for the metrics you care about",
                                   ar: "أهداف للمقاييس التي تهمّك")
        case .notifications:
            return LocalizedString(en: "Medication reminders", ar: "تذكيرات الأدوية")
        case .privacy:
            return LocalizedString(en: "Sensitive records, sources, policy, deletion",
                                   ar: "السجلات الحساسة، المصادر، السياسة، الحذف")
        case .personalization:
            return LocalizedString(en: "Appearance, icon, language, detail, units, Home",
                                   ar: "المظهر، الأيقونة، اللغة، التفصيل، الوحدات، الرئيسية")
        case .backup:
            return LocalizedString(en: "Export your data, restore from a backup",
                                   ar: "تصدير بياناتك، الاستعادة من نسخة")
        case .support:
            return LocalizedString(en: "Diagnostics, what's new, about", ar: "التشخيص، الجديد، حول")
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .goals: return "target"
        case .notifications: return "bell"
        case .privacy: return "lock.shield"
        case .personalization: return "paintbrush"
        case .backup: return "arrow.clockwise.icloud"
        case .support: return "lifepreserver"
        }
    }

    /// Search terms, English then Arabic. Matched by `SettingsScreen.matchesSearch`, which splits
    /// the query into words and compares both directions — so "app icons" finds "app icon".
    ///
    /// These are the leaves, not the category names: a user searching "dark" is looking for the
    /// theme control, and has no reason to know it lives under Personalization. Categorising
    /// settings makes search MORE important, not less, because the control is now a page deeper.
    var keywords: [String] {
        switch self {
        case .account:
            return ["account", "sign in", "referral", "apple", "app store", "subscription",
                    "billing", "cancel subscription", "حساب", "تسجيل", "إحالة", "اشتراك", "فوترة"]
        case .goals:
            return ["goals", "goal", "target", "targets", "أهداف", "هدف"]
        case .notifications:
            return ["notifications", "reminders", "medication", "alerts", "إشعارات", "تذكيرات", "أدوية"]
        case .privacy:
            return ["privacy", "security", "policy", "sensitive", "medication", "symptom", "sources",
                    "delete", "reset", "purge", "خصوصية", "أمان", "سياسة", "حساسة", "أعراض", "مصادر", "حذف"]
        case .personalization:
            return ["appearance", "theme", "dark", "light", "icon", "app icon", "language", "arabic",
                    "digits", "depth", "detail", "simple", "power", "units", "canonical", "display",
                    "modules", "home", "readiness", "sleep", "activity", "heart", "timeline",
                    "مظهر", "أيقونة", "لغة", "أرقام", "تفصيل", "وحدات", "الشاشة"]
        case .backup:
            return ["backup", "restore", "export", "import", "csv", "json", "share",
                    "نسخ", "استعادة", "تصدير", "استيراد"]
        case .support:
            return ["support", "diagnostics", "debug", "about", "version", "what's new", "resources",
                    "help", "terms of use", "دعم", "تشخيص", "حول", "الإصدار", "الجديد", "الموارد", "شروط الاستخدام"]
        }
    }
}
