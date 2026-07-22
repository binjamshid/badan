import SwiftUI

// MARK: - Comparator vocabulary shared by the quick/full entry forms

/// The real `LabComparator` (`Domain/Labs/LabModels.swift`) has no `.equal` case — `nil` already
/// means "exact value, no comparator printed". This is the small picker vocabulary over that same
/// optional, kept local to this file rather than a `CaseIterable` extension on the domain enum
/// (which would need to include `nil` as a pickable option, awkward for a `Picker` binding).
private enum ComparatorChoice: String, CaseIterable, Hashable {
    case exact = "=", lessThan = "<", lessThanOrEqual = "<=", greaterThan = ">", greaterThanOrEqual = ">=", approximately = "~"

    var labComparator: LabComparator? {
        switch self {
        case .exact: return nil
        case .lessThan: return .lessThan
        case .lessThanOrEqual: return .lessThanOrEqual
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqual: return .greaterThanOrEqual
        case .approximately: return .approximately
        }
    }

    init(_ comparator: LabComparator?) {
        switch comparator {
        case nil: self = .exact
        case .lessThan: self = .lessThan
        case .lessThanOrEqual: self = .lessThanOrEqual
        case .greaterThan: self = .greaterThan
        case .greaterThanOrEqual: self = .greaterThanOrEqual
        case .approximately: self = .approximately
        }
    }
}

/// Maps the OCR pipeline's own comparator vocabulary (`OCRComparator`, Unicode ≤/≥) onto the
/// domain's (`LabComparator`, ASCII `<=`/`>=`) — the two are independent enums for independent
/// reasons (documented on each type), so a prefill needs an explicit crosswalk rather than a shared
/// raw value.
private func labComparator(from ocr: OCRComparator?) -> LabComparator? {
    switch ocr {
    case nil: return nil
    case .lessThan: return .lessThan
    case .lessThanOrEqual: return .lessThanOrEqual
    case .greaterThan: return .greaterThan
    case .greaterThanOrEqual: return .greaterThanOrEqual
    }
}

// MARK: - Draft model (screen-local, never persisted until Save)

private struct DraftLabResult: Identifiable {
    var id = ULID.newID()
    var analyteId: String?
    var customLabel: String = ""
    var comparatorChoice: ComparatorChoice = .exact
    var valueText: String = ""
    var unit: String = ""
    var sourceIntervalLowText: String = ""
    var sourceIntervalHighText: String = ""
    var sourceIntervalFreeText: String = ""
    var sourceFlagText: String = ""
    /// Carried straight from `OCRFieldExtraction.reviewState` when prefilled from a scan
    /// (`.userEntered`/`.corrected` only — `OCRReviewGate` already required every field to leave
    /// `.needsReview` before reaching this screen); `.userEntered` for a hand-typed draft.
    var reviewState: LabReviewState = .userEntered
    var ingestionPath: IngestionPath = .manual

    /// Exactly one of `analyteId` (dictionary) / `customLabel` (free text) is meaningful — never
    /// blocked because a typed name isn't in `AnalyteCatalog` (a REJECTED ANTI-PATTERN per this
    /// slice's brief: an unrecognized marker is always a first-class entry).
    func displayName(language: AppLanguage) -> String {
        if let analyteId, let def = AnalyteCatalog.shared.definition(id: analyteId) { return def.displayName.resolved(language) }
        return customLabel
    }

    var isValid: Bool {
        let hasName = analyteId != nil || !customLabel.trimmingCharacters(in: .whitespaces).isEmpty
        return hasName && !valueText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {}

    /// Builds a draft from one confirmed OCR field — `OCRReviewScreen`'s own gate already required
    /// this field to have left `.needsReview` before the user could reach here.
    init(prefill field: OCRFieldExtraction) {
        switch field.analyteMatch {
        case .dictionary(let analyteId): self.analyteId = analyteId
        case .unrecognized: self.customLabel = field.analyteLabelRaw
        }
        comparatorChoice = ComparatorChoice(labComparator(from: field.comparator))
        valueText = field.valueText ?? ""
        unit = field.unitTextRaw ?? ""
        sourceFlagText = field.sourceFlagTextRaw ?? ""
        if let intervalText = field.sourceIntervalTextRaw {
            if let parsed = IntervalTextParsing.parse(intervalText) {
                sourceIntervalLowText = LabNumberFormat.string(parsed.low)
                sourceIntervalHighText = LabNumberFormat.string(parsed.high)
            } else {
                sourceIntervalFreeText = intervalText
            }
        }
        reviewState = field.reviewState == .corrected ? .corrected : .userEntered
        ingestionPath = .fileImport
    }

    /// Builds the real `LabResult` (+ full embedded `Provenance`, I1) and, when the user filled in
    /// any interval/flag field, the matching `ReferenceRange` (concepts 1+2 — never invented when
    /// left blank).
    func makeResultAndRange(reportId: String, sensitivityTier: LabSensitivityTier, collectedAt: Date, tzId: String,
                            writtenAt: Date, deviceId: String) -> (result: LabResult, range: ReferenceRange?)? {
        guard isValid else { return nil }
        let numericValue = DecimalParsing.parse(valueText)
        let resultType: LabResultType = numericValue != nil ? .numeric : .qualitative
        let provenance = Provenance(
            sourceId: deviceId, ingestionPath: ingestionPath, measuredAt: collectedAt, measuredTimezone: tzId,
            recordedAt: writtenAt, ingestedAt: writtenAt)
        let resultId = ULID.newID()
        var result = LabResult(
            id: resultId, reportId: reportId, analyteId: analyteId,
            customLabel: analyteId == nil ? customLabel : nil, rawValueText: valueText,
            comparator: comparatorChoice.labComparator, numericValue: numericValue,
            rawUnit: unit.isEmpty ? nil : unit, resultType: resultType, reviewState: reviewState,
            sensitivityTier: sensitivityTier, originalId: resultId, provenance: provenance,
            updatedAt: writtenAt, originDeviceId: deviceId)
        let analyte = analyteId.flatMap { AnalyteCatalog.shared.definition(id: $0) }
        result = UnitNormalization.applying(to: result, analyte: analyte)

        var range: ReferenceRange?
        let low = DecimalParsing.parse(sourceIntervalLowText)
        let high = DecimalParsing.parse(sourceIntervalHighText)
        let freeText = sourceIntervalFreeText.isEmpty ? nil : sourceIntervalFreeText
        let flag = sourceFlagText.isEmpty ? nil : sourceFlagText
        if low != nil || high != nil || freeText != nil || flag != nil {
            range = ReferenceRange(
                id: ULID.newID(), resultId: resultId, sourceIntervalLow: low, sourceIntervalHigh: high,
                sourceIntervalText: freeText, sourceIntervalUnit: (low != nil || high != nil) ? (unit.isEmpty ? nil : unit) : nil,
                sourceFlag: flag, updatedAt: writtenAt, originDeviceId: deviceId)
        }
        return (result, range)
    }
}

// MARK: - LAB-16 duplicate/conflict wiring (the resolver's own pure scoring is tested directly —
// see DuplicateConflictResolverTests; this is only the "which existing rows compete against this
// draft" + "what to do with each decision" glue that actually calls it from a save path).

enum LabDuplicateCheck {
    /// Scores `candidate` (not yet inserted) against every existing LIVE result sharing its
    /// `analyteKey`, keeping the highest-scoring non-`.distinct` match. `.merge` returns the
    /// existing row's id so the caller can `suppress` the new row right after inserting it (I2:
    /// always insert, never skip a write — suppression hides a row from live reads without
    /// deleting it). `.flag` returns `candidate` with `reviewState` raised to `.conflictFlagged`
    /// for explicit review (already rendered by `OCRFieldRow`'s pill). `.link`/`.distinct` (or no
    /// competing candidates at all) return `candidate` unchanged.
    static func apply(_ candidate: LabResult, against existingLive: [LabResult]) -> (result: LabResult, mergeWinnerId: String?) {
        var best: (evaluation: DuplicateConflictResolver.Evaluation, existing: LabResult)?
        for existing in existingLive where existing.analyteKey == candidate.analyteKey {
            let evaluation = DuplicateConflictResolver.evaluate(candidate, existing)
            guard evaluation.decision != .distinct else { continue }
            if best == nil || evaluation.score > best!.evaluation.score {
                best = (evaluation, existing)
            }
        }
        guard let best else { return (candidate, nil) }
        switch best.evaluation.decision {
        case .merge:
            return (candidate, best.existing.id)
        case .flag:
            var flagged = candidate
            flagged.reviewState = .conflictFlagged
            return (flagged, nil)
        case .link, .distinct:
            return (candidate, nil)
        }
    }
}

/// Parses a source-printed interval string ("3.5-5.5", "3.5 - 5.5") into low/high, or returns
/// `nil` when the text doesn't look like a numeric interval — callers fall back to storing it as
/// free-text `ReferenceRange.sourceIntervalText` rather than forcing a bad parse into numbers.
enum IntervalTextParsing {
    static func parse(_ text: String) -> (low: Double, high: Double)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let low = DecimalParsing.parse(parts[0]), let high = DecimalParsing.parse(parts[1]) else { return nil }
        return (low, high)
    }
}

// MARK: - Screen-local strings

private enum ManualEntryStrings {
    static let title = LocalizedString(en: "Add a result", ar: "إضافة نتيجة")
    static let modeQuick = LocalizedString(en: "Quick add", ar: "إضافة سريعة")
    static let modeFull = LocalizedString(en: "Full report", ar: "تقرير كامل")

    static let markerName = LocalizedString(en: "Marker", ar: "المؤشر")
    static let chooseMarker = LocalizedString(en: "Choose a marker", ar: "اختر مؤشراً")
    static let searchOrType = LocalizedString(en: "Search, or type your own", ar: "ابحث، أو اكتب اسمك الخاص")
    static let useCustom = LocalizedString(en: "Use \"{q}\" as your own marker", ar: "استخدام \"{q}\" كمؤشرك الخاص")

    static let value = LocalizedString(en: "Value", ar: "القيمة")
    static let unit = LocalizedString(en: "Unit", ar: "الوحدة")
    static let comparator = LocalizedString(en: "Comparator", ar: "المقارنة")
    static let date = LocalizedString(en: "Date", ar: "التاريخ")
    static let sourceIntervalSection = LocalizedString(
        en: "If the report printed a reference interval, enter it here (optional)",
        ar: "إذا طبع التقرير نطاقاً مرجعياً، أدخله هنا (اختياري)")
    static let low = LocalizedString(en: "Low", ar: "الأدنى")
    static let high = LocalizedString(en: "High", ar: "الأعلى")
    static let orFreeText = LocalizedString(en: "Or as printed (e.g. \"Negative\")", ar: "أو كما طُبع (مثلاً \"سلبي\")")
    static let sourceFlag = LocalizedString(en: "Flag printed by the lab (optional)", ar: "العلامة المطبوعة من المختبر (اختياري)")

    static let reportHeader = LocalizedString(en: "Report", ar: "التقرير")
    static let labName = LocalizedString(en: "Lab name (optional)", ar: "اسم المختبر (اختياري)")
    static let collectedDate = LocalizedString(en: "Collected on", ar: "تاريخ السحب")
    static let privacyLevel = LocalizedString(en: "Privacy level", ar: "مستوى الخصوصية")
    static let markersHeader = LocalizedString(en: "Markers", ar: "المؤشرات")
    static let addMarker = LocalizedString(en: "Add a marker", ar: "إضافة مؤشر")
    static let noMarkersYet = LocalizedString(en: "No markers added yet.", ar: "لا توجد مؤشرات مضافة بعد.")
    static let saveReport = LocalizedString(en: "Save report", ar: "حفظ التقرير")
    static let saveResult = LocalizedString(en: "Save result", ar: "حفظ النتيجة")
    static let editMarker = LocalizedString(en: "Edit marker", ar: "تعديل المؤشر")
    static let quickEntryLabel = LocalizedString(en: "Quick entry", ar: "إدخال سريع")
    static let saveFailed = LocalizedString(en: "Couldn't save. Try again.", ar: "تعذّر الحفظ. حاول مرة أخرى.")
}

// MARK: - Screen

/// LAB-03: both a quick single-marker entry (analyte picker, value, unit, comparator, date) and a
/// fuller multi-result report entry flow — chosen via the segmented control at the top. Prefilled
/// automatically from `OCRReviewScreen`'s confirmed fields when reached that way (always the
/// "Full report" mode in that case, since a scanned report is rarely a single marker).
struct ManualEntryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let services: LabNotebookServices
    let sourceDocumentId: String?

    private enum Mode: String, CaseIterable { case quick, full }

    @State private var mode: Mode
    @State private var labName: String = ""
    @State private var collectedDate: Date
    @State private var sensitivityTier: LabSensitivityTier = .standard
    @State private var drafts: [DraftLabResult]
    @State private var editingDraft: DraftLabResult?
    @State private var showAddMarker = false
    @State private var saveFailed = false

    init(services: LabNotebookServices, prefill: [OCRFieldExtraction] = [], sourceDocumentId: String? = nil) {
        self.services = services
        self.sourceDocumentId = sourceDocumentId
        _mode = State(initialValue: prefill.isEmpty ? .quick : .full)
        _collectedDate = State(initialValue: Date())
        _drafts = State(initialValue: prefill.isEmpty ? [DraftLabResult()] : prefill.map { DraftLabResult(prefill: $0) })
        // A scanned artifact's contents are more consistently identifying than a manually typed
        // quick entry (a full name/DOB/letterhead is usually visible on the page) — matches
        // `SourceDocument`'s own stricter default (`.high` vs `LabReport`'s `.standard`).
        _sensitivityTier = State(initialValue: sourceDocumentId != nil ? .high : .standard)
    }

    var body: some View {
        Form {
            if sourceDocumentId == nil {
                Section {
                    Picker("", selection: $mode) {
                        Text(env.s(ManualEntryStrings.modeQuick)).tag(Mode.quick)
                        Text(env.s(ManualEntryStrings.modeFull)).tag(Mode.full)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, BadanSpace.space2)
                }
            }

            switch mode {
            case .quick: quickForm
            case .full: fullForm
            }

            if saveFailed {
                Section {
                    Text(env.s(ManualEntryStrings.saveFailed)).font(BadanFont.caption).foregroundStyle(BadanColor.outOfBand)
                }
            }
        }
        .navigationTitle(env.s(ManualEntryStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(env.s(mode == .quick ? ManualEntryStrings.saveResult : ManualEntryStrings.saveReport)) { save() }
                    .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showAddMarker) {
            DraftMarkerEditor(draft: DraftLabResult()) { newDraft in drafts.append(newDraft) }
        }
        .sheet(item: $editingDraft) { draft in
            DraftMarkerEditor(draft: draft) { updated in
                if let index = drafts.firstIndex(where: { $0.id == updated.id }) { drafts[index] = updated }
            }
        }
    }

    private var canSave: Bool {
        switch mode {
        case .quick: return drafts.first?.isValid ?? false
        case .full: return !drafts.isEmpty && drafts.allSatisfy(\.isValid)
        }
    }

    // MARK: Quick add

    private var quickForm: some View {
        Group {
            Section {
                DraftMarkerFields(draft: Binding(get: { drafts.first ?? DraftLabResult() }, set: { drafts = [$0] }), env: env)
            }
            Section {
                DatePicker(env.s(ManualEntryStrings.date), selection: $collectedDate, displayedComponents: .date)
            }
        }
    }

    // MARK: Full report

    private var fullForm: some View {
        Group {
            Section(env.s(ManualEntryStrings.reportHeader)) {
                TextField(env.s(ManualEntryStrings.labName), text: $labName)
                DatePicker(env.s(ManualEntryStrings.collectedDate), selection: $collectedDate, displayedComponents: .date)
                Picker(env.s(ManualEntryStrings.privacyLevel), selection: $sensitivityTier) {
                    ForEach(LabSensitivityTier.allCases, id: \.self) { tier in
                        Text(env.s(tier.displayName)).tag(tier)
                    }
                }
            }
            Section(env.s(ManualEntryStrings.markersHeader)) {
                if drafts.isEmpty {
                    Text(env.s(ManualEntryStrings.noMarkersYet)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                } else {
                    ForEach(drafts) { draft in
                        Button { editingDraft = draft } label: {
                            DraftSummaryRow(draft: draft, language: env.language)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indices in drafts.remove(atOffsets: indices) }
                }
                Button(env.s(ManualEntryStrings.addMarker)) { showAddMarker = true }
            }
        }
    }

    private func save() {
        saveFailed = false
        let now = env.now()
        let tzId = TimeZone.current.identifier
        let reportId = ULID.newID()
        let report = LabReport(
            id: reportId, sourceLabName: labName.isEmpty ? nil : labName, collectionAt: collectedDate,
            reportedAt: nil, tzId: tzId, documentRef: sourceDocumentId,
            reviewState: sourceDocumentId != nil ? .needsReview : .userEntered,
            ingestionPath: sourceDocumentId != nil ? .fileImport : .manual, sensitivityTier: sensitivityTier,
            updatedAt: now, originDeviceId: services.deviceId)
        let existingLive = (try? services.results.allLiveResults()) ?? []
        do {
            try services.reports.transaction {
                try services.reports.insertReport(report)
                for draft in drafts {
                    guard let (rawResult, range) = draft.makeResultAndRange(
                        reportId: reportId, sensitivityTier: sensitivityTier, collectedAt: collectedDate, tzId: tzId,
                        writtenAt: now, deviceId: services.deviceId) else { continue }
                    let (result, mergeWinnerId) = LabDuplicateCheck.apply(rawResult, against: existingLive)
                    try services.results.insertResult(result)
                    if let range { try services.ranges.insertRange(range) }
                    if let mergeWinnerId {
                        try services.results.suppress(id: result.id, by: mergeWinnerId, at: now)
                    }
                }
            }
            Announce.status(env.s(Loc.done))
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

// MARK: - Shared marker field group (quick add's own fields, reused inside the add/edit sheet)

private struct DraftMarkerFields: View {
    @Binding var draft: DraftLabResult
    let env: AppEnvironment
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack {
                Text(env.s(ManualEntryStrings.markerName)).foregroundStyle(BadanColor.textPrimary)
                Spacer()
                Text(draft.displayName(language: env.language).isEmpty
                     ? env.s(ManualEntryStrings.chooseMarker)
                     : draft.displayName(language: env.language))
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
        .sheet(isPresented: $showPicker) {
            AnalytePickerSheet(language: env.language) { picked in
                switch picked {
                case .dictionary(let def):
                    draft.analyteId = def.id
                    draft.customLabel = ""
                    if draft.unit.isEmpty { draft.unit = def.canonicalUnit }
                case .custom(let name):
                    draft.analyteId = nil
                    draft.customLabel = name
                }
            }
        }
        HStack {
            Picker(env.s(ManualEntryStrings.comparator), selection: $draft.comparatorChoice) {
                ForEach(ComparatorChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            TextField(env.s(ManualEntryStrings.value), text: $draft.valueText)
            TextField(env.s(ManualEntryStrings.unit), text: $draft.unit).frame(width: 80)
        }
        // Deliberately NOT a nested `Section` (this view is already embedded inside one) — a
        // plain captioned group of fields.
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(env.s(ManualEntryStrings.sourceIntervalSection))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            HStack {
                TextField(env.s(ManualEntryStrings.low), text: $draft.sourceIntervalLowText).keyboardType(.decimalPad)
                TextField(env.s(ManualEntryStrings.high), text: $draft.sourceIntervalHighText).keyboardType(.decimalPad)
            }
            TextField(env.s(ManualEntryStrings.orFreeText), text: $draft.sourceIntervalFreeText)
            TextField(env.s(ManualEntryStrings.sourceFlag), text: $draft.sourceFlagText)
        }
    }
}

private struct DraftSummaryRow: View {
    let draft: DraftLabResult
    let language: AppLanguage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(draft.displayName(language: language).isEmpty ? "—" : draft.displayName(language: language))
                    .font(BadanFont.body).foregroundStyle(BadanColor.textPrimary)
                if !draft.valueText.isEmpty {
                    Text("\(draft.comparatorChoice == .exact ? "" : draft.comparatorChoice.rawValue)\(draft.valueText) \(draft.unit)")
                        .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                }
            }
            Spacer()
            if !draft.isValid {
                Image(systemName: "exclamationmark.circle").foregroundStyle(BadanColor.outOfBand).accessibilityHidden(true)
            }
        }
    }
}

private struct DraftMarkerEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State var draft: DraftLabResult
    let onSave: (DraftLabResult) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DraftMarkerFields(draft: $draft, env: env)
            }
            .navigationTitle(env.s(ManualEntryStrings.editMarker))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(env.s(Loc.cancel)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) { onSave(draft); dismiss() }.disabled(!draft.isValid)
                }
            }
        }
    }
}

// MARK: - Analyte picker (dictionary search + ALWAYS-available free text)

private enum AnalytePick {
    case dictionary(AnalyteDefinition)
    case custom(String)
}

private struct AnalytePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let language: AppLanguage
    let onPick: (AnalytePick) -> Void
    @State private var query = ""

    private var matches: [AnalyteDefinition] { AnalyteCatalog.shared.matching(query, language: language) }

    var body: some View {
        NavigationStack {
            List {
                // Unknown/unrecognized analyte name is ALWAYS enterable as free text — never
                // blocked because it isn't in the dictionary (REJECTED ANTI-PATTERN per this
                // slice's brief). Available whenever the search text is non-empty, even if it
                // ALSO matches curated entries below.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        onPick(.custom(query))
                        dismiss()
                    } label: {
                        Text(ManualEntryStrings.useCustom.filling(["q": query]).resolved(language))
                    }
                }
                ForEach(matches) { def in
                    Button {
                        onPick(.dictionary(def))
                        dismiss()
                    } label: {
                        Text(def.displayName.resolved(language)).foregroundStyle(BadanColor.textPrimary)
                    }
                }
            }
            .searchable(text: $query, prompt: ManualEntryStrings.searchOrType.resolved(language))
            .navigationTitle(ManualEntryStrings.chooseMarker.resolved(language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc.cancel.resolved(language)) { dismiss() } }
            }
        }
    }
}
