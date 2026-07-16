package net.albayyan.badan.core

/**
 * The app-wide string catalog. Every user-facing string in a shipped screen lives here (or
 * as an inline [LocalizedString]) with both English and Arabic, so a screen literally cannot
 * ship English-only. Wellness-safe wording only — no diagnosis/treatment/alarm language.
 */
object Loc {
    // Tabs / navigation
    val tabToday = LocalizedString(en = "Today", ar = "اليوم")
    val tabBody = LocalizedString(en = "Body", ar = "الجسم")
    val tabLog = LocalizedString(en = "Log", ar = "تسجيل")
    val tabInsights = LocalizedString(en = "Insights", ar = "ملاحظات")
    val tabSettings = LocalizedString(en = "Settings", ar = "الإعدادات")

    // Common actions
    val save = LocalizedString(en = "Save", ar = "حفظ")
    val saveAndAddAnother = LocalizedString(en = "Save & add another", ar = "حفظ وإضافة آخر")
    val cancel = LocalizedString(en = "Cancel", ar = "إلغاء")
    val done = LocalizedString(en = "Done", ar = "تم")
    val add = LocalizedString(en = "Add", ar = "إضافة")
    val edit = LocalizedString(en = "Edit", ar = "تعديل")
    val delete = LocalizedString(en = "Delete", ar = "حذف")
    val close = LocalizedString(en = "Close", ar = "إغلاق")
    val next = LocalizedString(en = "Next", ar = "التالي")
    val back = LocalizedString(en = "Back", ar = "رجوع")
    val skip = LocalizedString(en = "Skip", ar = "تخطٍّ")
    val seeAll = LocalizedString(en = "See all", ar = "عرض الكل")
    val seeTrends = LocalizedString(en = "See trends", ar = "عرض الاتجاهات")
    val why = LocalizedString(en = "Why?", ar = "لماذا؟")
    val today = LocalizedString(en = "Today", ar = "اليوم")
    val search = LocalizedString(en = "Search", ar = "بحث")

    // Home
    val homeGreetingMorning = LocalizedString(en = "Good morning", ar = "صباح الخير")
    // (C4) Afternoon and evening both read "مساء الخير" here, so an Arabic user was greeted
    // identically from noon to midnight while the English build changed at each. Aligned to iOS's
    // wording — one of the drifts that comes with hand-porting a string catalog.
    val homeGreetingAfternoon = LocalizedString(en = "Good afternoon", ar = "طاب مساؤك")
    val homeGreetingEvening = LocalizedString(en = "Good evening", ar = "مساء الخير")
    val readiness = LocalizedString(en = "Readiness", ar = "الجاهزية")
    val lastNight = LocalizedString(en = "Last night", ar = "الليلة الماضية")
    val backToToday = LocalizedString(en = "Back to today", ar = "العودة إلى اليوم")
    val dataPaused = LocalizedString(
        en = "Your data has been paused for a while — let's reconnect.",
        ar = "توقّفت بياناتك منذ فترة — لنعِد الاتصال."
    )
    val nothingYet = LocalizedString(en = "Nothing here yet", ar = "لا شيء هنا بعد")

    // Body / metrics
    val bodyTitle = LocalizedString(en = "Your body", ar = "جسمك")
    val allMetrics = LocalizedString(en = "All metrics", ar = "كل المؤشرات")
    val dataSources = LocalizedString(en = "Data sources", ar = "مصادر البيانات")
    val rawData = LocalizedString(en = "Raw data", ar = "البيانات الخام")
    val exportData = LocalizedString(en = "Export", ar = "تصدير")
    val inYourRange = LocalizedString(en = "In your usual range", ar = "ضمن نطاقك المعتاد")
    val aboveYourRange = LocalizedString(en = "Above your usual range", ar = "أعلى من نطاقك المعتاد")
    val belowYourRange = LocalizedString(en = "Below your usual range", ar = "أقل من نطاقك المعتاد")
    val stillLearning = LocalizedString(en = "Still learning your baseline", ar = "ما زلنا نتعرّف على مستواك المعتاد")
    val provenance = LocalizedString(en = "Where this came from", ar = "مصدر هذه البيانات")
    val anatomyTitle = LocalizedString(en = "How this was worked out", ar = "كيف تم حساب هذا")
    val contributingRecords = LocalizedString(en = "Records used", ar = "السجلات المستخدمة")
    val algorithm = LocalizedString(en = "Method", ar = "الطريقة")
    val personalRange = LocalizedString(en = "Your typical range", ar = "نطاقك المعتاد")
    val noDataMetric = LocalizedString(
        en = "No data yet — connect a source or log it to feed this.",
        ar = "لا بيانات بعد — اربط مصدراً أو سجّلها لتغذية هذا."
    )

    // Timeline
    val timeline = LocalizedString(en = "Timeline", ar = "الخط الزمني")
    val clearFilters = LocalizedString(en = "Clear filters", ar = "مسح عوامل التصفية")
    val historyStart = LocalizedString(en = "Your record begins here", ar = "يبدأ سجلّك هنا")
    val noEventsInRange = LocalizedString(en = "No events in this range", ar = "لا أحداث في هذه الفترة")

    // Log hub
    val logTitle = LocalizedString(en = "What would you like to log?", ar = "ماذا تريد أن تسجّل؟")
    val logSymptom = LocalizedString(en = "Symptom", ar = "عرض")
    val logMedication = LocalizedString(en = "Medication", ar = "دواء")
    val logWorkout = LocalizedString(en = "Workout", ar = "تمرين")
    val logFood = LocalizedString(en = "Food", ar = "طعام")
    val logWater = LocalizedString(en = "Water", ar = "ماء")
    val logWeight = LocalizedString(en = "Weight", ar = "الوزن")
    val logNote = LocalizedString(en = "Note", ar = "ملاحظة")
    val recents = LocalizedString(en = "Recent", ar = "الأخيرة")

    // Symptoms
    val severity = LocalizedString(en = "Severity", ar = "الشدة")
    val mild = LocalizedString(en = "Mild", ar = "خفيف")
    val moderate = LocalizedString(en = "Moderate", ar = "متوسط")
    val severe = LocalizedString(en = "Severe", ar = "شديد")
    val triggers = LocalizedString(en = "Triggers", ar = "المحفزات")
    val notePlaceholder = LocalizedString(en = "Add a note (optional)", ar = "أضف ملاحظة (اختياري)")
    val chooseSymptom = LocalizedString(en = "Choose or search a symptom", ar = "اختر أو ابحث عن عرض")

    // Medications
    val medsDue = LocalizedString(en = "Due", ar = "مستحق")
    val stillDue = LocalizedString(en = "Still due", ar = "ما زال مستحقاً")
    val takeAll = LocalizedString(en = "Take all", ar = "تناول الكل")
    val taken = LocalizedString(en = "Taken", ar = "تم تناوله")
    val skip_ = LocalizedString(en = "Skip", ar = "تخطٍّ")
    val skipped = LocalizedString(en = "Skipped", ar = "تم تخطّيه")
    val allDone = LocalizedString(en = "All done for now", ar = "انتهى كل شيء الآن")
    val addMedication = LocalizedString(en = "Add a medication", ar = "إضافة دواء")
    val medicationName = LocalizedString(en = "Name", ar = "الاسم")
    val strength = LocalizedString(en = "Strength", ar = "التركيز")
    val schedule = LocalizedString(en = "Schedule", ar = "الجدول")
    val medsBoundary = LocalizedString(
        en = "BADAN records your medications — it never advises on dosing.",
        ar = "بدن يسجّل أدويتك — ولا يقدّم أي نصيحة حول الجرعات."
    )

    // Workout
    val activityType = LocalizedString(en = "Activity", ar = "النشاط")
    val duration = LocalizedString(en = "Duration", ar = "المدة")
    val effort = LocalizedString(en = "Effort", ar = "الجهد")
    val recoveryDay = LocalizedString(en = "Recovery day", ar = "يوم تعافٍ")

    // Nutrition
    val describeFood = LocalizedString(en = "Describe what you ate", ar = "صف ما تناولته")
    val mealType = LocalizedString(en = "Meal", ar = "الوجبة")
    val calories = LocalizedString(en = "Calories", ar = "السعرات")
    val quickCalories = LocalizedString(en = "Quick calories (low detail)", ar = "سعرات سريعة (تفاصيل قليلة)")

    // Export
    val exportTitle = LocalizedString(en = "Export your data", ar = "تصدير بياناتك")
    val exportEverything = LocalizedString(
        en = "Everything, always — your data is yours.",
        ar = "كل شيء، دائماً — بياناتك ملكك."
    )
    val exportFormat = LocalizedString(en = "Format", ar = "الصيغة")
    val exportScope = LocalizedString(en = "What to include", ar = "ما الذي تريد تضمينه")
    val includeRaw = LocalizedString(en = "Raw records", ar = "السجلات الخام")
    val includeDerived = LocalizedString(en = "Computed values", ar = "القيم المحسوبة")
    val includeSuppressed = LocalizedString(en = "Suppressed duplicates", ar = "المكرّرات المستبعدة")
    val includeSensitive = LocalizedString(en = "Meds & symptoms", ar = "الأدوية والأعراض")
    val runExport = LocalizedString(en = "Create export", ar = "إنشاء التصدير")
    val share = LocalizedString(en = "Share", ar = "مشاركة")
    val exportDisclaimer = LocalizedString(
        en = "Personal wellness records from consumer devices and self-reports; not a medical record; accuracy varies by device.",
        ar = "سجلات عافية شخصية من أجهزة استهلاكية وإدخالات ذاتية؛ ليست سجلاً طبياً؛ وتختلف الدقة حسب الجهاز."
    )

    // Settings
    val settingsTitle = LocalizedString(en = "Settings", ar = "الإعدادات")
    val appearance = LocalizedString(en = "Appearance", ar = "المظهر")
    val language = LocalizedString(en = "Language", ar = "اللغة")
    val arabicDigits = LocalizedString(en = "Arabic numerals", ar = "الأرقام العربية")
    val depthLevel = LocalizedString(en = "Detail level", ar = "مستوى التفصيل")
    val units = LocalizedString(en = "Units", ar = "الوحدات")
    val modules = LocalizedString(en = "Home modules", ar = "وحدات الشاشة الرئيسية")
    val notifications = LocalizedString(en = "Notifications", ar = "الإشعارات")
    val privacy = LocalizedString(en = "Data & privacy", ar = "البيانات والخصوصية")
    val deviceOnly = LocalizedString(en = "On this device only", ar = "على هذا الجهاز فقط")
    /**
     * (C1) Was `resetDemo` = "Reset demo data". The action wipes both databases — every
     * medication, symptom, workout, meal and note the user ever logged — before re-seeding, so
     * the old name described the least important thing it does and hid the destructive part.
     * Renamed to match iOS's `Loc.deleteAllData` (COMP-09); the key is replaced rather than
     * kept alongside, so no call site can reach for the misleading wording again.
     */
    val deleteAllData = LocalizedString(en = "Delete all data", ar = "حذف جميع البيانات")
    val localFirstNote = LocalizedString(
        en = "Everything stays on your device. BADAN makes no network calls in this version.",
        ar = "كل شيء يبقى على جهازك. لا يجري بدن أي اتصال بالشبكة في هذا الإصدار."
    )

    // Onboarding
    val welcomeTitle = LocalizedString(en = "Welcome to BADAN", ar = "مرحباً بك في بدن")
    val welcomeSubtitle = LocalizedString(en = "Your private health repository.", ar = "مستودع صحتك الخاص.")
    val getStarted = LocalizedString(en = "Get started", ar = "لنبدأ")
    val continueWithoutConnecting = LocalizedString(en = "Continue without connecting", ar = "المتابعة دون اتصال")

    // Depth / provenance labels
    val simpleView = LocalizedString(en = "Simple", ar = "مبسّط")
    val detailedView = LocalizedString(en = "Detailed", ar = "مفصّل")
    val suppressedDuplicate = LocalizedString(en = "Suppressed duplicate", ar = "نسخة مكرّرة مستبعدة")
    val reversible = LocalizedString(en = "This can be reversed", ar = "يمكن التراجع عن هذا")

    /** Time-of-day greeting for a given hour (0-23). */
    fun greeting(forHour: Int): LocalizedString {
        return when (forHour) {
            in 5 until 12 -> homeGreetingMorning
            in 12 until 18 -> homeGreetingAfternoon
            else -> homeGreetingEvening
        }
    }
}
