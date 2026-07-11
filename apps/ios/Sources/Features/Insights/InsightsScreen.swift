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

    var body: some View {
        StatefulContainer(vm.state) { data in
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
                                InsightsFeedCard(insight: insight) { value in
                                    vm.toggleFeedback(env, id: insight.id, value: value)
                                }
                            }
                        }
                    }

                    InsightsFooterNote()
                }
                .padding(.horizontal, BadanSpace.space4)
                .padding(.vertical, BadanSpace.space4)
            }
            .background(BadanColor.background)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.tabInsights))
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.load(env) }
    }
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
            }
            Spacer(minLength: BadanSpace.space2)
            statusChip
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
    let onFeedback: (Int) -> Void

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                sentence
                Rectangle()
                    .fill(BadanColor.separator)
                    .frame(height: 1)
                feedbackRow
                if env.depth.showsPowerDetail {
                    InsightsWhyDisclosure(insight: insight)
                }
            }
        }
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
            feedbackButton(value: 1, symbol: "hand.thumbsup", a11y: InsightsLoc.thumbsUp)
            feedbackButton(value: -1, symbol: "hand.thumbsdown", a11y: InsightsLoc.thumbsDown)
        }
    }

    private func feedbackButton(value: Int, symbol: String, a11y: LocalizedString) -> some View {
        let selected = (insight.feedback ?? 0) == value
        return Button { onFeedback(value) } label: {
            Image(systemName: selected ? symbol + ".fill" : symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                .background(Circle().fill(selected ? BadanColor.primary.opacity(0.12) : Color.clear))
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
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                detailRow(InsightsLoc.templateLabel, value: insight.templateId)
                detailRow(Loc.contributingRecords, value: env.format.integer(insight.evidenceRefs.count))
                detailRow(InsightsLoc.generatedLabel, value: generatedText)
            }
            .padding(.top, BadanSpace.space2)
        } label: {
            Text(env.s(InsightsLoc.whyTitle))
                .font(BadanFont.caption.weight(.medium))
                .foregroundStyle(BadanColor.primary)
        }
        .tint(BadanColor.primary)
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

    private var generatedText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: env.language.localeIdentifier)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: insight.generatedAt)
    }
}

// MARK: - Empty feed + footer

private struct InsightsEmptyFeed: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        BadanCard {
            EmptyStateView(
                icon: "sparkles",
                title: env.s(InsightsLoc.emptyTitle),
                message: env.s(InsightsLoc.emptyMessage)
            )
        }
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
            Text(env.s(InsightsLoc.footerNote))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
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
    var id: String { metricId }
}

private struct InsightsData {
    var weekly: [WeeklyChange]
    var insights: [Insight]
}

@Observable
@MainActor
private final class InsightsViewModel {
    var state: LoadState<InsightsData> = .loading

    func load(_ env: AppEnvironment) {
        do {
            let weekly = try Self.weeklyChanges(env)
            let insights = try env.insightsRepo.recent(limit: 20)
            if weekly.isEmpty && insights.isEmpty {
                state = .empty(env.s(InsightsLoc.emptyTitle))
            } else {
                state = .loaded(InsightsData(weekly: weekly, insights: insights))
            }
        } catch {
            state = .error(String(describing: error))
        }
    }

    /// Persist the tap, then reflect it locally. Tapping the already-selected thumb clears it.
    func toggleFeedback(_ env: AppEnvironment, id: String, value: Int) {
        guard case .loaded(var data) = state,
              let idx = data.insights.firstIndex(where: { $0.id == id }) else { return }
        let current = data.insights[idx].feedback ?? 0
        let newValue = current == value ? 0 : value
        do { try env.insightsRepo.setFeedback(id: id, feedback: newValue) } catch { return }
        data.insights[idx].feedback = newValue
        state = .loaded(data)
    }

    // MARK: Weekly summary

    private static func weeklyChanges(_ env: AppEnvironment) throws -> [WeeklyChange] {
        let now = env.now()
        let tz = TimeZone.current.identifier
        var out: [WeeklyChange] = []
        if let seconds = try sleepSeconds(env, now: now, tz: tz) {
            out.append(makeChange(env, metricId: MetricID.timeAsleep, value: seconds))
        }
        if let rhr = try env.measurements.latestInterval(metricId: MetricID.restingHeartRate) {
            out.append(makeChange(env, metricId: MetricID.restingHeartRate, value: rhr.value))
        }
        return out
    }

    private static func sleepSeconds(_ env: AppEnvironment, now: Date, tz: String) throws -> Double? {
        let localNight = DayAttribution.localNight(sessionEnd: now, tz: tz)
        if let session = try env.measurements.primarySleep(localNight: localNight) {
            return session.detail.timeAsleepSeconds ?? session.durationSeconds
        }
        if let interval = try env.measurements.latestInterval(metricId: MetricID.timeAsleep) {
            return interval.value
        }
        return nil
    }

    private static func makeChange(_ env: AppEnvironment, metricId: String, value: Double) -> WeeklyChange {
        let def = env.registry.definitionOrFallback(metricId)
        let baseline = try? env.derivation.latestBaseline(metricId: metricId)
        let stillLearning = baseline?.provisional ?? true
        let position = baseline?.position(of: value)
        var delta: String?
        if env.depth.showsPowerDetail, let b = baseline, !stillLearning {
            delta = signedDelta(env, metricId: metricId, value: value, center: b.center)
        }
        return WeeklyChange(
            metricId: metricId,
            familySymbol: def.familyGroup.symbolName,
            label: def.label(depth: env.depth, language: env.language),
            position: stillLearning ? nil : position,
            stillLearning: stillLearning,
            valueText: env.format.full(metricId: metricId, canonicalValue: value),
            deltaText: delta
        )
    }

    private static func signedDelta(_ env: AppEnvironment, metricId: String, value: Double, center: Double) -> String {
        let delta = value - center
        let sign = delta >= 0 ? "+" : "\u{2212}"
        let magnitude = env.format.full(metricId: metricId, canonicalValue: abs(delta))
        return "\(sign)\(magnitude) \u{00B7} \(env.s(InsightsLoc.vsUsual))"
    }
}

// MARK: - Strings (bilingual, wellness-safe)

private enum InsightsLoc {
    static let weeklyTitle = LocalizedString(en: "This week", ar: "هذا الأسبوع")
    static let weeklySubtitle = LocalizedString(
        en: "What changed against your usual range.",
        ar: "ما الذي تغيّر مقارنةً بنطاقك المعتاد.")
    static let feedTitle = LocalizedString(en: "Recent insights", ar: "أحدث الملاحظات")
    static let helpful = LocalizedString(en: "Was this helpful?", ar: "هل كان هذا مفيداً؟")
    static let thumbsUp = LocalizedString(en: "Helpful", ar: "مفيد")
    static let thumbsDown = LocalizedString(en: "Not helpful", ar: "غير مفيد")
    static let whyTitle = LocalizedString(en: "Why am I seeing this?", ar: "لماذا أرى هذا؟")
    static let templateLabel = LocalizedString(en: "Template", ar: "القالب")
    static let generatedLabel = LocalizedString(en: "Generated", ar: "تاريخ الإنشاء")
    static let vsUsual = LocalizedString(en: "vs your usual", ar: "مقارنةً بالمعتاد")
    static let emptyTitle = LocalizedString(en: "No insights yet", ar: "لا ملاحظات بعد")
    static let emptyMessage = LocalizedString(
        en: "As your data builds up, gentle observations will appear here.",
        ar: "مع تراكم بياناتك، ستظهر هنا ملاحظات لطيفة.")
    static let footerNote = LocalizedString(
        en: "Insights are worked out on your device with fixed rules — no AI, and nothing leaves your phone.",
        ar: "تُحسَب الملاحظات على جهازك بقواعد ثابتة — بلا ذكاء اصطناعي، ولا يغادر أي شيء هاتفك.")
}
