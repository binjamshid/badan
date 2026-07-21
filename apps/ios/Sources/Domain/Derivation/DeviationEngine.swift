import Foundation

/// EPIC-27 — the read model behind the Health Monitor. Reads the personal bands EPIC-23 already
/// materialized (`Baseline` rows) and the latest raw reading of each tracked vital, and classifies
/// where the reading sits — never inventing a new stored score, never a population norm, never an
/// absolute skin temperature.
///
/// **This engine writes nothing.** It is a pure read model over `Baseline` + latest measurement, the
/// same shape as `BaselineEngine.calibration(metricId:)`. Band classification is a deterministic
/// position comparison (value vs the band's own published edges), fully explained by the baseline's
/// own `AlgorithmVersion` and `docs/algorithms/baselines.md` — so it needs no `DerivedValue`/
/// `AlgorithmVersion` row of its own (there is no second number to audit, only a comparison the tile
/// exposes the operands of). Producing a stored score here would be a score without provenance,
/// which is the one thing the anatomy sheet exists to prevent.
///
/// **The classification core is pure and static** (`makeTile`, `tempDirection`, `buildSparkline`,
/// `resolveSourceQuality`) so the pure-JVM Android mirror produces identical tiles and identical
/// bilingual copy from the same inputs — that parity is the acceptance anchor, exactly as it is for
/// `BaselineEngine.computeBaseline`. The DB orchestration (`buildReadModel`) is exercised on iOS,
/// which is the only platform with a DB-backed test harness (see `BaselineEngineGoldenTest`'s note).
final class DeviationEngine {
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let catalog: CatalogRepository
    private let registry: MetricRegistry
    private let sensorQuality: SensorQualityMap
    private let clock: Clock
    private let config: DeviationConfig

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         catalog: CatalogRepository, registry: MetricRegistry = .shared,
         sensorQuality: SensorQualityMap = .shared, clock: Clock,
         config: DeviationConfig = .default) {
        self.derivation = derivation
        self.measurements = measurements
        self.catalog = catalog
        self.registry = registry
        self.sensorQuality = sensorQuality
        self.clock = clock
        self.config = config
    }

    /// The vitals the Health Monitor tracks, in display order (plan §11 EPIC-27: RHR, HRV, RR,
    /// SpO2, wrist-temperature deviation). Ordered, not a `Set` — the tile grid reads top-to-bottom
    /// in this order, and the read model preserves it.
    static let vitals: [String] = [
        MetricID.restingHeartRate, MetricID.hrv, MetricID.respiratoryRate,
        MetricID.spo2, MetricID.wristTempDeviation,
    ]

    /// Metric ids whose STORED value is already a deviation from the person's own baseline, not an
    /// absolute reading. A tile for one of these is rendered as `VitalReading.deviation` with no
    /// band by construction — the read model shape then carries no field that could hold an absolute
    /// skin temperature, so the UI cannot render one (EPIC-27 acceptance: temperature is
    /// deviation-only by construction). The registry marks `body.wrist_temp_deviation`
    /// non-baseline-eligible for the same reason, so no `Baseline` row is ever drawn for it anyway;
    /// this set is the belt to that suspenders, enforced in `makeTile` regardless of what is passed.
    static let deviationVitals: Set<String> = [MetricID.wristTempDeviation]

    // MARK: - Read model assembly (DB-backed; iOS-tested)

    /// Build the Health Monitor read model as of `asOf` (defaults to the injected clock's now).
    ///
    /// For each vital: the latest reading (of any age — a reading older than the sparkline window is
    /// still shown, marked stale, rather than collapsed to "no data"), the recent per-day series for
    /// the sparkline (gaps preserved, never zero-filled), the personal band for banded vitals, and
    /// the per-source sensor-quality label for whatever source produced the latest reading. A vital
    /// with no reading at all becomes a first-class `noData` tile, not a crash and not a fake zero.
    func buildReadModel(asOf: Date? = nil, tz: String = TimeZone.current.identifier) throws -> HealthMonitorReadModel {
        let now = asOf ?? clock.now()
        let asOfDayStart = DayAttribution.startOfDay(now, tz: tz)
        // A reading is "stale" once its own day is strictly before (asOf − staleAfterDays). The
        // vitals are overnight and ~once-daily, so a two-day-old RHR is honestly "as of Tuesday",
        // not a live "now". Compared as YYYY-MM-DD strings, which sort chronologically.
        let staleCutoffDay = DayAttribution.localDayKey(
            DayAttribution.addingDays(-config.staleAfterDays, to: asOfDayStart, tz: tz), tz: tz)

        // The sparkline day axis: the most recent `sparklineDays` calendar days, oldest first. Built
        // as an explicit axis so `buildSparkline` can render missing days as gaps rather than the
        // series silently skipping them (plan §18: missing-input days are gaps, not zeros).
        let windowStart = DayAttribution.addingDays(-(config.sparklineDays - 1), to: asOfDayStart, tz: tz)
        var axisDays: [String] = []
        axisDays.reserveCapacity(config.sparklineDays)
        for i in 0..<config.sparklineDays {
            axisDays.append(DayAttribution.localDayKey(DayAttribution.addingDays(i, to: windowStart, tz: tz), tz: tz))
        }
        let windowFrom = windowStart
        let windowTo = DayAttribution.addingDays(1, to: asOfDayStart, tz: tz).addingTimeInterval(-1)

        var tiles: [VitalTile] = []
        tiles.reserveCapacity(Self.vitals.count)
        for metricId in Self.vitals {
            let def = registry.definitionOrFallback(metricId)

            // Latest reading of any age, for the "current value" + staleness + source attribution.
            let latestRecord = try measurements.latestInterval(metricId: metricId)
            let latest = latestRecord.map { DayValue(day: DayAttribution.localDayKey($0.startAt, tz: $0.tzId), value: $0.value) }

            // Recent per-day series for the sparkline, reduced deterministically per day.
            let windowRecords = try measurements.intervalRecords(metricId: metricId, from: windowFrom, to: windowTo)
            let byDay = Self.perDayLatest(windowRecords)
            let sparkline = Self.buildSparkline(axisDays: axisDays, byDay: byDay)

            // Personal band — only for banded vitals. Deviation-only vitals never get one, even if a
            // stray `Baseline` somehow existed, because `makeTile` forces `band = nil` for them.
            let band = Self.deviationVitals.contains(metricId)
                ? nil
                : try derivation.latestBaseline(metricId: metricId)

            // Per-source sensor-quality, attributed to the source that produced the latest reading.
            let sourceQuality: SourceQualityLabel?
            if let sourceId = latestRecord?.provenance.sourceId {
                let source = try catalog.source(id: sourceId)
                let devices = source == nil ? [] : try catalog.devices(sourceId: sourceId)
                sourceQuality = Self.resolveSourceQuality(source: source, devices: devices,
                                                          family: def.familyGroup, map: sensorQuality)
            } else {
                sourceQuality = nil
            }

            tiles.append(Self.makeTile(def: def, latest: latest, band: band, sparkline: sparkline,
                                       sourceQuality: sourceQuality, staleCutoffDay: staleCutoffDay))
        }

        return HealthMonitorReadModel(vitals: tiles, disclaimer: Self.disclaimer, generatedAt: now)
    }

    // MARK: - Pure tile assembly (identical on both platforms — golden-tested)

    /// Assemble one vital's tile from already-fetched inputs. Pure: no I/O, no clock, no repos — so
    /// both platforms produce byte-identical tiles and identical bilingual copy from the same inputs.
    ///
    /// The honesty rules are all enforced here, by construction:
    /// - `deviationVitals` (temperature) are forced to `.deviation` with `band = nil`; there is no
    ///   code path that gives one an `.absolute` reading or a numeric band.
    /// - A banded vital is only classified against an ESTABLISHED band. A provisional or absent band
    ///   yields `.calibrating`, never a fabricated in/out-of-range verdict (plan §18 cold start).
    /// - The calm out-of-band annotation is suppressed on a stale tile: "your latest reading sits
    ///   above your usual range" would misread as current when the reading is days old. The tile's
    ///   `asOfDay` + `isStale` carry the honest framing instead.
    static func makeTile(def: MetricDefinition, latest: DayValue?, band: Baseline?,
                         sparkline: [SparklinePoint], sourceQuality: SourceQualityLabel?,
                         staleCutoffDay: String) -> VitalTile {
        let isDeviationVital = deviationVitals.contains(def.metricId)
        let personalBand = isDeviationVital ? nil : band.map { PersonalBand(baseline: $0) }

        guard let latest else {
            // No reading in the store at all — a first-class empty tile, not a zero.
            return VitalTile(metricId: def.metricId, family: def.familyGroup, title: def.displayName,
                             unit: def.canonicalUnit, reading: nil, asOfDay: nil, band: personalBand,
                             state: .noData, isStale: false, annotation: nil, sparkline: sparkline,
                             sourceQuality: sourceQuality)
        }

        let isStale = latest.day < staleCutoffDay
        let reading: VitalReading
        let state: VitalState
        var annotation: LocalizedString?

        if isDeviationVital {
            // Temperature: the stored value IS the deviation. Rendered only as a signed deviation,
            // with direction (not a band verdict) derived from its sign.
            reading = .deviation(latest.value)
            let direction = tempDirection(latest.value)
            state = .deviation(direction)
            annotation = isStale ? nil : tempAnnotation(direction)
        } else {
            reading = .absolute(latest.value)
            if let band, !band.provisional {
                switch band.position(of: latest.value) {
                case .within: state = .withinBand; annotation = nil
                case .below: state = .belowBand; annotation = isStale ? nil : bandAnnotation(.below)
                case .above: state = .aboveBand; annotation = isStale ? nil : bandAnnotation(.above)
                }
            } else {
                // Reading present but no established band to judge it against yet — honest cold start.
                state = .calibrating
                annotation = nil
            }
        }

        return VitalTile(metricId: def.metricId, family: def.familyGroup, title: def.displayName,
                         unit: def.canonicalUnit, reading: reading, asOfDay: latest.day, band: personalBand,
                         state: state, isStale: isStale, annotation: annotation, sparkline: sparkline,
                         sourceQuality: sourceQuality)
    }

    /// Direction of a temperature deviation from the personal usual level. Sign only — the stored
    /// value is already rounded upstream, so a bare sign avoids inventing a "how far is meaningful"
    /// threshold, which without a personal spread could only be a population norm (forbidden in v1).
    static func tempDirection(_ deviation: Double) -> TempDirection {
        if deviation > 0 { return .aboveUsual }
        if deviation < 0 { return .belowUsual }
        return .atUsual
    }

    /// Map the sparkline day axis onto the per-day values, emitting `nil` for any day with no
    /// reading. The gap is preserved as a hole in the series, never as a zero — a day the watch
    /// wasn't worn is missing data, not a resting heart rate of 0 (plan §18 missing-data rule).
    static func buildSparkline(axisDays: [String], byDay: [String: Double]) -> [SparklinePoint] {
        axisDays.map { SparklinePoint(day: $0, value: byDay[$0]) }
    }

    /// Resolve the per-source sensor-quality label for a source that produced a reading, following
    /// the `SensorQualityMap` contract exactly (device-keyword class match → family level). `nil`
    /// when there is no source to attribute — an honest absence, not a guessed label.
    ///
    /// This is the plan's "`Source.sensorQuality` wiring": a source's quality is RESOLVED from the
    /// published contract at read time, not stored as a column. The contract is emphatic that class
    /// assignment "lives in code, not here" (model strings churn faster than a shared contract
    /// should), so a stored field would be a stale allowlist — the map's `classId(for:devices:)` is
    /// the single resolution point, and this composes it with `level(sourceClassId:family:)`.
    static func resolveSourceQuality(source: Source?, devices: [Device], family: MetricFamily,
                                     map: SensorQualityMap) -> SourceQualityLabel? {
        guard let source else { return nil }
        let classId = map.classId(for: source, devices: devices)
        let level = map.level(sourceClassId: classId, family: family)
        return SourceQualityLabel(sourceId: source.id, sourceDisplayName: source.displayName,
                                  sourceClassId: classId, level: level)
    }

    // MARK: - DB helpers (iOS-only path)

    /// Reduce a window's interval records to one value per local day, keyed in each record's own
    /// timezone. "Latest" mirrors `BaselineEngine.latestPerDay`: strictly newer `updatedAt` wins; an
    /// exact tie falls back to the lexicographically smaller `sourceId` so the choice is
    /// deterministic and not dependent on incidental query order (DATA-09).
    private static func perDayLatest(_ records: [IntervalRecord]) -> [String: Double] {
        var byDay: [String: (value: Double, updatedAt: Date, sourceId: String)] = [:]
        for r in records {
            let day = DayAttribution.localDayKey(r.startAt, tz: r.tzId)
            if let existing = byDay[day] {
                let newer = r.updatedAt > existing.updatedAt
                    || (r.updatedAt == existing.updatedAt && r.provenance.sourceId < existing.sourceId)
                if !newer { continue }
            }
            byDay[day] = (r.value, r.updatedAt, r.provenance.sourceId)
        }
        return byDay.mapValues { $0.value }
    }

    // MARK: - Copy (authored once, parity-asserted; the UI resolves the language)

    /// The persistent "not a medical evaluation" footer (plan §11 EPIC-27 risk mitigation). MANDATORY
    /// — the UI renders it, but it lives in the read model so its presence and exact wording are
    /// asserted by a test and the copy lint, not left to a view that could forget it. Wellness-safe:
    /// states what the surface is (a personal wellness overview of past readings), never a verdict.
    static let disclaimer = LocalizedString(
        en: "This is a wellness overview, not a medical evaluation. It reflects your own past readings.",
        ar: "هذه نظرة عامة على العافية، وليست تقييماً طبياً. تعكس قراءاتك السابقة الخاصة بك.")

    /// Calm, directional, personal note for a banded vital sitting outside its usual range. Never a
    /// verdict ("good"/"bad"), never a diagnosis, never an instruction — it names where the latest
    /// reading sits relative to the person's OWN band and stops there.
    static func bandAnnotation(_ position: Baseline.Position) -> LocalizedString? {
        switch position {
        case .within: return nil
        case .above: return LocalizedString(
            en: "Your latest reading sits above your usual range.",
            ar: "قراءتك الأخيرة أعلى من نطاقك المعتاد.")
        case .below: return LocalizedString(
            en: "Your latest reading sits below your usual range.",
            ar: "قراءتك الأخيرة أدنى من نطاقك المعتاد.")
        }
    }

    /// The temperature counterpart: names the overnight reading's direction from the usual level,
    /// nothing more. `atUsual` carries no annotation — silence is the safe default.
    static func tempAnnotation(_ direction: TempDirection) -> LocalizedString? {
        switch direction {
        case .atUsual: return nil
        case .aboveUsual: return LocalizedString(
            en: "Your latest overnight reading sits above your usual level.",
            ar: "قراءتك الليلية الأخيرة أعلى من مستواك المعتاد.")
        case .belowUsual: return LocalizedString(
            en: "Your latest overnight reading sits below your usual level.",
            ar: "قراءتك الليلية الأخيرة أدنى من مستواك المعتاد.")
        }
    }
}

// MARK: - Read model

/// The Health Monitor read model (EPIC-27). One tile per tracked vital plus the mandatory
/// wellness-safe footer. Pure data: the UI lane (stage 3) owns rendering, colour and layout; this
/// owns the numbers, the honest state, and the bilingual copy that MUST NOT drift between platforms.
struct HealthMonitorReadModel: Sendable, Hashable {
    let vitals: [VitalTile]
    /// The persistent "not a medical evaluation" footer — see `DeviationEngine.disclaimer`.
    let disclaimer: LocalizedString
    let generatedAt: Date
}

/// One vital's tile. No-data and stale are first-class states here (never a crash, never a fake
/// zero): a tile with `reading == nil` is `.noData`, and a real-but-old reading carries `isStale`.
struct VitalTile: Sendable, Hashable, Identifiable {
    let metricId: String
    let family: MetricFamily
    /// Registry name, en+ar. The UI picks casual/precise per its own depth policy.
    let title: LocalizedString
    /// Canonical unit for the reading (e.g. "bpm", "ms", "degC"). The UI formats it.
    let unit: String
    /// The latest reading, or `nil` when there is none — the tile is then `.noData`.
    let reading: VitalReading?
    /// The local day (YYYY-MM-DD) the reading belongs to, for "as of <day>" on a stale tile.
    let asOfDay: String?
    /// The personal band this vital is judged against. `nil` for temperature (deviation-only, no
    /// band by construction). Present-but-`provisional` for a banded vital still calibrating.
    let band: PersonalBand?
    let state: VitalState
    /// The latest reading exists but its day is older than the freshness horizon. `false` on a
    /// no-data tile (nothing to be stale). Independent of `state`, which still shows the last known
    /// position — a stale tile reads "as of Tuesday, within your usual range", not a live verdict.
    let isStale: Bool
    /// The calm, wellness-safe note when the reading sits outside the usual range (suppressed while
    /// stale). `nil` within band / at usual / calibrating / no data — silence is the safe default.
    let annotation: LocalizedString?
    /// Recent per-day series for the sparkline; a day with no reading is a `nil` point (a gap).
    let sparkline: [SparklinePoint]
    /// Per-source sensor-quality for the source that produced the latest reading. `nil` when there
    /// is no reading to attribute.
    let sourceQuality: SourceQualityLabel?

    var id: String { metricId }
}

/// How a vital's current value is represented.
///
/// The two cases are the whole enforcement of "temperature is shown only as a deviation": there is
/// deliberately NO case that carries an absolute skin temperature, so a tile built for
/// `body.wrist_temp_deviation` — which `DeviationEngine.makeTile` always gives `.deviation` — cannot
/// render one. A reviewer cannot add an absolute temperature to the UI without first adding a case
/// here, which is exactly the friction the EPIC-27 acceptance ("temp is deviation-only by
/// construction") calls for.
enum VitalReading: Sendable, Hashable {
    /// A directly-readable vital in the tile's canonical unit (RHR, HRV, RR, SpO2).
    case absolute(Double)
    /// A SIGNED deviation from the person's own usual level, in the tile's canonical unit — the only
    /// representation temperature is ever given.
    case deviation(Double)
}

/// Where a vital's latest reading sits. `deviation` is temperature's own state — a direction from
/// the personal usual level, never an in/out-of-band verdict (there is no band to judge against).
enum VitalState: Sendable, Hashable {
    /// No reading in the store — a first-class empty state, not a zero.
    case noData
    /// A reading exists but there is no established personal band to judge it against yet (the band
    /// is provisional or absent). Nothing is claimed about in/out of range — cold start is honest.
    case calibrating
    case withinBand
    case belowBand
    case aboveBand
    /// Temperature only: a signed deviation from the personal usual level, shown by direction.
    case deviation(TempDirection)
}

/// The direction of a temperature deviation from the personal usual level.
enum TempDirection: Sendable, Hashable {
    case atUsual
    case aboveUsual
    case belowUsual
}

/// A personal band, projected from a `Baseline` row for the read model. Carries the band edges the
/// UI draws, the calibration state, and enough provenance (`baselineId` + `algorithmVersion`) for
/// the anatomy sheet to trace the number back to the exact baseline that drew it (I1).
struct PersonalBand: Sendable, Hashable {
    let low: Double
    let high: Double
    let center: Double
    let unit: String
    let provisional: Bool
    let nPoints: Int
    let windowDays: Int
    let baselineId: String
    let algorithmVersion: String

    init(baseline: Baseline) {
        self.low = baseline.bandLow
        self.high = baseline.bandHigh
        self.center = baseline.center
        self.unit = baseline.unit
        self.provisional = baseline.provisional
        self.nPoints = baseline.nPoints
        self.windowDays = baseline.windowDays
        self.baselineId = baseline.id
        self.algorithmVersion = baseline.algorithmVersion
    }
}

/// One point of a tile's sparkline. `value == nil` marks a day with no reading — a gap, never a
/// zero (plan §18: missing-input days render as gaps).
struct SparklinePoint: Sendable, Hashable {
    let day: String
    let value: Double?
}

/// The per-source sensor-quality label attached to a tile: which source produced the reading, which
/// sensor class it resolved to, and how much that class is worth for this family. The UI renders
/// `SensorQualityLevel.label`/`.explainer` (already bilingual). An honesty surface, never a
/// suppressor — see `SensorQualityMap`'s header.
struct SourceQualityLabel: Sendable, Hashable {
    let sourceId: String
    let sourceDisplayName: String
    let sourceClassId: String
    let level: SensorQualityLevel
}

/// Read-model presentation parameters — NOT score constants. The band math and its constants live
/// in `algorithms.json` and belong to `BaselineEngine`; these govern only how much recent history a
/// tile's sparkline shows and how old a reading may be before it is marked stale. Kept here as
/// named, documented defaults (identical on both platforms by construction) and published in
/// `docs/algorithms/health-monitor.md`.
struct DeviationConfig: Sendable, Hashable {
    /// Calendar days of recent per-day history the sparkline covers (including the as-of day).
    let sparklineDays: Int
    /// A reading whose day is more than this many days before the as-of day is marked stale.
    let staleAfterDays: Int

    static let `default` = DeviationConfig(sparklineDays: 14, staleAfterDays: 2)
}

/// A single day's value, the platform-neutral primitive the pure tile core operates on (so the
/// classification logic never touches `IntervalRecord`'s platform-specific `Date`/`Long`).
struct DayValue: Sendable, Hashable {
    let day: String
    let value: Double
}
