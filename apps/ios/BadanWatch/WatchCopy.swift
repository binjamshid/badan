import Foundation

// MARK: - Small shared helpers, deliberately duplicated across the app/watch boundary
//
// This target cannot import `apps/ios/Sources/DesignSystem/Tokens.swift`,
// `apps/ios/Sources/Core/Localization/AppLanguage.swift`, or any other main-app source — see
// `Snapshot/AmbientSnapshotDto.swift`'s header for why. `WatchCopy`/`WatchLanguage` below are the
// SAME shape as `BadanWidgets`' own `WidgetCopy`/`WidgetLanguage`
// (`apps/ios/BadanWidgets/BadanWidgetsBundle.swift`) — small, hand-picked mirrors, not a new
// pattern — kept intentionally minimal (only what `TodayView`/`WatchMetricDetailView` actually
// need).

/// A tiny bilingual-string helper local to this target, matching `BadanWidgets`' `WidgetCopy`
/// exactly in shape. `AmbientSnapshotDto.language` ("en"/"ar") is the only signal this process has
/// for which half to read; there is no live app-language setting to consult here.
struct WatchCopy {
    let en: String
    let ar: String
    func resolved(isArabic: Bool) -> String { isArabic ? ar : en }
}

/// The one place every screen in this target decides Arabic vs. English/RTL — matches
/// `BadanWidgets.WidgetLanguage`'s exact fallback rule: `snapshot.language` (the user's in-app
/// language CHOICE, which can differ from the device locale) is authoritative whenever a snapshot
/// exists; only when this watch has NEVER received one does it fall back to the system locale, the
/// only remaining signal of the user's likely language.
enum WatchLanguage {
    static func isArabic(
        for snapshot: AmbientSnapshotDto?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        if let language = snapshot?.language {
            return language == "ar"
        }
        guard let topLanguage = preferredLanguages.first else { return false }
        let languageCode = topLanguage.split(separator: "-").first.map(String.init) ?? topLanguage
        return languageCode == "ar"
    }
}

/// Every user-facing string `TodayView`/`WatchMetricDetailView` need, centralized here the same way
/// `RingCopy`/`SleepCopy`/`MedsDueCopy` are centralized per-widget in `BadanWidgets` — collected
/// into one enum here since this target has few enough screens not to need one file per screen.
/// Several strings are DELIBERATELY copied verbatim from the phone-side/widget-side equivalents
/// (see each doc) so the same concept reads identically everywhere a user sees it.
enum WatchStrings {
    static let todayTitle = WatchCopy(en: "Today", ar: "اليوم")
    static let syncNow = WatchCopy(en: "Sync now", ar: "مزامنة الآن")
    /// Confirms the ASK reached the system, not that data has arrived — the watch genuinely cannot
    /// know when the phone will wake, so promising a time would be a guess dressed as a status.
    static let syncRequested = WatchCopy(en: "Asked your iPhone to check.",
                                         ar: "تم طلب التحقق من iPhone.")
    /// Verbatim match with `BadanWidgets`' `RingCopy.title`.
    static let readiness = WatchCopy(en: "Readiness", ar: "الاستعداد")
    /// Verbatim match with `ReportPresentation.metricName`'s `MetricID.effortDay` case and
    /// `AICoachContextAssembler`'s effort label.
    static let effort = WatchCopy(en: "Effort", ar: "الجهد")
    /// Verbatim match with `BadanWidgets`' `SleepCopy.title`.
    static let sleep = WatchCopy(en: "Last night", ar: "الليلة الماضية")
    /// Verbatim match with `BadanWidgets`' `RingCopy.noData`.
    static let noData = WatchCopy(en: "No data yet", ar: "لا توجد بيانات بعد")
    /// Verbatim match with `BadanWidgets`' `SleepCopy.noData`.
    static let noSleepData = WatchCopy(en: "No sleep data yet", ar: "لا توجد بيانات نوم بعد")
    /// Verbatim match with `BadanWidgets`' `RingCopy.provisional`/`SleepCopy.provisional`.
    static let provisional = WatchCopy(en: "Provisional", ar: "أولي")
    /// Verbatim match with `EffortCard`'s own `Copy.updated` template (`Features/Home/
    /// HomeScreen.swift`) — same concept, same words, on a different surface.
    static let updatedTemplate = WatchCopy(en: "Updated {time}", ar: "حُدّث {time}")
    /// New copy (A22/EPIC-42) for a genuinely new state no widget has ever needed — see
    /// `Snapshot/SnapshotFreshness.swift`'s header for why a watch, unlike a same-device widget,
    /// can go meaningfully stale. Plainly states what's true (the watch has not synced recently)
    /// without alarm-toned language, matching this app's wellness-safe register.
    static let staleTemplate = WatchCopy(
        en: "Not synced recently — last update {time}",
        ar: "لم تتم المزامنة مؤخراً — آخر تحديث {time}")
    static let neverSynced = WatchCopy(
        en: "Not synced with your phone yet", ar: "لم تتم المزامنة مع هاتفك بعد")
    static let openPhoneHint = WatchCopy(
        en: "Open BADAN on your phone nearby to sync.", ar: "افتح بدن على هاتفك القريب للمزامنة.")

    // MARK: - Detail-screen explainers (the "bit more detail than a widget can show")
    //
    // Short, static, generic sentences describing what each metric IS — never a personalized
    // guidance sentence (those are computed phone-side and are not part of the bounded snapshot;
    // fabricating one here would violate this app's "never invent data" discipline). Adapted in
    // spirit from `registry.json`'s own English-only `explainerEn` text for the same metric ids
    // (`readiness.score`/`effort.day`/`sleep.performance`), with real Arabic translations added
    // here since that file carries no `explainerAr`.
    static let readinessExplainer = WatchCopy(
        en: "A summary of how your overnight signals compare with your own usual pattern.",
        ar: "ملخص لكيفية مقارنة مؤشراتك الليلية بنمطك المعتاد.")
    static let effortExplainer = WatchCopy(
        en: "How much cardiovascular work today has added up to, based on time in each heart-rate zone.",
        ar: "مقدار الجهد القلبي الذي تراكم اليوم، استناداً إلى الوقت في كل نطاق لمعدل ضربات القلب.")
    static let sleepExplainer = WatchCopy(
        en: "How well last night's sleep met your body's usual need.",
        ar: "مدى تلبية نوم الليلة الماضية لحاجة جسمك المعتادة.")
}
