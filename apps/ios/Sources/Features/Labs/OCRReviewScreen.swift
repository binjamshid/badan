import SwiftUI
import PhotosUI
import PDFKit

// ============================================================================
// MARK: - LAB-07: side-by-side OCR correction UI
// ============================================================================
//
// The real on-device OCR pipeline (`LabDocumentOCR`, `Ingest/OCR/LabDocumentOCR.swift`) already
// runs entirely through Apple's Vision framework with zero network calls — this file's job is only
// the REVIEW step: showing the source page next to each `OCRFieldExtraction` candidate, letting the
// user edit/confirm/skip each one, and never letting a field slip past `.needsReview` (its own
// default) without an explicit tap.

/// A minimal `PHPickerViewController` wrapper for "photo of a report". `PHPickerViewController`
/// (not `UIImagePickerController`) is used deliberately: it runs out-of-process and needs no photo-
/// library permission/usage-description entry at all, which matters for a picker whose whole
/// purpose is choosing a photo of sensitive lab data.
struct LabImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.onPick(object as? UIImage) }
            }
        }
    }
}

/// Renders one PDF page to a `CGImage` entirely on-device via PDFKit + `UIGraphicsImageRenderer` —
/// the rasterization step `LabDocumentOCR.run(sourceDocumentId:pages:)` deliberately leaves to its
/// caller (per that type's own doc).
enum LabPDFRendering {
    static func pageImage(document: PDFDocument, pageIndex: Int, scale: CGFloat = 2) -> CGImage? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.set()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        return image.cgImage
    }
}

// MARK: - Pure gate rule (tested directly — see LabNotebookUITests)

/// `.needsReview` is `OCRFieldExtraction`'s own default (`LabDocumentOCR` never produces anything
/// else) — this is the ONE place that decides whether a set of fields may proceed past this
/// screen. Every field must have left `.needsReview` via an explicit user action (`confirm`/`skip`
/// below), and a non-empty set is required so "review nothing" can't finalize an empty report.
enum OCRReviewGate {
    static func canFinalize(_ fields: [OCRFieldExtraction]) -> Bool {
        !fields.isEmpty && fields.allSatisfy { $0.reviewState != .needsReview }
    }
}

// MARK: - Screen-local strings

private enum OCRReviewStrings {
    static let title = LocalizedString(en: "Review scanned fields", ar: "مراجعة الحقول الممسوحة")
    static let subtitle = LocalizedString(
        en: "Check each field against the original before continuing. Nothing is saved until you confirm it.",
        ar: "تحقق من كل حقل مقابل الأصل قبل المتابعة. لا يُحفظ شيء حتى تؤكده.")
    static let confidence = LocalizedString(en: "Confidence", ar: "درجة الثقة")
    static let needsReview = LocalizedString(en: "Needs your review", ar: "يحتاج مراجعتك")
    static let confirmed = LocalizedString(en: "Confirmed as scanned", ar: "تم تأكيدها كما وَرَدت")
    static let corrected = LocalizedString(en: "Corrected by you", ar: "صححتَها بنفسك")
    static let confirm = LocalizedString(en: "Confirm", ar: "تأكيد")
    static let editAgain = LocalizedString(en: "Edit again", ar: "تعديل مجدداً")
    static let skip = LocalizedString(en: "Skip this line", ar: "تخطي هذا السطر")
    static let labelField = LocalizedString(en: "Marker name (as scanned)", ar: "اسم المؤشر (كما وَرَد)")
    static let valueField = LocalizedString(en: "Value", ar: "القيمة")
    static let unitField = LocalizedString(en: "Unit", ar: "الوحدة")
    static let intervalField = LocalizedString(en: "Interval printed by the lab (if any)", ar: "النطاق المطبوع من المختبر (إن وُجد)")
    static let flagField = LocalizedString(en: "Flag printed by the lab (if any)", ar: "العلامة المطبوعة من المختبر (إن وُجدت)")
    static let noFieldsFound = LocalizedString(
        en: "Nothing was recognized on this page. You can still enter the results by hand.",
        ar: "لم يتم التعرّف على شيء في هذه الصفحة. لا يزال بإمكانك إدخال النتائج يدوياً.")
    static let enterByHand = LocalizedString(en: "Enter by hand instead", ar: "إدخال يدوي بدلاً من ذلك")
    static let continueAction = LocalizedString(en: "Continue", ar: "متابعة")
    static let lowConfidence = LocalizedString(en: "Low confidence", ar: "ثقة منخفضة")
    static let notInDictionary = LocalizedString(en: "Not in the dictionary", ar: "غير موجود في القاموس")
    static let ambiguousDecimal = LocalizedString(en: "Decimal mark unclear", ar: "علامة عشرية غير واضحة")
}

// MARK: - Screen

/// LAB-07: side-by-side correction UI — the source page (image or PDF) above the extracted
/// candidate fields on narrow layouts (this app is iPhone-only), each field showing its confidence/
/// ambiguity flags and editable before the user explicitly confirms it. `review_required`
/// (`.needsReview`) stays the default for every field; nothing here lets a low-confidence field
/// slip through as confirmed without an explicit tap (`OCRReviewGate`).
struct OCRReviewScreen: View {
    @Environment(AppEnvironment.self) private var env
    let services: LabNotebookServices
    let documentId: String

    @State private var fields: [OCRFieldExtraction]
    @State private var originalSnapshots: [String: (label: String, value: String, unit: String)] = [:]
    @State private var editingId: String?
    @State private var route: LabRoute?

    init(services: LabNotebookServices, documentId: String) {
        self.services = services
        self.documentId = documentId
        _fields = State(initialValue: services.pendingScans.byDocumentId[documentId]?.fields ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                Text(env.s(OCRReviewStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                documentPreview

                if fields.isEmpty {
                    // Routes through `continueToEntry()` — NOT a bare `.manualEntry(sourceDocumentId:
                    // nil)` — so the scanned document still gets vaulted and stored (LAB-06: a scan
                    // that recognized nothing, or failed outright, is stored and browsable exactly
                    // like a successful one; only its extracted-fields list is empty).
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: env.s(OCRReviewStrings.noFieldsFound),
                        message: "",
                        actionTitle: env.s(OCRReviewStrings.enterByHand)
                    ) { continueToEntry() }
                } else {
                    ForEach(fields, id: \.id) { field in
                        OCRFieldRow(
                            field: field,
                            isEditing: editingId == field.id,
                            language: env.language,
                            onEdit: { editingId = field.id },
                            onChange: { updated in
                                if let index = fields.firstIndex(where: { $0.id == updated.id }) { fields[index] = updated }
                            },
                            onConfirm: { confirm(field.id) },
                            onSkip: { skip(field.id) }
                        )
                    }
                }
            }
            .padding(BadanSpace.space4)
            .padding(.bottom, BadanSpace.space8)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(OCRReviewStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { continueBar }
        .navigationDestination(item: $route) { $0.makeView(services: services) }
        .onAppear {
            for field in fields where originalSnapshots[field.id] == nil {
                originalSnapshots[field.id] = (field.analyteLabelRaw, field.valueText ?? "", field.unitTextRaw ?? "")
            }
        }
    }

    @ViewBuilder
    private var documentPreview: some View {
        let pending = services.pendingScans.byDocumentId[documentId]
        if let image = pending?.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .frame(maxWidth: .infinity)
                .background(BadanColor.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        } else if let data = pending?.pdfData, let document = PDFDocument(data: data) {
            PDFKitPreview(document: document)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        }
    }

    private var continueBar: some View {
        Button {
            continueToEntry()
        } label: {
            Text(env.s(OCRReviewStrings.continueAction))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.onPrimary)
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                .background(canFinalize ? BadanColor.primary : BadanColor.separator,
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .disabled(!canFinalize)
        .padding(BadanSpace.space4)
        .background(.ultraThinMaterial)
    }

    private var canFinalize: Bool { OCRReviewGate.canFinalize(fields) }

    private func confirm(_ id: String) {
        guard let index = fields.firstIndex(where: { $0.id == id }) else { return }
        let field = fields[index]
        let original = originalSnapshots[id]
        let wasEdited = original.map {
            $0.label != field.analyteLabelRaw || $0.value != (field.valueText ?? "") || $0.unit != (field.unitTextRaw ?? "")
        } ?? true
        fields[index].reviewState = wasEdited ? .corrected : .userEntered
        if editingId == id { editingId = nil }
    }

    private func skip(_ id: String) {
        fields.removeAll { $0.id == id }
        services.pendingScans.byDocumentId[documentId]?.fields = fields
        if editingId == id { editingId = nil }
    }

    /// Best-effort vault the source bytes (see this feature's top-of-file note on the
    /// `source_documents`-table gap — a failure here degrades to "no linked document", never a
    /// blocked save) before handing the CONFIRMED fields to `ManualEntryScreen` for commit.
    private func continueToEntry() {
        var sourceDocumentId: String?
        if let pending = services.pendingScans.byDocumentId[documentId], let vault = services.vault {
            let bytes = pending.image?.jpegData(compressionQuality: 0.9) ?? pending.pdfData
            if let bytes {
                do {
                    let vaulted = try vault.store(bytes)
                    let now = env.now()
                    let doc = SourceDocument(
                        id: ULID.newID(), sha256: vaulted.sha256,
                        mimeType: pending.pdfData != nil ? "application/pdf" : "image/jpeg",
                        pageCount: 1, ocrStatus: .completed, vaultFileRef: vaulted.vaultFileRef,
                        importedAt: now, updatedAt: now, originDeviceId: services.deviceId)
                    try services.documents.insert(doc)
                    sourceDocumentId = doc.id
                } catch {
                    sourceDocumentId = nil
                }
            }
        }
        route = .manualEntry(prefill: fields, sourceDocumentId: sourceDocumentId)
    }
}

// MARK: - One field row

private struct OCRFieldRow: View {
    @Environment(AppEnvironment.self) private var env
    let field: OCRFieldExtraction
    let isEditing: Bool
    let language: AppLanguage
    let onEdit: () -> Void
    let onChange: (OCRFieldExtraction) -> Void
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack {
                    statePill
                    Spacer(minLength: BadanSpace.space2)
                    if let confidence = field.analyteConfidence ?? field.valueConfidence {
                        PillLabel(
                            "\(env.s(OCRReviewStrings.confidence)) \(Int(confidence * 100))%",
                            tint: BadanColor.textSecondary, filled: false)
                    }
                }

                if !field.ambiguityFlags.isEmpty {
                    ambiguityRow
                }

                if field.reviewState == .needsReview || isEditing {
                    editableFields
                } else {
                    readOnlySummary
                }

                HStack(spacing: BadanSpace.space3) {
                    if field.reviewState == .needsReview || isEditing {
                        Button(env.s(OCRReviewStrings.confirm), action: onConfirm)
                            .font(BadanFont.link)
                            .foregroundStyle(BadanColor.primary)
                    } else {
                        Button(env.s(OCRReviewStrings.editAgain), action: onEdit)
                            .font(BadanFont.link)
                            .foregroundStyle(BadanColor.primary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Button(role: .destructive, action: onSkip) {
                        Text(env.s(OCRReviewStrings.skip)).font(BadanFont.link)
                    }
                }
            }
        }
    }

    private var statePill: some View {
        switch field.reviewState {
        case .needsReview:
            return PillLabel(env.s(OCRReviewStrings.needsReview), systemImage: "exclamationmark.circle", tint: BadanColor.outOfBand)
        case .userEntered:
            return PillLabel(env.s(OCRReviewStrings.confirmed), systemImage: "checkmark.circle", tint: BadanColor.inBand)
        case .corrected:
            return PillLabel(env.s(OCRReviewStrings.corrected), systemImage: "pencil.circle", tint: BadanColor.info)
        case .conflictFlagged:
            return PillLabel(env.s(OCRReviewStrings.needsReview), systemImage: "exclamationmark.circle", tint: BadanColor.outOfBand)
        }
    }

    private var ambiguityRow: some View {
        HStack(spacing: BadanSpace.space2) {
            ForEach(field.ambiguityFlags, id: \.self) { flag in
                PillLabel(ambiguityLabel(flag), systemImage: "questionmark.circle", tint: BadanColor.outOfBand, filled: false)
            }
        }
    }

    private func ambiguityLabel(_ flag: OCRAmbiguityFlag) -> String {
        switch flag {
        case .lowConfidenceRecognition: return env.s(OCRReviewStrings.lowConfidence)
        case .lowConfidenceAnalyteMatch, .noAnalyteDictionaryAvailable: return env.s(OCRReviewStrings.notInDictionary)
        case .localeAmbiguousDecimal: return env.s(OCRReviewStrings.ambiguousDecimal)
        }
    }

    private var readOnlySummary: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(field.analyteLabelRaw).font(BadanFont.body.weight(.medium)).foregroundStyle(BadanColor.textPrimary)
            Text("\(field.comparator?.rawValue ?? "")\(field.valueText ?? "") \(field.unitTextRaw ?? "")")
                .font(BadanFont.bodyCompact).foregroundStyle(BadanColor.textSecondary)
        }
    }

    private var editableFields: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            labeledField(OCRReviewStrings.labelField, text: field.analyteLabelRaw) { onChange(withLabel($0)) }
            HStack(spacing: BadanSpace.space2) {
                labeledField(OCRReviewStrings.valueField, text: field.valueText ?? "") { onChange(withValue($0)) }
                labeledField(OCRReviewStrings.unitField, text: field.unitTextRaw ?? "") { onChange(withUnit($0)) }
            }
            labeledField(OCRReviewStrings.intervalField, text: field.sourceIntervalTextRaw ?? "") { onChange(withInterval($0)) }
            labeledField(OCRReviewStrings.flagField, text: field.sourceFlagTextRaw ?? "") { onChange(withFlag($0)) }
        }
    }

    private func labeledField(_ title: LocalizedString, text: String, onEdit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(env.s(title)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
            TextField("", text: Binding(get: { text }, set: onEdit))
                .font(BadanFont.body)
                .padding(BadanSpace.space2)
                .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
    }

    private func withLabel(_ value: String) -> OCRFieldExtraction { var c = field; c.analyteLabelRaw = value; return c }
    private func withValue(_ value: String) -> OCRFieldExtraction { var c = field; c.valueText = value; return c }
    private func withUnit(_ value: String) -> OCRFieldExtraction { var c = field; c.unitTextRaw = value.isEmpty ? nil : value; return c }
    private func withInterval(_ value: String) -> OCRFieldExtraction { var c = field; c.sourceIntervalTextRaw = value.isEmpty ? nil : value; return c }
    private func withFlag(_ value: String) -> OCRFieldExtraction { var c = field; c.sourceFlagTextRaw = value.isEmpty ? nil : value; return c }
}
