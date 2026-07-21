import Foundation

/// EPIC-26 — the cardiovascular Effort engine (WHOOP "strain"-equivalent). It answers "how much
/// cardiovascular load did today (or this workout) actually carry?" as a single score on the
/// published BADAN curve, and it is a transparency differentiator against WHOOP's black box: every
/// score ships with a published formula (`docs/algorithms/effort.md`), a versioned `AlgorithmVersion`,
/// an `InputManifest` (here, the minutes spent in each zone — which is also exactly what the zone-time
/// bars render), and a provisional flag while the constants are unvalidated.
///
/// **The model, in one line:** minutes are attributed to five heart-rate zones (from the person's own
/// HR max, or their stored `HRZones` override), weighted by intensity, summed into a "weighted-minutes"
/// load `L`, and mapped through `score = scaleMax · (1 − e^(−k·L))`. That curve is **monotonic** (more
/// time, or the same time at a higher zone, never lowers the score) and **diminishing** (each extra
/// weighted-minute adds less than the last), which is the WHOOP-familiar shape and is asserted as a
/// property test on both platforms. Every constant — the scale, the zone weights, the curve steepness,
/// the zone floors — is DATA in `algorithms.json` (`EffortSpec`), never a literal here, so the two
/// platforms cannot drift and a tuning change is a reviewable diff.
///
/// **Two honesty guards that define the product:**
/// - *Reduced input, never a shaming zero.* A phone-only user has no continuous HR; scored on zones
///   they would read 0 ("you did nothing") on a day they may have walked 12,000 steps. The engine
///   DETECTS the absence of usable HR and emits a distinctly-labelled steps/energy **activity load**
///   under the same `effort.day` id (with an activity unit, not `score_0_100`), never a zero-looking
///   score. The two are mutually exclusive per day and a reader tells them apart by the row's unit.
/// - *No false precision on the max.* The age-derived HR max carries a real ±10–12 bpm uncertainty
///   (the reason the EPIC-03 `WorkoutEffortBands` display bands avoid it entirely). Here it is used
///   only to WEIGHT a score that is itself provisional, is shown as a directional number rather than a
///   per-zone prescription, and is always overridable by the user's own `hrMax`/`hrZones`.
///
/// Everything is append-only and driven by an injected `Clock` (INVARIANT I2): editing HR max triggers
/// a historical recompute that APPENDS fresh rows with a new `computedAt`; the superseded rows keep
/// their own `computedAt`, value, and algorithm id — free auditability, never a mutation. The pure
/// math (`accumulate`, `effortScore`) is static so the Android port computes byte-identical numbers.
///
/// **Declared context (EPIC-29, plan §18) reaches effort as COPY only, and this engine holds no
/// resolver.** `ContextStatus` may do exactly two things to a derived result: cap its confidence and
/// add a caveat sentence. Effort rows store `confidence: nil` — there is no completeness or maturity
/// model behind an effort score in v1; the row's honesty lives in its `provisional` flag and, for the
/// phone-only path, in its unit. There is therefore nothing here for a ceiling to cap, and wiring a
/// `ContextAnnotationResolver` in would be a call whose result is discarded by construction. The
/// caveat still reaches the reader: the effort surfaces resolve it at display time through
/// `ContextCaveats`, exactly as they do for readiness and sleep. If `effort.day` ever gains a real
/// confidence, the resolver belongs here and this paragraph should be deleted in the same change.
final class EffortEngine {
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String
    private let spec: EffortSpec
    /// The person's profile (HR max + zone override + birth year). Read via a closure rather than a
    /// stored `UserProfile` so a mid-session HR-max edit is picked up on the next recompute without the
    /// engine caching a stale copy; the composition root supplies `{ try catalog.userProfile() }`. The
    /// engine READS the profile and never writes it (the editor lane owns writes).
    private let profileProvider: () throws -> UserProfile?

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         registry: MetricRegistry, clock: Clock, deviceId: String,
         spec: EffortSpec = .defaultShared,
         profileProvider: @escaping () throws -> UserProfile? = { nil }) {
        self.derivation = derivation
        self.measurements = measurements
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
        self.spec = spec
        self.profileProvider = profileProvider
    }

    /// Frozen day/workout identities, resolved from the contract (never hand-written — a change is a
    /// contract diff + semver bump; old rows keep their old id under I2).
    var dayAlgorithm: AlgorithmVersion { spec.dayAlgorithm }
    var workoutAlgorithm: AlgorithmVersion { spec.workoutAlgorithm }

    // MARK: - Day effort (trigger point + intraday recompute)

    /// Compute the Effort score for the local day containing `asOf` and APPEND it. Returns the rich
    /// result (for the anatomy sheet, the zone-time bars, and tests) or `nil` when the day cannot be
    /// scored at all — the spec did not load, or there is neither usable HR nor any activity to report
    /// (a genuine gap: no wearable, no movement, so no number is honest). Missing days are gaps, never
    /// zeros.
    ///
    /// Called on ingest for intraday updates and again at day close; a later call over changed data
    /// appends a fresh row (I2). The write is skipped only when an identical row already exists for the
    /// day, so a repeat trigger over unchanged data does not grow the table.
    @discardableResult
    func computeDay(asOf: Date, tz: String = TimeZone.current.identifier) throws -> EffortResult? {
        guard spec.isLoaded else { return nil }
        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)

        let profile = try profileProvider()
        let model = HRZoneModel.resolve(override: profile?.hrZones, hrMax: profile?.hrMax,
                                        age: Self.age(profile: profile, asOf: asOf, tz: tz), params: spec.params)

        // Zone-based path requires BOTH a resolvable zone model and usable continuous HR coverage.
        if let model {
            let samples = try hrSamples(from: dayStart, to: dayEnd)
            let acc = Self.accumulate(samples: samples, windowEnd: dayEnd.timeIntervalSinceReferenceDate,
                                      model: model, params: spec.params)
            // "Usable HR" = at least one full continuous-sampling interval's worth of attributable
            // time. A phone-only user has 0 (no `heart.hr` at all); a watch worn during any activity
            // clears it immediately because dense sampling accrues covered-seconds fast. A watch worn
            // passively all day ALSO clears it (its many resting samples cover the day) and correctly
            // scores a low-but-real effort rather than being mislabelled reduced-input.
            if acc.coveredSeconds >= spec.params.maxAttributableGapSeconds {
                let score = Self.effortScore(load: acc.load, params: spec.params)
                let result = EffortResult(periodKey: "day:" + dayKey, variant: .zoneBased(acc), score: score)
                try persistZoneBased(result: result, metricId: MetricID.effortDay, algorithm: dayAlgorithm)
                return result
            }
        }

        // Fell through: no zone model (no HR max, no age, no override) OR no usable HR. Offer the
        // labelled activity load instead of a zero-looking score.
        let reason: EffortReducedReason = (model == nil) ? .noHeartRateMax : .sparseHeartRate
        return try computeReducedInput(dayKey: dayKey, dayStart: dayStart, dayEnd: dayEnd, reason: reason)
    }

    /// The reduced-input activity load for a day with no zone-based score. Built from the day's own
    /// active energy (preferred — it captures cycling and the like, not just steps) or, absent that,
    /// steps. Emitted under `effort.day` but with the ACTIVITY metric's unit, so a reader distinguishes
    /// it from a `score_0_100` row without a second column, and it is never a fabricated 0–100 number
    /// (steps carry no intensity, so dressing them as an effort score would be exactly the false
    /// precision the house rules forbid). Returns `nil` when there is no activity either — an honest gap.
    private func computeReducedInput(dayKey: String, dayStart: Date, dayEnd: Date,
                                     reason: EffortReducedReason) throws -> EffortResult? {
        let energy = try sumIntervals(metricId: MetricID.activeEnergy, from: dayStart, to: dayEnd, dayKey: dayKey)
        let load: ActivityLoad
        if let energy, energy.total > 0 {
            load = ActivityLoad(kind: .activeEnergy, magnitude: energy.total,
                                unit: registry.definitionOrFallback(MetricID.activeEnergy).canonicalUnit,
                                recordIds: energy.ids)
        } else if let steps = try sumIntervals(metricId: MetricID.steps, from: dayStart, to: dayEnd, dayKey: dayKey),
                  steps.total > 0 {
            load = ActivityLoad(kind: .steps, magnitude: steps.total,
                                unit: registry.definitionOrFallback(MetricID.steps).canonicalUnit,
                                recordIds: steps.ids)
        } else {
            return nil
        }

        let result = EffortResult(periodKey: "day:" + dayKey, variant: .reducedInput(load, reason: reason), score: nil)
        try persistReducedInput(result: result, load: load, metricId: MetricID.effortDay, algorithm: dayAlgorithm)
        return result
    }

    // MARK: - Workout effort

    /// Compute effort for every workout session overlapping `[from, to]` and append a row per session
    /// (keyed `session:<id>`). Returns the per-session results. A session with continuous HR gets a
    /// zone-based score over its own window; one whose watch did not record HR (density below the
    /// contract threshold) gets the labelled activity load from its energy total instead of a zero.
    @discardableResult
    func computeWorkouts(from: Date, to: Date, tz: String = TimeZone.current.identifier) throws -> [EffortResult] {
        guard spec.isLoaded else { return [] }
        let profile = try profileProvider()
        var results: [EffortResult] = []
        for session in try measurements.sessions(kind: .workout, from: from, to: to) {
            if let result = try computeWorkout(session: session, profile: profile, tz: tz) {
                results.append(result)
            }
        }
        return results
    }

    private func computeWorkout(session: Session, profile: UserProfile?, tz: String) throws -> EffortResult? {
        let periodKey = "session:" + session.id
        let model = HRZoneModel.resolve(override: profile?.hrZones, hrMax: profile?.hrMax,
                                        age: Self.age(profile: profile, asOf: session.startAt, tz: tz), params: spec.params)
        let duration = session.durationSeconds
        if let model, duration > 0 {
            let samples = try hrSamples(from: session.startAt, to: session.endAt)
            let density = Self.hrDensityPerMinute(sampleCount: samples.count, windowSeconds: duration)
            if density >= spec.params.sparseHrMinSamplesPerMinute {
                let acc = Self.accumulate(samples: samples, windowEnd: session.endAt.timeIntervalSinceReferenceDate,
                                          model: model, params: spec.params)
                let score = Self.effortScore(load: acc.load, params: spec.params)
                let result = EffortResult(periodKey: periodKey, variant: .zoneBased(acc), score: score)
                try persistZoneBased(result: result, metricId: MetricID.effortWorkout, algorithm: workoutAlgorithm)
                return result
            }
        }

        // No usable HR for this session: fall back to its recorded energy as the activity load, so a
        // logged workout never renders as zero effort just because HR was not captured.
        let reason: EffortReducedReason = (model == nil) ? .noHeartRateMax : .sparseHeartRate
        guard let kcal = session.detail.workout?.totals.energyKcal, kcal > 0 else { return nil }
        let load = ActivityLoad(kind: .activeEnergy, magnitude: kcal, unit: "kcal", recordIds: [session.id])
        let result = EffortResult(periodKey: periodKey, variant: .reducedInput(load, reason: reason), score: nil)
        try persistReducedInput(result: result, load: load, metricId: MetricID.effortWorkout, algorithm: workoutAlgorithm)
        return result
    }

    // MARK: - Historical backfill (HR-max edit → append + supersede, I2)

    /// Recompute day and workout effort across `[from, to]` and append the results. This is the clean
    /// entry point the composition lane wires to a checkpointed BGProcessing job when the user edits
    /// their HR max or zones: because every score is a function of those edited zones, the whole window
    /// must be re-derived — and because derivation is append-only (I2), that is a plain re-run, not a
    /// special mutating path. Each changed day/session APPENDS a fresh row with a new `computedAt`; the
    /// superseded rows keep their `computedAt`, value, and algorithm id, so "what BADAN believed before
    /// the edit" survives and the change is auditable. Idempotent over unchanged data (the skip-if-
    /// identical guard), so a re-run writes nothing.
    ///
    /// Returned so the caller (and the checkpoint) can see how many days/sessions were touched; the day
    /// loop is ordered oldest→newest so a job interrupted midway resumes cleanly from the last written
    /// day.
    @discardableResult
    func recompute(from: Date, to: Date, tz: String = TimeZone.current.identifier) throws -> Int {
        guard spec.isLoaded else { return 0 }
        var touched = 0
        try derivation.transaction {
            var day = DayAttribution.startOfDay(from, tz: tz)
            let lastDayStart = DayAttribution.startOfDay(to, tz: tz)
            while day <= lastDayStart {
                if try computeDay(asOf: day, tz: tz) != nil { touched += 1 }
                day = DayAttribution.addingDays(1, to: day, tz: tz)
            }
            touched += try computeWorkouts(from: from, to: to, tz: tz).count
        }
        return touched
    }

    // MARK: - Guidance (readiness-linked, wellness-safe read model)

    /// A wellness-safe daily guidance read model, linked to Readiness. NOT prescriptive and NOT a
    /// stored value: it reads the day's `readiness.score` (if the sibling engine produced one) and
    /// returns a DIRECTION — a gentler range may suit a low-readiness day, there is headroom on a high
    /// one — plus, when available, a PERSONAL soft ceiling taken from the user's OWN effort baseline
    /// (never a population number). The UI lane owns the bilingual, copy-linted strings ("a gentler
    /// range may suit today: under your typical"); this only supplies the band and the optional number
    /// so the surface never has to invent either. Returns `nil` when there is no Readiness score to
    /// anchor to — no anchor, no suggestion.
    func guidance(asOf: Date, tz: String = TimeZone.current.identifier) throws -> EffortGuidance? {
        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)
        guard let readiness = try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: "day:" + dayKey) else {
            return nil
        }
        let band = Self.guidanceBand(readiness: readiness.value)
        // A personal soft ceiling only when readiness suggests easing off AND the person has an
        // established effort baseline to reference — otherwise the direction alone is the honest output.
        var suggestedCeiling: Double?
        if band == .gentler, let baseline = try derivation.latestBaseline(metricId: MetricID.effortDay),
           !baseline.provisional {
            suggestedCeiling = baseline.center
        }
        return EffortGuidance(readinessBand: band, readinessScore: readiness.value,
                              readinessProvisional: readiness.provisional, suggestedCeiling: suggestedCeiling)
    }

    // MARK: - Persistence (append-only, I2)

    private func persistZoneBased(result: EffortResult, metricId: String, algorithm: AlgorithmVersion) throws {
        guard case let .zoneBased(acc) = result.variant, let score = result.score else { return }
        let unit = registry.definitionOrFallback(metricId).canonicalUnit
        // The algorithm identity is part of the skip check: a version bump that recomputes the same
        // score must still append, or the day's latest row would keep the OLD version id and the
        // change would go unrecorded (auditability; mirrors ReadinessEngine.persist).
        if let existing = try derivation.latestDerived(metricId: metricId, periodKey: result.periodKey),
           existing.algorithmId == algorithm.algorithmId, existing.algorithmVersion == algorithm.semver,
           existing.unit == unit, existing.provisional == spec.params.algorithmProvisional,
           Self.approximatelyEqual(existing.value, score) {
            return
        }
        try derivation.transaction {
            // One manifest input PER ZONE: `value` = minutes in that zone (the zone-time bars read this
            // straight off the manifest), `weight` = that zone's weighted-minutes contribution to `L`.
            // `recordId` is a zone token, not a raw-row id, because an effort score aggregates a whole
            // `heart.hr` series over the window rather than resolving to one record — the lineage is
            // "the HR series in this window", queryable via `rawSamples(heart.hr, window)` (I1/I5).
            let manifest = InputManifest(id: ULID.newID(), inputs: acc.minutesPerZone.enumerated().map { i, minutes in
                InputManifest.Input(recordId: "\(result.periodKey)#zone\(i + 1)", metricId: MetricID.heartRate,
                                    value: minutes, weight: (minutes) * spec.params.zoneWeights[i])
            })
            try derivation.insertManifest(manifest)
            let now = clock.now()
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: metricId, value: score, unit: unit,
                periodKey: result.periodKey, confidence: nil, provisional: spec.params.algorithmProvisional,
                algorithmId: algorithm.algorithmId, algorithmVersion: algorithm.semver,
                inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId))
        }
    }

    private func persistReducedInput(result: EffortResult, load: ActivityLoad,
                                     metricId: String, algorithm: AlgorithmVersion) throws {
        // Same version-aware skip as the zone-based path: a version bump appends even when the
        // reduced-input magnitude is unchanged, so the row's version id never lags the algorithm.
        if let existing = try derivation.latestDerived(metricId: metricId, periodKey: result.periodKey),
           existing.algorithmId == algorithm.algorithmId, existing.algorithmVersion == algorithm.semver,
           existing.unit == load.unit, Self.approximatelyEqual(existing.value, load.magnitude) {
            return
        }
        try derivation.transaction {
            let manifest = InputManifest(id: ULID.newID(), inputs: load.recordIds.map {
                InputManifest.Input(recordId: $0, metricId: load.kind.metricId, value: load.magnitude)
            })
            try derivation.insertManifest(manifest)
            let now = clock.now()
            // `provisional = true` always — a reduced-input activity load is by definition not the
            // validated zone-based score. `confidence` is left nil; the row IS the reduced variant,
            // signalled by its activity unit (not `score_0_100`), which is how the surface labels it.
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: metricId, value: load.magnitude, unit: load.unit,
                periodKey: result.periodKey, confidence: nil, provisional: true,
                algorithmId: algorithm.algorithmId, algorithmVersion: algorithm.semver,
                inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId))
        }
    }

    // MARK: - Input readers

    /// Heart-rate samples in `[from, to]` as `(time-in-seconds, bpm)` ordered by time. Non-positive
    /// readings are dropped (a sensor zero is missing data, not a real 0 bpm). `startAt` is the sample
    /// instant, matching every other event-time read in the app.
    private func hrSamples(from: Date, to: Date) throws -> [(t: Double, bpm: Double)] {
        try measurements.rawSamples(metricId: MetricID.heartRate, from: from, to: to)
            .filter { $0.value.isFinite && $0.value > 0 }
            .map { (t: $0.startAt.timeIntervalSinceReferenceDate, bpm: $0.value) }
    }

    /// Sum an interval metric's values for a local day, with the contributing record ids for lineage.
    /// Each record is attributed by its OWN timezone to the day, exactly as everywhere else. `nil` when
    /// nothing landed on the day.
    private func sumIntervals(metricId: String, from: Date, to: Date, dayKey: String) throws -> (total: Double, ids: [String])? {
        let records = try measurements.intervalRecords(metricId: metricId, from: from, to: to)
            .filter { DayAttribution.localDayKey($0.startAt, tz: $0.tzId) == dayKey }
        guard !records.isEmpty else { return nil }
        return (records.reduce(0) { $0 + $1.value }, records.map(\.id))
    }

    /// Age in whole years at `asOf`, from `birthYear`, or `nil` when no birth year is recorded (the
    /// engine then has no age to derive an HR max from, and degrades honestly rather than guessing one).
    private static func age(profile: UserProfile?, asOf: Date, tz: String) -> Int? {
        guard let birthYear = profile?.birthYear else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz) ?? .current
        let year = cal.component(.year, from: asOf)
        let age = year - birthYear
        return age > 0 ? age : nil
    }

    // MARK: - Pure math (identical on both platforms — golden + property tested)

    /// The published BADAN effort curve: `scaleMax · (1 − e^(−k · L))` over weighted-minutes load `L`.
    /// Bounded above by `scaleMax`, strictly increasing in `L` (more load → higher score) and concave
    /// (each extra weighted-minute adds less than the last — WHOOP's "harder at the top" shape). Both
    /// properties are asserted as property tests. `L` is floored at 0 so a degenerate empty day is 0,
    /// not a rounding artefact below it.
    static func effortScore(load: Double, params: EffortParams) -> Double {
        let L = max(0, load)
        return params.scaleMax * (1 - exp(-params.logCurveK * L))
    }

    /// Weighted-minutes load `L = Σ (minutes-in-zone · zoneWeight)`. Zone 0 (below Z1) contributes
    /// nothing. Strictly monotonic: adding minutes to any zone, or moving a minute to a higher-weighted
    /// zone, only ever raises `L` (hence the score). Pure.
    static func weightedZoneMinutes(minutesPerZone: [Double], zoneWeights: [Double]) -> Double {
        var total = 0.0
        for i in 0..<min(minutesPerZone.count, zoneWeights.count) {
            total += minutesPerZone[i] * zoneWeights[i]
        }
        return total
    }

    /// Attribute HR samples to zones and accumulate the load. Each sample "holds forward" (zero-order
    /// hold) until the next sample or the window end, but a gap longer than `maxAttributableGapSeconds`
    /// is clamped — a recording dropout is not credited as time spent at the last reading (otherwise a
    /// five-minute sensor gap would invent five minutes of whatever zone the last sample fell in). Pure
    /// and deterministic: the same samples produce the same `load`, `coveredSeconds`, and per-zone
    /// minutes on both platforms, which is the acceptance golden.
    static func accumulate(samples: [(t: Double, bpm: Double)], windowEnd: Double,
                           model: HRZoneModel, params: EffortParams) -> ZoneAccumulation {
        let ordered = samples.sorted { $0.t < $1.t }
        var minutesPerZone = [Double](repeating: 0, count: HRZones.zoneCount)
        var coveredSeconds = 0.0
        for (i, sample) in ordered.enumerated() {
            let nextInstant = i + 1 < ordered.count ? ordered[i + 1].t : windowEnd
            let dwell = min(max(nextInstant - sample.t, 0), params.maxAttributableGapSeconds)
            guard dwell > 0 else { continue }
            coveredSeconds += dwell
            let zone = model.zoneIndex(bpm: sample.bpm)   // 0…5
            if zone >= 1 && zone <= HRZones.zoneCount { minutesPerZone[zone - 1] += dwell / 60.0 }
        }
        let load = weightedZoneMinutes(minutesPerZone: minutesPerZone, zoneWeights: params.zoneWeights)
        return ZoneAccumulation(load: load, coveredSeconds: coveredSeconds,
                                minutesPerZone: minutesPerZone, sampleCount: ordered.count)
    }

    /// Heart-rate sample density in samples per minute over a window — the sparse-HR gate for workouts.
    static func hrDensityPerMinute(sampleCount: Int, windowSeconds: Double) -> Double {
        guard windowSeconds > 0 else { return 0 }
        return Double(sampleCount) / (windowSeconds / 60.0)
    }

    /// Map a 0–100 Readiness score to a directional guidance band by even thirds. A presentation split
    /// of an existing score into low/typical/high — deliberately coarse, it makes no physiological
    /// claim an uneven boundary would smuggle in (the same reasoning `WorkoutEffortBands` uses for its
    /// even quarters). `gentler` = readiness in the lowest third; `headroom` = highest; `typical`
    /// otherwise. The thresholds scale with `scaleMax`-independent 0–100 readiness, not effort.
    static func guidanceBand(readiness: Double) -> EffortGuidanceBand {
        if readiness < 100.0 / 3.0 { return .gentler }
        if readiness >= 200.0 / 3.0 { return .headroom }
        return .typical
    }

    static func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }
}

// MARK: - Read models

/// The pure zone accumulation for a window: the weighted-minutes `load` the curve consumes, how many
/// `coveredSeconds` of HR were actually attributed (the reduced-input gate reads this), the per-zone
/// minutes (Z1…Z5 → indices 0…4, what the zone-time bars and the manifest render), and the raw sample
/// count. No I/O or clock — both platforms compute this identically (the goldens assert exactly it).
struct ZoneAccumulation: Sendable, Hashable {
    let load: Double
    let coveredSeconds: Double
    let minutesPerZone: [Double]
    let sampleCount: Int
}

/// Why a day/session produced the reduced-input activity variant instead of a zone-based score —
/// carried so the surface can be specific ("no continuous heart rate today" vs "add your age or max
/// HR to see zones") rather than lumping two different absences under one label.
enum EffortReducedReason: String, Sendable, Hashable {
    /// Continuous HR was present-enough to zone, but too sparse (phone-only, watch not worn / not
    /// recording) — the classic case the guard exists for.
    case sparseHeartRate
    /// No HR max could be established (no `hrMax` override and no birth year), so no zones could be
    /// drawn at all, whatever HR existed.
    case noHeartRateMax
}

/// What kind of movement magnitude the reduced-input activity load is measured in. Active energy is
/// preferred (it captures non-step activity); steps are the fallback for a day with no energy record.
enum ActivityLoadKind: Sendable, Hashable {
    case activeEnergy
    case steps

    var metricId: String {
        switch self {
        case .activeEnergy: return MetricID.activeEnergy
        case .steps: return MetricID.steps
        }
    }
}

/// The reduced-input activity load: a truthful raw movement magnitude (not a fabricated 0–100 score),
/// its unit, and the record ids that fed it. Persisted under the effort id but with THIS unit, which
/// is how a reader tells a reduced-input row from a zone-based `score_0_100` one.
struct ActivityLoad: Sendable, Hashable {
    let kind: ActivityLoadKind
    let magnitude: Double
    let unit: String
    let recordIds: [String]
}

/// Which model produced a period's effort. `zoneBased` carries the full zone accumulation (score +
/// bars + anatomy); `reducedInput` carries the activity load and the reason, so the surface labels the
/// degradation DISTINCTLY rather than passing a thinner reading off as the score (plan §11 EPIC-26).
enum EffortVariant: Sendable, Hashable {
    case zoneBased(ZoneAccumulation)
    case reducedInput(ActivityLoad, reason: EffortReducedReason)
}

/// A computed effort result for one period (a day `day:<key>` or a session `session:<id>`): the
/// variant, and the 0–`scaleMax` `score` for zone-based results (`nil` for reduced-input, which has a
/// magnitude, not a score). What `computeDay`/`computeWorkouts` return and persist.
struct EffortResult: Sendable, Hashable {
    let periodKey: String
    let variant: EffortVariant
    let score: Double?
}

/// The directional readiness→effort guidance band. Never a command — a suggestion of range.
enum EffortGuidanceBand: String, Sendable, Hashable {
    case gentler   // low readiness: a gentler range may suit today
    case typical   // mid readiness: your usual range
    case headroom  // high readiness: room to push if you want it
}

/// The wellness-safe guidance read model. `readinessBand` is the direction; `suggestedCeiling` is an
/// OPTIONAL personal number (the user's own effort-baseline centre) offered only on a gentler day with
/// an established baseline — never a population target. The UI lane turns this into copy; the engine
/// never authors user-facing strings.
struct EffortGuidance: Sendable, Hashable {
    let readinessBand: EffortGuidanceBand
    let readinessScore: Double
    let readinessProvisional: Bool
    let suggestedCeiling: Double?
}

// MARK: - Spec (data-driven params, mirror of ReadinessSpec/BaselineSpec)

/// The data-driven Effort spec: the ONLY place the scale, zone weights, curve steepness, zone floors,
/// HR-max default and sparse threshold enter the engine — never hardcoded — so the two platforms
/// cannot drift and a change is a reviewable one-line contract diff plus a semver bump. It resolves
/// `effort.day` (scale, weights, curve, floors, Tanaka constants) and `effort.workout` (the sparse
/// threshold; its scale/curve MUST match `effort.day`'s per the contract, asserted by a golden). A
/// spec that failed to load (`isLoaded == false`) makes the engine COMPUTE NOTHING rather than invent
/// constants (mirror of `ReadinessSpec`).
struct EffortSpec: Sendable, Hashable {
    let dayAlgorithm: AlgorithmVersion
    let workoutAlgorithm: AlgorithmVersion
    let params: EffortParams
    let isLoaded: Bool

    private static let dayContractId = "effort.day"
    private static let workoutContractId = "effort.workout"

    /// Resolve from a loaded `AlgorithmRegistry`. Returns `.unavailable` if either entry or any
    /// required param is missing — the engine treats that as "compute nothing", never as a cue to
    /// invent one (mirror of `ReadinessSpec.load`).
    static func load(from registry: AlgorithmRegistry) -> EffortSpec {
        guard let day = registry.definition(dayContractId),
              let workout = registry.definition(workoutContractId) else { return .unavailable }
        guard let scaleMax = day.params["scaleMax"],
              let k = day.params["logCurveK"],
              let hrMaxConstant = day.params["hrMaxConstant"],
              let hrMaxAgeCoefficient = day.params["hrMaxAgeCoefficient"],
              let sparse = workout.params["sparseHrFallbackMinSamplesPerMinute"] else { return .unavailable }
        var weights: [Double] = []
        var floors: [Double] = []
        for z in 1...HRZones.zoneCount {
            guard let w = day.params["zone\(z)Weight"], let f = day.params["zone\(z)FloorPctHrMax"] else { return .unavailable }
            weights.append(w)
            floors.append(f)
        }
        let params = EffortParams(
            scaleMax: scaleMax, zoneWeights: weights, logCurveK: k, zoneFloorPcts: floors,
            hrMaxConstant: hrMaxConstant, hrMaxAgeCoefficient: hrMaxAgeCoefficient,
            sparseHrMinSamplesPerMinute: sparse, algorithmProvisional: day.provisional)
        return EffortSpec(dayAlgorithm: day.algorithmVersion, workoutAlgorithm: workout.algorithmVersion,
                          params: params, isLoaded: true)
    }

    /// The app-default spec, resolved once from the bundled contract.
    static let defaultShared = load(from: .shared)

    /// The degenerate "the contract did not load" spec. Never produces a score.
    static let unavailable = EffortSpec(
        dayAlgorithm: AlgorithmVersion(algorithmId: dayContractId, semver: "0.0.0", introducedIn: "0.0.0"),
        workoutAlgorithm: AlgorithmVersion(algorithmId: workoutContractId, semver: "0.0.0", introducedIn: "0.0.0"),
        params: EffortParams(scaleMax: 0, zoneWeights: [], logCurveK: 0, zoneFloorPcts: [],
                             hrMaxConstant: 0, hrMaxAgeCoefficient: 0, sparseHrMinSamplesPerMinute: 0,
                             algorithmProvisional: true),
        isLoaded: false)
}
