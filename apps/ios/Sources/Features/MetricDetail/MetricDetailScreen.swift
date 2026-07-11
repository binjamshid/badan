import SwiftUI

// MARK: - Localized strings local to this screen

/// Strings that only the metric-detail surface needs. Everything user-facing is bilingual;
/// shared vocabulary comes from `Loc`, these fill the gaps with real Arabic.
private enum MetricDetailStrings {
    static let trend = LocalizedString(en: "Trend", ar: "الاتجاه")
    static let period = LocalizedString(en: "Period", ar: "الفترة")
    static let recentValues = LocalizedString(en: "Recent values", ar: "القيم الأخيرة")
    static let method = LocalizedString(en: "Method & units", ar: "الطريقة والوحدات")
    static let unit = LocalizedString(en: "Unit", ar: "الوحدة")
    static let latestReading = LocalizedString(en: "Latest reading", ar: "أحدث قراءة")
    static let howWorkedOut = LocalizedString(en: "How this was worked out", ar: "كيف تم حساب هذا")
    static let straightFromRecords = LocalizedString(
        en: "This reads straight from your records — no extra calculation.",
        ar: "تُقرأ هذه القيمة مباشرة من سجلاتك — دون أي حساب إضافي.")
}

// MARK: - Loaded data

/// Everything the detail needs, gathered once so casual and power are two altitudes over the
/// same query result rather than two different loads.
struct MetricDetailData {
    var def: MetricDefinition
    var baseline: Baseline?
    var intervals: [IntervalRecord]           // ascending by start
    var derived: [DerivedValue]               // ascending by period
    var latestDerivedValue: DerivedValue?     // most recent, for the anatomy manifest
    var manifest: InputManifest?
    var sourceNames: [String: String]         // sourceId -> display name
    var recentDedup: [ReconciliationDecision] // populated only for sleep.time_asleep

    /// The chart reads derived values when there is no raw interval series (composites).
    var usesDerivedSeries: Bool { intervals.isEmpty && !derived.isEmpty }

    /// The full canonical series (ascending), tagged with the date it belongs to.
    func fullSeries(tz: String) -> [(date: Date, value: Double)] {
        if !intervals.isEmpty {
            return intervals.map { (date: $0.startAt, value: $0.value) }
        }
        return derived.map { (date: Self.periodDate($0.periodKey, tz: tz) ?? $0.computedAt, value: $0.value) }
    }

    /// Parse the date out of a `"day:YYYY-MM-DD"` period key; other shapes fall back to nil.
    static func periodDate(_ key: String, tz: String) -> Date? {
        guard let range = key.range(of: "day:") else { return nil }
        return DayAttribution.date(fromDayKey: String(key[range.upperBound...]), tz: tz)
    }
}

// MARK: - View model

@Observable
@MainActor
final class MetricDetailViewModel {
    var state: LoadState<MetricDetailData> = .loading

    /// Gather the metric's baseline, chart series, lineage and (for composites) its manifest.
    func load(_ env: AppEnvironment, metricId: String) {
        let tz = TimeZone.current.identifier
        do {
            let def = env.registry.definitionOrFallback(metricId)
            let from = env.now().addingTimeInterval(-90 * 86_400)

            let intervals = try env.measurements.intervalRecords(metricId: metricId, from: from, to: env.now())
            let derivedSeries = try env.derivation.latestDerivedSeries(metricId: metricId)
            let baseline = try env.derivation.latestBaseline(metricId: metricId)

            // The single most recent derived value drives the anatomy manifest.
            let latestDerived = derivedSeries.max { $0.computedAt < $1.computedAt }
            let manifest: InputManifest?
            if let manifestId = latestDerived?.inputManifestId {
                manifest = try env.derivation.manifest(id: manifestId)
            } else {
                manifest = nil
            }

            let sourceNames = Dictionary(
                try env.catalog.sources().map { ($0.id, $0.displayName) },
                uniquingKeysWith: { a, _ in a })

            // Only sleep time-asleep surfaces the dedup decision (one kept, one suppressed).
            let dedup = metricId == MetricID.timeAsleep ? (try env.reconciliation.recent(limit: 6)) : []

            let data = MetricDetailData(
                def: def, baseline: baseline, intervals: intervals, derived: derivedSeries,
                latestDerivedValue: latestDerived, manifest: manifest, sourceNames: sourceNames,
                recentDedup: dedup)

            if data.fullSeries(tz: tz).isEmpty {
                state = .empty(env.s(Loc.noDataMetric))
            } else {
                state = .loaded(data)
            }
        } catch {
            state = .error(String(describing: error))
        }
    }
}

// MARK: - Screen

/// The universal metric detail — one grammar for every metric. Casual shows a hero value, a
/// status word, a calm chart and a plain explainer; power adds a period selector, a values
/// table, provenance lineage, a method note and the "how this was worked out" anatomy sheet.
struct MetricDetailScreen: View {
    let metricId: String

    @Environment(AppEnvironment.self) private var env
    @State private var vm = MetricDetailViewModel()
    @State private var periodDays: Int = 30
    @State private var showAnatomy = false

    private static let periodOptions = [7, 30, 90]

    var body: some View {
        ScrollView {
            StatefulContainer(vm.state) { data in
                content(data)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(env.registry.definitionOrFallback(metricId).displayName))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAnatomy) {
            if case .loaded(let data) = vm.state {
                MetricAnatomySheet(data: data)
            }
        }
        .task { vm.load(env, metricId: metricId) }
    }

    // MARK: Body composition

    @ViewBuilder
    private func content(_ data: MetricDetailData) -> some View {
        let tz = TimeZone.current.identifier
        let fullSeries = data.fullSeries(tz: tz)
        let latest = fullSeries.last
        let power = env.depth.showsPowerDetail
        let chartDays = power ? periodDays : 30

        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            headerCard(data, latest: latest)

            chartCard(data, days: chartDays, tz: tz)

            if power {
                periodSelector
                valuesTableCard(series(within: chartDays, from: fullSeries), data: data)
                lineageCard(data)
                methodCard(data)
                anatomyButton
            } else {
                explainerCard(data)
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func headerCard(_ data: MetricDetailData, latest: (date: Date, value: Double)?) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                if let latest {
                    StatBox(
                        value: env.format.heroValue(metricId: data.def.metricId, canonicalValue: latest.value),
                        label: data.def.label(depth: env.depth, language: env.language),
                        unit: env.format.unitLabel(metricId: data.def.metricId),
                        chip: statusChip(value: latest.value, baseline: data.baseline))
                    Text(dateText(latest.date))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                } else {
                    Text(data.def.label(depth: env.depth, language: env.language))
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                }
            }
        }
    }

    // MARK: Chart

    @ViewBuilder
    private func chartCard(_ data: MetricDetailData, days: Int, tz: String) -> some View {
        let points = series(within: days, from: data.fullSeries(tz: tz))
        let provisional = data.baseline?.provisional ?? true
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(MetricDetailStrings.trend)) {
                    if provisional { ProvisionalBadge(language: env.language) }
                }
                MetricChart(
                    series: points,
                    style: data.def.chartHint == .bar ? .bar : .line,
                    band: data.baseline.map { (low: $0.bandLow, high: $0.bandHigh) })
                    .frame(height: 200)
            }
        }
    }

    // MARK: Casual explainer

    @ViewBuilder
    private func explainerCard(_ data: MetricDetailData) -> some View {
        if let explainer = data.def.explainerEn, !explainer.isEmpty {
            BadanCard {
                Text(LocalizedString(en: explainer, ar: data.def.nameAr), language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Power — period selector

    private var periodSelector: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(MetricDetailStrings.period))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Picker(env.s(MetricDetailStrings.period), selection: $periodDays) {
                ForEach(Self.periodOptions, id: \.self) { d in
                    Text(env.format.integer(d)).tag(d)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Power — values table

    @ViewBuilder
    private func valuesTableCard(_ points: [(date: Date, value: Double)], data: MetricDetailData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(MetricDetailStrings.recentValues))
                let rows = Array(points.reversed().prefix(14))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, point in
                    HStack(spacing: BadanSpace.space2) {
                        Text(dateText(point.date))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        Text(env.format.full(metricId: data.def.metricId, canonicalValue: point.value))
                            .font(BadanFont.bodyCompact.monospacedDigit())
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    Rectangle()
                        .fill(BadanColor.separator)
                        .frame(height: 1)
                }
            }
        }
    }

    // MARK: Power — provenance lineage

    @ViewBuilder
    private func lineageCard(_ data: MetricDetailData) -> some View {
        let entries = lineage(data)
        if !entries.isEmpty {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(Loc.provenance))
                    ForEach(entries) { entry in
                        ProvenanceRow(sourceName: entry.sourceName, ingestionPath: entry.ingestionPath,
                                      timestamp: entry.timestamp, language: env.language)
                    }
                }
            }
        }
    }

    // MARK: Power — method / unit note

    @ViewBuilder
    private func methodCard(_ data: MetricDetailData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(MetricDetailStrings.method))
                noteRow(label: env.s(MetricDetailStrings.unit),
                        value: env.format.unitLabel(metricId: data.def.metricId) ?? data.def.canonicalUnit)
                if let method = methodString(data) {
                    noteRow(label: env.s(Loc.algorithm), value: method)
                }
            }
        }
    }

    private func noteRow(label: String, value: String) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Text(label)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.bodyCompact.monospacedDigit())
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Power — anatomy button

    private var anatomyButton: some View {
        Button {
            showAnatomy = true
        } label: {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "function")
                    .accessibilityHidden(true)
                Text(env.s(MetricDetailStrings.howWorkedOut))
                    .font(BadanFont.body.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(BadanColor.primary)
            .frame(minHeight: BadanSpace.touchMin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BadanSpace.cardPadding)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                    .strokeBorder(BadanColor.separator, lineWidth: 1))
        }
    }

    // MARK: Helpers

    private func series(within days: Int, from full: [(date: Date, value: Double)]) -> [(date: Date, value: Double)] {
        let cutoff = env.now().addingTimeInterval(-Double(days) * 86_400)
        return full.filter { $0.date >= cutoff }
    }

    private func statusChip(value: Double, baseline: Baseline?) -> StatusChip {
        guard let baseline, !baseline.provisional else {
            return StatusChip(.info, label: env.s(Loc.stillLearning), language: env.language)
        }
        let position = baseline.position(of: value)
        let label: LocalizedString
        switch position {
        case .within: label = Loc.inYourRange
        case .above: label = Loc.aboveYourRange
        case .below: label = Loc.belowYourRange
        }
        return StatusChip(position: position, label: env.s(label), language: env.language)
    }

    private func methodString(_ data: MetricDetailData) -> String? {
        if let d = data.latestDerivedValue { return "\(d.algorithmId)@\(d.algorithmVersion)" }
        return data.baseline?.algorithmVersion
    }

    private func lineage(_ data: MetricDetailData) -> [LineageEntry] {
        if !data.intervals.isEmpty {
            return data.intervals.suffix(8).reversed().map { r in
                LineageEntry(id: r.id,
                             sourceName: data.sourceNames[r.provenance.sourceId] ?? r.provenance.sourceId,
                             ingestionPath: r.provenance.ingestionPath,
                             timestamp: r.provenance.measuredAt)
            }
        }
        return data.derived.suffix(8).reversed().map { d in
            LineageEntry(id: d.id,
                         sourceName: env.s(data.def.displayName),
                         ingestionPath: .derived,
                         timestamp: d.computedAt)
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// A uniform lineage row model so raw records and computed values render the same shape.
private struct LineageEntry: Identifiable {
    let id: String
    let sourceName: String
    let ingestionPath: IngestionPath
    let timestamp: Date
}
