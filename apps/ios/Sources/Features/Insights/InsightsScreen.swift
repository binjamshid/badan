import SwiftUI

// MARK: - Screen

/// The interpretation feed. A calm, deterministic account of "what changed" and "why we're
/// saying it" — never diagnostic, never moralized. A weekly summary card sits on top (sleep +
/// resting heart rate against each personal band), then the recent insight cards with 👍/👎
/// feedback and, at power depth, a "Why am I seeing this?" disclosure. Everything is worked out
/// on-device with fixed rules; there is no AI in this version, and a footer says so.
struct InsightsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = InsightsViewModel()
    /// UX-07: when set (Home's insight-card "Why?" link passes the insight that was actually
    /// tapped), the feed lands on / visually distinguishes that specific insight instead of
    /// just opening at the top of the generic feed. `nil` — every other entry point (the tab
    /// bar itself) — keeps today's behavior unchanged.
    var focusInsightId: String? = nil

    var body: some View {
        Group {
            // Rendered directly rather than through `StatefulContainer`'s generic `.empty`
            // branch (UX-08): that branch is the same interchangeable tray icon every screen
            // falls back to, when Insights already has a purpose-built empty surface
            // (`InsightsEmptyFeed`, sparkles + friendly copy) it uses for the feed-only-empty
            // case just below — this makes the whole-screen empty case use the same one.
            if case .empty = vm.state {
                emptyScreen
            } else {
                StatefulContainer(
                    vm.state,
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env) } }
                ) { data in
                    loadedScreen(data)
                }
            }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.tabInsights))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: InsightsLoadKey(profile: env.profile, generation: env.dataGeneration)) { await vm.load(env) }
    }

    private var emptyScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                InsightsEmptyFeed()
                InsightsFooterNote()
            }
            .padding(.horizontal, BadanSpace.space4)
            .padding(.vertical, BadanSpace.space4)
        }
        .background(BadanColor.background)
    }

    private func loadedScreen(_ data: InsightsData) -> some View {
        // UX-07: `ScrollViewReader` so a `focusInsightId` passed in from Home can actually land
        // on that row rather than just opening at the top of the feed.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    if !data.weekly.isEmpty {
                        InsightsWeeklyCard(changes: data.weekly)
                    }

                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        SectionHeader(env.s(InsightsLoc.feedTitle))
                        if data.insights.isEmpty {
                            InsightsEmptyFeed()
                        } else {
                            ForEach(data.insights) { insight in
                                InsightsFeedCard(
                                    insight: insight,
                                    feedbackFailed: vm.failedFeedbackIds.contains(insight.id),
                                    isFocused: insight.id == focusInsightId
                                ) { value in
                                    vm.toggleFeedback(env, id: insight.id, value: value)
                                }
                                .id(insight.id)
                            }
                        }
                    }

                    InsightsFooterNote()
                }
                .padding(.horizontal, BadanSpace.space4)
                .padding(.vertical, BadanSpace.space4)
            }
            .background(BadanColor.background)
            .onAppear { scrollToFocusedInsight(proxy) }
        }
    }

    /// Best-effort — deferred a beat so the just-appeared `ScrollView`'s layout has settled
    /// before asking it to scroll (an immediate `scrollTo` on first appear is a well-known
    /// SwiftUI no-op/partial-scroll pitfall). Not finding the row (e.g. it aged out of the
    /// feed's own limit) is silently a no-op — landing on top of the ordinary feed is still a
    /// reasonable fallback, never an error state.
    private func scrollToFocusedInsight(_ proxy: ScrollViewProxy) {
        guard let focusInsightId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation { proxy.scrollTo(focusInsightId, anchor: .center) }
        }
    }
}

/// BUG-12/13: the standardized `.task(id:)` identity — see `HomeLoadKey` (`HomeScreen.swift`).
private struct InsightsLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

// MARK: - Weekly summary ("what changed")

private struct InsightsWeeklyCard: View {
    @Environment(AppEnvironment.self) private var env
    let changes: [WeeklyChange]

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(InsightsLoc.weeklyTitle))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    Text(env.s(InsightsLoc.weeklySubtitle))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(changes.enumerated()), id: \.element.id) { idx, change in
                        if idx > 0 {
                            Rectangle()
                                .fill(BadanColor.separator)
                                .frame(height: 1)
                        }
                        InsightsWeeklyRow(change: change)
                    }
                }
            }
        }
    }
}

private struct InsightsWeeklyRow: View {
    @Environment(AppEnvironment.self) private var env
    let change: WeeklyChange

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: change.metricId) } label: { rowContent }
            .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: BadanSpace.space3) {
            Image(systemName: change.familySymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BadanColor.primary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.label)
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                HStack(spacing: BadanSpace.space2) {
                    Text(change.valueText)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    if let delta = change.deltaText {
                        Text(delta)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                if let consistency = change.consistencyText {
                    Text(consistency)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        // A day-count fraction is a technical fragment, not prose — keep it
                        // left-to-right in both languages, matching InsightsWhyDisclosure.
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            Spacer(minLength: BadanSpace.space2)
            statusChip
            Image(systemName: "chevron.forward")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusChip: some View {
        if change.stillLearning || change.position == nil {
            StatusChip(.info, label: env.s(Loc.stillLearning), language: env.language)
        } else if let position = change.position {
            StatusChip(position: position, label: env.s(Self.positionLabel(position)), language: env.language)
        }
    }

    private static func positionLabel(_ p: Baseline.Position) -> LocalizedString {
        switch p {
        case .within: return Loc.inYourRange
        case .above: return Loc.aboveYourRange
        case .below: return Loc.belowYourRange
        }
    }
}

// MARK: - Insight feed card

private struct InsightsFeedCard: View {
    @Environment(AppEnvironment.self) private var env
    let insight: Insight
    let feedbackFailed: Bool
    /// UX-07: true when this is the specific insight Home's "Why?" link was tapped for. Draws a
    /// quiet highlight (mirrors `SourcesPriorityNote`'s tinted-border treatment for "this card is
    /// special") and, at power depth, opens `InsightsWhyDisclosure` pre-expanded.
    var isFocused: Bool = false
    let onFeedback: (Int) -> Void

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                sentence
                Rectangle()
                    .fill(BadanColor.separator)
                    .frame(height: 1)
                feedbackRow
                if feedbackFailed {
                    Text(env.s(InsightsLoc.feedbackFailed))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                if env.depth.showsPowerDetail {
                    InsightsWhyDisclosure(insight: insight, initiallyExpanded: isFocused)
                } else {
                    InsightsCasualWhyNote(insight: insight)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(isFocused ? BadanColor.primary.opacity(0.5) : .clear, lineWidth: 1.5)
        )
    }

    // The localized interpretation, tappable through to the metric it concerns.
    @ViewBuilder private var sentence: some View {
        if let metricId = insight.metricIds.first {
            NavigationLink { MetricDetailScreen(metricId: metricId) } label: { sentenceRow(tappable: true) }
                .buttonStyle(.plain)
        } else {
            sentenceRow(tappable: false)
        }
    }

    private func sentenceRow(tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            Image(systemName: familySymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BadanColor.primary)
                // A dimmer icon signals "nothing to tap through to" for insights with no
                // associated metric, matching the missing chevron below.
                .opacity(tappable ? 1 : 0.5)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(insight.renderedText.resolved(env.language))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tappable {
                Image(systemName: "chevron.forward")
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var familySymbol: String {
        guard let id = insight.metricIds.first else { return "sparkles" }
        return env.registry.definitionOrFallback(id).familyGroup.symbolName
    }

    private var feedbackRow: some View {
        HStack(spacing: BadanSpace.space2) {
            Text(env.s(InsightsLoc.helpful))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            // Wider gap than the row's own spacing so the two adjacent 44pt touch targets
            // don't sit closer together than HIG-recommended breathing room allows.
            HStack(spacing: BadanSpace.space4) {
                feedbackButton(value: 1, symbol: "hand.thumbsup", a11y: InsightsLoc.thumbsUp)
                feedbackButton(value: -1, symbol: "hand.thumbsdown", a11y: InsightsLoc.thumbsDown)
            }
        }
    }

    private func feedbackButton(value: Int, symbol: String, a11y: LocalizedString) -> some View {
        let selected = (insight.feedback ?? 0) == value
        return Button { onFeedback(value) } label: {
            Image(systemName: selected ? symbol + ".fill" : symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                .background(Circle().fill(selected ? BadanColor.primary.opacity(0.25) : Color.clear))
                .overlay(Circle().strokeBorder(selected ? BadanColor.primary.opacity(0.4) : Color.clear, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(a11y, language: env.language))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - "Why am I seeing this?" (power depth)

private struct InsightsWhyDisclosure: View {
    @Environment(AppEnvironment.self) private var env
    let insight: Insight
    @State private var expanded: Bool

    /// UX-07: `initiallyExpanded` lets `InsightsFeedCard` open this pre-expanded for the one
    /// insight Home's "Why?" link actually pointed at, without changing this view's own
    /// collapsed-by-default behavior for every other card.
    init(insight: Insight, initiallyExpanded: Bool = false) {
        self.insight = insight
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: BadanSpace.space2) {
                    Text(env.s(InsightsLoc.whyTitle))
                        .font(BadanFont.caption.weight(.medium))
                        .foregroundStyle(BadanColor.primary)
                    Spacer(minLength: BadanSpace.space2)
                    // The app's own chevron language, rotated to signal expand/collapse —
                    // matching every other affordance instead of the system disclosure triangle.
                    Image(systemName: "chevron.forward")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.primary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)

            if expanded {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    detailRow(InsightsLoc.templateLabel, value: friendlyTemplateName)
                    detailRow(Loc.contributingRecords, value: env.format.integer(insight.evidenceRefs.count))
                    detailRow(InsightsLoc.generatedLabel, value: InsightsDateFormatting.string(from: insight.generatedAt, language: env.language))
                }
                .padding(.top, BadanSpace.space2)
            }
        }
    }

    private func detailRow(_ label: LocalizedString, value: String) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Text(env.s(label))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.caption.monospaced())
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
                // Identifiers/timestamps read left-to-right in both languages.
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    // A plain-language stand-in for the raw template id, keeping the one power-mode disclosure
    // row that showed a technical identifier consistent with Insights' sentence-first design.
    // Falls back to the raw id for any template not yet in the map (forward-compatible).
    private var friendlyTemplateName: String {
        (Self.templateNames[insight.templateId] ?? LocalizedString(en: insight.templateId, ar: insight.templateId))
            .resolved(env.language)
    }

    private static let templateNames: [String: LocalizedString] = [
        "vitals_within_band": LocalizedString(en: "Within range", ar: "ضمن النطاق"),
        "hrv_below_band": LocalizedString(en: "Below range", ar: "أقل من النطاق"),
        "rhr_above_band": LocalizedString(en: "Above range", ar: "أعلى من النطاق"),
        "composite_vitals_drift": LocalizedString(en: "Multiple vitals drifting", ar: "انحراف عدة مؤشرات حيوية"),
        "trend_improving": LocalizedString(en: "Improving trend", ar: "اتجاه متحسّن"),
        "sleep_debt_rising": LocalizedString(en: "Sleep dipping", ar: "انخفاض في النوم"),
        "baseline_provisional": LocalizedString(en: "Still calibrating", ar: "لا تزال قيد المعايرة"),
        "window_insufficient_coverage": LocalizedString(en: "Not enough data", ar: "بيانات غير كافية"),
        "status_sick_context": LocalizedString(en: "Rest-day context", ar: "سياق يوم راحة"),
        "cycle_phase_typical": LocalizedString(en: "Cycle-phase typical", ar: "معتاد لمرحلة الدورة"),
        "correlation_association": LocalizedString(en: "Pattern association", ar: "ارتباط نمطي"),
        "recovery_back_to_baseline": LocalizedString(en: "Back to range", ar: "عودة إلى النطاق"),
        "within_band_streak": LocalizedString(en: "Consistent streak", ar: "استمرارية ضمن النطاق"),
    ]
}

/// A minimal, always-visible reassurance for casual depth: just the generated date, without the
/// more technical rule/evidence rows reserved for power mode. Casual users get some provenance
/// instead of none (the footer note is the only other "why" signal they otherwise see).
private struct InsightsCasualWhyNote: View {
    @Environment(AppEnvironment.self) private var env
    let insight: Insight

    var body: some View {
        HStack(spacing: BadanSpace.space2) {
            Text(env.s(InsightsLoc.generatedLabel))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Text(InsightsDateFormatting.string(from: insight.generatedAt, language: env.language))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// Cached once per file instead of allocating a fresh `DateFormatter` on every render; only the
/// locale (a cheap property set) changes between calls. Shared by the power "why" disclosure
/// and the casual note above it.
private enum InsightsDateFormatting {
    static let cached: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func string(from date: Date, language: AppLanguage) -> String {
        cached.locale = Locale(identifier: language.localeIdentifier)
        return cached.string(from: date)
    }
}

// MARK: - Empty feed + footer

private struct InsightsEmptyFeed: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // EmptyStateView already provides its own generous padding/centering — an outer
        // BadanCard doubled up chrome and produced an oversized card (matches how
        // TimelineScreen uses EmptyStateView directly, with no extra wrapper).
        EmptyStateView(
            icon: "sparkles",
            title: env.s(InsightsLoc.emptyTitle),
            message: env.s(InsightsLoc.emptyMessage)
        )
    }
}

private struct InsightsFooterNote: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "lock.shield")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            // Elevated from caption/textSecondary so this trust/privacy message doesn't
            // visually disappear next to ordinary incidental metadata on the same screen.
            Text(env.s(InsightsLoc.footerNote))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BadanSpace.space1)
    }
}

// MARK: - View model + data

/// One row of the weekly summary: a metric's latest value placed against its personal band.
private struct WeeklyChange: Identifiable {
    let metricId: String
    let familySymbol: String
    let label: String
    let position: Baseline.Position?   // nil while still learning
    let stillLearning: Bool
    let valueText: String
    let deltaText: String?             // power depth only
    let consistencyText: String?       // "N/W days" — positive, non-comparative logging cadence
    var id: String { metricId }
}

private struct InsightsData {
    var weekly: [WeeklyChange]
    var insights: [Insight]
}

/// Everything the fetch core needs to run off the main actor (PERF-01) — thread-safe repository
/// references plus value-type snapshots of the profile/format bits it reads.
private struct InsightsFetchInputs {
    var measurements: MeasurementRepository
    var derivation: DerivationRepository
    var insightsRepo: InsightRepository
    var registry: MetricRegistry
    var format: ValueFormatter
    var language: AppLanguage
    var depth: DepthPolicy
    var now: Date
}

private enum InsightsFetchOutcome {
    case loaded(InsightsData)
    case empty
}

@Observable
@MainActor
private final class InsightsViewModel {
    var state: LoadState<InsightsData> = .loading
    /// Insight ids whose most recent feedback tap failed to persist, so the card can show a
    /// brief inline signal instead of silently looking like a no-op.
    var failedFeedbackIds: Set<String> = []

    /// Runs the weekly-summary + feed queries on a detached task (PERF-01). A cancelled load
    /// never clobbers state.
    func load(_ env: AppEnvironment) async {
        let inputs = InsightsFetchInputs(
            measurements: env.measurements, derivation: env.derivation, insightsRepo: env.insightsRepo,
            registry: env.registry, format: env.format, language: env.language, depth: env.depth,
            now: env.now())

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(.loaded(let data)):
            state = .loaded(data)
        case .success(.empty):
            state = .empty(env.s(InsightsLoc.emptyTitle))
        case .failure(let error):
            // The raw error goes to the debug log, not the UI (BUG-14) — users see one calm,
            // bilingual "couldn't load" message with a retry action instead of a Swift error
            // description as the screen's title.
            LoadErrorLog.log(error, screen: "Insights")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Fetch core (nonisolated — runs on a detached task)

    nonisolated private static func fetch(_ inputs: InsightsFetchInputs) -> Result<InsightsFetchOutcome, Error> {
        let signpostState = PerformanceLog.signposter.beginInterval("InsightsViewModel.load")
        defer { PerformanceLog.signposter.endInterval("InsightsViewModel.load", signpostState) }
        do {
            let weekly = try weeklyChanges(inputs)
            let insights = try inputs.insightsRepo.recent(limit: 20)
            if weekly.isEmpty && insights.isEmpty {
                return .success(.empty)
            }
            return .success(.loaded(InsightsData(weekly: weekly, insights: insights)))
        } catch {
            return .failure(error)
        }
    }

    /// Persist the tap, then reflect it locally. Tapping the already-selected thumb clears it.
    func toggleFeedback(_ env: AppEnvironment, id: String, value: Int) {
        guard case .loaded(var data) = state,
              let idx = data.insights.firstIndex(where: { $0.id == id }) else { return }
        let current = data.insights[idx].feedback ?? 0
        let newValue = current == value ? 0 : value
        do {
            try env.insightsRepo.setFeedback(id: id, feedback: newValue)
        } catch {
            failedFeedbackIds.insert(id)
            return
        }
        failedFeedbackIds.remove(id)
        data.insights[idx].feedback = newValue
        state = .loaded(data)
    }

    // MARK: Weekly summary

    private nonisolated static func weeklyChanges(_ inputs: InsightsFetchInputs) throws -> [WeeklyChange] {
        let now = inputs.now
        let tz = TimeZone.current.identifier
        var out: [WeeklyChange] = []
        if let seconds = try sleepSeconds(inputs, now: now, tz: tz) {
            out.append(try makeChange(inputs, metricId: MetricID.timeAsleep, value: seconds))
        }
        if let rhr = try inputs.measurements.latestInterval(metricId: MetricID.restingHeartRate) {
            out.append(try makeChange(inputs, metricId: MetricID.restingHeartRate, value: rhr.value))
        }
        return out
    }

    /// Beyond this age, a fallback interval reading is stale enough that presenting it as
    /// "right now" would be misleading (UX-01-Insights) — the same 48h bound Home's own sleep
    /// fallback uses, defined locally since this file doesn't own `HomeScreen.swift`.
    private nonisolated static let sleepFallbackMaxAge: TimeInterval = 48 * 3_600

    private nonisolated static func sleepSeconds(_ inputs: InsightsFetchInputs, now: Date, tz: String) throws -> Double? {
        let localNight = DayAttribution.localNight(sessionEnd: now, tz: tz)
        if let session = try inputs.measurements.primarySleep(localNight: localNight) {
            return session.detail.timeAsleepSeconds ?? session.durationSeconds
        }
        if let interval = try inputs.measurements.latestInterval(metricId: MetricID.timeAsleep),
           now.timeIntervalSince(interval.endAt) <= sleepFallbackMaxAge {
            return interval.value
        }
        return nil
    }

    /// `try?`-swallowing `latestBaseline` used to make a genuine DB error look identical to
    /// "still learning your baseline" (FIX-11, mirroring `BodyViewModel`'s own OPT-018 fix) —
    /// this now throws so `fetch`'s existing `do`/`catch` renders the honest friendly-error
    /// state (BUG-14) instead.
    private nonisolated static func makeChange(_ inputs: InsightsFetchInputs, metricId: String, value: Double) throws -> WeeklyChange {
        let def = inputs.registry.definitionOrFallback(metricId)
        let baseline = try inputs.derivation.latestBaseline(metricId: metricId)
        let stillLearning = baseline?.provisional ?? true
        let position = baseline?.position(of: value)
        var delta: String?
        if inputs.depth.showsPowerDetail, let b = baseline, !stillLearning {
            delta = signedDelta(inputs, metricId: metricId, value: value, center: b.center)
        }
        let consistency = baseline.map { consistencyText(inputs, nPoints: $0.nPoints, windowDays: $0.windowDays) }
        return WeeklyChange(
            metricId: metricId,
            familySymbol: def.familyGroup.symbolName,
            label: def.label(depth: inputs.depth, language: inputs.language),
            position: stillLearning ? nil : position,
            stillLearning: stillLearning,
            valueText: inputs.format.full(metricId: metricId, canonicalValue: value),
            deltaText: delta,
            consistencyText: consistency
        )
    }

    /// A free, already-computed positive-framing signal: how many of the baseline's window days
    /// actually had data. Never comparative, never "good/bad" — just a count.
    private nonisolated static func consistencyText(_ inputs: InsightsFetchInputs, nPoints: Int, windowDays: Int) -> String {
        "\(inputs.format.integer(nPoints))/\(inputs.format.integer(windowDays)) \(InsightsLoc.daysLogged.resolved(inputs.language))"
    }

    private nonisolated static func signedDelta(_ inputs: InsightsFetchInputs, metricId: String, value: Double, center: Double) -> String {
        let delta = value - center
        let sign = delta >= 0 ? "+" : "\u{2212}"
        let magnitude = inputs.format.full(metricId: metricId, canonicalValue: abs(delta))
        return "\(sign)\(magnitude) \u{00B7} \(InsightsLoc.vsUsual.resolved(inputs.language))"
    }
}

// MARK: - Strings (bilingual, wellness-safe)

private enum InsightsLoc {
    // FIX-05: this card reads a single latest value per metric, not an aggregated week — "This
    // week" implied a weekly rollup that was never actually computed. Retitled to an honest
    // point-in-time label rather than building real week aggregation.
    static let weeklyTitle = LocalizedString(en: "Right now", ar: "الآن")
    static let weeklySubtitle = LocalizedString(
        en: "Your latest reading against your usual range, for sleep and resting heart rate for now.",
        ar: "أحدث قراءة لديك مقارنةً بنطاقك المعتاد، للنوم ومعدل ضربات القلب أثناء الراحة حالياً.")
    static let feedTitle = LocalizedString(en: "Recent insights", ar: "أحدث الملاحظات")
    static let helpful = LocalizedString(en: "Was this helpful?", ar: "هل كان هذا مفيداً؟")
    static let thumbsUp = LocalizedString(en: "Helpful", ar: "مفيد")
    static let thumbsDown = LocalizedString(en: "Not helpful", ar: "غير مفيد")
    static let feedbackFailed = LocalizedString(
        en: "Couldn't save that — please try again.",
        ar: "تعذّر الحفظ — يرجى المحاولة مرة أخرى.")
    static let whyTitle = LocalizedString(en: "Why am I seeing this?", ar: "لماذا أرى هذا؟")
    static let templateLabel = LocalizedString(en: "Rule used", ar: "القاعدة المستخدمة")
    static let generatedLabel = LocalizedString(en: "Generated", ar: "تاريخ الإنشاء")
    static let vsUsual = LocalizedString(en: "vs your usual", ar: "مقارنةً بالمعتاد")
    static let daysLogged = LocalizedString(en: "days logged", ar: "أيام مسجّلة")
    static let emptyTitle = LocalizedString(en: "No insights yet", ar: "لا ملاحظات بعد")
    static let emptyMessage = LocalizedString(
        en: "As your data builds up, gentle observations will appear here.",
        ar: "مع تراكم بياناتك، ستظهر هنا ملاحظات لطيفة.")
    static let footerNote = LocalizedString(
        en: "Insights are worked out on your device with fixed rules — no AI, and nothing leaves your phone. Feedback you give is saved on your device but doesn't change what's shown yet.",
        ar: "تُحسَب الملاحظات على جهازك بقواعد ثابتة — بلا ذكاء اصطناعي، ولا يغادر أي شيء هاتفك. ملاحظاتك (الإعجاب/عدمه) تُحفظ على جهازك، لكنها لا تغيّر ما يظهر لك حالياً.")
}
