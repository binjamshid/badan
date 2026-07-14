import SwiftUI
import UIKit

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
    /// Fallback for metrics missing `explainerEn` so casual users never see a silent gap
    /// (EASE-159).
    static let genericExplainer = LocalizedString(
        en: "A measurement from your connected sources over time.",
        ar: "قياس من مصادرك المتصلة عبر الزمن.")
    /// Casual's chart window has no period selector to state it, so it's spelled out (EASE-164).
    static let last30Days = LocalizedString(en: "Last 30 days", ar: "آخر 30 يومًا")
    static let showMore = LocalizedString(en: "Show more", ar: "عرض المزيد")
    /// Distinguishes a computed/composite line from a directly-measured one (UIUX-042).
    static let computedFromData = LocalizedString(en: "Computed from your data", ar: "محسوبة من بياناتك")
    /// Names the shaded band so it isn't left unexplained on the chart itself (UIUX-043).
    static let usualRangeLegend = LocalizedString(en: "Shaded area: your usual range", ar: "المنطقة المظللة: نطاقك المعتاد")
    static let asOf = LocalizedString(en: "As of", ar: "اعتبارًا من")
    static let computedForDate = LocalizedString(en: "Computed for", ar: "محسوبة لـ")
    static let moreInFamily = LocalizedString(en: "More in this family", ar: "المزيد في هذه الفئة")
    static let shareMetric = LocalizedString(en: "Share this metric", ar: "مشاركة هذا المقياس")
    /// Deviation-from-center caption at power depth (EASE-157).
    static let vsYourMedian = LocalizedString(en: "vs your median", ar: "مقارنة بمتوسطك")
    /// Single-letter day-count suffix for the period picker segments (UIUX-035).
    static let daySuffix = LocalizedString(en: "d", ar: "ي")
    /// Casual's quiet route into the same anatomy sheet power opens via `howWorkedOut` above
    /// (UX-02) — phrased as an inviting question rather than power's declarative label, since
    /// casual has never been shown this exists at all before now.
    static let howIsThisWorkedOutCasual = LocalizedString(en: "How is this worked out?", ar: "كيف يتم حساب هذا؟")

    /// Plain-language gloss for each algorithm id, shown alongside (not instead of) the raw
    /// `algorithmId@version` token so power users get comprehension, not just a traceable
    /// code (EASE-155/EASE-251).
    static let algorithmGloss: [String: LocalizedString] = [
        "baseline.rolling_median_mad": LocalizedString(
            en: "Rolling median of your last 14 days",
            ar: "الوسيط المتحرك لآخر 14 يومًا"),
        "composite.sleep_efficiency": LocalizedString(
            en: "Time asleep divided by time in bed",
            ar: "وقت النوم مقسومًا على الوقت في الفراش"),
        "composite.readiness_score": LocalizedString(
            en: "Combines sleep and resting heart rate against your usual range",
            ar: "يجمع بين النوم ومعدل ضربات القلب أثناء الراحة مقارنة بنطاقك المعتاد"),
    ]
}

/// Period options shared between the power-mode picker and the ViewModel's fetch window, so
/// the two can't silently drift apart (OPT-033).
private let metricDetailPeriodOptions = [7, 30, 90]
private let metricDetailMaxPeriodDays = metricDetailPeriodOptions.max() ?? 90

/// The period-memory read side (STUB-06a), factored out to a pure static function so it's
/// directly testable without standing up the view: `sessionPreferences.lastMetricPeriodDays`
/// was already modeled on `CustomizationProfile` but nothing ever read or wrote it, so the
/// period picker silently reset to 30 on every push instead of remembering the metric's last
/// viewed window.
enum SessionPeriodMemory {
    static let defaultPeriodDays = 30

    static func rememberedPeriod(for metricId: String, in map: [String: Int]) -> Int {
        map[metricId] ?? defaultPeriodDays
    }
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
    /// The full canonical series (ascending), tagged with the date it belongs to — computed
    /// once at load time rather than re-derived on every render (PERF-036/037/042).
    var fullSeries: [(date: Date, value: Double)]

    /// The chart reads derived values when there is no raw interval series (composites).
    var usesDerivedSeries: Bool { intervals.isEmpty && !derived.isEmpty }

    /// Parse the date out of a `"day:YYYY-MM-DD"` period key; other shapes fall back to nil.
    static func periodDate(_ key: String, tz: String) -> Date? {
        guard let range = key.range(of: "day:") else { return nil }
        return DayAttribution.date(fromDayKey: String(key[range.upperBound...]), tz: tz)
    }
}

// MARK: - View model

/// Everything `MetricDetailViewModel.fetch` needs to run off the main actor (PERF-01) — the
/// thread-safe repository references plus value-type snapshots of the profile/metric bits the
/// query logic reads.
struct MetricDetailFetchInputs {
    var registry: MetricRegistry
    var measurements: MeasurementRepository
    var derivation: DerivationRepository
    var catalog: CatalogRepository
    var reconciliation: ReconciliationRepository
    var depth: DepthPolicy
    var now: Date
    var metricId: String
}

@Observable
@MainActor
final class MetricDetailViewModel {
    var state: LoadState<MetricDetailData> = .loading

    /// Gather the metric's baseline, chart series, lineage and (for composites) its manifest —
    /// on a detached task so the most data-dense screen in the app never blocks the main thread
    /// (PERF-01). A cancelled load (e.g. navigating to a different metric before this one
    /// finished) never clobbers state.
    func load(_ env: AppEnvironment, metricId: String) async {
        let inputs = MetricDetailFetchInputs(
            registry: env.registry, measurements: env.measurements, derivation: env.derivation,
            catalog: env.catalog, reconciliation: env.reconciliation, depth: env.depth,
            now: env.now(), metricId: metricId)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let data):
            if data.fullSeries.isEmpty {
                state = .empty(env.s(Loc.noDataMetric))
            } else {
                state = .loaded(data)
            }
        case .failure(let error):
            // The raw error goes to the debug log, not the UI (BUG-14) — users see one calm,
            // bilingual "couldn't load" message with a retry action instead of a Swift error
            // description as the screen's title.
            LoadErrorLog.log(error, screen: "MetricDetail")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Fetch core (nonisolated — runs on a detached task)

    nonisolated static func fetch(_ inputs: MetricDetailFetchInputs) -> Result<MetricDetailData, Error> {
        let tz = TimeZone.current.identifier
        do {
            let def = inputs.registry.definitionOrFallback(inputs.metricId)
            // Casual mode never shows more than a fixed 30-day window, so only power mode
            // needs to fetch the full period-selector range up front (PERF-038).
            let fetchDays = inputs.depth.showsPowerDetail ? metricDetailMaxPeriodDays : 30
            // A tolerant rolling lookback window (fetch "the last N*24h", not "the last N
            // calendar days") — intentionally not `DayAttribution` day math (DATA-11-UI): this
            // is just a query-side overfetch bound feeding the period selector below, which
            // itself re-filters by the same rolling-window rule in `series(within:from:)`.
            let from = inputs.now.addingTimeInterval(-Double(fetchDays) * 86_400)

            let intervals = try inputs.measurements.intervalRecords(metricId: inputs.metricId, from: from, to: inputs.now)
            let derivedSeries = try inputs.derivation.latestDerivedSeries(metricId: inputs.metricId)
            let baseline = try inputs.derivation.latestBaseline(metricId: inputs.metricId)

            // The single most recent derived value drives the anatomy manifest.
            let latestDerived = derivedSeries.max { $0.computedAt < $1.computedAt }
            let manifest: InputManifest?
            if let manifestId = latestDerived?.inputManifestId {
                manifest = try inputs.derivation.manifest(id: manifestId)
            } else {
                manifest = nil
            }

            // Composite/derived metrics never surface raw-record source names (their lineage
            // reads from `derived`, not `intervals`), so skip the query + dictionary build
            // entirely when there are no raw records to name (PERF-041).
            let sourceNames: [String: String]
            if !intervals.isEmpty {
                sourceNames = Dictionary(
                    try inputs.catalog.sources().map { ($0.id, $0.displayName) },
                    uniquingKeysWith: { a, _ in a })
            } else {
                sourceNames = [:]
            }

            // Only sleep time-asleep surfaces the dedup decision (one kept, one suppressed).
            let dedup = inputs.metricId == MetricID.timeAsleep ? (try inputs.reconciliation.recent(limit: 6)) : []

            let fullSeries: [(date: Date, value: Double)]
            if !intervals.isEmpty {
                fullSeries = intervals.map { (date: $0.startAt, value: $0.value) }
            } else {
                fullSeries = derivedSeries.map {
                    (date: MetricDetailData.periodDate($0.periodKey, tz: tz) ?? $0.computedAt, value: $0.value)
                }
            }

            let data = MetricDetailData(
                def: def, baseline: baseline, intervals: intervals, derived: derivedSeries,
                latestDerivedValue: latestDerived, manifest: manifest, sourceNames: sourceNames,
                recentDedup: dedup, fullSeries: fullSeries)

            return .success(data)
        } catch {
            return .failure(error)
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
    @Environment(\.displayScale) private var displayScale
    @State private var vm = MetricDetailViewModel()
    @State private var periodDays: Int = 30
    @State private var showAnatomy = false
    /// How many values-table rows are currently revealed; grows via "Show more" instead of a
    /// silent hard cap (EASE-243/244, UIUX-034).
    @State private var visibleValuesCount = MetricDetailScreen.valuesPageSize
    /// Same "show more" pattern for the provenance lineage list (EASE-246).
    @State private var visibleLineageCount = MetricDetailScreen.lineagePageSize
    @State private var shareImage: UIImage?
    @State private var showShare = false

    private static let periodOptions = metricDetailPeriodOptions
    private static let valuesPageSize = 14
    private static let lineagePageSize = 8

    var body: some View {
        ScrollView {
            StatefulContainer(
                vm.state,
                retryTitle: env.s(LoadErrorCopy.retry),
                onRetry: { Task { await vm.load(env, metricId: metricId) } }
            ) { data in
                content(data)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(env.registry.definitionOrFallback(metricId).displayName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .loaded(let data) = vm.state {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        shareImage = renderShareImage(data)
                        showShare = shareImage != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(env.s(MetricDetailStrings.shareMetric))
                }
            }
        }
        .sheet(isPresented: $showAnatomy) {
            if case .loaded(let data) = vm.state {
                MetricAnatomySheet(data: data)
            }
        }
        .sheet(isPresented: $showShare) {
            if let shareImage {
                ShareSheet(activityItems: [shareImage])
            }
        }
        // Reload on any profile change (language/units/depth), not just first appearance, so
        // the most data-dense screen in the app never shows stale-language content (OPT-040).
        .task(id: env.profile) { await vm.load(env, metricId: metricId) }
        // Seeds the power period picker from this metric's remembered window (STUB-06a) instead
        // of always starting at the 30-day default on every push.
        .onAppear {
            periodDays = SessionPeriodMemory.rememberedPeriod(
                for: metricId, in: env.profile.sessionPreferences.lastMetricPeriodDays)
        }
    }

    // MARK: Body composition

    @ViewBuilder
    private func content(_ data: MetricDetailData) -> some View {
        let latest = data.fullSeries.last
        let power = env.depth.showsPowerDetail
        let chartDays = power ? periodDays : 30
        // Filtered once per render and shared by the chart and the values table instead of
        // each independently re-deriving it from `data` (PERF-036/037).
        let points = series(within: chartDays, from: data.fullSeries)

        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            headerCard(data, latest: latest)

            chartCard(data, points: points)

            if power {
                anatomyButton
                periodSelector
                valuesTableCard(points, data: data)
                lineageCard(data)
                methodCard(data)
                siblingMetricsRow(data)
            } else {
                // Same anatomy sheet power opens, just a quiet text link instead of the boxed
                // affordance — casual previously had zero route to "how was this worked out"
                // even though the sheet's own language is casual-safe (UX-02). Shown wherever
                // the sheet has content, mirroring power's own (unconditional) gate: every
                // branch of `MetricAnatomySheet` renders something — a real baseline/manifest
                // or an honest fallback line — so there's no loaded-data case where it's empty.
                casualAnatomyLink
                explainerCard(data)
            }
        }
        .onChange(of: periodDays) { _, newValue in
            visibleValuesCount = MetricDetailScreen.valuesPageSize
            // Write-back side of STUB-06a: remembers this metric's last-viewed window so the
            // next visit seeds from it instead of always starting over at 30.
            env.update { $0.sessionPreferences.lastMetricPeriodDays[metricId] = newValue }
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
                        chip: statusChip(data, value: latest.value))
                    // "As of"/"Computed for" removes the ambiguity of whether the date is a
                    // real capture time or a computed period date (UIUX-045).
                    Text("\(env.s(data.usesDerivedSeries ? MetricDetailStrings.computedForDate : MetricDetailStrings.asOf)) \(dateText(latest.date))")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    // Power depth gets the numeric distance from center, not just the
                    // three-state chip — the magnitude z-score/deviation view promises (EASE-157).
                    if env.depth.showsPowerDetail, let baseline = data.baseline {
                        Text(signedDelta(metricId: data.def.metricId, value: latest.value, baseline: baseline))
                            .font(BadanFont.caption.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
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
    private func chartCard(_ data: MetricDetailData, points: [(date: Date, value: Double)]) -> some View {
        // A metric that structurally can't have a baseline (not baseline-eligible) is not
        // "still learning" — that badge should only ever imply a baseline is genuinely on its
        // way (OPT-034/035).
        let provisional = data.def.baselineEligible && (data.baseline?.provisional ?? true)
        let band = chartBand(data)
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(MetricDetailStrings.trend) + (env.depth.showsPowerDetail ? "" : " · " + env.s(MetricDetailStrings.last30Days))) {
                    if provisional { ProvisionalBadge(language: env.language) }
                }
                // Passes the env's own unit/language/digit preference (FIX-02) — without these,
                // the chart's init defaults to English/Western-digit and no unit, which left the
                // Y axis unitless and every Arabic-only surface (empty state, tap caption,
                // outlier caption, VoiceOver summary, audio-graph labels) rendering in English.
                MetricChart(
                    series: points,
                    style: data.def.chartHint == .bar ? .bar : .line,
                    band: band,
                    unit: env.format.unitLabel(metricId: data.def.metricId),
                    language: env.language,
                    arabicDigits: env.profile.arabicDigits)
                    .frame(height: 200)
                if data.usesDerivedSeries || band != nil {
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        // Computed vs. measured is otherwise invisible until the anatomy sheet
                        // is opened (UIUX-042).
                        if data.usesDerivedSeries {
                            captionRow(icon: "function", text: env.s(MetricDetailStrings.computedFromData))
                        }
                        // The shaded band has no meaning without this legend anywhere on the
                        // screen that actually shows it (UIUX-043).
                        if band != nil {
                            HStack(spacing: BadanSpace.space1) {
                                Rectangle()
                                    .fill(BadanColor.inBand.opacity(0.35))
                                    .frame(width: 12, height: 12)
                                Text(env.s(MetricDetailStrings.usualRangeLegend))
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func captionRow(icon: String, text: String) -> some View {
        HStack(spacing: BadanSpace.space1) {
            Image(systemName: icon)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .font(BadanFont.caption)
        }
        .foregroundStyle(BadanColor.textSecondary)
    }

    // MARK: Casual explainer

    @ViewBuilder
    private func explainerCard(_ data: MetricDetailData) -> some View {
        BadanCard {
            // Casual depth has no fallback elsewhere on the screen, so a missing/empty
            // `explainerEn` must never leave casual users with zero explanatory text
            // (EASE-159). The ontology only carries an English explainer — there is no
            // `explainerAr` field — so the previous Arabic path silently substituted the
            // metric's own *name* as if it were a translated explainer, which just repeated
            // the header back at the user (FIX-03). Only English gets the real explainer;
            // Arabic always gets the honest generic fallback below.
            if env.language == .en, let explainer = data.def.explainerEn, !explainer.isEmpty {
                Text(explainer)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(env.s(MetricDetailStrings.genericExplainer))
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
                    // A bare "7 | 30 | 90" has no on-control unit; the "d" suffix confirms
                    // these are day counts without inference (UIUX-035).
                    Text("\(env.format.integer(d))\(env.s(MetricDetailStrings.daySuffix))").tag(d)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Power — values table

    @ViewBuilder
    private func valuesTableCard(_ points: [(date: Date, value: Double)], data: MetricDetailData) -> some View {
        // Reveals more of the already period-filtered `points` on tap instead of a silent,
        // period-blind 14-row hard cap (EASE-243/244, UIUX-034).
        let ordered = Array(points.reversed())
        let rows = Array(ordered.prefix(visibleValuesCount))
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                // Names the active unit right where the numbers are, instead of only in the
                // separate Method card further down (EASE-161).
                SectionHeader(env.s(MetricDetailStrings.recentValues) + " (\(env.format.unitLabel(metricId: data.def.metricId) ?? data.def.canonicalUnit))")
                ForEach(Array(rows.enumerated()), id: \.offset) { index, point in
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
                    // No divider trails the final row (UIUX-033).
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(BadanColor.separator)
                            .frame(height: 1)
                    }
                }
                if rows.count < ordered.count {
                    Button {
                        visibleValuesCount += Self.valuesPageSize
                    } label: {
                        Text(env.s(MetricDetailStrings.showMore))
                            .font(BadanFont.bodyCompact.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    // MARK: Power — provenance lineage

    @ViewBuilder
    private func lineageCard(_ data: MetricDetailData) -> some View {
        let total = data.usesDerivedSeries ? data.derived.count : data.intervals.count
        let entries = lineage(data, limit: visibleLineageCount)
        if !entries.isEmpty {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(Loc.provenance))
                    ForEach(entries) { entry in
                        ProvenanceRow(sourceName: entry.sourceName, ingestionPath: entry.ingestionPath,
                                      timestamp: entry.timestamp, language: env.language)
                    }
                    // Provenance auditing had nowhere to go past the most recent 8 (EASE-246).
                    if entries.count < total {
                        Button {
                            visibleLineageCount += Self.lineagePageSize
                        } label: {
                            Text(env.s(MetricDetailStrings.showMore))
                                .font(BadanFont.bodyCompact.weight(.medium))
                                .foregroundStyle(BadanColor.primary)
                                .frame(minHeight: BadanSpace.touchMin)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
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
                    // A raw "algorithmId@version" token satisfies transparency in letter but
                    // not in spirit; add the plain-language gloss alongside it (EASE-155/251).
                    if let gloss = methodGloss(data) {
                        Text(env.s(gloss))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
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
            // `.monospaced()`, not `.monospacedDigit()` — these values (unit labels, algorithm
            // ids) are mostly alphabetic, so only the whole-string variant actually aligns them
            // (UIUX-037).
            Text(value)
                .font(BadanFont.bodyCompact.monospaced())
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Casual — anatomy link

    /// Casual's minimal mirror of `anatomyButton` below — same `showAnatomy = true` action and
    /// the same sheet, just a quiet text link instead of a full card affordance (UX-02).
    private var casualAnatomyLink: some View {
        Button {
            showAnatomy = true
        } label: {
            Text(env.s(MetricDetailStrings.howIsThisWorkedOutCasual))
                .font(BadanFont.link)
                .foregroundStyle(BadanColor.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
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
            // Sits beside real `BadanCard`s in the same stack; without this it's the one flat
            // surface among several elevated ones (UIUX-036).
            .badanElevation()
        }
    }

    // MARK: Power — sibling metrics

    @ViewBuilder
    private func siblingMetricsRow(_ data: MetricDetailData) -> some View {
        let siblings = env.registry.metrics(in: data.def.familyGroup).filter { $0.metricId != data.def.metricId }
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(env.s(MetricDetailStrings.moreInFamily))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(siblings) { sibling in
                            NavigationLink {
                                MetricDetailScreen(metricId: sibling.metricId)
                            } label: {
                                Text(sibling.label(depth: env.depth, language: env.language))
                                    .font(BadanFont.bodyCompact.weight(.medium))
                                    .foregroundStyle(BadanColor.primary)
                                    .padding(.horizontal, BadanSpace.space3)
                                    .frame(minHeight: BadanSpace.touchMin)
                                    .background(BadanColor.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(BadanColor.separator, lineWidth: 1))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    // A tolerant rolling filter window (last N*24h, not "last N calendar days") — deliberately
    // not `DayAttribution` day math (DATA-11-UI): the 7/30/90 period picker itself is a rolling
    // window by design, not calendar-aligned, so switching this to day-boundary math would
    // change what "7 days" means without changing the picker's own labels.
    private func series(within days: Int, from full: [(date: Date, value: Double)]) -> [(date: Date, value: Double)] {
        let cutoff = env.now().addingTimeInterval(-Double(days) * 86_400)
        return full.filter { $0.date >= cutoff }
    }

    /// The shaded personal-band, shared by the on-screen chart and the share-image render
    /// (FIX-06) so the two can't silently drift apart. A provisional baseline hasn't earned the
    /// visual authority of a shaded "trustworthy range" yet — suppress the band until it's
    /// confirmed, matching the badge/chip's own honesty (OPT-042).
    private func chartBand(_ data: MetricDetailData) -> (low: Double, high: Double)? {
        (data.baseline?.provisional == false)
            ? data.baseline.map { (low: $0.bandLow, high: $0.bandHigh) }
            : nil
    }

    private func statusChip(_ data: MetricDetailData, value: Double) -> StatusChip? {
        // A metric with no personal-range concept at all shouldn't perpetually claim to be
        // "still learning" a baseline that's never coming (OPT-034/035).
        guard data.def.baselineEligible else { return nil }
        guard let baseline = data.baseline, !baseline.provisional else {
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

    /// Signed distance from the personal band's center — the magnitude figure power depth
    /// promises but previously never showed (EASE-157). Mirrors `HomeViewModel.signedDelta`;
    /// kept file-local since `HomeScreen.swift` isn't owned by this change.
    private func signedDelta(metricId: String, value: Double, baseline: Baseline) -> String {
        let delta = value - baseline.center
        let sign = delta >= 0 ? "+" : "\u{2212}"
        let magnitude = env.format.heroValue(metricId: metricId, canonicalValue: abs(delta))
        let vs = env.s(MetricDetailStrings.vsYourMedian)
        if let unit = env.format.unitLabel(metricId: metricId) {
            return "\(sign)\(magnitude) \(unit) \u{00B7} \(vs)"
        }
        return "\(sign)\(magnitude) \u{00B7} \(vs)"
    }

    private func methodString(_ data: MetricDetailData) -> String? {
        if let d = data.latestDerivedValue { return "\(d.algorithmId)@\(d.algorithmVersion)" }
        return data.baseline?.algorithmVersion
    }

    /// The algorithm id alone (without version), used to look up its plain-language gloss.
    private func algorithmId(_ data: MetricDetailData) -> String? {
        if let d = data.latestDerivedValue { return d.algorithmId }
        guard let version = data.baseline?.algorithmVersion else { return nil }
        return version.split(separator: "@").first.map(String.init)
    }

    private func methodGloss(_ data: MetricDetailData) -> LocalizedString? {
        guard let id = algorithmId(data) else { return nil }
        return MetricDetailStrings.algorithmGloss[id]
    }

    private func lineage(_ data: MetricDetailData, limit: Int) -> [LineageEntry] {
        // Wires up the previously-dead `usesDerivedSeries` flag instead of re-deriving the
        // same branch condition separately (OPT-043).
        if !data.usesDerivedSeries {
            return data.intervals.suffix(limit).reversed().map { r in
                LineageEntry(id: r.id,
                             sourceName: data.sourceNames[r.provenance.sourceId] ?? r.provenance.sourceId,
                             ingestionPath: r.provenance.ingestionPath,
                             timestamp: r.provenance.measuredAt)
            }
        }
        // A composite's own display name repeated per row said nothing real about
        // provenance; the algorithm identity that actually produced each row does (OPT-038).
        return data.derived.suffix(limit).reversed().map { d in
            LineageEntry(id: d.id,
                         sourceName: "\(d.algorithmId)@\(d.algorithmVersion)",
                         ingestionPath: .derived,
                         timestamp: d.computedAt)
        }
    }

    // Cached once per type instead of allocating a fresh `DateFormatter` on every render; only
    // the locale changes between calls (PERF-039/040).
    private static let cachedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func dateText(_ date: Date) -> String {
        Self.cachedDateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.cachedDateFormatter.string(from: date)
    }

    /// Renders a small shareable summary (headline value + chart) for the toolbar share
    /// action, reusing the existing generic `ShareSheet` (FEAT-158).
    @MainActor
    private func renderShareImage(_ data: MetricDetailData) -> UIImage? {
        // Shares whatever window/band the user is actually looking at on screen (FIX-06) —
        // this used to hardcode 30 days and skip the provisional-baseline band gate regardless
        // of the 7/30/90 picker, so a shared image could silently disagree with the chart it
        // was captured from.
        let chartDays = env.depth.showsPowerDetail ? periodDays : 30
        let points = series(within: chartDays, from: data.fullSeries)
        let latest = points.last
        let summary = VStack(alignment: .leading, spacing: BadanSpace.space3) {
            Text(data.def.label(depth: env.depth, language: env.language))
                .font(BadanFont.sectionTitle)
                .foregroundStyle(BadanColor.textPrimary)
            if let latest {
                Text(env.format.heroValue(metricId: data.def.metricId, canonicalValue: latest.value))
                    .font(BadanFont.heroNumeral)
                    .foregroundStyle(BadanColor.textPrimary)
            }
            MetricChart(
                series: points,
                style: data.def.chartHint == .bar ? .bar : .line,
                band: chartBand(data),
                unit: env.format.unitLabel(metricId: data.def.metricId),
                language: env.language,
                arabicDigits: env.profile.arabicDigits)
                .frame(height: 160)
        }
        .padding(BadanSpace.space4)
        .frame(width: 360)
        .background(BadanColor.background)
        .environment(\.layoutDirection, env.language == .ar ? .rightToLeft : .leftToRight)

        let renderer = ImageRenderer(content: summary)
        renderer.scale = displayScale
        return renderer.uiImage
    }
}

/// A uniform lineage row model so raw records and computed values render the same shape.
private struct LineageEntry: Identifiable {
    let id: String
    let sourceName: String
    let ingestionPath: IngestionPath
    let timestamp: Date
}
