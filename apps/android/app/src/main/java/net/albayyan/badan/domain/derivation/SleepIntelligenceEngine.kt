package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.GregorianCalendar
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt
import net.albayyan.badan.domain.journal.ContextAnnotation
import net.albayyan.badan.domain.journal.ContextAnnotationResolver
import net.albayyan.badan.domain.journal.NO_CONTEXT_ANNOTATIONS

// MARK: - Pure inputs (platform-identical)

/**
 * The two sleep episode kinds this engine distinguishes. A [SessionKind.WORKOUT] never reaches here;
 * the mapping from the storage enum happens at the DB edge (`recompute`), so the pure core never has
 * to know the full session taxonomy. Mirror of iOS `SleepSessionKind`.
 */
enum class SleepSessionKind { PRIMARY, NAP }

/**
 * A half-open interval on the epoch-SECONDS line, used for awake-stage episodes. Kept as plain
 * [Double] seconds (not millis) so the disturbance state machine is byte-identical to the iOS mirror
 * — the acceptance golden is that both platforms count the same episodes from the same numbers.
 */
data class SleepInterval(val start: Double, val end: Double) {
    val durationSeconds: Double get() = end - start
}

/**
 * One sleep episode reduced to the primitives the pure state machine needs. The DB edge builds these
 * from `Session` + `SessionStage`; everything downstream is timezone-aware arithmetic over [Double]
 * epoch seconds and an IANA [tzId], so nap attribution, split-night merge, DST and travel all fall
 * out of the same code on both platforms. Mirror of iOS `SleepSessionInput`.
 */
data class SleepSessionInput(
    val sessionId: String,
    val kind: SleepSessionKind,
    val startEpoch: Double,
    val endEpoch: Double,
    val tzId: String,
    /**
     * Time actually asleep in seconds, as the source reported it. Never re-derived from the duration
     * here — "in bed 8h, asleep 6h" is a claim the source made and we preserve, not one we
     * reconstruct (I1).
     */
    val asleepSeconds: Double,
    val inBedSeconds: Double,
    /**
     * The awake-stage rows for this episode. Empty is not the same as [hasStages] == false: a staged
     * night with no awake episodes legitimately has zero disturbances, whereas an unstaged night's
     * disturbance count is *unknown* and must render as a gap, never a zero.
     */
    val awakeIntervals: List<SleepInterval> = emptyList(),
    val hasStages: Boolean = false,
)

/**
 * One assembled local night: every primary cluster for that night folded into a single record, with
 * the naps kept out (they credit a *later* night — see [SleepAssembly]). This is the output of the
 * split-night / travel / DST state machine and the unit the score pass iterates. Mirror of iOS
 * `SleepNight`.
 */
data class SleepNight(
    val localNight: String,
    val sessionIds: List<String>,
    val asleepSeconds: Double,
    val inBedSeconds: Double,
    val bedSecondsOfDay: Double,
    val wakeSecondsOfDay: Double,
    val awakeIntervals: List<SleepInterval>,
    val hasStages: Boolean,
) {
    val primarySessionId: String get() = sessionIds.firstOrNull() ?: ""
}

/**
 * The whole assembly: the nights that have primary sleep, plus a nap ledger keyed by the nap's own
 * local day. Naps are surfaced separately because a 2pm nap does not shorten the sleep you already
 * had last night — it lowers the need for the night to *come*, which the score pass looks up as
 * `napSecondsByDayKey[previousDayKey(thisNight)]`. Mirror of iOS `SleepAssembly`.
 */
data class SleepAssembly(
    val nights: List<SleepNight>,
    val napSecondsByDayKey: Map<String, Double>,
)

// MARK: - Pure results (platform-identical)

/**
 * Sleep need as an honest range, never a fake-exact minutes target (plan §4 principle 9). [centerSeconds]
 * is the point estimate; [lowSeconds]/[highSeconds] are the band the surface must render instead. The
 * band widens as [confidence] drops (a thin baseline or a missing effort input), so an estimate the
 * engine is unsure of *looks* unsure. Mirror of iOS `SleepNeedRange`.
 */
data class SleepNeedRange(
    val centerSeconds: Double,
    val lowSeconds: Double,
    val highSeconds: Double,
    val confidence: Double,
    /**
     * False when the prior-day Effort input was absent — the reduced-input variant (plan §11). Carried
     * so the surface can label it distinctly rather than silently degrade.
     */
    val effortPresent: Boolean,
)

/**
 * Sleep performance = actual / need, as a percentage. [centerPercent] is stored UNCAPPED (the raw
 * ratio stays inspectable); [cappedCenterPercent] is what the surface shows. [lowPercent]/[highPercent]
 * propagate the need band (more need => lower performance), and [showRange] is the honest-render flag.
 * Mirror of iOS `SleepPerformance`.
 */
data class SleepPerformance(
    val centerPercent: Double,
    val cappedCenterPercent: Double,
    val lowPercent: Double,
    val highPercent: Double,
    val confidence: Double,
    val showRange: Boolean,
)

/**
 * Everything computed for one night. [need]/[performance]/[debtSeconds] are null when there is no
 * personal sleep-duration baseline yet (honest cold start), while [consistency] and [disturbanceCount]
 * do not depend on the baseline and can stand alone. Mirror of iOS `SleepNightScore`.
 */
data class SleepNightScore(
    val localNight: String,
    val primarySessionId: String,
    val actualAsleepSeconds: Double,
    val need: SleepNeedRange?,
    val performance: SleepPerformance?,
    val debtSeconds: Double?,
    val consistency: Double?,
    val consistencyNights: Int,
    val consistencySufficient: Boolean,
    val consistencyWindowSessionIds: List<String>,
    val disturbanceCount: Int?,
)

// MARK: - Contract-loaded parameters

/**
 * One derived output's frozen identity plus whether its constants are still provisional. Every sleep
 * output is provisional today (seeded defaults, not validated — `algorithms.json`), so every row this
 * engine writes carries `provisional = true`. Mirror of iOS `SleepOutputSpec`.
 */
data class SleepOutputSpec(val algorithm: AlgorithmVersion, val provisional: Boolean)

/**
 * The data-driven sleep parameters, resolved once from the algorithm contract (the five `sleep.*`
 * entries in `algorithms.json`). This is the ONLY place those constants enter the engine — never
 * hardcoded — so the two platforms cannot drift and a tuning change is a reviewable one-line diff plus
 * a semver bump (plan §15). A spec that failed to load ([isLoaded] == false) makes the engine COMPUTE
 * NOTHING rather than invent constants. Mirror of iOS `SleepSpec`.
 */
data class SleepSpec(
    val need: SleepOutputSpec,
    val performance: SleepOutputSpec,
    val debt: SleepOutputSpec,
    val consistency: SleepOutputSpec,
    val disturbances: SleepOutputSpec,
    // need
    val debtRepaymentFraction: Double,
    /**
     * Half-life of the debt view that feeds NEED. Deliberately shorter than the displayed-debt
     * half-life: tonight's target reacts to the last few nights, while the surfaced debt trend has a
     * longer memory. Two half-lives, both published, both used.
     */
    val needDebtHalfLifeDays: Double,
    val effortFactorSecondsPerPoint: Double,
    val napCreditFraction: Double,
    val rangeHalfWidthSeconds: Double,
    val minNeedSeconds: Double,
    val maxNeedSeconds: Double,
    // performance
    val upperBoundPercent: Double,
    val lowConfidenceThreshold: Double,
    // debt
    val displayDebtHalfLifeDays: Double,
    val debtLookbackDays: Int,
    val maxDebtSeconds: Double,
    // consistency
    val consistencyWindowDays: Int,
    val consistencyMinNights: Int,
    val zeroScoreStdevSeconds: Double,
    val bedWakeWeightSplit: Double,
    // disturbances
    val minEpisodeSeconds: Double,
    val mergeGapSeconds: Double,
    val isLoaded: Boolean,
) {
    companion object {
        /**
         * Resolve from a loaded [AlgorithmRegistry]. Returns [unavailable] if any of the five entries
         * or any constant they own is missing — the engine treats that as "compute nothing".
         */
        fun load(registry: AlgorithmRegistry): SleepSpec {
            val needDef = registry.definition("sleep.need") ?: return unavailable
            val perfDef = registry.definition("sleep.performance") ?: return unavailable
            val debtDef = registry.definition("sleep.debt") ?: return unavailable
            val consDef = registry.definition("sleep.consistency") ?: return unavailable
            val distDef = registry.definition("sleep.disturbances") ?: return unavailable

            val repay = needDef.params["debtRepaymentFraction"] ?: return unavailable
            val needHalf = needDef.params["debtDecayHalfLifeDays"] ?: return unavailable
            val effortFactor = needDef.params["effortFactorSecondsPerPoint"] ?: return unavailable
            val napFrac = needDef.params["napCreditFraction"] ?: return unavailable
            val rangeHalf = needDef.params["rangeHalfWidthSeconds"] ?: return unavailable
            val minNeed = needDef.params["minNeedSeconds"] ?: return unavailable
            val maxNeed = needDef.params["maxNeedSeconds"] ?: return unavailable
            val upperBound = perfDef.params["upperBoundPercent"] ?: return unavailable
            val lowConf = perfDef.params["lowConfidenceThreshold"] ?: return unavailable
            val displayHalf = debtDef.params["decayHalfLifeDays"] ?: return unavailable
            val lookback = debtDef.params["lookbackDays"] ?: return unavailable
            val maxDebt = debtDef.params["maxDebtSeconds"] ?: return unavailable
            val consWindow = consDef.params["windowDays"] ?: return unavailable
            val minNights = consDef.params["minNights"] ?: return unavailable
            val zeroStdev = consDef.params["zeroScoreStdevSeconds"] ?: return unavailable
            val bedWakeSplit = consDef.params["bedWakeWeightSplit"] ?: return unavailable
            val minEpisode = distDef.params["minEpisodeSeconds"] ?: return unavailable
            val mergeGap = distDef.params["mergeGapSeconds"] ?: return unavailable

            return SleepSpec(
                need = SleepOutputSpec(needDef.algorithmVersion, needDef.provisional),
                performance = SleepOutputSpec(perfDef.algorithmVersion, perfDef.provisional),
                debt = SleepOutputSpec(debtDef.algorithmVersion, debtDef.provisional),
                consistency = SleepOutputSpec(consDef.algorithmVersion, consDef.provisional),
                disturbances = SleepOutputSpec(distDef.algorithmVersion, distDef.provisional),
                debtRepaymentFraction = repay, needDebtHalfLifeDays = needHalf,
                effortFactorSecondsPerPoint = effortFactor, napCreditFraction = napFrac,
                rangeHalfWidthSeconds = rangeHalf, minNeedSeconds = minNeed, maxNeedSeconds = maxNeed,
                upperBoundPercent = upperBound, lowConfidenceThreshold = lowConf,
                displayDebtHalfLifeDays = displayHalf, debtLookbackDays = lookback.toInt(), maxDebtSeconds = maxDebt,
                consistencyWindowDays = consWindow.toInt(), consistencyMinNights = minNights.toInt(),
                zeroScoreStdevSeconds = zeroStdev, bedWakeWeightSplit = bedWakeSplit,
                minEpisodeSeconds = minEpisode, mergeGapSeconds = mergeGap, isLoaded = true,
            )
        }

        /** The app-default spec, resolved once from the classpath contract mirror (no Android Context). */
        fun default(): SleepSpec = cachedDefault

        private val cachedDefault: SleepSpec by lazy { load(AlgorithmRegistry.fromClasspath()) }

        /** The degenerate "the contract did not load" spec. Never produces a score. */
        val unavailable = SleepSpec(
            need = SleepOutputSpec(AlgorithmVersion("sleep.need", "0.0.0", introducedIn = "0.0.0"), true),
            performance = SleepOutputSpec(AlgorithmVersion("sleep.performance", "0.0.0", introducedIn = "0.0.0"), true),
            debt = SleepOutputSpec(AlgorithmVersion("sleep.debt", "0.0.0", introducedIn = "0.0.0"), true),
            consistency = SleepOutputSpec(AlgorithmVersion("sleep.consistency", "0.0.0", introducedIn = "0.0.0"), true),
            disturbances = SleepOutputSpec(AlgorithmVersion("sleep.disturbances", "0.0.0", introducedIn = "0.0.0"), true),
            debtRepaymentFraction = 0.0, needDebtHalfLifeDays = 1.0, effortFactorSecondsPerPoint = 0.0,
            napCreditFraction = 0.0, rangeHalfWidthSeconds = 0.0, minNeedSeconds = 0.0, maxNeedSeconds = 0.0,
            upperBoundPercent = 0.0, lowConfidenceThreshold = 0.0, displayDebtHalfLifeDays = 1.0,
            debtLookbackDays = 0, maxDebtSeconds = 0.0, consistencyWindowDays = 0, consistencyMinNights = 0,
            zeroScoreStdevSeconds = 1.0, bedWakeWeightSplit = 0.5, minEpisodeSeconds = 0.0, mergeGapSeconds = 0.0,
            isLoaded = false,
        )
    }
}

/**
 * Computes the sleep-intelligence cluster per `localNight` — need (as a range), performance, debt,
 * consistency and disturbances — from the sessions BADAN already ingests, appending one [DerivedValue]
 * per output with an [InputManifest] and a confidence. Every constant is read from `algorithms.json`
 * via [SleepSpec]; nothing is hardcoded, and every output is provisional until its constants are
 * validated, so every row carries `provisional = true` today.
 *
 * The hard part is the state machine, and it is deliberately PURE and static ([assembleNights],
 * [score], and the five sub-computations): iOS `SleepIntelligenceEngine` computes byte-identical
 * numbers from the same inputs, and that cross-platform identity is the acceptance golden. The DB
 * orchestration ([recompute]) reads sessions/baselines/effort and appends rows; the pure math is what
 * the JVM goldens assert, exactly as [BaselineEngine] splits pure math from DB wiring.
 *
 * Soft dependency on Effort (plan §11): the need model runs at a reduced-input version when `effort.day`
 * is absent — it drops the effort term and lowers confidence (which widens the range), never imputes.
 * Mirror of iOS `SleepIntelligenceEngine`.
 */
class SleepIntelligenceEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val clock: Clock,
    private val deviceId: String,
    private val spec: SleepSpec = SleepSpec.default(),
    /**
     * EPIC-29 (plan §18). What the user declared over each night being scored. Resolved PER NIGHT,
     * not once per run: one recompute emits a fortnight of nights and only some may sit inside a
     * declared interval. A function rather than the sensitive repository — see
     * [ContextAnnotationResolver].
     */
    private val contextAnnotations: ContextAnnotationResolver = NO_CONTEXT_ANNOTATIONS,
) {

    // MARK: - DB orchestration (the pure core below is what the JVM goldens assert)

    /**
     * Recompute the sleep cluster for the nights up to [asOf] (epoch millis) and append the derived
     * rows. Idempotent and append-only (I2): a repeat run over unchanged data writes nothing, a run
     * over new/corrected data appends fresh rows and never mutates the old ones.
     */
    fun recompute(asOf: Long, tz: String = TimeZone.getDefault().id, context: String = "default") {
        if (!spec.isLoaded) return

        val gatherDays = spec.debtLookbackDays + spec.consistencyWindowDays
        val dayStart = DayAttribution.startOfDay(asOf, tz)
        val from = DayAttribution.addingDays(-(gatherDays + 1), dayStart, tz)
        val sleepSessions = measurements.sessions(from = from, to = asOf).filter { it.kind.isSleep }
        if (sleepSessions.isEmpty()) return

        val inputs = sleepSessions.map { s ->
            val stages = measurements.stages(s.id)
            val awake = stages.filter { it.stage == SleepStage.AWAKE }
                .map { SleepInterval(it.startAt / 1000.0, it.endAt / 1000.0) }
            // Prefer the source's own asleep claim (I1); fall back to the in-bed span only when the
            // source reported no asleep figure at all, never re-derive it when it exists.
            val asleep = s.detail.timeAsleepSeconds ?: s.durationSeconds
            val inBed = s.detail.timeInBedSeconds ?: s.durationSeconds
            SleepSessionInput(
                sessionId = s.id, kind = if (s.kind == SessionKind.SLEEP_NAP) SleepSessionKind.NAP else SleepSessionKind.PRIMARY,
                startEpoch = s.startAt / 1000.0, endEpoch = s.endAt / 1000.0, tzId = s.tzId,
                asleepSeconds = asleep, inBedSeconds = inBed, awakeIntervals = awake, hasStages = stages.isNotEmpty(),
            )
        }

        val assembly = assembleNights(inputs)
        if (assembly.nights.isEmpty()) return

        val baseline = derivation.latestBaseline(MetricId.timeAsleep)
        val baselineArg: Pair<Double, Double>? = baseline?.let {
            it.center to if (it.windowDays > 0) min(1.0, it.nPoints.toDouble() / it.windowDays.toDouble()) else 0.0
        }

        // Effort is a SOFT input: read whatever prior-day `effort.day` rows exist; absence is the
        // reduced-input path, not an error.
        val effortById = HashMap<String, DerivedValue>()
        val effortByDayKey = HashMap<String, Double>()
        for (night in assembly.nights) {
            val priorKey = previousDayKey(night.localNight)
            if (!effortByDayKey.containsKey(priorKey)) {
                derivation.latestDerived(EFFORT_DAY, "day:$priorKey")?.let {
                    effortByDayKey[priorKey] = it.value
                    effortById[priorKey] = it
                }
            }
        }

        val scores = score(assembly, baselineArg, effortByDayKey, spec)
        for (s in scores) {
            // One resolve per night, over the local day the night is attributed to — the same
            // day-attribution rule every other reader of these rows uses. A status declared for the
            // previous day annotates that day's night, not this one's.
            val nightStart = DayAttribution.dateFromDayKey(s.localNight, tz)
            val annotation = if (nightStart != null) {
                contextAnnotations(nightStart, DayAttribution.addingDays(1, nightStart, tz))
            } else {
                ContextAnnotation.NONE
            }
            appendScore(s, baseline, effortById, annotation)
        }
    }

    private fun appendScore(
        s: SleepNightScore,
        baseline: Baseline?,
        effortById: Map<String, DerivedValue>,
        context: ContextAnnotation = ContextAnnotation.NONE,
    ) {
        val priorKey = previousDayKey(s.localNight)

        var needId: String? = null
        val need = s.need
        if (need != null && baseline != null) {
            val inputs = mutableListOf(InputManifest.Input(baseline.id, MetricId.timeAsleep, baseline.center))
            effortById[priorKey]?.let { inputs.add(InputManifest.Input(it.id, EFFORT_DAY, it.value)) }
            needId = upsertDerived(MetricId.sleepNeed, need.centerSeconds, "s", s.localNight, need.confidence, spec.need, inputs, context)
        }

        val perf = s.performance
        if (perf != null && needId != null) {
            val inputs = listOf(
                InputManifest.Input(needId, MetricId.sleepNeed, s.need?.centerSeconds ?: 0.0),
                InputManifest.Input(s.primarySessionId, MetricId.timeAsleep, s.actualAsleepSeconds),
            )
            upsertDerived(MetricId.sleepPerformance, perf.centerPercent, "percent", s.localNight, perf.confidence, spec.performance, inputs, context)
        }

        val debt = s.debtSeconds
        if (debt != null && needId != null) {
            val inputs = listOf(
                InputManifest.Input(needId, MetricId.sleepNeed, s.need?.centerSeconds ?: 0.0),
                InputManifest.Input(s.primarySessionId, MetricId.timeAsleep, s.actualAsleepSeconds),
            )
            upsertDerived(MetricId.sleepDebt, debt, "s", s.localNight, null, spec.debt, inputs)
        }

        val consistency = s.consistency
        if (consistency != null) {
            val confidence = if (s.consistencySufficient) {
                min(1.0, s.consistencyNights.toDouble() / spec.consistencyWindowDays.toDouble())
            } else {
                0.0
            }
            val inputs = s.consistencyWindowSessionIds.map { InputManifest.Input(it, MetricId.timeAsleep, consistency) }
            upsertDerived(MetricId.sleepConsistency, consistency, "score_0_100", s.localNight, confidence, spec.consistency, inputs, context)
        }

        val disturbances = s.disturbanceCount
        if (disturbances != null) {
            val inputs = listOf(InputManifest.Input(s.primarySessionId, MetricId.sleepAwake, disturbances.toDouble()))
            // Deliberately NOT context-annotated. This confidence means "the stages were there and we
            // counted them", not "here is how confidently this reads against your usual" — a count of
            // observed awake episodes is as true on a travel night as on any other. `sleep.debt` is
            // likewise unannotated, for the plainer reason that it stores no confidence at all.
            upsertDerived(MetricId.sleepDisturbances, disturbances.toDouble(), "count", s.localNight, 1.0, spec.disturbances, inputs)
        }
    }

    /**
     * [context] caps the confidence and NOTHING else — [value] is written through untouched, and
     * [ContextAnnotation] has no value field it could touch it with. Callers pass NONE for the
     * outputs whose confidence is not an interpretation against the person's usual pattern (see the
     * disturbance-count note above).
     */
    private fun upsertDerived(
        metricId: String, value: Double, unit: String, day: String, rawConfidence: Double?,
        output: SleepOutputSpec, inputs: List<InputManifest.Input>,
        context: ContextAnnotation = ContextAnnotation.NONE,
    ): String {
        val confidence = context.applyingTo(rawConfidence)
        val periodKey = "day:$day"
        // Skip the append only when the latest row is identical on ALL of value, confidence,
        // provisional AND the algorithm identity — a version bump that yields the same value must
        // still record a fresh row, or that period's latest row would keep the OLD version id and
        // the recompute would go unrecorded (auditability; mirrors ReadinessEngine.persist).
        val existing = derivation.latestDerived(metricId, periodKey)
        if (existing != null &&
            existing.algorithmId == output.algorithm.algorithmId &&
            existing.algorithmVersion == output.algorithm.semver &&
            approximatelyEqual(existing.value, value) &&
            approximatelyEqual(existing.confidence ?: -1.0, confidence ?: -1.0) &&
            existing.provisional == output.provisional
        ) {
            return existing.id
        }
        val manifest = InputManifest(id = Ulid.newId(), inputs = inputs)
        derivation.insertManifest(manifest)
        val now = clock.now()
        val dv = DerivedValue(
            id = Ulid.newId(), metricId = metricId, value = value, unit = unit, periodKey = periodKey,
            confidence = confidence, provisional = output.provisional,
            algorithmId = output.algorithm.algorithmId, algorithmVersion = output.algorithm.semver,
            inputManifestId = manifest.id, computedAt = now, updatedAt = now, originDeviceId = deviceId,
        )
        derivation.appendDerived(dv)
        return dv.id
    }

    companion object {
        /**
         * The metric ids this engine wires. `EFFORT_DAY` is a soft input owned by EPIC-26 — referenced
         * by string rather than adding a shared constant the concurrent Effort epic would also want.
         */
        const val EFFORT_DAY = "effort.day"

        // MARK: - Pure state machine (identical on both platforms — golden-tested)

        /**
         * Fold sleep sessions into per-night records: primary clusters merge into one night, nap
         * seconds accrue against their own local day. Grouping is by the local night the episode ENDS
         * in, computed in the episode's OWN timezone — so a Riyadh night stays a Riyadh night after you
         * fly to London, and a post-midnight bedtime still lands on the right morning.
         */
        fun assembleNights(sessions: List<SleepSessionInput>): SleepAssembly {
            val primaryByNight = HashMap<String, MutableList<SleepSessionInput>>()
            val napByDay = HashMap<String, Double>()
            for (s in sessions) {
                val key = DayAttribution.localNight((s.endEpoch * 1000).toLong(), s.tzId)
                when (s.kind) {
                    SleepSessionKind.PRIMARY -> primaryByNight.getOrPut(key) { mutableListOf() }.add(s)
                    SleepSessionKind.NAP -> napByDay[key] = (napByDay[key] ?: 0.0) + s.asleepSeconds
                }
            }

            val nights = ArrayList<SleepNight>()
            for ((key, clustersRaw) in primaryByNight) {
                val clusters = clustersRaw.sortedBy { it.startEpoch }
                val asleep = clusters.sumOf { it.asleepSeconds }
                val inBed = clusters.sumOf { it.inBedSeconds }
                val first = clusters.first()
                val last = clusters.last()
                val bedSod = localSecondsOfDay(first.startEpoch, first.tzId)
                val wakeSod = localSecondsOfDay(last.endEpoch, last.tzId)

                val awake = clusters.flatMap { it.awakeIntervals }.toMutableList()
                // The awake gap between two clusters of a split night is a disturbance the sleeper
                // lived through, even though no stage row spans it.
                for (i in 0 until clusters.size - 1) {
                    val gapStart = clusters[i].endEpoch
                    val gapEnd = clusters[i + 1].startEpoch
                    if (gapEnd > gapStart) awake.add(SleepInterval(gapStart, gapEnd))
                }
                val hasStages = clusters.any { it.hasStages }

                nights.add(
                    SleepNight(
                        localNight = key, sessionIds = clusters.map { it.sessionId },
                        asleepSeconds = asleep, inBedSeconds = inBed,
                        bedSecondsOfDay = bedSod, wakeSecondsOfDay = wakeSod,
                        awakeIntervals = awake, hasStages = hasStages,
                    ),
                )
            }
            nights.sortBy { it.localNight }
            return SleepAssembly(nights, napByDay)
        }

        /**
         * The forward pass over the assembled nights. Debt is a forward recurrence (tonight's need
         * depends only on PAST shortfalls, so there is no circularity), computed twice with the two
         * published half-lives. Consistency and disturbances do not depend on the baseline and are
         * always attempted. [baseline] is (center seconds, maturity 0..1) or null when none exists yet.
         */
        fun score(
            assembly: SleepAssembly, baseline: Pair<Double, Double>?,
            effortByDayKey: Map<String, Double>, spec: SleepSpec,
        ): List<SleepNightScore> {
            val nights = assembly.nights
            val shortfalls = ArrayList<Pair<String, Double>>()
            val out = ArrayList<SleepNightScore>()

            for (night in nights) {
                val key = night.localNight
                val priorKey = previousDayKey(key)

                var need: SleepNeedRange? = null
                var performance: SleepPerformance? = null
                var debt: Double? = null
                if (baseline != null) {
                    val needDebt = accumulateDebt(
                        shortfalls, key, spec.needDebtHalfLifeDays, spec.debtLookbackDays,
                        spec.maxDebtSeconds, includeAsOf = false,
                    )
                    val napCredit = spec.napCreditFraction * (assembly.napSecondsByDayKey[priorKey] ?: 0.0)
                    val n = computeNeed(
                        baseline.first, needDebt, effortByDayKey[priorKey], napCredit, baseline.second, spec,
                    )
                    need = n
                    performance = computePerformance(night.asleepSeconds, n, spec)
                    shortfalls.add(key to (n.centerSeconds - night.asleepSeconds))
                    debt = accumulateDebt(
                        shortfalls, key, spec.displayDebtHalfLifeDays, spec.debtLookbackDays,
                        spec.maxDebtSeconds, includeAsOf = true,
                    )
                }

                val window = nights.filter {
                    val age = daysBetween(it.localNight, key)
                    age in 0 until spec.consistencyWindowDays
                }
                val consistency = if (window.size >= 2) {
                    computeConsistency(window.map { it.bedSecondsOfDay }, window.map { it.wakeSecondsOfDay }, spec)
                } else {
                    null
                }

                out.add(
                    SleepNightScore(
                        localNight = key, primarySessionId = night.primarySessionId,
                        actualAsleepSeconds = night.asleepSeconds,
                        need = need, performance = performance, debtSeconds = debt,
                        consistency = consistency, consistencyNights = window.size,
                        consistencySufficient = window.size >= spec.consistencyMinNights,
                        consistencyWindowSessionIds = window.map { it.primarySessionId },
                        disturbanceCount = if (night.hasStages) countDisturbances(night.awakeIntervals, spec) else null,
                    ),
                )
            }
            return out
        }

        /**
         * need = baseline duration + repaymentFraction*debt + priorDayEffort*factor - napCredit,
         * clamped to [min, max], returned as a range whose half-width grows as confidence falls.
         * Confidence = baseline maturity * input completeness (0.5 when the effort term is missing).
         */
        fun computeNeed(
            baselineDurationSeconds: Double, needDebtSeconds: Double, priorDayEffort: Double?,
            napCreditSeconds: Double, baselineMaturity: Double, spec: SleepSpec,
        ): SleepNeedRange {
            val effortPresent = priorDayEffort != null
            val effortTerm = (priorDayEffort ?: 0.0) * spec.effortFactorSecondsPerPoint
            var center = baselineDurationSeconds + spec.debtRepaymentFraction * needDebtSeconds +
                effortTerm - napCreditSeconds
            center = min(spec.maxNeedSeconds, maxOf(spec.minNeedSeconds, center))

            val completeness = if (effortPresent) 1.0 else 0.5
            val confidence = maxOf(0.0, min(1.0, baselineMaturity * completeness))
            val halfWidth = spec.rangeHalfWidthSeconds * (2 - confidence)
            return SleepNeedRange(
                centerSeconds = center, lowSeconds = maxOf(0.0, center - halfWidth),
                highSeconds = center + halfWidth, confidence = confidence, effortPresent = effortPresent,
            )
        }

        /**
         * performance = actual / need * 100, stored uncapped, presented capped. The band inverts the
         * need band, and [SleepPerformance.showRange] fires below the confidence threshold.
         */
        fun computePerformance(actualSeconds: Double, need: SleepNeedRange, spec: SleepSpec): SleepPerformance {
            val center = if (need.centerSeconds > 0) actualSeconds / need.centerSeconds * 100 else 0.0
            val low = if (need.highSeconds > 0) actualSeconds / need.highSeconds * 100 else 0.0
            val high = if (need.lowSeconds > 0) actualSeconds / need.lowSeconds * 100 else center
            return SleepPerformance(
                centerPercent = center, cappedCenterPercent = min(center, spec.upperBoundPercent),
                lowPercent = low, highPercent = high, confidence = need.confidence,
                showRange = need.confidence < spec.lowConfidenceThreshold,
            )
        }

        /**
         * Rolling accumulator of signed shortfall (need - actual) with exponential decay, so old
         * shortfalls stop counting and a catch-up night pays debt down. Clamped to [0, max].
         */
        fun accumulateDebt(
            shortfalls: List<Pair<String, Double>>, asOfKey: String, halfLifeDays: Double,
            lookbackDays: Int, maxDebtSeconds: Double, includeAsOf: Boolean,
        ): Double {
            var sum = 0.0
            for ((key, seconds) in shortfalls) {
                val age = daysBetween(key, asOfKey)
                if (age < 0 || age > lookbackDays) continue
                if (age == 0 && !includeAsOf) continue
                sum += seconds * 0.5.pow(age.toDouble() / halfLifeDays)
            }
            return min(maxDebtSeconds, maxOf(0.0, sum))
        }

        /**
         * 0-100 from the timing spread of bed and wake times over the window. The spread is a
         * wrap-aware standard deviation (a 23:50 and a 00:10 bedtime are 20 minutes apart), arithmetic
         * only (no trig), so it is bit-identical across platforms.
         */
        fun computeConsistency(bedTimes: List<Double>, wakeTimes: List<Double>, spec: SleepSpec): Double {
            val bedComp = maxOf(0.0, 1 - circularSpreadSeconds(bedTimes) / spec.zeroScoreStdevSeconds)
            val wakeComp = maxOf(0.0, 1 - circularSpreadSeconds(wakeTimes) / spec.zeroScoreStdevSeconds)
            return 100 * (spec.bedWakeWeightSplit * bedComp + (1 - spec.bedWakeWeightSplit) * wakeComp)
        }

        /**
         * Count of awake episodes lasting at least `minEpisodeSeconds`, after merging episodes closer
         * than `mergeGapSeconds` (so stage-classifier flapping is one disturbance, not five).
         */
        fun countDisturbances(intervals: List<SleepInterval>, spec: SleepSpec): Int {
            val sorted = intervals.filter { it.durationSeconds > 0 }.sortedBy { it.start }
            if (sorted.isEmpty()) return 0
            val merged = ArrayList<SleepInterval>()
            var current = sorted[0]
            for (iv in sorted.drop(1)) {
                current = if (iv.start - current.end <= spec.mergeGapSeconds) {
                    SleepInterval(current.start, maxOf(current.end, iv.end))
                } else {
                    merged.add(current)
                    iv
                }
            }
            merged.add(current)
            return merged.count { it.durationSeconds >= spec.minEpisodeSeconds }
        }

        // MARK: - Pure helpers (identical on both platforms)

        /**
         * Wrap-aware population standard deviation of times-of-day (seconds). Times are unwrapped to
         * within ±half a day of the first sample, then a plain stdev is taken. Uses only `+ - * /` and
         * `sqrt` (IEEE-754 correctly rounded), keeping it bit-identical to the iOS mirror.
         */
        fun circularSpreadSeconds(times: List<Double>): Double {
            if (times.size < 2) return 0.0
            val day = 86_400.0
            val anchor = times[0]
            val unwrapped = times.map { t ->
                var d = (t - anchor) % day
                if (d < -day / 2) d += day
                if (d >= day / 2) d -= day
                anchor + d
            }
            val mean = unwrapped.sum() / unwrapped.size
            val variance = unwrapped.sumOf { (it - mean) * (it - mean) } / unwrapped.size
            return sqrt(variance)
        }

        /**
         * Wall-clock second-of-day for an epoch instant in a timezone (DST-correct via Calendar). Not
         * elapsed-seconds-since-midnight: on a spring-forward day 07:00 is 25200 both sides of the
         * transition, which keeps consistency stable across a DST night.
         */
        fun localSecondsOfDay(epochSeconds: Double, tz: String): Double {
            val c = GregorianCalendar(TimeZone.getTimeZone(tz))
            c.timeInMillis = (epochSeconds * 1000).toLong()
            return (c.get(GregorianCalendar.HOUR_OF_DAY) * 3600 +
                c.get(GregorianCalendar.MINUTE) * 60 +
                c.get(GregorianCalendar.SECOND)).toDouble()
        }

        /**
         * The calendar day before a "YYYY-MM-DD" key — the day whose exertion and naps feed this
         * night's need. Computed over UTC (a civil date has no zone), so identical on both platforms.
         */
        fun previousDayKey(key: String): String {
            val d = DayAttribution.dateFromDayKey(key, "UTC") ?: return key
            return DayAttribution.localDayKey(DayAttribution.addingDays(-1, d, "UTC"), "UTC")
        }

        /**
         * Whole days from [a] to [b] (positive when [b] is later). Both keys are UTC midnights, so the
         * difference is an exact day count — no DST fuzz.
         */
        fun daysBetween(a: String, b: String): Int {
            val da = DayAttribution.dateFromDayKey(a, "UTC") ?: return 0
            val db = DayAttribution.dateFromDayKey(b, "UTC") ?: return 0
            return ((db - da) / 86_400_000.0).roundToInt()
        }

        private fun approximatelyEqual(a: Double, b: Double, tolerance: Double = 1e-9): Boolean =
            abs(a - b) < tolerance
    }
}
