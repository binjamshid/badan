package net.albayyan.badan.platform.health

import net.albayyan.badan.core.Clock
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.TimeZone
import kotlin.math.PI
import kotlin.math.sin

/**
 * Deterministic, offline health source that stands in for HealthKit/Health Connect on the
 * emulator. All variation comes from an FNV-1a hash of "metricKey:dayIndex", so output is
 * stable and reproducible regardless of call order — the ingestion pipeline and downstream
 * insights get truthful, repeatable data (two overlapping sleep sources exercise dedup, a
 * mild "rough patch" gives the narrative something honest to say).
 */
class FakeHealthStore(
    private val clock: Clock,
    historyDays: Int = 90,
    private val tz: String = TimeZone.getDefault().id,
) : HealthStorePort {

    private val dayCount: Int = maxOf(1, historyDays)

    /** Bundles the three generated lists so they can share one `by lazy` delegate. */
    private class GeneratedHistory(
        val sessions: List<SessionDto>,
        val intervals: List<IntervalDto>,
        val samples: List<SampleDto>,
    )

    // Full history is generated lazily on first read (not at construction time), so building a
    // FakeHealthStore is cheap even off the IO dispatcher; reads just filter by the requested
    // range once the (memoized) generation has run.
    private val generated: GeneratedHistory by lazy { generateHistory() }
    private val allSessions: List<SessionDto> get() = generated.sessions
    private val allIntervals: List<IntervalDto> get() = generated.intervals
    private val allSamples: List<SampleDto> get() = generated.samples

    private fun generateHistory(): GeneratedHistory {
        val sessions = mutableListOf<SessionDto>()
        val intervals = mutableListOf<IntervalDto>()
        val samples = mutableListOf<SampleDto>()

        val now = clock.now()
        val todayStart = DayAttribution.startOfDay(now, tz)
        val cal = calendar()

        for (dayIndex in 0 until dayCount) {
            val daysAgo = dayCount - 1 - dayIndex
            val dayStart = DayAttribution.addingDays(-daysAgo, todayStart, tz)
            val dayEnd = DayAttribution.addingDays(1, dayStart, tz)
            val dayKey = DayAttribution.localDayKey(dayStart, tz)
            cal.timeInMillis = dayStart
            val weekday = cal.get(Calendar.DAY_OF_WEEK)
            val isWeekend = weekday == 1 || weekday == 7
            val roughPatch = daysAgo in 10..14

            val weekly = sin(2.0 * PI * dayIndex.toDouble() / 7.0)

            // Sleep window: bed ~23:00 (prev evening), wake ~06:45, both jittered; the rough
            // patch pushes bedtime later and wake earlier so total sleep truthfully drops.
            val bedBase = addSeconds(dayStart, -3600.0)                    // 23:00 prev day
            val bedJitter = (unit(dayKey, "bedtime") - 0.5) * 2 * 40 * 60  // +/- 40 min
            val bedtime = addSeconds(bedBase, bedJitter + (if (roughPatch) 40.0 * 60 else 0.0))
            val wakeBase = addSeconds(dayStart, (6 * 3600 + 45 * 60).toDouble()) // 06:45
            val wakeJitter = (unit(dayKey, "wake") - 0.5) * 2 * 30 * 60    // +/- 30 min
            val wake = addSeconds(wakeBase, wakeJitter - (if (roughPatch) 35.0 * 60 else 0.0))
            val inBed = (wake - bedtime) / 1000.0

            // --- Watch primary sleep, with realistic stage breakdown ---
            val (stages, asleep) = buildStages(bedtime, wake, inBed, roughPatch)
            sessions.add(
                SessionDto(
                    kind = SessionKind.SLEEP_PRIMARY, start = bedtime, end = wake, tz = tz,
                    sourceId = watchSource, deviceId = watchDevice,
                    externalId = "watch-sleep-$dayKey", stages = stages,
                    timeAsleepSeconds = asleep, timeInBedSeconds = inBed,
                ),
            )

            // --- iPhone rougher duplicate: overlapping (>=70%) boundaries, no stages ---
            val inset1 = 480.0 + unit(dayKey, "ip1") * 300                 // 8-13 min
            val inset2 = 360.0 + unit(dayKey, "ip2") * 300                 // 6-11 min
            val ipStart = addSeconds(bedtime, inset1)
            val ipEnd = addSeconds(wake, -inset2)
            val ipInBed = rounded((ipEnd - ipStart) / 1000.0 / 900.0) * 900.0 // ~15 min
            val ipAsleep = rounded(ipInBed * 0.88 / 600.0) * 600.0            // coarse
            sessions.add(
                SessionDto(
                    kind = SessionKind.SLEEP_PRIMARY, start = ipStart, end = ipEnd, tz = tz,
                    sourceId = phoneSource, deviceId = phoneDevice,
                    externalId = "iphone-sleep-$dayKey", stages = emptyList(),
                    timeAsleepSeconds = ipAsleep, timeInBedSeconds = ipInBed,
                ),
            )

            // --- Ingested workout, every third day (watch) ---
            // Totals are carried on the DTO rather than emitted as extra energy/distance interval
            // rows deliberately: this generator already writes one daily row per metric, and a
            // second contained row for the same metric and day would double-count in every daily
            // sum downstream. A real HealthKit workout also arrives with its totals attached, so
            // the DTO path is the honest shape to exercise here; Health Connect's assemble-from-
            // overlapping-records path is exercised by `WorkoutLinkage`'s own fixtures.
            //
            // Note what is NOT generated: routes. Sample mode must never invent GPS coordinates.
            // Every other fabricated value here is a number in a plausible range; a coordinate is
            // a *place*, and a fake trace would put the user somewhere they have never been, in a
            // map view, flagged only by a banner. Route ingestion is covered by tests that build
            // their own points, which is where invented coordinates belong.
            if (dayIndex % 3 == 1) {
                val startOffset = 17 * 3600 + (unit(dayKey, "wstart") * 3600).toLong()
                val workoutStart = addSeconds(dayStart, startOffset.toDouble())
                val durationMin = 30 + rounded(unit(dayKey, "wdur") * 30)
                val workoutEnd = addSeconds(workoutStart, durationMin * 60)
                val wEnergy = round1(clamp(900 + (unit(dayKey, "wenergy") - 0.5) * 700, 500.0, 2000.0))
                val wDistance = rounded(clamp(4500 + (unit(dayKey, "wdist") - 0.5) * 3000, 2000.0, 9000.0))
                val wAvgHr = rounded(clamp(138 + (unit(dayKey, "whr") - 0.5) * 20, 110.0, 165.0))
                sessions.add(
                    SessionDto(
                        kind = SessionKind.WORKOUT, subtype = "Evening run",
                        start = workoutStart, end = workoutEnd, tz = tz,
                        sourceId = watchSource, deviceId = watchDevice,
                        externalId = "watch-workout-$dayKey",
                        activityType = "running",
                        totals = WorkoutTotalsDto(
                            energyKj = wEnergy, distanceM = wDistance,
                            avgHrBpm = wAvgHr, maxHrBpm = wAvgHr + 18,
                        ),
                    ),
                )
            }

            // --- Daily interval metrics (watch) ---
            fun daily(metricId: String, unitStr: String, agg: Aggregation, value: Double) {
                intervals.add(
                    IntervalDto(
                        metricId = metricId, value = value, unit = unitStr, start = dayStart, end = dayEnd,
                        tz = tz, aggregation = agg, sourceId = watchSource, deviceId = watchDevice,
                        externalId = "watch-$metricId-$dayKey",
                    ),
                )
            }

            val rhr = clamp(57 + 2 * weekly + (unit(dayKey, "rhr") - 0.5) * 4 + (if (roughPatch) 5.0 else 0.0), 48.0, 72.0)
            daily(MetricId.restingHeartRate, "bpm", Aggregation.MEAN, rounded(rhr))

            val hrv = clamp(58 + 6 * weekly + (unit(dayKey, "hrv") - 0.5) * 16 - (if (roughPatch) 12.0 else 0.0), 30.0, 85.0)
            daily(MetricId.hrv, "ms", Aggregation.MEAN, rounded(hrv))

            val steps = clamp(8000 + (unit(dayKey, "steps") - 0.5) * 7000 + (if (isWeekend) 1500.0 else 0.0) - (if (roughPatch) 1500.0 else 0.0), 2000.0, 15000.0)
            daily(MetricId.steps, "count", Aggregation.SUM, rounded(steps))

            // Canonical energy is kJ; emitting kcal deliberately exercises unit conversion.
            val energy = clamp(420 + (unit(dayKey, "energy") - 0.5) * 360 + (if (isWeekend) 80.0 else 0.0) - (if (roughPatch) 60.0 else 0.0), 200.0, 750.0)
            daily(MetricId.activeEnergy, "kcal", Aggregation.SUM, rounded(energy))

            val distance = clamp(6000 + (unit(dayKey, "distance") - 0.5) * 5000 + (if (isWeekend) 800.0 else 0.0), 2500.0, 10000.0)
            daily(MetricId.distance, "m", Aggregation.SUM, rounded(distance))

            val exercise = clamp(32 + (unit(dayKey, "exercise") - 0.5) * 44 + (if (isWeekend) 8.0 else 0.0) - (if (roughPatch) 10.0 else 0.0), 0.0, 90.0)
            daily(MetricId.exerciseMinutes, "min", Aggregation.SUM, rounded(exercise))

            // Respiratory rate is a nightly mean over the sleep window.
            val resp = round1(clamp(14.3 + (unit(dayKey, "resp") - 0.5) * 1.8 + (if (roughPatch) 0.7 else 0.0), 11.0, 20.0))
            intervals.add(
                IntervalDto(
                    metricId = MetricId.respiratoryRate, value = resp, unit = "breaths/min",
                    start = bedtime, end = wake, tz = tz, aggregation = Aggregation.MEAN,
                    sourceId = watchSource, deviceId = watchDevice,
                    externalId = "watch-respiratory.rate-$dayKey",
                ),
            )

            // --- Sub-daily samples (watch) ---
            // SpO2: two nightly readings.
            for ((i, hour) in listOf(2.5, 4.5).withIndex()) {
                val spo2 = round1(clamp(97.6 + (unit(dayKey, "spo2$i") - 0.5) * 2.2 - (if (roughPatch) 0.5 else 0.0), 93.0, 100.0))
                val at = addSeconds(dayStart, hour * 3600)
                samples.add(
                    SampleDto(
                        metricId = MetricId.spo2, value = spo2, unit = "%", start = at, tz = tz,
                        sourceId = watchSource, deviceId = watchDevice,
                        externalId = "watch-respiratory.spo2-$dayKey-$i",
                    ),
                )
            }

            // Weight: every 3rd day, slow upward trend ~78 -> ~80 kg, measured mid-morning.
            if (dayIndex % 3 == 0) {
                val trend = dayIndex.toDouble() / maxOf(1, dayCount - 1).toDouble() * 2.0
                val weight = round1(78.0 + trend + (unit(dayKey, "weight") - 0.5) * 0.8)
                val at = addSeconds(dayStart, (7 * 3600 + 10 * 60).toDouble())
                samples.add(
                    SampleDto(
                        metricId = MetricId.weight, value = weight, unit = "kg", start = at, tz = tz,
                        sourceId = watchSource, deviceId = watchDevice,
                        externalId = "watch-body.weight-$dayKey",
                    ),
                )
            }

            // Heart rate: four spot readings across the day.
            val hrHours = listOf(8, 12, 16, 20)
            val hrBase = listOf(70.0, 88.0, 96.0, 76.0)
            for (i in hrHours.indices) {
                val hr = clamp(hrBase[i] + (unit(dayKey, "hr$i") - 0.5) * 24, 55.0, 120.0)
                val minute = unit(dayKey, "hrm$i") * 3540
                val at = addSeconds(dayStart, hrHours[i] * 3600 + minute)
                samples.add(
                    SampleDto(
                        metricId = MetricId.heartRate, value = rounded(hr), unit = "bpm", start = at, tz = tz,
                        sourceId = watchSource, deviceId = watchDevice,
                        externalId = "watch-heart.hr-$dayKey-$i",
                    ),
                )
            }
        }

        // Every row this class produces is invented, so every row says so. Stamped once here —
        // the single point where generation finishes — rather than at each construction site, so
        // a metric added to the generator later cannot silently ship unflagged. Mirrors iOS's
        // FakeHealthStore.
        return GeneratedHistory(
            sessions.map { it.copy(qualityFlags = it.qualityFlags + QualityFlag.SAMPLE_DATA) },
            intervals.map { it.copy(qualityFlags = it.qualityFlags + QualityFlag.SAMPLE_DATA) },
            samples.map { it.copy(qualityFlags = it.qualityFlags + QualityFlag.SAMPLE_DATA) },
        )
    }

    // MARK: HealthStorePort

    override fun availability(): HealthAvailability = HealthAvailability.available

    /**
     * The simulated devices behind the sample data.
     *
     * These were branded "Apple Watch" and "iPhone" under `com.apple.health` — on an Android
     * device. That is fabricated data claiming provenance from a competitor's platform that
     * cannot exist here: it surfaced in the provenance sheet, in the Sources screen, and in
     * exported CSV's `source_app`, telling the user their readings came from hardware they do not
     * own. Now BADAN's own namespace, with names that say "sample" wherever they are shown.
     *
     * [SourceType.HEALTHKIT] is kept only because it is the enum's platform-store case and the
     * dedup/priority path keys off the descriptor rather than the type. The watch/phone shape and
     * the priority gap are kept deliberately: they are what exercise the wearable-beats-phone
     * reconciliation the two overlapping sleep sources exist to test.
     */
    override fun sourceDescriptors(): List<SourceDescriptor> = listOf(
        SourceDescriptor(
            id = watchSource, displayName = "Sample watch (simulated)", type = SourceType.HEALTHKIT,
            bundleId = SAMPLE_BUNDLE_ID, deviceId = watchDevice,
            deviceName = "Sample watch (simulated)", deviceModel = "BADAN sample data", priority = 100,
        ),
        SourceDescriptor(
            id = phoneSource, displayName = "Sample phone (simulated)", type = SourceType.HEALTHKIT,
            bundleId = SAMPLE_BUNDLE_ID, deviceId = phoneDevice,
            deviceName = "Sample phone (simulated)", deviceModel = "BADAN sample data", priority = 50,
        ),
    )

    override fun readSamples(range: HealthDateRange): List<SampleDto> =
        allSamples.filter { it.start >= range.start && it.start <= range.end }

    override fun readIntervals(range: HealthDateRange): List<IntervalDto> =
        allIntervals.filter { it.start >= range.start && it.start <= range.end }

    override fun readSessions(range: HealthDateRange): List<SessionDto> =
        // Attributed to the morning they end (the "last night" key).
        allSessions.filter { it.end >= range.start && it.end <= range.end }

    // MARK: Deterministic generation helpers

    private fun calendar(): Calendar = GregorianCalendar(TimeZone.getTimeZone(tz))

    /** Add [seconds] (may be fractional/negative) to an epoch-millis [base], rounding to the ms. */
    private fun addSeconds(base: Long, seconds: Double): Long = base + Math.round(seconds * 1000.0)

    /** FNV-1a (64-bit) of "metricKey:salt" mapped into [0, 1) — the sole source of variation. */
    private fun unit(metricKey: String, salt: String): Double {
        var hash = 0xcbf29ce484222325UL
        for (b in "$metricKey:$salt".toByteArray(Charsets.UTF_8)) {
            hash = hash xor b.toUByte().toULong()
            hash = hash * 0x100000001b3UL
        }
        return (hash shr 11).toDouble() * (1.0 / 9007199254740992.0) // / 2^53
    }

    private fun clamp(x: Double, lo: Double, hi: Double): Double = minOf(maxOf(x, lo), hi)

    private fun round1(x: Double): Double = Math.round(x * 10.0).toDouble() / 10.0

    private fun rounded(x: Double): Double = Math.round(x).toDouble()

    /**
     * Contiguous stage segments tiling [bedtime, wake] with a realistic cycle pattern; the
     * rough-patch variant carries more awake time and less deep/REM. Returns the stages plus
     * total time asleep (sum of non-awake segments).
     */
    private fun buildStages(bedtime: Long, wake: Long, inBed: Double, rough: Boolean): Pair<List<StageDto>, Double> {
        val pattern: List<Pair<SleepStage, Double>> = if (rough) {
            listOf(
                SleepStage.AWAKE to 0.05, SleepStage.LIGHT to 0.11, SleepStage.DEEP to 0.06, SleepStage.LIGHT to 0.10,
                SleepStage.REM to 0.05, SleepStage.LIGHT to 0.10, SleepStage.AWAKE to 0.04, SleepStage.LIGHT to 0.10,
                SleepStage.DEEP to 0.05, SleepStage.LIGHT to 0.10, SleepStage.REM to 0.05, SleepStage.LIGHT to 0.08,
                SleepStage.AWAKE to 0.03, SleepStage.REM to 0.04, SleepStage.AWAKE to 0.04,
            )
        } else {
            listOf(
                SleepStage.AWAKE to 0.03, SleepStage.LIGHT to 0.10, SleepStage.DEEP to 0.09, SleepStage.LIGHT to 0.08,
                SleepStage.REM to 0.06, SleepStage.LIGHT to 0.10, SleepStage.DEEP to 0.06, SleepStage.LIGHT to 0.09,
                SleepStage.REM to 0.07, SleepStage.LIGHT to 0.10, SleepStage.AWAKE to 0.02, SleepStage.LIGHT to 0.06,
                SleepStage.REM to 0.09, SleepStage.LIGHT to 0.03, SleepStage.AWAKE to 0.02,
            )
        }

        val stages = mutableListOf<StageDto>()
        var asleep = 0.0
        var cursor = bedtime
        var cum = 0.0
        for ((idx, seg) in pattern.withIndex()) {
            cum += seg.second
            val end = if (idx == pattern.size - 1) wake else addSeconds(bedtime, cum * inBed)
            if (end <= cursor) continue
            stages.add(StageDto(stage = seg.first, start = cursor, end = end))
            if (seg.first != SleepStage.AWAKE) asleep += (end - cursor) / 1000.0
            cursor = end
        }
        return Pair(stages, asleep)
    }

    companion object {
        // Source identity (device wins dedup ties by priority — I4).
        private const val watchSource = "src_watch"
        private const val watchDevice = "watch-0001"
        private const val phoneSource = "src_iphone"
        private const val phoneDevice = "iphone-0001"

        /** Bundle id for both simulated sources — BADAN's own namespace, never Apple's or
         *  Google's. See [sourceDescriptors]. Matches iOS's `FakeHealthStore.sampleBundleId`. */
        const val SAMPLE_BUNDLE_ID = "com.badan.sampledata"
    }
}
