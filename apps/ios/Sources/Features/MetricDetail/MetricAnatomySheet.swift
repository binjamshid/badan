import SwiftUI

/// Strings only the anatomy sheet needs — the calm, honest "why is it saying that" vocabulary.
private enum AnatomyStrings {
    static let baseline = LocalizedString(en: "Your baseline", ar: "خط الأساس")
    static let center = LocalizedString(en: "Center (median)", ar: "المركز (الوسيط)")
    // Named locally rather than reusing `Loc.personalRange` so the anatomy sheet can name the
    // method (median ± scaled deviation) without changing that string's wording anywhere else
    // it might ship in future.
    static let typicalRange = LocalizedString(en: "Typical range (median ± scaled deviation)",
                                               ar: "النطاق المعتاد (الوسيط ± انحراف مُعاير)")
    static let bandFormula = LocalizedString(en: "Center ± {k} × typical variation",
                                              ar: "المركز ± {k} × الانحراف المعتاد")
    static let daysUsed = LocalizedString(en: "Days used", ar: "الأيام المستخدمة")
    static let daysUsedOf = LocalizedString(en: "of", ar: "من")
    static let window = LocalizedString(en: "Window", ar: "النافذة الزمنية")
    static let computed = LocalizedString(en: "Last computed", ar: "آخر تحديث")
    static let confidence = LocalizedString(en: "Confidence", ar: "درجة الثقة")
    static let confidenceHigh = LocalizedString(en: "High", ar: "عالية")
    static let confidenceModerate = LocalizedString(en: "Moderate", ar: "متوسطة")
    static let confidenceLower = LocalizedString(en: "Lower", ar: "منخفضة")
    static let dedupHeading = LocalizedString(en: "Duplicate handling", ar: "معالجة التكرار")
    static let oneKept = LocalizedString(en: "One source kept, one suppressed.",
                                         ar: "مصدر واحد محتفظ به، وآخر مستبعد.")
    static let kept = LocalizedString(en: "Kept", ar: "المحتفظ به")
    // Repeats the same "nothing is deleted" reassurance `SourcesPriorityNote` gives on the
    // Sources screen, but placed directly next to the pill it actually explains here.
    static let reversibleNote = LocalizedString(en: "Nothing is deleted — this can be reversed.",
                                                 ar: "لا يُحذف شيء — يمكن التراجع عن هذا.")
    static let alreadyReversed = LocalizedString(en: "Already reversed", ar: "تمت الاستعادة بالفعل")
    static let overlapDetail = LocalizedString(en: "{pct}% overlap", ar: "تداخل بنسبة {pct}٪")
    static let learnDedup = LocalizedString(en: "Learn how duplicates are settled",
                                             ar: "تعرّف على كيفية تسوية التكرارات")
    static let straightFromRecords = LocalizedString(
        en: "This reads straight from your records — no extra calculation.",
        ar: "تُقرأ هذه القيمة مباشرة من سجلاتك — دون أي حساب إضافي.")
    // Distinct from `straightFromRecords`: a *derived* metric whose latest value simply isn't
    // linked to a manifest yet genuinely did involve a calculation, so it must not claim
    // otherwise (OPT-046).
    static let calculationUnavailable = LocalizedString(
        en: "This is a calculated value — the specific records behind this number aren't linked yet.",
        ar: "هذه قيمة محسوبة — السجلات المحددة التي تقف خلف هذا الرقم غير مرتبطة بعد.")
    static let noBaselineYet = LocalizedString(
        en: "Not enough history yet to draw a typical range.",
        ar: "لا يوجد سجل كافٍ بعد لرسم نطاق معتاد.")

    /// Plain-language description of each frozen algorithm id BaselineEngine actually emits
    /// (see `BaselineEngine.swift`), keyed by the id portion before "@version". Unknown ids
    /// simply show no extra line rather than a guess.
    static let algorithmGlossary: [String: LocalizedString] = [
        "baseline.rolling_median_mad": LocalizedString(
            en: "Uses your typical value and how much it usually varies, ignoring occasional outliers.",
            ar: "تستخدم قيمتك المعتادة ومقدار تغيّرها عادة، متجاهلةً القيم الشاذة العارضة."),
        "composite.sleep_efficiency": LocalizedString(
            en: "Time asleep divided by time in bed, as a percentage.",
            ar: "زمن النوم مقسوماً على زمن البقاء في الفراش، كنسبة مئوية."),
        "composite.readiness_score": LocalizedString(
            en: "Combines how your sleep and resting heart rate compare to your own baselines.",
            ar: "يجمع بين مقارنة نومك ومعدل نبضك أثناء الراحة بخط أساسك الشخصي."),
    ]

    /// Plain-language description of a reconciliation rule id, journaled verbatim on every
    /// dedup decision (`ReconciliationDecision.rule`). Only the one rule BADAN ships
    /// (`DedupLite.ruleId`) is listed; unknown ids simply show no extra line.
    static let ruleGlossary: [String: LocalizedString] = [
        "sleep.session_overlap.v1": LocalizedString(
            en: "Two sleep sessions overlapped heavily, so the higher-priority source's reading was kept.",
            ar: "تداخلت جلستا نوم بشكل كبير، فتم الاحتفاظ بقراءة المصدر الأعلى أولوية."),
    ]
}

/// Small in-place memoization so the sheet's formatted values (manifest rows, band text,
/// method string) are computed once per presentation instead of on every re-render — `data`
/// is immutable for the sheet's lifetime, so nothing cached here can go stale.
private final class AnatomyDisplayCache {
    var recordRows: [(label: String, value: String)]?
    var bandText: String?
    var methodStringComputed = false
    var methodString: String?
}

/// The "How this was worked out" sheet (VS-4). Presented modally in its own stack, it shows the
/// personal baseline (center, band, days used, provisional honesty), the records that fed the
/// latest computed value, the frozen algorithm version, and — for sleep time-asleep — the
/// reversible dedup decision that kept one source and suppressed a duplicate sibling.
struct MetricAnatomySheet: View {
    let data: MetricDetailData

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var cache = AnatomyDisplayCache()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    baselineCard
                    manifestOrFallbackCard
                    if let method = methodString {
                        methodCard(method)
                    }
                    if !data.recentDedup.isEmpty {
                        dedupCard
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.anatomyTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
        // Short-content metrics (e.g. a raw metric with just the baseline card) don't need a
        // full-height sheet; longer ones (manifest + dedup) can still expand to `.large`.
        .presentationDetents([.medium, .large])
    }

    // MARK: Baseline

    private var baselineCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.baseline)) {
                    if data.baseline?.provisional ?? true { ProvisionalBadge(language: env.language) }
                }
                if let b = data.baseline {
                    infoRow(label: env.s(AnatomyStrings.center),
                            value: env.format.full(metricId: data.def.metricId, canonicalValue: b.center))
                    infoRow(label: env.s(AnatomyStrings.typicalRange), value: bandText(b))
                    if let k = bandMultiplier(b) {
                        Text(env.s(AnatomyStrings.bandFormula.filling(["k": env.format.number(k, fraction: 2)])))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    infoRow(label: env.s(AnatomyStrings.daysUsed), value: daysUsedText(b))
                    infoRow(label: env.s(AnatomyStrings.window), value: windowRangeText(b), forceLTR: true)
                    infoRow(label: env.s(AnatomyStrings.computed), value: computedAtText(b.computedAt), forceLTR: true)
                } else {
                    Text(env.s(AnatomyStrings.noBaselineYet))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The multiplier the band was actually built with (`bandHigh = center + k × spread`),
    /// derived from the stored fields instead of duplicating BaselineEngine's own constant.
    private func bandMultiplier(_ b: Baseline) -> Double? {
        guard b.spread > 0 else { return nil }
        return (b.bandHigh - b.center) / b.spread
    }

    private func daysUsedText(_ b: Baseline) -> String {
        "\(env.format.integer(b.nPoints)) \(env.s(AnatomyStrings.daysUsedOf)) \(env.format.integer(b.windowDays))"
    }

    /// `Baseline` carries no timezone field of its own, so the window's day math needs a tz
    /// from elsewhere. The metric's own most-recent raw interval record is the closest honest
    /// source (its `tzId` is where this metric's data actually lives); a composite/derived-only
    /// metric has no raw interval to read at all, so this falls back to the device's current tz
    /// exactly like the rest of the app already does when no measurement tz is available
    /// (FIX-12).
    private var windowTz: String {
        data.intervals.last?.tzId ?? TimeZone.current.identifier
    }

    /// The window BaselineEngine queried for this baseline (`validFrom` minus `windowDays`).
    /// Not necessarily the exact span of contributing data points — a sparser baseline may
    /// only have data covering part of this window — but it's the honest bound the app can
    /// show today without a domain-model change to carry per-point dates. Uses `DayAttribution`
    /// day math in the measurement tz rather than `Calendar.current` (the device's current tz),
    /// so a baseline computed while the user was traveling doesn't shift its window boundary.
    private func windowRangeText(_ b: Baseline) -> String {
        let tz = windowTz
        let start = DayAttribution.addingDays(-b.windowDays, to: b.validFrom, tz: tz)
        return "\(dateOnlyText(start)) – \(dateOnlyText(b.validFrom))"
    }

    // MARK: Contributing records

    @ViewBuilder
    private var manifestOrFallbackCard: some View {
        if let manifest = data.manifest, !manifest.inputs.isEmpty {
            recordsCard(manifest)
        } else if data.def.kind == .derived {
            // A derived/composite metric with no manifest link is a data gap, not evidence
            // that "no calculation" happened — telling the user otherwise would be false.
            calculationUnavailableCard
        } else {
            straightFromRecordsCard
        }
    }

    private func recordsCard(_ manifest: InputManifest) -> some View {
        let rows = cachedRecordRows(manifest)
        return BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.contributingRecords))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    infoRow(label: row.label, value: row.value)
                }
            }
        }
    }

    private func cachedRecordRows(_ manifest: InputManifest) -> [(label: String, value: String)] {
        if let cached = cache.recordRows { return cached }
        let rows = manifest.inputs.map { input -> (label: String, value: String) in
            let inputDef = env.registry.definitionOrFallback(input.metricId)
            var value = env.format.full(metricId: input.metricId, canonicalValue: input.value)
            if let weight = input.weight {
                value += " (\(env.format.integer(Int((weight * 100).rounded())))%)"
            }
            return (label: inputDef.label(depth: env.depth, language: env.language), value: value)
        }
        cache.recordRows = rows
        return rows
    }

    private var straightFromRecordsCard: some View {
        BadanCard {
            Text(env.s(AnatomyStrings.straightFromRecords))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var calculationUnavailableCard: some View {
        BadanCard {
            Text(env.s(AnatomyStrings.calculationUnavailable))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Method

    private func methodCard(_ method: String) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(Loc.algorithm))
                Text(method)
                    .font(BadanFont.bodyCompact.monospacedDigit())
                    .foregroundStyle(BadanColor.textPrimary)
                    .textSelection(.enabled)
                if let explanation = algorithmExplanation(method) {
                    Text(env.s(explanation))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let confidence = data.latestDerivedValue?.confidence {
                    infoRow(label: env.s(AnatomyStrings.confidence), value: confidenceLabel(confidence))
                }
            }
        }
    }

    /// Looks up the plain-language explanation for an algorithm id, tolerating both the raw
    /// `algorithmId` and the composed `"algorithmId@semver"` form `methodString` can produce.
    private func algorithmExplanation(_ method: String) -> LocalizedString? {
        let id = method.split(separator: "@").first.map(String.init) ?? method
        return AnatomyStrings.algorithmGlossary[id]
    }

    /// A qualitative, wellness-safe reading of `DerivedValue.confidence` (0...1) — never a
    /// bare percentage framed as "accuracy", and never red/green.
    private func confidenceLabel(_ confidence: Double) -> String {
        let label: LocalizedString
        switch confidence {
        case ..<0.34: label = AnatomyStrings.confidenceLower
        case ..<0.67: label = AnatomyStrings.confidenceModerate
        default: label = AnatomyStrings.confidenceHigh
        }
        return env.s(label)
    }

    // MARK: Dedup (sleep time-asleep only)

    private var dedupCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.dedupHeading))
                Text(env.s(AnatomyStrings.oneKept))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(data.recentDedup.prefix(3)) { decision in
                    dedupRow(decision)
                }
                NavigationLink {
                    SourcesScreen()
                } label: {
                    HStack(spacing: BadanSpace.space1) {
                        Text(env.s(AnatomyStrings.learnDedup))
                            .font(BadanFont.link)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(BadanColor.primary)
                }
                .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
            }
        }
    }

    private func dedupRow(_ decision: ReconciliationDecision) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            // Stacked (not side-by-side) since each pill now names its source and can run long.
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                PillLabel(pillText(decision.detail["winner_source"], suffix: env.s(AnatomyStrings.kept)),
                          systemImage: "checkmark", tint: BadanColor.inBand)
                PillLabel(pillText(decision.detail["loser_source"], suffix: env.s(Loc.suppressedDuplicate)),
                          systemImage: "arrow.uturn.backward", tint: BadanColor.textSecondary)
            }
            if let explanation = AnatomyStrings.ruleGlossary[decision.rule] {
                Text(env.s(explanation))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(decisionDetailLine(decision))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            if decision.isReversed {
                PillLabel(env.s(AnatomyStrings.alreadyReversed), systemImage: "arrow.uturn.backward.circle",
                          tint: BadanColor.textSecondary, filled: false)
            } else if decision.reversible {
                Text(env.s(AnatomyStrings.reversibleNote))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Text("\(decision.rule) · \(decision.ruleVersion)")
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pillText(_ sourceId: String?, suffix: String) -> String {
        guard let sourceId, !sourceId.isEmpty else { return suffix }
        let name = data.sourceNames[sourceId] ?? sourceId
        return "\(name) — \(suffix)"
    }

    /// Overlap percentage and decision timestamp from `ReconciliationDecision.detail`/`decidedAt`
    /// — the fields the model carries specifically to explain a dedup decision, previously
    /// unread by this card.
    private func decisionDetailLine(_ decision: ReconciliationDecision) -> String {
        let when = decidedAtText(decision.decidedAt)
        guard let pctString = decision.detail["overlap_pct"], let pct = Double(pctString) else { return when }
        let pctText = env.s(AnatomyStrings.overlapDetail.filling(["pct": env.format.number(pct, fraction: 0)]))
        return "\(pctText) · \(when)"
    }

    // MARK: Helpers

    private func infoRow(label: String, value: String, forceLTR: Bool = false) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Text(label)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Group {
                if forceLTR {
                    // Dates/window bounds are technical, not prose — keep them left-to-right in
                    // both languages, matching `ProvenanceRow`'s timestamp treatment.
                    Text(value).environment(\.layoutDirection, .leftToRight)
                } else {
                    Text(value)
                }
            }
            .font(BadanFont.bodyCompact.monospacedDigit())
            .foregroundStyle(BadanColor.textPrimary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private func bandText(_ b: Baseline) -> String {
        if let cached = cache.bandText { return cached }
        let low = env.format.heroValue(metricId: data.def.metricId, canonicalValue: b.bandLow)
        let high = env.format.heroValue(metricId: data.def.metricId, canonicalValue: b.bandHigh)
        let text: String
        if let unit = env.format.unitLabel(metricId: data.def.metricId) {
            text = "\(low) – \(high) \(unit)"
        } else {
            text = "\(low) – \(high)"
        }
        cache.bandText = text
        return text
    }

    private var methodString: String? {
        if cache.methodStringComputed { return cache.methodString }
        let value: String?
        if let d = data.latestDerivedValue { value = "\(d.algorithmId)@\(d.algorithmVersion)" }
        else { value = data.baseline?.algorithmVersion }
        cache.methodString = value
        cache.methodStringComputed = true
        return value
    }

    // Cached once per type instead of allocating a fresh `DateFormatter` on every render,
    // matching the pattern already used by `ProvenanceRow`/`MetricDetailScreen`.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func decidedAtText(_ date: Date) -> String {
        Self.timestampFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.timestampFormatter.string(from: date)
    }

    private func computedAtText(_ date: Date) -> String {
        Self.timestampFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.timestampFormatter.string(from: date)
    }

    private func dateOnlyText(_ date: Date) -> String {
        Self.dateOnlyFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateOnlyFormatter.string(from: date)
    }
}
