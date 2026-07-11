import SwiftUI

// MARK: - Model

/// One pillar shown on the Body front door: a family, its headline metric, and just enough
/// data to render a calm value + status word + recent-trend sparkline.
struct BodyPillar: Identifiable {
    let family: MetricFamily
    let metricId: String
    let latest: Double
    let values: [Double]      // chronological; last == most recent (for the sparkline)
    let baseline: Baseline?

    var id: String { family.rawValue }
}

struct BodyData {
    let pillars: [BodyPillar]
}

// MARK: - View model

@Observable
@MainActor
final class BodyViewModel {
    var state: LoadState<BodyData> = .loading

    /// Headline metric preference per family; falls back to any baseline-eligible metric that
    /// actually carries data. Same data, curated altitude — never a second dataset.
    private static let headline: [MetricFamily: [String]] = [
        .sleep: [MetricID.timeAsleep, MetricID.sleepEfficiency],
        .heart: [MetricID.restingHeartRate, MetricID.hrv, MetricID.heartRate],
        .activity: [MetricID.steps, MetricID.activeEnergy, MetricID.distance, MetricID.exerciseMinutes],
        .body: [MetricID.weight, MetricID.bmi],
        .respiratory: [MetricID.respiratoryRate, MetricID.spo2],
        .nutrition: [MetricID.energyIn, MetricID.protein, MetricID.water],
    ]

    func load(_ env: AppEnvironment) {
        var pillars: [BodyPillar] = []
        for family in env.registry.families {
            if let pillar = makePillar(env, family: family) { pillars.append(pillar) }
        }
        state = .loaded(BodyData(pillars: pillars))
    }

    private func makePillar(_ env: AppEnvironment, family: MetricFamily) -> BodyPillar? {
        var candidates = Self.headline[family] ?? []
        candidates += env.registry.metrics(in: family).filter { $0.baselineEligible }.map(\.metricId)

        var seen = Set<String>()
        for metricId in candidates where seen.insert(metricId).inserted {
            let series = recentSeries(env, metricId: metricId, windowDays: 12)
            guard let latest = series.last?.value else { continue }
            let baseline = (try? env.derivation.latestBaseline(metricId: metricId)) ?? nil
            return BodyPillar(
                family: family, metricId: metricId, latest: latest,
                values: series.suffix(7).map { $0.value }, baseline: baseline)
        }
        return nil
    }

    /// Recent daily-ish series for a metric, tried across the three stores it might live in:
    /// derived rollups, interval records (latest per local day), then raw samples.
    private func recentSeries(_ env: AppEnvironment, metricId: String, windowDays: Int) -> [(date: Date, value: Double)] {
        let now = env.now()
        let from = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let def = env.registry.definitionOrFallback(metricId)

        if def.kind == .derived {
            let pts = derivedSeries(env, metricId: metricId, from: from)
            if !pts.isEmpty { return pts }
        }

        if let recs = try? env.measurements.intervalRecords(metricId: metricId, from: from, to: now), !recs.isEmpty {
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

        if let recs = try? env.measurements.rawSamples(metricId: metricId, from: from, to: now), !recs.isEmpty {
            return recs.map { (date: $0.startAt, value: $0.value) }.sorted { $0.date < $1.date }
        }

        return derivedSeries(env, metricId: metricId, from: from)
    }

    private func derivedSeries(_ env: AppEnvironment, metricId: String, from: Date) -> [(date: Date, value: Double)] {
        guard let values = try? env.derivation.latestDerivedSeries(metricId: metricId), !values.isEmpty else { return [] }
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

    private static let browseHeader = LocalizedString(en: "Browse everything", ar: "تصفّح كل شيء")
    private static let pillarsHeader = LocalizedString(en: "Your systems", ar: "أنظمتك")

    var body: some View {
        StatefulContainer(vm.state) { data in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    if !data.pillars.isEmpty {
                        SectionHeader(env.s(Self.pillarsHeader))
                        ForEach(data.pillars) { pillar in
                            NavigationLink {
                                MetricDetailScreen(metricId: pillar.metricId)
                            } label: {
                                BodyPillarCard(pillar: pillar)
                            }
                            .buttonStyle(.plain)
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
        .task { vm.load(env) }
    }
}

// MARK: - Pillar card

private struct BodyPillarCard: View {
    @Environment(AppEnvironment.self) private var env
    let pillar: BodyPillar

    var body: some View {
        BadanCard {
            HStack(alignment: .center, spacing: BadanSpace.space4) {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: pillar.family.symbolName)
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        LText(pillar.family.displayName)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                        Text(env.format.heroValue(metricId: pillar.metricId, canonicalValue: pillar.latest))
                            .font(BadanFont.numeralM)
                            .foregroundStyle(BadanColor.textPrimary)
                        if let unit = env.format.unitLabel(metricId: pillar.metricId), !unit.isEmpty {
                            Text(unit)
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }

                    let status = pillarStatus
                    StatusChip(status.0, label: env.s(status.1), language: env.language)
                }

                Spacer(minLength: BadanSpace.space2)

                if pillar.values.count >= 2 {
                    MetricSparkline(values: pillar.values)
                        .frame(width: 76, height: 36)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.forward")
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
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
}

// MARK: - Repository tools

private struct BodyToolsCard: View {
    var body: some View {
        BadanCard(padding: 0) {
            VStack(spacing: 0) {
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

/// The full ontology, searchable and grouped by family — raw catalog is never paywalled. Every
/// row leads to the same universal metric detail.
struct BodyAllMetricsBrowser: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""

    private static let noMatches = LocalizedString(en: "No matching metrics", ar: "لا مؤشرات مطابقة")

    var body: some View {
        List {
            if groups.isEmpty {
                Text(env.s(Self.noMatches))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .listRowBackground(BadanColor.surface)
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
                        Text(env.s(group.family.displayName))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BadanColor.background.ignoresSafeArea())
        .searchable(text: $query, prompt: Text(Loc.search, language: env.language))
        .navigationTitle(env.s(Loc.allMetrics))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metricRow(_ def: MetricDefinition) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(def.label(depth: env.depth, language: env.language))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            if env.depth.showsPowerDetail {
                Text(def.metricId)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
        .padding(.vertical, BadanSpace.space1)
    }

    private var results: [MetricDefinition] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? env.registry.all : env.registry.search(query)
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
