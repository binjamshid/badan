import Foundation

// MARK: - Metric id composition

/// The `journal.correlation.<behaviorId>.<scoreId>` id pattern (plan §11 EPIC-29), in one place.
///
/// The registry carries the NAMESPACE row (`journal.correlation`) and nothing beneath it: the
/// concrete set is a product of `behaviors.json` and `MetricID.correlatedScores`, so enumerating it
/// would add ~90 catalogue rows that never carry data and would rot the moment a behaviour is added.
/// What the namespace row fixes — unit, chart hint, bilingual name, and `sensitiveClass:
/// sensitivePlus` — applies to every id composed here.
///
/// **Parsing depends on behaviour ids containing no dot.** The score id does (`readiness.score`), so
/// the split is at the FIRST separator after the namespace: everything before it is the behaviour,
/// everything after is the score. `CorrelationEngineTests.testEveryBehaviorIdRoundTripsThroughTheIdPattern`
/// asserts that property against the shipped dictionary, so a future behaviour key with a dot in it
/// fails the suite rather than silently producing ids that parse back to the wrong pair.
public enum CorrelationMetricID {
    public static let namespace = MetricID.journalCorrelationNamespace
    private static let prefix = namespace + "."

    /// `journal.correlation.<behaviorId>.<scoreId>`.
    public static func metricId(behaviorId: String, scoreId: String) -> String {
        prefix + behaviorId + "." + scoreId
    }

    /// The pair a finding id names, or nil if `metricId` is not one of ours. Nil is a normal answer
    /// (every other metric in the registry returns it), never an error.
    public static func parse(_ metricId: String) -> (behaviorId: String, scoreId: String)? {
        guard metricId.hasPrefix(prefix) else { return nil }
        let rest = String(metricId.dropFirst(prefix.count))
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let behaviorId = String(rest[rest.startIndex..<dot])
        let scoreId = String(rest[rest.index(after: dot)...])
        guard !behaviorId.isEmpty, !scoreId.isEmpty else { return nil }
        return (behaviorId, scoreId)
    }

    /// Whether an id belongs to this family. The one predicate any sensitivity or export gate
    /// should ask, because `MetricRegistry.definition(_:)` returns nil for a composed id (only the
    /// namespace row exists) and a nil sensitiveClass reads as "not sensitive" — which for THIS
    /// family would be exactly backwards.
    public static func isCorrelationMetricId(_ metricId: String) -> Bool {
        parse(metricId) != nil
    }
}

// MARK: - Spec (published constants)

/// The data-driven correlation parameters, resolved once from `journal.correlation` in
/// `algorithms.json`. This is the only place the gates, the bootstrap settings and the effect-size
/// thresholds enter the engine — never a literal below — so the two platforms cannot drift and a
/// change is a reviewable contract diff plus a semver bump (plan §15).
///
/// A spec that failed to load (`isLoaded == false`) makes the engine compute NOTHING rather than
/// fall back to invented constants. For this engine that rule matters more than most: the constants
/// ARE the honesty guarantee, and a finding computed from a default `minObservedDays` nobody
/// published would be indistinguishable, on the stored row, from a gated one.
struct CorrelationSpec: Sendable, Hashable {
    let algorithm: AlgorithmVersion
    let params: Params
    let isLoaded: Bool

    struct Params: Sendable, Hashable {
        let lookbackDays: Int
        /// MANDATORY GATE. Minimum paired days (both arms together).
        let minObservedDays: Int
        /// MANDATORY GATE. Minimum days in EACH arm.
        let minDaysPerArm: Int
        let bootstrapIterations: Int
        let bootstrapSeed: UInt64
        let ciLowerPercentile: Double
        let ciUpperPercentile: Double
        let negligibleDeltaThreshold: Double
        let smallDeltaThreshold: Double
        let mediumDeltaThreshold: Double
        let confidenceFullNDays: Double
        /// True while the contract entry is `provisional` — carried onto every row this engine writes.
        let algorithmProvisional: Bool
    }

    static let algorithmId = "journal.correlation"

    static let defaultShared: CorrelationSpec = .load(AlgorithmRegistry.shared)

    static func load(_ registry: AlgorithmRegistry) -> CorrelationSpec {
        guard let definition = registry.definition(algorithmId) else {
            return CorrelationSpec(
                algorithm: AlgorithmVersion(algorithmId: algorithmId, semver: "0", introducedIn: "0"),
                params: Params(lookbackDays: 0, minObservedDays: .max, minDaysPerArm: .max,
                               bootstrapIterations: 0, bootstrapSeed: 0,
                               ciLowerPercentile: 0, ciUpperPercentile: 0,
                               negligibleDeltaThreshold: 0, smallDeltaThreshold: 0,
                               mediumDeltaThreshold: 0, confidenceFullNDays: 0,
                               algorithmProvisional: true),
                isLoaded: false)
        }
        let p = definition.params
        // A missing gate resolves to `Int.max`, not to a permissive default: if the contract loses
        // `minObservedDays`, every behaviour is suppressed and nothing is published — the safe
        // direction to fail in for a feature whose value is refusing to speak on thin evidence.
        return CorrelationSpec(
            algorithm: definition.algorithmVersion,
            params: Params(
                lookbackDays: Int(p["lookbackDays"] ?? 0),
                minObservedDays: p["minObservedDays"].map { Int($0) } ?? .max,
                minDaysPerArm: p["minDaysPerArm"].map { Int($0) } ?? .max,
                bootstrapIterations: Int(p["bootstrapIterations"] ?? 0),
                bootstrapSeed: UInt64(max(0, p["bootstrapSeed"] ?? 0)),
                ciLowerPercentile: p["ciLowerPercentile"] ?? 0,
                ciUpperPercentile: p["ciUpperPercentile"] ?? 0,
                negligibleDeltaThreshold: p["negligibleDeltaThreshold"] ?? 0,
                smallDeltaThreshold: p["smallDeltaThreshold"] ?? 0,
                mediumDeltaThreshold: p["mediumDeltaThreshold"] ?? 0,
                confidenceFullNDays: p["confidenceFullNDays"] ?? 0,
                algorithmProvisional: definition.provisional),
            isLoaded: true)
    }
}

// MARK: - Inputs

/// One local day as the engine sees it: was the behaviour logged, what did the NEXT day's score
/// read, and did the day fall inside a declared context interval.
///
/// A day only exists here if the user journaled on it at all. That rule is the difference between
/// an honest comparison and an invented one: a day with no journal activity is not evidence the
/// behaviour was absent, it is evidence of nothing, and quietly filing it in the "without" arm
/// would manufacture an arm out of days the user simply did not open the app.
struct CorrelationDay: Sendable, Hashable {
    let dayKey: String
    /// True when the behaviour was asserted that day (`JournalEntry.isPresent` — an explicit 0
    /// count is an assertion it did NOT happen, and lands in the "without" arm).
    let present: Bool
    /// The next local day's score. Nil days are dropped BEFORE the gates are evaluated, so the
    /// counts the gates judge are the counts that actually feed the comparison.
    let nextDayScore: Double?
    /// Whether a `ContextStatus` was in force. Disclosure only — never a reason to drop the day.
    let inDeclaredContext: Bool
    /// The `DerivedValue.id` of the next-day score, for the input manifest (I1 lineage).
    let nextDayScoreRecordId: String

    init(dayKey: String, present: Bool, nextDayScore: Double?,
         inDeclaredContext: Bool = false, nextDayScoreRecordId: String = "") {
        self.dayKey = dayKey
        self.present = present
        self.nextDayScore = nextDayScore
        self.inDeclaredContext = inDeclaredContext
        self.nextDayScoreRecordId = nextDayScoreRecordId
    }
}

// MARK: - Outcome types

/// Why a behaviour x score pair produced no finding. Suppression is a first-class, *displayable*
/// outcome carrying the shortfall — "come back in about 6 days" — never a silent skip and never a
/// finding with a warning label on it.
enum CorrelationSuppressionReason: Sendable, Hashable {
    /// Fewer than `minObservedDays` paired days in total.
    case tooFewObservedDays(moreDaysNeeded: Int)
    /// Enough days overall, fewer than `minDaysPerArm` days WITH the behaviour.
    case tooFewDaysWithBehavior(moreDaysNeeded: Int)
    /// Enough days overall, fewer than `minDaysPerArm` days WITHOUT it.
    case tooFewDaysWithoutBehavior(moreDaysNeeded: Int)

    var moreDaysNeeded: Int {
        switch self {
        case let .tooFewObservedDays(n), let .tooFewDaysWithBehavior(n), let .tooFewDaysWithoutBehavior(n):
            return n
        }
    }
}

struct CorrelationSuppression: Sendable, Hashable {
    let behaviorId: String
    let scoreId: String
    let nObserved: Int
    let nWith: Int
    let nWithout: Int
    let reason: CorrelationSuppressionReason
}

/// Which way the next-day score leaned, once the interval has had its say. `.noClearAssociation` is
/// a RESULT, not an absence of one: the comparison ran, it cleared both gates, and the interval
/// straddles zero.
enum CorrelationDirection: String, Sendable, Hashable {
    case higher, lower, noClearAssociation
}

/// Effect-size wording, from the published Cliff's-delta thresholds (Romano et al. 2006). Used for
/// the strength word only — never to decide whether a finding is shown, which is the interval's job.
enum CorrelationMagnitude: String, Sendable, Hashable {
    case negligible, small, medium, large

    var displayLabel: LocalizedString {
        switch self {
        case .negligible: return LocalizedString(en: "negligible", ar: "ضئيل")
        case .small: return LocalizedString(en: "small", ar: "صغير")
        case .medium: return LocalizedString(en: "moderate", ar: "متوسط")
        case .large: return LocalizedString(en: "large", ar: "كبير")
        }
    }
}

/// One computed association. Everything a card needs at either altitude — the casual sentence and
/// the power-mode numbers are rendered from THIS struct, so there is one computation and two
/// presentations rather than two code paths that can disagree (D-5).
struct CorrelationFinding: Sendable, Hashable {
    let behaviorId: String
    let scoreId: String
    /// Paired days that fed the comparison (`nWith + nWithout`).
    let nObserved: Int
    let nWith: Int
    let nWithout: Int
    /// Cliff's delta. Positive = the next-day score ran HIGHER after the behaviour.
    let delta: Double
    let ciLow: Double
    let ciHigh: Double
    /// Arm medians, kept for the anatomy sheet. Medians rather than means, for the same reason the
    /// effect size is non-parametric: one atypical night should not move the summary of an arm.
    let medianWith: Double
    let medianWithout: Double
    /// Days inside a declared `ContextStatus`. Disclosed and confidence-capped; never removed.
    let contextDays: Int
    let confidence: Double
    let provisional: Bool
    let firstDayKey: String
    let lastDayKey: String

    var metricId: String { CorrelationMetricID.metricId(behaviorId: behaviorId, scoreId: scoreId) }

    /// `window:<first>..<last>`. A correlation describes a SPAN of days, so it cannot honestly be
    /// keyed `day:` — and the span is in the key rather than only in the manifest so two findings
    /// over different windows are different rows rather than one overwriting the other on read.
    var periodKey: String { "window:\(firstDayKey)..\(lastDayKey)" }

    /// The interval decides the direction, not the point estimate. A delta of −0.4 with an interval
    /// from −0.8 to +0.1 is "no clear association", and rendering it as "lower" because the centre
    /// happens to be negative is the exact failure this engine exists to refuse.
    var direction: CorrelationDirection {
        if ciLow > 0 { return .higher }
        if ciHigh < 0 { return .lower }
        return .noClearAssociation
    }

    var spansZero: Bool { direction == .noClearAssociation }

    func magnitude(params: CorrelationSpec.Params) -> CorrelationMagnitude {
        let magnitude = abs(delta)
        if magnitude < params.negligibleDeltaThreshold { return .negligible }
        if magnitude < params.smallDeltaThreshold { return .small }
        if magnitude < params.mediumDeltaThreshold { return .medium }
        return .large
    }
}

enum CorrelationOutcome: Sendable, Hashable {
    case finding(CorrelationFinding)
    case suppressed(CorrelationSuppression)

    var finding: CorrelationFinding? {
        if case let .finding(f) = self { return f }
        return nil
    }

    var suppression: CorrelationSuppression? {
        if case let .suppressed(s) = self { return s }
        return nil
    }
}

// MARK: - The statistics

/// The non-parametric core: Cliff's delta and a percentile bootstrap, and deliberately nothing else.
///
/// **Why no t-test, anywhere.** The samples this runs on are two handfuls of daily scores — often 7
/// against 9 — drawn from bounded, skewed distributions (a readiness score is capped at 100 and
/// piles up near a person's own typical band). A t-test would assume approximate normality and
/// report a precise-looking p-value computed from a shape the data does not have. Cliff's delta
/// assumes only that the values can be ORDERED, which is exactly what is true of them, and the
/// bootstrap gets its interval from the data instead of from a table.
///
/// Everything here is `static` and pure so the Kotlin mirror computes byte-identical numbers from
/// the same inputs — asserted from a shared fixture on both platforms.
enum CorrelationMath {

    /// Cliff's delta: P(x > y) − P(x < y) over all pairs, where x is drawn from the
    /// behaviour-present arm and y from the behaviour-absent arm.
    ///
    /// Positive means the next-day score tended to be HIGHER after the behaviour. Ties count for
    /// neither side, which is why identical arms give exactly 0 rather than a small artefact.
    ///
    /// O(n·m) by construction rather than the sorted O(n log n) form, and the naive double loop is
    /// the definition itself — a reader can check it against the formula without trusting a rank
    /// trick, which for the one number this whole feature rests on is worth more than the
    /// asymptotics. The cost was measured rather than assumed, because this runs inside the
    /// bootstrap: the true worst case (every one of ~28 behaviours x 3 scores clearing the gates
    /// with both arms at 60 days, the most `lookbackDays` allows) is **1.1 s** in an optimised
    /// build for the whole batch. That batch has one caller — `CorrelationsViewModel.fetch`, which
    /// runs it on a detached task — so the cost is TIME TO FIRST RENDER on the correlations screen,
    /// behind its loading state, and never main-thread jank. At that latency the readable form
    /// wins; if `lookbackDays` or the behaviour vocabulary grows by an order of magnitude, measure
    /// again before assuming it still does.
    static func cliffsDelta(with: [Double], without: [Double]) -> Double {
        guard !with.isEmpty, !without.isEmpty else { return 0 }
        var greater = 0
        var less = 0
        for x in with {
            for y in without {
                if x > y { greater += 1 } else if x < y { less += 1 }
            }
        }
        return Double(greater - less) / Double(with.count * without.count)
    }

    /// The middle value (mean of the two middle values for an even count). Used for the arm
    /// summaries shown in power mode.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// splitmix64 — a small, exactly-specified 64-bit generator, written out rather than taken from
    /// either platform's standard library.
    ///
    /// The reason is the whole determinism requirement: `SystemRandomNumberGenerator` and
    /// `kotlin.random.Random` produce different sequences from the same seed, so a bootstrap built
    /// on either would give iOS and Android different intervals for identical data — and a
    /// "confidence interval" that depends on which phone you hold is not one. splitmix64 is
    /// arithmetic only (wrapping multiply, xor, logical shift), so the Kotlin mirror using `Long`
    /// with `ushr` produces the identical bit sequence.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform index in `0..<count`. The high 31 bits are used (`>> 33`) because splitmix64's
        /// low bits are the weakest, and a plain modulo of the full word would also overflow the
        /// `Int` conversion on the Kotlin side.
        mutating func index(upperBound count: Int) -> Int {
            guard count > 0 else { return 0 }
            return Int(next() >> 33) % count
        }
    }

    /// Percentile-method bootstrap interval for Cliff's delta.
    ///
    /// Stratified: each arm is resampled with replacement to its OWN original size, so the
    /// with/without balance of the real sample is preserved in every resample — pooling and
    /// re-splitting would silently answer a different question.
    ///
    /// The draw order is fixed (all "with" draws, then all "without" draws, per iteration) and the
    /// seed is a published constant, so the interval is a pure function of the inputs: the same
    /// data gives the same interval on a recompute, on the other platform, forever. That is why the
    /// generator is threaded through explicitly rather than being a global.
    ///
    /// Index rule, part of the cross-platform contract (see `docs/algorithms/correlations.md`):
    /// with B sorted resample deltas, the bounds are `sorted[floor(lo·B)]` and
    /// `sorted[min(B−1, ceil(hi·B) − 1)]`. Written out rather than "the 2.5th percentile" because
    /// percentile definitions differ between libraries and this one has to be reproducible by hand.
    static func bootstrapInterval(with: [Double], without: [Double],
                                  params: CorrelationSpec.Params) -> (low: Double, high: Double) {
        let iterations = params.bootstrapIterations
        guard iterations > 0, !with.isEmpty, !without.isEmpty else {
            let point = cliffsDelta(with: with, without: without)
            return (point, point)
        }

        var rng = SplitMix64(seed: params.bootstrapSeed)
        var deltas = [Double]()
        deltas.reserveCapacity(iterations)
        var sampleWith = [Double](repeating: 0, count: with.count)
        var sampleWithout = [Double](repeating: 0, count: without.count)

        for _ in 0..<iterations {
            for i in 0..<with.count { sampleWith[i] = with[rng.index(upperBound: with.count)] }
            for i in 0..<without.count { sampleWithout[i] = without[rng.index(upperBound: without.count)] }
            deltas.append(cliffsDelta(with: sampleWith, without: sampleWithout))
        }

        deltas.sort()
        let lowIndex = min(iterations - 1, max(0, Int((params.ciLowerPercentile * Double(iterations)).rounded(.down))))
        let highIndex = min(iterations - 1, max(0, Int((params.ciUpperPercentile * Double(iterations)).rounded(.up)) - 1))
        return (deltas[lowIndex], deltas[max(lowIndex, highIndex)])
    }

    /// How much weight the finding may claim, as two published factors multiplied:
    ///
    /// * `sampleFactor` — paired days over `confidenceFullNDays`, capped at 1. More days, more
    ///   weight, saturating rather than growing forever.
    /// * `precisionFactor` — `1 − width/2`, where 2 is the full range Cliff's delta can span. A
    ///   near-total interval (−1…+1) earns nothing; a tight one earns almost everything.
    ///
    /// This is NOT a p-value and must never be rendered as one. It is a display weight, and the
    /// numbers it is derived from (n, and the interval) are shown next to it in power mode so the
    /// reader can check it rather than take it on faith.
    static func confidence(nObserved: Int, ciLow: Double, ciHigh: Double,
                           params: CorrelationSpec.Params) -> Double {
        let full = params.confidenceFullNDays
        let sampleFactor = full > 0 ? min(1.0, Double(nObserved) / full) : 0
        let width = max(0, min(2, ciHigh - ciLow))
        let precisionFactor = 1 - (width / 2)
        return max(0, min(1, sampleFactor * precisionFactor))
    }
}

// MARK: - The engine

/// EPIC-29 — the journal correlation engine. **Its product is the refusal, not the finding.**
///
/// Anyone can compute a difference between two groups of days. What makes this shippable is what it
/// declines to say: below the published minimum-n gates it emits NOTHING (suppressed, with the
/// shortfall named), and above them an interval that straddles zero is reported as "no clear
/// association" rather than quietly dropped so the list only ever contains hits. A correlations
/// screen that only shows hits is a slot machine with a health theme.
///
/// **What it computes.** For each behaviour the user has logged and each of `MetricID.correlatedScores`:
/// split the days the user actually journaled into behaviour-present and behaviour-absent arms,
/// take the NEXT day's score for each, and compare the two distributions with Cliff's delta plus a
/// percentile bootstrap interval (`CorrelationMath`). Next-day and not same-day, because the
/// behaviours in `behaviors.json` are things that happen during a day and the score they could
/// plausibly line up with is the one computed from the night that follows.
///
/// **I7.** Findings are written to the SENSITIVE database through `CorrelationRepository`, not to
/// `badan.db`. The metric id itself names the behaviour, so the row is as lifestyle-revealing as the
/// journal entry it came from, and it has to live where "turn this off" is a file deletion. This
/// engine holds no main-database connection at all, which is what makes that structural rather than
/// a rule someone has to remember.
///
/// **Rendering.** `CorrelationRenderer` builds `CorrelationRenderer.Card` values through the shared
/// `InsightTemplateStore` and `InsightEngine.fill` — the same templates file and the same
/// `{placeholder}` substitution the status-explanation path uses, extending that path rather than
/// forking a second one. A `Card` rather than a stored `Insight` on purpose: no correlation sentence
/// is written to the main `insights` table, because the rendered text names the behaviour and
/// storing it in `badan.db` would leak through the front door what putting the findings in the
/// sensitive database closed the back one on.
final class CorrelationEngine {
    private let journal: JournalRepository
    private let derivation: DerivationRepository
    private let findings: CorrelationRepository
    private let clock: Clock
    private let deviceId: String
    private let spec: CorrelationSpec

    init(journal: JournalRepository, derivation: DerivationRepository,
         findings: CorrelationRepository, clock: Clock, deviceId: String,
         spec: CorrelationSpec = .defaultShared) {
        self.journal = journal
        self.derivation = derivation
        self.findings = findings
        self.clock = clock
        self.deviceId = deviceId
        self.spec = spec
    }

    var algorithm: AlgorithmVersion { spec.algorithm }
    var params: CorrelationSpec.Params { spec.params }

    // MARK: Pure evaluation

    /// The whole decision, as a pure function of the days — no clock, no storage, no I/O. Both
    /// platforms' goldens call exactly this, which is what makes "identical across platforms" a
    /// property that can be asserted rather than hoped for.
    ///
    /// Order of operations is load-bearing and is the same order the doc publishes:
    /// 1. drop days with no next-day score (they can pair with nothing);
    /// 2. split into arms;
    /// 3. **check the gates** — and stop here if either fails;
    /// 4. only then compute an effect size.
    ///
    /// Computing first and gating afterwards would produce the same visible result today and a
    /// tempting `if showAnyway` tomorrow.
    static func evaluate(behaviorId: String, scoreId: String,
                         days: [CorrelationDay], spec: CorrelationSpec) -> CorrelationOutcome {
        let paired = days.filter { $0.nextDayScore != nil }.sorted { $0.dayKey < $1.dayKey }
        let withDays = paired.filter(\.present)
        let withoutDays = paired.filter { !$0.present }
        let p = spec.params

        if !spec.isLoaded || paired.count < p.minObservedDays {
            return .suppressed(CorrelationSuppression(
                behaviorId: behaviorId, scoreId: scoreId, nObserved: paired.count,
                nWith: withDays.count, nWithout: withoutDays.count,
                reason: .tooFewObservedDays(moreDaysNeeded: max(0, p.minObservedDays - paired.count))))
        }
        if withDays.count < p.minDaysPerArm {
            return .suppressed(CorrelationSuppression(
                behaviorId: behaviorId, scoreId: scoreId, nObserved: paired.count,
                nWith: withDays.count, nWithout: withoutDays.count,
                reason: .tooFewDaysWithBehavior(moreDaysNeeded: p.minDaysPerArm - withDays.count)))
        }
        if withoutDays.count < p.minDaysPerArm {
            return .suppressed(CorrelationSuppression(
                behaviorId: behaviorId, scoreId: scoreId, nObserved: paired.count,
                nWith: withDays.count, nWithout: withoutDays.count,
                reason: .tooFewDaysWithoutBehavior(moreDaysNeeded: p.minDaysPerArm - withoutDays.count)))
        }

        // Values in day order, so the bootstrap's indexed draws are reproducible.
        let withValues = withDays.compactMap(\.nextDayScore)
        let withoutValues = withoutDays.compactMap(\.nextDayScore)

        let delta = CorrelationMath.cliffsDelta(with: withValues, without: withoutValues)
        let interval = CorrelationMath.bootstrapInterval(with: withValues, without: withoutValues, params: p)
        var confidence = CorrelationMath.confidence(nObserved: paired.count, ciLow: interval.low,
                                                    ciHigh: interval.high, params: p)

        // Context days are COUNTED and capped, never dropped. Removing a travel week would silently
        // change what the finding is about, and the resulting number would describe a life the user
        // did not live. `ContextAnnotator`'s ceiling is the single published value for this (it is
        // deliberately not re-declared in the correlation params block).
        let contextDays = paired.filter(\.inDeclaredContext).count
        if contextDays > 0 {
            confidence = min(confidence, ContextAnnotator.activeContextConfidenceCeiling)
        }

        return .finding(CorrelationFinding(
            behaviorId: behaviorId, scoreId: scoreId, nObserved: paired.count,
            nWith: withDays.count, nWithout: withoutDays.count,
            delta: delta, ciLow: interval.low, ciHigh: interval.high,
            medianWith: CorrelationMath.median(withValues),
            medianWithout: CorrelationMath.median(withoutValues),
            contextDays: contextDays, confidence: confidence,
            provisional: p.algorithmProvisional,
            firstDayKey: paired.first?.dayKey ?? "", lastDayKey: paired.last?.dayKey ?? ""))
    }

    // MARK: Batch run

    /// Recompute every behaviour x score pair over the trailing `lookbackDays` and persist the
    /// findings. Returns every outcome — suppressions included — because the correlations screen
    /// shows "not yet, about N more days" rows alongside the findings, and a caller that only saw
    /// findings would have to re-derive the shortfall itself.
    ///
    /// Suppressed pairs write NOTHING. That is the storage-level half of the small-n invariant: a
    /// suppressed finding does not exist as a row that some future read path could pick up and
    /// render without re-checking the gate.
    @discardableResult
    func recompute(asOf: Date, tz: String = TimeZone.current.identifier) throws -> [CorrelationOutcome] {
        guard spec.isLoaded, params.lookbackDays > 0 else { return [] }

        let dayEnd = DayAttribution.addingDays(1, to: DayAttribution.startOfDay(asOf, tz: tz), tz: tz)
        let windowStart = DayAttribution.addingDays(-params.lookbackDays, to: dayEnd, tz: tz)

        let entries = try journal.entries(from: windowStart, to: dayEnd)
        guard !entries.isEmpty else { return [] }
        let statuses = try journal.statuses(overlapping: windowStart, to: dayEnd)

        // Every day the user journaled at all — the observation frame. A behaviour is "absent" only
        // on a day inside this set, never on a day the app was not opened.
        let observedDayKeys = Set(entries.map { $0.dayKey() })
        let contextDayKeys = Self.contextDayKeys(observedDayKeys: observedDayKeys, statuses: statuses, tz: tz)

        // Behaviours the dictionary named. Free-text `customLabel` entries are deliberately not
        // correlated: two spellings of one habit would split into two under-powered behaviours and
        // both would be suppressed, which reads as a bug rather than as the honest statement that
        // BADAN cannot tell they are the same thing.
        let behaviorIds = Set(entries.compactMap(\.behaviorId)).sorted()
        var presentDays: [String: Set<String>] = [:]
        for entry in entries {
            guard let behaviorId = entry.behaviorId, entry.isPresent else { continue }
            presentDays[behaviorId, default: []].insert(entry.dayKey())
        }

        // The scores are read over one extra day at the end: the last journaled day pairs with the
        // day AFTER it, which is outside the journal window by construction.
        let firstScoreDayKey = DayAttribution.localDayKey(windowStart, tz: tz)
        let lastScoreDayKey = DayAttribution.localDayKey(DayAttribution.addingDays(1, to: dayEnd, tz: tz), tz: tz)

        var outcomes: [CorrelationOutcome] = []
        for scoreId in MetricID.correlatedScores {
            let scoreByDay = try dailyScores(metricId: scoreId, fromDayKey: firstScoreDayKey, toDayKey: lastScoreDayKey)
            for behaviorId in behaviorIds {
                let present = presentDays[behaviorId] ?? []
                let days = observedDayKeys.sorted().map { dayKey -> CorrelationDay in
                    let next = Self.nextDayKey(dayKey, tz: tz)
                    let score = scoreByDay[next]
                    return CorrelationDay(dayKey: dayKey, present: present.contains(dayKey),
                                          nextDayScore: score?.value,
                                          inDeclaredContext: contextDayKeys.contains(dayKey),
                                          nextDayScoreRecordId: score?.id ?? "")
                }
                let outcome = Self.evaluate(behaviorId: behaviorId, scoreId: scoreId, days: days, spec: spec)
                if let finding = outcome.finding {
                    try persist(finding, days: days)
                }
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// Latest score value per local day, keyed by day key, over the window. One read per score id
    /// rather than one per (behaviour, day) — the same rows serve every behaviour.
    ///
    /// Filtered on the day-key STRING because `"YYYY-MM-DD"` sorts lexicographically the same way
    /// the dates do; the alternative (re-deriving each row's instant from its period key) would
    /// re-parse thousands of keys to answer a comparison the string already answers.
    private func dailyScores(metricId: String, fromDayKey: String,
                             toDayKey: String) throws -> [String: (id: String, value: Double)] {
        var out: [String: (id: String, value: Double)] = [:]
        for row in try derivation.latestDerivedSeries(metricId: metricId) {
            guard row.periodKey.hasPrefix("day:") else { continue }
            let dayKey = String(row.periodKey.dropFirst(4))
            guard dayKey >= fromDayKey, dayKey <= toDayKey else { continue }
            out[dayKey] = (row.id, row.value)
        }
        return out
    }

    /// Observed days that fall inside any declared status interval. Computed over the observed set
    /// rather than by expanding the intervals, so an open-ended "still travelling" status annotates
    /// exactly the journaled days it covers and no phantom ones.
    static func contextDayKeys(observedDayKeys: Set<String>, statuses: [ContextStatus],
                               tz: String) -> Set<String> {
        guard !statuses.isEmpty else { return [] }
        var out = Set<String>()
        for dayKey in observedDayKeys {
            guard let start = DayAttribution.date(fromDayKey: dayKey, tz: tz) else { continue }
            let end = DayAttribution.addingDays(1, to: start, tz: tz)
            if statuses.contains(where: { $0.deletedAt == nil && $0.overlaps(from: start, to: end) }) {
                out.insert(dayKey)
            }
        }
        return out
    }

    /// The day key one calendar day after `dayKey`. Calendar arithmetic rather than +86400 so a DST
    /// boundary does not shift a score onto the wrong day — the same reason `JournalLog.yesterday`
    /// uses `byAdding:`.
    static func nextDayKey(_ dayKey: String, tz: String) -> String {
        guard let date = DayAttribution.date(fromDayKey: dayKey, tz: tz) else { return dayKey }
        return DayAttribution.localDayKey(DayAttribution.addingDays(1, to: date, tz: tz), tz: tz)
    }

    // MARK: Persistence

    /// Append one finding as a `DerivedValue` + `InputManifest` in the sensitive database.
    ///
    /// Skip-if-identical, matching the other engines: a repeat run over unchanged data appends
    /// nothing, so a nightly recompute does not grow the table with copies of the same belief. A
    /// CHANGED belief always appends (I2) — the prior row keeps its own `computedAt` and stays
    /// readable as what BADAN thought last week.
    private func persist(_ finding: CorrelationFinding, days: [CorrelationDay]) throws {
        let existing = try findings.latestDerived(metricId: finding.metricId, periodKey: finding.periodKey)
        if let existing,
           existing.value == finding.delta,
           existing.confidence == finding.confidence,
           existing.algorithmVersion == spec.algorithm.semver {
            return
        }

        let now = clock.now()
        let manifest = InputManifest(id: ULID.newID(), inputs: Self.manifestInputs(for: finding, days: days))
        try findings.transaction {
            try findings.insertManifest(manifest)
            try findings.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: finding.metricId, value: finding.delta, unit: "index",
                periodKey: finding.periodKey, confidence: finding.confidence,
                provisional: finding.provisional, algorithmId: spec.algorithm.algorithmId,
                algorithmVersion: spec.algorithm.semver, inputManifestId: manifest.id,
                computedAt: now, updatedAt: now, originDeviceId: deviceId))
        }
    }

    /// The manifest a finding files with: its summary statistics, then every day that fed it.
    ///
    /// **The `stat:` convention.** `DerivedValue` carries one number, and a correlation is n, an
    /// effect size, two interval bounds and two arm counts. Rather than invent a parallel table or
    /// smuggle a JSON blob into a column, the statistics ride in the manifest — which is exactly
    /// what the manifest is for ("the records that fed a derived value ... renders the anatomy
    /// sheet") — under reserved `stat:<name>` record ids. `CorrelationFinding.from(derived:manifest:)`
    /// is the matching reader, and the round trip is asserted, so this is a contract rather than a
    /// convention someone has to know.
    ///
    /// **`weight` carries the arm** for the per-day inputs: 1 = behaviour-present day, 0 = absent.
    /// It is the manifest's only per-input slot and the arm IS that input's role in this
    /// computation, so it is the honest place for it.
    static func manifestInputs(for finding: CorrelationFinding, days: [CorrelationDay]) -> [InputManifest.Input] {
        let metricId = finding.metricId
        var inputs: [InputManifest.Input] = [
            .init(recordId: "stat:n", metricId: metricId, value: Double(finding.nObserved)),
            .init(recordId: "stat:n_with", metricId: metricId, value: Double(finding.nWith)),
            .init(recordId: "stat:n_without", metricId: metricId, value: Double(finding.nWithout)),
            .init(recordId: "stat:delta", metricId: metricId, value: finding.delta),
            .init(recordId: "stat:ci_low", metricId: metricId, value: finding.ciLow),
            .init(recordId: "stat:ci_high", metricId: metricId, value: finding.ciHigh),
            .init(recordId: "stat:median_with", metricId: metricId, value: finding.medianWith),
            .init(recordId: "stat:median_without", metricId: metricId, value: finding.medianWithout),
            .init(recordId: "stat:context_days", metricId: metricId, value: Double(finding.contextDays)),
        ]
        for day in days {
            guard let score = day.nextDayScore else { continue }
            inputs.append(.init(recordId: day.nextDayScoreRecordId.isEmpty ? "day:" + day.dayKey : day.nextDayScoreRecordId,
                                metricId: finding.scoreId, value: score,
                                weight: day.present ? 1 : 0))
        }
        return inputs
    }
}

// MARK: - Reading a stored finding back

extension CorrelationFinding {

    /// Rebuild a finding from the row and manifest it was stored as — the reader half of the `stat:`
    /// contract `manifestInputs` writes, pinned by the round-trip test on both platforms.
    ///
    /// **Nothing in the app calls this yet.** Both correlation surfaces render the outcomes
    /// `CorrelationEngine.recompute` has just returned, never rows re-read from storage: a
    /// suppressed pair is deliberately never persisted, so the "not yet, about N more days" half of
    /// the screen can only come from a live evaluation, and the findings arrive on the same pass.
    /// This reader exists so a stored row is legible on its own terms — what a later stored-findings
    /// surface, an anatomy sheet or an export would have to do — and so the writer cannot drift from
    /// what a reader would make of it without the round-trip test failing.
    ///
    /// **It fails closed.** The interval is what decides the direction, so a manifest that is
    /// missing, undecodable, or short of any statistic read here yields NO finding rather than a
    /// patched-up one. Defaulting the bounds to the point estimate — the obvious shortcut — rebuilds
    /// `ciLow == ciHigh == delta`, which `direction` reads as a confident `.higher`/`.lower` over
    /// `nObserved == 0`: a statistical claim fabricated out of missing data, which is the one thing
    /// this engine exists to refuse. `CorrelationEngineTests` asserts the refusal.
    static func from(derived: DerivedValue, manifest: InputManifest?) -> CorrelationFinding? {
        guard let pair = CorrelationMetricID.parse(derived.metricId) else { return nil }
        let stats = Dictionary(
            (manifest?.inputs ?? []).filter { $0.recordId.hasPrefix("stat:") }
                .map { ($0.recordId, $0.value) },
            uniquingKeysWith: { a, _ in a })

        // A count has to be a real, non-negative, day-sized number to be one. Anything else is
        // corruption rather than data — and `Int(_:)` on a non-finite or out-of-range `Double` traps.
        func count(_ value: Double?) -> Int? {
            guard let value, value.isFinite, value >= 0, value <= 1_000_000 else { return nil }
            return Int(value)
        }

        guard let nObserved = count(stats["stat:n"]),
              let nWith = count(stats["stat:n_with"]),
              let nWithout = count(stats["stat:n_without"]),
              let contextDays = count(stats["stat:context_days"]),
              let ciLow = stats["stat:ci_low"], let ciHigh = stats["stat:ci_high"],
              let medianWith = stats["stat:median_with"],
              let medianWithout = stats["stat:median_without"],
              derived.value.isFinite, medianWith.isFinite, medianWithout.isFinite,
              ciLow.isFinite, ciHigh.isFinite, ciLow <= ciHigh
        else { return nil }

        // A window key we cannot parse degrades to empty day keys rather than to invented ones —
        // the finding still renders its numbers, and nothing claims a span it cannot show. That is a
        // safe degradation in a way a missing interval is not: the span is a label, the interval is
        // the claim.
        let window = derived.periodKey.hasPrefix("window:")
            ? String(derived.periodKey.dropFirst("window:".count)).components(separatedBy: "..")
            : []
        return CorrelationFinding(
            behaviorId: pair.behaviorId, scoreId: pair.scoreId,
            nObserved: nObserved, nWith: nWith, nWithout: nWithout, delta: derived.value,
            ciLow: ciLow, ciHigh: ciHigh,
            medianWith: medianWith, medianWithout: medianWithout,
            contextDays: contextDays, confidence: derived.confidence ?? 0,
            provisional: derived.provisional,
            firstDayKey: window.first ?? "", lastDayKey: window.count > 1 ? window[1] : "")
    }
}

// MARK: - Rendering

/// Turns an outcome into the sentences a card shows, through the shared `InsightTemplateStore`.
///
/// **The locked line.** `journal_correlation_not_cause` is appended to EVERY rendered card — the
/// positive, the negative and the null alike — in both languages. It is not conditional and it is
/// not a caller's responsibility: a caller that forgot it would ship a card reading as causal, which
/// is the single failure mode this epic exists to prevent. `CorrelationEngineTests` asserts it on
/// every outcome the engine can produce.
///
/// **Two altitudes, one computation.** `casualText` is a sentence; `powerText` is n, the effect size
/// and the interval as numbers. Both are rendered from the SAME `CorrelationFinding` — there is no
/// second computation for the detailed view, which is what stops the two from ever disagreeing (D-5).
///
/// Nothing here is persisted to the `insights` table. The rendered sentence names the behaviour, so
/// storing it in `badan.db` would leak through the front door what putting the findings in the
/// sensitive database closed the back one on.
enum CorrelationRenderer {

    struct Card: Sendable, Hashable {
        let metricId: String
        let templateId: String
        /// The one-sentence altitude.
        let casualText: LocalizedString
        /// The numbers altitude — nil for a suppressed pair, which has no statistics to show
        /// (that is the point of suppression).
        let powerText: LocalizedString?
        /// Context disclosure, when the window overlapped a declared status.
        let contextNote: LocalizedString?
        /// The locked association-not-cause line. Always present.
        let associationNotCause: LocalizedString
        let isSuppressed: Bool

        /// Every line the card renders, in order — what a test asserts over and what a simple
        /// surface can join without deciding an order of its own.
        var lines: [LocalizedString] {
            var out = [casualText]
            if let contextNote { out.append(contextNote) }
            if let powerText { out.append(powerText) }
            out.append(associationNotCause)
            return out
        }
    }

    /// Arabic count-noun agreement for the correlation copy's day-count phrases (1 singular · 2
    /// dual · 3–10 plural · 11+ indeclinable) — the same rule already shipped by
    /// `StressTrendCard.dayCount`, `CalibrationCount.dayPhrase`, `HomeArabicCount.phrase` and
    /// `ReportPresentation.dayCount`. Returns both languages at once, matching `plain()` below,
    /// because `render()` fills one `LocalizedString` template with values that already carry both
    /// languages — there is no language selector at this layer to branch on.
    ///
    /// One parameterized function rather than one per call site: the correlation templates that
    /// count days each attach a different trailing description ("additional", "additional … of
    /// this kind", "additional logged … without it"), so only the singular/dual/plural/many
    /// arguments need to vary between call sites — they are the FULL phrase per bracket, not just
    /// the bare noun, because the adjectives themselves inflect too ("يومان إضافيان" has a
    /// dual-marked adjective, not "يومان إضافي"). Not private so a test can exercise the boundary
    /// directly, mirroring `StressSurfacesTests`' direct test of `StressPresentation.dayCount`.
    enum CorrelationDayCount {
        static func phrase(_ n: Int, enSingular: String, enPlural: String, arSingular: String,
                          arDual: String, arPlural: String, arMany: String) -> LocalizedString {
            let en = n == 1 ? enSingular : "\(n) \(enPlural)"
            let ar: String
            switch n {
            case 1: ar = arSingular
            case 2: ar = arDual
            case 3...10: ar = "\(n) \(arPlural)"
            default: ar = "\(n) \(arMany)"
            }
            return LocalizedString(en: en, ar: ar)
        }
    }

    static let lockedTemplateId = "journal_correlation_not_cause"

    /// The fallback used only if the template store failed to load. Kept verbatim-equal to the
    /// contract's copy and asserted so, because a card that lost this line to a packaging failure
    /// would be worse than a card that failed to render at all.
    static let associationNotCauseFallback = LocalizedString(
        en: "This is an association in your own logged data, not a cause.",
        ar: "هذا ارتباط في بياناتك المسجّلة، وليس سببًا.")

    static func render(_ outcome: CorrelationOutcome, behavior: LocalizedString, score: LocalizedString,
                       templates: InsightTemplateStore, params: CorrelationSpec.Params) -> Card {
        let locked = templates.template(lockedTemplateId)?.text ?? associationNotCauseFallback
        switch outcome {
        case let .suppressed(suppression):
            let templateId: String
            let daysPhrase: LocalizedString
            let n = suppression.reason.moreDaysNeeded
            // All three of this switch's Arabic dual forms use the OBLIQUE dual (ين), not the
            // nominative "يومان" `CorrelationDayCount`'s doc comment cites as the general default:
            // every one of these templates places the phrase directly after "نحو" ("about" / "roughly"),
            // which governs its complement as an idafa genitive — "نحو يومين", never "نحو يومان",
            // the same way "نحو عشرين رجلاً" takes the oblique, not "نحو عشرون رجل". The adjectives
            // agree in case too (إضافيين, مسجّلين — not the nominative إضافيان/مسجّلان). This is
            // NOT the same context as the bare "يومان" used below in the finding branch's
            // nWithPhrase, which sits in a parenthetical appositive list with no case-assigning
            // word before it and is correctly nominative as written.
            switch suppression.reason {
            case .tooFewObservedDays:
                templateId = "journal_correlation_needs_days"
                daysPhrase = CorrelationDayCount.phrase(n, enSingular: "1 more day", enPlural: "more days",
                    arSingular: "يوم واحد إضافي", arDual: "يومين إضافيين",
                    arPlural: "أيام إضافية", arMany: "يومًا إضافيًا")
            case .tooFewDaysWithBehavior:
                templateId = "journal_correlation_needs_with_days"
                daysPhrase = CorrelationDayCount.phrase(n,
                    enSingular: "1 more day of this kind", enPlural: "more days of this kind",
                    arSingular: "يوم واحد إضافي من هذا النوع", arDual: "يومين إضافيين من هذا النوع",
                    arPlural: "أيام إضافية من هذا النوع", arMany: "يومًا إضافيًا من هذا النوع")
            case .tooFewDaysWithoutBehavior:
                templateId = "journal_correlation_needs_without_days"
                daysPhrase = CorrelationDayCount.phrase(n,
                    enSingular: "1 more logged day without it", enPlural: "more logged days without it",
                    arSingular: "يوم واحد مسجّل إضافي بدونه", arDual: "يومين مسجّلين إضافيين بدونه",
                    arPlural: "أيام مسجّلة إضافية بدونه", arMany: "يومًا مسجّلًا إضافيًا بدونه")
            }
            let text = fill(templates, templateId, [
                "behavior": behavior, "score": score,
                "days": daysPhrase,
                "nWith": plain("\(suppression.nWith)"),
                "nWithout": plain("\(suppression.nWithout)"),
                "n": plain("\(suppression.nObserved)"),
            ])
            return Card(metricId: CorrelationMetricID.metricId(behaviorId: suppression.behaviorId,
                                                              scoreId: suppression.scoreId),
                        templateId: templateId, casualText: text, powerText: nil,
                        contextNote: nil, associationNotCause: locked, isSuppressed: true)

        case let .finding(finding):
            let templateId: String
            switch finding.direction {
            case .higher: templateId = "journal_correlation_higher"
            case .lower: templateId = "journal_correlation_lower"
            case .noClearAssociation: templateId = "journal_correlation_none"
            }
            let counts: [String: LocalizedString] = [
                "behavior": behavior, "score": score,
                "n": plain("\(finding.nObserved)"),
                "nWith": plain("\(finding.nWith)"),
                "nWithout": plain("\(finding.nWithout)"),
                // Distinct from the bare "nWith" above, which journal_correlation_power_detail
                // still reads as a plain stat ("n = 14 (7 with / 9 without)" — a data readout that
                // must never grow a noun). The casual higher/lower/none templates read this one
                // instead: nWith only has to clear minDaysPerArm (5), so it lands in the Arabic
                // 3-10 plural bracket at least as often as the 11+ bracket, and "N يومًا" is wrong
                // Arabic for that range — see CorrelationDayCount's doc comment.
                "nWithPhrase": CorrelationDayCount.phrase(finding.nWith,
                    enSingular: "1 day", enPlural: "days",
                    arSingular: "يوم واحد", arDual: "يومان", arPlural: "أيام", arMany: "يومًا"),
                // Same reasoning as nWithPhrase, applied defensively to nObserved. Today
                // finding.nObserved can never actually fall below minObservedDays (14), so this
                // always resolves through the 11+ branch in practice — but that safety depends
                // entirely on minObservedDays staying >= 11, which is a spec constant this file does
                // not own. Filling the casual template's sentence-opening count from the same
                // bracket-aware helper (rather than a bare digit) removes that dependency instead of
                // leaving a correctness guarantee resting on a number defined elsewhere never
                // dropping.
                "nPhrase": CorrelationDayCount.phrase(finding.nObserved,
                    enSingular: "1 day", enPlural: "days",
                    arSingular: "يوم واحد", arDual: "يومان", arPlural: "أيام", arMany: "يومًا"),
            ]
            let casual = fill(templates, templateId, counts)
            let power = fill(templates, "journal_correlation_power_detail", counts.merging([
                "delta": plain(twoDecimals(finding.delta)),
                "ciLow": plain(twoDecimals(finding.ciLow)),
                "ciHigh": plain(twoDecimals(finding.ciHigh)),
                "confidence": plain(twoDecimals(finding.confidence)),
                "iterations": plain("\(params.bootstrapIterations)"),
            ], uniquingKeysWith: { _, b in b }))
            let contextNote = finding.contextDays > 0
                ? fill(templates, "journal_correlation_context", ["days": plain("\(finding.contextDays)")])
                : nil
            return Card(metricId: finding.metricId, templateId: templateId, casualText: casual,
                        powerText: power, contextNote: contextNote, associationNotCause: locked,
                        isSuppressed: false)
        }
    }

    /// Fill a template in both languages at once. Uses `InsightEngine.fill`, the same substitution
    /// the status-explanation path uses — extending the existing rendering path rather than forking
    /// a second one.
    private static func fill(_ templates: InsightTemplateStore, _ templateId: String,
                             _ values: [String: LocalizedString]) -> LocalizedString {
        guard let template = templates.template(templateId) else { return LocalizedString(en: "", ar: "") }
        var en: [String: String] = [:]
        var ar: [String: String] = [:]
        for (key, value) in values {
            en[key] = value.en
            ar[key] = value.ar
        }
        return LocalizedString(en: InsightEngine.fill(template.textEn, en),
                               ar: InsightEngine.fill(template.textAr, ar))
    }

    /// A token that is the same in both languages (a numeral). Digits stay Latin here for the same
    /// reason `InsightEngine.formatValue` leaves them Latin — the Arabic-digit preference lives in
    /// the App-layer `CustomizationProfile`, which Domain must not depend on.
    private static func plain(_ value: String) -> LocalizedString { LocalizedString(en: value, ar: value) }

    /// Two decimals, `en_US_POSIX`-fixed so the string is identical on both platforms and in every
    /// locale — a Cliff's delta rendered as "0,42" in one place and "0.42" in another would break
    /// the cross-platform golden for no gain.
    static func twoDecimals(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
