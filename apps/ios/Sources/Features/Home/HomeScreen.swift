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

    /// Relative freshness ("2h ago") for the power-depth key-metric grid (UX-04). Mirrors
    /// `SourcesDateText.relative` (`Features/Body/SourcesScreen.swift`) rather than adding a
    /// shared helper for a single-token change, matching this file's existing convention of
    /// keeping Home's own formatting self-contained.
    static func relative(_ date: Date, _ language: AppLanguage, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Arabic count-noun agreement (FIX-14): grammatical number depends on magnitude — 1 is
/// singular, 2 is dual, 3–10 is plural, 11+ reverts to the indeclinable singular count form.
/// Mirrors `TimelineAssembler.caloriesText`'s handling of the same rule. Home's two
/// "{n} of {total} ..." progress strings (`stillLearningText`/`calibrationText` below)
/// previously hardcoded the 3–10 plural regardless of the actual count; the noun's Arabic form
/// must agree with `total` (the denominator being described), not `n`. Not `private` so
/// `HomeChartFixTests` can exercise the 1/2/3–10/11+ boundaries directly.
enum HomeArabicCount {
    static func phrase(
        n: Int, total: Int, language: AppLanguage, format: ValueFormatter,
        enNoun: String, arSingular: String, arDual: String, arPlural: String, arMany: String
    ) -> String {
        let nText = format.integer(n)
        let totalText = format.integer(total)
        guard language == .ar else { return "\(nText) of \(totalText) \(enNoun)" }
        let noun: String
        switch total {
        case 1: noun = arSingular
        case 2: noun = arDual
        case 3...10: noun = arPlural
        default: noun = arMany
        }
        return "\(nText) من \(totalText) \(noun)"
    }
}

/// Staleness bounds for Home's "latest ever recorded" fallback queries (UX-01-Home). Absent a
/// same-window reading, `loadSleep`/`loadMetrics` fall back to the single most recent record
/// regardless of age — unbounded, that can silently show a reading that's weeks old as if it
/// were current. Beyond these windows the fallback is treated as no data instead. Not
/// `private` so `HomeChartFixTests` can exercise the boundary directly.
enum HomeStaleness {
    /// "Last night" sleep is meaningfully stale past about two nights.
    static let sleepFallbackMaxAge: TimeInterval = 48 * 3_600
    /// A daily-cadence metric (steps, RHR, HRV, active energy) is meaningfully stale past a week.
    static let keyMetricMaxAge: TimeInterval = 7 * 86_400

    static func isFresh(_ recordEnd: Date, now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(recordEnd) <= maxAge
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
                            // §16: Export Center is elevated to a first-class destination — reachable
                            // from Body, Settings, and here as a Home tool card.
                            HomeExportToolCard()
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
        .task(id: HomeLoadKey(profile: env.profile, generation: env.dataGeneration)) { await vm.load(env) }
    }
}

/// BUG-12/13: the standardized `.task(id:)` identity every screen this fix touches uses —
/// `profile` alone (the old key) misses every write that doesn't also change a settings field
/// (a HealthKit backfill, a foreground sync, a quick water/weight log). Folding `dataGeneration`
/// in means any bump forces a reload regardless of what else did or didn't change.
private struct HomeLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
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
            // (UX-06) The badge used to be display-only despite being styled like the app's
            // other interactive pills — switching altitude meant a 3-tap trip through Settings.
            // `DepthBadge` itself lives outside this fix's scope, so it's wrapped rather than
            // changed: its visual is untouched, this just adds the tap + accessibility.
            Button {
                toggleDepth()
            } label: {
                DepthBadge(env.depth, language: env.language)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(env.s(Loc.depthLevel)): \(env.depth.displayName.resolved(env.language))")
            .accessibilityHint(env.s(env.depth == .casual ? Loc.depthToggleHintToDetailed : Loc.depthToggleHintToSimple))
        }
    }

    private var dateText: String {
        HomeDateFormatting.longDate(env.language).string(from: data.date)
    }

    private func toggleDepth() {
        env.update { $0.depthPolicy = env.depth == .casual ? .power : .casual }
    }
}

// MARK: - Casual body

private struct HomeCasualBody: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    let data: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            // The narrative now lives inside the hero card itself (matching power mode) so the
            // "why" sentence reads as an explanation of the score above it, not a separate,
            // unlabeled aside.
            if isVisible("readiness") {
                ReadinessHeroCard(data: data)
            }

            // On iPad's regular width, the module cards below the hero pair up into a 2-column
            // tile grid instead of stacking full-width — the iPhone layout otherwise leaves half
            // the screen empty. `tileColumns` collapses back to a single column on iPhone
            // (compact width), so this renders identically to the old VStack there.
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: BadanSpace.space4) {
                if isVisible("effort"), let effort = data.effort {
                    EffortCard(effort: effort)
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
            }

            if let insight = data.topInsight {
                InsightCard(insight: insight)
            }
        }
    }

    private var tileColumns: [GridItem] {
        AdaptiveTiles.columns(for: sizeClass, spacing: BadanSpace.space3)
    }

    private func isVisible(_ id: String) -> Bool {
        isHomeModuleVisible(id, in: env.profile)
    }
}

// MARK: - Export tool card (§16 elevation)

/// The Home entry point to the elevated Export Center. A calm tool card at the foot of Today —
/// "your data is yours" made reachable without a trip through Body → Tools.
private struct HomeExportToolCard: View {
    @Environment(AppEnvironment.self) private var env

    private static let subtitle = LocalizedString(
        en: "Your records, offline — CSV or JSON, always free.",
        ar: "سجلاتك دون اتصال — CSV أو JSON، مجاناً دائماً.")

    var body: some View {
        NavigationLink { ExportCenterScreen() } label: {
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "square.and.arrow.up")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Loc.exportTitle, language: env.language)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(Self.subtitle, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: "chevron.forward")
                        .imageScale(.small)
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BadanSpace.touchMin)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Power body

private struct HomePowerBody: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    let data: HomeData

    private let metricColumns = [
        GridItem(.flexible(), spacing: BadanSpace.space3),
        GridItem(.flexible(), spacing: BadanSpace.space3),
    ]

    private static let snapshotHeader = LocalizedString(en: "Key metrics", ar: "المؤشرات الرئيسية")

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            if isVisible("readiness") {
                ReadinessHeroCard(data: data)
            }

            // On iPad's regular width, effort/sleep/meds pair up into a 2-column tile grid
            // instead of stacking full-width beside the already-2-column key-metrics section
            // below — `tileColumns` collapses to a single column on iPhone (compact width), so
            // this renders identically to the old VStack there.
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: BadanSpace.space5) {
                if isVisible("effort"), let effort = data.effort {
                    EffortCard(effort: effort)
                }
                if isVisible("sleep"), let sleep = data.sleep {
                    SleepModuleCard(sleep: sleep)
                }
                if isVisible("meds"), env.profile.sensitiveModulesEnabled, data.medsActive > 0 {
                    MedsModuleCard(data: data)
                }
            }

            // (FIX-04) Power previously showed the whole grid regardless of module visibility.
            // The grid mixes two module ids (steps/active-energy -> "activity",
            // RHR/HRV -> "heart"), so each cell is filtered by its own family's toggle rather
            // than gating the section as a single unit.
            if !visibleMetrics.isEmpty {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(Self.snapshotHeader)) {
                        NavigationLink { BodyScreen() } label: {
                            Text(env.s(Loc.seeAll)).font(BadanFont.chip)
                        }
                        .foregroundStyle(BadanColor.primary)
                    }
                    LazyVGrid(columns: metricColumns, spacing: BadanSpace.space3) {
                        ForEach(visibleMetrics) { metric in
                            MetricGridCell(metric: metric)
                        }
                    }
                }
            }

            if let insight = data.topInsight {
                InsightCard(insight: insight)
            }
            if isVisible("timeline"), !data.recentEvents.isEmpty {
                TimelinePreviewCard(events: data.recentEvents, partial: data.recentEventsPartial)
            }
        }
    }

    private var tileColumns: [GridItem] {
        AdaptiveTiles.columns(for: sizeClass, spacing: BadanSpace.space3)
    }

    private func isVisible(_ id: String) -> Bool {
        isHomeModuleVisible(id, in: env.profile)
    }

    private var visibleMetrics: [HomeKeyMetric] {
        data.metrics.filter { isVisible(homeModuleId(forMetric: $0.metricId)) }
    }
}

// MARK: - Shared card chrome

/// The small "icon · title · chevron" header the score cards share, so Readiness, Effort and Sleep
/// read as one family of tappable cards. Title is a caption (the card's subject), never the hero —
/// the sentence and value inside carry the weight (the score-fixation guard).
private struct CardLabelRow: View {
    @Environment(AppEnvironment.self) private var env
    let icon: String
    let title: LocalizedString

    var body: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: icon)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(title, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Image(systemName: "chevron.forward")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
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
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    CardLabelRow(icon: MetricFamily.readiness.symbolName, title: Loc.readiness)
                    if let readiness = data.readiness {
                        // SCORE-FIXATION GUARD (plan §16): the plain-language sentence LEADS — it is
                        // the prominent line — and the number FOLLOWS as a supporting figure, so the
                        // eye lands on "what this means for me today", not a big anxious numeral.
                        Text(data.narrative, language: env.language)
                            .font(BadanFont.sectionTitle)
                            .foregroundStyle(BadanColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                            Text(env.format.integer(Int(readiness.value.rounded())))
                                .font(BadanFont.numeralM)
                                .foregroundStyle(BadanColor.textPrimary)
                            Text("/ \(env.format.integer(100))")
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                            Spacer(minLength: BadanSpace.space2)
                            if readiness.provisional {
                                ProvisionalBadge(language: env.language)
                            }
                        }
                        // Freshness is ALWAYS visible (plan §16: "Freshness timestamp always visible"),
                        // not only when the value is a day or more old.
                        Text(asOfText)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        if env.depth.showsPowerDetail {
                            PillLabel(algorithmLabel(readiness), systemImage: "function")
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        // Cold-start honesty: while readiness is still provisional, the calibration
                        // countdown says how far along its bottleneck input is — "we don't guess
                        // before we know you" — rather than presenting a not-yet-settled score bare.
                        if readiness.provisional, let calibration = data.readinessCalibration {
                            CalibrationNote(calibration: calibration, language: env.language,
                                            format: env.format, showsDetail: env.depth.showsPowerDetail)
                        }
                        // EPIC-29: "computed while you were travelling". Renders nothing on an
                        // ordinary day. The score itself is unchanged — the engine capped this
                        // row's confidence and nothing else (see `ReadinessResult`).
                        ContextCaveatNote(caveats: data.readinessContextCaveats, language: env.language)
                    } else {
                        // Readiness has not cleared its cold start yet — show the countdown, never a
                        // fabricated number. What already works (sleep, vitals) is shown below.
                        Text(stillLearningText)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let calibration = data.readinessCalibration {
                            CalibrationNote(calibration: calibration, language: env.language,
                                            format: env.format, showsDetail: env.depth.showsPowerDetail)
                        }
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

    // (FIX-01) Was `data.date` — today's date, regardless of how stale the shown readiness
    // value actually is. `data.readinessDate` is the day the matched value was actually
    // computed for (carried out of `latestReadiness`), so this now names the right day.
    private var asOfText: String {
        let dateText = HomeDateFormatting.longDate(env.language).string(from: data.readinessDate)
        return HomeStrings.asOf.filling(["date": dateText]).resolved(env.language)
    }

    private var stillLearningText: String {
        let base = Loc.stillLearning.resolved(env.language)
        guard let progress = data.readinessProgressDays else { return base }
        // (FIX-14) Arabic noun agreement keyed off `total` (minPointsForConfident), not `n`.
        let suffix = HomeArabicCount.phrase(
            n: progress, total: BaselineEngine.minPointsForConfident,
            language: env.language, format: env.format,
            enNoun: "days", arSingular: "يوم", arDual: "يومان", arPlural: "أيام", arMany: "يوماً")
        return "\(base) (\(suffix))"
    }

    private var calibrationText: String {
        // (FIX-14) Arabic noun agreement keyed off `total` (trackedCount), not `n`.
        HomeArabicCount.phrase(
            n: data.calibratedCount, total: data.trackedCount,
            language: env.language, format: env.format,
            enNoun: "metrics calibrated", arSingular: "مؤشر معاير", arDual: "مؤشران معايران",
            arPlural: "مؤشرات معايرة", arMany: "مؤشراً معايراً")
    }
}

// MARK: - Effort card (EPIC-26)

private struct EffortCard: View {
    @Environment(AppEnvironment.self) private var env
    let effort: HomeEffortSummary

    private enum Copy {
        static let guidanceGentler = LocalizedString(
            en: "A gentler range may suit today.", ar: "قد تناسبك وتيرة ألطف اليوم.")
        static let guidanceTypical = LocalizedString(
            en: "Your usual range suits today.", ar: "نطاقك المعتاد يناسب اليوم.")
        static let guidanceHeadroom = LocalizedString(
            en: "There's room to push if you want it.", ar: "لديك متّسع للدفع إن أردت.")
        static let ceilingSuffix = LocalizedString(en: "around {value}", ar: "نحو {value}")
        static let effortSoFar = LocalizedString(en: "Your effort so far today.", ar: "جهدك حتى الآن اليوم.")
        static let activityToday = LocalizedString(en: "Activity from your movement today.", ar: "نشاط من حركتك اليوم.")
        // The reduced-input variant is labelled DISTINCTLY (plan §11 EPIC-26 / §18): a real movement
        // magnitude, never a zero-looking score, with a specific reason it isn't the zone-based score.
        static let activityLoadLabel = LocalizedString(en: "Activity load (estimated)", ar: "حمل النشاط (تقديري)")
        static let activityLoadWhy = LocalizedString(
            en: "From your movement — continuous heart rate is needed to see effort zones.",
            ar: "من حركتك — يلزم معدل ضربات قلب مستمر لرؤية نطاقات الجهد.")
        static let updated = LocalizedString(en: "Updated {time}", ar: "حُدّث {time}")
    }

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: MetricID.effortDay) } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    CardLabelRow(icon: MetricFamily.effort.symbolName, title: Loc.effort)
                    // SENTENCE LEADS (score-fixation guard) — the guidance direction, then the number.
                    Text(guidanceSentence, language: env.language)
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    valueBlock
                    Text(updatedText)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var valueBlock: some View {
        switch effort.kind {
        case .score(let score):
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                    Text(env.format.integer(Int(score.rounded())))
                        .font(BadanFont.numeralM)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text("/ \(env.format.integer(100))")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Spacer(minLength: BadanSpace.space2)
                    if effort.provisional {
                        ProvisionalBadge(language: env.language)
                    }
                }
                EffortProgressBar(fraction: min(1, max(0, score / 100)), ceilingFraction: ceilingFraction)
                    .frame(height: 8)
                    .accessibilityHidden(true)
            }
        case .activityLoad(let value, let unit):
            // Reduced-input: a real movement magnitude, DISTINCTLY labelled — never a fake 0–100 score.
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                    Text(HomeEffortActivity.valueText(value: value, unit: unit, format: env.format))
                        .font(BadanFont.numeralM)
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    PillLabel(env.s(Copy.activityLoadLabel), systemImage: "figure.walk",
                              tint: BadanColor.info, filled: false)
                }
                Text(Copy.activityLoadWhy, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The guidance sentence: the readiness-linked direction when available, else a neutral framing of
    /// what effort is showing. A gentler day with a personal ceiling appends the soft number.
    private var guidanceSentence: LocalizedString {
        guard let band = effort.guidanceBand else {
            if case .activityLoad = effort.kind { return Copy.activityToday }
            return Copy.effortSoFar
        }
        switch band {
        case .gentler:
            guard let ceiling = effort.guidanceCeiling else { return Copy.guidanceGentler }
            let ceilingText = Copy.ceilingSuffix.filling(
                ["value": env.format.integer(Int(ceiling.rounded()))]).resolved(env.language)
            // "A gentler range may suit today: around 40." — the number is a personal soft ceiling
            // (the user's own effort baseline centre), never a command.
            return LocalizedString(
                en: "\(Copy.guidanceGentler.en) \(ceilingText)",
                ar: "\(Copy.guidanceGentler.ar) \(ceilingText)")
        case .typical: return Copy.guidanceTypical
        case .headroom: return Copy.guidanceHeadroom
        }
    }

    /// Where the personal ceiling sits on the 0–100 track (gentler days only), so the bar can mark it.
    private var ceilingFraction: Double? {
        guard effort.guidanceBand == .gentler, let ceiling = effort.guidanceCeiling else { return nil }
        return min(1, max(0, ceiling / 100))
    }

    private var updatedText: String {
        let relative = HomeDateFormatting.relative(effort.computedAt, env.language, now: env.now())
        return Copy.updated.filling(["time": relative]).resolved(env.language)
    }
}

/// A thin day-progress bar for the zone-based effort score, with an optional tick at the personal
/// guidance ceiling. `primary` fill — accumulating effort is neutral progress, never a graded state.
private struct EffortProgressBar: View {
    let fraction: Double
    var ceilingFraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BadanColor.surfaceElevated)
                Capsule()
                    .fill(BadanColor.primary.opacity(0.7))
                    .frame(width: max(0, geo.size.width * fraction))
                if let ceilingFraction {
                    Rectangle()
                        .fill(BadanColor.textSecondary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: geo.size.width * ceilingFraction)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight) // progress axis is LTR
    }
}

/// Pure formatting for a reduced-input activity load's value+unit, so the "never a bare number"
/// rendering is unit-testable. Active energy (kcal) and steps (count) each get their localized unit.
enum HomeEffortActivity {
    static func valueText(value: Double, unit: String, format: ValueFormatter) -> String {
        let number = format.integer(Int(value.rounded()))
        // The activity-load unit is the source metric's canonical unit ("kcal" or "count"); a bare
        // "count" reads as nothing, so steps show no unit suffix while energy keeps "kcal".
        switch unit {
        case "count", "steps", "": return number
        default: return "\(number) \(unit)"
        }
    }
}

// MARK: - Sleep module

private struct SleepModuleCard: View {
    @Environment(AppEnvironment.self) private var env
    let sleep: HomeSleepSummary

    private enum Copy {
        static let sleptOfNeed = LocalizedString(en: "Slept {duration} · {pct}% of your need",
                                                 ar: "نمت {duration} · {pct}٪ من حاجتك")
        static let sleepDebt = LocalizedString(en: "Sleep debt {duration}", ar: "دين النوم {duration}")
        static let metNeed = LocalizedString(en: "You met your sleep need last night.", ar: "لبّيت حاجتك للنوم الليلة الماضية.")
        static let mostOfNeed = LocalizedString(en: "You got most of the sleep you needed.", ar: "حصلت على معظم النوم الذي تحتاجه.")
        static let lessThanNeed = LocalizedString(en: "You slept less than your body needed.", ar: "نمت أقل مما يحتاجه جسمك.")
        static let wellShort = LocalizedString(en: "Last night ran well short of your usual need.", ar: "كانت الليلة الماضية أقل بكثير من حاجتك المعتادة.")
    }

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: MetricID.timeAsleep) } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    CardLabelRow(icon: MetricFamily.sleep.symbolName, title: Loc.lastNight)
                    if let pct = sleep.performancePercent {
                        performanceBlock(pct)
                    } else {
                        // Cold start / not computed yet: the honest duration + range position, never
                        // a fabricated performance score.
                        StatBox(
                            value: env.format.duration(seconds: sleep.seconds),
                            label: env.s(MetricFamily.sleep.displayName),
                            chip: sleep.position.map { p in
                                StatusChip(position: p, label: env.s(rangeLabel(p)), language: env.language)
                            }
                        )
                    }

                    // Need-vs-actual (EPIC-24): a RANGE, never a fake-exact target. Only when the
                    // need row exists — otherwise the honest duration above stands alone.
                    if let needCenter = sleep.needCenterSeconds {
                        needVsActualBar(needCenter: needCenter)
                    }

                    if let debt = sleep.debtSeconds, debt >= Self.debtVisibilityThreshold {
                        Text(env.s(Copy.sleepDebt.filling(["duration": env.format.duration(seconds: debt)])))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }

                    // Cold-start note while the sleep-duration baseline is still filling.
                    if let calibration = sleep.calibration, calibration.provisional {
                        CalibrationNote(calibration: calibration, language: env.language,
                                        format: env.format, showsDetail: env.depth.showsPowerDetail)
                    }

                    // Power depth adds the density: the hypnogram of last night's stages, the debt
                    // trend, and the nightly duration sparkline.
                    if env.depth.showsPowerDetail {
                        powerDetail
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Threshold below which sleep debt is not surfaced — a few minutes of debt is noise, and a card
    /// that announces "debt 4m" reads as alarming precision about nothing.
    private static let debtVisibilityThreshold: Double = 30 * 60

    @ViewBuilder
    private func performanceBlock(_ pct: Double) -> some View {
        // SCORE-FIXATION GUARD: the plain-language sentence LEADS; the duration + percent follow.
        Text(performanceSentence(pct), language: env.language)
            .font(BadanFont.sectionTitle)
            .foregroundStyle(BadanColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            Text(env.s(Copy.sleptOfNeed.filling([
                "duration": env.format.duration(seconds: sleep.seconds),
                "pct": env.format.integer(Int(pct.rounded()))])))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            if sleep.performanceProvisional {
                ProvisionalBadge(language: env.language)
            }
        }
    }

    @ViewBuilder
    private func needVsActualBar(needCenter: Double) -> some View {
        let range = SleepNeedRangeReconstruction.range(centerSeconds: needCenter, confidence: sleep.needConfidence)
        SleepNeedVsActualBar(
            actualSeconds: sleep.seconds,
            needLowSeconds: range.low, needCenterSeconds: needCenter, needHighSeconds: range.high,
            language: env.language,
            actualText: env.format.duration(seconds: sleep.seconds),
            needRangeText: "\(env.format.duration(seconds: range.low))–\(env.format.duration(seconds: range.high))")
    }

    @ViewBuilder
    private var powerDetail: some View {
        if !sleep.stages.isEmpty {
            Hypnogram(stages: sleep.stages, language: env.language)
        }
        if sleep.debtSpark.count >= 2 {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(Self.sleepDebtTrendLabel, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                MetricSparkline(series: sleep.debtSpark)
                    .frame(height: 28)
                    .accessibilityHidden(true)
            }
        }
        if sleep.spark.count >= 2 {
            // (FIX-07) Date-spaced series init (OPT-098) so a gap in the last 14 nights renders as a
            // visible gap instead of implying a smooth run.
            MetricSparkline(series: sleep.spark)
                .frame(height: 36)
                .accessibilityHidden(true)
        }
    }

    private static let sleepDebtTrendLabel = LocalizedString(en: "Sleep-debt trend", ar: "اتجاه دين النوم")

    private func performanceSentence(_ pct: Double) -> LocalizedString {
        switch pct {
        case 90...: return Copy.metNeed
        case 70..<90: return Copy.mostOfNeed
        case 50..<70: return Copy.lessThanNeed
        default: return Copy.wellShort
        }
    }
}

/// Reconstructs the published sleep-need RANGE from a stored `sleep.need` row's centre + confidence.
///
/// The engine does not store the band edges — only the centre and the confidence — but the band is a
/// deterministic function of both plus one published constant (`rangeHalfWidthSeconds`), so the surface
/// can recover the exact same range the engine computed rather than inventing one. This MIRRORS
/// `SleepIntelligenceEngine.computeNeed` (the `halfWidth = rangeHalfWidthSeconds · (2 − confidence)`
/// line); the constant is loaded from the shared contract (never hardcoded), exactly as the anatomy
/// sheet derives the band multiplier from stored fields rather than duplicating a constant. A missing
/// confidence is treated as fully uncertain (widest band), so the range never looks tighter than the
/// data earns.
enum SleepNeedRangeReconstruction {
    static func range(centerSeconds: Double, confidence: Double?) -> (low: Double, high: Double) {
        let spec = SleepSpec.defaultShared
        let conf = max(0, min(1, confidence ?? 0))
        let halfWidth = spec.rangeHalfWidthSeconds * (2 - conf)
        return (low: max(0, centerSeconds - halfWidth), high: centerSeconds + halfWidth)
    }
}

// MARK: - Generic metric module (casual)

private struct MetricModuleCard: View {
    @Environment(AppEnvironment.self) private var env
    let metric: HomeKeyMetric
    var secondary: HomeKeyMetric?

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                // EPIC-39 CYCLE-06: `CyclePhaseCovariateNote` below is its own tappable control
                // (a one-tap explainer alert) — kept as a SIBLING of this `NavigationLink`, never
                // nested inside its label, mirroring `BodyPillarCard`'s established pattern of
                // keeping a card's secondary interactive controls outside its primary link.
                NavigationLink { MetricDetailScreen(metricId: metric.metricId) } label: {
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
                .buttonStyle(.plain)
                // Only ever renders when `metric`'s band above was actually phase-conditioned
                // (never on a plain default reading) — research doc §7's "optional overlay chip,
                // not forced narrative" rule.
                if let covariate = metric.phaseCovariate {
                    CyclePhaseCovariateNote(covariate: covariate)
                }
            }
        }
    }
}

// MARK: - Metric grid cell (power)

private struct MetricGridCell: View {
    @Environment(AppEnvironment.self) private var env
    let metric: HomeKeyMetric

    var body: some View {
        BadanCard(padding: BadanSpace.space3) {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                // EPIC-39 CYCLE-06: `CyclePhaseCovariateNote` below is its own tappable control —
                // kept as a SIBLING of this `NavigationLink`, never nested inside its label,
                // mirroring `BodyPillarCard`'s established pattern.
                NavigationLink { MetricDetailScreen(metricId: metric.metricId) } label: {
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
                        if env.depth.showsPowerDetail {
                            // (UX-04) Power depth only — casual's grid cell has no room for a
                            // freshness caption without crowding the layout, and the question
                            // ("how current is this?") is itself a power-user concern.
                            Text(HomeDateFormatting.relative(metric.capturedAt, env.language, now: env.now()))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        if metric.spark.count >= 2 {
                            // (FIX-07) Date-spaced series init (OPT-098) so gaps in the 14-day
                            // window render as gaps instead of a smoothed, evenly-spaced line.
                            MetricSparkline(series: metric.spark)
                                .frame(height: 28)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                // Only ever renders when `metric`'s band above was actually phase-conditioned
                // (never on a plain default reading) — research doc §7's "optional overlay chip,
                // not forced narrative" rule.
                if let covariate = metric.phaseCovariate {
                    CyclePhaseCovariateNote(covariate: covariate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                // UX-07: "Why?" used to push the whole (root-tab) InsightsScreen, landing on a
                // generic feed rather than the insight the user actually tapped through from.
                // Passing this insight's id lets Insights scroll to / distinguish that one row
                // instead.
                NavigationLink { InsightsScreen(focusInsightId: insight.id) } label: {
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

// MARK: - Shared module-visibility helper (FIX-04)

/// The single check every module-mapped Home card applies, in both the casual and power
/// bodies, so a module hidden in Settings actually disappears from every altitude instead of
/// only some cards in one of them. "nutrition" has no Home surface (Settings' caption for it
/// is being reworded separately) so it intentionally has no mapping here.
private func isHomeModuleVisible(_ id: String, in profile: CustomizationProfile) -> Bool {
    profile.module(id)?.visible ?? true
}

/// Maps a Home key-metric id to the `HomeModule` id that governs its visibility, since the
/// power-depth grid renders all four key metrics as one section spanning two modules
/// ("activity": steps/active energy; "heart": resting heart rate/HRV).
private func homeModuleId(forMetric metricId: String) -> String {
    switch metricId {
    case MetricID.restingHeartRate, MetricID.hrv: return "heart"
    default: return "activity"
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
    /// (FIX-07) Date-spaced, not index-spaced — feeds `MetricSparkline`'s `series:` init so a
    /// gap in the window renders as a gap.
    var spark: [(date: Date, value: Double)]
    var familySymbol: String
    var provisional: Bool
    /// When this metric's latest value was captured — the interval record's `endAt` (UX-04),
    /// shown as a relative "2h ago" caption at power depth.
    var capturedAt: Date
    /// EPIC-39 CYCLE-06: set ONLY when `position`/`provisional`/`deltaText` above were resolved
    /// against a phase-CONDITIONED band rather than the default one — the cue to render
    /// `CyclePhaseCovariateNote` beside this metric. `nil` for every metric outside
    /// `CyclePhaseCovariateCoordinator.phaseConditionedMetricIds`, and `nil` whenever the cycle
    /// module is disabled or fell back to the default band, per `PhaseAwareBaselineReader`.
    var phaseCovariate: PhaseCovariateReading?

    var id: String { metricId }
}

struct HomeSleepSummary {
    var seconds: Double
    var position: Baseline.Position?
    /// (FIX-07) Date-spaced, not index-spaced — see `HomeKeyMetric.spark`.
    var spark: [(date: Date, value: Double)]
    var provisional: Bool
    // EPIC-24 sleep-intelligence additions. All optional: when the composition lane hasn't produced
    // the derived rows yet, the card falls back to duration + calibration, never a fabricated score.
    /// `sleep.performance` centre percent + its confidence/provisional, when computed for last night.
    var performancePercent: Double?
    var performanceProvisional: Bool
    var performanceConfidence: Double?
    /// `sleep.need` centre seconds + confidence — enough to reconstruct the published need RANGE
    /// (see `SleepNeedRangeReconstruction`), so the need-vs-actual bar shows a range, never a point.
    var needCenterSeconds: Double?
    var needConfidence: Double?
    /// Latest `sleep.debt` seconds and its recent trend (date-spaced), for the debt caption + sparkline.
    var debtSeconds: Double?
    var debtSpark: [(date: Date, value: Double)]
    /// Last night's stage rows for the hypnogram (empty when the night carried no stages).
    var stages: [SessionStage]
    /// The sleep-duration baseline's calibration, for the cold-start note on the card.
    var calibration: BaselineCalibration?
}

/// The Home Effort card's data. Effort is stored under one id (`effort.day`) in two shapes: a
/// zone-based 0–100 `score`, or — for a sparse-HR day — a reduced-input `activityLoad` with a real
/// movement magnitude and its own unit. They are rendered DISTINCTLY (plan §11 EPIC-26 / §18): the
/// reduced variant is never dressed up as a low score, and a day with neither is a gap, not a zero.
struct HomeEffortSummary {
    enum Kind: Equatable {
        case score(Double)                              // 0–100 zone-based effort
        case activityLoad(value: Double, unit: String)  // reduced-input: raw magnitude + its unit
    }
    var kind: Kind
    var provisional: Bool
    var computedAt: Date
    /// The readiness-linked guidance direction + optional personal ceiling (`nil` when there is no
    /// readiness score to anchor to — no anchor, no suggestion).
    var guidanceBand: EffortGuidanceBand?
    var guidanceCeiling: Double?
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
    /// (FIX-01) The actual calendar day the shown readiness value belongs to — carried out of
    /// `latestReadiness` rather than re-derived from `date`/`readinessDayOffset` at the view
    /// layer, so the "As of {date}" caption can never drift from the value it's describing.
    /// Only meaningful when `readiness` is non-nil (equals `date` otherwise).
    var readinessDate: Date
    /// When `readiness == nil`: how many of the `BaselineEngine.minPointsForConfident` days
    /// needed are already banked (min across readiness's sleep/RHR inputs), so "Still learning"
    /// reads as a countdown instead of an open-ended wait.
    var readinessProgressDays: Int?
    /// The calibration state of readiness's bottleneck input baseline, for the cold-start note on the
    /// hero card (shown when readiness is provisional or not computed yet). `nil` when no contributing
    /// baseline exists at all.
    var readinessCalibration: BaselineCalibration?
    /// EPIC-29 (plan §18). The caveat sentences for any period the user marked over `readinessDate`
    /// — "computed while you were travelling". Empty on an ordinary day, which is the common case,
    /// and empty whenever sensitive records are switched off (a caveat names a circumstance, so it
    /// is sensitive-plus text; the confidence cap the engine already applied is a bare number and
    /// stays). Resolved at load time from the sensitive store, never carried on the derived row.
    var readinessContextCaveats: [LocalizedString] = []
    var narrative: LocalizedString
    var effort: HomeEffortSummary?
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

/// Everything `HomeViewModel.fetch` needs to run off the main actor: the thread-safe repository
/// references (locked `SQLiteConnection` underneath, PERF-01) plus value-type snapshots of the
/// bits of `AppEnvironment` the query logic reads. Deliberately narrower than passing `env`
/// itself, which is `@MainActor`-bound.
struct HomeFetchInputs {
    var measurements: MeasurementRepository
    var derivation: DerivationRepository
    var catalog: CatalogRepository
    var logging: LoggingRepository
    /// EPIC-29. The context seam, read here for exactly one thing: the caveat sentences beside the
    /// readiness value (`ContextCaveats`). Home holds no sensitive connection of its own.
    var contextAnnotations: ContextAnnotationResolver
    var insightsRepo: InsightRepository
    var registry: MetricRegistry
    var format: ValueFormatter
    var language: AppLanguage
    var depth: DepthPolicy
    var nutritionEnabled: Bool
    var sensitiveModulesEnabled: Bool
    var now: Date
    /// EPIC-39 CYCLE-06 integration (closes `CycleModuleServices.refreshAll`'s own named
    /// integration debt — see `PhaseAwareBaselineReader`). `phaseEstimates`/`sensitiveDerivation`
    /// are an ad hoc sensitive-backed `CyclePhaseEstimateRepository`/`DerivationRepository` pair,
    /// constructed ONLY when the cycle module is enabled (mirroring `CycleModuleServices.init`'s
    /// own construction pattern exactly) — `nil` together otherwise. Defaulted so every existing
    /// construction site (this file's own `load`, and `ViewModelPerformanceTests`) keeps
    /// compiling unchanged and keeps reading exactly as it did before this integration: module
    /// disabled, every metric's baseline read untouched.
    var cycleModuleEnabled: Bool = false
    var phaseEstimates: CyclePhaseEstimateRepository? = nil
    var sensitiveDerivation: DerivationRepository? = nil
}

/// The result of the off-main fetch, before it's applied to `HomeViewModel.state` on the
/// main actor.
enum HomeFetchOutcome {
    case loaded(HomeData)
    case empty(hasConnectedSource: Bool)
    case failure
}

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
    /// BUG-12/13: a bumped `dataGeneration` always forces a reload even when `profile` hasn't
    /// changed and the 5s window hasn't elapsed — see `AppEnvironment.dataGeneration`.
    private var lastLoadedGeneration: Int?
    private static let staleThreshold: TimeInterval = 5

    /// Evaluates the staleness guard on the main actor, then (PERF-01) runs the actual queries
    /// on a detached task against the thread-safe store so a Home reload never blocks the main
    /// thread. A cancelled load (e.g. `.task(id:)` re-firing before this one finished) never
    /// clobbers state — mirrors `AppEnvironment.bootstrap`'s `Task.isCancelled` guard.
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
        // EPIC-39 CYCLE-06 integration: ad hoc sensitive-backed repositories, constructed ONLY
        // when the cycle module is enabled — mirrors `CycleModuleServices.init`'s own
        // construction pattern exactly (never `env.database.main`, per I7). `nil` together when
        // disabled, so `PhaseAwareBaselineReader.read` always falls through to the plain default
        // read for every metric.
        let cycleModuleEnabled = profileSnapshot.cycleModuleEnabled
        let inputs = HomeFetchInputs(
            measurements: env.measurements, derivation: env.derivation, catalog: env.catalog,
            logging: env.logging, contextAnnotations: env.contextAnnotations,
            insightsRepo: env.insightsRepo, registry: env.registry,
            format: env.format, language: env.language, depth: env.depth,
            nutritionEnabled: profileSnapshot.nutritionEnabled,
            sensitiveModulesEnabled: profileSnapshot.sensitiveModulesEnabled,
            now: now,
            cycleModuleEnabled: cycleModuleEnabled,
            phaseEstimates: cycleModuleEnabled
                ? CyclePhaseEstimateRepository(sensitive: env.database.sensitive) : nil,
            sensitiveDerivation: cycleModuleEnabled
                ? DerivationRepository(env.database.sensitive) : nil)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .loaded(let data):
            lastLoadedAt = now
            lastLoadedProfile = profileSnapshot
            lastLoadedGeneration = generationSnapshot
            state = .loaded(data)
        case .empty(let hasConnectedSource):
            emptyHasConnectedSource = hasConnectedSource
            state = .empty(hasConnectedSource ? env.s(HomeStrings.stillComingIn) : env.s(Loc.nothingYet))
        case .failure:
            state = .error(env.s(HomeStrings.genericLoadError))
        }
    }

    // MARK: Fetch core (nonisolated — runs on a detached task)

    /// The pure, synchronous query core — everything `load` used to do inline on the main
    /// thread. Kept `internal` (not `private`) so `ViewModelPerformanceTests` can measure query
    /// cost directly, same as before this change.
    nonisolated static func fetch(_ inputs: HomeFetchInputs) -> HomeFetchOutcome {
        let signpostState = PerformanceLog.signposter.beginInterval("HomeViewModel.load")
        defer { PerformanceLog.signposter.endInterval("HomeViewModel.load", signpostState) }

        let tz = TimeZone.current.identifier
        let now = inputs.now
        do {
            let (readiness, dayOffset, readinessDay) = try latestReadiness(inputs, now: now, tz: tz)
            let readinessProgress = readiness == nil ? readinessProgressDays(inputs, now: now) : nil
            let readinessCalibration = try readinessBottleneckCalibration(inputs, now: now)
            // EPIC-29: the note beside the score, resolved from the sensitive store at render time
            // rather than stored on the row (see `ContextCaveats`). Skipped entirely — not merely
            // hidden — when sensitive records are off, so the read never happens either.
            let readinessCaveats = (readiness != nil && inputs.sensitiveModulesEnabled)
                ? try ContextCaveats.forDay(readinessDay, tz: tz, annotations: inputs.contextAnnotations)
                : []
            let effort = try loadEffort(inputs, now: now, tz: tz, readiness: readiness)
            let sleep = try loadSleep(inputs, now: now, tz: tz)
            let metrics = try loadMetrics(inputs, now: now)
            let meds = try loadMeds(inputs, now: now, tz: tz)
            let insight = try inputs.insightsRepo.recent(limit: 1).first
            let (events, eventsPartial) = inputs.depth.showsPowerDetail ? loadEvents(inputs, now: now) : ([], false)

            let hasAny = readiness != nil || sleep != nil || effort != nil || !metrics.isEmpty
                || meds.active > 0 || insight != nil || !events.isEmpty
            guard hasAny else {
                let hasConnectedSource = (try? inputs.catalog.sources())?.contains { $0.status == .active } ?? false
                return .empty(hasConnectedSource: hasConnectedSource)
            }

            let data = HomeData(
                date: now,
                readiness: readiness,
                readinessDayOffset: dayOffset,
                readinessDate: readinessDay,
                readinessProgressDays: readinessProgress,
                readinessCalibration: readinessCalibration,
                readinessContextCaveats: readinessCaveats,
                narrative: narrative(for: readiness, sleep: sleep),
                effort: effort,
                sleep: sleep,
                metrics: metrics,
                medsDue: meds.due,
                medsActive: meds.active,
                firstDueMedName: meds.firstDueName,
                topInsight: insight,
                recentEvents: events,
                recentEventsPartial: eventsPartial
            )
            return .loaded(data)
        } catch {
            #if DEBUG
            print("HomeViewModel.load failed: \(error)")
            #endif
            return .failure
        }
    }

    // MARK: Readiness

    // (DATA-11-UI) Was `now.addingTimeInterval(Double(-offset) * 86_400)` — walking back by a
    // fixed 86,400s per day silently miscounts across a DST transition (a 23- or 25-hour local
    // day) in `tz`. `DayAttribution.addingDays` walks calendar days instead.
    //
    // (FIX-01) Returns the matched day itself (not just an offset) so the caller can label the
    // readiness value with the day it actually belongs to, rather than re-deriving it (or
    // worse, using "now") at the view layer.
    private nonisolated static func latestReadiness(_ inputs: HomeFetchInputs, now: Date, tz: String) throws -> (value: DerivedValue?, dayOffset: Int, day: Date) {
        for offset in 0..<4 {
            let day = DayAttribution.addingDays(-offset, to: now, tz: tz)
            let key = DayAttribution.dayPeriodKey(day, tz: tz)
            if let value = try inputs.derivation.latestDerived(metricId: "readiness.score", periodKey: key) {
                return (value, offset, day)
            }
        }
        return (nil, 0, now)
    }

    /// How many of the `minPointsForConfident` days readiness's own inputs (sleep, RHR
    /// baselines) already have banked, so the "still learning" fallback can read as a countdown
    /// rather than an open-ended wait (EASE-139). Best-effort: a fetch failure here just means
    /// no progress hint is shown, never a broken Home load.
    private nonisolated static func readinessProgressDays(_ inputs: HomeFetchInputs, now: Date) -> Int? {
        let sleepPoints = (try? inputs.derivation.latestBaseline(metricId: MetricID.timeAsleep))?.nPoints ?? 0
        // EPIC-39 CYCLE-06: resting heart rate is one of the three phase-conditioned metrics —
        // routed through `PhaseAwareBaselineReader` like every other RHR/HRV baseline read on
        // this screen (see the type's own header). Module-disabled behavior is bit-for-bit
        // unchanged: the helper's guard falls straight through to the same plain default read
        // this line always made.
        let rhrPoints = (try? PhaseAwareBaselineReader.read(
            metricId: MetricID.restingHeartRate, cycleModuleEnabled: inputs.cycleModuleEnabled,
            phaseEstimates: inputs.phaseEstimates, sensitiveDerivation: inputs.sensitiveDerivation,
            defaultDerivation: inputs.derivation, asOf: now))?.baseline?.nPoints ?? 0
        return min(min(sleepPoints, rhrPoints), BaselineEngine.minPointsForConfident)
    }

    // MARK: Sleep

    private nonisolated static func loadSleep(_ inputs: HomeFetchInputs, now: Date, tz: String) throws -> HomeSleepSummary? {
        let localNight = DayAttribution.localNight(sessionEnd: now, tz: tz)
        let primary = try inputs.measurements.primarySleep(localNight: localNight)
        var seconds: Double?
        if let primary {
            seconds = primary.detail.timeAsleepSeconds ?? primary.durationSeconds
        } else if let interval = try inputs.measurements.latestInterval(metricId: MetricID.timeAsleep),
                  // (UX-01-Home) The fallback picks the single most recent sleep record ever
                  // logged with no age bound — unbounded, "Last night" could silently show a
                  // reading from a month ago. Beyond `sleepFallbackMaxAge`, fall through to nil
                  // (the sleep card's existing no-data treatment: it simply doesn't render).
                  HomeStaleness.isFresh(interval.endAt, now: now, maxAge: HomeStaleness.sleepFallbackMaxAge) {
            seconds = interval.value
        }
        guard let seconds else { return nil }

        let baseline = try inputs.derivation.latestBaseline(metricId: MetricID.timeAsleep)
        let position = baseline?.position(of: seconds)
        let calibration = baseline.map { BaselineCalibration.from(baseline: $0, spec: BaselineSpec.defaultShared) }

        // Kept as a plain 14-day window rather than routed through `DayAttribution` (DATA-11-UI
        // scope note): it's a fixed lookback range for sparkline history, not a day-attribution
        // boundary, and changing it would ripple into the sparkline's actual data window.
        let from = now.addingTimeInterval(-14 * 86_400)
        // Sparkline history is decorative, not primary content — a failure here should cost the
        // sparkline, not the whole Home screen (OPT-011).
        let nights = (try? inputs.measurements.sessions(kind: .sleepPrimary, from: from, to: now)) ?? []
        // (FIX-07) Date-spaced (date, value) pairs — feeds `MetricSparkline`'s `series:` init
        // so a missing night renders as a visible gap instead of an evenly-spaced line.
        let spark = nights
            .sorted { $0.startAt < $1.startAt }
            .map { (date: $0.startAt, value: $0.detail.timeAsleepSeconds ?? $0.durationSeconds) }

        // EPIC-24 sleep-intelligence: the derived rows the composition lane persists for last night.
        // Each read is best-effort (a nil is an honest "not computed yet", never a fabricated value),
        // so a store hiccup or a night still awaiting recompute costs only the enrichment, not the card.
        let nightKey = "day:" + localNight
        let performance = (try? inputs.derivation.latestDerived(metricId: MetricID.sleepPerformance, periodKey: nightKey)) ?? nil
        let need = (try? inputs.derivation.latestDerived(metricId: MetricID.sleepNeed, periodKey: nightKey)) ?? nil
        let debt = (try? inputs.derivation.latestDerived(metricId: MetricID.sleepDebt, periodKey: nightKey)) ?? nil

        // Debt trend: the recent `sleep.debt` series, date-spaced so a missed night reads as a gap.
        let debtSpark: [(date: Date, value: Double)] = ((try? inputs.derivation.latestDerivedSeries(metricId: MetricID.sleepDebt)) ?? [])
            .compactMap { dv in
                let key = dv.periodKey.hasPrefix("day:") ? String(dv.periodKey.dropFirst(4)) : dv.periodKey
                guard let date = DayAttribution.date(fromDayKey: key, tz: tz), date >= from else { return nil }
                return (date: date, value: dv.value)
            }
            .sorted { $0.date < $1.date }

        // Stages for the hypnogram — decorative enrichment, isolated from the primary load (OPT-011).
        let stages = primary.flatMap { try? inputs.measurements.stages(sessionId: $0.id) } ?? []

        return HomeSleepSummary(
            seconds: seconds, position: position, spark: spark, provisional: baseline?.provisional ?? true,
            performancePercent: performance?.value, performanceProvisional: performance?.provisional ?? true,
            performanceConfidence: performance?.confidence,
            needCenterSeconds: need?.value, needConfidence: need?.confidence,
            debtSeconds: debt?.value, debtSpark: debtSpark, stages: stages, calibration: calibration)
    }

    // MARK: Effort (EPIC-26)

    /// The day's Effort, read from the `effort.day` derived row the composition lane persists. A
    /// `score_0_100` unit is the zone-based score; any other unit is the reduced-input activity load
    /// (a real movement magnitude, labelled distinctly — never a zero-looking score). Guidance is the
    /// readiness-linked direction, computed from the day's readiness value via the engine's own pure
    /// band function so the surface and the engine can't disagree.
    private nonisolated static func loadEffort(_ inputs: HomeFetchInputs, now: Date, tz: String,
                                               readiness: DerivedValue?) throws -> HomeEffortSummary? {
        // The day's period key, exactly as `latestReadiness` forms today's — so effort and readiness
        // are read against the same local day.
        let dayKey = DayAttribution.dayPeriodKey(now, tz: tz)
        guard let effort = try inputs.derivation.latestDerived(metricId: MetricID.effortDay, periodKey: dayKey) else {
            return nil
        }
        let scoreUnit = inputs.registry.definitionOrFallback(MetricID.effortDay).canonicalUnit
        let kind: HomeEffortSummary.Kind = effort.unit == scoreUnit
            ? .score(effort.value)
            : .activityLoad(value: effort.value, unit: effort.unit)

        // Guidance direction from readiness (pure band function, shared with the engine). Only a
        // gentler day with an ESTABLISHED personal effort baseline offers a soft ceiling — never a
        // population number, never a command.
        var band: EffortGuidanceBand?
        var ceiling: Double?
        if let readiness {
            band = EffortEngine.guidanceBand(readiness: readiness.value)
            if band == .gentler,
               let effortBaseline = try inputs.derivation.latestBaseline(metricId: MetricID.effortDay),
               !effortBaseline.provisional {
                ceiling = effortBaseline.center
            }
        }
        return HomeEffortSummary(kind: kind, provisional: effort.provisional, computedAt: effort.computedAt,
                                 guidanceBand: band, guidanceCeiling: ceiling)
    }

    /// The calibration state of readiness's *bottleneck* input — the contributing baseline with the
    /// fewest points (RHR, HRV, or sleep duration), i.e. the one still gating a settled readiness. Its
    /// `BaselineCalibration` drives the cold-start note on the hero card. `nil` when none of readiness's
    /// inputs has a baseline yet (there is simply nothing to calibrate against to report progress on).
    private nonisolated static func readinessBottleneckCalibration(_ inputs: HomeFetchInputs, now: Date) throws -> BaselineCalibration? {
        // EPIC-39 CYCLE-06: resting heart rate and HRV are two of the three phase-conditioned
        // metrics — routed through `PhaseAwareBaselineReader`, same as every other RHR/HRV
        // baseline read on this screen. `timeAsleep` is NOT phase-conditioned and keeps its exact
        // original call, untouched. Module-disabled behavior for all three ids is bit-for-bit
        // unchanged (the helper falls straight through to the same plain default read).
        var baselines: [Baseline] = [MetricID.restingHeartRate, MetricID.hrv].compactMap { id -> Baseline? in
            (try? PhaseAwareBaselineReader.read(
                metricId: id, cycleModuleEnabled: inputs.cycleModuleEnabled,
                phaseEstimates: inputs.phaseEstimates, sensitiveDerivation: inputs.sensitiveDerivation,
                defaultDerivation: inputs.derivation, asOf: now))?.baseline
        }
        if let sleepBaseline = try? inputs.derivation.latestBaseline(metricId: MetricID.timeAsleep) {
            baselines.append(sleepBaseline)
        }
        guard let bottleneck = baselines.min(by: { $0.nPoints < $1.nPoints }) else { return nil }
        return BaselineCalibration.from(baseline: bottleneck, spec: BaselineSpec.defaultShared)
    }

    // MARK: Key metrics

    private nonisolated static func loadMetrics(_ inputs: HomeFetchInputs, now: Date) throws -> [HomeKeyMetric] {
        let ids = [MetricID.restingHeartRate, MetricID.hrv, MetricID.steps, MetricID.activeEnergy]
        // Kept as a plain 14-day window (DATA-11-UI scope note) — a fixed sparkline lookback,
        // not a day-attribution boundary.
        let from = now.addingTimeInterval(-14 * 86_400)
        var result: [HomeKeyMetric] = []
        for id in ids {
            guard let latest = try inputs.measurements.latestInterval(metricId: id),
                  // (UX-01-Home) Unbounded, this fallback could show a reading weeks old as
                  // "current." Beyond `keyMetricMaxAge`, skip the metric entirely — the grid's
                  // existing no-data treatment for a metric with nothing to show.
                  HomeStaleness.isFresh(latest.endAt, now: now, maxAge: HomeStaleness.keyMetricMaxAge)
            else { continue }
            let def = inputs.registry.definitionOrFallback(id)
            // EPIC-39 CYCLE-06: resting heart rate and HRV are two of the three phase-conditioned
            // metrics — routed through `PhaseAwareBaselineReader`, the SAME helper every other
            // RHR/HRV baseline read on this screen now uses. `steps`/`activeEnergy` are outside
            // `CyclePhaseCovariateCoordinator.phaseConditionedMetricIds`, so the helper's own
            // guard falls straight through to the exact original call for them — untouched.
            // Module-disabled behavior is bit-for-bit unchanged for every id.
            let phaseAwareRead = try PhaseAwareBaselineReader.read(
                metricId: id, cycleModuleEnabled: inputs.cycleModuleEnabled,
                phaseEstimates: inputs.phaseEstimates, sensitiveDerivation: inputs.sensitiveDerivation,
                defaultDerivation: inputs.derivation, asOf: now)
            let baseline = phaseAwareRead.baseline
            let position = baseline?.position(of: latest.value)
            // Sparkline history is decorative — isolate its failure from the primary
            // latest-value/baseline fetches above (OPT-011).
            // (FIX-07) Date-spaced (date, value) pairs, not index-spaced — see `HomeKeyMetric.spark`.
            let spark = ((try? inputs.measurements.intervalRecords(metricId: id, from: from, to: now)) ?? [])
                .map { (date: $0.startAt, value: $0.value) }
            let delta: String? = (inputs.depth.showsPowerDetail ? baseline : nil).map {
                signedDelta(inputs, metricId: id, value: latest.value, center: $0.center)
            }
            result.append(HomeKeyMetric(
                metricId: id,
                label: def.label(depth: inputs.depth, language: inputs.language),
                heroValue: inputs.format.heroValue(metricId: id, canonicalValue: latest.value),
                unit: inputs.format.unitLabel(metricId: id),
                position: position,
                deltaText: delta,
                spark: spark,
                familySymbol: def.familyGroup.symbolName,
                provisional: baseline?.provisional ?? true,
                capturedAt: latest.endAt,
                phaseCovariate: phaseAwareRead.covariate
            ))
        }
        return result
    }

    private nonisolated static func signedDelta(_ inputs: HomeFetchInputs, metricId: String, value: Double, center: Double) -> String {
        let delta = value - center
        let sign = delta >= 0 ? "+" : "\u{2212}"
        let magnitude = inputs.format.heroValue(metricId: metricId, canonicalValue: abs(delta))
        // Matches Insights' "vs your usual" wording (InsightsLoc.vsUsual) so the same comparison
        // doesn't read as two different concepts across adjacent tabs (EASE-149).
        let vs = LocalizedString(en: "vs your usual", ar: "مقارنةً بالمعتاد")
        if let unit = inputs.format.unitLabel(metricId: metricId) {
            return "\(sign)\(magnitude) \(unit) \u{00B7} \(vs.resolved(inputs.language))"
        }
        return "\(sign)\(magnitude) \u{00B7} \(vs.resolved(inputs.language))"
    }

    // MARK: Meds

    private nonisolated static func loadMeds(_ inputs: HomeFetchInputs, now: Date, tz: String) throws -> (due: Int, active: Int, firstDueName: String?) {
        let active = try inputs.logging.regimens(activeOnly: true)
        let weekday = mondayBasedWeekday(now, tz: tz)

        let dayStart = DayAttribution.startOfDay(now, tz: tz)
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
        let handledByRegimen = Dictionary(grouping: try inputs.logging.adherence(from: dayStart, to: dayEnd), by: \.regimenId)

        var due = 0
        var firstDueName: String?
        for regimen in active.sorted(by: { $0.name < $1.name }) {
            let scheduled = regimen.schedule.dueTimes(onWeekday: weekday).count
            guard scheduled > 0 else { continue }
            // (EDGE-20) Was `.count` over every raw event for the regimen today — a duplicate
            // "taken" row for the same slot (e.g. legacy data from before scheduled adherence
            // ids became deterministic) inflated the handled count past `scheduled`, silently
            // suppressing a genuinely-due later dose. Count distinct handled *slots* instead.
            let handled = distinctHandledSlotCount(handledByRegimen[regimen.id] ?? [])
            let regimenDue = max(0, scheduled - handled)
            due += regimenDue
            if regimenDue > 0, firstDueName == nil {
                firstDueName = regimen.name
            }
        }
        return (due, active.count, firstDueName)
    }

    /// (EDGE-20) How many distinct scheduled slots a day's adherence events for one regimen
    /// actually resolve, deduping same-slot duplicates so they can't over-count against
    /// `dueTimes().count`. Scheduled events (see `MedicationLogView.record`) carry a
    /// deterministic id of the form `"adh-<regimenId>-<yyyy-MM-dd>-<HH:mm>"` — the trailing
    /// `-`-delimited component is exactly that slot's canonical "HH:mm" time (the id's other
    /// dash-delimited pieces are the ULID regimen id, which never itself contains a dash, and
    /// the day key's own dashes), so parsing it is cheaper and just as correct as re-deriving a
    /// nearest-slot match the way the medication screen does for display. An id that doesn't
    /// match that shape (an as-needed dose's ULID) can't collide with a scheduled slot, so it
    /// counts as its own distinct occurrence via its full id. Kept `internal` (not `private`) so
    /// `SyncBusFixTests` can exercise it directly as a pure function.
    nonisolated static func distinctHandledSlotCount(_ events: [AdherenceEvent]) -> Int {
        var slotKeys = Set<String>()
        for event in events {
            if event.id.hasPrefix("adh-"), let time = event.id.split(separator: "-").last {
                slotKeys.insert(String(time))
            } else {
                slotKeys.insert(event.id)
            }
        }
        return slotKeys.count
    }

    private nonisolated static func mondayBasedWeekday(_ date: Date, tz: String) -> Int {
        let cal = DayAttribution.calendar(tz: tz)
        let sundayBased = cal.component(.weekday, from: date) // 1 = Sunday ... 7 = Saturday
        return ((sundayBased + 5) % 7) + 1                    // 1 = Monday ... 7 = Sunday
    }

    // MARK: Recent events (power timeline preview)

    private nonisolated static func loadEvents(_ inputs: HomeFetchInputs, now: Date) -> (events: [HomeEvent], partial: Bool) {
        // Reuses Timeline's own "recent" window so the two screens' notion of "recent" can't
        // silently diverge (OPT-008).
        let from = now.addingTimeInterval(-Double(TimelineAssembler.windowDays) * 86_400)
        var byType: [TimelineEventType: [HomeEvent]] = [:]
        var partial = false

        if let workouts = try? inputs.logging.workouts(from: from, to: now) {
            byType[.workout] = workouts.map {
                HomeEvent(id: "w:\($0.id)", type: .workout, occurredAt: $0.startAt, detail: $0.activityType)
            }
        } else { partial = true }

        if let notes = try? inputs.logging.notes(from: from, to: now) {
            byType[.note] = notes.map {
                HomeEvent(id: "n:\($0.id)", type: .note, occurredAt: $0.occurredAt, detail: $0.text)
            }
        } else { partial = true }

        if inputs.nutritionEnabled {
            if let meals = try? inputs.logging.nutrition(from: from, to: now) {
                byType[.meal] = meals.map {
                    HomeEvent(id: "m:\($0.id)", type: .meal, occurredAt: $0.occurredAt, detail: $0.description)
                }
            } else { partial = true }
        }

        if inputs.sensitiveModulesEnabled {
            if let symptoms = try? inputs.logging.symptoms(from: from, to: now) {
                byType[.symptom] = symptoms.map {
                    HomeEvent(id: "s:\($0.id)", type: .symptom, occurredAt: $0.occurredAt, detail: nil)
                }
            } else { partial = true }
            if let doses = try? inputs.logging.adherence(from: from, to: now) {
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

    private nonisolated static func narrative(for readiness: DerivedValue?, sleep: HomeSleepSummary?) -> LocalizedString {
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
