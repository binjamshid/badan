import SwiftUI
import UserNotifications

// MARK: - Screen

/// Settings' root: seven categories, plus search.
///
/// This was one flat scroll of eleven sections — every control in the app stacked on one page, so
/// reaching Home modules meant scrolling past appearance, icons, language, depth and units. It
/// also had nowhere to put anything new: goals and backup/restore had existed as schema and
/// export for months with no home. Categories give each area a page and room to grow.
///
/// Search is now MORE important, not less, because every control moved a level deeper — so it
/// searches the LEAVES (`SettingsCategory.keywords`), not the category names. A user typing
/// "dark" wants the theme control and has no reason to know it lives under Personalization; the
/// matching category is filtered in, and its subtitle says what's inside.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var searchQuery = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                BadanCard {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleCategories.enumerated()), id: \.element.id) { index, category in
                            NavigationLink { destination(category) } label: { categoryRow(category) }
                                .buttonStyle(.plain)
                            if index < visibleCategories.count - 1 { settingsDivider }
                        }
                    }
                }
                // Hidden while searching, so it never appears as an unrelated result below a
                // filtered category list.
                if searchQuery.isEmpty { SyncNowRow() }
                // (EU5) A search matching nothing used to render an entirely blank screen —
                // indistinguishable from the setting not existing, or from the app breaking.
                if noSearchResults {
                    searchEmptyState
                }
            }
            .padding(BadanSpace.space4)
        }
        .searchable(text: $searchQuery, prompt: Text(Loc.search, language: env.language))
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.settingsTitle))
    }

    // MARK: Routing

    @ViewBuilder
    private func destination(_ category: SettingsCategory) -> some View {
        switch category {
        case .account: AccountSettingsScreen()
        case .goals: GoalsSettingsScreen()
        case .notifications: NotificationsSettingsScreen()
        case .privacy: PrivacySecuritySettingsScreen()
        case .personalization: PersonalizationSettingsScreen()
        case .backup: BackupRestoreSettingsScreen()
        case .support: SupportSettingsScreen()
        }
    }

    private func categoryRow(_ category: SettingsCategory) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: category.icon)
                .foregroundStyle(BadanColor.primary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                LText(category.title)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                LText(category.subtitle)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BadanSpace.space2)
            // `chevron.forward` rather than `.right` so it mirrors itself in Arabic.
            Image(systemName: "chevron.forward")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Search

    private var visibleCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { matchesSearch($0.keywords + [$0.title.en, $0.title.ar]) }
    }

    /// (EU5) Matches per WORD, and in both directions.
    ///
    /// The old `keyword.contains(query)` failed the most ordinary thing a user can do: type what
    /// they see. "app icons" never matched the keyword "app icon" (a keyword can't contain a
    /// longer string), and any two-word query like "dark theme" missed every single-word keyword.
    ///
    /// Each word must match some keyword, so extra words narrow rather than widen; direction is
    /// checked both ways so a plural or a longer typed phrase still hits its shorter keyword.
    private func matchesSearch(_ keywords: [String]) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            keywords.contains { keyword in
                keyword.localizedCaseInsensitiveContains(word) || word.localizedCaseInsensitiveContains(keyword)
            }
        }
    }

    private var noSearchResults: Bool {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return visibleCategories.isEmpty
    }

    private var searchEmptyState: some View {
        VStack(spacing: BadanSpace.space2) {
            Text(SettingsStrings.searchNoResultsTitle, language: env.language)
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.textPrimary)
            Text(SettingsStrings.searchNoResultsBody, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                searchQuery = ""
            } label: {
                Text(SettingsStrings.searchClear, language: env.language)
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.primary)
                    .frame(minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BadanSpace.space6)
        .accessibilityElement(children: .contain)
    }

}


// MARK: - Reusable single-select rows (no card — for embedding inside a shared card)

/// The bare rows of a mutually-exclusive choice list, without the enclosing `BadanCard` —
/// factored out of `SettingsRadioGroup` so a caller (e.g. `languageSection`) can place a
/// related, non-radio row inside the *same* card as the options themselves.
struct SettingsRadioRows<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    let subtitle: ((Option) -> String)?
    let isOn: (Option) -> Bool
    var badgeText: ((Option) -> String?)? = nil
    let onSelect: (Option) -> Void
    /// Whether a divider should also render after the last option (the caller has more rows
    /// below it in the same card).
    var trailingDivider: Bool = false

    var body: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            let selected = isOn(option)
            Button { onSelect(option) } label: {
                HStack(spacing: BadanSpace.space3) {
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        HStack(spacing: BadanSpace.space2) {
                            Text(title(option))
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            if let badge = badgeText?(option), !badge.isEmpty {
                                Text(badge)
                                    .font(BadanFont.chip)
                                    .foregroundStyle(BadanColor.primary)
                                    .padding(.horizontal, BadanSpace.space2)
                                    .padding(.vertical, 2)
                                    .background(BadanColor.primary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        if let subtitle, !subtitle(option).isEmpty {
                            Text(subtitle(option))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.medium)
                        .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BadanSpace.touchMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if index < options.count - 1 || trailingDivider {
                Rectangle()
                    .fill(BadanColor.separator)
                    .frame(height: 1)
                    .padding(.vertical, BadanSpace.space1)
            }
        }
    }
}

// MARK: - Reusable single-select group (radio rows in their own card)

/// A calm list of mutually-exclusive choices. Uses a checkmark, never colour alone, and reads
/// correctly in both LTR and RTL because it relies on leading/trailing layout.
struct SettingsRadioGroup<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    let subtitle: ((Option) -> String)?
    let isOn: (Option) -> Bool
    var badgeText: ((Option) -> String?)? = nil
    let onSelect: (Option) -> Void

    var body: some View {
        BadanCard {
            VStack(spacing: 0) {
                SettingsRadioRows(options: options, title: title, subtitle: subtitle,
                                  isOn: isOn, badgeText: badgeText, onSelect: onSelect)
            }
        }
    }
}

// MARK: - Reusable toggle row

struct SettingsToggleRow: View {
    @Environment(AppEnvironment.self) private var env
    let title: LocalizedString
    let subtitle: LocalizedString?
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(title, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                if let subtitle {
                    Text(subtitle, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(BadanColor.primary)
        .frame(minHeight: BadanSpace.touchMin)
    }
}

// MARK: - Navigation row label

struct SettingsNavRowLabel: View {
    @Environment(AppEnvironment.self) private var env
    let icon: String
    let title: LocalizedString

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(title, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            Image(systemName: "chevron.forward")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
    }
}

// MARK: - Units explainer sheet

/// A single worked example distinguishing canonical (source-faithful) from display (converted)
/// units — reachable via the info button next to the Units section header.
struct UnitsExplainerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space3) {
                            LText(SettingsStrings.unitsExplainerIntro)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            LText(SettingsStrings.unitsExplainerExample)
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.units))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - What's new sheet

/// A minimal, locally-bundled release-notes surface (FEAT-226) — a static, bilingual list, no
/// network or new resource file required, consistent with ADR-0002.
struct WhatsNewSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let version: String
        let notes: LocalizedString
    }

    private let entries: [Entry] = [
        Entry(version: "0.1.0", notes: LocalizedString(
            en: "First release: Today, Body, Log, Insights and Settings, with local-only storage and full export.",
            ar: "الإصدار الأول: الرئيسية، الجسم، التسجيل، الملاحظات والإعدادات، مع تخزين محلي بالكامل وتصدير كامل."))
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    ForEach(entries) { entry in
                        BadanCard {
                            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                                Text(entry.version)
                                    .font(BadanFont.body.weight(.semibold))
                                    .foregroundStyle(BadanColor.textPrimary)
                                Text(entry.notes, language: env.language)
                                    .font(BadanFont.bodyCompact)
                                    .foregroundStyle(BadanColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(SettingsStrings.whatsNewTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - About sheet

/// A simple, always-available diagnostic panel (FEAT-298) — app version and build number only;
/// contract/schema version strings aren't exposed by `MetricRegistry`/`InsightTemplateStore`
/// today, so surfacing those is left for a follow-up that adds that accessor.
struct AboutSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    BadanCard {
                        VStack(spacing: 0) {
                            aboutRow(label: SettingsStrings.aboutVersion, value: env.appVersion)
                            Rectangle()
                                .fill(BadanColor.separator)
                                .frame(height: 1)
                                .padding(.vertical, BadanSpace.space1)
                            aboutRow(label: SettingsStrings.aboutBuild, value: buildNumber)
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(SettingsStrings.aboutTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }

    private func aboutRow(label: LocalizedString, value: String) -> some View {
        HStack {
            Text(label, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer()
            Text(value)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }
}

// MARK: - Strings (screen-local, always bilingual)

enum SettingsStrings {
    static let arabicDigitsHint = LocalizedString(
        en: "Show numbers using Arabic-Indic digits.",
        ar: "عرض الأرقام بالصيغة العربية الهندية.")
    static let arabicDigitsHintPrimed = LocalizedString(
        en: "Show numbers using Arabic-Indic digits — applies once Arabic is selected.",
        ar: "عرض الأرقام بالصيغة العربية الهندية — يُطبَّق عند اختيار اللغة العربية.")

    static let sensitiveHeader = LocalizedString(en: "Sensitive records", ar: "السجلات الحساسة")
    static let sensitiveSubtitle = LocalizedString(
        en: "Kept in a separate store on this device.",
        ar: "تُحفظ في مخزن منفصل على هذا الجهاز.")
    static let sensitivePurgeNote = LocalizedString(
        en: "Turning this off removes everything in your sensitive store from this device — "
            + "medications, symptoms, journal entries, cycle records, and any lab results you "
            + "imported.",
        ar: "إيقاف هذا يزيل كل ما في مخزنك الحساس من هذا الجهاز — الأدوية والأعراض ومدوّناتك "
            + "وسجلات الدورة وأي نتائج مخبرية استوردتها.")
    static let sensitiveReenableNotice = LocalizedString(
        en: "Sensitive records are back on. Previously removed data is not restored.",
        ar: "عادت السجلات الحساسة إلى العمل. البيانات التي أُزيلت سابقاً لن تعود.")

    static let purgeConfirmTitle = LocalizedString(
        en: "Turn off and remove your sensitive records?",
        ar: "إيقاف وإزالة سجلاتك الحساسة؟")
    static let purgeConfirmMessage = LocalizedString(
        en: "This permanently removes every medication, symptom, journal, cycle and imported lab "
            + "record from this device. It cannot be undone.",
        ar: "يزيل هذا نهائياً كل سجلات الأدوية والأعراض من هذا الجهاز.")
    static let purgeConfirmAction = LocalizedString(en: "Turn off & remove", ar: "إيقاف وإزالة")
    // EDGE-01: shown when the underlying file delete genuinely failed — the toggle stays on in
    // that case (see the confirmation button above), so this explains why nothing changed.
    static let purgeFailedNotice = LocalizedString(
        en: "Couldn't remove sensitive records — sensitive records are still on. Please try again.",
        ar: "تعذّرت إزالة السجلات الحساسة — ما زالت السجلات الحساسة مفعّلة. حاول مرة أخرى.")

    // COMP-09: this used to read "Reset demo data?" / "This restores the sample data set,"
    // which read as if only bundled demo content was affected. `resetAll()` actually drops
    // every table in both databases first — any medications, symptoms, workouts, nutrition
    // logs or notes the user has entered are gone — and only afterward re-seeds the sample
    // data set, so the copy says both things plainly.
    /// (F6) Shown only when the OS ceiling actually pushed reminders out of the plan. Says what
    /// is scheduled and what isn't, without alarm — the nearest reminders do fire, and each
    /// reschedule rolls the window forward, so this is a real limit rather than a failure.
    static func remindersCappedNote(_ dropped: Int) -> LocalizedString {
        LocalizedString(
            en: "iOS schedules at most \(MedicationReminderPlan.systemPendingLimit) reminders at a "
                + "time. Your soonest ones are set; \(dropped) further reminder(s) will be "
                + "scheduled as they come closer.",
            ar: "يجدول iOS \(MedicationReminderPlan.systemPendingLimit) تذكيراً كحدّ أقصى في المرة "
                + "الواحدة. أقربها مضبوط الآن، وستُجدوَل \(dropped) تذكيرات أخرى كلما اقترب موعدها.")
    }

    // (EU5) Says the search found nothing — and, crucially, offers the way out. The old blank
    // screen left the query in the field with no visible reason for the emptiness.
    static let diagnosticsTitle = LocalizedString(en: "Diagnostics", ar: "التشخيص")
    static let diagnosticsBlurb = LocalizedString(
        en: "Technical details about this install, for when something looks wrong and you want to "
            + "describe it accurately.",
        ar: "تفاصيل تقنية عن هذا التثبيت، لحين بدا شيء غير صحيح وأردت وصفه بدقة.")
    static let searchNoResultsTitle = LocalizedString(en: "No settings match", ar: "لا إعدادات مطابقة")
    static let searchNoResultsBody = LocalizedString(
        en: "Try a different word, or clear the search to see everything.",
        ar: "جرّب كلمة أخرى، أو امسح البحث لعرض كل شيء.")
    static let searchClear = LocalizedString(en: "Clear search", ar: "مسح البحث")

    static let resetConfirmTitle = LocalizedString(en: "Delete all data?", ar: "حذف جميع البيانات؟")

    /// (C3) What happens after the wipe depends on whether a real source is connected —
    /// `AppEnvironment.resetDemoData()` re-ingests from HealthKit when it is, and only
    /// demo-seeds when it isn't. A single message promising "the bundled sample data set" was
    /// therefore wrong for exactly the users with real data to lose: it told them their own
    /// history would be replaced by fabricated readings, which would make anyone abandon the
    /// action or, worse, distrust what came back.
    static func resetConfirmMessage(connected: Bool) -> LocalizedString {
        let deletes = LocalizedString(
            en: "This permanently deletes everything on this device — including anything you've "
                + "logged yourself.",
            ar: "يؤدي هذا إلى حذف كل شيء على هذا الجهاز نهائياً — بما في ذلك كل ما سجّلته بنفسك.")
        let after = connected
            ? LocalizedString(
                en: " Your measurements are then read again from Apple Health. Anything Apple "
                    + "Health doesn't have — your own logs — won't come back.",
                ar: " ثم تُقرأ قياساتك مجدداً من صحة آبل. أما ما ليس لدى صحة آبل — أي سجلاتك "
                    + "الخاصة — فلن يعود.")
            : LocalizedString(
                en: " It's then replaced with the bundled sample data set.",
                ar: " ثم يُستبدل بمجموعة البيانات التجريبية المرفقة.")
        let undo = LocalizedString(en: " This can't be undone.", ar: " لا يمكن التراجع عن هذا.")
        return LocalizedString(en: deletes.en + after.en + undo.en,
                               ar: deletes.ar + after.ar + undo.ar)
    }
    // BUG-17: `AppEnvironment.resetError` used to be set with nothing ever reading it.
    static let resetFailedNotice = LocalizedString(
        en: "Something went wrong while resetting your data. Some of it may be incomplete — try again.",
        ar: "حدث خطأ أثناء إعادة تعيين بياناتك. قد يكون بعضها غير مكتمل — حاول مرة أخرى.")

    static let dataManagementHeader = LocalizedString(en: "Data management", ar: "إدارة البيانات")

    static let notifMeds = LocalizedString(en: "Medication reminders", ar: "تذكيرات الأدوية")
    static let notifMedsSubtitle = LocalizedString(
        en: "A gentle nudge at your usual times. No names appear on the lock screen.",
        ar: "تذكير لطيف في أوقاتك المعتادة. لا تظهر أي أسماء على شاشة القفل.")
    static let systemNotificationsOffNote = LocalizedString(
        en: "Notifications are off at the system level. Enable them in iOS Settings to receive these.",
        ar: "الإشعارات متوقفة على مستوى النظام. فعّلها من إعدادات iOS لتصلك هذه التذكيرات.")
    static let notifPermissionDenied = LocalizedString(
        en: "To get reminders, enable notifications for BADAN in iOS Settings.",
        ar: "لتصلك التذكيرات، فعّل الإشعارات لتطبيق بدن من إعدادات iOS.")

    // EPIC-32 summaries & reminders section.
    static let notifSummariesHeader = LocalizedString(en: "Summaries & reminders", ar: "الملخّصات والتذكيرات")
    static let notifQuietHours = LocalizedString(en: "Quiet hours", ar: "ساعات الهدوء")
    static let notifQuietHoursHint = LocalizedString(
        en: "These notifications are held during this window.",
        ar: "تُحجب هذه الإشعارات خلال هذه الفترة.")
    static let notifQuietFrom = LocalizedString(en: "From", ar: "من")
    static let notifQuietTo = LocalizedString(en: "To", ar: "إلى")
    static let notifBedtimeTitle = LocalizedString(en: "Wind-down timing", ar: "توقيت الاسترخاء")
    static let notifBedtimeHint = LocalizedString(
        en: "By default the wind-down arrives at a fixed hour.",
        ar: "يصل تذكير الاسترخاء افتراضياً في ساعة ثابتة.")
    static let notifBedtimeAdaptive = LocalizedString(
        en: "Time it to my recent nights", ar: "اضبطه على لياليّ الأخيرة")
    static let notifBedtimeWake = LocalizedString(en: "I'd like to wake at", ar: "أودّ الاستيقاظ عند")
    /// Says plainly that the derived time needs data, rather than implying every user gets one.
    /// `SleepNightScore.need` is nil until a personal baseline exists.
    static let notifBedtimeFallbackNote = LocalizedString(
        en: "Until BADAN has enough of your nights, this stays on your usual bedtime, then the fixed hour.",
        ar: "إلى أن تتوفّر لدى «بدن» ليالٍ كافية، يبقى على وقت نومك المعتاد، ثم على الساعة الثابتة.")
    static let iconNeedsProNotice = LocalizedString(
        en: "Alternate icons are part of BADAN Pro.", ar: "الأيقونات البديلة جزء من «بدن برو».")
    static let subscriptionRow = LocalizedString(en: "BADAN Pro", ar: "بدن برو")
    static let notifShowValues = LocalizedString(
        en: "Show readings on the lock screen", ar: "إظهار القراءات على شاشة القفل")
    static let notifShowValuesHint = LocalizedString(
        en: "Off by default. When off, a notification says only that something is ready — never a number.",
        ar: "متوقّف افتراضياً. عند إيقافه، يذكر الإشعار أن شيئاً جاهز فقط — دون أي رقم.")
    static let notifDailyLimit = LocalizedString(en: "Daily limit", ar: "الحدّ اليومي")
    static let notifDailyLimitHint = LocalizedString(
        en: "The most of these BADAN will send in a day. Medication reminders don't count towards it.",
        ar: "أقصى عدد يرسله «بدن» من هذه الإشعارات في اليوم. تذكيرات الأدوية غير محسوبة ضمنه.")

    static let depthChangeNotice = LocalizedString(
        en: "Applied — you'll see the change on Home and other screens.",
        ar: "تم التطبيق — سترى التغيير في الرئيسية وشاشات أخرى.")

    // FIX-04: previously claimed the list order matched Home's screen order — there is no
    // reorder UI here (and Home's own visibility-honoring is being done by another change in
    // parallel), so this only ever claimed something true about visibility, never order.
    static let modulesOrderCaption = LocalizedString(
        en: "Choose what appears on Home.", ar: "اختر ما يظهر في الشاشة الرئيسية.")

    // D-35. Deliberately says "browse" and "Home", never "track" or "collect": the setting behind
    // this row changes what is shown, and nothing about what is recorded.
    static let metricsHeader = LocalizedString(en: "Metrics", ar: "المؤشرات")
    static let metricsRow = LocalizedString(en: "Shown metrics & pins", ar: "المؤشرات الظاهرة والمثبّتة")
    static let metricsCaption = LocalizedString(
        en: "Choose which metrics you browse, and pin a few to Home. Hiding one never stops BADAN "
            + "recording it.",
        ar: "اختر المؤشرات التي تتصفّحها، وثبّت بعضها في الرئيسية. الإخفاء لا يوقف تسجيل بادن لها.")

    static let unitsInfoAccessibilityLabel = LocalizedString(en: "About units", ar: "حول الوحدات")
    static let unitsExplainerIntro = LocalizedString(
        en: "Canonical units are exactly what your source recorded — nothing is converted, so provenance "
            + "stays exact. Display units convert everything to the units you prefer to read.",
        ar: "الوحدات الأصلية هي ما سجّله مصدرك تماماً — دون أي تحويل، فيبقى المصدر دقيقاً. أما الوحدات "
            + "المعروضة فتحوّل كل شيء إلى الوحدات التي تفضّل قراءتها.")
    static let unitsExplainerExample = LocalizedString(
        en: "Example: your Apple Health source recorded 6.2 mi. Canonical mode shows 6.2 mi, unchanged. "
            + "Display mode (if you prefer km) shows 10 km instead.",
        ar: "مثال: سجّل مصدر Apple Health مسافة 6.2 ميل. يعرضها الوضع الأصلي 6.2 ميل دون تغيير. أما وضع "
            + "العرض (إن كنت تفضّل الكيلومتر) فيعرض 10 كم بدلاً منها.")

    static let privacyPolicyTitle = LocalizedString(en: "Privacy Policy", ar: "سياسة الخصوصية")

    // EDGE-16: app-icon switch failure/unsupported-device messaging.
    static let iconUnsupportedNotice = LocalizedString(
        en: "Alternate icons aren't available on this device.",
        ar: "الأيقونات البديلة غير متاحة على هذا الجهاز.")
    static let iconSwitchFailedNotice = LocalizedString(
        en: "Couldn't switch the app icon. Your icon hasn't changed.",
        ar: "تعذّر تبديل أيقونة التطبيق. لم تتغيّر أيقونتك.")

    static let resourcesHeader = LocalizedString(en: "Resources", ar: "الموارد")
    static let whatsNewTitle = LocalizedString(en: "What's new", ar: "ما الجديد")
    static let aboutTitle = LocalizedString(en: "About", ar: "حول التطبيق")
    static let aboutVersion = LocalizedString(en: "Version", ar: "الإصدار")
    static let aboutBuild = LocalizedString(en: "Build", ar: "رقم البناء")

    static func depthSubtitle(_ depth: DepthPolicy) -> LocalizedString {
        switch depth {
        case .casual: return LocalizedString(en: "Calm and minimal.", ar: "هادئ ومبسّط.")
        case .power: return LocalizedString(en: "Raw values, lineage and tables.",
                                            ar: "القيم الخام والمصدر والجداول.")
        }
    }

    static func themeSubtitle(_ theme: AppTheme) -> LocalizedString {
        switch theme {
        case .system: return LocalizedString(en: "Follows your device's appearance.", ar: "يتبع مظهر جهازك.")
        case .light: return LocalizedString(en: "Always light.", ar: "فاتح دائماً.")
        case .dark: return LocalizedString(en: "Always dark.", ar: "داكن دائماً.")
        }
    }

    static func languageSubtitle(_ lang: AppLanguage) -> LocalizedString {
        switch lang {
        case .en: return LocalizedString(en: "English interface, left to right.",
                                         ar: "واجهة إنجليزية، من اليسار إلى اليمين.")
        case .ar: return LocalizedString(en: "Arabic interface, right to left.",
                                         ar: "واجهة عربية، من اليمين إلى اليسار.")
        }
    }

    static func unitModeTitle(_ mode: UnitProfileMode) -> LocalizedString {
        switch mode {
        case .display: return LocalizedString(en: "My display units", ar: "وحداتي المعروضة")
        case .canonical: return LocalizedString(en: "Original units", ar: "الوحدات الأصلية")
        }
    }

    static func unitModeSubtitle(_ mode: UnitProfileMode) -> LocalizedString {
        switch mode {
        case .display: return LocalizedString(en: "Convert to the units you prefer — e.g. kg becomes lb.",
                                              ar: "تحويل إلى الوحدات التي تفضّلها — مثلاً كغ تصبح رطل.")
        case .canonical: return LocalizedString(en: "Show source units, unchanged — e.g. stays in kg as recorded.",
                                                ar: "عرض وحدات المصدر كما هي — مثلاً تبقى كغ كما سُجّلت.")
        }
    }
}
