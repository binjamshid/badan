import Foundation

/// EPIC-34 — the device-gated stress monitor. **The gate is the feature.**
///
/// Plan §11 calls a real-time stress index "the biggest false-precision trap in the plan", and the
/// reason is physical, not editorial: an Apple-Watch-class wearable writes a handful of HRV samples a
/// day, most of them overnight. A live "your stress is 62 right now" built on top of that would be
/// fiction with a progress ring around it. So this engine's primary output is not a number — it is a
/// DECISION about whether BADAN has earned the right to say anything at all:
///
/// 1. **Density detector.** Daytime HRV sampling rate (samples per WAKING hour — sleep sessions are
///    excluded, because daytime is the entire point) measured over a trailing week.
/// 2. **Three surface states, and only three** (`StressSurface`, a closed enum so a surface cannot
///    invent a fourth):
///    - `.dense` — vendor-grade continuous sampling (Oura/Garmin/Samsung, Phase 4). The full
///      intraday index is **not implemented in this phase**: a dense-classified window still gets the
///      daily trend, and `StressEngine.intradayIndexImplemented == false` says so in code rather than
///      in a comment that could rot. Building the state now fixes the shape; pretending it computes
///      something today would be exactly the lie this epic exists to refuse.
///    - `.moderate` — a DAILY low-confidence trend, and nothing else. Confidence is capped by the
///      contract (`moderateConfidenceCap`), so "low confidence" is structural, not a copy choice.
///    - `.hidden` — no surface, plus an explanation of *why*. This is the **default for Apple-Watch-
///      only users** and the copy (`StressAbsenceReason.explanation`) is deliberately a statement
///      about what the DEVICE records, never about the user having done something wrong and never
///      about BADAN having failed.
/// 3. **No live number, ever, on phone/watch-class data.** Every value this engine emits is keyed
///    `day:<key>` and describes a *window ending on that day*. There is no API here that takes an
///    instant and returns a current index, and `StressTrend` carries the window it was computed over
///    so a surface cannot quietly relabel it "now". No notifications are raised from this engine in
///    this phase (plan §5.4 defers spike alerts behind a confident index that does not exist yet).
///
/// **The trend method** (published in `docs/algorithms/stress.md`): each day's daytime HRV samples
/// collapse to a robust median; that daily value is read as a log-domain z against the person's own
/// recent *daytime* reference (median + MAD over `referenceWindowDays`); the z is inverted (lower HRV
/// than your usual = more autonomic load) and mapped onto 0–100 around a neutral 50; and the trend is
/// the recency-weighted mean of those daily loads across a sliding window.
///
/// The reference is deliberately **not** the EPIC-23 `heart.hrv` baseline. That baseline is dominated
/// by overnight readings, and overnight HRV runs systematically higher than daytime HRV — reading a
/// daytime median against it would print "elevated load" every day of the user's life. Daytime is
/// compared with daytime or with nothing. (This is also why the engine does not read `BaselineEngine`
/// at all; it reuses its published robust-statistics primitives and its `madToSigma` constant, so
/// there is still exactly one definition of each in the codebase.)
///
/// Everything is append-only and clock-injected (INVARIANT I2): a recompute over changed data appends
/// a fresh row and the superseded row keeps its own `computedAt`, value and algorithm id. The whole
/// decision core (`evaluate`, `classify`, `dailyLoad`, `trendValue`) is pure and static so the Android
/// mirror computes byte-identical numbers and gates at byte-identical boundaries — that parity is the
/// acceptance criterion, since a gate that differs by platform is not a gate.
final class StressEngine {
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String
    private let spec: StressSpec
    /// EPIC-29 (plan §18). What the user declared over the day being persisted. A function, not the
    /// sensitive repository — see `ContextAnnotationResolver`. Only `compute` consults it: `evaluate`
    /// is the read path and stores nothing, so there is nothing there for a ceiling to cap.
    private let contextAnnotations: ContextAnnotationResolver

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         registry: MetricRegistry = .shared, clock: Clock, deviceId: String,
         spec: StressSpec = .defaultShared,
         contextAnnotations: @escaping ContextAnnotationResolver = noContextAnnotations) {
        self.derivation = derivation
        self.measurements = measurements
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
        self.spec = spec
        self.contextAnnotations = contextAnnotations
    }

    /// Frozen identity, resolved from the contract (never hand-written — a change is a contract diff
    /// plus a semver bump; rows already written keep their old id under I2).
    var algorithm: AlgorithmVersion { spec.algorithm }

    /// Whether this build computes the dense-density intraday index. **False, and stated in code.**
    /// The `.dense` surface state exists so the shape is fixed and the read model is honest about what
    /// it is holding; the intraday index itself is Phase-4 work behind vendor ingestion. A surface
    /// reading `.dense` must render the daily trend and say the intraday view is not available yet.
    static let intradayIndexImplemented = false

    // MARK: - Evaluate (the gate) + compute (the gate, then maybe a row)

    /// Decide what — if anything — may be shown for the local day containing `asOf`, and return the
    /// full surface state. **Writes nothing**: this is the read path the UI calls, and it is safe to
    /// call when the answer is "hidden", which is the common case.
    ///
    /// Returns `.hidden(.contractUnavailable)` when the contract did not load: an engine with no
    /// constants computes nothing rather than inventing them (mirror of `ReadinessSpec`/`EffortSpec`).
    func evaluate(asOf: Date, tz: String = TimeZone.current.identifier) throws -> StressSurface {
        guard spec.isLoaded else { return .hidden(reason: .contractUnavailable) }
        let buckets = try gatherDaytimeBuckets(asOf: asOf, tz: tz)
        return Self.evaluate(buckets: buckets, params: spec.params)
    }

    /// Evaluate the day and, when the gate allows a trend, APPEND it as a `stress.day_trend`
    /// `DerivedValue`. Returns the same surface `evaluate` would, so a caller gets the decision and
    /// the persistence in one pass. A hidden day writes nothing at all — an absence is not stored as
    /// a zero, a null row, or a "no data" sentinel; it is simply absent, and the surface explains it.
    ///
    /// A repeat call over unchanged data is skipped by the value+version guard, so a debounced burst
    /// of ingests does not grow the append-only table; a changed value, or a bumped algorithm
    /// version, always appends (I2 auditability).
    @discardableResult
    func compute(asOf: Date, tz: String = TimeZone.current.identifier) throws -> StressSurface {
        let surface = try evaluate(asOf: asOf, tz: tz)
        if let trend = surface.trend {
            // A hidden day never reaches here, so a hidden day also never resolves a context — the
            // "hidden days write nothing" rule covers the sensitive read too, not just the row.
            let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
            try persist(trend: trend,
                        context: try contextAnnotations(dayStart, DayAttribution.addingDays(1, to: dayStart, tz: tz)))
        }
        return surface
    }

    // MARK: - Input gathering (I/O)

    /// Build one bucket per local day over the longest window either half of the method needs, oldest
    /// first, ending on `asOf`'s local day.
    ///
    /// "Daytime" is the day's clock time minus every SLEEP session overlapping it — primary sleep and
    /// naps alike. A nap is chronologically daytime but physiologically sleep, and HRV recorded during
    /// one says nothing about waking autonomic load, so it is excluded rather than counted as a dense
    /// daytime hour (which would be the easiest way to accidentally unlock the gate).
    private func gatherDaytimeBuckets(asOf: Date, tz: String) throws -> [StressDayBucket] {
        let days = max(spec.params.densityWindowDays, spec.params.referenceWindowDays)
        let today = DayAttribution.startOfDay(asOf, tz: tz)
        let windowStart = DayAttribution.addingDays(-(days - 1), to: today, tz: tz)
        let windowEnd = DayAttribution.addingDays(1, to: today, tz: tz)

        // One query per source table for the whole window, then bucketed in memory — the same shape
        // the sibling engines use, and it keeps the per-day loop free of I/O.
        let hrv = try measurements.intervalRecords(metricId: MetricID.hrv, from: windowStart, to: windowEnd)
            .filter { $0.value.isFinite && $0.value > 0 }
        // A sleep session that STARTED before the window can still cover its first morning, so the
        // session query reaches back a day further than the buckets do.
        let sleepWindows = try measurements
            .sessions(kind: nil, from: DayAttribution.addingDays(-1, to: windowStart, tz: tz), to: windowEnd)
            .filter { $0.kind.isSleep }
            .map { (start: $0.startAt, end: $0.endAt) }

        var buckets: [StressDayBucket] = []
        var dayStart = windowStart
        while dayStart < windowEnd {
            let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
            let asleepSeconds = Self.overlapSeconds(windows: sleepWindows, from: dayStart, to: dayEnd)
            let daySeconds = dayEnd.timeIntervalSince(dayStart)   // 23/24/25h — DST-correct via Calendar
            // Samples are placed by their INSTANT inside the day's window, not by each record's own
            // timezone (the day-attribution rule the sibling engines use for daily aggregates). The
            // question here is "how much of this waking window did the device sample", which is an
            // arithmetic over real elapsed time — attributing a reading to a different calendar day
            // than the hours it is being divided by would break the rate, not fix it.
            let samples = hrv
                .filter { $0.startAt >= dayStart && $0.startAt < dayEnd && !Self.isAsleep($0.startAt, windows: sleepWindows) }
                .map(\.value)
            buckets.append(StressDayBucket(
                dayKey: DayAttribution.localDayKey(dayStart, tz: tz),
                daytimeHours: max(0, daySeconds - asleepSeconds) / 3600.0,
                daytimeHrv: samples))
            dayStart = dayEnd
        }
        return buckets
    }

    /// Total seconds of `[from, to)` covered by any of `windows`. Overlapping sleep sessions (two
    /// devices recording the same night, both still live because dedup suppresses rather than deletes)
    /// are unioned, not summed — double-counting them would shrink the waking day and inflate the
    /// samples-per-hour rate, which is precisely the direction the gate must never err in.
    static func overlapSeconds(windows: [(start: Date, end: Date)], from: Date, to: Date) -> Double {
        let clipped = windows
            .map { (start: max($0.start, from), end: min($0.end, to)) }
            .filter { $0.start < $0.end }
            .sorted { $0.start < $1.start }
        guard let first = clipped.first else { return 0 }
        var total = 0.0
        var runStart = first.start
        var runEnd = first.end
        for w in clipped.dropFirst() {
            if w.start <= runEnd {
                runEnd = max(runEnd, w.end)
            } else {
                total += runEnd.timeIntervalSince(runStart)
                runStart = w.start
                runEnd = w.end
            }
        }
        total += runEnd.timeIntervalSince(runStart)
        return total
    }

    private static func isAsleep(_ instant: Date, windows: [(start: Date, end: Date)]) -> Bool {
        windows.contains { instant >= $0.start && instant < $0.end }
    }

    // MARK: - Persistence (append-only, I2)

    private func persist(trend: StressTrend, context: ContextAnnotation = .none) throws {
        let periodKey = "day:" + trend.dayKey
        let unit = registry.definitionOrFallback(MetricID.stressDayTrend).canonicalUnit
        // The only thing a declared context reaches in this engine. `trend.value` goes onto the row
        // verbatim below; the ceiling stacks UNDER the contract's own density cap by the same
        // `min`, so a moderate-density trend declared inside a travel window ends up at the lower of
        // the two — never above either.
        let confidence = context.applying(to: trend.confidence) ?? trend.confidence
        // The algorithm identity is part of the skip check: a version bump that recomputes the same
        // value must still append, or the day's latest row would keep the OLD version id and the
        // change would go unrecorded (mirrors ReadinessEngine/EffortEngine).
        if let existing = try derivation.latestDerived(metricId: MetricID.stressDayTrend, periodKey: periodKey),
           existing.algorithmId == algorithm.algorithmId, existing.algorithmVersion == algorithm.semver,
           existing.unit == unit, existing.provisional == trend.provisional,
           Self.approximatelyEqual(existing.value, trend.value),
           Self.approximatelyEqual(existing.confidence ?? -1, confidence) {
            return
        }
        try derivation.transaction {
            // One manifest input per CONTRIBUTING DAY: `value` = that day's daytime HRV median,
            // `weight` = the recency weight it carried into the trend. `recordId` is a day token
            // rather than a raw-row id because a day's value aggregates every daytime sample on it —
            // the lineage is "the daytime `heart.hrv` samples on this day", queryable directly
            // (I1/I5), exactly as `EffortEngine` does with its zone tokens.
            let manifest = InputManifest(id: ULID.newID(), inputs: trend.contributions.map {
                InputManifest.Input(recordId: "day:\($0.dayKey)#daytime_hrv", metricId: MetricID.hrv,
                                    value: $0.dayValue, weight: $0.weight)
            })
            try derivation.insertManifest(manifest)
            let now = clock.now()
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: MetricID.stressDayTrend, value: trend.value, unit: unit,
                periodKey: periodKey, confidence: confidence, provisional: trend.provisional,
                algorithmId: algorithm.algorithmId, algorithmVersion: algorithm.semver,
                inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId))
        }
    }

    // MARK: - Pure decision core (identical on both platforms — golden-tested)

    /// The whole gate-then-trend decision, pure. `buckets` are consecutive local days, oldest first,
    /// with the day being evaluated LAST. Both platforms run exactly this, so the boundaries cannot
    /// drift between them.
    static func evaluate(buckets: [StressDayBucket], params: StressParams) -> StressSurface {
        guard let today = buckets.last else { return .hidden(reason: .noDaytimeHrv) }

        let density = measureDensity(buckets: buckets, params: params)
        let state = classify(density: density, params: params)
        guard state != .insufficient else {
            return .hidden(reason: absenceReason(density: density, params: params))
        }

        // Daily values, keyed by day: a day with too few daytime samples is a GAP, never an imputed
        // value. `dayValue` is the MEDIAN of that day's daytime samples — robust, so one artefactual
        // reading (a bad sample after a coffee, a movement spike) cannot carry the day.
        var dayValues: [String: Double] = [:]
        for bucket in buckets where bucket.daytimeHrv.count >= params.minDaytimeSamplesPerDay {
            dayValues[bucket.dayKey] = BaselineEngine.median(bucket.daytimeHrv)
        }

        // The personal DAYTIME reference over the trailing reference window (log domain — HRV is
        // right-skewed, matching `docs/algorithms/baselines.md`).
        let referenceValues = buckets.suffix(params.referenceWindowDays).compactMap { dayValues[$0.dayKey] }
        guard referenceValues.count >= params.minReferenceDays,
              let reference = reference(values: referenceValues, params: params) else {
            return .hidden(reason: .stillLearningDaytimePattern)
        }

        // The sliding trend window ends on the evaluated day; days inside it that produced no value
        // are simply absent (gaps, not zeros). Age is taken from the bucket ORDER — the buckets are
        // already consecutive calendar days, so this stays correct across DST and month ends without
        // a second date calculation.
        let trendDays = Array(buckets.suffix(params.trendWindowDays))
        let lastIndex = trendDays.count - 1
        let contributions: [StressDayContribution] = trendDays.enumerated().compactMap { index, bucket in
            guard let value = dayValues[bucket.dayKey] else { return nil }
            return StressDayContribution(
                dayKey: bucket.dayKey, dayValue: value,
                load: dailyLoad(dayValue: value, reference: reference, params: params),
                weight: recencyWeight(ageDays: Double(lastIndex - index), params: params))
        }
        guard contributions.count >= params.minTrendDays else {
            return .hidden(reason: .tooFewRecentDays)
        }

        let value = trendValue(contributions: contributions)
        let cap = state == .dense ? params.denseConfidenceCap : params.moderateConfidenceCap
        let coverage = Double(contributions.count) / Double(max(1, params.trendWindowDays))
        let maturity = min(1.0, Double(referenceValues.count) / Double(max(1, params.referenceWindowDays)))
        let confidence = min(cap, max(0, coverage * maturity))
        // A moderate-density trend is provisional BY CONSTRUCTION, independent of whether the
        // algorithm's own constants are validated: sparse daytime sampling cannot produce an
        // established reading, and the row must say so wherever it is read.
        let provisional = params.algorithmProvisional || state != .dense

        let trend = StressTrend(
            dayKey: today.dayKey, value: value, band: band(value: value, params: params),
            confidence: confidence, provisional: provisional, densityState: state,
            density: density, daysPresent: contributions.count, windowDays: params.trendWindowDays,
            contributions: contributions)

        return state == .dense ? .dense(trend: trend) : .moderate(trend: trend)
    }

    /// Daytime HRV sampling density over the trailing `densityWindowDays` buckets. Counts EVERY
    /// daytime sample, including those on days too thin to contribute a value — density is a question
    /// about how the device samples, not about which days end up usable.
    static func measureDensity(buckets: [StressDayBucket], params: StressParams) -> StressDensity {
        let window = buckets.suffix(params.densityWindowDays)
        let samples = window.reduce(0) { $0 + $1.daytimeHrv.count }
        let hours = window.reduce(0.0) { $0 + $1.daytimeHours }
        let daysWithSamples = window.reduce(0) { $0 + ($1.daytimeHrv.isEmpty ? 0 : 1) }
        return StressDensity(samplesPerHour: hours > 0 ? Double(samples) / hours : 0,
                             daytimeSamples: samples, daytimeHours: hours,
                             daysWithSamples: daysWithSamples, windowDays: window.count)
    }

    /// The gate itself. Thresholds are contract data; the ordering (dense before moderate) and the
    /// inclusive `>=` boundaries are the published behaviour — a value exactly ON a threshold clears
    /// it, which is what the boundary fixtures on both platforms pin.
    static func classify(density: StressDensity, params: StressParams) -> StressDensityState {
        guard density.daytimeHours >= params.minDaytimeHoursInWindow,
              density.daysWithSamples >= params.minDaysWithDaytimeSamples else { return .insufficient }
        if density.samplesPerHour >= params.denseMinSamplesPerHour { return .dense }
        if density.samplesPerHour >= params.moderateMinSamplesPerHour { return .moderate }
        return .insufficient
    }

    /// Why a window failed the gate. Ordered most-specific first so the explanation names the actual
    /// obstacle: no daytime readings at all is a different sentence from "some, but not often enough",
    /// and both are different from "the week has barely any waking time recorded".
    static func absenceReason(density: StressDensity, params: StressParams) -> StressAbsenceReason {
        if density.daytimeSamples == 0 { return .noDaytimeHrv }
        if density.daytimeHours < params.minDaytimeHoursInWindow { return .notEnoughWakingCoverage }
        if density.daysWithSamples < params.minDaysWithDaytimeSamples { return .tooFewDaysCovered }
        return .daytimeHrvTooSparse
    }

    /// The personal daytime reference: robust centre and spread of `ln(value)`. Returns `nil` when
    /// nothing usable survives (all non-positive) — no reference, no reading.
    static func reference(values: [Double], params: StressParams) -> StressReference? {
        let usable = values.filter { $0 > 0 }
        guard !usable.isEmpty else { return nil }
        let logs = usable.map { Foundation.log($0) }
        let center = BaselineEngine.median(logs)
        return StressReference(logCenter: center, logMad: BaselineEngine.mad(logs, center: center), nDays: usable.count)
    }

    /// One day's autonomic-load sub-score on 0–100, where **50 is your own usual**. The sign is
    /// inverted relative to HRV: a daytime median BELOW your reference reads above 50 (more load),
    /// above it reads below 50. A zero-spread reference (a perfectly flat fortnight) yields exactly
    /// the neutral 50 rather than an infinite z — flat data is not evidence of anything.
    static func dailyLoad(dayValue: Double, reference: StressReference, params: StressParams) -> Double {
        guard dayValue > 0, reference.logMad > 0, params.zClampSigmas > 0 else { return 50 }
        let z = (Foundation.log(dayValue) - reference.logCenter) / (params.madToSigma * reference.logMad)
        let clamped = min(params.zClampSigmas, max(-params.zClampSigmas, z))
        return 50 - clamped / params.zClampSigmas * 50
    }

    /// Recency weight for a day `ageDays` before the evaluated day: `0.5^(ageDays / halfLifeDays)`.
    /// In DAYS — there is no intraday smoothing constant in this engine because there is no intraday
    /// output to smooth.
    static func recencyWeight(ageDays: Double, params: StressParams) -> Double {
        guard params.trendHalfLifeDays > 0 else { return 1 }
        return pow(0.5, max(0, ageDays) / params.trendHalfLifeDays)
    }

    /// The published trend value: the recency-weighted mean of the present daily loads. Bounded to
    /// 0–100 by construction (it is a convex combination of values already in that range).
    static func trendValue(contributions: [StressDayContribution]) -> Double {
        let totalWeight = contributions.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 50 }
        return contributions.reduce(0.0) { $0 + $1.load * $1.weight } / totalWeight
    }

    /// Coarse direction band around the neutral 50. Deliberately blunt: the honest output of a
    /// sparse-input trend is a direction, and a band boundary is easier to defend than a decimal.
    static func band(value: Double, params: StressParams) -> StressTrendBand {
        if value > 50 + params.bandNeutralHalfWidth { return .higherThanUsual }
        if value < 50 - params.bandNeutralHalfWidth { return .lowerThanUsual }
        return .aboutUsual
    }

    static func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }
}

// MARK: - Inputs

/// One local day's daytime evidence: how many WAKING hours the day contained (day length minus every
/// sleep session overlapping it) and the daytime `heart.hrv` values recorded in them. Pure input to
/// the decision core, so both platforms feed the gate the same shape.
struct StressDayBucket: Sendable, Hashable {
    let dayKey: String
    let daytimeHours: Double
    let daytimeHrv: [Double]

    init(dayKey: String, daytimeHours: Double, daytimeHrv: [Double]) {
        self.dayKey = dayKey
        self.daytimeHours = daytimeHours
        self.daytimeHrv = daytimeHrv
    }
}

/// The measured daytime sampling density — the evidence the gate rules on, carried into the read
/// model so power mode can show the numbers behind a hidden surface ("14 readings across 112 waking
/// hours") rather than an unexplained absence.
struct StressDensity: Sendable, Hashable {
    let samplesPerHour: Double
    let daytimeSamples: Int
    let daytimeHours: Double
    let daysWithSamples: Int
    let windowDays: Int
}

/// The person's own recent daytime HRV reference, in the log domain (HRV is right-skewed). `nDays` is
/// how many daily values it was built from — the maturity term in the trend's confidence.
struct StressReference: Sendable, Hashable {
    let logCenter: Double
    let logMad: Double
    let nDays: Int
}

// MARK: - Surface states

/// What the density detector concluded. Three values, matching the three surfaces — there is no
/// "partial" or "estimated" tier, because a tier that exists to soften a gate is a gate that does not
/// hold.
enum StressDensityState: String, Sendable, Hashable, CaseIterable {
    /// Vendor-grade continuous daytime sampling. Would support an intraday index; this build does not
    /// compute one (`StressEngine.intradayIndexImplemented`).
    case dense
    /// Enough daytime sampling for a DAILY trend and nothing finer.
    case moderate
    /// Not enough to say anything. The surface is hidden with an explanation.
    case insufficient
}

/// Why nothing is shown. Every case is a statement about the DATA or the DEVICE — never about the
/// user, and never phrased as BADAN having failed. The bilingual copy lives on the reason itself (the
/// same pattern `DeviationEngine` uses for its annotations) so an absence cannot ship unexplained:
/// there is no code path that produces a hidden surface without a rendered sentence attached.
enum StressAbsenceReason: String, Sendable, Hashable, CaseIterable {
    /// Daytime HRV exists but is too infrequent for any honest reading. **The default for
    /// Apple-Watch-only users**, and the reason this epic is a gate before it is a score.
    case daytimeHrvTooSparse
    /// No daytime HRV at all in the window — no wearable, or none worn during waking hours.
    case noDaytimeHrv
    /// Readings exist but land on too few separate days to describe a week.
    case tooFewDaysCovered
    /// The window barely contains any waking, recorded time, so a samples-per-hour rate would be
    /// arithmetic rather than evidence.
    case notEnoughWakingCoverage
    /// Sampling is dense enough, but there is not yet enough daytime history to know what this
    /// person's usual daytime pattern *is*. A calibration state, deliberately distinct from the
    /// device-sparsity ones — telling an Oura user their device samples too rarely would be false.
    case stillLearningDaytimePattern
    /// Too few days inside the trend window carried a usable value.
    case tooFewRecentDays
    /// The algorithm contract did not load, so the engine has no constants and computes nothing.
    case contractUnavailable

    /// The explanation shown in place of the surface. Wellness-safe, device-factual, en + ar.
    var explanation: LocalizedString {
        switch self {
        case .daytimeHrvTooSparse:
            return LocalizedString(
                en: "Your device doesn't record daytime heart-rate variability often enough for this.",
                ar: "جهازك لا يسجّل تغيّر معدل ضربات القلب أثناء النهار بالتكرار الكافي لهذا المؤشر.")
        case .noDaytimeHrv:
            return LocalizedString(
                en: "No daytime heart-rate variability readings arrived this week, so there's nothing to read here.",
                ar: "لم تصل أي قراءات لتغيّر معدل ضربات القلب أثناء النهار هذا الأسبوع، فلا شيء يمكن عرضه هنا.")
        case .tooFewDaysCovered:
            return LocalizedString(
                en: "Daytime readings arrived on too few days this week to describe a pattern.",
                ar: "وصلت قراءات نهارية في أيام قليلة جداً هذا الأسبوع لوصف نمط معيّن.")
        case .notEnoughWakingCoverage:
            return LocalizedString(
                en: "There aren't enough recorded waking hours this week to judge how often your device samples.",
                ar: "لا توجد ساعات يقظة مسجّلة كافية هذا الأسبوع لتقدير مدى تكرار قياسات جهازك.")
        case .stillLearningDaytimePattern:
            return LocalizedString(
                en: "Still learning your usual daytime pattern — this needs a few more weeks of readings.",
                ar: "ما زلنا نتعرّف على نمطك النهاري المعتاد — يحتاج هذا إلى أسابيع إضافية من القراءات.")
        case .tooFewRecentDays:
            return LocalizedString(
                en: "Too few days with daytime readings in the last week to show a trend.",
                ar: "عدد الأيام التي تحتوي قراءات نهارية خلال الأسبوع الماضي أقل من أن يُظهر اتجاهاً.")
        case .contractUnavailable:
            return LocalizedString(
                en: "This measure isn't available in this version of the app.",
                ar: "هذا المؤشر غير متاح في هذه النسخة من التطبيق.")
        }
    }
}

/// The direction band around the neutral 50 — the casual altitude's whole vocabulary. Never
/// "high stress"/"low stress": a direction relative to the person's own usual, nothing more.
enum StressTrendBand: String, Sendable, Hashable {
    case lowerThanUsual
    case aboutUsual
    case higherThanUsual
}

/// One day's line in the trend's anatomy: its daytime HRV median, the 0–100 load it mapped to, and
/// the recency weight it carried. Sums to the trend value by construction, so power mode renders the
/// contribution bars straight off the manifest.
struct StressDayContribution: Sendable, Hashable {
    let dayKey: String
    let dayValue: Double
    let load: Double
    let weight: Double
}

/// A computed daily trend. It describes the **window ending on `dayKey`** — `windowDays` and
/// `daysPresent` travel with the value precisely so a surface cannot relabel it "now". There is no
/// timestamp field here, and that omission is deliberate: this type structurally cannot express a
/// live reading.
struct StressTrend: Sendable, Hashable {
    let dayKey: String
    /// 0–100, 50 = your own usual daytime pattern. Higher = more autonomic load than usual.
    let value: Double
    let band: StressTrendBand
    /// Capped by the contract for a moderate-density window (`moderateConfidenceCap`) — a sparse
    /// input can never present as a confident reading.
    let confidence: Double
    let provisional: Bool
    let densityState: StressDensityState
    let density: StressDensity
    let daysPresent: Int
    let windowDays: Int
    let contributions: [StressDayContribution]
}

/// **The three surfaces EPIC-34 may present, and no others.** A closed enum rather than a struct with
/// optional fields, so a UI cannot assemble a fourth state (a "live" reading, or a trend without its
/// hidden-state explanation) out of the parts.
enum StressSurface: Sendable, Hashable {
    /// Vendor-grade density detected. The payload is still the DAILY trend: the intraday index is
    /// Phase-4 work and `StressEngine.intradayIndexImplemented` is `false`, so a surface in this state
    /// renders the trend and says the intraday view is not available yet. Presenting this case as a
    /// live number would be a defect.
    case dense(trend: StressTrend)
    /// A daily, explicitly low-confidence trend. The only state that renders a number today.
    case moderate(trend: StressTrend)
    /// Nothing is shown, and `reason.explanation` says why. A first-class shipped state — the honest
    /// default for phone-and-watch-only data, not an error and not an empty placeholder.
    case hidden(reason: StressAbsenceReason)

    /// The trend, when there is one. `nil` for `.hidden` — the only shape in which absence is
    /// expressible, which is why nothing downstream can fabricate a value for a hidden day.
    var trend: StressTrend? {
        switch self {
        case let .dense(trend), let .moderate(trend): return trend
        case .hidden: return nil
        }
    }

    var absenceReason: StressAbsenceReason? {
        if case let .hidden(reason) = self { return reason }
        return nil
    }
}

// MARK: - Spec (data-driven params, mirror of ReadinessSpec/EffortSpec)

/// The numeric params the pure core needs. Resolved once from `stress.day_trend` in
/// `algorithms.json`; the pure functions take THIS, never the registry, so they stay I/O-free.
struct StressParams: Sendable, Hashable {
    // Density gate
    let densityWindowDays: Int
    let denseMinSamplesPerHour: Double
    let moderateMinSamplesPerHour: Double
    let minDaysWithDaytimeSamples: Int
    let minDaytimeHoursInWindow: Double
    let minDaytimeSamplesPerDay: Int
    // Trend
    let referenceWindowDays: Int
    let minReferenceDays: Int
    let trendWindowDays: Int
    let minTrendDays: Int
    let trendHalfLifeDays: Double
    let zClampSigmas: Double
    let bandNeutralHalfWidth: Double
    let moderateConfidenceCap: Double
    let denseConfidenceCap: Double
    /// The MAD→sigma consistency constant, read from the BASELINE contract entry rather than
    /// re-declared here. The baseline entry's own note calls it not-tunable ("changing it changes what
    /// the band means"), so a second copy of it in this block would be exactly the hand-copied
    /// constant table `algorithms.json` exists to prevent.
    let madToSigma: Double
    /// From the contract entry's `provisional` flag.
    let algorithmProvisional: Bool
}

/// The data-driven Stress spec. The ONLY place the gate thresholds and trend constants enter the
/// engine — never hardcoded — so the two platforms cannot drift and a change is a reviewable contract
/// diff plus a semver bump. A spec that failed to load (`isLoaded == false`) makes the engine hide
/// with `.contractUnavailable` rather than invent constants (mirror of `ReadinessSpec`/`EffortSpec`).
struct StressSpec: Sendable, Hashable {
    let algorithm: AlgorithmVersion
    let params: StressParams
    let isLoaded: Bool

    private static let contractId = "stress.day_trend"
    private static let baselineContractId = "baseline.rolling_median_mad"

    static func load(from registry: AlgorithmRegistry) -> StressSpec {
        guard let def = registry.definition(contractId),
              let madToSigma = registry.param(baselineContractId, "madToSigma") else { return .unavailable }
        guard let densityWindowDays = def.params["densityWindowDays"],
              let denseMin = def.params["denseMinSamplesPerHour"],
              let moderateMin = def.params["moderateMinSamplesPerHour"],
              let minDays = def.params["minDaysWithDaytimeSamples"],
              let minHours = def.params["minDaytimeHoursInWindow"],
              let minPerDay = def.params["minDaytimeSamplesPerDay"],
              let referenceWindowDays = def.params["referenceWindowDays"],
              let minReferenceDays = def.params["minReferenceDays"],
              let trendWindowDays = def.params["trendWindowDays"],
              let minTrendDays = def.params["minTrendDays"],
              let halfLife = def.params["trendHalfLifeDays"],
              let zClamp = def.params["zClampSigmas"],
              let bandHalfWidth = def.params["bandNeutralHalfWidth"],
              let moderateCap = def.params["moderateConfidenceCap"],
              let denseCap = def.params["denseConfidenceCap"] else { return .unavailable }
        let params = StressParams(
            densityWindowDays: Int(densityWindowDays), denseMinSamplesPerHour: denseMin,
            moderateMinSamplesPerHour: moderateMin, minDaysWithDaytimeSamples: Int(minDays),
            minDaytimeHoursInWindow: minHours, minDaytimeSamplesPerDay: Int(minPerDay),
            referenceWindowDays: Int(referenceWindowDays), minReferenceDays: Int(minReferenceDays),
            trendWindowDays: Int(trendWindowDays), minTrendDays: Int(minTrendDays),
            trendHalfLifeDays: halfLife, zClampSigmas: zClamp, bandNeutralHalfWidth: bandHalfWidth,
            moderateConfidenceCap: moderateCap, denseConfidenceCap: denseCap,
            madToSigma: madToSigma, algorithmProvisional: def.provisional)
        return StressSpec(algorithm: def.algorithmVersion, params: params, isLoaded: true)
    }

    /// The app-default spec, resolved once from the bundled contract.
    static let defaultShared = load(from: .shared)

    /// The degenerate "the contract did not load" spec. The gate then answers `.hidden` for every
    /// window — an engine with no thresholds must not guess where the thresholds are.
    static let unavailable = StressSpec(
        algorithm: AlgorithmVersion(algorithmId: contractId, semver: "0.0.0", introducedIn: "0.0.0"),
        params: StressParams(
            densityWindowDays: 0, denseMinSamplesPerHour: .infinity, moderateMinSamplesPerHour: .infinity,
            minDaysWithDaytimeSamples: .max, minDaytimeHoursInWindow: .infinity, minDaytimeSamplesPerDay: .max,
            referenceWindowDays: 0, minReferenceDays: .max, trendWindowDays: 0, minTrendDays: .max,
            trendHalfLifeDays: 0, zClampSigmas: 0, bandNeutralHalfWidth: 0,
            moderateConfidenceCap: 0, denseConfidenceCap: 0, madToSigma: 0, algorithmProvisional: true),
        isLoaded: false)
}
