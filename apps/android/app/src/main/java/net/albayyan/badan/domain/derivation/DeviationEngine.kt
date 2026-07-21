package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.ontology.SensorQualityLevel
import net.albayyan.badan.ontology.SensorQualityMap
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.TimeZone

/**
 * EPIC-27 — the read model behind the Health Monitor. Reads the personal bands EPIC-23 already
 * materialized ([Baseline] rows) and the latest raw reading of each tracked vital, and classifies
 * where the reading sits — never inventing a new stored score, never a population norm, never an
 * absolute skin temperature. Mirror of iOS `DeviationEngine`.
 *
 * **This engine writes nothing.** It is a pure read model over [Baseline] + latest measurement, the
 * same shape as `BaselineEngine.calibration`. Band classification is a deterministic position
 * comparison (value vs the band's own published edges), fully explained by the baseline's own
 * `AlgorithmVersion` and `docs/algorithms/baselines.md` — so it needs no `DerivedValue`/
 * `AlgorithmVersion` row of its own (there is no second number to audit, only a comparison the tile
 * exposes the operands of). Producing a stored score here would be a score without provenance, which
 * is the one thing the anatomy sheet exists to prevent.
 *
 * **The classification core is pure** ([makeTile], [tempDirection], [buildSparkline],
 * [resolveSourceQuality]) so it produces tiles and bilingual copy byte-identical to iOS from the
 * same inputs — that parity is the acceptance anchor, exactly as it is for `BaselineEngine`'s pure
 * math. Android has no DB-backed test harness (see `BaselineEngineGoldenTest`'s note), so the DB
 * orchestration in [buildReadModel] is exercised on iOS; what `DeviationEngineTest` runs here is the
 * pure core and the copy.
 */
class DeviationEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val catalog: CatalogRepository,
    private val registry: MetricRegistry,
    private val sensorQuality: SensorQualityMap,
    private val clock: Clock,
    private val config: DeviationConfig = DeviationConfig.DEFAULT,
) {

    // MARK: - Read model assembly (DB-backed; iOS-tested)

    /**
     * Build the Health Monitor read model as of [asOf] (defaults to the injected clock's now).
     *
     * For each vital: the latest reading (of any age — a reading older than the sparkline window is
     * still shown, marked stale, rather than collapsed to "no data"), the recent per-day series for
     * the sparkline (gaps preserved, never zero-filled), the personal band for banded vitals, and the
     * per-source sensor-quality label for whatever source produced the latest reading. A vital with
     * no reading at all becomes a first-class no-data tile, not a crash and not a fake zero.
     */
    fun buildReadModel(asOf: Long? = null, tz: String = TimeZone.getDefault().id): HealthMonitorReadModel {
        val now = asOf ?: clock.now()
        val asOfDayStart = DayAttribution.startOfDay(now, tz)
        // A reading is "stale" once its own day is strictly before (asOf − staleAfterDays). The
        // vitals are overnight and ~once-daily, so a two-day-old RHR is honestly "as of Tuesday", not
        // a live "now". Compared as YYYY-MM-DD strings, which sort chronologically.
        val staleCutoffDay = DayAttribution.localDayKey(
            DayAttribution.addingDays(-config.staleAfterDays, asOfDayStart, tz), tz,
        )

        // The sparkline day axis: the most recent `sparklineDays` calendar days, oldest first. Built
        // as an explicit axis so `buildSparkline` can render missing days as gaps rather than the
        // series silently skipping them (plan §18: missing-input days are gaps, not zeros).
        val windowStart = DayAttribution.addingDays(-(config.sparklineDays - 1), asOfDayStart, tz)
        val axisDays = ArrayList<String>(config.sparklineDays)
        for (i in 0 until config.sparklineDays) {
            axisDays.add(DayAttribution.localDayKey(DayAttribution.addingDays(i, windowStart, tz), tz))
        }
        val windowTo = DayAttribution.addingDays(1, asOfDayStart, tz) - 1

        val tiles = DeviationEngine.vitals.map { metricId ->
            val def = registry.definitionOrFallback(metricId)

            // Latest reading of any age, for the "current value" + staleness + source attribution.
            val latestRecord = measurements.latestInterval(metricId)
            val latest = latestRecord?.let {
                DayValue(DayAttribution.localDayKey(it.startAt, it.tzId), it.value)
            }

            // Recent per-day series for the sparkline, reduced deterministically per day.
            val windowRecords = measurements.intervalRecords(metricId, windowStart, windowTo)
            val sparkline = buildSparkline(axisDays, perDayLatest(windowRecords))

            // Personal band — only for banded vitals. Deviation-only vitals never get one, even if a
            // stray `Baseline` somehow existed, because `makeTile` forces `band = null` for them.
            val band = if (deviationVitals.contains(metricId)) null else derivation.latestBaseline(metricId)

            // Per-source sensor-quality, attributed to the source that produced the latest reading.
            val sourceQuality = latestRecord?.provenance?.sourceId?.let { sourceId ->
                val source = catalog.source(sourceId)
                val devices = if (source == null) emptyList() else catalog.devices(sourceId)
                resolveSourceQuality(source, devices, def.familyGroup, sensorQuality)
            }

            makeTile(def, latest, band, sparkline, sourceQuality, staleCutoffDay)
        }

        return HealthMonitorReadModel(vitals = tiles, disclaimer = disclaimer, generatedAt = now)
    }

    /**
     * Reduce a window's interval records to one value per local day, keyed in each record's own
     * timezone. "Latest" mirrors `BaselineEngine.latestPerDay`: strictly newer `updatedAt` wins; an
     * exact tie falls back to the lexicographically smaller `sourceId` so the choice is deterministic
     * and not dependent on incidental query order (DATA-09).
     */
    private fun perDayLatest(records: List<IntervalRecord>): Map<String, Double> {
        data class Winner(val value: Double, val updatedAt: Long, val sourceId: String)
        val byDay = HashMap<String, Winner>()
        for (r in records) {
            val day = DayAttribution.localDayKey(r.startAt, r.tzId)
            val existing = byDay[day]
            if (existing != null) {
                val newer = r.updatedAt > existing.updatedAt ||
                    (r.updatedAt == existing.updatedAt && r.provenance.sourceId < existing.sourceId)
                if (!newer) continue
            }
            byDay[day] = Winner(r.value, r.updatedAt, r.provenance.sourceId)
        }
        return byDay.mapValues { it.value.value }
    }

    companion object {
        /**
         * The vitals the Health Monitor tracks, in display order (plan §11 EPIC-27: RHR, HRV, RR,
         * SpO2, wrist-temperature deviation). Ordered, not a set — the tile grid reads top-to-bottom
         * in this order, and the read model preserves it.
         */
        val vitals: List<String> = listOf(
            MetricId.restingHeartRate, MetricId.hrv, MetricId.respiratoryRate,
            MetricId.spo2, MetricId.wristTempDeviation,
        )

        /**
         * Metric ids whose STORED value is already a deviation from the person's own baseline, not an
         * absolute reading. A tile for one of these is rendered as [VitalReading.Deviation] with no
         * band by construction — the read model shape then carries no field that could hold an
         * absolute skin temperature, so the UI cannot render one (EPIC-27 acceptance: temperature is
         * deviation-only by construction). The registry marks `body.wrist_temp_deviation`
         * non-baseline-eligible for the same reason, so no [Baseline] row is ever drawn for it anyway;
         * this set is the belt to that suspenders, enforced in [makeTile] regardless of what is passed.
         */
        val deviationVitals: Set<String> = setOf(MetricId.wristTempDeviation)

        // MARK: - Pure tile assembly (identical on both platforms — golden-tested)

        /**
         * Assemble one vital's tile from already-fetched inputs. Pure: no I/O, no clock, no repos — so
         * both platforms produce byte-identical tiles and identical bilingual copy from the same
         * inputs.
         *
         * The honesty rules are all enforced here, by construction:
         * - [deviationVitals] (temperature) are forced to [VitalReading.Deviation] with `band = null`;
         *   there is no code path that gives one an absolute reading or a numeric band.
         * - A banded vital is only classified against an ESTABLISHED band. A provisional or absent
         *   band yields [VitalState.Calibrating], never a fabricated in/out-of-range verdict (plan §18
         *   cold start).
         * - The calm out-of-band annotation is suppressed on a stale tile: "your latest reading sits
         *   above your usual range" would misread as current when the reading is days old. The tile's
         *   `asOfDay` + `isStale` carry the honest framing instead.
         */
        fun makeTile(
            def: MetricDefinition,
            latest: DayValue?,
            band: Baseline?,
            sparkline: List<SparklinePoint>,
            sourceQuality: SourceQualityLabel?,
            staleCutoffDay: String,
        ): VitalTile {
            val isDeviationVital = deviationVitals.contains(def.metricId)
            val personalBand = if (isDeviationVital) null else band?.let { PersonalBand.from(it) }

            if (latest == null) {
                // No reading in the store at all — a first-class empty tile, not a zero.
                return VitalTile(
                    metricId = def.metricId, family = def.familyGroup, title = def.displayName,
                    unit = def.canonicalUnit, reading = null, asOfDay = null, band = personalBand,
                    state = VitalState.NoData, isStale = false, annotation = null,
                    sparkline = sparkline, sourceQuality = sourceQuality,
                )
            }

            val isStale = latest.day < staleCutoffDay
            val reading: VitalReading
            val state: VitalState
            var annotation: LocalizedString? = null

            if (isDeviationVital) {
                // Temperature: the stored value IS the deviation. Rendered only as a signed deviation,
                // with direction (not a band verdict) derived from its sign.
                reading = VitalReading.Deviation(latest.value)
                val direction = tempDirection(latest.value)
                state = VitalState.Deviation(direction)
                annotation = if (isStale) null else tempAnnotation(direction)
            } else {
                reading = VitalReading.Absolute(latest.value)
                if (band != null && !band.provisional) {
                    when (band.position(of = latest.value)) {
                        Baseline.Position.WITHIN -> { state = VitalState.WithinBand }
                        Baseline.Position.BELOW -> {
                            state = VitalState.BelowBand
                            annotation = if (isStale) null else bandAnnotation(Baseline.Position.BELOW)
                        }
                        Baseline.Position.ABOVE -> {
                            state = VitalState.AboveBand
                            annotation = if (isStale) null else bandAnnotation(Baseline.Position.ABOVE)
                        }
                    }
                } else {
                    // Reading present but no established band to judge it against yet — honest cold start.
                    state = VitalState.Calibrating
                }
            }

            return VitalTile(
                metricId = def.metricId, family = def.familyGroup, title = def.displayName,
                unit = def.canonicalUnit, reading = reading, asOfDay = latest.day, band = personalBand,
                state = state, isStale = isStale, annotation = annotation,
                sparkline = sparkline, sourceQuality = sourceQuality,
            )
        }

        /**
         * Direction of a temperature deviation from the personal usual level. Sign only — the stored
         * value is already rounded upstream, so a bare sign avoids inventing a "how far is meaningful"
         * threshold, which without a personal spread could only be a population norm (forbidden in v1).
         */
        fun tempDirection(deviation: Double): TempDirection = when {
            deviation > 0 -> TempDirection.ABOVE_USUAL
            deviation < 0 -> TempDirection.BELOW_USUAL
            else -> TempDirection.AT_USUAL
        }

        /**
         * Map the sparkline day axis onto the per-day values, emitting `null` for any day with no
         * reading. The gap is preserved as a hole in the series, never as a zero — a day the watch
         * wasn't worn is missing data, not a resting heart rate of 0 (plan §18 missing-data rule).
         */
        fun buildSparkline(axisDays: List<String>, byDay: Map<String, Double>): List<SparklinePoint> =
            axisDays.map { SparklinePoint(it, byDay[it]) }

        /**
         * Resolve the per-source sensor-quality label for a source that produced a reading, following
         * the [SensorQualityMap] contract exactly (device-keyword class match → family level). `null`
         * when there is no source to attribute — an honest absence, not a guessed label.
         *
         * This is the plan's "`Source.sensorQuality` wiring": a source's quality is RESOLVED from the
         * published contract at read time, not stored as a column. The contract is emphatic that class
         * assignment "lives in code, not here" (model strings churn faster than a shared contract
         * should), so a stored field would be a stale allowlist — the map's `classId(source, devices)`
         * is the single resolution point, and this composes it with `level(sourceClassId, family)`.
         */
        fun resolveSourceQuality(
            source: Source?,
            devices: List<Device>,
            family: MetricFamily,
            map: SensorQualityMap,
        ): SourceQualityLabel? {
            if (source == null) return null
            val classId = map.classId(source, devices)
            val level = map.level(classId, family)
            return SourceQualityLabel(
                sourceId = source.id, sourceDisplayName = source.displayName,
                sourceClassId = classId, level = level,
            )
        }

        // MARK: - Copy (authored once, parity-asserted; the UI resolves the language)

        /**
         * The persistent "not a medical evaluation" footer (plan §11 EPIC-27 risk mitigation).
         * MANDATORY — the UI renders it, but it lives in the read model so its presence and exact
         * wording are asserted by a test and the copy lint, not left to a view that could forget it.
         * Wellness-safe: states what the surface is (a personal wellness overview of past readings),
         * never a verdict. Word-for-word identical to iOS `DeviationEngine.disclaimer`.
         */
        val disclaimer = LocalizedString(
            en = "This is a wellness overview, not a medical evaluation. It reflects your own past readings.",
            ar = "هذه نظرة عامة على العافية، وليست تقييماً طبياً. تعكس قراءاتك السابقة الخاصة بك.",
        )

        /**
         * Calm, directional, personal note for a banded vital sitting outside its usual range. Never a
         * verdict ("good"/"bad"), never a diagnosis, never an instruction — it names where the latest
         * reading sits relative to the person's OWN band and stops there.
         */
        fun bandAnnotation(position: Baseline.Position): LocalizedString? = when (position) {
            Baseline.Position.WITHIN -> null
            Baseline.Position.ABOVE -> LocalizedString(
                en = "Your latest reading sits above your usual range.",
                ar = "قراءتك الأخيرة أعلى من نطاقك المعتاد.",
            )
            Baseline.Position.BELOW -> LocalizedString(
                en = "Your latest reading sits below your usual range.",
                ar = "قراءتك الأخيرة أدنى من نطاقك المعتاد.",
            )
        }

        /**
         * The temperature counterpart: names the overnight reading's direction from the usual level,
         * nothing more. [TempDirection.AT_USUAL] carries no annotation — silence is the safe default.
         */
        fun tempAnnotation(direction: TempDirection): LocalizedString? = when (direction) {
            TempDirection.AT_USUAL -> null
            TempDirection.ABOVE_USUAL -> LocalizedString(
                en = "Your latest overnight reading sits above your usual level.",
                ar = "قراءتك الليلية الأخيرة أعلى من مستواك المعتاد.",
            )
            TempDirection.BELOW_USUAL -> LocalizedString(
                en = "Your latest overnight reading sits below your usual level.",
                ar = "قراءتك الليلية الأخيرة أدنى من مستواك المعتاد.",
            )
        }
    }
}

// MARK: - Read model

/**
 * The Health Monitor read model (EPIC-27). One tile per tracked vital plus the mandatory
 * wellness-safe footer. Pure data: the UI lane (stage 3) owns rendering, colour and layout; this owns
 * the numbers, the honest state, and the bilingual copy that MUST NOT drift between platforms.
 */
data class HealthMonitorReadModel(
    val vitals: List<VitalTile>,
    /** The persistent "not a medical evaluation" footer — see `DeviationEngine.disclaimer`. */
    val disclaimer: LocalizedString,
    val generatedAt: Long,
)

/**
 * One vital's tile. No-data and stale are first-class states here (never a crash, never a fake zero):
 * a tile with `reading == null` is [VitalState.NoData], and a real-but-old reading carries [isStale].
 */
data class VitalTile(
    val metricId: String,
    val family: MetricFamily,
    /** Registry name, en+ar. The UI picks casual/precise per its own depth policy. */
    val title: LocalizedString,
    /** Canonical unit for the reading (e.g. "bpm", "ms", "degC"). The UI formats it. */
    val unit: String,
    /** The latest reading, or `null` when there is none — the tile is then [VitalState.NoData]. */
    val reading: VitalReading?,
    /** The local day (YYYY-MM-DD) the reading belongs to, for "as of <day>" on a stale tile. */
    val asOfDay: String?,
    /**
     * The personal band this vital is judged against. `null` for temperature (deviation-only, no band
     * by construction). Present-but-provisional for a banded vital still calibrating.
     */
    val band: PersonalBand?,
    val state: VitalState,
    /**
     * The latest reading exists but its day is older than the freshness horizon. `false` on a no-data
     * tile (nothing to be stale). Independent of [state], which still shows the last known position —
     * a stale tile reads "as of Tuesday, within your usual range", not a live verdict.
     */
    val isStale: Boolean,
    /**
     * The calm, wellness-safe note when the reading sits outside the usual range (suppressed while
     * stale). `null` within band / at usual / calibrating / no data — silence is the safe default.
     */
    val annotation: LocalizedString?,
    /** Recent per-day series for the sparkline; a day with no reading is a `null` point (a gap). */
    val sparkline: List<SparklinePoint>,
    /**
     * Per-source sensor-quality for the source that produced the latest reading. `null` when there is
     * no reading to attribute.
     */
    val sourceQuality: SourceQualityLabel?,
) {
    val id: String get() = metricId
}

/**
 * How a vital's current value is represented.
 *
 * The two cases are the whole enforcement of "temperature is shown only as a deviation": there is
 * deliberately NO case that carries an absolute skin temperature, so a tile built for
 * `body.wrist_temp_deviation` — which `DeviationEngine.makeTile` always gives [Deviation] — cannot
 * render one. A reviewer cannot add an absolute temperature to the UI without first adding a case
 * here, which is exactly the friction the EPIC-27 acceptance ("temp is deviation-only by
 * construction") calls for.
 */
sealed interface VitalReading {
    /** A directly-readable vital in the tile's canonical unit (RHR, HRV, RR, SpO2). */
    data class Absolute(val value: Double) : VitalReading

    /**
     * A SIGNED deviation from the person's own usual level, in the tile's canonical unit — the only
     * representation temperature is ever given.
     */
    data class Deviation(val value: Double) : VitalReading
}

/**
 * Where a vital's latest reading sits. [Deviation] is temperature's own state — a direction from the
 * personal usual level, never an in/out-of-band verdict (there is no band to judge against).
 */
sealed interface VitalState {
    /** No reading in the store — a first-class empty state, not a zero. */
    object NoData : VitalState

    /**
     * A reading exists but there is no established personal band to judge it against yet (the band is
     * provisional or absent). Nothing is claimed about in/out of range — cold start is honest.
     */
    object Calibrating : VitalState
    object WithinBand : VitalState
    object BelowBand : VitalState
    object AboveBand : VitalState

    /** Temperature only: a signed deviation from the personal usual level, shown by direction. */
    data class Deviation(val direction: TempDirection) : VitalState
}

/** The direction of a temperature deviation from the personal usual level. */
enum class TempDirection { AT_USUAL, ABOVE_USUAL, BELOW_USUAL }

/**
 * A personal band, projected from a [Baseline] row for the read model. Carries the band edges the UI
 * draws, the calibration state, and enough provenance (`baselineId` + `algorithmVersion`) for the
 * anatomy sheet to trace the number back to the exact baseline that drew it (I1).
 */
data class PersonalBand(
    val low: Double,
    val high: Double,
    val center: Double,
    val unit: String,
    val provisional: Boolean,
    val nPoints: Int,
    val windowDays: Int,
    val baselineId: String,
    val algorithmVersion: String,
) {
    companion object {
        fun from(baseline: Baseline): PersonalBand = PersonalBand(
            low = baseline.bandLow, high = baseline.bandHigh, center = baseline.center,
            unit = baseline.unit, provisional = baseline.provisional, nPoints = baseline.nPoints,
            windowDays = baseline.windowDays, baselineId = baseline.id,
            algorithmVersion = baseline.algorithmVersion,
        )
    }
}

/**
 * One point of a tile's sparkline. `value == null` marks a day with no reading — a gap, never a zero
 * (plan §18: missing-input days render as gaps).
 */
data class SparklinePoint(val day: String, val value: Double?)

/**
 * The per-source sensor-quality label attached to a tile: which source produced the reading, which
 * sensor class it resolved to, and how much that class is worth for this family. The UI renders
 * `SensorQualityLevel.label`/`.explainer` (already bilingual). An honesty surface, never a suppressor
 * — see [SensorQualityMap]'s header.
 */
data class SourceQualityLabel(
    val sourceId: String,
    val sourceDisplayName: String,
    val sourceClassId: String,
    val level: SensorQualityLevel,
)

/**
 * Read-model presentation parameters — NOT score constants. The band math and its constants live in
 * `algorithms.json` and belong to `BaselineEngine`; these govern only how much recent history a
 * tile's sparkline shows and how old a reading may be before it is marked stale. Kept here as named,
 * documented defaults (identical on both platforms by construction) and published in
 * `docs/algorithms/health-monitor.md`.
 */
data class DeviationConfig(
    /** Calendar days of recent per-day history the sparkline covers (including the as-of day). */
    val sparklineDays: Int,
    /** A reading whose day is more than this many days before the as-of day is marked stale. */
    val staleAfterDays: Int,
) {
    companion object {
        val DEFAULT = DeviationConfig(sparklineDays = 14, staleAfterDays = 2)
    }
}

/**
 * A single day's value, the platform-neutral primitive the pure tile core operates on (so the
 * classification logic never touches [IntervalRecord]'s platform-specific `Long`).
 */
data class DayValue(val day: String, val value: Double)
