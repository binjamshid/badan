import SwiftUI

// MARK: - Model

/// One pillar shown on the Body front door: a family, its headline metric, and just enough
/// data to render a calm value + status word + recent-trend sparkline.
struct BodyPillar: Identifiable {
    let family: MetricFamily
    let metricId: String
    let latest: Double
    let series: [(date: Date, value: Double)]   // chronological; last == most recent (for the sparkline)
    let baseline: Baseline?
    /// Total baseline-eligible metrics tracked in this family, so the card can hint that more
    /// than just the headline metric is available (EASE-179).
    let familyMetricCount: Int

    var id: String { family.rawValue }
}

struct BodyData {
    let pillars: [BodyPillar]
}

// MARK: - View model

/// Everything `BodyViewModel.fetch` needs to run off the main actor — the thread-safe
/// registry/repository references plus a `now` snapshot (PERF-01).
struct BodyFetchInputs {
    var registry: MetricRegistry
    var derivation: DerivationRepository
    var measurements: MeasurementRepository
    var now: Date
}

@Observable
@MainActor
final class BodyViewModel {
    var state: LoadState<BodyData> = .loading

    /// Headline metric preference per family; falls back to any baseline-eligible metric that
    /// actually carries data. Same data, curated altitude — never a second dataset.
    ///
    /// Only 6 of `MetricFamily`'s 17 cases are curated here. The uncurated remainder splits in two:
    /// `.subjective`/`.symptoms`/`.medications`/`.other` have no typed `MetricID` constants yet
    /// (OPT-016), and the seven registry v0.2.0 families (`.readiness`, `.workout`, `.effort`,
    /// `.hydration`, `.stress`, `.cycle`, `.lab`) have constants but no curated headline choice —
    /// picking one is a product call owned by the epics building those surfaces. Both fall through
    /// to `makePillar`'s uncurated "first baseline-eligible metric in registry order" path below,
    /// which yields a correct pillar, just not a deliberately-chosen one. Extending this dictionary
    /// needs either new constants in `Domain/MetricID.swift` or that product call — left as a known,
    /// intentional gap rather than hardcoding raw id strings here.
    /// `nonisolated` — read from `makePillar`, which now runs off the main actor (PERF-01); a
    /// plain immutable `let` of `Sendable` value types is safe to hand to a nonisolated context.
    private nonisolated static let headline: [MetricFamily: [String]] = [
        .sleep: [MetricID.timeAsleep, MetricID.sleepEfficiency],
        .heart: [MetricID.restingHeartRate, MetricID.hrv, MetricID.heartRate],
        .activity: [MetricID.steps, MetricID.activeEnergy, MetricID.distance, MetricID.exerciseMinutes],
        .body: [MetricID.weight, MetricID.bmi],
        .respiratory: [MetricID.respiratoryRate, MetricID.spo2],
        .nutrition: [MetricID.energyIn, MetricID.protein, MetricID.water],
    ]

    /// Guards against a redundant full reload (widest store fan-out of any presentation load,
    /// PERF-026) when Body reappears with nothing changed. Mirrors Home's `lastLoadedAt` guard
    /// (PERF-022); any real profile change still reloads immediately since `.task(id: env.profile)`
    /// re-invokes `load` with a new task.
    private var lastLoadedAt: Date?
    private var lastLoadedProfile: CustomizationProfile?
    /// BUG-12/13: a bumped `dataGeneration` always forces a reload even when `profile` hasn't
    /// changed and the 5s window hasn't elapsed — see `AppEnvironment.dataGeneration`.
    private var lastLoadedGeneration: Int?
    private static let staleThreshold: TimeInterval = 5

    /// Evaluates the staleness guard on the main actor, then (PERF-01) runs the actual queries
    /// on a detached task so a Body reload — the widest store fan-out of any screen — never
    /// blocks the main thread. A cancelled load never clobbers state.
    func load(_ env: AppEnvironment) async {
        if case .loaded = state,
           let lastLoadedAt, let lastLoadedProfile, lastLoadedProfile == env.profile,
           let lastLoadedGeneration, lastLoadedGeneration == env.dataGeneration,
           env.now().timeIntervalSince(lastLoadedAt) < Self.staleThreshold {
            return
        }

        let now = env.now()
        let profileSnapshot = env.profile
        let generationSnapshot = env.dataGeneration
        let inputs = BodyFetchInputs(
            registry: env.registry, derivation: env.derivation, measurements: env.measurements, now: now)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let data):
            lastLoadedAt = now
            lastLoadedProfile = profileSnapshot
            lastLoadedGeneration = generationSnapshot
            state = .loaded(data)
        case .failure(let error):
            // A genuine store failure, not "no data yet" — the try?-swallowing this replaced
            // made every DB error render identically to an empty Body tab (OPT-015). The raw
            // error goes to the debug log, not the UI (BUG-14) — the user sees one calm,
            // bilingual "couldn't load" message with a retry action instead.
            LoadErrorLog.log(error, screen: "Body")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Fetch core (nonisolated — runs on a detached task)

    /// Kept `internal` (not `private`) so `ViewModelPerformanceTests` can measure query cost
    /// directly, same as before this change.
    nonisolated static func fetch(_ inputs: BodyFetchInputs) -> Result<BodyData, Error> {
        let signpostState = PerformanceLog.signposter.beginInterval("BodyViewModel.load")
        defer { PerformanceLog.signposter.endInterval("BodyViewModel.load", signpostState) }

        do {
            var pillars: [BodyPillar] = []
            for family in inputs.registry.families {
                if let pillar = try makePillar(inputs, family: family) { pillars.append(pillar) }
            }
            return .success(BodyData(pillars: pillars))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func makePillar(_ inputs: BodyFetchInputs, family: MetricFamily) throws -> BodyPillar? {
        let eligible = inputs.registry.metrics(in: family).filter { $0.baselineEligible }
        var candidates = Self.headline[family] ?? []
        candidates += eligible.map(\.metricId)

        var seen = Set<String>()
        for metricId in candidates where seen.insert(metricId).inserted {
            let series = try recentSeries(inputs, metricId: metricId, windowDays: 12)
            guard let latest = series.last?.value else { continue }
            // No trailing `?? nil` — `latestBaseline` already returns an honest `Baseline?`;
            // a thrown error now propagates instead of masquerading as "no baseline yet" (OPT-018).
            let baseline = try inputs.derivation.latestBaseline(metricId: metricId)
            return BodyPillar(
                family: family, metricId: metricId, latest: latest,
                series: Array(series.suffix(7)), baseline: baseline,
                familyMetricCount: max(eligible.count, 1))
        }
        return nil
    }

    /// Recent daily-ish series for a metric, tried across the stores it might live in: derived
    /// rollups, interval records (latest per local day), then raw samples. `def.kind` short-
    /// circuits the interval-records round trip for metrics that only ever land as raw samples
    /// (PERF-026); an empty result from a store is a legitimate "nothing recorded there" and
    /// keeps probing the next store, but a thrown error now propagates instead of being silently
    /// swallowed and retried as if it were just an empty store (OPT-019).
    private nonisolated static func recentSeries(_ inputs: BodyFetchInputs, metricId: String, windowDays: Int) throws -> [(date: Date, value: Double)] {
        let now = inputs.now
        // A tolerant rolling lookback (last N*24h), not a calendar-day boundary — intentionally
        // not `DayAttribution` day math (DATA-11-UI): this only bounds the sparkline/headline
        // query, and the per-day dedup below already reduces raw samples via `DayAttribution`.
        let from = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let def = inputs.registry.definitionOrFallback(metricId)

        if def.kind == .derived {
            let pts = try derivedSeries(inputs, metricId: metricId, from: from)
            if !pts.isEmpty { return pts }
        }

        if def.kind != .rawSample {
            let recs = try inputs.measurements.intervalRecords(metricId: metricId, from: from, to: now)
            if !recs.isEmpty {
                var byDay: [String: IntervalRecord] = [:]
                for r in recs {
                    let key = DayAttribution.localDayKey(r.startAt, tz: r.tzId)
                    if let existing = byDay[key], existing.startAt >= r.startAt { continue }
                    byDay[key] = r
                }
                let pts = byDay.keys.sorted().compactMap { key -> (date: Date, value: Double)? in
                    byDay[key].map { (date: $0.startAt, value: $0.value) }
                }
                if !pts.isEmpty { return pts }
            }
        }

        let raws = try inputs.measurements.rawSamples(metricId: metricId, from: from, to: now)
        if !raws.isEmpty {
            return raws.map { (date: $0.startAt, value: $0.value) }.sorted { $0.date < $1.date }
        }

        return try derivedSeries(inputs, metricId: metricId, from: from)
    }

    private nonisolated static func derivedSeries(_ inputs: BodyFetchInputs, metricId: String, from: Date) throws -> [(date: Date, value: Double)] {
        let values = try inputs.derivation.latestDerivedSeries(metricId: metricId)
        guard !values.isEmpty else { return [] }
        let tz = TimeZone.current.identifier
        return values.compactMap { dv -> (date: Date, value: Double)? in
            let key = dv.periodKey.hasPrefix("day:") ? String(dv.periodKey.dropFirst(4)) : dv.periodKey
            let date = DayAttribution.date(fromDayKey: key, tz: tz) ?? dv.computedAt
            return (date: date, value: dv.value)
        }
        .filter { $0.date >= from }
        .sorted { $0.date < $1.date }
    }
}

// MARK: - Screen

/// "Your body" — the repository front door. Each family with data becomes a calm pillar that
/// leads into the universal metric detail; below, the tools that open the whole repository.
struct BodyScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = BodyViewModel()
    /// (EPIC-01 task 5, plan §13.1: "body metrics from Body") Weight, body fat and lean mass are
    /// asked for here rather than at onboarding's connect step — most people have none of them,
    /// and spending a permission prompt on an empty family before the user has seen anything is
    /// how a first run starts feeling extractive.
    @State private var permissions = HealthPermissionGate()

    private static let browseHeader = LocalizedString(en: "Browse everything", ar: "تصفّح كل شيء")
    private static let pillarsHeader = LocalizedString(en: "Your systems", ar: "أنظمتك")

    var body: some View {
        StatefulContainer(
            vm.state,
            retryTitle: env.s(LoadErrorCopy.retry),
            onRetry: { Task { await vm.load(env) } }
        ) { data in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    if !data.pillars.isEmpty {
                        SectionHeader(env.s(Self.pillarsHeader))
                        ForEach(data.pillars) { pillar in
                            BodyPillarCard(pillar: pillar)
                        }
                    }

                    SectionHeader(env.s(Self.browseHeader))
                        .padding(.top, data.pillars.isEmpty ? 0 : BadanSpace.space2)
                    BodyToolsCard()
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.bodyTitle))
        // A search-shaped question ("find this one metric") shouldn't require recognizing that
        // "Browse everything → All metrics" is where search lives, two taps down (EASE-178).
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    BodyAllMetricsBrowser()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(Text(Loc.search, language: env.language))
            }
        }
        .permissionExplainer(permissions)
        .task(id: BodyLoadKey(profile: env.profile, generation: env.dataGeneration)) { await vm.load(env) }
        // Separate from the load task: staging runs once per appearance, not again on every
        // `dataGeneration` bump — an explainer that re-evaluates whenever a sync lands is one
        // background wake away from reading as a nag.
        .task { permissions.request([.body]) }
    }
}

/// BUG-12/13: the standardized `.task(id:)` identity — see `HomeLoadKey` (`HomeScreen.swift`)
/// for the rationale; kept as its own file-local type (not shared) since Home and Body don't
/// otherwise depend on each other.
private struct BodyLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

// MARK: - Pillar card

private struct BodyPillarCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let pillar: BodyPillar

    @State private var showsExplainer = false

    private static let moreInFamily = LocalizedString(en: "+{n} more in this family", ar: "+{n} أخرى في هذه الفئة")
    private static let whatIsThis = LocalizedString(en: "What is this?", ar: "ما هذا؟")
    /// "In your usual range" alone is unfalsifiable without the numbers behind it; show the band
    /// once here rather than forcing a second tap into Metric Detail to see it (EASE-140).
    private static let usualRangeCaption = LocalizedString(en: "Usual range {low}–{high}", ar: "النطاق المعتاد {low}–{high}")

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                NavigationLink {
                    MetricDetailScreen(metricId: pillar.metricId)
                } label: {
                    HStack(alignment: .top, spacing: BadanSpace.space3) {
                        Image(systemName: pillar.family.symbolName)
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: BadanSpace.space1) {
                            let status = pillarStatus
                            StatBox(
                                value: env.format.heroValue(metricId: pillar.metricId, canonicalValue: pillar.latest),
                                label: env.s(pillar.family.displayName),
                                unit: env.format.unitLabel(metricId: pillar.metricId),
                                chip: StatusChip(status.0, label: env.s(status.1), language: env.language),
                                size: .compact
                            )
                            // Long family names shouldn't wrap into the sparkline/chevron column
                            // at larger Dynamic Type sizes (UIUX-026).
                            .lineLimit(1)
                            if let bandCaption {
                                Text(bandCaption)
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                        }

                        Spacer(minLength: BadanSpace.space2)

                        // Fixed-size decoration; hidden at accessibility text sizes rather than
                        // fighting the growing label/value/chip stack for room (UIUX-018).
                        if pillar.series.count >= 2, !dynamicTypeSize.isAccessibilitySize {
                            MetricSparkline(series: pillar.series)
                                .frame(width: 76, height: 36)
                                .accessibilityHidden(true)
                        }

                        Image(systemName: "chevron.forward")
                            .font(BadanFont.caption.weight(.semibold))
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)

                // A family can carry several tracked metrics behind its one headline value; hint
                // that more exist instead of leaving them undiscoverable outside "All metrics"
                // (EASE-179). A separate tap target, not nested inside the link above.
                HStack(spacing: BadanSpace.touchGap) {
                    if pillar.familyMetricCount > 1 {
                        NavigationLink {
                            BodyAllMetricsBrowser(initialFamily: pillar.family)
                        } label: {
                            Text(Self.moreInFamily.filling(["n": env.format.integer(pillar.familyMetricCount - 1)]), language: env.language)
                                .font(BadanFont.caption.weight(.medium))
                                .foregroundStyle(BadanColor.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    // (EPIC-01 task 5) The family explainer, reachable from the surface the
                    // family is actually shown on. "Why is this empty?" and "what is wrist
                    // temperature?" are both questions people ask HERE, looking at the card —
                    // not two taps away in Sources.
                    Button {
                        showsExplainer = true
                    } label: {
                        Text(Self.whatIsThis, language: env.language)
                            .font(BadanFont.caption.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: BadanSpace.touchMin)
            }
        }
        .sheet(isPresented: $showsExplainer) {
            MetricFamilyExplainerSheet(family: pillar.family)
        }
    }

    /// Position over the personal band, never good/bad. Provisional or missing baseline stays
    /// honest with a "still learning" info state.
    private var pillarStatus: (StatusChip.Status, LocalizedString) {
        if let baseline = pillar.baseline, !baseline.provisional {
            switch baseline.position(of: pillar.latest) {
            case .within: return (.inBand, Loc.inYourRange)
            case .above: return (.above, Loc.aboveYourRange)
            case .below: return (.below, Loc.belowYourRange)
            }
        }
        return (.info, Loc.stillLearning)
    }

    private var bandCaption: String? {
        guard let baseline = pillar.baseline, !baseline.provisional else { return nil }
        let low = env.format.heroValue(metricId: pillar.metricId, canonicalValue: baseline.bandLow)
        let high = env.format.heroValue(metricId: pillar.metricId, canonicalValue: baseline.bandHigh)
        return Self.usualRangeCaption.filling(["low": low, "high": high]).resolved(env.language)
    }
}

// MARK: - Repository tools

private struct BodyToolsCard: View {
    // EPIC-27: the Health Monitor lives under Body (plan §11 EPIC-27 / §16 IA: "new, under Body";
    // a sixth tab would regress the documented five-destination shell). Placed first so the vitals
    // dashboard is the most reachable of Body's tools.
    private static let healthMonitor = LocalizedString(en: "Health Monitor", ar: "مراقب الصحة")

    var body: some View {
        BadanCard(padding: 0) {
            VStack(spacing: 0) {
                BodyToolLink(icon: "waveform.path.ecg", title: Self.healthMonitor) { HealthMonitorScreen() }
                BodyToolDivider()
                BodyToolLink(icon: "square.grid.2x2", title: Loc.allMetrics) { BodyAllMetricsBrowser() }
                BodyToolDivider()
                BodyToolLink(icon: "antenna.radiowaves.left.and.right", title: Loc.dataSources) { SourcesScreen() }
                BodyToolDivider()
                BodyToolLink(icon: "square.and.arrow.up", title: Loc.exportData) { ExportCenterScreen() }
                BodyToolDivider()
                BodyToolLink(icon: "clock.arrow.circlepath", title: Loc.timeline) { TimelineScreen() }
            }
        }
    }
}

private struct BodyToolDivider: View {
    var body: some View {
        Rectangle()
            .fill(BadanColor.separator)
            .frame(height: 1)
            .padding(.leading, BadanSpace.cardPadding)
    }
}

private struct BodyToolLink<Destination: View>: View {
    let icon: String
    let title: LocalizedString
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            BodyToolRow(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }
}

private struct BodyToolRow: View {
    let icon: String
    let title: LocalizedString

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(BadanColor.primary)
                .frame(width: 26)
                .accessibilityHidden(true)
            LText(title)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            Image(systemName: "chevron.forward")
                .font(BadanFont.caption.weight(.semibold))
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, BadanSpace.cardPadding)
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
    }
}

// MARK: - All-metrics browser

private struct BodyMetricGroup: Identifiable {
    let family: MetricFamily
    let metrics: [MetricDefinition]
    var id: String { family.rawValue }
}

/// Session-scoped memory of the browser's last search query — not persisted across app
/// launches, just kept alive for the process lifetime so a power user reopening the browser
/// within the same session doesn't have to retype it (EASE-297, minimal scope: last query only,
/// not a full recent/frequent-metrics history). Only ever touched from `BodyAllMetricsBrowser`,
/// which is itself only ever used on the main thread.
private enum RecentMetricSearch {
    static var lastQuery: String = ""
}

/// The full ontology, searchable and grouped by family — raw catalog is never paywalled. Every
/// row leads to the same universal metric detail.
struct BodyAllMetricsBrowser: View {
    @Environment(AppEnvironment.self) private var env
    /// When set, scopes the browser to a single family — used by a pillar card's "+N more" link
    /// (EASE-179) rather than dropping the user into the full unscoped ontology.
    var initialFamily: MetricFamily?
    @State private var query: String

    /// A family-scoped browser (opened from a pillar's "+N more" link) is a different task from
    /// the full unscoped ontology browser, so it shouldn't inherit a stale search query the user
    /// typed the last time they opened the *other* one (BUG-20) — nor should typing here later
    /// overwrite that unscoped session's memory (see `onChange(of: query)` below).
    init(initialFamily: MetricFamily? = nil) {
        self.initialFamily = initialFamily
        _query = State(initialValue: initialFamily == nil ? RecentMetricSearch.lastQuery : "")
    }

    private static let noMatches = LocalizedString(en: "No matching metrics", ar: "لا مؤشرات مطابقة")
    private static let clearSearch = LocalizedString(en: "Clear search", ar: "مسح البحث")

    var body: some View {
        List {
            if groups.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: env.s(Self.noMatches),
                    message: "",
                    actionTitle: query.isEmpty ? nil : env.s(Self.clearSearch),
                    action: query.isEmpty ? nil : { query = "" }
                )
                .listRowBackground(BadanColor.surface)
                .listRowSeparator(.hidden)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.metrics) { def in
                            NavigationLink {
                                MetricDetailScreen(metricId: def.metricId)
                            } label: {
                                metricRow(def)
                            }
                            .listRowBackground(BadanColor.surface)
                        }
                    } header: {
                        // Native `List` section headers render in the system's default
                        // gray-uppercase style; restyle to match `SectionHeader`'s look so this
                        // screen doesn't read as visually distinct from the rest of the app
                        // (UIUX-028).
                        Text(env.s(group.family.displayName))
                            .font(BadanFont.sectionTitle)
                            .foregroundStyle(BadanColor.textPrimary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BadanColor.background.ignoresSafeArea())
        .searchable(text: $query, prompt: Text(Loc.search, language: env.language))
        .onChange(of: query) { _, newValue in
            // Only the unscoped browser's query is worth remembering session-wide; a
            // family-scoped session shouldn't clobber that memory with its own narrower search
            // (BUG-20).
            guard initialFamily == nil else { return }
            RecentMetricSearch.lastQuery = newValue
        }
        // A family-scoped browser is titled with that family's own name rather than the
        // generic "All metrics" (BUG-20) — it isn't showing all metrics, just this family's.
        .navigationTitle(env.s(initialFamily?.displayName ?? Loc.allMetrics))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metricRow(_ def: MetricDefinition) -> some View {
        HStack(spacing: BadanSpace.space3) {
            // Every other row-based list in the app leads with a family/type icon; this was the
            // one text-only list, exactly where scanning the registry's whole catalogue of
            // unfamiliar metric names benefits most from it (UIUX-022).
            //
            // The catalogue size is not written here: it said "44 unfamiliar metric names" and the
            // registry had already grown past that (audit finding #9). The argument for the icon
            // does not depend on the exact count, and a count in a comment is a count that goes
            // stale on the next ontology addition — `env.registry.all` is the live one.
            Image(systemName: def.familyGroup.symbolName)
                .font(.system(size: 17))
                .foregroundStyle(BadanColor.primary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(def.label(depth: env.depth, language: env.language))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                if env.depth.showsPowerDetail {
                    // Monospaced marks this as a technical identifier, not a second descriptive
                    // label, matching how algorithm/method strings are styled elsewhere (EASE-182).
                    Text(def.metricId)
                        .font(BadanFont.caption.monospaced())
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
        .padding(.vertical, BadanSpace.space1)
    }

    private var results: [MetricDefinition] {
        let base = query.trimmingCharacters(in: .whitespaces).isEmpty ? env.registry.all : env.registry.search(query)
        guard let initialFamily else { return base }
        return base.filter { $0.familyGroup == initialFamily }
    }

    private var groups: [BodyMetricGroup] {
        Dictionary(grouping: results, by: { $0.familyGroup })
            .map { BodyMetricGroup(family: $0.key, metrics: $0.value.sorted { $0.metricId < $1.metricId }) }
            .sorted { orderIndex($0.family) < orderIndex($1.family) }
    }

    private func orderIndex(_ family: MetricFamily) -> Int {
        MetricFamily.allCases.firstIndex(of: family) ?? MetricFamily.allCases.count
    }
}
