import SwiftUI
import PDFKit

/// A thin `UIViewRepresentable` over `PDFView` so a vaulted PDF can be shown next to its structured
/// data ("a notebook, not a chart") — read-only, no editing/annotation surface.
struct PDFKitPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document { uiView.document = document }
    }
}

// MARK: - Shared formatting helpers (used across this feature folder)

enum SourceIntervalFormat {
    /// Renders concept #1 EXACTLY as the source stated it — a numeric interval, a qualitative
    /// text, or (if truly absent) an explicit "not printed" caption. Never derives a range from
    /// anything other than `range`'s own fields.
    static func text(_ range: ReferenceRange, language: AppLanguage) -> String? {
        if let text = range.sourceIntervalText, !text.isEmpty { return text }
        let unit = range.sourceIntervalUnit ?? ""
        switch (range.sourceIntervalLow, range.sourceIntervalHigh) {
        case (let low?, let high?): return "\(LabNumberFormat.string(low))–\(LabNumberFormat.string(high)) \(unit)"
        case (let low?, nil): return "≥ \(LabNumberFormat.string(low)) \(unit)"
        case (nil, let high?): return "≤ \(LabNumberFormat.string(high)) \(unit)"
        case (nil, nil): return nil
        }
    }
}

enum LabNumberFormat {
    static func string(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e12 { return String(Int64(value)) }
        var text = String(format: "%.4f", value)
        while text.contains(".") && text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Renders a result's own value exactly as printed/typed (`rawValueText`), with the comparator
/// prefixed only when it isn't already embedded in the raw text — never a re-derived number.
enum LabResultValueFormat {
    static func text(_ result: LabResult) -> String {
        guard let comparator = result.comparator else { return result.rawValueText }
        return result.rawValueText.hasPrefix(comparator.rawValue) ? result.rawValueText : "\(comparator.rawValue)\(result.rawValueText)"
    }
}

// MARK: - Screen-local strings

private enum ReportViewerStrings {
    static let originalDocument = LocalizedString(en: "Original document", ar: "المستند الأصلي")
    static let results = LocalizedString(en: "Results", ar: "النتائج")
    static let collectedOn = LocalizedString(en: "Collected", ar: "تاريخ السحب")
    static let reportedOn = LocalizedString(en: "Reported", ar: "تاريخ الإصدار")
    static let sensitivity = LocalizedString(en: "Privacy level", ar: "مستوى الخصوصية")
    static let noResults = LocalizedString(en: "No results recorded on this report.", ar: "لا توجد نتائج مسجّلة في هذا التقرير.")
    static let deleteReport = LocalizedString(en: "Delete report", ar: "حذف التقرير")
    static let deleteConfirmTitle = LocalizedString(en: "Delete this report?", ar: "حذف هذا التقرير؟")
    static let deleteConfirmMessage = LocalizedString(
        en: "This removes it and its results from your notebook. This can't be undone.",
        ar: "سيؤدي هذا إلى إزالته ونتائجه من دفترك. لا يمكن التراجع عن هذا.")
    static let notFound = LocalizedString(en: "This report is no longer here.", ar: "هذا التقرير لم يعد موجوداً.")
    static let loadFailed = LocalizedString(en: "Couldn't load this report right now.", ar: "تعذّر تحميل هذا التقرير الآن.")
}

private struct ReportViewerData {
    var report: LabReport
    var results: [LabResult]
    var sourceDocument: SourceDocument?
    var documentImage: UIImage?
    var documentPDF: PDFDocument?
}

// MARK: - Screen

/// A full report: its results and — when a `SourceDocument` exists — the original artifact
/// (PDFKit for a PDF, a plain image view for a photo) shown alongside the structured data, per
/// this slice's own "a notebook, not a chart" premise.
struct ReportViewerScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let services: LabNotebookServices
    let reportId: String

    @State private var state: LoadState<ReportViewerData> = .loading
    @State private var showDeleteConfirm = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        StatefulContainer(state, emptyIcon: "testtube.2") { data in
            content(data)
        }
        .background(BadanColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        do {
            guard let report = try services.reports.report(id: reportId), report.deletedAt == nil else {
                state = .empty(env.s(ReportViewerStrings.notFound))
                return
            }
            let results = try services.results.liveResults(reportId: reportId)
            var image: UIImage?
            var pdf: PDFDocument?
            var document: SourceDocument?
            if let ref = report.documentRef, let doc = services.document(id: ref) {
                document = doc
                if let bytes = services.documentBytes(vaultFileRef: doc.vaultFileRef) {
                    if doc.mimeType == "application/pdf" { pdf = PDFDocument(data: bytes) }
                    else { image = UIImage(data: bytes) }
                }
            }
            state = .loaded(ReportViewerData(report: report, results: results, sourceDocument: document,
                                             documentImage: image, documentPDF: pdf))
        } catch {
            state = .error(env.s(ReportViewerStrings.loadFailed))
        }
    }

    private func content(_ data: ReportViewerData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                header(data.report)

                if data.documentImage != nil || data.documentPDF != nil {
                    documentSection(data)
                }

                resultsSection(data)
            }
            .padding(BadanSpace.space4)
        }
        .navigationTitle(data.report.sourceLabName ?? Self.dateFormatter.string(from: data.report.collectionAt))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label(env.s(ReportViewerStrings.deleteReport), systemImage: "trash")
                }
            }
        }
        .confirmationDialog(env.s(ReportViewerStrings.deleteConfirmTitle), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(env.s(ReportViewerStrings.deleteReport), role: .destructive) { deleteReport(data) }
            Button(env.s(Loc.cancel), role: .cancel) {}
        } message: {
            Text(env.s(ReportViewerStrings.deleteConfirmMessage))
        }
    }

    private func deleteReport(_ data: ReportViewerData) {
        let now = env.now()
        try? services.reports.deleteReport(id: data.report.id, at: now)
        for originalId in Set(data.results.map(\.originalId)) {
            try? services.results.deleteChain(originalId: originalId, at: now)
        }
        dismiss()
    }

    private func header(_ report: LabReport) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                detailRow(ReportViewerStrings.collectedOn, Self.dateFormatter.string(from: report.collectionAt))
                if let reportedAt = report.reportedAt {
                    detailRow(ReportViewerStrings.reportedOn, Self.dateFormatter.string(from: reportedAt))
                }
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                    LText(ReportViewerStrings.sensitivity)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .frame(minWidth: 120, alignment: .leading)
                    Spacer(minLength: BadanSpace.space2)
                    PillLabel(env.s(report.sensitivityTier.displayName), tint: BadanColor.textSecondary, filled: false)
                }
            }
        }
    }

    private func detailRow(_ label: LocalizedString, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            LText(label).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary).frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: BadanSpace.space2)
            Text(value).font(BadanFont.caption).foregroundStyle(BadanColor.textPrimary).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func documentSection(_ data: ReportViewerData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ReportViewerStrings.originalDocument))
            if let image = data.documentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 340)
                    .background(BadanColor.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            } else if let pdf = data.documentPDF {
                PDFKitPreview(document: pdf)
                    .frame(height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            }
        }
    }

    private func resultsSection(_ data: ReportViewerData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ReportViewerStrings.results))
            if data.results.isEmpty {
                Text(env.s(ReportViewerStrings.noResults)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
            } else {
                ForEach(data.results) { result in
                    NavigationLink {
                        MarkerDetailScreen(services: services, analyteKey: result.analyteKey)
                    } label: {
                        LabResultRow(result: result, range: services.range(resultId: result.id), language: env.language)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - One result row (report-level list — the four concepts get their own full detail on MarkerDetailScreen)

private struct LabResultRow: View {
    let result: LabResult
    let range: ReferenceRange?
    let language: AppLanguage

    var body: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(result.customLabel ?? result.analyteId ?? result.analyteKey)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    if let range, let text = SourceIntervalFormat.text(range, language: language) {
                        Text(text).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                    }
                }
                Spacer(minLength: BadanSpace.space2)
                VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                    Text("\(LabResultValueFormat.text(result)) \(result.rawUnit ?? "")")
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                    // Concept #2, rendered verbatim, never re-interpreted into a verdict word.
                    if let flag = range?.sourceFlag, !flag.isEmpty {
                        PillLabel(flag, tint: BadanColor.outOfBand)
                    }
                }
                Image(systemName: "chevron.forward")
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
