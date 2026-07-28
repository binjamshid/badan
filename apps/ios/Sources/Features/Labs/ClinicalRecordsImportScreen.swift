import SwiftUI

/// LAB-11's surface: import lab results a provider has already shared into Apple Health.
///
/// The honesty rules this screen holds to, which are the reason it is a screen rather than a
/// silent background sync:
///
/// 1. **Nothing is imported without the person asking.** Clinical records are the most sensitive
///    data BADAN touches; a background importer that quietly pulled them in would be indefensible
///    even with the entitlement granted.
/// 2. **An empty result is never reported as a denial.** HealthKit deliberately never tells an app
///    that a read was refused — so "no records found" and "you said no" are indistinguishable from
///    inside the app, and this screen says exactly that rather than guessing which happened.
/// 3. **Nothing is graded.** Imported values keep the provider's own reference interval and their
///    own abnormal flag; BADAN adds no verdict of its own.
struct ClinicalRecordsImportScreen: View {
    @Environment(AppEnvironment.self) private var env

    /// Injected so tests and previews can drive the flow without HealthKit. Production passes the
    /// real store.
    let store: ClinicalRecordStorePort

    @State private var phase: Phase = .idle
    @State private var outcome: ClinicalRecordImporter.Outcome?

    private enum Phase: Equatable {
        case idle
        case working
        case done
        case unavailable
        case failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                LText(ClinicalImportStrings.intro)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                BadanCard {
                    VStack(alignment: .leading, spacing: BadanSpace.space2) {
                        bullet(ClinicalImportStrings.pointReadOnly)
                        bullet(ClinicalImportStrings.pointStaysLocal)
                        bullet(ClinicalImportStrings.pointNoVerdict)
                    }
                }

                actionSection
                if let outcome { resultSection(outcome) }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(ClinicalImportStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !store.isAvailable() { phase = .unavailable }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        switch phase {
        case .unavailable:
            LText(ClinicalImportStrings.unavailable)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .working:
            HStack(spacing: BadanSpace.space2) {
                ProgressView().controlSize(.small)
                LText(ClinicalImportStrings.working)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        default:
            Button {
                Task { await runImport() }
            } label: {
                LText(phase == .done ? ClinicalImportStrings.checkAgain : ClinicalImportStrings.importAction)
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control))
            }
            .buttonStyle(.plain)
        }

        if phase == .failed {
            LText(ClinicalImportStrings.failed)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.outOfBand)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultSection(_ outcome: ClinicalRecordImporter.Outcome) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                if outcome.resultsImported > 0 {
                    Text(ClinicalImportStrings.imported
                        .filling(["results": env.format.integer(outcome.resultsImported),
                                  "reports": env.format.integer(outcome.reportsCreated)])
                        .resolved(env.language))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                } else {
                    // Rule 2: this covers BOTH "nothing there" and "access refused", because
                    // HealthKit does not distinguish them. Saying so, and pointing at Settings, is
                    // more useful than picking one and being wrong half the time.
                    LText(ClinicalImportStrings.nothingFound)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Counted and shown rather than hidden: "imported 0" with 14 records on file reads
                // as a broken feature unless it says they were already here.
                if outcome.duplicatesSkipped > 0 {
                    Text(ClinicalImportStrings.alreadyHad
                        .filling(["n": env.format.integer(outcome.duplicatesSkipped)])
                        .resolved(env.language))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                if outcome.skippedMissingDate > 0 {
                    Text(ClinicalImportStrings.skippedNoDate
                        .filling(["n": env.format.integer(outcome.skippedMissingDate)])
                        .resolved(env.language))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private func bullet(_ text: LocalizedString) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            LText(text)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runImport() async {
        phase = .working
        outcome = nil
        guard await store.requestAuthorization() else {
            phase = .failed
            return
        }
        let payloads = await store.fetchLabRecords()
        let reports = LabReportRepository(sensitive: env.database.sensitive)
        let results = LabResultRepository(sensitive: env.database.sensitive)
        let matcher = AnalyteNameMatcher.loadFromBundle()
        let clock = env.clock
        let deviceId = env.deviceId

        var total = ClinicalRecordImporter.Outcome()
        do {
            // Grouped by provider so each batch is filed under its own source name, rather than
            // collapsing several providers' results into one anonymous "Apple Health" report.
            for (sourceName, payloads) in Dictionary(grouping: payloads, by: \.sourceName) {
                let observations = payloads.flatMap { FHIRObservationParser.parse($0.data) }
                guard !observations.isEmpty else { continue }
                let batch = ClinicalRecordImporter.Batch(sourceName: sourceName, observations: observations)
                let result = try ClinicalRecordImporter.import(
                    batch, reports: reports, results: results, analyteMatcher: matcher,
                    clock: clock, deviceId: deviceId)
                total.reportsCreated += result.reportsCreated
                total.resultsImported += result.resultsImported
                total.duplicatesSkipped += result.duplicatesSkipped
                total.skippedMissingDate += result.skippedMissingDate
            }
        } catch {
            LoadErrorLog.log(error, screen: "ClinicalRecordsImport")
            phase = .failed
            return
        }

        outcome = total
        phase = .done
        if total.resultsImported > 0 { env.bumpDataGeneration() }
    }
}

enum ClinicalImportStrings {
    static let title = LocalizedString(en: "Import from Health", ar: "استيراد من الصحة")
    static let openImport = LocalizedString(en: "Import from Apple Health", ar: "استيراد من صحة أبل")
    static let intro = LocalizedString(
        en: "If your clinic or lab shares results into Apple Health, BADAN can bring those lab results into your notebook.",
        ar: "إذا كانت عيادتك أو مختبرك يشارك النتائج مع تطبيق صحة أبل، يمكن لبدن جلب نتائج المختبر تلك إلى دفترك.")
    static let pointReadOnly = LocalizedString(
        en: "BADAN only reads. It never changes or adds anything in Apple Health.",
        ar: "يقرأ بدن فقط. لا يغيّر أو يضيف شيئًا في تطبيق صحة أبل.")
    static let pointStaysLocal = LocalizedString(
        en: "Imported results are stored encrypted on this device, with the rest of your lab notebook.",
        ar: "تُخزَّن النتائج المستوردة مشفّرة على هذا الجهاز، مع بقية دفتر مختبرك.")
    static let pointNoVerdict = LocalizedString(
        en: "Your lab's own reference range and flags are kept as they were. BADAN adds no judgement of its own.",
        ar: "يُحتفظ بالنطاق المرجعي وعلامات مختبرك كما هي. ولا يضيف بدن حكمًا من عنده.")

    static let importAction = LocalizedString(en: "Import lab results", ar: "استيراد نتائج المختبر")
    static let checkAgain = LocalizedString(en: "Check for new results", ar: "ابحث عن نتائج جديدة")
    static let working = LocalizedString(en: "Looking…", ar: "جارٍ البحث…")
    static let imported = LocalizedString(en: "Imported {results} results into {reports} reports.",
                                          ar: "تم استيراد {results} نتيجة ضمن {reports} تقارير.")
    static let alreadyHad = LocalizedString(en: "{n} were already in your notebook.",
                                            ar: "{n} كانت موجودة في دفترك بالفعل.")
    static let skippedNoDate = LocalizedString(
        en: "{n} had no readable date, so they were left out rather than filed under the wrong day.",
        ar: "{n} بلا تاريخ مقروء، فتُركت بدل حفظها تحت يوم خاطئ.")
    static let nothingFound = LocalizedString(
        en: "No lab results came back. That can mean there are none connected yet, or that BADAN wasn't given access — Apple doesn't tell apps which. You can check under Settings › Health › Data Access.",
        ar: "لم ترد أي نتائج مختبر. قد يعني ذلك عدم وجود نتائج متصلة بعد، أو أن بدن لم يُمنح الإذن — ولا تخبر أبل التطبيقات بأيهما. يمكنك التحقق من الإعدادات › الصحة › الوصول إلى البيانات.")
    static let unavailable = LocalizedString(
        en: "Health records aren't available on this device. Apple only offers them in some countries and with participating clinics.",
        ar: "السجلات الصحية غير متاحة على هذا الجهاز. توفّرها أبل في بعض الدول ومع عيادات مشاركة فقط.")
    static let failed = LocalizedString(en: "That didn't work. Nothing was changed.",
                                        ar: "لم ينجح ذلك. لم يتغير شيء.")
}
