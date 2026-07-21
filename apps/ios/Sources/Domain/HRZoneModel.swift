import Foundation

/// The numeric constants the Effort engine (EPIC-26) computes on, resolved once from the algorithm
/// contract (`effort.day` + `effort.workout` in `algorithms.json`) and passed to the pure math so
/// that math never reaches for the registry. This is the effort analogue of `ReadinessParams` /
/// `BaselineSpec`: every number the score depends on is versioned DATA here, never a literal in an
/// engine, so the two platforms cannot drift and a tuning change is a reviewable one-line contract
/// diff plus a semver bump (INVARIANT I2 keeps old rows on their old constants).
///
/// The scale is deliberately NOT hard-coded to 21 or 100. Plan §28 A3 selected a 0–21 WHOOP-shaped
/// scale, but the shipped contract still carries `scaleMax = 100` (and the registry still calls
/// `effort.day`'s unit `score_0_100`) — this engine reads `scaleMax` from the contract and renders
/// whatever it says, so the day the contract is updated to 21 the engine produces 0–21 with no code
/// change. That is the whole point of constants-as-data: baking either number in here would defeat
/// it. See `docs/algorithms/effort.md`.
struct EffortParams: Sendable, Hashable {
    /// The top of the effort scale (contract `scaleMax`). The saturating curve approaches but never
    /// reaches it; a change here rescales every future score without touching a metric id.
    let scaleMax: Double
    /// Per-zone multipliers Z1…Z5 (roughly geometric), applied to minutes-in-zone before the curve.
    /// A minute of Z5 therefore contributes far more load than a minute of Z1 — the "intensity is
    /// rewarded, but a single hard interval can't swamp a long easy day" shape.
    let zoneWeights: [Double]
    /// Curve steepness `k` in `scaleMax · (1 − e^(−k·L))`. Governs how quickly the score saturates
    /// as weighted-minutes accumulate; provisional and re-tuned together with `scaleMax`.
    let logCurveK: Double
    /// Default zone lower edges as a PERCENTAGE of the person's max HR (Z1…Z5, e.g. 50/60/70/80/90).
    /// Used only when the user has no stored `HRZones` override; the override's own bpm edges win.
    let zoneFloorPcts: [Double]
    /// Tanaka (2001) default-max-HR intercept and slope: `hrMaxConstant − hrMaxAgeCoefficient · age`.
    /// A DEFAULT, never a measured maximum, and never used when `UserProfile.hrMax` is set.
    let hrMaxConstant: Double
    let hrMaxAgeCoefficient: Double
    /// Below this heart-rate sample density (samples per minute) a WORKOUT is treated as having no
    /// continuous HR and falls to the reduced-input activity variant instead of a zero-looking score.
    let sparseHrMinSamplesPerMinute: Double
    /// The contract's `provisional` flag for `effort.day`. A provisional algorithm stamps every row it
    /// produces `provisional = true`, so the surface can say the constants are not yet validated.
    let algorithmProvisional: Bool

    /// The longest inter-sample gap credited as continuous time-in-zone, in seconds. DERIVED from the
    /// sparse-density threshold rather than a second magic literal: if HR is being sampled at least at
    /// the sparse density (`sparseHrMinSamplesPerMinute` per minute), consecutive samples are at most
    /// `60 / that` seconds apart, so a longer gap is a recording dropout (wrist lifted, session
    /// paused), not time the person actually held a zone. Tying the two together means the "what
    /// counts as continuous HR" decision has one source of truth. This mirrors the intent of the
    /// EPIC-03 `WorkoutEffortBands.maxSampleGapSeconds` guard (a fixed 90s there); EPIC-26 derives it
    /// from the contract so a change to the density gate moves both in lockstep.
    var maxAttributableGapSeconds: Double {
        sparseHrMinSamplesPerMinute > 0 ? 60.0 / sparseHrMinSamplesPerMinute : 90.0
    }
}

/// The DEFAULT heart-rate zone COMPUTATION EPIC-26 owns — the derivation half of the zone model.
/// `HRZones` (Domain/HRZones.swift, the profile-schema lane's type) is the STORAGE half: the user's
/// edited bpm override. Keeping the two apart is the same discipline the rest of BADAN follows — a
/// stored value type never derives, and every constant the derivation uses (the floor percentages,
/// the Tanaka coefficients) is versioned DATA in `EffortParams`, never a literal here — which is what
/// lets the score stay inspectable and a params change stay a reviewable diff.
///
/// A model is just the five zone FLOORS in bpm, ascending. Classification is floor-based: a reading
/// lands in the highest zone whose floor it meets, and the top zone is OPEN above Z5's floor. That
/// openness is deliberate — an age-derived HR max is an estimate, not a ceiling, so a reading above
/// it is still Z5, never dropped as "off the chart". Because classification needs only the lower
/// edges, the model never has to invent an upper bound for the top zone (the honesty problem that a
/// fixed ceiling would create), and a stored override's own upper bounds are used for display/editing
/// but not for placing a sample.
struct HRZoneModel: Sendable, Hashable {
    /// Zone lower edges in bpm, ascending: `[Z1floor, Z2floor, Z3floor, Z4floor, Z5floor]`. Length is
    /// always `HRZones.zoneCount`; a reading below `floorsBpm[0]` is "zone 0" and carries no load.
    let floorsBpm: [Double]

    /// The zone a heart-rate reading falls in: 0 (below Z1 — no cardiovascular load) through
    /// `HRZones.zoneCount`. Pure and platform-identical (golden-tested) — the count of floors the
    /// reading meets or exceeds, so an ascending-floor invariant is all it depends on.
    func zoneIndex(bpm: Double) -> Int {
        var idx = 0
        for (i, floor) in floorsBpm.enumerated() where bpm >= floor { idx = i + 1 }
        return idx
    }

    /// Resolve the effective model for a person. Precedence, and why:
    ///  1. a well-formed stored `HRZones` override → its zone floors (the user's explicit choice wins
    ///     over any derivation, exactly as `UserProfile.hrMax` wins over the age default);
    ///  2. else an effective HR max (`hrMax`, or the age-derived Tanaka default) → the contract floor
    ///     percentages applied to it.
    /// Returns `nil` when neither can be established (no override, no `hrMax`, no age): the engine then
    /// cannot honestly place a reading into a zone and degrades to the labelled reduced-input activity
    /// variant rather than inventing an age it does not have (COLD START IS HONEST).
    static func resolve(override: HRZones?, hrMax: Double?, age: Int?, params: EffortParams) -> HRZoneModel? {
        if let override, override.isWellFormed {
            return HRZoneModel(floorsBpm: override.zones.map { Double($0.lowerBpm) })
        }
        guard let max = effectiveHrMax(hrMax: hrMax, age: age, params: params), max > 0 else { return nil }
        return HRZoneModel(floorsBpm: params.zoneFloorPcts.map { $0 / 100.0 * max })
    }

    /// The effective maximum heart rate: the profile override if set and positive, else the age-derived
    /// Tanaka default (`hrMaxConstant − hrMaxAgeCoefficient · age`), else `nil`. A negative/zero age is
    /// treated as unusable (nil) rather than producing an inflated max from a bad birth year.
    static func effectiveHrMax(hrMax: Double?, age: Int?, params: EffortParams) -> Double? {
        if let hrMax, hrMax > 0 { return hrMax }
        guard let age, age > 0 else { return nil }
        let derived = params.hrMaxConstant - params.hrMaxAgeCoefficient * Double(age)
        return derived > 0 ? derived : nil
    }

    /// A default five-zone override (whole bpm) to SEED the profile editor from an HR max — the UI lane
    /// presents it and lets the user adjust, and storing the adjusted result makes it an override like
    /// any other. Upper bounds are display-only (classification uses floors), so Z5's upper is the
    /// estimated max itself; the user can widen it. Whole bpm because a zone edge shown as "142.6" is
    /// the false precision `HRZone` exists to avoid.
    static func defaultZones(hrMax: Double, params: EffortParams) -> HRZones {
        let floors = params.zoneFloorPcts.map { $0 / 100.0 * hrMax }
        var zones: [HRZone] = []
        for i in 0..<floors.count {
            let lower = Int(floors[i].rounded())
            // Each zone runs up to one below the next zone's floor; the top zone runs up to the max.
            let upperExclusive = i + 1 < floors.count ? floors[i + 1] : hrMax
            let upper = i + 1 < floors.count ? Int(upperExclusive.rounded()) - 1 : Int(hrMax.rounded())
            zones.append(HRZone(lowerBpm: lower, upperBpm: Swift.max(upper, lower)))
        }
        return HRZones(zones: zones)
    }
}
