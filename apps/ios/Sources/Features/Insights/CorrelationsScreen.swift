import SwiftUI
import Observation

// MARK: - Read model

/// One behaviour x score pair as the list renders it.
///
/// **`card` and `finding` are the same computation, twice presented.** The casual sentence, the
/// power numbers and the confidence word are all derived from `finding` — there is no second query,
/// no second statistic and no rounding done twice (D-5). A suppressed pair has no `finding` at all,
/// which is the point of suppression: below the gates there is nothing to show, so there is nothing
/// stored on the row for a future view to reach for.
struct CorrelationRow: Identifiable, Hashable {
    let metricId: String
    let behaviorId: String
    let scoreId: String
    let behaviorName: LocalizedString
    let scoreName: LocalizedString
    let card: CorrelationRenderer.Card
    /// Present for a computed finding; nil for a suppressed pair.
    let finding: CorrelationFinding?

    var id: String { metricId }
    var isSuppressed: Bool { card.isSuppressed }
}

/// Everything the correlations surface shows: the findings, the pairs that are not eligible yet, and
/// the published gates behind that split.
struct CorrelationsReadModel: Hashable {
    var findings: [CorrelationRow]
    var notYet: [CorrelationRow]
    var minObservedDays: Int
    var minDaysPerArm: Int

    var isEmpty: Bool { findings.isEmpty && notYet.isEmpty }
}

// MARK: - Presentation (pure, testable)

/// The pure mapping from a finding to the words and spoken numbers the cards use. Extracted from the
/// views so the honesty rules here — one confidence value behind both altitudes, a spelled-out
/// reading of every number for VoiceOver (§16: "numbers spelled out for VO") — are unit-tested
/// without standing up a view.
enum CorrelationsPresentation {

    /// The casual altitude's confidence vocabulary. Three bands over the SAME `confidence` value
    /// power mode prints as a number, so the word and the number can never disagree — the word is
    /// a reading of the number, not a second judgement of the finding.
    ///
    /// It is deliberately not a p-value and must never be worded as one: `CorrelationMath.confidence`
    /// is sample size x interval precision, a display weight, and calling it "significance" would
    /// claim a test that was never run.
    enum ConfidenceWord: String, Hashable, CaseIterable {
        case early, moderate, established

        var label: LocalizedString {
            switch self {
            case .early: return LocalizedString(en: "Early estimate", ar: "تقدير مبدئي")
            case .moderate: return LocalizedString(en: "Moderate confidence", ar: "ثقة متوسطة")
            case .established: return LocalizedString(en: "Well supported", ar: "مدعوم جيداً")
            }
        }
    }

    static func confidenceWord(_ confidence: Double) -> ConfidenceWord {
        if confidence < 1.0 / 3.0 { return .early }
        if confidence < 2.0 / 3.0 { return .moderate }
        return .established
    }

    /// Two decimals with a real minus sign (U+2212) instead of an ASCII hyphen. VoiceOver reads the
    /// hyphen as a dash or skips it, so "−0.42" is spoken as "minus zero point four two" where
    /// "-0.42" may be read as "0.42" — on the one number that carries the direction of a finding.
    static func signedNumber(_ value: Double) -> String {
        CorrelationRenderer.twoDecimals(value).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    /// The spoken form of the power line. The rendered `powerText` is a dense
    /// "n = 18 (11 with / 7 without) · Cliff's delta 0.42 · 95% CI [0.10, 0.71] …" — accurate to
    /// read, hostile to hear. This says the same numbers as sentences, in the same order, from the
    /// same finding.
    static func spokenPowerDetail(_ finding: CorrelationFinding, language: AppLanguage) -> String {
        let n = "\(finding.nObserved)"
        let with = "\(finding.nWith)"
        let without = "\(finding.nWithout)"
        let delta = signedNumber(finding.delta)
        let low = signedNumber(finding.ciLow)
        let high = signedNumber(finding.ciHigh)
        let confidence = CorrelationRenderer.twoDecimals(finding.confidence)
        let template = LocalizedString(
            en: "Based on {n} logged days: {with} with, {without} without. Effect size {delta} on a scale from minus 1 to plus 1. The 95 percent range runs from {low} to {high}. Confidence {confidence} out of 1.",
            ar: "بناءً على {n} يوماً مسجّلاً: {with} مع و{without} بدون. حجم الأثر {delta} على مقياس من سالب 1 إلى موجب 1. ويمتد نطاق 95 بالمئة من {low} إلى {high}. الثقة {confidence} من 1.")
        return template.filling([
            "n": n, "with": with, "without": without, "delta": delta,
            "low": low, "high": high, "confidence": confidence,
        ]).resolved(language)
    }

    /// The whole card as one VoiceOver phrase: the sentence, the confidence word, the numbers (power
    /// only) and — always — the association-not-cause line. The locked line is inside the spoken
    /// label rather than a separate stop, so it cannot be swiped past.
    static func spokenCard(_ row: CorrelationRow, depth: DepthPolicy, language: AppLanguage) -> String {
        var parts = [row.card.casualText.resolved(language)]
        if let finding = row.finding {
            parts.append(confidenceWord(finding.confidence).label.resolved(language))
        }
        if let contextNote = row.card.contextNote {
            parts.append(contextNote.resolved(language))
        }
        if depth.showsPowerDetail, let finding = row.finding {
            parts.append(spokenPowerDetail(finding, language: language))
        }
        parts.append(row.card.associationNotCause.resolved(language))
        return parts.joined(separator: " ")
    }

    /// Build the list from the engine's outcomes.
    ///
    /// **Ordering is alphabetical by behaviour, never by effect size.** Ranking the strongest
    /// association first would turn the screen into a leaderboard of whichever comparison happened
    /// to land hardest this week, which is the reading this epic exists to refuse; a stable order
    /// also means a finding doesn't move under the reader's thumb between opens. The "not yet" pairs
    /// are a separate section rather than greyed-out rows, so a shortfall is never one glance away
    /// from being mistaken for a weak result.
    static func build(outcomes: [CorrelationOutcome], behaviors: BehaviorDictionary,
                      registry: MetricRegistry, templates: InsightTemplateStore,
                      params: CorrelationSpec.Params) -> CorrelationsReadModel {
        var findings: [CorrelationRow] = []
        var notYet: [CorrelationRow] = []
        for outcome in outcomes {
            let behaviorId: String
            let scoreId: String
            switch outcome {
            case let .finding(f): behaviorId = f.behaviorId; scoreId = f.scoreId
            case let .suppressed(s): behaviorId = s.behaviorId; scoreId = s.scoreId
            }
            let behaviorName = behaviors.displayName(forId: behaviorId, customLabel: nil)
            let scoreName = registry.definitionOrFallback(scoreId).displayName
            let card = CorrelationRenderer.render(outcome, behavior: behaviorName, score: scoreName,
                                                  templates: templates, params: params)
            let row = CorrelationRow(
                metricId: card.metricId, behaviorId: behaviorId, scoreId: scoreId,
                behaviorName: behaviorName, scoreName: scoreName, card: card,
                finding: outcome.finding)
            if row.isSuppressed { notYet.append(row) } else { findings.append(row) }
        }
        return CorrelationsReadModel(
            findings: sorted(findings), notYet: sorted(notYet),
            minObservedDays: params.minObservedDays, minDaysPerArm: params.minDaysPerArm)
    }

    private static func sorted(_ rows: [CorrelationRow]) -> [CorrelationRow] {
        rows.sorted {
            $0.behaviorName.en == $1.behaviorName.en
                ? $0.scoreId < $1.scoreId
                : $0.behaviorName.en < $1.behaviorName.en
        }
    }
}

// MARK: - View model

/// Everything the fetch core needs off the main actor (PERF-01), mirroring `HealthMonitorFetchInputs`.
struct CorrelationsFetchInputs {
    var journal: JournalRepository
    var derivation: DerivationRepository
    var correlations: CorrelationRepository
    var behaviors: BehaviorDictionary
    var registry: MetricRegistry
    var templates: InsightTemplateStore
    var clock: Clock
    var deviceId: String
    var now: Date
    var tz: String
}

@Observable
@MainActor
final class CorrelationsViewModel {
    var state: LoadState<CorrelationsReadModel> = .loading

    func load(_ env: AppEnvironment) async {
        let inputs = CorrelationsFetchInputs(
            journal: env.journal, derivation: env.derivation, correlations: env.correlations,
            behaviors: .shared, registry: env.registry, templates: env.templates,
            clock: env.clock, deviceId: env.deviceId, now: env.now(),
            tz: TimeZone.current.identifier)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let model) where model.isEmpty:
            state = .empty(env.s(CorrelationsStrings.emptyTitle))
        case .success(let model):
            state = .loaded(model)
        case .failure(let error):
            LoadErrorLog.log(error, screen: "Correlations")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    /// Runs the batch and maps its outcomes.
    ///
    /// **Why the screen runs the engine.** `CorrelationEngine.recompute` returns EVERY outcome —
    /// findings and suppressions alike — and suppressions are deliberately never persisted (a
    /// suppressed pair must not exist as a row some later read path could render without re-checking
    /// the gate). So "you need about six more days" can only come from a live evaluation. A nightly
    /// job is the right long-term home for the write half, and the read half would still have to run
    /// this to know what is missing. The run is idempotent — a repeat over unchanged data appends
    /// nothing — and it happens on a detached task, never on the main thread.
    nonisolated static func fetch(_ inputs: CorrelationsFetchInputs) -> Result<CorrelationsReadModel, Error> {
        let signpostState = PerformanceLog.signposter.beginInterval("CorrelationsViewModel.load")
        defer { PerformanceLog.signposter.endInterval("CorrelationsViewModel.load", signpostState) }
        do {
            let engine = CorrelationEngine(
                journal: inputs.journal, derivation: inputs.derivation, findings: inputs.correlations,
                clock: inputs.clock, deviceId: inputs.deviceId)
            let outcomes = try engine.recompute(asOf: inputs.now, tz: inputs.tz)
            return .success(CorrelationsPresentation.build(
                outcomes: outcomes, behaviors: inputs.behaviors, registry: inputs.registry,
                templates: inputs.templates, params: engine.params))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Screen

/// EPIC-29 — the correlations list. **The refusal is the product.**
///
/// Three things are on this screen that a "what affects my sleep" feature usually leaves off:
///
/// * **Below-gate pairs are shown as shortfalls, not teasers.** A behaviour with nine logged days
///   gets "about five more days would let this be looked at" and no number, no bar, no direction.
/// * **"No clear association" is a result.** It is rendered in the findings section with the same
///   weight as a positive one, because a list that only ever contains hits is a slot machine.
/// * **"Association, not cause" is on every card**, in both languages, including the shortfall
///   cards — `CorrelationRenderer` attaches it to every outcome it can produce, so no caller can
///   forget it.
///
/// Casual is one sentence plus a confidence word. Power adds n, the effect size and the interval as
/// numbers. Both read the same `CorrelationFinding` (D-5) — there is no second computation for the
/// detailed view, which is what stops the two altitudes from ever disagreeing.
struct CorrelationsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = CorrelationsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if env.profile.sensitiveModulesEnabled {
                    StatefulContainer(
                        vm.state,
                        emptyIcon: "chart.dots.scatter",
                        retryTitle: env.s(LoadErrorCopy.retry),
                        onRetry: { Task { await vm.load(env) } }
                    ) { model in
                        loaded(model)
                    }
                    if case .empty = vm.state { emptyGuidance }
                    footer
                } else {
                    sensitiveOffCard
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(CorrelationsStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: CorrelationsLoadKey(profile: env.profile, generation: env.dataGeneration)) {
            guard env.profile.sensitiveModulesEnabled else { return }
            await vm.load(env)
        }
    }

    private func loaded(_ model: CorrelationsReadModel) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            Text(CorrelationsStrings.subtitle, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.findings.isEmpty {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(CorrelationsStrings.findingsHeader, language: env.language)
                    ForEach(model.findings) { row in
                        CorrelationCard(row: row)
                    }
                }
            }

            if !model.notYet.isEmpty {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(CorrelationsStrings.notYetHeader, language: env.language)
                    Text(gateText(model))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(model.notYet) { row in
                        CorrelationCard(row: row)
                    }
                }
            }
        }
    }

    /// The published gates, stated as numbers. Plan §16's mitigation for overtrust is "minimum-n
    /// gate copy" — the rule is on screen, not only in a doc, so a reader can check the app against
    /// its own promise.
    private func gateText(_ model: CorrelationsReadModel) -> String {
        env.s(CorrelationsStrings.gateNote.filling([
            "n": env.format.integer(model.minObservedDays),
            "arm": env.format.integer(model.minDaysPerArm),
        ]))
    }

    private var emptyGuidance: some View {
        Text(CorrelationsStrings.emptyMessage, language: env.language)
            .font(BadanFont.body)
            .foregroundStyle(BadanColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "lock.shield")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(CorrelationsStrings.methodNote, language: env.language)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BadanSpace.space1)
    }

    private var sensitiveOffCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(JournalStrings.sensitiveOffTitle, language: env.language)
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CorrelationsStrings.sensitiveOffMessage, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CorrelationsLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

// MARK: - Entry point

/// The Insights-feed row that opens the correlations list.
///
/// Sensitive-gated at the entry point, not only inside the screen: the row's own subtitle names what
/// the surface is about ("behaviours you tag"), so showing it while sensitive records are off would
/// advertise the family the toggle exists to hide.
struct CorrelationsEntryCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.profile.sensitiveModulesEnabled {
            NavigationLink { CorrelationsScreen() } label: {
                BadanCard {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "chart.dots.scatter")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(BadanColor.primary)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CorrelationsStrings.title, language: env.language)
                                .font(BadanFont.bodyCompact.weight(.medium))
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(CorrelationsStrings.openSubtitle, language: env.language)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - One card

private struct CorrelationCard: View {
    @Environment(AppEnvironment.self) private var env
    let row: CorrelationRow

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                header
                Text(row.card.casualText, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let contextNote = row.card.contextNote {
                    Text(contextNote, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if env.depth.showsPowerDetail, let powerText = row.card.powerText {
                    powerLine(powerText)
                }

                Rectangle().fill(BadanColor.separator).frame(height: 1)

                // The locked line. Not conditional, not a caller's choice: a card without it reads
                // as causal, which is the single failure this epic exists to prevent.
                Text(row.card.associationNotCause, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // One VoiceOver stop per card, read as a phrase, with the locked line inside it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CorrelationsPresentation.spokenCard(row, depth: env.depth, language: env.language))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            Image(systemName: row.isSuppressed ? "hourglass" : "chart.dots.scatter")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(row.isSuppressed ? BadanColor.textSecondary : BadanColor.primary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.behaviorName, language: env.language)
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Text(row.scoreName, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            if let chip = confidenceChip { chip }
        }
    }

    /// The casual altitude's whole quantitative vocabulary: one word, read off the same confidence
    /// value power mode prints. Absent on a suppressed card — there is no confidence in a comparison
    /// that was never made.
    private var confidenceChip: StatusChip? {
        guard let finding = row.finding else { return nil }
        let word = CorrelationsPresentation.confidenceWord(finding.confidence)
        return StatusChip(.info, label: env.s(word.label), language: env.language)
    }

    /// The numbers, monospaced and pinned left-to-right: an interval like "[−0.42, 0.10]" is a
    /// technical fragment, not prose, and mirroring it in Arabic would move the brackets off the
    /// bounds they belong to — the same rule `InsightsWhyDisclosure` applies to its detail rows.
    private func powerLine(_ text: LocalizedString) -> some View {
        Text(text, language: env.language)
            .font(BadanFont.caption.monospacedDigit())
            .foregroundStyle(BadanColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, .leftToRight)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Strings

/// Copy for the correlations surface. Internal so `CorrelationSurfacesTests` can assert every line
/// carries real Arabic — this is the screen where a mistranslation would misstate a statistic.
enum CorrelationsStrings {
    static let title = LocalizedString(en: "Correlations", ar: "الارتباطات")
    static let subtitle = LocalizedString(
        en: "How the days you tag line up with the next day’s scores.",
        ar: "كيف تتوافق الأيام التي تضع فيها علامات مع مؤشرات اليوم التالي.")
    static let findingsHeader = LocalizedString(en: "What your days show", ar: "ما تُظهره أيامك")
    static let notYetHeader = LocalizedString(en: "Not enough days yet", ar: "لا توجد أيام كافية بعد")
    static let gateNote = LocalizedString(
        en: "A comparison needs at least {n} logged days and at least {arm} days on each side — with the behaviour and without it. Below that, nothing is shown at all.",
        ar: "تحتاج المقارنة إلى {n} يوماً مسجّلاً على الأقل و{arm} أيام على الأقل في كل جهة — مع السلوك وبدونه. ودون ذلك لا يُعرض شيء إطلاقاً.")
    static let emptyTitle = LocalizedString(en: "Nothing to compare yet", ar: "لا شيء للمقارنة بعد")
    static let emptyMessage = LocalizedString(
        en: "Tag a few days in the journal. Once a behaviour has enough days on both sides, its comparison appears here.",
        ar: "ضع علامات على بضعة أيام في المفكرة. وحين تتوفر أيام كافية على الجهتين لأي سلوك، تظهر مقارنته هنا.")
    static let methodNote = LocalizedString(
        en: "Compared on your device with a rank-based method that assumes nothing about the shape of your scores, and an interval drawn from your own data. Nothing leaves your phone.",
        ar: "تُجرى المقارنة على جهازك بطريقة تعتمد على الترتيب ولا تفترض شيئاً عن شكل توزيع مؤشراتك، وبفاصل ثقة مُستخرج من بياناتك نفسها. ولا يغادر أي شيء هاتفك.")
    static let sensitiveOffMessage = LocalizedString(
        en: "Findings name the behaviour they’re about, so they live in the separate, purgeable store with the journal. Turn on Sensitive records in Settings to see them.",
        ar: "تذكر النتائج اسم السلوك الذي تخصّه، لذا تُحفظ في المخزن المنفصل القابل للحذف مع المفكرة. فعّل السجلات الحساسة من الإعدادات لعرضها.")
    /// The entry point on the Insights feed.
    static let openSubtitle = LocalizedString(
        en: "Behaviours you tag, against your next-day scores",
        ar: "السلوكيات التي تسجّلها مقارنةً بمؤشرات اليوم التالي")
}
