import SwiftUI

// ============================================================================
// MARK: - The four-concept reference-range law, on screen
// ============================================================================
//
// `Domain/Labs/ReferenceRangeEngine.swift` already states and enforces the law at the domain
// layer: `ReferenceRangeEngine.render(range:baseline:threshold:)` returns a `RenderableRange` whose
// four slots (`sourceInterval`/`sourceFlag`/`personalBaseline`/`userThreshold`) are independently
// optional, with NO fifth field a caller could read as "the" normal range. This screen's whole job
// is to relabel those four slots as four separate cards — it never combines them, and the engine's
// own type makes combining them a compile-time non-option rather than a discipline to remember.
//
// Concept #1 uses `ReferenceRangeEngine.sourceIntervalCaption` (the engine's own pinned wording,
// "Outside this laboratory's stated reference interval") for the outside case — never a re-derived
// phrase, and never "abnormal"/"unhealthy". Concept #3 legitimately reuses this codebase's existing
// `Loc.personalRange`/`Loc.stillLearning`/`Loc.inYourRange`/`Loc.aboveYourRange`/`Loc.belowYourRange`
// vocabulary — that IS what concept #3 is (BADAN's own computed personal pattern) — but that
// vocabulary is never borrowed for concept #1, which is a different fact entirely.

private enum MarkerDetailStrings {
    static let sourceIntervalTitle = LocalizedString(en: "The lab's own reference interval", ar: "النطاق المرجعي الذي حدده المختبر")
    static let sourceIntervalAbsent = LocalizedString(en: "Not printed on this report", ar: "غير مطبوع في هذا التقرير")
    static let insideInterval = LocalizedString(
        en: "Inside this laboratory's stated reference interval",
        ar: "ضمن النطاق المرجعي الذي ذكره هذا المختبر")

    static let sourceFlagTitle = LocalizedString(en: "The flag the lab printed", ar: "العلامة التي طبعها المختبر")
    static let sourceFlagAbsent = LocalizedString(en: "Not printed on this report", ar: "غير مطبوعة في هذا التقرير")

    static let userThresholdTitle = LocalizedString(en: "The threshold you set", ar: "الحد الذي حدّدته بنفسك")
    static let userThresholdAbsent = LocalizedString(en: "Not set", ar: "غير محدد")
    static let pastThreshold = LocalizedString(en: "Past the threshold you set", ar: "تجاوز الحد الذي حدّدته")
    static let withinThreshold = LocalizedString(en: "Within the threshold you set", ar: "ضمن الحد الذي حدّدته")
    static let setThreshold = LocalizedString(en: "Set a threshold", ar: "تحديد حد")

    static let conceptsHeader = LocalizedString(en: "Is this in range? Four separate answers", ar: "هل هذا ضمن النطاق؟ أربع إجابات منفصلة")
    static let history = LocalizedString(en: "History", ar: "السجل")
    static let noHistory = LocalizedString(en: "No results yet for this marker.", ar: "لا توجد نتائج بعد لهذا المؤشر.")
    static let correctResult = LocalizedString(en: "Correct this value", ar: "تصحيح هذه القيمة")
    static let save = LocalizedString(en: "Save correction", ar: "حفظ التصحيح")
    static let setThresholdTitle = LocalizedString(en: "Set your own threshold", ar: "تحديد حدّك الخاص")
    static let thresholdHint = LocalizedString(
        en: "This is your own alert level — separate from anything the lab printed.",
        ar: "هذا مستوى تنبيه خاص بك — منفصل تماماً عن أي شيء طبعه المختبر.")
    static let value = LocalizedString(en: "Value", ar: "القيمة")
    static let unit = LocalizedString(en: "Unit", ar: "الوحدة")
    static let loadFailed = LocalizedString(en: "Couldn't load this marker right now.", ar: "تعذّر تحميل هذا المؤشر الآن.")

    static let summaryPlain = LocalizedString(en: "Your latest {name} was {value}.", ar: "كانت آخر قيمة لـ{name} لديك {value}.")
    static let summaryInside = LocalizedString(
        en: "Your latest {name} was {value} — inside this laboratory's stated reference interval.",
        ar: "كانت آخر قيمة لـ{name} لديك {value} — ضمن النطاق المرجعي الذي ذكره هذا المختبر.")
}

// MARK: - Concept rows (pure relabeling of ReferenceRangeEngine.RenderableRange — tested directly)

enum LabConcept: String, CaseIterable, Hashable, Sendable {
    case sourceInterval, sourceFlag, personalBaseline, userThreshold
}

struct MarkerConceptRow: Identifiable, Hashable {
    var concept: LabConcept
    var title: LocalizedString
    var valueText: String
    var captionText: String?
    var icon: String
    var id: String { concept.rawValue }
}

enum MarkerDetailConceptRows {
    /// Builds exactly one row per concept, ALWAYS four rows, straight off `RenderableRange`'s own
    /// four independently-optional slots — never derives a fifth "verdict" and never lets one
    /// concept's numbers leak into another's row.
    static func rows(renderable: ReferenceRangeEngine.RenderableRange, latestValue: (value: Double, unit: String)?,
                     language: AppLanguage) -> [MarkerConceptRow] {
        [
            sourceIntervalRow(renderable.sourceInterval, latestValue: latestValue, language: language),
            sourceFlagRow(renderable.sourceFlag, language: language),
            personalBaselineRow(renderable.personalBaseline, latestValue: latestValue, language: language),
            userThresholdRow(renderable.userThreshold, latestValue: latestValue, language: language),
        ]
    }

    private static func sourceIntervalRow(
        _ interval: ReferenceRangeEngine.RenderableRange.SourceInterval?, latestValue: (value: Double, unit: String)?,
        language: AppLanguage
    ) -> MarkerConceptRow {
        guard let interval else {
            return MarkerConceptRow(concept: .sourceInterval, title: MarkerDetailStrings.sourceIntervalTitle,
                                    valueText: MarkerDetailStrings.sourceIntervalAbsent.resolved(language),
                                    captionText: nil, icon: "doc.text")
        }
        let text = intervalText(interval)
        var caption: String?
        if let latestValue, interval.unit == nil || interval.unit == latestValue.unit {
            let outside = (interval.low.map { latestValue.value < $0 } ?? false) || (interval.high.map { latestValue.value > $0 } ?? false)
            caption = outside
                ? ReferenceRangeEngine.sourceIntervalCaption.resolved(language)
                : MarkerDetailStrings.insideInterval.resolved(language)
        }
        return MarkerConceptRow(concept: .sourceInterval, title: MarkerDetailStrings.sourceIntervalTitle,
                                valueText: text, captionText: caption, icon: "doc.text")
    }

    private static func intervalText(_ interval: ReferenceRangeEngine.RenderableRange.SourceInterval) -> String {
        if let text = interval.text, !text.isEmpty { return text }
        let unit = interval.unit ?? ""
        switch (interval.low, interval.high) {
        case (let low?, let high?): return "\(LabNumberFormat.string(low))–\(LabNumberFormat.string(high)) \(unit)"
        case (let low?, nil): return "≥ \(LabNumberFormat.string(low)) \(unit)"
        case (nil, let high?): return "≤ \(LabNumberFormat.string(high)) \(unit)"
        case (nil, nil): return ""
        }
    }

    private static func sourceFlagRow(_ flag: String?, language: AppLanguage) -> MarkerConceptRow {
        let value = (flag?.isEmpty == false) ? flag! : MarkerDetailStrings.sourceFlagAbsent.resolved(language)
        return MarkerConceptRow(concept: .sourceFlag, title: MarkerDetailStrings.sourceFlagTitle,
                                valueText: value, captionText: nil, icon: "flag")
    }

    private static func personalBaselineRow(
        _ baseline: ReferenceRangeEngine.PersonalBaselineView?, latestValue: (value: Double, unit: String)?,
        language: AppLanguage
    ) -> MarkerConceptRow {
        guard let baseline else {
            return MarkerConceptRow(concept: .personalBaseline, title: Loc.personalRange,
                                    valueText: Loc.stillLearning.resolved(language), captionText: nil, icon: "chart.xyaxis.line")
        }
        let text = "\(LabNumberFormat.string(baseline.bandLow))–\(LabNumberFormat.string(baseline.bandHigh)) \(baseline.unit)"
        var caption: String?
        if let latestValue, latestValue.unit == baseline.unit {
            if latestValue.value < baseline.bandLow { caption = Loc.belowYourRange.resolved(language) }
            else if latestValue.value > baseline.bandHigh { caption = Loc.aboveYourRange.resolved(language) }
            else { caption = Loc.inYourRange.resolved(language) }
        }
        if baseline.provisional {
            caption = [caption, Loc.stillLearning.resolved(language)].compactMap { $0 }.joined(separator: " · ")
        }
        return MarkerConceptRow(concept: .personalBaseline, title: Loc.personalRange, valueText: text, captionText: caption,
                                icon: "chart.xyaxis.line")
    }

    private static func userThresholdRow(
        _ threshold: ReferenceRangeEngine.UserLabThreshold?, latestValue: (value: Double, unit: String)?, language: AppLanguage
    ) -> MarkerConceptRow {
        guard let threshold else {
            return MarkerConceptRow(concept: .userThreshold, title: MarkerDetailStrings.userThresholdTitle,
                                    valueText: MarkerDetailStrings.userThresholdAbsent.resolved(language),
                                    captionText: nil, icon: "bell")
        }
        let symbol = threshold.direction == .above ? ">" : "<"
        let text = "\(symbol) \(LabNumberFormat.string(threshold.value)) \(threshold.unit)"
        var caption: String?
        if let latestValue, latestValue.unit == threshold.unit {
            let triggered = threshold.direction == .above ? latestValue.value > threshold.value : latestValue.value < threshold.value
            caption = (triggered ? MarkerDetailStrings.pastThreshold : MarkerDetailStrings.withinThreshold).resolved(language)
        }
        return MarkerConceptRow(concept: .userThreshold, title: MarkerDetailStrings.userThresholdTitle,
                                valueText: text, captionText: caption, icon: "bell")
    }
}

// MARK: - "One sentence" summary (pure, tested)

enum MarkerSummarySentence {
    static func text(latest: LabResult, displayName: String, renderable: ReferenceRangeEngine.RenderableRange,
                     language: AppLanguage) -> String {
        let valueText = "\(LabResultValueFormat.text(latest)) \(latest.rawUnit ?? "")".trimmingCharacters(in: .whitespaces)
        let values = ["name": displayName, "value": valueText]
        guard let interval = renderable.sourceInterval, let resolved = LabValueResolution.resolved(latest),
              interval.unit == nil || interval.unit == resolved.unit else {
            return MarkerDetailStrings.summaryPlain.filling(values).resolved(language)
        }
        let outside = (interval.low.map { resolved.value < $0 } ?? false) || (interval.high.map { resolved.value > $0 } ?? false)
        if outside {
            return "\(MarkerDetailStrings.summaryPlain.filling(values).resolved(language)) \(ReferenceRangeEngine.sourceIntervalCaption.resolved(language))."
        }
        return MarkerDetailStrings.summaryInside.filling(values).resolved(language)
    }
}

// MARK: - Loaded data

private struct MarkerDetailData {
    var latest: LabResult
    var history: [LabResult]
    var renderable: ReferenceRangeEngine.RenderableRange
    var points: [(date: Date, value: Double)]
}

// MARK: - Screen

/// One analyte's page: "one sentence -> chart -> details" — a single calm summary sentence, a
/// trend chart over the user's own historical results, then a detail list showing EVERY one of
/// the four reference-range concepts separately and clearly labeled.
struct MarkerDetailScreen: View {
    @Environment(AppEnvironment.self) private var env
    let services: LabNotebookServices
    let analyteKey: String

    @State private var state: LoadState<MarkerDetailData> = .loading
    @State private var correctingResult: LabResult?
    @State private var showThresholdEditor = false

    private var displayName: String {
        if case .loaded(let data) = state {
            if let custom = data.latest.customLabel { return custom }
            if let id = data.latest.analyteId, let def = AnalyteCatalog.shared.definition(id: id) { return def.displayName.resolved(env.language) }
        }
        return analyteKey
    }

    var body: some View {
        ScrollView {
            StatefulContainer(state, emptyIcon: "chart.xyaxis.line") { data in
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    Text(MarkerSummarySentence.text(latest: data.latest, displayName: displayName, renderable: data.renderable,
                                                    language: env.language))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if data.points.count >= 2 {
                        MetricChart(series: data.points, style: .line,
                                   band: data.renderable.personalBaseline.map { ($0.bandLow, $0.bandHigh) },
                                   unit: LabValueResolution.resolved(data.latest)?.unit,
                                   language: env.language, arabicDigits: env.profile.arabicDigits)
                            .frame(height: 200)
                    }

                    conceptDetailsSection(data)
                    historySection(data)
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(item: $correctingResult) { result in
            LabResultCorrectionSheet(services: services, result: result, onSaved: { load() })
        }
        .sheet(isPresented: $showThresholdEditor) {
            if case .loaded(let data) = state {
                LabThresholdEditorSheet(services: services, analyteKey: analyteKey,
                                        defaultUnit: LabValueResolution.resolved(data.latest)?.unit ?? data.latest.rawUnit ?? "",
                                        onSaved: { load() })
            }
        }
    }

    private func load() {
        do {
            let history = try services.results.allLiveResults().filter { $0.analyteKey == analyteKey }
                .sorted { $0.provenance.measuredAt < $1.provenance.measuredAt }
            guard let latest = history.last else {
                state = .empty(env.s(MarkerDetailStrings.noHistory))
                return
            }
            let range = services.range(resultId: latest.id)
            let existingTrend = try services.trends.latestTrend(analyteId: analyteKey)
            var trend = existingTrend
            // Append-only (I2): recompute on every view, but only WRITE a fresh row when it
            // actually differs from the latest stored one — otherwise every glance at this marker
            // would grow `derived_trends` with an identical repeat, which is exactly the kind of
            // "meaningless append" I2 doesn't intend (mirrors `BaselineEngine.recompute`'s own
            // skip-if-unchanged guard).
            if let unit = LabValueResolution.resolved(latest)?.unit {
                let now = env.now()
                if let fresh = ReferenceRangeEngine.makeTrend(id: ULID.newID(), analyteKey: analyteKey, history: history,
                                                              unit: unit, validFrom: now, computedAt: now, updatedAt: now,
                                                              originDeviceId: services.deviceId) {
                    let changed = existingTrend.map { !Self.trendsApproximatelyEqual($0, fresh) } ?? true
                    if changed {
                        try? services.trends.appendTrend(fresh)
                        trend = fresh
                    }
                }
            }
            let threshold = services.thresholds.threshold(for: analyteKey)
            let renderable = ReferenceRangeEngine.render(range: range, baseline: trend, threshold: threshold)
            let points = history.compactMap { result -> (date: Date, value: Double)? in
                guard let resolved = LabValueResolution.resolved(result) else { return nil }
                return (result.provenance.measuredAt, resolved.value)
            }
            state = .loaded(MarkerDetailData(latest: latest, history: history, renderable: renderable, points: points))
        } catch {
            state = .error(env.s(MarkerDetailStrings.loadFailed))
        }
    }

    private static func trendsApproximatelyEqual(_ a: DerivedTrend, _ b: DerivedTrend) -> Bool {
        a.nPoints == b.nPoints && a.unit == b.unit
            && abs(a.center - b.center) < 1e-6 && abs(a.bandLow - b.bandLow) < 1e-6 && abs(a.bandHigh - b.bandHigh) < 1e-6
    }

    private func conceptDetailsSection(_ data: MarkerDetailData) -> some View {
        let latestValue = LabValueResolution.resolved(data.latest)
        return VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(MarkerDetailStrings.conceptsHeader, language: env.language)
            ForEach(MarkerDetailConceptRows.rows(renderable: data.renderable, latestValue: latestValue, language: env.language)) { row in
                MarkerConceptCard(row: row) {
                    if row.concept == .userThreshold { showThresholdEditor = true }
                }
            }
        }
    }

    private func historySection(_ data: MarkerDetailData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(MarkerDetailStrings.history, language: env.language)
            ForEach(data.history.reversed()) { result in
                Button { correctingResult = result } label: {
                    MarkerHistoryRow(result: result, language: env.language)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Concept card

private struct MarkerConceptCard: View {
    @Environment(AppEnvironment.self) private var env
    let row: MarkerConceptRow
    var onTapSetThreshold: (() -> Void)?

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: row.icon).imageScale(.small).foregroundStyle(BadanColor.textSecondary).accessibilityHidden(true)
                    Text(env.s(row.title)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                }
                Text(row.valueText).font(BadanFont.body.weight(.semibold)).foregroundStyle(BadanColor.textPrimary)
                if let caption = row.captionText, !caption.isEmpty {
                    Text(caption).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                }
                if row.concept == .userThreshold, let onTapSetThreshold {
                    Button(env.s(MarkerDetailStrings.setThreshold), action: onTapSetThreshold)
                        .font(BadanFont.link)
                        .foregroundStyle(BadanColor.primary)
                }
            }
        }
    }
}

// MARK: - History row

private struct MarkerHistoryRow: View {
    let result: LabResult
    let language: AppLanguage

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Text(Self.formatter.string(from: result.provenance.measuredAt))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .frame(minWidth: 96, alignment: .leading)
            Text("\(LabResultValueFormat.text(result)) \(result.rawUnit ?? "")")
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            if result.isRevised {
                PillLabel(LocalizedString(en: "Corrected", ar: "مُصحَّحة").resolved(language), tint: BadanColor.info, filled: false)
            }
        }
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
    }
}

// MARK: - Correction sheet (append-first — never mutates the row it corrects; DuplicateConflictResolver.makeAmendment)

private struct LabResultCorrectionSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let services: LabNotebookServices
    let result: LabResult
    let onSaved: () -> Void

    @State private var valueText: String
    @State private var unitText: String

    init(services: LabNotebookServices, result: LabResult, onSaved: @escaping () -> Void) {
        self.services = services
        self.result = result
        self.onSaved = onSaved
        _valueText = State(initialValue: result.rawValueText)
        _unitText = State(initialValue: result.rawUnit ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(env.s(MarkerDetailStrings.value), text: $valueText)
                    TextField(env.s(MarkerDetailStrings.unit), text: $unitText)
                }
            }
            .navigationTitle(env.s(MarkerDetailStrings.correctResult))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(env.s(Loc.cancel)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(MarkerDetailStrings.save)) { save() }
                        .disabled(valueText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let now = env.now()
        let numeric = DecimalParsing.parse(valueText)
        let analyte = result.analyteId.flatMap { AnalyteCatalog.shared.definition(id: $0) }
        var amended = DuplicateConflictResolver.makeAmendment(
            of: result, id: ULID.newID(), rawValueText: valueText, numericValue: numeric,
            rawUnit: unitText.isEmpty ? nil : unitText, canonicalValue: nil, canonicalUnit: nil,
            provenance: result.provenance, updatedAt: now, originDeviceId: env.deviceId)
        amended = UnitNormalization.applying(to: amended, analyte: analyte)
        try? services.results.insertResult(amended)
        dismiss()
        onSaved()
    }
}

// MARK: - Threshold editor sheet (Concept #4 — entirely separate from the lab's own interval)

private struct LabThresholdEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let services: LabNotebookServices
    let analyteKey: String
    let defaultUnit: String
    let onSaved: () -> Void

    @State private var direction: ReferenceRangeEngine.UserLabThreshold.Direction = .above
    @State private var valueText: String = ""
    @State private var unitText: String

    init(services: LabNotebookServices, analyteKey: String, defaultUnit: String, onSaved: @escaping () -> Void) {
        self.services = services
        self.analyteKey = analyteKey
        self.defaultUnit = defaultUnit
        self.onSaved = onSaved
        _unitText = State(initialValue: defaultUnit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(env.s(MarkerDetailStrings.thresholdHint))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                Section {
                    Picker("", selection: $direction) {
                        Text(">").tag(ReferenceRangeEngine.UserLabThreshold.Direction.above)
                        Text("<").tag(ReferenceRangeEngine.UserLabThreshold.Direction.below)
                    }
                    .pickerStyle(.segmented)
                    TextField(env.s(MarkerDetailStrings.value), text: $valueText).keyboardType(.decimalPad)
                    TextField(env.s(MarkerDetailStrings.unit), text: $unitText)
                }
            }
            .navigationTitle(env.s(MarkerDetailStrings.setThresholdTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(env.s(Loc.cancel)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) {
                        guard let value = DecimalParsing.parse(valueText) else { return }
                        let threshold = ReferenceRangeEngine.UserLabThreshold(
                            analyteKey: analyteKey, direction: direction, value: value,
                            unit: unitText.isEmpty ? defaultUnit : unitText)
                        services.thresholds.set(threshold)
                        dismiss()
                        onSaved()
                    }
                    .disabled(DecimalParsing.parse(valueText) == nil)
                }
            }
        }
    }
}
