import Foundation

/// The app-wide string catalog. Every user-facing string in a shipped screen lives here (or
/// as an inline `LocalizedString`) with both English and Arabic, so a screen literally cannot
/// ship English-only. Wellness-safe wording only — no diagnosis/treatment/alarm language.
enum Loc {
    // MARK: Tabs / navigation
    static let tabToday = LocalizedString(en: "Today", ar: "اليوم")
    static let tabBody = LocalizedString(en: "Body", ar: "الجسم")
    static let tabLog = LocalizedString(en: "Log", ar: "تسجيل")
    static let tabInsights = LocalizedString(en: "Insights", ar: "ملاحظات")
    static let tabSettings = LocalizedString(en: "Settings", ar: "الإعدادات")

    // MARK: Common actions
    static let save = LocalizedString(en: "Save", ar: "حفظ")
    static let saveAndAddAnother = LocalizedString(en: "Save & add another", ar: "حفظ وإضافة آخر")
    static let cancel = LocalizedString(en: "Cancel", ar: "إلغاء")
    static let done = LocalizedString(en: "Done", ar: "تم")
    static let add = LocalizedString(en: "Add", ar: "إضافة")
    static let edit = LocalizedString(en: "Edit", ar: "تعديل")
    static let delete = LocalizedString(en: "Delete", ar: "حذف")
    static let close = LocalizedString(en: "Close", ar: "إغلاق")
    static let next = LocalizedString(en: "Next", ar: "التالي")
    static let back = LocalizedString(en: "Back", ar: "رجوع")
    static let skip = LocalizedString(en: "Skip", ar: "تخطٍّ")
    static let seeAll = LocalizedString(en: "See all", ar: "عرض الكل")
    static let seeTrends = LocalizedString(en: "See trends", ar: "عرض الاتجاهات")
    static let why = LocalizedString(en: "Why?", ar: "لماذا؟")
    static let today = LocalizedString(en: "Today", ar: "اليوم")
    static let search = LocalizedString(en: "Search", ar: "بحث")

    // MARK: Home
    static let homeGreetingMorning = LocalizedString(en: "Good morning", ar: "صباح الخير")
    static let homeGreetingAfternoon = LocalizedString(en: "Good afternoon", ar: "طاب مساؤك")
    static let homeGreetingEvening = LocalizedString(en: "Good evening", ar: "مساء الخير")
    static let readiness = LocalizedString(en: "Readiness", ar: "الجاهزية")
    static let lastNight = LocalizedString(en: "Last night", ar: "الليلة الماضية")
    static let backToToday = LocalizedString(en: "Back to today", ar: "العودة إلى اليوم")
    static let dataPaused = LocalizedString(en: "Your data has been paused for a while — let's reconnect.",
                                            ar: "توقّفت بياناتك منذ فترة — لنعِد الاتصال.")
    static let nothingYet = LocalizedString(en: "Nothing here yet", ar: "لا شيء هنا بعد")

    // MARK: Body / metrics
    static let bodyTitle = LocalizedString(en: "Your body", ar: "جسمك")
    static let allMetrics = LocalizedString(en: "All metrics", ar: "كل المؤشرات")
    static let dataSources = LocalizedString(en: "Data sources", ar: "مصادر البيانات")
    static let rawData = LocalizedString(en: "Raw data", ar: "البيانات الخام")
    static let exportData = LocalizedString(en: "Export", ar: "تصدير")
    static let inYourRange = LocalizedString(en: "In your usual range", ar: "ضمن نطاقك المعتاد")
    static let aboveYourRange = LocalizedString(en: "Above your usual range", ar: "أعلى من نطاقك المعتاد")
    static let belowYourRange = LocalizedString(en: "Below your usual range", ar: "أقل من نطاقك المعتاد")
    static let stillLearning = LocalizedString(en: "Still learning your baseline", ar: "ما زلنا نتعرّف على مستواك المعتاد")
    static let provenance = LocalizedString(en: "Where this came from", ar: "مصدر هذه البيانات")
    static let anatomyTitle = LocalizedString(en: "How this was worked out", ar: "كيف تم حساب هذا")
    static let contributingRecords = LocalizedString(en: "Records used", ar: "السجلات المستخدمة")
    static let algorithm = LocalizedString(en: "Method", ar: "الطريقة")
    static let personalRange = LocalizedString(en: "Your typical range", ar: "نطاقك المعتاد")
    static let noDataMetric = LocalizedString(en: "No data yet — connect a source or log it to feed this.",
                                              ar: "لا بيانات بعد — اربط مصدراً أو سجّلها لتغذية هذا.")

    // MARK: Timeline
    static let timeline = LocalizedString(en: "Timeline", ar: "الخط الزمني")
    static let clearFilters = LocalizedString(en: "Clear filters", ar: "مسح عوامل التصفية")
    static let historyStart = LocalizedString(en: "Your record begins here", ar: "يبدأ سجلّك هنا")
    static let noEventsInRange = LocalizedString(en: "No events in this range", ar: "لا أحداث في هذه الفترة")

    // MARK: Log hub
    static let logTitle = LocalizedString(en: "What would you like to log?", ar: "ماذا تريد أن تسجّل؟")
    static let logSymptom = LocalizedString(en: "Symptom", ar: "عرض")
    static let logMedication = LocalizedString(en: "Medication", ar: "دواء")
    static let logWorkout = LocalizedString(en: "Workout", ar: "تمرين")
    static let logFood = LocalizedString(en: "Food", ar: "طعام")
    static let logWater = LocalizedString(en: "Water", ar: "ماء")
    static let logWeight = LocalizedString(en: "Weight", ar: "الوزن")
    static let logNote = LocalizedString(en: "Note", ar: "ملاحظة")
    static let recents = LocalizedString(en: "Recent", ar: "الأخيرة")

    // MARK: Symptoms
    static let severity = LocalizedString(en: "Severity", ar: "الشدة")
    static let mild = LocalizedString(en: "Mild", ar: "خفيف")
    static let moderate = LocalizedString(en: "Moderate", ar: "متوسط")
    static let severe = LocalizedString(en: "Severe", ar: "شديد")
    static let triggers = LocalizedString(en: "Triggers", ar: "المحفزات")
    static let notePlaceholder = LocalizedString(en: "Add a note (optional)", ar: "أضف ملاحظة (اختياري)")
    static let chooseSymptom = LocalizedString(en: "Choose or search a symptom", ar: "اختر أو ابحث عن عرض")

    // MARK: Medications
    static let medsDue = LocalizedString(en: "Due", ar: "مستحق")
    static let stillDue = LocalizedString(en: "Still due", ar: "ما زال مستحقاً")
    static let takeAll = LocalizedString(en: "Take all", ar: "تناول الكل")
    static let taken = LocalizedString(en: "Taken", ar: "تم تناوله")
    static let skip_ = LocalizedString(en: "Skip", ar: "تخطٍّ")
    static let skipped = LocalizedString(en: "Skipped", ar: "تم تخطّيه")
    static let allDone = LocalizedString(en: "All done for now", ar: "انتهى كل شيء الآن")
    static let addMedication = LocalizedString(en: "Add a medication", ar: "إضافة دواء")
    static let medicationName = LocalizedString(en: "Name", ar: "الاسم")
    static let strength = LocalizedString(en: "Strength", ar: "التركيز")
    static let schedule = LocalizedString(en: "Schedule", ar: "الجدول")
    static let medsBoundary = LocalizedString(en: "BADAN records your medications — it never advises on dosing.",
                                              ar: "بدن يسجّل أدويتك — ولا يقدّم أي نصيحة حول الجرعات.")

    // MARK: Workout
    static let activityType = LocalizedString(en: "Activity", ar: "النشاط")
    static let duration = LocalizedString(en: "Duration", ar: "المدة")
    static let effort = LocalizedString(en: "Effort", ar: "الجهد")
    static let recoveryDay = LocalizedString(en: "Recovery day", ar: "يوم تعافٍ")

    // MARK: Nutrition
    static let describeFood = LocalizedString(en: "Describe what you ate", ar: "صف ما تناولته")
    static let mealType = LocalizedString(en: "Meal", ar: "الوجبة")
    static let calories = LocalizedString(en: "Calories", ar: "السعرات")
    static let quickCalories = LocalizedString(en: "Quick calories (low detail)", ar: "سعرات سريعة (تفاصيل قليلة)")

    // MARK: Export
    static let exportTitle = LocalizedString(en: "Export your data", ar: "تصدير بياناتك")
    static let exportEverything = LocalizedString(en: "Everything, always — your data is yours.",
                                                  ar: "كل شيء، دائماً — بياناتك ملكك.")
    static let exportFormat = LocalizedString(en: "Format", ar: "الصيغة")
    static let exportScope = LocalizedString(en: "What to include", ar: "ما الذي تريد تضمينه")
    static let includeRaw = LocalizedString(en: "Raw records", ar: "السجلات الخام")
    static let includeDerived = LocalizedString(en: "Computed values", ar: "القيم المحسوبة")
    static let includeSuppressed = LocalizedString(en: "Suppressed duplicates", ar: "المكرّرات المستبعدة")
    static let includeSensitive = LocalizedString(en: "Meds & symptoms", ar: "الأدوية والأعراض")
    static let runExport = LocalizedString(en: "Create export", ar: "إنشاء التصدير")
    static let share = LocalizedString(en: "Share", ar: "مشاركة")
    static let exportDisclaimer = LocalizedString(
        en: "Personal wellness records from consumer devices and self-reports; not a medical record; accuracy varies by device.",
        ar: "سجلات عافية شخصية من أجهزة استهلاكية وإدخالات ذاتية؛ ليست سجلاً طبياً؛ وتختلف الدقة حسب الجهاز.")

    // MARK: Settings
    static let settingsTitle = LocalizedString(en: "Settings", ar: "الإعدادات")
    static let appearance = LocalizedString(en: "Appearance", ar: "المظهر")
    static let appIcon = LocalizedString(en: "App Icon", ar: "أيقونة التطبيق")
    static let language = LocalizedString(en: "Language", ar: "اللغة")
    static let arabicDigits = LocalizedString(en: "Arabic numerals", ar: "الأرقام العربية")
    static let depthLevel = LocalizedString(en: "Detail level", ar: "مستوى التفصيل")
    static let units = LocalizedString(en: "Units", ar: "الوحدات")
    static let modules = LocalizedString(en: "Home modules", ar: "وحدات الشاشة الرئيسية")
    static let notifications = LocalizedString(en: "Notifications", ar: "الإشعارات")
    static let privacy = LocalizedString(en: "Data & privacy", ar: "البيانات والخصوصية")
    static let deviceOnly = LocalizedString(en: "On this device only", ar: "على هذا الجهاز فقط")
    // COMP-09: this used to read "Reset demo data," but the control wipes every database on
    // the device (medications/symptoms, workouts, nutrition, notes, ingested history) before
    // re-seeding sample data — say so plainly rather than implying only bundled demo content
    // is affected.
    static let deleteAllData = LocalizedString(en: "Delete all data", ar: "حذف جميع البيانات")
    static let localFirstNote = LocalizedString(
        en: "Everything stays on your device. BADAN makes no network calls in this version.",
        ar: "كل شيء يبقى على جهازك. لا يجري بدن أي اتصال بالشبكة في هذا الإصدار.")

    // MARK: Onboarding
    static let welcomeTitle = LocalizedString(en: "Welcome to BADAN", ar: "مرحباً بك في بدن")
    static let welcomeSubtitle = LocalizedString(en: "Your private health repository.", ar: "مستودع صحتك الخاص.")
    static let continueWithoutConnecting = LocalizedString(en: "Continue without connecting", ar: "المتابعة دون اتصال")

    // MARK: Onboarding — first fact (NEW-01)
    // Wellness-safe baseline-statement fallback used by `FirstFact` when no generated insight
    // exists yet — hedged ("about", "lately"), self-referenced, no "healthy/normal" framing,
    // matching `insight_templates.json`'s wellnessRules.
    static let firstFactSleepBaseline = LocalizedString(
        en: "You've been averaging about {value} of sleep lately.",
        ar: "كنت تنام بمعدّل {value} تقريباً في الفترة الأخيرة.")
    static let firstFactRHRBaseline = LocalizedString(
        en: "Your resting heart rate has been averaging about {value} lately.",
        ar: "كان معدّل نبضك أثناء الراحة حوالي {value} تقريباً في الفترة الأخيرة.")

    // MARK: Depth / provenance labels
    static let simpleView = LocalizedString(en: "Simple", ar: "مبسّط")
    static let detailedView = LocalizedString(en: "Detailed", ar: "مفصّل")
    static let suppressedDuplicate = LocalizedString(en: "Suppressed duplicate", ar: "نسخة مكرّرة مستبعدة")
    static let reversible = LocalizedString(en: "This can be reversed", ar: "يمكن التراجع عن هذا")

    /// Time-of-day greeting for a given hour (0-23).
    ///
    /// Intentionally keyed off the device's current wall-clock hour rather than routed
    /// through `DayAttribution`'s tz-aware helpers (unlike readiness lookback, sleep
    /// local-night, meds weekday, or day grouping): a greeting should reflect the moment
    /// the user is actually experiencing right now, not a recorded data timezone. This is
    /// a deliberate, documented exception to the app's "no wall-clock in domain code"
    /// convention (see `Clock.swift`), not an oversight.
    static func greeting(forHour hour: Int) -> LocalizedString {
        switch hour {
        case 5..<12: return homeGreetingMorning
        case 12..<18: return homeGreetingAfternoon
        default: return homeGreetingEvening
        }
    }

    // MARK: Home — depth toggle (UX-06)
    // Home's DepthBadge became tappable (casual <-> power); these are its accessibility hint,
    // phrased per current depth so VoiceOver announces where the tap will land.
    static let depthToggleHintToDetailed = LocalizedString(
        en: "Double tap to switch to detailed view", ar: "اضغط مرتين للتبديل إلى العرض المفصّل")
    static let depthToggleHintToSimple = LocalizedString(
        en: "Double tap to switch to simple view", ar: "اضغط مرتين للتبديل إلى العرض المبسّط")
}
