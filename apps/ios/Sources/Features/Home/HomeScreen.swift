import SwiftUI

// MARK: - Screen

/// The flagship "Today" tab. Answers, at two altitudes over one model: how am I doing, why,
/// and what changed? Casual shows a calm readiness hero + a short narrative + a few tappable
/// modules; power keeps the same data but denser — deviation numbers, inline sparklines and a
/// timeline preview. Never moralizes state (no good/bad colour); out-of-band is one amber chip.
struct HomeScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = HomeViewModel()

    var body: some View {
        StatefulContainer(vm.state) { data in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    HomeHeader(data: data)
                    if env.depth.showsPowerDetail {
                        HomePowerBody(data: data)
                    } else {
                        HomeCasualBody(data: data)
                    }
                }
                .padding(.horizontal, BadanSpace.space4)
                .padding(.vertical, BadanSpace.space4)
            }
            .background(BadanColor.background)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.today))
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.load(env) }
    }
}

// MARK: - Header

private struct HomeHeader: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(env.greeting, language: env.language)
                    .font(BadanFont.sectionTitle)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(dateText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            DepthBadge(env.depth, language: env.language)
        }
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: env.language.localeIdentifier)
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: data.date)
    }
}

// MARK: - Casual body

private struct HomeCasualBody: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            ReadinessHeroCard(data: data)

            // One calm sentence: the "how am I doing" in plain language.
            BadanCard {
                Text(data.narrative, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isVisible("sleep"), let sleep = data.sleep {
                SleepModuleCard(sleep: sleep)
            }
            if isVisible("activity"), let steps = data.metric(MetricID.steps) {
                MetricModuleCard(metric: steps, secondary: data.metric(MetricID.activeEnergy))
            }
            if isVisible("heart"), let rhr = data.metric(MetricID.restingHeartRate) {
                MetricModuleCard(metric: rhr, secondary: data.metric(MetricID.hrv))
            }
            if isVisible("meds"), env.profile.sensitiveModulesEnabled, data.medsActive > 0 {
                MedsModuleCard(data: data)
            }
            if let insight = data.topInsight {
                InsightCard(insight: insight)
            }
        }
    }

    private func isVisible(_ id: String) -> Bool {
        env.profile.module(id)?.visible ?? true
    }
}

// MARK: - Power body

private struct HomePowerBody: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    private let columns = [
        GridItem(.flexible(), spacing: BadanSpace.space3),
        GridItem(.flexible(), spacing: BadanSpace.space3),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            ReadinessHeroCard(data: data)

            if !data.metrics.isEmpty {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(LocalizedString(en: "Snapshot", ar: "لمحة"))) {
                        NavigationLink { BodyScreen() } label: {
                            Text(env.s(Loc.seeAll)).font(BadanFont.chip)
                        }
                        .foregroundStyle(BadanColor.primary)
                    }
                    LazyVGrid(columns: columns, spacing: BadanSpace.space3) {
                        ForEach(data.metrics) { metric in
                            MetricGridCell(metric: metric)
                        }
                    }
                }
            }

            if let sleep = data.sleep {
                SleepModuleCard(sleep: sleep)
            }
            if env.profile.sensitiveModulesEnabled, data.medsActive > 0 {
                MedsModuleCard(data: data)
            }
            if let insight = data.topInsight {
                InsightCard(insight: insight)
            }
            if !data.recentEvents.isEmpty {
                TimelinePreviewCard(events: data.recentEvents)
            }
        }
    }
}

// MARK: - Readiness hero

private struct ReadinessHeroCard: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                if let readiness = data.readiness {
                    StatBox(
                        value: env.format.integer(Int(readiness.value.rounded())),
                        label: env.s(Loc.readiness),
                        unit: "/ \(env.format.integer(100))"
                    )
                    HStack(spacing: BadanSpace.space2) {
                        if readiness.provisional {
                            ProvisionalBadge(language: env.language)
                        }
                        if env.depth.showsPowerDetail {
                            PillLabel(
                                "\(readiness.algorithmId) · \(readiness.algorithmVersion)",
                                systemImage: "function"
                            )
                        }
                    }
                    if env.depth.showsPowerDetail {
                        Text(data.narrative, language: env.language)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(Loc.readiness, language: env.language)
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(Loc.stillLearning, language: env.language)
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }
}

// MARK: - Sleep module

private struct SleepModuleCard: View {
    @Environment(AppEnvironment.self) private var env
    let sleep: HomeSleepSummary

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: MetricID.timeAsleep) } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: MetricFamily.sleep.symbolName)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(Loc.lastNight, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    StatBox(
                        value: env.format.duration(seconds: sleep.seconds),
                        label: env.s(MetricFamily.sleep.displayName),
                        chip: sleep.position.map { p in
                            StatusChip(position: p, label: env.s(rangeLabel(p)), language: env.language)
                        }
                    )
                    if env.depth.showsPowerDetail, sleep.spark.count >= 2 {
                        MetricSparkline(values: sleep.spark)
                            .frame(height: 36)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Generic metric module (casual)

private struct MetricModuleCard: View {
    @Environment(AppEnvironment.self) private var env
    let metric: HomeKeyMetric
    var secondary: HomeKeyMetric?

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: metric.metricId) } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: metric.familySymbol)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(metric.label)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    HStack(alignment: .top, spacing: BadanSpace.space4) {
                        StatBox(
                            value: metric.heroValue,
                            label: metric.label,
                            unit: metric.unit,
                            chip: metric.position.map { p in
                                StatusChip(position: p, label: env.s(rangeLabel(p)), language: env.language)
                            }
                        )
                        Spacer(minLength: 0)
                        if let secondary {
                            VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                                Text(secondary.heroValue)
                                    .font(BadanFont.numeralM)
                                    .foregroundStyle(BadanColor.textPrimary)
                                Text(secondary.label)
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Metric grid cell (power)

private struct MetricGridCell: View {
    @Environment(AppEnvironment.self) private var env
    let metric: HomeKeyMetric

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: metric.metricId) } label: {
            BadanCard(padding: BadanSpace.space3) {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    Text(metric.label)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                        Text(metric.heroValue)
                            .font(BadanFont.numeralM)
                            .foregroundStyle(BadanColor.textPrimary)
                        if let unit = metric.unit {
                            Text(unit)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                    if let position = metric.position {
                        StatusChip(position: position, label: env.s(rangeLabel(position)), language: env.language)
                    }
                    if let delta = metric.deltaText {
                        Text(delta)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    if metric.spark.count >= 2 {
                        MetricSparkline(values: metric.spark)
                            .frame(height: 28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meds module

private struct MedsModuleCard: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    var body: some View {
        NavigationLink { MedicationLogView() } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: MetricFamily.medications.symbolName)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(MetricFamily.medications.displayName, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    if data.medsDue > 0 {
                        StatBox(
                            value: env.format.integer(data.medsDue),
                            label: env.s(Loc.medsDue),
                            chip: StatusChip(.info, label: env.s(Loc.stillDue), language: env.language)
                        )
                    } else {
                        HStack(spacing: BadanSpace.space2) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(BadanColor.inBand)
                                .accessibilityHidden(true)
                            Text(Loc.allDone, language: env.language)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                        }
                        .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Insight card

private struct InsightCard: View {
    @Environment(AppEnvironment.self) private var env
    let insight: Insight

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(Loc.tabInsights, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                Text(insight.renderedText, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink { InsightsScreen() } label: {
                    HStack(spacing: BadanSpace.space1) {
                        Text(Loc.why, language: env.language)
                        Image(systemName: "chevron.forward").imageScale(.small)
                    }
                    .font(BadanFont.chip.weight(.medium))
                    .foregroundStyle(BadanColor.primary)
                    .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Timeline preview (power)

private struct TimelinePreviewCard: View {
    @Environment(AppEnvironment.self) private var env
    let events: [HomeEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.timeline)) {
                NavigationLink { TimelineScreen() } label: {
                    Text(env.s(Loc.seeAll)).font(BadanFont.chip)
                }
                .foregroundStyle(BadanColor.primary)
            }
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: BadanSpace.space3) {
                            Image(systemName: event.type.symbolName)
                                .foregroundStyle(BadanColor.textSecondary)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.type.displayName, language: env.language)
                                    .font(BadanFont.bodyCompact)
                                    .foregroundStyle(BadanColor.textPrimary)
                                if let detail = event.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: BadanSpace.space2)
                            Text(timeText(event.occurredAt))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        if index < events.count - 1 {
                            Rectangle()
                                .fill(BadanColor.separator)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: env.language.localeIdentifier)
        f.setLocalizedDateFormatFromTemplate("EEE jm")
        return f.string(from: date)
    }
}

// MARK: - Shared label helper

private func rangeLabel(_ position: Baseline.Position) -> LocalizedString {
    switch position {
    case .within: return Loc.inYourRange
    case .above: return Loc.aboveYourRange
    case .below: return Loc.belowYourRange
    }
}

// MARK: - Data model

struct HomeKeyMetric: Identifiable {
    var metricId: String
    var label: String
    var heroValue: String
    var unit: String?
    var position: Baseline.Position?
    var deltaText: String?
    var spark: [Double]
    var familySymbol: String

    var id: String { metricId }
}

struct HomeSleepSummary {
    var seconds: Double
    var position: Baseline.Position?
    var spark: [Double]
}

struct HomeEvent: Identifiable {
    var id: String
    var type: TimelineEventType
    var occurredAt: Date
    var detail: String?
}

struct HomeData {
    var date: Date
    var readiness: DerivedValue?
    var narrative: LocalizedString
    var sleep: HomeSleepSummary?
    var metrics: [HomeKeyMetric]
    var medsDue: Int
    var medsActive: Int
    var topInsight: Insight?
    var recentEvents: [HomeEvent]

    func metric(_ id: String) -> HomeKeyMetric? { metrics.first { $0.metricId == id } }
}

// MARK: - View model

@Observable
@MainActor
final class HomeViewModel {
    var state: LoadState<HomeData> = .loading

    func load(_ env: AppEnvironment) {
        let tz = TimeZone.current.identifier
        let now = env.now()
        do {
            let readiness = try latestReadiness(env, now: now, tz: tz)
            let sleep = try loadSleep(env, now: now, tz: tz)
            let metrics = try loadMetrics(env, now: now)
            let (medsDue, medsActive) = try loadMeds(env, now: now, tz: tz)
            let insight = try env.insightsRepo.recent(limit: 1).first
            let events = env.depth.showsPowerDetail ? loadEvents(env, now: now) : []

            let hasAny = readiness != nil || sleep != nil || !metrics.isEmpty
                || medsActive > 0 || insight != nil
            guard hasAny else { state = .empty(env.s(Loc.nothingYet)); return }

            let data = HomeData(
                date: now,
                readiness: readiness,
                narrative: narrative(for: readiness, sleep: sleep),
                sleep: sleep,
                metrics: metrics,
                medsDue: medsDue,
                medsActive: medsActive,
                topInsight: insight,
                recentEvents: events
            )
            state = .loaded(data)
        } catch {
            state = .error(String(describing: error))
        }
    }

    // MARK: Readiness

    private func latestReadiness(_ env: AppEnvironment, now: Date, tz: String) throws -> DerivedValue? {
        for offset in 0..<4 {
            let day = now.addingTimeInterval(Double(-offset) * 86_400)
            let key = DayAttribution.dayPeriodKey(day, tz: tz)
            if let value = try env.derivation.latestDerived(metricId: "readiness.score", periodKey: key) {
                return value
            }
        }
        return nil
    }

    // MARK: Sleep

    private func loadSleep(_ env: AppEnvironment, now: Date, tz: String) throws -> HomeSleepSummary? {
        let localNight = DayAttribution.localNight(sessionEnd: now, tz: tz)
        var seconds: Double?
        if let session = try env.measurements.primarySleep(localNight: localNight) {
            seconds = session.detail.timeAsleepSeconds ?? session.durationSeconds
        } else if let interval = try env.measurements.latestInterval(metricId: MetricID.timeAsleep) {
            seconds = interval.value
        }
        guard let seconds else { return nil }

        let baseline = try env.derivation.latestBaseline(metricId: MetricID.timeAsleep)
        let position = baseline?.position(of: seconds)

        let from = now.addingTimeInterval(-14 * 86_400)
        let nights = try env.measurements.sessions(kind: .sleepPrimary, from: from, to: now)
        let spark = nights
            .sorted { $0.startAt < $1.startAt }
            .map { $0.detail.timeAsleepSeconds ?? $0.durationSeconds }

        return HomeSleepSummary(seconds: seconds, position: position, spark: spark)
    }

    // MARK: Key metrics

    private func loadMetrics(_ env: AppEnvironment, now: Date) throws -> [HomeKeyMetric] {
        let ids = [MetricID.restingHeartRate, MetricID.hrv, MetricID.steps, MetricID.activeEnergy]
        let from = now.addingTimeInterval(-14 * 86_400)
        var result: [HomeKeyMetric] = []
        for id in ids {
            guard let latest = try env.measurements.latestInterval(metricId: id) else { continue }
            let def = env.registry.definitionOrFallback(id)
            let baseline = try env.derivation.latestBaseline(metricId: id)
            let position = baseline?.position(of: latest.value)
            let spark = try env.measurements.intervalRecords(metricId: id, from: from, to: now).map(\.value)
            let delta: String? = (env.depth.showsPowerDetail ? baseline : nil).map {
                signedDelta(env, metricId: id, value: latest.value, center: $0.center)
            }
            result.append(HomeKeyMetric(
                metricId: id,
                label: def.label(depth: env.depth, language: env.language),
                heroValue: env.format.heroValue(metricId: id, canonicalValue: latest.value),
                unit: env.format.unitLabel(metricId: id),
                position: position,
                deltaText: delta,
                spark: spark,
                familySymbol: def.familyGroup.symbolName
            ))
        }
        return result
    }

    private func signedDelta(_ env: AppEnvironment, metricId: String, value: Double, center: Double) -> String {
        let delta = value - center
        let sign = delta >= 0 ? "+" : "\u{2212}"
        let magnitude = env.format.heroValue(metricId: metricId, canonicalValue: abs(delta))
        let vs = LocalizedString(en: "vs your median", ar: "مقارنة بمتوسطك")
        if let unit = env.format.unitLabel(metricId: metricId) {
            return "\(sign)\(magnitude) \(unit) \u{00B7} \(env.s(vs))"
        }
        return "\(sign)\(magnitude) \u{00B7} \(env.s(vs))"
    }

    // MARK: Meds

    private func loadMeds(_ env: AppEnvironment, now: Date, tz: String) throws -> (due: Int, active: Int) {
        let active = try env.logging.regimens(activeOnly: true)
        let weekday = mondayBasedWeekday(now, tz: tz)
        let scheduledToday = active.reduce(0) { $0 + $1.schedule.dueTimes(onWeekday: weekday).count }

        let dayStart = DayAttribution.startOfDay(now, tz: tz)
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
        let handled = try env.logging.adherence(from: dayStart, to: dayEnd).count

        let due = max(0, scheduledToday - handled)
        return (due, active.count)
    }

    private func mondayBasedWeekday(_ date: Date, tz: String) -> Int {
        let cal = DayAttribution.calendar(tz: tz)
        let sundayBased = cal.component(.weekday, from: date) // 1 = Sunday ... 7 = Saturday
        return ((sundayBased + 5) % 7) + 1                    // 1 = Monday ... 7 = Sunday
    }

    // MARK: Recent events (power timeline preview)

    private func loadEvents(_ env: AppEnvironment, now: Date) -> [HomeEvent] {
        let from = now.addingTimeInterval(-7 * 86_400)
        var events: [HomeEvent] = []

        if let workouts = try? env.logging.workouts(from: from, to: now) {
            for w in workouts {
                events.append(HomeEvent(id: "w:\(w.id)", type: .workout, occurredAt: w.startAt, detail: w.activityType))
            }
        }
        if let notes = try? env.logging.notes(from: from, to: now) {
            for n in notes {
                events.append(HomeEvent(id: "n:\(n.id)", type: .note, occurredAt: n.occurredAt, detail: n.text))
            }
        }
        if env.profile.nutritionEnabled, let meals = try? env.logging.nutrition(from: from, to: now) {
            for m in meals {
                events.append(HomeEvent(id: "m:\(m.id)", type: .meal, occurredAt: m.occurredAt, detail: m.description))
            }
        }
        if env.profile.sensitiveModulesEnabled {
            if let symptoms = try? env.logging.symptoms(from: from, to: now) {
                for s in symptoms {
                    events.append(HomeEvent(id: "s:\(s.id)", type: .symptom, occurredAt: s.occurredAt, detail: nil))
                }
            }
            if let doses = try? env.logging.adherence(from: from, to: now) {
                for d in doses {
                    events.append(HomeEvent(id: "a:\(d.id)", type: .medication, occurredAt: d.occurredAt, detail: nil))
                }
            }
        }

        return Array(events.sorted { $0.occurredAt > $1.occurredAt }.prefix(4))
    }

    // MARK: Narrative

    private func narrative(for readiness: DerivedValue?, sleep: HomeSleepSummary?) -> LocalizedString {
        guard let readiness else {
            return LocalizedString(en: "Here's your day at a glance.", ar: "إليك يومك بلمحة.")
        }
        switch readiness.value {
        case 66...:
            return LocalizedString(en: "You're rested and steady today.", ar: "أنت مرتاح ومستقر اليوم.")
        case 45..<66:
            return LocalizedString(en: "You're in a balanced place today.", ar: "أنت في حالة متوازنة اليوم.")
        default:
            return LocalizedString(en: "A gentler pace may suit you today.", ar: "قد تناسبك وتيرة ألطف اليوم.")
        }
    }
}
