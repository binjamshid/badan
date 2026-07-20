import Foundation

/// EPIC-19 runtime copy: everything an intent *says back* and everything the in-app setup guide
/// shows.
///
/// Split from `Localizable.strings` on purpose, and the split is not cosmetic. Static intent
/// metadata — intent titles, parameter titles, Siri phrases — is extracted at build time and
/// rendered by Shortcuts/Siri in the **system** language, so it has to be a
/// `LocalizedStringResource` backed by a strings table. Everything here is produced at runtime by
/// BADAN itself, so it follows the **app's** language toggle like every other string the user
/// reads inside the product. A user who set BADAN to Arabic on an English phone gets Arabic
/// answers, which is the behavior `CustomizationProfile.language` promises everywhere else.
///
/// Wellness-safe and promise-safe: nothing here states a wall-clock guarantee, and the words
/// "cron", "guaranteed" and "every day at" do not appear (plan §4 rule 10 / §13.7).
enum IntentStrings {

    // MARK: - Run export template

    static let exportFinished = LocalizedString(
        en: "Export ready: {files} file(s) from {count} record(s).",
        ar: "التصدير جاهز: {files} من الملفات تضم {count} من السجلات.")
    static let exportNothingInRange = LocalizedString(
        en: "Nothing to export in that window — BADAN found no records in range. The attempt is "
            + "in your export history.",
        ar: "لا شيء لتصديره في تلك الفترة — لم يجد بدن أي سجلات ضمن النطاق. وقد سُجّلت المحاولة "
            + "في سجل التصدير لديك.")
    static let exportTemplateNotFound = LocalizedString(
        en: "BADAN has no export template by that name. Open BADAN to see your templates.",
        ar: "لا يوجد في بدن قالب تصدير بهذا الاسم. افتح بدن لعرض قوالبك.")
    static let exportSensitiveNeedsTheApp = LocalizedString(
        en: "That template includes medications and symptoms. Those export only from inside "
            + "BADAN, where you confirm the run and set the passphrase that encrypts the file.",
        ar: "يشمل هذا القالب الأدوية والأعراض. ولا تُصدَّر هذه إلا من داخل بدن، حيث تؤكّد التشغيل "
            + "وتحدّد عبارة المرور التي تُشفَّر بها الملفات.")
    static let exportFailed = LocalizedString(
        en: "BADAN couldn't finish that export. The failed attempt is recorded in your export "
            + "history.",
        ar: "لم يتمكّن بدن من إتمام هذا التصدير. وقد سُجّلت المحاولة الفاشلة في سجل التصدير لديك.")
    /// Shown when a `sinceLastRun` template runs. Says what actually happened rather than
    /// pretending the incremental path exists — see `IntentExportService.resolvedWindow`.
    static let sinceLastRunFallbackNotice = LocalizedString(
        en: "This template asks for everything since its last run. BADAN can't do that yet, so it "
            + "exported the last 30 days instead.",
        ar: "يطلب هذا القالب كل ما استجدّ منذ آخر تشغيل له. لا يستطيع بدن ذلك بعد، فصدّر آخر ٣٠ "
            + "يوماً بدلاً من ذلك.")

    // MARK: - Latest score

    static let scoreReadiness = LocalizedString(en: "Readiness", ar: "الجاهزية")
    static let scoreSleepEfficiency = LocalizedString(en: "Sleep efficiency", ar: "كفاءة النوم")
    static let scoreAnswer = LocalizedString(
        en: "{label} for {date}: {value}.",
        ar: "{label} ليوم {date}: {value}.")
    /// The provisional case is a separate sentence rather than a parenthetical because it changes
    /// what the number means: BADAN is still learning this person's usual range.
    static let scoreAnswerProvisional = LocalizedString(
        en: "{label} for {date}: {value}. BADAN is still learning your usual range, so this one "
            + "may move.",
        ar: "{label} ليوم {date}: {value}. ما زال بدن يتعرّف على نطاقك المعتاد، لذا قد تتغيّر هذه "
            + "القيمة.")
    static let scoreUnavailable = LocalizedString(
        en: "No {label} value yet. BADAN works this out from your own history and doesn't have "
            + "enough of it so far.",
        ar: "لا توجد قيمة {label} بعد. يحسب بدن هذا من سجلّك الخاص، وما لديه منه لا يكفي حتى الآن.")

    // MARK: - Log water

    static let waterLogged = LocalizedString(
        en: "Logged {amount} of water.",
        ar: "تم تسجيل {amount} من الماء.")
    static let waterAmountOutOfRange = LocalizedString(
        en: "That doesn't look like a drink BADAN can log. Enter between 1 and 5000 ml.",
        ar: "لا يبدو هذا مقداراً يمكن لبدن تسجيله. أدخل قيمة بين ١ و٥٠٠٠ مل.")
    static let waterSaveFailed = LocalizedString(
        en: "BADAN couldn't save that entry.",
        ar: "لم يتمكّن بدن من حفظ هذا الإدخال.")
    static let milliliters = LocalizedString(en: "ml", ar: "مل")

    // MARK: - Setup guide

    static let guideTitle = LocalizedString(en: "Run an export at a set time", ar: "تشغيل تصدير في وقت محدّد")
    static let guideLead = LocalizedString(
        en: "iOS has no way for an app to run itself at a fixed time. Shortcuts does have one, "
            + "and BADAN can be the action it runs — so this is set up in Shortcuts, not here.",
        ar: "لا يتيح iOS لأي تطبيق أن يشغّل نفسه في وقت ثابت. أما اختصارات فيتيح ذلك، ويمكن أن "
            + "يكون بدن هو الإجراء الذي تشغّله — لذا يُضبط هذا في اختصارات لا هنا.")

    static let guideBeforeYouStartHeader = LocalizedString(en: "Before you set this up", ar: "قبل أن تبدأ")
    /// The sanctioned §13.7 line (table row "Shortcuts time-of-day"), verbatim in English. This is
    /// the sentence the epic exists to make sure the user reads *before* they turn anything on.
    static let guideUnlockRule = LocalizedString(
        en: "Runs at your chosen time via Shortcuts; iPhone must be unlocked.",
        ar: "يعمل في الوقت الذي تختاره عبر اختصارات؛ ويجب أن يكون الآيفون غير مقفل.")
    static let guideUnlockDetail = LocalizedString(
        en: "If your iPhone is locked when the time comes, the automation waits — BADAN is never "
            + "told the moment passed. That is an iOS rule, not a BADAN setting, and no app can "
            + "work around it. So treat the time you pick as a reminder, not an appointment.",
        ar: "إذا كان آيفونك مقفلاً عند حلول الوقت، ينتظر التشغيل التلقائي — ولا يُبلَّغ بدن بأن "
            + "الوقت قد مرّ. هذه قاعدة في iOS لا إعداد في بدن، ولا يستطيع أي تطبيق تجاوزها. "
            + "فاعتبر الوقت الذي تختاره تذكيراً لا موعداً مؤكداً.")
    static let guideLedgerNote = LocalizedString(
        en: "Every run BADAN does see is written to your export history — including the ones that "
            + "found nothing and the ones that failed. If it isn't there, it didn't run.",
        ar: "كل تشغيل يراه بدن يُكتب في سجل التصدير لديك — بما في ذلك ما لم يجد شيئاً وما أخفق. "
            + "وإن لم يكن موجوداً هناك فهو لم يعمل.")
    static let guideSensitiveNote = LocalizedString(
        en: "Templates that include medications, symptoms or routes can't run this way. They need "
            + "you present, to confirm the run and set a passphrase.",
        ar: "القوالب التي تشمل الأدوية أو الأعراض أو المسارات لا يمكن تشغيلها بهذه الطريقة. فهي "
            + "تتطلّب حضورك لتأكيد التشغيل وتحديد عبارة مرور.")

    static let guideStepsHeader = LocalizedString(en: "In the Shortcuts app", ar: "في تطبيق اختصارات")
    static let guideStep1 = LocalizedString(
        en: "Open Shortcuts and go to the Automation tab.",
        ar: "افتح اختصارات وانتقل إلى تبويب التشغيل التلقائي.")
    static let guideStep2 = LocalizedString(
        en: "Tap + to create a new personal automation.",
        ar: "اضغط + لإنشاء تشغيل تلقائي شخصي جديد.")
    static let guideStep3 = LocalizedString(
        en: "Choose \"Time of Day\", pick your time, and choose how often it repeats.",
        ar: "اختر «وقت من اليوم»، وحدّد وقتك، واختر عدد مرات التكرار.")
    static let guideStep4 = LocalizedString(
        en: "Choose \"Run Immediately\" so it doesn't stop to ask you each time.",
        ar: "اختر «التشغيل فوراً» حتى لا يتوقف ليسألك في كل مرة.")
    static let guideStep5 = LocalizedString(
        en: "Add an action, search for BADAN, and pick \"Run export template\".",
        ar: "أضف إجراءً، وابحث عن بدن، ثم اختر «تشغيل قالب تصدير».")
    static let guideStep6 = LocalizedString(
        en: "Tap the template field and choose which of your export templates it should run.",
        ar: "اضغط حقل القالب واختر أيّاً من قوالب التصدير لديك ينبغي تشغيله.")
    static let guideStep7 = LocalizedString(
        en: "Add \"Save File\" after it if you want the export filed somewhere automatically.",
        ar: "أضف بعده «حفظ ملف» إن أردت حفظ التصدير في مكان ما تلقائياً.")

    static let guideOpenShortcuts = LocalizedString(en: "Open Shortcuts", ar: "فتح اختصارات")
    static let guideShortcutsMissing = LocalizedString(
        en: "Shortcuts isn't available on this device. You can reinstall it from the App Store.",
        ar: "تطبيق اختصارات غير متاح على هذا الجهاز. يمكنك إعادة تثبيته من App Store.")

    static let guideOtherWaysHeader = LocalizedString(en: "The other ways BADAN can run", ar: "الطرق الأخرى لتشغيل بدن")
    static let guideWhenYouOpen = LocalizedString(
        en: "When you open BADAN — always, immediately.",
        ar: "عند فتحك بدن — دائماً وفوراً.")
    static let guideManualRun = LocalizedString(
        en: "When you tap Create export — always, immediately.",
        ar: "عند ضغطك «إنشاء التصدير» — دائماً وفوراً.")
    static let guideBackground = LocalizedString(
        en: "In the background — best-effort. iOS decides when, and sometimes it doesn't.",
        ar: "في الخلفية — بأفضل جهد ممكن. يقرّر iOS متى، وأحياناً لا يفعل.")
    static let guideShortcutsRow = LocalizedString(
        en: "Via a Shortcuts automation — at your chosen time, if the iPhone is unlocked.",
        ar: "عبر تشغيل تلقائي في اختصارات — في الوقت الذي تختاره، إن كان الآيفون غير مقفل.")

    static let guideEntryPointTitle = LocalizedString(en: "Shortcuts & Siri", ar: "الاختصارات وSiri")
    static let guideEntryPointSubtitle = LocalizedString(
        en: "Run an export by voice, or at a time you choose",
        ar: "شغّل تصديراً بصوتك، أو في وقت تختاره")
}
