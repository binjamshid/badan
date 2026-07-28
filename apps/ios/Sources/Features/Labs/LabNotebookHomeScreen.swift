import SwiftUI
import UIKit
import PDFKit

// ============================================================================
// MARK: - EPIC-41 (Phase 3E) — lab notebook MVP. Scope note.
// ============================================================================
//
// "A notebook, not a chart": original artifacts are always preserved, structure is added where
// safe, source wording is kept where not, and a missing/absent range or value is never invented.
// This slice is UI-only — it owns exactly the five screens under this folder, one edit into
// `LogHubScreen`, and `LabNotebookUITests`.
//
// By the time these screens were built, BOTH parallel lanes had already landed real domain types:
// `LabReport`/`LabResult`/`LabPanel`/`ReferenceRange`/`AnalyteDefinition`/`UserCorrection`/
// `LabAnnotation`/`DerivedTrend`/`ReferenceRangeEngine`/`UnitNormalization`/`DuplicateConflictResolver`
// (`Domain/Labs/`), `SourceDocument`/`OCRExtraction`/`OCRFieldExtraction`/`LabDocumentOCR`
// (`Domain/Labs/` + `Ingest/OCR/`), and the sensitive-DB repositories (`Storage/Repositories/
// Lab*Repository.swift`, `ReferenceRangeRepository`, `DerivedTrendRepository`,
// `SourceDocumentRepository`) plus `Storage/DocumentVault.swift`. Every screen in this folder is
// wired to those REAL types — nothing here is a placeholder.
//
// TWO DOCUMENTED, CROSS-LANE GAPS this UI works around honestly rather than papering over:
//   1. `SourceDocumentRepository`'s own header admits its `source_documents` table is not yet in
//      `Schema.sensitiveMigrations` (the domain lane's migration 5 added `lab_reports`/`lab_results`/
//      `reference_ranges`/`derived_trends`/etc., but not this one table the vault lane's repository
//      expects). Every call into `SourceDocumentRepository`/`DocumentVault` below is therefore
//      wrapped so a "no such table" failure degrades to "no document on file" rather than crashing
//      the notebook — the scanned artifact still gets OCR'd and its results still save; only the
//      original-document viewer has nothing to show until that migration lands.
//   2. `ReferenceRangeEngine.UserLabThreshold` (concept 4) is explicitly documented as NOT persisted
//      by that lane ("no Feature surface exists yet to let a user set one... Persisting a user's
//      chosen thresholds is a follow-up slice's job"). This Features/ slice IS that follow-up, so it
//      builds the UI — but keeps the threshold in-memory only for the current app session
//      (`UserThresholdStore`), since adding a persisted table/migration is `Storage/`'s job.

// MARK: - Analyte catalog (packages/contracts/analytes/analytes.json's bundled copy)

/// Reads `analytes.json` (bundled as `apps/ios/Sources/Resources/analytes.json`) into the real
/// `AnalyteDefinition` type (`Domain/Labs/LabModels.swift`). No Swift-side reader for the FULL
/// definition (category/loincCode/canonicalUnit/conversionSafetyClass) existed yet — `AnalyteNameMatcher`
/// (`Ingest/OCR/LabDocumentOCR.swift`) only reads id/name pairs for its own fuzzy OCR matcher. An
/// unrecognized marker is never blocked by this catalog being small or missing an entry — see every
/// "free text always works" path in `ManualEntryScreen`.
struct AnalyteCatalog {
    static let shared = AnalyteCatalog()

    let all: [AnalyteDefinition]

    private struct JSONRoot: Decodable { let analytes: [JSONEntry] }
    private struct JSONEntry: Decodable {
        let id: String, nameEn: String, nameAr: String, category: String
        let loincCode: String?, canonicalUnit: String, conversionSafetyClass: String
    }

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "analytes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(JSONRoot.self, from: data) else {
            all = []
            return
        }
        all = root.analytes.map { entry in
            AnalyteDefinition(
                id: entry.id, nameEn: entry.nameEn, nameAr: entry.nameAr, category: entry.category,
                loincCode: entry.loincCode, canonicalUnit: entry.canonicalUnit,
                conversionSafetyClass: ConversionSafetyClass(rawValue: entry.conversionSafetyClass) ?? .none)
        }
    }

    func definition(id: String) -> AnalyteDefinition? { all.first { $0.id == id } }

    /// Empty text returns the whole catalog (a browse list); a non-empty query that matches nothing
    /// returns an empty array — the catalog never claims to recognize a marker it doesn't.
    func matching(_ query: String, language: AppLanguage) -> [AnalyteDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        return all.filter {
            $0.displayName.resolved(language).folding(options: .diacriticInsensitive, locale: nil)
                .lowercased().contains(needle)
        }
    }
}

// MARK: - Value resolution (shared by the out-of-interval count, the trend chart, and export)

/// The value to read for one result: the safe-class canonical pair when present, else the
/// as-reported numeric pair — mirroring `ReferenceRangeEngine`'s own private `resolvedValue` (that
/// engine does not expose it, so this is a small, deliberately-matching duplicate rather than a
/// reach into a private implementation detail). Never invents a value neither field carries.
enum LabValueResolution {
    static func resolved(_ result: LabResult) -> (value: Double, unit: String)? {
        if let value = result.canonicalValue, let unit = result.canonicalUnit { return (value, unit) }
        if let value = result.numericValue, let unit = result.rawUnit { return (value, unit) }
        return nil
    }
}

/// Concept #1/#2 evaluation for one result — used ONLY for the Home screen's out-of-interval count
/// and the honest interval caption, NEVER for anything touching concept #3/#4. Numeric comparison
/// only happens when the result's own unit matches the printed interval's unit (or no interval unit
/// was recorded, the common case) — this never silently converts across units to force a comparison.
enum LabRangeEvaluation {
    static func isOutOfSourceInterval(_ result: LabResult, range: ReferenceRange?) -> Bool {
        guard let range else { return false }
        if let flag = range.sourceFlag, !flag.isEmpty { return true }
        guard range.sourceIntervalLow != nil || range.sourceIntervalHigh != nil,
              let resolved = LabValueResolution.resolved(result),
              range.sourceIntervalUnit == nil || range.sourceIntervalUnit == resolved.unit
        else { return false }
        if let low = range.sourceIntervalLow, resolved.value < low { return true }
        if let high = range.sourceIntervalHigh, resolved.value > high { return true }
        return false
    }
}

// MARK: - In-memory user-threshold store (concept #4 — documented gap, see top-of-file note)

@Observable
@MainActor
final class UserThresholdStore {
    private(set) var byAnalyteKey: [String: ReferenceRangeEngine.UserLabThreshold] = [:]

    func threshold(for analyteKey: String) -> ReferenceRangeEngine.UserLabThreshold? { byAnalyteKey[analyteKey] }

    func set(_ threshold: ReferenceRangeEngine.UserLabThreshold) { byAnalyteKey[threshold.analyteKey] = threshold }
}

// MARK: - Pending scan (in-memory bridge between Home's import action, OCRReviewScreen, and the
// eventual ManualEntryScreen commit) — the source image/PDF bytes and the on-device OCR pipeline's
// own candidate fields for one not-yet-reviewed scan. Never persisted — a scan that never reaches
// "Continue" in `OCRReviewScreen` simply vanishes with the app session, matching the rest of this
// slice's "nothing commits without an explicit user action" rule.
@Observable
@MainActor
final class PendingScanStore {
    struct Pending {
        var image: UIImage?
        var pdfData: Data?
        var fields: [OCRFieldExtraction]
    }

    var byDocumentId: [String: Pending] = [:]
}

// MARK: - This feature's repository/service bundle

/// Constructed once per `LabNotebookHomeScreen` instance and threaded down to every child screen —
/// mirrors `WorkoutSessionCoordinator`'s composition pattern (`makeWorkoutSessionCoordinator(env:)`
/// in `WorkoutHomeScreen.swift`): NOT added to `AppEnvironment` itself, since this slice's owned
/// files are exactly the five Labs screens + one `LogHubScreen` edit + tests, matching that same
/// slice's own documented reasoning for not touching `AppEnvironment.swift`.
@MainActor
struct LabNotebookServices {
    let reports: LabReportRepository
    let results: LabResultRepository
    let ranges: ReferenceRangeRepository
    let trends: DerivedTrendRepository
    let documents: SourceDocumentRepository
    /// `nil` only if `DocumentVault`'s own directory/Keychain setup throws — degrades to "no
    /// document preview available" rather than crashing the notebook.
    let vault: DocumentVault?
    let ocr = LabDocumentOCR()
    let thresholds: UserThresholdStore
    let pendingScans: PendingScanStore
    let deviceId: String

    init(env: AppEnvironment, thresholds: UserThresholdStore, pendingScans: PendingScanStore) {
        reports = LabReportRepository(sensitive: env.database.sensitive)
        results = LabResultRepository(sensitive: env.database.sensitive)
        ranges = ReferenceRangeRepository(sensitive: env.database.sensitive)
        trends = DerivedTrendRepository(sensitive: env.database.sensitive)
        documents = SourceDocumentRepository(sensitive: env.database.sensitive)
        vault = try? DocumentVault(database: env.database)
        self.thresholds = thresholds
        self.pendingScans = pendingScans
        self.deviceId = env.deviceId
    }

    /// The `ReferenceRange` for one result, or `nil` on any failure.
    func range(resultId: String) -> ReferenceRange? { try? ranges.range(resultId: resultId) }

    /// The `SourceDocument` for a report's `documentRef`, or `nil` when absent OR when the lookup
    /// throws (the documented `source_documents`-table gap — see this file's top-of-file note).
    func document(id: String) -> SourceDocument? { try? documents.document(id: id) }

    /// Decrypted original bytes for a vaulted document, or `nil` on any failure (missing vault, key
    /// issue, or the file having been purged) — never surfaced as a crash, only as an absent preview.
    func documentBytes(vaultFileRef: String) -> Data? {
        guard let vault else { return nil }
        return try? vault.retrieve(vaultFileRef: vaultFileRef)
    }
}

// MARK: - Screen-local strings

enum LabHomeStrings {
    static let title = LocalizedString(en: "Lab notebook", ar: "دفتر نتائج المختبر")
    static let subtitle = LocalizedString(
        en: "Your own lab results, kept exactly as recorded — with structure added where it's safe to add.",
        ar: "نتائج مختبرك الخاصة، محفوظة كما هي بالضبط — مع إضافة تنظيم حيث يكون ذلك آمناً.")
    static let addResult = LocalizedString(en: "Add a result", ar: "إضافة نتيجة")
    static let scanReport = LocalizedString(en: "Scan or import a report", ar: "مسح أو استيراد تقرير")
    static let choosePhoto = LocalizedString(en: "Photo of a report", ar: "صورة تقرير")
    static let choosePDF = LocalizedString(en: "PDF file", ar: "ملف PDF")
    static let recentReports = LocalizedString(en: "Recent reports", ar: "التقارير الأخيرة")
    static let changesSince = LocalizedString(en: "{n} new since your last visit", ar: "{n} جديدة منذ آخر زيارة")
    static let outOfIntervalCount = LocalizedString(
        en: "{n} outside the lab's stated interval",
        ar: "{n} خارج النطاق الذي حدده المختبر")
    static let noneOutOfInterval = LocalizedString(
        en: "Everything is inside the interval each lab printed",
        ar: "كل شيء ضمن النطاق الذي طبعه كل مختبر")
    static let emptyMessage = LocalizedString(
        en: "No lab results yet. Add one by hand, or scan a report to get started.",
        ar: "لا نتائج مختبر بعد. أضف واحدة يدوياً، أو امسح تقريراً للبدء.")
    static let exportAction = LocalizedString(en: "Export", ar: "تصدير")
    static let ocrFailed = LocalizedString(
        en: "Couldn't read that image or file. You can still enter it by hand.",
        ar: "تعذّرت قراءة هذه الصورة أو الملف. لا يزال بإمكانك إدخالها يدوياً.")
    static let loadFailed = LocalizedString(en: "Couldn't load your lab notebook right now.", ar: "تعذّر تحميل دفترك الآن.")
}

// MARK: - Pure summary rules (tested directly — see LabNotebookUITests)

enum LabHomeSummary {
    /// ONLY concept #1/#2 (`LabRangeEvaluation`) — NEVER the personal baseline (concept #3) or a
    /// user threshold (concept #4).
    static func outOfSourceIntervalCount(_ resultsWithRanges: [(result: LabResult, range: ReferenceRange?)]) -> Int {
        resultsWithRanges.filter { LabRangeEvaluation.isOutOfSourceInterval($0.result, range: $0.range) }.count
    }

    static func changesSinceLastVisit(_ reports: [LabReport], lastViewedAt: Date?) -> Int {
        guard let lastViewedAt else { return 0 }
        return reports.filter { ($0.reportedAt ?? $0.collectionAt) > lastViewedAt }.count
    }
}

/// A bare UI-state timestamp (when the notebook was last opened) — NOT health data, so it's fine to
/// persist outside the sensitive namespace, matching `SeedController.isDemoDataActive`'s existing
/// bare-`UserDefaults`-flag precedent for non-health UI state.
enum LabNotebookLastViewed {
    private static let key = "badan.labs.lastViewedAt"
    static var value: Date? {
        get { UserDefaults.standard.object(forKey: key) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Navigation routing shared by every screen in this feature folder

enum LabRoute: Hashable, Identifiable {
    case report(String)
    case marker(String)
    case ocrReview(String)
    case manualEntry(prefill: [OCRFieldExtraction], sourceDocumentId: String?)
    case export
    /// LAB-11. Its own route rather than a sheet on the scan dialog: importing from Apple Health is
    /// a different ingestion path from scanning a document, with its own consent and its own
    /// honesty copy, and burying it under "scan or import a report" would misdescribe it.
    case clinicalImport

    var id: String {
        switch self {
        case .report(let id): return "report:\(id)"
        case .marker(let key): return "marker:\(key)"
        case .ocrReview(let id): return "ocr:\(id)"
        case .manualEntry(_, let docId): return "manualEntry:\(docId ?? "blank")"
        case .export: return "export"
        case .clinicalImport: return "clinicalImport"
        }
    }

    @ViewBuilder
    func makeView(services: LabNotebookServices) -> some View {
        switch self {
        case .report(let id): ReportViewerScreen(services: services, reportId: id)
        case .marker(let key): MarkerDetailScreen(services: services, analyteKey: key)
        case .ocrReview(let id): OCRReviewScreen(services: services, documentId: id)
        case .manualEntry(let prefill, let sourceDocumentId):
            ManualEntryScreen(services: services, prefill: prefill, sourceDocumentId: sourceDocumentId)
        case .export: LabExportScreen(services: services)
        case .clinicalImport: ClinicalRecordsImportScreen(store: HealthKitClinicalStore())
        }
    }
}

// MARK: - Loaded data

private struct LabHomeData {
    var reports: [LabReport]
    var outOfIntervalCount: Int
}

// MARK: - Screen

/// The lab notebook's calm entry point: a "changes since last time" summary, an out-of-interval
/// count using ONLY concept #1 (never a computed judgment presented as if the lab said it), the
/// recent reports list, and the two ways data enters — manual entry and scan/import. Anti-panic
/// palette throughout: `BadanColor.outOfBand` (a muted amber), never a raw red, and never a
/// traffic-light/verdict word.
struct LabNotebookHomeScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var thresholds = UserThresholdStore()
    @State private var pendingScans = PendingScanStore()
    @State private var services: LabNotebookServices?
    @State private var state: LoadState<LabHomeData> = .loading
    @State private var route: LabRoute?
    @State private var showScanOptions = false
    @State private var photoImporter = false
    @State private var pdfImporter = false
    @State private var ocrErrorText: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                Text(env.s(LabHomeStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                actionsRow

                if let ocrErrorText {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(BadanColor.outOfBand).accessibilityHidden(true)
                        Text(env.s(ocrErrorText)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                    }
                }

                StatefulContainer(state, emptyIcon: "testtube.2") { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space5) {
                        summarySection(data)
                        recentReportsSection(data)
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(LabHomeStrings.title))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { route = .export } label: {
                    Label(env.s(LabHomeStrings.exportAction), systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationDestination(item: $route) { destination in
            if let services { destination.makeView(services: services) }
        }
        .confirmationDialog(env.s(LabHomeStrings.scanReport), isPresented: $showScanOptions, titleVisibility: .visible) {
            Button(env.s(LabHomeStrings.choosePhoto)) { photoImporter = true }
            Button(env.s(LabHomeStrings.choosePDF)) { pdfImporter = true }
            Button(env.s(Loc.cancel), role: .cancel) {}
        }
        .sheet(isPresented: $photoImporter) {
            LabImagePicker { image in handlePickedImage(image) }
        }
        .fileImporter(isPresented: $pdfImporter, allowedContentTypes: [.pdf]) { result in
            handlePickedPDF(result)
        }
        .task {
            if services == nil {
                services = LabNotebookServices(env: env, thresholds: thresholds, pendingScans: pendingScans)
            }
            load()
            // Recorded once per appearance, after `load()` reads the OLD marker for its own
            // "changes since last time" computation — so this same visit still shows what changed.
            LabNotebookLastViewed.value = env.now()
        }
    }

    private func load() {
        guard let services else { return }
        do {
            let reports = try services.reports.liveReports()
            var pairs: [(result: LabResult, range: ReferenceRange?)] = []
            for report in reports {
                for result in try services.results.liveResults(reportId: report.id) {
                    pairs.append((result, services.range(resultId: result.id)))
                }
            }
            let data = LabHomeData(reports: reports, outOfIntervalCount: LabHomeSummary.outOfSourceIntervalCount(pairs))
            state = reports.isEmpty ? .empty(env.s(LabHomeStrings.emptyMessage)) : .loaded(data)
        } catch {
            state = .error(env.s(LabHomeStrings.loadFailed))
        }
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: BadanSpace.space3) {
            Button { route = .manualEntry(prefill: [], sourceDocumentId: nil) } label: {
                LabActionTile(title: env.s(LabHomeStrings.addResult), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.plain)

            Button { showScanOptions = true } label: {
                LabActionTile(title: env.s(LabHomeStrings.scanReport), systemImage: "doc.viewfinder")
            }
            .buttonStyle(.plain)

            // LAB-11. A third way data enters the notebook, alongside manual entry and scanning.
            Button { route = .clinicalImport } label: {
                LabActionTile(title: env.s(ClinicalImportStrings.openImport), systemImage: "heart.text.square")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Summary

    private func summarySection(_ data: LabHomeData) -> some View {
        let changed = LabHomeSummary.changesSinceLastVisit(data.reports, lastViewedAt: LabNotebookLastViewed.value)
        return BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                if changed > 0 {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "sparkles").foregroundStyle(BadanColor.primary).accessibilityHidden(true)
                        Text(env.s(LabHomeStrings.changesSince.filling(["n": env.format.integer(changed)])))
                            .font(BadanFont.body.weight(.medium)).foregroundStyle(BadanColor.textPrimary)
                    }
                }
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: data.outOfIntervalCount > 0 ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(data.outOfIntervalCount > 0 ? BadanColor.outOfBand : BadanColor.inBand)
                        .accessibilityHidden(true)
                    Text(data.outOfIntervalCount > 0
                         ? env.s(LabHomeStrings.outOfIntervalCount.filling(["n": env.format.integer(data.outOfIntervalCount)]))
                         : env.s(LabHomeStrings.noneOutOfInterval))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Recent reports

    private func recentReportsSection(_ data: LabHomeData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(LabHomeStrings.recentReports))
            ForEach(data.reports) { report in
                Button { route = .report(report.id) } label: {
                    LabReportRow(report: report, resultCount: (try? services?.results.liveResults(reportId: report.id).count) ?? 0,
                                language: env.language)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: OCR entry points (on-device only — LabDocumentOCR, Vision framework, zero network calls)

    private func handlePickedImage(_ image: UIImage?) {
        guard let services, let image, let cgImage = image.cgImage else {
            ocrErrorText = LabHomeStrings.ocrFailed
            return
        }
        importAndScan(cgImages: [cgImage], image: image, pdfData: nil, services: services)
    }

    private func handlePickedPDF(_ result: Result<URL, Error>) {
        guard let services, case .success(let url) = result else {
            ocrErrorText = LabHomeStrings.ocrFailed
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data),
              let firstPage = LabPDFRendering.pageImage(document: document, pageIndex: 0) else {
            ocrErrorText = LabHomeStrings.ocrFailed
            return
        }
        importAndScan(cgImages: [firstPage], image: nil, pdfData: data, services: services)
    }

    /// Runs the real on-device `LabDocumentOCR` pipeline (Vision framework, zero network calls),
    /// stashes the source bytes + candidate fields in `PendingScanStore`, and routes to
    /// `OCRReviewScreen` — the side-by-side correction UI (LAB-07) — rather than committing
    /// anything directly.
    ///
    /// Routes to `OCRReviewScreen` regardless of `extraction.status`, including `.failed`: LAB-06
    /// requires the scanned document to be stored and browsable even when nothing could be read
    /// off it (`LabDocumentOCR`'s own doc comment: "a .failed OCRExtraction is not an exception").
    /// A failed run always carries `fields == []` by construction, which lands cleanly on
    /// `OCRReviewScreen`'s existing empty-fields state ("enter by hand") — there is no separate
    /// failure UI to maintain.
    private func importAndScan(cgImages: [CGImage], image: UIImage?, pdfData: Data?, services: LabNotebookServices) {
        let documentId = ULID.newID()
        let extraction = services.ocr.run(sourceDocumentId: documentId, pages: cgImages)
        services.pendingScans.byDocumentId[documentId] = PendingScanStore.Pending(
            image: image, pdfData: pdfData, fields: extraction.fields)
        ocrErrorText = nil
        route = .ocrReview(documentId)
    }
}

// MARK: - Small shared subviews

private struct LabActionTile: View {
    let title: String
    let systemImage: String

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        }
    }
}

private struct LabReportRow: View {
    let report: LabReport
    let resultCount: Int
    let language: AppLanguage

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "testtube.2")
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(report.sourceLabName ?? Self.formatter.string(from: report.collectionAt))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(Self.formatter.string(from: report.collectionAt))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                Spacer(minLength: BadanSpace.space2)
                PillLabel("\(resultCount)", tint: BadanColor.textSecondary, filled: false)
                Image(systemName: "chevron.forward")
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
