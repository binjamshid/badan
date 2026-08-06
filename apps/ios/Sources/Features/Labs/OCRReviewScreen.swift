import SwiftUI
import PhotosUI
import PDFKit
import VisionKit

// ============================================================================
// MARK: - LAB-07: side-by-side OCR correction UI
// ============================================================================
//
// The real on-device OCR pipeline (`LabDocumentOCR`, `Ingest/OCR/LabDocumentOCR.swift`) already
// runs entirely through Apple's Vision framework with zero network calls — this file's job is only
// the REVIEW step: showing the source page next to each `OCRFieldExtraction` candidate, letting the
// user edit/confirm/skip each one, and never letting a field slip past `.needsReview` (its own
// default) without an explicit tap.

/// A minimal `PHPickerViewController` wrapper for "photos of a report". `PHPickerViewController`
/// (not `UIImagePickerController`) is used deliberately: it runs out-of-process and needs no photo-
/// library permission/usage-description entry at all, which matters for a picker whose whole
/// purpose is choosing a photo of sensitive lab data.
///
/// Multi-select, because a lab report is routinely more than one page and the previous
/// single-image limit quietly made page 2 onwards un-importable — the user's only recourse was to
/// import the same report several times as several "reports". `selectionLimit = 0` is PhotosUI's
/// spelling of "no limit"; `LabScanLimits.maxPages` is what actually bounds the work.
struct LabImagePicker: UIViewControllerRepresentable {
    let onPick: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([UIImage]) -> Void
        init(onPick: @escaping ([UIImage]) -> Void) { self.onPick = onPick }

        /// Reports and returns; the caller lowers the sheet binding. This used to dismiss itself
        /// while leaving `photoImporter` true, so the picker opened exactly once per visit to the
        /// notebook and silently did nothing on the second tap — see `LabDocumentScanner`'s note.
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let providers = results.map(\.itemProvider)
            guard !providers.isEmpty else {
                onPick([])
                return
            }
            // Loaded into a fixed-size slot array rather than appended, because the providers
            // finish in whatever order they finish and page order is the whole point: pages 1-2-3
            // arriving as 2-3-1 would file a report whose lines read out of sequence.
            var slots = [UIImage?](repeating: nil, count: providers.count)
            let group = DispatchGroup()
            let lock = NSLock()
            for (index, provider) in providers.enumerated() {
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        lock.lock(); slots[index] = image; lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { self.onPick(slots.compactMap { $0 }) }
        }
    }
}

/// The document camera, as a SwiftUI view. `VNDocumentCameraViewController` rather than a bare
/// `UIImagePickerController` camera: it does the edge detection, perspective correction and
/// multi-page capture that make a phone photo of a printed page legible to `VNRecognizeTextRequest`
/// at all, and all of it happens on device inside Apple's own controller.
///
/// Cancelling and failing are the same outcome here — an empty array — because neither produced
/// pages, and the caller's honest message for "nothing to read" covers both. A failure is not
/// reported as an error the user must dismiss when the user may simply have backed out.
struct LabDocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    /// **Dismissal is SwiftUI's, not this controller's.** Every callback below reports its pages and
    /// nothing else; the caller lowers the `fullScreenCover` binding, which is what actually takes
    /// the scanner off screen. Calling `controller.dismiss` here as well would dismiss the cover out
    /// from under SwiftUI's own state — two owners of one presentation, which desyncs on the second
    /// use rather than the first and is exactly the bug the photo picker used to have.
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onFinish([])
        }
    }
}

/// Bakes a `UIImage`'s EXIF orientation into its pixels.
///
/// **Why this is not optional.** A `UIImage` carries its rotation as metadata: `size` is the
/// ORIENTED size, while `cgImage` is the raw sensor bitmap, still sideways. Both consumers of a
/// picked page read `cgImage` directly — `LabDocumentOCR` hands it to Vision, and the vault's PDF
/// composition draws it into a box measured from `size` — so a photo carrying any orientation but
/// `.up` reaches Vision rotated 90° (text recognition on a sideways page finds close to nothing)
/// and reaches the PDF stretched into a box of the wrong aspect. Library photos of a printed report
/// carry orientation routinely; this is the ordinary case, not the exotic one.
///
/// Returns `self` untouched when there is nothing to bake, so an already-upright image — every
/// `VNDocumentCameraScan` page, and most PDF rasterizations — costs nothing.
extension UIImage {
    func uprightedForRecognition() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// How much of a document one scan will read.
///
/// A bound is necessary — every page is a full `VNRecognizeTextRequest` at `.accurate`, and a
/// 200-page PDF would sit there for minutes holding rasterized pages in memory. 25 is chosen to sit
/// well above any real lab report (the longest ones in testing were 8 pages) while keeping the
/// worst case bounded. What matters more than the number: when a document is longer, the extra
/// pages are reported to the user (`OCRReviewStrings.pagesReadOfTotal`), never silently dropped.
enum LabScanLimits {
    static let maxPages = 25
}

/// Renders one PDF page to a `CGImage` entirely on-device via PDFKit + `UIGraphicsImageRenderer` —
/// the rasterization step `LabDocumentOCR.run(sourceDocumentId:pages:)` deliberately leaves to its
/// caller (per that type's own doc).
enum LabPDFRendering {
    /// **Rotation is honoured, and it did not used to be.** `bounds(for:)` reports the page box
    /// BEFORE its `/Rotate`, so a page rotated a quarter turn — routine in anything produced by a
    /// sheet-fed scanner or a phone-scanned upload — was rendered into a canvas of the wrong aspect
    /// and reached Vision sideways. Recognition on a sideways page returns nothing at all, which
    /// the app could only report as "no results found on this report" for a file that opens
    /// perfectly straight in Preview. Proven by `testARotatedPDFPageRasterizesUpright`, which fails
    /// against the previous implementation.
    ///
    /// `page.draw(with:to:)` applies the rotation itself, so the fix is the CANVAS, not the drawing:
    /// a quarter-turned page is rendered at its displayed aspect. Drawing is deliberately still done
    /// through `UIGraphicsImageRenderer` at `scale` rather than `thumbnail(of:for:)` — the thumbnail
    /// path was tried and measurably degrades recognition (a header that read "Report page 1 of 3"
    /// through this renderer came back as "eport page 1 ot 3" through the thumbnail), and OCR
    /// quality is the whole point of this function.
    static func pageImage(document: PDFDocument, pageIndex: Int, scale: CGFloat = 2) -> CGImage? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }

        let quarterTurn = abs(page.rotation % 180) == 90
        let size = CGSize(width: (quarterTurn ? pageRect.height : pageRect.width) * scale,
                          height: (quarterTurn ? pageRect.width : pageRect.height) * scale)
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

    /// Every page of `document`, rasterized in order, up to `limit`.
    ///
    /// A page that fails to render is SKIPPED, not fatal: one malformed page in a twelve-page
    /// report must not cost the user the other eleven, and `LabDocumentOCR` already treats a
    /// missing page the same way it treats a page it could not read.
    ///
    /// Returns the true page count alongside the images so the caller can tell the user when a
    /// document was longer than `limit` — the count is the document's, not the array's.
    static func pageImages(document: PDFDocument, limit: Int = LabScanLimits.maxPages,
                           scale: CGFloat = 2) -> (images: [CGImage], totalPages: Int) {
        let total = document.pageCount
        let images = (0..<min(total, limit)).compactMap { pageImage(document: document, pageIndex: $0, scale: scale) }
        return (images, total)
    }

    /// Wraps captured/picked page images into a single PDF for the document vault.
    ///
    /// The vault stores one blob per source document, and a camera scan or a multi-photo pick is
    /// genuinely one document with several pages. Composing them into a PDF keeps that true —
    /// the alternative, storing only the first image, would show page 1 next to results read off
    /// page 4 and quietly misrepresent what the user is checking against. Each page is drawn at
    /// its own pixel size, so nothing is rescaled or cropped on the way in.
    static func pdfData(from images: [UIImage]) -> Data? {
        guard !images.isEmpty else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: images[0].size)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            var box = CGRect(origin: .zero, size: image.size)
            context.beginPage(mediaBox: &box)
            context.draw(cgImage, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
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
    static let pagesReadOfTotal = LocalizedString(
        en: "Only the first {read} of {total} pages were read. Anything on the later pages isn't here — you can add it by hand.",
        ar: "قُرئت أول {read} صفحات فقط من أصل {total}. ما ورد في الصفحات التالية غير موجود هنا — يمكنك إضافته يدوياً.")
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
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            if let images = pending?.images, !images.isEmpty {
                // Swipeable rather than first-page-only: the fields below can come from any page,
                // and "check each field against the original" is not something the user can do if
                // the original they are shown is page 1 of 6.
                TabView {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(.bottom, BadanSpace.space5)
                    }
                }
                .tabViewStyle(.page)
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .background(BadanColor.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            } else if let data = pending?.pdfData, let document = PDFDocument(data: data) {
                PDFKitPreview(document: document)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            }

            // Said out loud, never inferred from a short field list: a reader who does not know
            // that pages 26+ went unread would take the absence of their markers as the lab not
            // having reported them.
            if let pending, pending.pagesRead < pending.pageCount {
                Text(env.s(OCRReviewStrings.pagesReadOfTotal.filling([
                    "read": env.format.integer(pending.pagesRead),
                    "total": env.format.integer(pending.pageCount)])))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.outOfBand)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            // One document in, one blob out. A single photo stays a JPEG (nothing is gained by
            // wrapping it); several pages become one PDF so the vaulted artifact has the same page
            // count as the thing the user actually scanned. A PDF source is stored byte-for-byte —
            // re-encoding the user's own file would break "the original is always preserved".
            let isPDF = pending.pdfData != nil || pending.images.count > 1
            let bytes: Data?
            if let pdfData = pending.pdfData {
                bytes = pdfData
            } else if pending.images.count > 1 {
                bytes = LabPDFRendering.pdfData(from: pending.images)
            } else {
                bytes = pending.images.first?.jpegData(compressionQuality: 0.9)
            }
            if let bytes {
                do {
                    let vaulted = try vault.store(bytes)
                    let now = env.now()
                    let doc = SourceDocument(
                        id: ULID.newID(), sha256: vaulted.sha256,
                        mimeType: isPDF ? "application/pdf" : "image/jpeg",
                        pageCount: pending.pageCount, ocrStatus: .completed,
                        vaultFileRef: vaulted.vaultFileRef,
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
