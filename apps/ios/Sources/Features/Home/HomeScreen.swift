import SwiftUI

// MARK: - Local strings

/// Strings that only Home needs, kept local rather than in the shared `Loc` catalog (matching
/// `ProvisionalBadge`'s existing self-contained pattern).
private enum HomeStrings {
    static let connectSource = LocalizedString(en: "Connect a source", ar: "إضافة مصدر بيانات")
    static let stillComingIn = LocalizedString(
        en: "Your data is still coming in — check back soon.",
        ar: "بياناتك لا تزال قيد الوصول — تحقق مرة أخرى قريباً.")
    static let genericLoadError = LocalizedString(
        en: "Couldn't load this right now — try again.",
        ar: "تعذّر التحميل الآن — حاول مرة أخرى.")
    static let daysProgress = LocalizedString(en: "{n} of {total} days", ar: "{n} من {total} أيام")
    static let calibrationProgress = LocalizedString(
        en: "{n} of {total} metrics calibrated", ar: "{n} من {total} مؤشرات معايرة")
    static let asOf = LocalizedString(en: "As of {date}", ar: "اعتباراً من {date}")
    static let andMore = LocalizedString(en: "+ {n} more", ar: "+ {n} أخرى")
    static let someActivityMayBeMissing = LocalizedString(
        en: "Some recent activity may not be shown.", ar: "قد لا تظهر بعض الأنشطة الأخيرة.")
}

/// A small per-language `DateFormatter` cache local to this screen, so repeated renders (header
/// date, timeline preview rows) don't each pay Foundation's formatter-init cost. `static let`s
/// only — no shared mutable cache — so this stays concurrency-safe without any actor ceremony.
private enum HomeDateFormatting {
    static func longDate(_ language: AppLanguage) -> DateFormatter {
        language == .ar ? longDateAR : longDateEN
    }

    static func eventTime(_ language: AppLanguage) -> DateFormatter {
        language == .ar ? eventTimeAR : eventTimeEN
    }

    private static let longDateEN = makeLongDate(.en)
    private static let longDateAR = makeLongDate(.ar)
    private static let eventTimeEN = makeEventTime(.en)
    private static let eventTimeAR = makeEventTime(.ar)

    private static func makeLongDate(_ language: AppLanguage) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language.localeIdentifier)
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }

    private static func makeEventTime(_ language: AppLanguage) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language.localeIdentifier)
        f.setLocalizedDateFormatFromTemplate("EEE jm")
        return f
    }
}

// MARK: - Screen

/// The flagship "Today" tab. Answers, at two altitudes over one model: how am I doing, why,
/// and what changed? Casual shows a calm readiness hero + a short narrative + a few tappable
/// modules; power keeps the same data but denser — deviation numbers, inline sparklines and a
/// timeline preview. Never moralizes state (no good/bad colour); out-of-band is one amber chip.
struct HomeScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = HomeViewModel()

    var body: some View {
        Group {
            switch vm.state {
            case .empty(let message):
                HomeEmptyStateView(message: message, showsConnectAction: !vm.emptyHasConnectedSource)
            case .loading:
                HomeSkeletonView()
            default:
                StatefulContainer(vm.state) { data in
                    ScrollView {
                        VStack(alignment: .leading, spacing: BadanSpace.space4) {
                            HomeHeader(data: data)
                            Group {
                                if env.depth.showsPowerDetail {
                                    HomePowerBody(data: data)
                                } else {
                                    HomeCasualBody(data: data)
                                }
                            }
                            .animation(.default, value: env.depth)
                        }
                        .padding(.horizontal, BadanSpace.space4)
                        .padding(.vertical, BadanSpace.space4)
                    }
                    .background(BadanColor.background)
                }
            }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.today))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: env.profile) { vm.load(env) }
    }
}

// MARK: - Empty / loading surfaces (Home-specific, bypassing StatefulContainer's generic ones)

/// Home's empty state differentiates *why* nothing is showing (no source connected vs. a
/// connected source with not-enough-history-yet) and, when a source genuinely isn't connected,
/// offers the one action most likely to fix it — instead of a dead-end "Nothing here yet".
private struct HomeEmptyStateView: View {
    @Environment(AppEnvironment.self) private var env
    var message: String
    var showsConnectAction: Bool

    var body: some View {
        VStack(spacing: BadanSpace.space3) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(BadanFont.sectionTitle)
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.center)
            if showsConnectAction {
                NavigationLink { SourcesScreen() } label: {
                    Text(env.s(HomeStrings.connectSource))
                        .font(BadanFont.body.weight(.medium))
                        .frame(minHeight: BadanSpace.touchMin)
                        .padding(.horizontal, BadanSpace.space5)
                }
                .foregroundStyle(BadanColor.primary)
                .background(
                    BadanColor.primary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BadanSpace.space7)
        .padding(.horizontal, BadanSpace.space5)
    }
}

/// A lightweight, shape-matched placeholder for Home's first paint — kept intentionally simple
/// since `HomeViewModel.load` runs synchronously and this may only be visible for a moment.
private struct HomeSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                ForEach(0..<3, id: \.self) { _ in
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space2) {
                            RoundedRectangle(cornerRadius: BadanRadius.chip)
                                .fill(BadanColor.textSecondary.opacity(0.15))
                                .frame(width: 96, height: 14)
                            RoundedRectangle(cornerRadius: BadanRadius.chip)
                                .fill(BadanColor.textSecondary.opacity(0.15))
                                .frame(width: 140, height: 36)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, BadanSpace.space4)
            .padding(.vertical, BadanSpace.space4)
        }
        .background(BadanColor.background)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(dateText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: BadanSpace.space2)
            DepthBadge(env.depth, language: env.language)
        }
    }

    private var dateText: String {
        HomeDateFormatting.longDate(env.language).string(from: data.date)
    }
}

// MARK: - Casual body

private struct HomeCasualBody: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            // The narrative now lives inside the hero card itself (matching power mode) so the
            // "why" sentence reads as an explanation of the score above it, not a separate,
            // unlabeled aside.
            ReadinessHeroCard(data: data)

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

    private static let snapshotHeader = LocalizedString(en: "Key metrics", ar: "المؤشرات الرئيسية")

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            ReadinessHeroCard(data: data)

            if !data.metrics.isEmpty {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(Self.snapshotHeader)) {
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
                TimelinePreviewCard(events: data.recentEvents, partial: data.recentEventsPartial)
            }
        }
    }
}

// MARK: - Readiness hero

private struct ReadinessHeroCard: View {
    @Environment(AppEnvironment.self) private var env
    let data: HomeData

    /// Human-readable names for the algorithm ids power users otherwise see verbatim
    /// (e.g. "composite.readiness_score"). The raw id/version stays available in the anatomy
    /// sheet where technical transparency is the explicit point; this is just the Home pill.
    private static let algorithmFriendlyNames: [String: LocalizedString] = [
        "baseline.rolling_median_mad": LocalizedString(en: "Personal range", ar: "النطاق الشخصي"),
        "composite.sleep_efficiency": LocalizedString(en: "Sleep efficiency formula", ar: "معادلة كفاءة النوم"),
        "composite.readiness_score": LocalizedString(en: "Readiness formula", ar: "معادلة الجاهزية"),
    ]

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: "readiness.score") } label: {
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
                                PillLabel(algorithmLabel(readiness), systemImage: "function")
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                        }
                        if data.readinessDayOffset > 0 {
                            Text(asOfText)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        // Shown at both altitudes now — power already explained the score this
                        // way; casual gets the same plain-language "why" instead of a separate,
                        // unlabeled narrative card.
                        Text(data.narrative, language: env.language)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Loc.readiness, language: env.language)
                            .font(BadanFont.sectionTitle)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(stillLearningText)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    if data.trackedCount > 0, data.calibratedCount < data.trackedCount {
                        Text(calibrationText)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func algorithmLabel(_ readiness: DerivedValue) -> String {
        if let friendly = Self.algorithmFriendlyNames[readiness.algorithmId] {
            return "\(friendly.resolved(env.language)) · \(readiness.algorithmVersion)"
        }
        return "\(readiness.algorithmId) · \(readiness.algorithmVersion)"
    }

    private var asOfText: String {
        let dateText = HomeDateFormatting.longDate(env.language).string(from: data.date)
        return HomeStrings.asOf.filling(["date": dateText]).resolved(env.language)
    }

    private var stillLearningText: String {
        let base = Loc.stillLearning.resolved(env.language)
        guard let progress = data.readinessProgressDays else { return base }
        let suffix = HomeStrings.daysProgress.filling([
            "n": env.format.integer(progress),
            "total": env.format.integer(BaselineEngine.minPointsForConfident),
        ]).resolved(env.language)
        return "\(base) (\(suffix))"
    }

    private var calibrationText: String {
        HomeStrings.calibrationProgress.filling([
            "n": env.format.integer(data.calibratedCount),
            "total": env.format.integer(data.trackedCount),
        ]).resolved(env.language)
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
                            .accessibilityHidden(true)
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
                            // Demoted below the primary StatBox's hero numeral so the eye lands
                            // on the headline metric first (UIUX-011): a supplementary number
                            // reads as supplementary, not co-equal.
                            VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                                Text(secondary.heroValue)
                                    .font(BadanFont.body)
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
                    HStack(spacing: BadanSpace.space1) {
                        Text(metric.label)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                        Spacer(minLength: BadanSpace.space1)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
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
                            .accessibilityHidden(true)
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
                            label: medsSubtitle,
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

    /// "Magnesium + 1 more" when a due medication's name is known, falling back to the plain
    /// "Due" label so a user doesn't have to tap through just to see what's outstanding.
    private var medsSubtitle: String {
        guard let name = data.firstDueMedName else { return env.s(Loc.medsDue) }
        guard data.medsDue > 1 else { return name }
        let more = HomeStrings.andMore.filling(["n": env.format.integer(data.medsDue - 1)]).resolved(env.language)
        return "\(name) \(more)"
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
    var partial: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.timeline)) {
                NavigationLink { TimelineScreen() } label: {
                    Text(env.s(Loc.seeAll)).font(BadanFont.chip)
                }
                .foregroundStyle(BadanColor.primary)
            }
            if partial {
                Text(env.s(HomeStrings.someActivityMayBeMissing))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: BadanSpace.space3) {
                            Image(systemName: event.type.symbolName)
                                .foregroundStyle(BadanColor.primary)
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
        HomeDateFormatting.eventTime(env.language).string(from: date)
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
    var provisional: Bool

    var id: String { metricId }
}

struct HomeSleepSummary {
    var seconds: Double
    var position: Baseline.Position?
    var spark: [Double]
    var provisional: Bool
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
    /// How many days old the shown readiness value is (0 = today). Only meaningful when
    /// `readiness` is non-nil.
    var readinessDayOffset: Int
    /// When `readiness == nil`: how many of the `BaselineEngine.minPointsForConfident` days
    /// needed are already banked (min across readiness's sleep/RHR inputs), so "Still learning"
    /// reads as a countdown instead of an open-ended wait.
    var readinessProgressDays: Int?
    var narrative: LocalizedString
    var sleep: HomeSleepSummary?
    var metrics: [HomeKeyMetric]
    var medsDue: Int
    var medsActive: Int
    var firstDueMedName: String?
    var topInsight: Insight?
    var recentEvents: [HomeEvent]
    var recentEventsPartial: Bool

    func metric(_ id: String) -> HomeKeyMetric? { metrics.first { $0.metricId == id } }

    /// How many of the metrics actually shown on Home today have a non-provisional (settled)
    /// personal baseline — the aggregate "calibration" signal for FEAT-256.
    var calibratedCount: Int {
        (sleep.map { $0.provisional ? 0 : 1 } ?? 0) + metrics.filter { !$0.provisional }.count
    }

    var trackedCount: Int {
        (sleep != nil ? 1 : 0) + metrics.count
    }
}

// MARK: - View model

@Observable
@MainActor
final class HomeViewModel {
    var state: LoadState<HomeData> = .loading
    /// Set alongside `.empty` state so the view knows whether "Connect a source" is the right
    /// action to offer (vs. a source already being connected but data still thin).
    var emptyHasConnectedSource = false

    /// Guards against a redundant full reload (see PERF-017/018/021's N+1 cost) when Home
    /// reappears with nothing changed. Any actual profile change (language/units/depth) still
    /// reloads immediately since `.task(id: env.profile)` re-invokes `load` with a new task.
    private var lastLoadedAt: Date?
    private var lastLoadedProfile: CustomizationProfile?
    private static let staleThreshold: TimeInterval = 5

    func load(_ env: AppEnvironment) {
        if case .loaded = state,
           let lastLoadedAt, let lastLoadedProfile, lastLoadedProfile == env.profile,
           env.now().timeIntervalSince(lastLoadedAt) < Self.staleThreshold {
            return
        }

        let signpostState = PerformanceLog.signposter.beginInterval("HomeViewModel.load")
        defer { PerformanceLog.signposter.endInterval("HomeViewModel.load", signpostState) }

        let tz = TimeZone.current.identifier
        let now = env.now()
        do {
            let (readiness, dayOffset) = try latestReadiness(env, now: now, tz: tz)
            let readinessProgress = readiness == nil ? readinessProgressDays(env) : nil
            let sleep = try loadSleep(env, now: now, tz: tz)
            let metrics = try loadMetrics(env, now: now)
            let meds = try loadMeds(env, now: now, tz: tz)
            let insight = try env.insightsRepo.recent(limit: 1).first
            let (events, eventsPartial) = env.depth.showsPowerDetail ? loadEvents(env, now: now) : ([], false)

            let hasAny = readiness != nil || sleep != nil || !metrics.isEmpty
                || meds.active > 0 || insight != nil || !events.isEmpty
            guard hasAny else {
                let hasConnectedSource = (try? env.catalog.sources())?.contains { $0.status == .active } ?? false
                emptyHasConnectedSource = hasConnectedSource
                state = .empty(hasConnectedSource ? env.s(HomeStrings.stillComingIn) : env.s(Loc.nothingYet))
                return
            }

            let data = HomeData(
                date: now,
                readiness: readiness,
                readinessDayOffset: dayOffset,
                readinessProgressDays: readinessProgress,
                narrative: narrative(for: readiness, sleep: sleep),
                sleep: sleep,
                metrics: metrics,
                medsDue: meds.due,
                medsActive: meds.active,
                firstDueMedName: meds.firstDueName,
                topInsight: insight,
                recentEvents: events,
                recentEventsPartial: eventsPartial
            )
            lastLoadedAt = now
            lastLoadedProfile = env.profile
            state = .loaded(data)
        } catch {
            #if DEBUG
            print("HomeViewModel.load failed: \(error)")
            #endif
            state = .error(env.s(HomeStrings.genericLoadError))
        }
    }

    // MARK: Readiness

    private func latestReadiness(_ env: AppEnvironment, now: Date, tz: String) throws -> (value: DerivedValue?, dayOffset: Int) {
        for offset in 0..<4 {
            let day = now.addingTimeInterval(Double(-offset) * 86_400)
            let key = DayAttribution.dayPeriodKey(day, tz: tz)
            if let value = try env.derivation.latestDerived(metricId: "readiness.score", periodKey: key) {
                return (value, offset)
            }
        }
        return (nil, 0)
    }

    /// How many of the `minPointsForConfident` days readiness's own inputs (sleep, RHR
    /// baselines) already have banked, so the "still learning" fallback can read as a countdown
    /// rather than an open-ended wait (EASE-139). Best-effort: a fetch failure here just means
    /// no progress hint is shown, never a broken Home load.
    private func readinessProgressDays(_ env: AppEnvironment) -> Int? {
        let sleepPoints = (try? env.derivation.latestBaseline(metricId: MetricID.timeAsleep))?.nPoints ?? 0
        let rhrPoints = (try? env.derivation.latestBaseline(metricId: MetricID.restingHeartRate))?.nPoints ?? 0
        return min(min(sleepPoints, rhrPoints), BaselineEngine.minPointsForConfident)
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
        // Sparkline history is decorative, not primary content — a failure here should cost the
        // sparkline, not the whole Home screen (OPT-011).
        let nights = (try? env.measurements.sessions(kind: .sleepPrimary, from: from, to: now)) ?? []
        let spark = nights
            .sorted { $0.startAt < $1.startAt }
            .map { $0.detail.timeAsleepSeconds ?? $0.durationSeconds }

        return HomeSleepSummary(seconds: seconds, position: position, spark: spark, provisional: baseline?.provisional ?? true)
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
            // Sparkline history is decorative — isolate its failure from the primary
            // latest-value/baseline fetches above (OPT-011).
            let spark = (try? env.measurements.intervalRecords(metricId: id, from: from, to: now))?.map(\.value) ?? []
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
                familySymbol: def.familyGroup.symbolName,
                provisional: baseline?.provisional ?? true
            ))
        }
        return result
    }

    private func signedDelta(_ env: AppEnvironment, metricId: String, value: Double, center: Double) -> String {
        let delta = value - center
        let sign = delta >= 0 ? "+" : "\u{2212}"
        let magnitude = env.format.heroValue(metricId: metricId, canonicalValue: abs(delta))
        // Matches Insights' "vs your usual" wording (InsightsLoc.vsUsual) so the same comparison
        // doesn't read as two different concepts across adjacent tabs (EASE-149).
        let vs = LocalizedString(en: "vs your usual", ar: "مقارنةً بالمعتاد")
        if let unit = env.format.unitLabel(metricId: metricId) {
            return "\(sign)\(magnitude) \(unit) \u{00B7} \(env.s(vs))"
        }
        return "\(sign)\(magnitude) \u{00B7} \(env.s(vs))"
    }

    // MARK: Meds

    private func loadMeds(_ env: AppEnvironment, now: Date, tz: String) throws -> (due: Int, active: Int, firstDueName: String?) {
        let active = try env.logging.regimens(activeOnly: true)
        let weekday = mondayBasedWeekday(now, tz: tz)

        let dayStart = DayAttribution.startOfDay(now, tz: tz)
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
        let handledByRegimen = Dictionary(
            grouping: try env.logging.adherence(from: dayStart, to: dayEnd), by: \.regimenId
        ).mapValues(\.count)

        var due = 0
        var firstDueName: String?
        for regimen in active.sorted(by: { $0.name < $1.name }) {
            let scheduled = regimen.schedule.dueTimes(onWeekday: weekday).count
            guard scheduled > 0 else { continue }
            let handled = handledByRegimen[regimen.id] ?? 0
            let regimenDue = max(0, scheduled - handled)
            due += regimenDue
            if regimenDue > 0, firstDueName == nil {
                firstDueName = regimen.name
            }
        }
        return (due, active.count, firstDueName)
    }

    private func mondayBasedWeekday(_ date: Date, tz: String) -> Int {
        let cal = DayAttribution.calendar(tz: tz)
        let sundayBased = cal.component(.weekday, from: date) // 1 = Sunday ... 7 = Saturday
        return ((sundayBased + 5) % 7) + 1                    // 1 = Monday ... 7 = Sunday
    }

    // MARK: Recent events (power timeline preview)

    private func loadEvents(_ env: AppEnvironment, now: Date) -> (events: [HomeEvent], partial: Bool) {
        // Reuses Timeline's own "recent" window so the two screens' notion of "recent" can't
        // silently diverge (OPT-008).
        let from = now.addingTimeInterval(-Double(TimelineAssembler.windowDays) * 86_400)
        var byType: [TimelineEventType: [HomeEvent]] = [:]
        var partial = false

        if let workouts = try? env.logging.workouts(from: from, to: now) {
            byType[.workout] = workouts.map {
                HomeEvent(id: "w:\($0.id)", type: .workout, occurredAt: $0.startAt, detail: $0.activityType)
            }
        } else { partial = true }

        if let notes = try? env.logging.notes(from: from, to: now) {
            byType[.note] = notes.map {
                HomeEvent(id: "n:\($0.id)", type: .note, occurredAt: $0.occurredAt, detail: $0.text)
            }
        } else { partial = true }

        if env.profile.nutritionEnabled {
            if let meals = try? env.logging.nutrition(from: from, to: now) {
                byType[.meal] = meals.map {
                    HomeEvent(id: "m:\($0.id)", type: .meal, occurredAt: $0.occurredAt, detail: $0.description)
                }
            } else { partial = true }
        }

        if env.profile.sensitiveModulesEnabled {
            if let symptoms = try? env.logging.symptoms(from: from, to: now) {
                byType[.symptom] = symptoms.map {
                    HomeEvent(id: "s:\($0.id)", type: .symptom, occurredAt: $0.occurredAt, detail: nil)
                }
            } else { partial = true }
            if let doses = try? env.logging.adherence(from: from, to: now) {
                byType[.medication] = doses.map {
                    HomeEvent(id: "a:\($0.id)", type: .medication, occurredAt: $0.occurredAt, detail: nil)
                }
            } else { partial = true }
        }

        // Round-robin across present types (each already newest-first) instead of one global
        // sort+prefix(4), so a burst of one type (e.g. 4 recent notes) can't silently crowd out
        // every other category from the same window (OPT-007). Final list is re-sorted
        // newest-first for display.
        let typeOrder: [TimelineEventType] = [.workout, .note, .meal, .symptom, .medication]
        var queues = typeOrder.compactMap { type -> [HomeEvent]? in
            guard let items = byType[type], !items.isEmpty else { return nil }
            return items.sorted { $0.occurredAt > $1.occurredAt }
        }
        var result: [HomeEvent] = []
        outer: while result.count < 4 {
            var progressed = false
            for i in queues.indices {
                guard !queues[i].isEmpty else { continue }
                result.append(queues[i].removeFirst())
                progressed = true
                if result.count == 4 { break outer }
            }
            if !progressed { break }
        }
        result.sort { $0.occurredAt > $1.occurredAt }

        return (result, partial)
    }

    // MARK: Narrative

    /// Readiness cut points, named so they can't silently drift from the scoring algorithm
    /// without someone noticing this comment (OPT-004). Tied to `composite.readiness_score`
    /// (`BaselineEngine.readinessAlgorithm`) — a change to that algorithm's scale should revisit
    /// these.
    private enum ReadinessBands {
        static let steady = 66.0
        static let balanced = 45.0
    }

    private func narrative(for readiness: DerivedValue?, sleep: HomeSleepSummary?) -> LocalizedString {
        guard let readiness else {
            return LocalizedString(en: "Here's your day at a glance.", ar: "إليك يومك بلمحة.")
        }
        // Readiness isn't badly off but last night was short — call that out distinctly rather
        // than folding it into a generic "balanced" sentence (OPT-012: sleep now actually
        // informs the narrative it's passed).
        if readiness.value >= ReadinessBands.balanced, sleep?.position == .below {
            return LocalizedString(
                en: "You're managing on less sleep than usual today.",
                ar: "أنت تتدبر أمرك بنوم أقل من المعتاد اليوم.")
        }
        switch readiness.value {
        case ReadinessBands.steady...:
            return LocalizedString(en: "You're rested and steady today.", ar: "أنت مرتاح ومستقر اليوم.")
        case ReadinessBands.balanced..<ReadinessBands.steady:
            return LocalizedString(en: "You're in a balanced place today.", ar: "أنت في حالة متوازنة اليوم.")
        default:
            return LocalizedString(en: "A gentler pace may suit you today.", ar: "قد تناسبك وتيرة ألطف اليوم.")
        }
    }
}
