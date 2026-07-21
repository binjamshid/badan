package net.albayyan.badan

import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.domain.reports.EvidenceKind
import net.albayyan.badan.domain.reports.ReportBuilder
import net.albayyan.badan.domain.reports.ReportPeriod
import net.albayyan.badan.domain.reports.ReportPeriodKind
import net.albayyan.badan.domain.reports.ReportSectionKind
import net.albayyan.badan.domain.reports.TrendDirection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone

/**
 * EPIC-31 — the pure `ReportBuilder`, its period resolver, and the weekly trigger. Mirror of iOS
 * `ReportBuilderTests`.
 *
 * The acceptance contract lives here: a report MODEL snapshot (numbers + refs, not pixels), an honest
 * empty week, deterministic hashing, and — the transparency claim — that *every* evidence ref a claim
 * carries resolves to a row that was actually supplied.
 *
 * Scope, stated honestly: this module has no Robolectric and no `androidTest` source set, so nothing
 * here opens a real SQLite database. The evidence-resolution test therefore runs against the pure
 * `build` seam (refs must resolve into the exact input set) rather than a live store; the same
 * assertion over a real `DerivationRepository`/`LoggingRepository` is `ReportBuilderTests` on iOS.
 */
class ReportBuilderTest {

    private val tz = "UTC"

    // A Tuesday (2026-07-14 03:33 UTC), so the ISO week around it — 2026-W29, Mon 07-13 to Sun
    // 07-19 — is unambiguous, and the week the trigger picks (2026-W28) is fully in the past.
    private val now = 1_784_000_000_000L

    private fun dv(
        metric: String,
        day: String,
        value: Double,
        unit: String = "score_0_100",
        id: String = Ulid.newId(),
    ) = DerivedValue(
        id = id, metricId = metric, value = value, unit = unit, periodKey = "day:$day",
        algorithmId = "test", algorithmVersion = "1.0.0", computedAt = now, updatedAt = now,
        originDeviceId = "test-device",
    )

    private fun adherence(kind: AdherenceKind, id: String = Ulid.newId()) = AdherenceEvent(
        id = id, regimenId = "r1", kind = kind, occurredAt = now, tzId = tz,
        updatedAt = now, originDeviceId = "test-device",
    )

    private fun week() = ReportPeriod.week(now, tz)

    // MARK: - Structure + snapshot

    @Test fun weeklyModelHasScoreSectionsWithCorrectStats() {
        val period = week()
        val prior = ReportPeriod.prior(period, tz)
        // Sleep performance across 5 of 7 days: 60,70,80,90,100 → mean 80, min 60, max 100, latest 100.
        val sleep = period.dayKeys.zip(listOf(60.0, 70.0, 80.0, 90.0, 100.0))
            .map { (day, v) -> dv(MetricId.sleepPerformance, day, v) }
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.sleepPerformance to sleep),
                priorByMetric = emptyMap(), adherence = null, generatedAt = now,
            ),
        )

        assertTrue(model.hasSufficientData)
        assertEquals(ReportPeriodKind.WEEK, model.periodKind)
        assertEquals("1.0", model.schemaVersion)
        assertEquals("report.periodic@1.0.0", model.algorithmVersionId)

        val summary = model.section(ReportSectionKind.SLEEP)?.metrics?.firstOrNull()
        requireNotNull(summary) { "expected a sleep section with a metric summary" }
        assertEquals(MetricId.sleepPerformance, summary.metricId)
        assertEquals(5, summary.count)
        assertEquals(80.0, summary.mean!!, 1e-9)
        assertEquals(60.0, summary.min!!, 1e-9)
        assertEquals(100.0, summary.max!!, 1e-9)
        assertEquals(100.0, summary.latest!!, 1e-9)
        // No prior data → no delta, direction insufficient.
        assertNull(summary.deltaVsPrior)
        assertEquals(TrendDirection.INSUFFICIENT, summary.direction)
        assertEquals(5, summary.evidence.size)
        assertTrue(summary.evidence.all { it.kind == EvidenceKind.DERIVED_VALUE })
    }

    @Test fun deltaAndDirectionAgainstPriorPeriod() {
        val period = week()
        val prior = ReportPeriod.prior(period, tz)
        // Current mean 80 (4 days), prior mean 60 (4 days) → delta +20, direction up.
        val cur = period.dayKeys.zip(listOf(80.0, 80.0, 80.0, 80.0))
            .map { (day, v) -> dv(MetricId.readinessScore, day, v) }
        val pri = prior.dayKeys.zip(listOf(60.0, 60.0, 60.0, 60.0))
            .map { (day, v) -> dv(MetricId.readinessScore, day, v) }
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.readinessScore to cur),
                priorByMetric = mapOf(MetricId.readinessScore to pri),
                adherence = null, generatedAt = now,
            ),
        )
        val summary = model.section(ReportSectionKind.READINESS)?.metrics?.firstOrNull()
        assertEquals(20.0, summary?.deltaVsPrior!!, 1e-9)
        assertEquals(TrendDirection.UP, summary.direction)

        // A +33% shift crosses the 10% notable threshold → a change item, evidence from both periods.
        val change = model.section(ReportSectionKind.CHANGES)?.changes?.firstOrNull()
        requireNotNull(change) { "expected a change item" }
        assertEquals(MetricId.readinessScore, change.metricId)
        assertEquals(80.0, change.currentMean, 1e-9)
        assertEquals(60.0, change.priorMean, 1e-9)
        assertEquals(20.0, change.deltaAbs, 1e-9)
        assertEquals(TrendDirection.UP, change.direction)
        assertEquals(8, change.evidence.size) // 4 current + 4 prior
    }

    @Test fun smallShiftIsNotNotable() {
        val period = week()
        val prior = ReportPeriod.prior(period, tz)
        // 80 vs 78 → 2.5% < 10% → not a notable change.
        val cur = period.dayKeys.zip(listOf(80.0, 80.0, 80.0)).map { (d, v) -> dv(MetricId.effortDay, d, v) }
        val pri = prior.dayKeys.zip(listOf(78.0, 78.0, 78.0)).map { (d, v) -> dv(MetricId.effortDay, d, v) }
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.effortDay to cur),
                priorByMetric = mapOf(MetricId.effortDay to pri),
                adherence = null, generatedAt = now,
            ),
        )
        assertNull("a 2.5% shift must not be a notable change", model.section(ReportSectionKind.CHANGES))
    }

    @Test fun belowMinComparableDaysGivesNoDelta() {
        val period = week()
        val prior = ReportPeriod.prior(period, tz)
        // Only 2 current days (< MIN_COMPARABLE_DAYS = 3) → no delta even though prior has enough.
        val cur = period.dayKeys.zip(listOf(80.0, 90.0)).map { (d, v) -> dv(MetricId.sleepPerformance, d, v) }
        val pri = prior.dayKeys.zip(listOf(60.0, 60.0, 60.0)).map { (d, v) -> dv(MetricId.sleepPerformance, d, v) }
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.sleepPerformance to cur),
                priorByMetric = mapOf(MetricId.sleepPerformance to pri),
                adherence = null, generatedAt = now,
            ),
        )
        assertNull(model.section(ReportSectionKind.SLEEP)?.metrics?.first()?.deltaVsPrior)
        assertNull(model.section(ReportSectionKind.CHANGES))
    }

    // MARK: - Adherence (counts only, I7)

    @Test fun adherenceSummaryCounts() {
        val period = week()
        val events = listOf(
            adherence(AdherenceKind.TAKEN), adherence(AdherenceKind.TAKEN),
            adherence(AdherenceKind.LATE), adherence(AdherenceKind.SKIPPED),
        )
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = ReportPeriod.prior(period, tz),
                currentByMetric = emptyMap(), priorByMetric = emptyMap(),
                adherence = events, generatedAt = now,
            ),
        )
        val a = model.section(ReportSectionKind.ADHERENCE)?.adherence
        requireNotNull(a) { "expected adherence section" }
        assertEquals(2, a.taken)
        assertEquals(1, a.late)
        assertEquals(1, a.skipped)
        assertEquals(4, a.logged)
        assertEquals(0.75, a.adherenceRate!!, 1e-9) // (2 taken + 1 late) / 4
        assertEquals(4, a.evidence.size)
        assertTrue(a.evidence.all { it.kind == EvidenceKind.ADHERENCE_EVENT })
    }

    // MARK: - Empty week (honest, never fabricated)

    @Test fun emptyWeekIsHonestNotFabricated() {
        val period = week()
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = ReportPeriod.prior(period, tz),
                currentByMetric = emptyMap(), priorByMetric = emptyMap(),
                adherence = emptyList(), generatedAt = now,
            ),
        )
        assertFalse(model.hasSufficientData)
        assertTrue(model.sections.isEmpty())
        assertEquals(64, model.sha256.length) // still a valid, hashable model
    }

    // MARK: - Determinism / hashing

    @Test fun hashIsStableAcrossRunsAndIgnoresGeneratedAt() {
        val period = week()
        val prior = ReportPeriod.prior(period, tz)
        // Fixed ids so re-building with the same inputs is bit-identical.
        val a = dv(MetricId.sleepPerformance, period.dayKeys[0], 70.0, id = "id-a")
        val b = dv(MetricId.sleepPerformance, period.dayKeys[1], 80.0, id = "id-b")
        fun buildWith(rows: List<DerivedValue>, at: Long) = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.sleepPerformance to rows),
                priorByMetric = emptyMap(), adherence = null, generatedAt = at,
            ),
        )
        assertEquals(
            "generatedAt must not affect the content hash",
            buildWith(listOf(a, b), now).sha256,
            buildWith(listOf(a, b), now + 9_999_000).sha256,
        )
        val c = dv(MetricId.sleepPerformance, period.dayKeys[1], 81.0, id = "id-b")
        assertNotEquals(
            "a changed value must change the content hash",
            buildWith(listOf(a, b), now).sha256,
            buildWith(listOf(a, c), now).sha256,
        )
    }

    // MARK: - Every claim resolves to a real evidence ref

    @Test fun everyEvidenceRefResolvesToASuppliedRow() {
        val period = week()
        val prior = ReportPeriod.prior(period, tz)
        val cur = period.dayKeys.mapIndexed { i, day -> dv(MetricId.readinessScore, day, 60.0 + i * 4) }
        val pri = prior.dayKeys.map { dv(MetricId.readinessScore, it, 50.0) }
        val events = listOf(adherence(AdherenceKind.TAKEN), adherence(AdherenceKind.SKIPPED))
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.readinessScore to cur),
                priorByMetric = mapOf(MetricId.readinessScore to pri),
                adherence = events, generatedAt = now,
            ),
        )

        val derivedIds = (cur + pri).map { it.id }.toSet()
        val adherenceIds = events.map { it.id }.toSet()
        var checked = 0
        for (section in model.sections) {
            for (metric in section.metrics) {
                for (ref in metric.evidence) {
                    assertTrue("derived evidence ${ref.id} must be real", derivedIds.contains(ref.id))
                    checked++
                }
            }
            for (change in section.changes) {
                for (ref in change.evidence) {
                    assertTrue("derived evidence ${ref.id} must be real", derivedIds.contains(ref.id))
                    checked++
                }
            }
            section.adherence?.evidence?.forEach { ref ->
                assertTrue("adherence evidence ${ref.id} must be real", adherenceIds.contains(ref.id))
                checked++
            }
        }
        assertTrue("the report must carry at least one evidence ref", checked > 0)
    }

    /** Counts only: no medication name, dosage or skip reason may reach the model (I7). */
    @Test fun adherenceEvidenceCarriesIdsOnly() {
        val period = week()
        val model = ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = ReportPeriod.prior(period, tz),
                currentByMetric = emptyMap(), priorByMetric = emptyMap(),
                adherence = listOf(adherence(AdherenceKind.TAKEN, id = "ev-1")), generatedAt = now,
            ),
        )
        val evidence = model.section(ReportSectionKind.ADHERENCE)?.adherence?.evidence.orEmpty()
        assertEquals(listOf("ev-1"), evidence.map { it.id })
        assertTrue("an adherence ref must carry no day period key", evidence.all { it.periodKey == null })
    }

    // MARK: - Period resolver

    @Test fun weekResolverShapeAndRoundTrip() {
        val w = week()
        assertEquals(7, w.dayKeys.size)
        assertTrue(w.periodKey.startsWith("week:"))
        assertTrue(w.start < w.end)
        // First day is a Monday.
        val cal = GregorianCalendar(TimeZone.getTimeZone(tz))
        cal.timeInMillis = w.start
        assertEquals("ISO week starts Monday", Calendar.MONDAY, cal.get(Calendar.DAY_OF_WEEK))
        // Round-trips through resolve.
        assertEquals(w.dayKeys, ReportPeriod.resolve(w.periodKey, tz)?.dayKeys)
        // Prior week ends where this one starts.
        assertEquals(w.start, ReportPeriod.prior(w, tz).end)
    }

    @Test fun monthResolverShapeAndRoundTrip() {
        val m = ReportPeriod.month(now, tz)
        assertTrue(m.dayKeys.size in 28..31)
        assertTrue(m.periodKey.startsWith("month:"))
        assertEquals(m.dayKeys, ReportPeriod.resolve(m.periodKey, tz)?.dayKeys)
        assertEquals(m.start, ReportPeriod.prior(m, tz).end)
    }

    @Test fun malformedPeriodKeyRejected() {
        assertNull(ReportPeriod.resolve("week:2026-W54", tz))
        assertNull(ReportPeriod.resolve("month:2026-13", tz))
        assertNull(ReportPeriod.resolve("day:2026-07-13", tz))
    }

    /** The two platforms must agree on which week a given instant belongs to, key and days alike. */
    @Test fun weekKeyMatchesTheIsoWeekOfTheInstant() {
        assertEquals("week:2026-W29", week().periodKey)
        assertEquals("2026-07-13", week().dayKeys.first())
        assertEquals("2026-07-19", week().dayKeys.last())
    }

    /**
     * A period key is a machine key — stored, pattern-matched against the shared contract, sorted,
     * and compared across devices — so it must be Western-digit regardless of the device's locale.
     * `String.format` without an explicit locale uses `Locale.getDefault(FORMAT)`, and for `ar` /
     * `ar-SA` / `ar-EG` the JVM's zero digit is `٠`, so an un-localed `%04d` renders
     * `week:٢٠٢٦-W٢٩`: it fails the contract's `^week:\d{4}-W\d{2}$`, sorts wrong against every
     * Western-digit key, and lets one week be generated twice if the user changes locale. Arabic
     * DIGITS belong in `ReportPresentation`'s labels, never in a key.
     */
    @Test fun periodKeysAreWesternDigitsUnderAnArabicDefaultLocale() {
        val original = Locale.getDefault()
        try {
            for (tag in listOf("ar", "ar-SA", "ar-EG")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                val week = ReportPeriod.week(now, tz)
                val month = ReportPeriod.month(now, tz)
                assertEquals("$tag: week key must be Western-digit", "week:2026-W29", week.periodKey)
                assertEquals("$tag: month key must be Western-digit", "month:2026-07", month.periodKey)
                assertTrue(
                    "$tag: week key must match the contract's pattern",
                    Regex("^week:\\d{4}-W\\d{2}$").matches(week.periodKey),
                )
                assertTrue(
                    "$tag: month key must match the contract's pattern",
                    Regex("^month:\\d{4}-\\d{2}$").matches(month.periodKey),
                )
                // And it still round-trips, which a locale-formatted key would not do consistently.
                assertEquals(week.dayKeys, ReportPeriod.resolve(week.periodKey, tz)?.dayKeys)
            }
        } finally {
            Locale.setDefault(original)
        }
    }

    // MARK: - Trigger

    @Test fun lastCompletedWeekIsFullyInThePast() {
        val last = net.albayyan.badan.domain.reports.ReportTrigger.lastCompletedWeek(now, tz)
        val startToday = DayAttribution.startOfDay(now, tz)
        assertTrue("every day of a completed week is before today", last.end <= startToday)
    }

    @Test fun dueWeeklyReturnsKeyThenNothingOnceGenerated() {
        val trigger = net.albayyan.badan.domain.reports.ReportTrigger
        val last = trigger.lastCompletedWeek(now, tz)
        assertEquals(listOf(last.periodKey), trigger.dueWeeklyPeriodKeys(now, tz, emptySet()))
        assertEquals(emptyList<String>(), trigger.dueWeeklyPeriodKeys(now, tz, setOf(last.periodKey)))
    }

    /**
     * A fresh install must NOT manufacture reports for weeks that predate it. With no report rows at
     * all there is no run of reports to have a gap in, so only the last completed week is due.
     */
    @Test fun firstEverRunGeneratesOnlyTheLastCompletedWeek() {
        val trigger = net.albayyan.badan.domain.reports.ReportTrigger
        assertEquals(
            listOf(trigger.lastCompletedWeek(now, tz).periodKey),
            trigger.dueWeeklyPeriodKeys(now, tz, emptySet(), maxBackfillWeeks = 4),
        )
    }

    /**
     * The defect this backfill exists for: three weeks with no background wake used to leave two
     * weeks permanently unreported, because by the time a wake landed they were no longer "last".
     * Here reports exist up to three weeks back; the two skipped weeks and the current one are all
     * due, newest first.
     */
    @Test fun threeMissedWakesBackfillTheSkippedWeeks() {
        val trigger = net.albayyan.badan.domain.reports.ReportTrigger
        val w0 = trigger.lastCompletedWeek(now, tz)
        val w1 = ReportPeriod.prior(w0, tz)
        val w2 = ReportPeriod.prior(w1, tz)
        val w3 = ReportPeriod.prior(w2, tz)
        assertEquals(
            listOf(w0.periodKey, w1.periodKey, w2.periodKey),
            trigger.dueWeeklyPeriodKeys(now, tz, setOf(w3.periodKey), maxBackfillWeeks = 4),
        )
    }

    /**
     * The horizon is a real bound, not decoration: with `maxBackfillWeeks = 2` only the last
     * completed week and the one before it can be returned, however long the outage was.
     */
    @Test fun backfillIsBoundedByTheHorizon() {
        val trigger = net.albayyan.badan.domain.reports.ReportTrigger
        val w0 = trigger.lastCompletedWeek(now, tz)
        val w1 = ReportPeriod.prior(w0, tz)
        var w5 = w1
        repeat(4) { w5 = ReportPeriod.prior(w5, tz) }
        assertEquals(
            listOf(w0.periodKey, w1.periodKey),
            trigger.dueWeeklyPeriodKeys(now, tz, setOf(w5.periodKey), maxBackfillWeeks = 2),
        )
    }

    /**
     * `periodKeys` comes straight from the reports table and carries monthly keys too. A month key
     * must not be mistaken for the weekly run's floor — it sorts before every `week:` key, which
     * would otherwise open the backfill all the way to the horizon on a fresh install that had only
     * ever generated a monthly report.
     */
    @Test fun monthlyKeysDoNotSeedTheWeeklyBackfillFloor() {
        val trigger = net.albayyan.badan.domain.reports.ReportTrigger
        assertEquals(
            listOf(trigger.lastCompletedWeek(now, tz).periodKey),
            trigger.dueWeeklyPeriodKeys(now, tz, setOf("month:2020-01"), maxBackfillWeeks = 4),
        )
    }
}
