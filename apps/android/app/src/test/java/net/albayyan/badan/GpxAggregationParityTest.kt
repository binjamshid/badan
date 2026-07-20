package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.ExportAggregationMethod
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricKind
import net.albayyan.badan.domain.RoutePoint
import net.albayyan.badan.export.AggregateGranularity
import net.albayyan.badan.export.AggregateInputRow
import net.albayyan.badan.export.AggregateRecord
import net.albayyan.badan.export.AggregateStat
import net.albayyan.badan.export.CsvWriter
import net.albayyan.badan.export.GpxRoute
import net.albayyan.badan.export.GpxWorkout
import net.albayyan.badan.export.GpxWriter
import net.albayyan.badan.export.MetricAggregator
import net.albayyan.badan.export.RouteExportConfirmation
import net.albayyan.badan.export.RouteExportPlan
import net.albayyan.badan.export.WideCsvProjector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The Android half of the EPIC-12 (GPX) and EPIC-13 (aggregation + wide layout) cross-platform
 * fixtures — the exit criterion "the same input produces byte-identical output on both platforms".
 *
 * What this pins is the *serialization contract* of the two new writers: given one frozen input,
 * what exact bytes do `GpxWriter`, `MetricAggregator` and `WideCsvProjector` produce? These are
 * where the two platforms diverge silently — a coordinate on a dyadic rational (`25 + 1/256`) that
 * `String.format("%.7f")` rounds one way on the JVM and `printf("%.7f")` rounds the other way in C,
 * a DST-transition day whose length depends on getting the offset arithmetic right, a mixed-zone
 * bucket that has to agree on which zone anchors it. None of it is visible from inside one platform.
 *
 * The golden artifacts live in `packages/fixtures/gpx/` and `packages/fixtures/aggregation/`, read
 * from the repo. The iOS half is `apps/ios/Tests/GPXAggregationParityTests.swift`, which reads the
 * SAME inputs, builds the SAME objects, and must produce the same bytes through its own writers.
 * Neither test is sufficient alone: a shared misunderstanding still round-trips within one platform.
 *
 * Fixtures are read from disk, never copied into either platform's source — a copy is one more
 * thing that can drift from the artifact it polices (same reasoning as [ExportSchemaParityTest]).
 *
 * ## Regenerating (rare — read the fixture READMEs first)
 *
 * `BADAN_REGENERATE_EXPORT_GOLDENS=true ./gradlew :app:testDebugUnitTest` rewrites the goldens from
 * THIS platform's output and fails the run so the rewrite can never be mistaken for a pass. A
 * regenerated golden is not a verified golden: iOS must then be run against it unchanged.
 */
class GpxAggregationParityTest {

    private val gpxDir = File("../../../packages/fixtures/gpx")
    private val aggDir = File("../../../packages/fixtures/aggregation")
    private val regenerating = System.getenv("BADAN_REGENERATE_EXPORT_GOLDENS") == "true"

    // ===== EPIC-12: GPX =====

    @Test fun gpxRoutesMatchTheSharedGoldensByte() {
        val input = Json.parseToJsonElement(readVerified(gpxDir, "gpx-input-v1.json").toString(Charsets.UTF_8)).jsonObject
        val appVersion = input.getValue("appVersion").jsonPrimitive.content
        val generatedAt = input.getValue("generatedAtMillis").jsonPrimitive.content.toLong()
        val enabled = input.getValue("routeExportEnabled").jsonPrimitive.boolean

        val workouts = input.getValue("workouts").jsonArray.map { w ->
            val wo = w.jsonObject
            GpxWorkout(
                workoutId = wo.getValue("workoutId").jsonPrimitive.content,
                name = wo.getValue("name").jsonPrimitive.content,
                routes = wo.getValue("routes").jsonArray.map { r ->
                    val ro = r.jsonObject
                    val routeId = ro.getValue("routeId").jsonPrimitive.content
                    GpxRoute(
                        routeId = routeId,
                        points = ro.getValue("points").jsonArray.map { p ->
                            val po = p.jsonObject
                            val ele = po.getValue("ele").let { if (it is JsonNull) null else it.jsonPrimitive.content.toDouble() }
                            RoutePoint(
                                routeId = routeId, seq = po.getValue("seq").jsonPrimitive.content.toInt(),
                                lat = po.getValue("lat").jsonPrimitive.content.toDouble(),
                                lon = po.getValue("lon").jsonPrimitive.content.toDouble(),
                                altitudeM = ele, horizontalAccuracyM = null,
                                timestamp = po.getValue("ts").jsonPrimitive.content.toLong(),
                            )
                        },
                    )
                },
            )
        }

        val plan = RouteExportPlan.make(workouts)
        val confirmation = RouteExportConfirmation(plan, workouts)
        val artifacts = GpxWriter(appVersion, generatedAt).artifacts(workouts, enabled, confirmation)

        assertEquals("one GPX file per workout", workouts.size, artifacts.size)
        for (artifact in artifacts) {
            assertGolden(gpxDir, artifact.fileName, artifact.gpx)
        }
    }

    /**
     * The two route-export gates are independent and both enforced *before* any bytes are written.
     * Asserted here rather than assumed because "requires the route-export toggle" and "confirm the
     * exact route set" are the privacy contract of this feature, not implementation details.
     */
    @Test fun gpxRefusesWithoutTheExportToggleAndOnAStaleConfirmation() {
        val workouts = listOf(
            GpxWorkout(
                "01JQZ8WKATRN00000000000001", "run",
                listOf(GpxRoute("r", listOf(RoutePoint("r", 0, 1.0, 2.0, null, null, 1_000L)))),
            ),
        )
        val confirmation = RouteExportConfirmation(RouteExportPlan.make(workouts), workouts)
        val writer = GpxWriter("0.1.0", 0L)

        // Toggle off -> refused even with a valid confirmation.
        val toggleOff = runCatching { writer.artifacts(workouts, false, confirmation) }.exceptionOrNull()
        assertTrue("expected RouteExportNotEnabled", toggleOff is net.albayyan.badan.export.GpxExportException.RouteExportNotEnabled)

        // A confirmation acknowledging a DIFFERENT set is rejected against these workouts.
        val otherWorkouts = listOf(
            GpxWorkout(
                "01JQZ8WKACTY00000000000002", "ride",
                listOf(GpxRoute("r2", listOf(RoutePoint("r2", 0, 3.0, 4.0, null, null, 2_000L)))),
            ),
        )
        val staleConfirmation = RouteExportConfirmation(RouteExportPlan.make(otherWorkouts), otherWorkouts)
        val stale = runCatching { writer.artifacts(workouts, true, staleConfirmation) }.exceptionOrNull()
        assertTrue("expected ConfirmationStale", stale is net.albayyan.badan.export.GpxExportException.ConfirmationStale)
    }

    // ===== EPIC-13: aggregation + wide =====

    @Test fun aggregationRecordsAndWideMatchTheSharedGoldensByte() {
        val (rows, defs) = aggregationFixture()
        val agg = MetricAggregator()

        val hint = agg.aggregate(rows, AggregateGranularity.DAY, method = null, definitions = defs)
        val mam = agg.aggregate(rows, AggregateGranularity.DAY, ExportAggregationMethod.MIN_AVG_MAX, defs)

        assertGolden(aggDir, "records-hint-v1.csv", recordsCsv(hint))
        assertGolden(aggDir, "records-minavgmax-v1.csv", recordsCsv(mam))
        assertGolden(aggDir, "wide-v1.csv", WideCsvProjector().render(mam))
    }

    /**
     * DST and timezone-change correctness, asserted on the record fields the wide layout drops.
     * These come straight off the shared golden dump too (the goldens carry bucket_start_ms /
     * bucket_end_ms / contributing_tzs), so they are not a second source of truth — they are a
     * readable statement of what those columns mean, and why the fixture chose those dates.
     */
    @Test fun aggregationHandlesDstAndTimezoneChanges() {
        val (rows, defs) = aggregationFixture()
        val hint = MetricAggregator().aggregate(rows, AggregateGranularity.DAY, method = null, definitions = defs)

        val springDay = hint.first { it.metricId == "activity.steps" && it.bucketKey == "2026-03-08" }
        assertEquals("spring-forward day is 23h", 82_800_000L, springDay.bucketEndMillis - springDay.bucketStartMillis)

        val fallDay = hint.first { it.metricId == "activity.steps" && it.bucketKey == "2026-11-01" }
        assertEquals("fall-back day is 25h", 90_000_000L, fallDay.bucketEndMillis - fallDay.bucketStartMillis)

        val mixed = hint.first { it.metricId == "heart.hr" && it.bucketKey == "2026-06-20" }
        assertEquals("one bucket fed by two zones", listOf("America/New_York", "Asia/Dubai"), mixed.contributingTimezones)
        assertEquals("boundaries anchored in the earliest row's zone", "Asia/Dubai", mixed.tzId)
        assertTrue(mixed.spansMultipleTimezones)
    }

    /** `duration` and `latest` are computed by trivial code but distinct from the goldened stats. */
    @Test fun aggregationComputesDurationAndLatest() {
        val (rows, defs) = aggregationFixture()
        val agg = MetricAggregator()
        val duration = agg.aggregate(rows, AggregateGranularity.DAY, ExportAggregationMethod.DURATION, defs)
            .first { it.metricId == "activity.distance" && it.bucketKey == "2026-03-08" }
        assertEquals(7200.0, duration.value, 0.0)
        assertEquals("s", duration.unit)
        val latest = agg.aggregate(rows, AggregateGranularity.DAY, ExportAggregationMethod.LATEST, defs)
            .first { it.metricId == "activity.distance" && it.bucketKey == "2026-03-08" }
        assertEquals(1500.0, latest.value, 0.0)
    }

    @Test fun regenerationSwitchIsNeverAPass() {
        if (regenerating) {
            org.junit.Assert.fail(
                "goldens were regenerated from THIS platform's output. Run " +
                    "scripts/check_fixture_hashes.sh --update, then run BOTH suites with the switch OFF.",
            )
        }
    }

    // ===== helpers =====

    private fun aggregationFixture(): Pair<List<AggregateInputRow>, Map<String, MetricDefinition>> {
        val input = Json.parseToJsonElement(readVerified(aggDir, "aggregation-input-v1.json").toString(Charsets.UTF_8)).jsonObject
        val defs = input.getValue("definitions").jsonArray.associate { d ->
            val dobj = d.jsonObject
            val id = dobj.getValue("metricId").jsonPrimitive.content
            id to MetricDefinition(
                metricId = id, family = "",
                kind = MetricKind.fromCode(dobj.getValue("kind").jsonPrimitive.content),
                canonicalUnit = dobj.getValue("canonicalUnit").jsonPrimitive.content,
                nameEn = "", nameAr = "",
            )
        }
        val rows = input.getValue("rows").jsonArray.map { r ->
            val ro = r.jsonObject
            fun nullable(key: String) = ro.getValue(key).let { if (it is JsonNull) null else it.jsonPrimitive.content }
            AggregateInputRow(
                metricId = ro.getValue("metricId").jsonPrimitive.content,
                value = ro.getValue("value").jsonPrimitive.content.toDouble(),
                unit = ro.getValue("unit").jsonPrimitive.content,
                startAt = ro.getValue("startMs").jsonPrimitive.content.toLong(),
                endAt = nullable("endMs")?.toLong(),
                tzId = ro.getValue("tzId").jsonPrimitive.content,
                storedAggregation = nullable("storedAggregation")?.let { code -> Aggregation.entries.first { it.code == code } },
            )
        }
        return rows to defs
    }

    /**
     * Test-only serialization of the aggregator's records. NOT the product tidy CSV (CSVWriter owns
     * that); this dumps every AggregateRecord field so DST instants and mixed-zone provenance are
     * pinned cross-platform. Must stay byte-identical to iOS `GPXAggregationParityTests.recordsCSV`.
     */
    private fun recordsCsv(records: List<AggregateRecord>): String {
        val cols = listOf(
            "metric_id", "bucket_key", "granularity", "aggregation_method", "value", "unit",
            "bucket_start_ms", "bucket_end_ms", "tz_id", "contributing_tzs", "sample_count",
        )
        val out = StringBuilder(cols.joinToString(",") { CsvWriter.escape(it) })
        for (r in records) {
            val cells = listOf(
                r.metricId, r.bucketKey, r.granularity.csvGranularity.code, r.stat.csvMethod.code,
                CsvWriter.decimal(r.value), r.unit,
                r.bucketStartMillis.toString(), r.bucketEndMillis.toString(),
                r.tzId, r.contributingTimezones.joinToString(";"), r.sampleCount.toString(),
            )
            out.append(CsvWriter.NEWLINE).append(cells.joinToString(",") { CsvWriter.escape(it) })
        }
        out.append(CsvWriter.NEWLINE)
        return out.toString()
    }

    private fun assertGolden(dir: File, fileName: String, produced: String) {
        if (regenerating) {
            File(dir, fileName).writeBytes(produced.toByteArray(Charsets.UTF_8))
            return
        }
        val expected = readVerified(dir, fileName).toString(Charsets.UTF_8)
        assertEquals("$fileName is not byte-identical to what this platform's writer produced", expected, produced)
    }

    private fun readVerified(dir: File, fileName: String): ByteArray {
        val manifestFile = File(dir, "manifest.json")
        assertTrue("missing ${manifestFile.path}", manifestFile.isFile)
        val entry = Json.parseToJsonElement(manifestFile.readText()).jsonObject
            .getValue("files").jsonArray.map { it.jsonObject }
            .firstOrNull { it.getValue("file").jsonPrimitive.content == fileName }
        requireNotNull(entry) { "fixture manifest has no entry for '$fileName'" }

        val file = File(dir, fileName)
        assertTrue("missing fixture at ${file.path}", file.isFile)
        val bytes = file.readBytes()
        if (!regenerating) {
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            assertEquals(
                "fixture '$fileName' does not match the SHA-256 in manifest.json — the shared artifact " +
                    "changed underneath this test.",
                entry.getValue("sha256").jsonPrimitive.content, digest,
            )
        }
        return bytes
    }
}
