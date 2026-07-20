package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.Units
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.platform.health.HcTypeMap
import net.albayyan.badan.platform.health.IntervalDto
import net.albayyan.badan.platform.health.SampleDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The Android half of the cross-platform canonical-output fixture (Phase-0 exit criterion, plan
 * §19: "widened ingestion fixtures pass identically both platforms"; §20 EPIC-02 acceptance:
 * "same fixture set as EPIC-01 passes with identical canonical output").
 *
 * What this pins is the *canonicalization contract*: given a reading as a source reported it
 * (metric id + value + unit), what value, in what unit, does BADAN store? That is the layer where
 * the two platforms can actually diverge silently — a kcal/kJ mix-up, a percent-versus-fraction
 * slip, a missing dimension — and it is reachable in a pure-JVM test on both sides, which the
 * database layer is not (`SqliteConnection` is Android-only here; iOS's is not).
 *
 * The golden rows are `packages/fixtures/canonicalization/canonical-rows-v1.json`, read from the
 * repo. The iOS half is `apps/ios/Tests/CanonicalizationParityTests.swift`, which reads the SAME
 * file and asserts the same outputs through its own `Units`. If the two ever disagree, one
 * platform is storing a number the other would not recognise, and every export that claims to be
 * one format is really two.
 *
 * This docstring used to make that claim while the rows were a hardcoded Kotlin list below it and
 * no iOS counterpart existed at all — the audit finding this file was rewritten to fix. Nothing
 * on iOS compared against those rows; nothing would have failed if iOS's `Units` had diverged.
 * If you move the rows back inline, you delete the only thing that makes the claim true and
 * restore an exit criterion asserted on one platform.
 *
 * Fixtures are read from disk rather than copied into either platform's test sources: a copy is
 * one more thing that can drift from the artifact it is supposed to police (same reasoning as
 * `ExportEncryptorTest` and `UnitsRegistryParityTest`).
 */
class HealthConnectCanonicalParityTest {

    // Unit tests run with the module dir (`apps/android/app`) as the working directory.
    private val fixtureDir = File("../../../packages/fixtures/canonicalization")

    /**
     * One as-received reading and the exact pair BADAN must store for it.
     *
     * [value] and [canonicalValue] arrive as strings and are parsed with `String.toDouble` on
     * purpose — see the fixture README. They are compared for exact IEEE-754 equality, so the
     * parse has to be the correctly-rounded one on both platforms rather than whatever each
     * platform's JSON number handling decides a bare numeric literal is.
     */
    private data class Row(
        val id: String,
        val metricId: String,
        val value: Double,
        val unit: String,
        val canonicalUnit: String,
        val canonicalValue: Double,
        val emittedBy: List<String>,
    ) {
        /** The `HcTypeMap.platformType`s this row claims to arrive through, if any. */
        val healthConnectTypes: List<String> get() =
            emittedBy.filter { it.startsWith(HC_PREFIX) }.map { it.removePrefix(HC_PREFIX) }
    }

    /** A row the two platforms provably do NOT agree on yet. See the fixture README. */
    private data class Divergence(
        val id: String,
        val value: Double,
        val unit: String,
        val canonicalUnit: String,
        val android: String,
        val fix: String,
    )

    // MARK: - The shared fixture (the acceptance criterion)

    /**
     * Every row's as-received value, through this platform's `Units`, lands on the fixture's
     * canonical pair — exactly what `IngestionPipeline` does to a DTO before it becomes a row.
     * The arithmetic is duplicated here rather than driven through the pipeline because the
     * pipeline needs repositories and the arithmetic is the part under test.
     *
     * Both `convert` and `toCanonical` are asserted, and the `convert` leg is the load-bearing
     * one. `toCanonical` swallows an unknown or incompatible unit and returns the value unchanged
     * — right for ingestion (a bad unit must not crash the pipeline; it is flagged upstream) and
     * useless here, because for every identity row an entirely *missing* unit produces the same
     * number as a correct conversion. A fixture asserted through `toCanonical` alone would pass
     * while this platform's table had lost the dimension — the `vo2max-lowercase-litre` row is a
     * promoted example, and it was THIS platform that had lost it: `ml/kg/min` was missing from
     * Units.kt for a whole round while reading correctly through `toCanonical`.
     */
    @Test fun everyFixtureRowCanonicalizesToTheSharedGolden() {
        val canonical = registryCanonicalUnits()
        val rows = fixtureRows()

        for (row in rows) {
            assertEquals(
                "${row.id}: registry.json says ${row.metricId}'s canonical unit is " +
                    "'${canonical[row.metricId]}', the fixture says '${row.canonicalUnit}' — the " +
                    "contract moved under the golden",
                canonical[row.metricId], row.canonicalUnit,
            )

            val converted = try {
                Units.convert(row.value, row.unit, row.canonicalUnit)
            } catch (e: Units.ConversionError) {
                fail(
                    "${row.id}: Units cannot convert '${row.unit}' to '${row.canonicalUnit}' " +
                        "(${e.message}). iOS can — see the row's `emittedBy`. An unknown unit is " +
                        "not a crash at runtime, it is worse: the value is stored unconverted and " +
                        "stamped ESTIMATE.",
                )
                return
            }

            assertEquals("${row.id}: canonical value", row.canonicalValue, converted, 0.0)
            assertEquals(
                "${row.id}: Units.toCanonical (the path IngestionPipeline actually takes) " +
                    "disagrees with Units.convert",
                row.canonicalValue, Units.toCanonical(row.value, row.unit, row.canonicalUnit), 0.0,
            )
        }
    }

    /**
     * The rows that claim to arrive through Health Connect must still match what `HcTypeMap`
     * actually emits. This is the property the old inline golden had — it read its as-received
     * units out of `HcTypeMap` so the fixture broke if the table's unit column changed — kept
     * now that the units live in a shared file the table cannot reach.
     */
    @Test fun fixtureRowsAgreeWithTheUnitsHcTypeMapEmits() {
        for (row in fixtureRows()) {
            for (platformType in row.healthConnectTypes) {
                val entry = HcTypeMap.entry(platformType)
                assertNotNull(
                    "${row.id}: fixture names HcTypeMap type '$platformType', which no longer exists",
                    entry,
                )
                assertEquals("${row.id}: $platformType's metric id", row.metricId, entry!!.metricId)
                assertEquals(
                    "${row.id}: $platformType emits '${entry.unit}' but the fixture was written " +
                        "against '${row.unit}' — update the fixture and re-run BOTH suites",
                    row.unit, entry.unit,
                )
            }
        }
    }

    /**
     * Coverage, stated as an assertion rather than assumed: every Health Connect type that
     * produces a measurement row has a golden. "Widened ingestion fixtures" is the exit criterion;
     * a widened adapter with an un-widened fixture set meets it only on paper.
     *
     * Filtered to entries with a metric id because the sleep and workout types land in `sessions`,
     * not in a measurement table, and have no canonical value to pin.
     */
    @Test fun everyIngestedHealthConnectTypeHasAFixtureRow() {
        val covered = fixtureRows().flatMap { it.healthConnectTypes }.toSet()
        val uncovered = HcTypeMap.ingested
            .filter { it.metricId != null }
            .map { it.platformType }
            .filterNot { it in covered }

        assertTrue(
            "Health Connect types that produce rows but have no fixture row: $uncovered — add " +
                "one to packages/fixtures/canonicalization/canonical-rows-v1.json (with the " +
                "iOS spelling too, if HKTypeMap reads the same metric in a different unit)",
            uncovered.isEmpty(),
        )
    }

    /**
     * The divergences the fixture declares must still describe THIS platform. Stated as a test so
     * a known gap cannot quietly become a stale note: when someone fixes `Units.kt`, this fails
     * and tells them to promote the entry into `rows`.
     *
     * That is exactly what happened to the two entries this file used to carry: `ml/kg/min` was
     * missing from `Units.kt` and `brpm` was based on `count/min`, both fixed here, both promoted
     * into `rows`. `knownDivergences` is now empty and this test asserts nothing — kept because it
     * is the mechanism rather than those two entries, and an empty loop is the honest
     * representation of "the platforms agree on every unit in the fixture".
     *
     * A divergence that gets fixed and stays listed is a lie with a longer half-life than the bug
     * was — which is the whole reason these are declared rather than silently omitted from the
     * row set.
     */
    @Test fun knownDivergencesStillDescribeThisPlatform() {
        for (divergence in fixtureDivergences()) {
            val outcome = try {
                Units.convert(divergence.value, divergence.unit, divergence.canonicalUnit)
                "converts"
            } catch (_: Units.ConversionError.UnknownUnit) {
                "unknownUnit"
            } catch (_: Units.ConversionError.Incompatible) {
                "incompatible"
            }
            assertEquals(
                "known divergence '${divergence.id}' says Android does '${divergence.android}' " +
                    "with '${divergence.unit}', but it now does '$outcome'. If you just fixed " +
                    "this: ${divergence.fix}",
                divergence.android, outcome,
            )
        }
    }

    // MARK: - Local coverage (makes a fixture failure diagnosable)

    /**
     * Percent is the conversion most likely to be wrong in exactly one place, because the registry
     * canonical spells it "percent" while Health Connect's adapter emits "%" and HealthKit's emits
     * a 0-1 "fraction" — and all three resolve to the same base. If one platform ever treated "%"
     * as the fraction itself, a 97.5% SpO2 would be stored as 0.975 there and 97.5 here, and both
     * would render plausibly on their own screen.
     */
    @Test fun percentPercentSignAndFractionAreTheSameCanonicalValue() {
        assertEquals(97.5, Units.toCanonical(97.5, "%", "percent"), 1e-9)
        assertEquals(97.5, Units.toCanonical(97.5, "percent", "percent"), 1e-9)
        assertEquals(97.5, Units.toCanonical(0.975, "fraction", "percent"), 1e-9)
    }

    /**
     * A source that reports kilocalories must land on the same canonical number as one reporting
     * kilojoules. The Health Connect adapter emits kJ (so the common path is a no-op), HealthKit's
     * emits kcal, and the sample store deliberately emits kcal to keep this path exercised here
     * too.
     */
    @Test fun energyFromEitherUnitLandsOnTheSameCanonicalValue() {
        val fromKj = Units.toCanonical(4184.0, "kJ", "kJ")
        val fromKcal = Units.toCanonical(1000.0, "kcal", "kJ")
        assertEquals(fromKj, fromKcal, 0.01)
    }

    /**
     * Quality flags are part of canonical output, not decoration: a row that says "this timezone
     * was assumed" on one platform and says nothing on the other is not the same row. Pinned as
     * wire codes because that is what crosses the export boundary.
     */
    @Test fun qualityFlagWireCodesAreStable() {
        assertEquals("tzAssumed", QualityFlag.TZ_ASSUMED.code)
        assertEquals("estimate", QualityFlag.ESTIMATE.code)
        assertEquals("sampleData", QualityFlag.SAMPLE_DATA.code)
    }

    /**
     * The DTO contract itself, pinned so a field rename or default change on one platform shows up
     * as a failing fixture rather than as a silently different export column.
     */
    @Test fun dtoDefaultsMatchTheDocumentedContract() {
        val sample = SampleDto(
            metricId = MetricId.weight, value = 80.0, unit = "kg", start = 1_700_000_000_000L,
            tz = "GMT+03:00", sourceId = "com.example.app", externalId = "abc",
        )
        assertEquals("end defaults to null, not to start", null, sample.end)
        assertTrue("flags default to empty, never to a placeholder", sample.qualityFlags.isEmpty())

        val interval = IntervalDto(
            metricId = MetricId.steps, value = 100.0, unit = "count", start = 0L, end = 1L,
            tz = "GMT", aggregation = Aggregation.SUM, sourceId = "com.example.app", externalId = "abc",
        )
        assertEquals(Aggregation.SUM, interval.aggregation)
        assertEquals("sum", interval.aggregation.code)
    }

    // MARK: - Contract registry

    /**
     * The registry's canonical unit per metric, from the contract file both platforms build
     * against. Read rather than hard-coded so that a registry change breaks this test instead of
     * quietly making the goldens describe a unit BADAN no longer stores in.
     */
    private fun registryCanonicalUnits(): Map<String, String> {
        val file = File("../../../packages/metric-ontology/registry.json")
        assertTrue("contract registry must be readable at ${file.absolutePath}", file.exists())
        return Json.parseToJsonElement(file.readText()).jsonObject["metrics"]!!.jsonArray
            .mapNotNull { metric ->
                val obj = metric.jsonObject
                val id = obj["metricId"]?.jsonPrimitive?.content ?: return@mapNotNull null
                val unit = obj["canonicalUnit"]?.jsonPrimitive?.content ?: return@mapNotNull null
                id to unit
            }.toMap()
    }

    // MARK: - Shared fixture loading

    /**
     * Reads the shared fixture and checks its SHA-256 against the manifest before parsing.
     *
     * A missing file or a bad digest FAILS here; it never skips. Without the digest check, a
     * fixture mangled in transit (a text-mode checkout, a bad merge, a well-meaning reformat)
     * would surface as a canonicalization mismatch — technically true, and exactly the wrong
     * thing to send someone debugging a cross-platform disagreement. Same contract as
     * `ExportEncryptorTest.readFixtureContainer`; `scripts/check_fixture_hashes.sh` is the
     * out-of-band version of this check.
     */
    private fun fixtureBytes(): ByteArray {
        val manifestFile = File(fixtureDir, "manifest.json")
        assertTrue(
            "missing fixture manifest at ${manifestFile.absolutePath} — see " +
                "packages/fixtures/canonicalization/README.md",
            manifestFile.exists(),
        )
        val entry = Json.parseToJsonElement(manifestFile.readText()).jsonObject["files"]!!.jsonArray
            .map { it.jsonObject }
            .firstOrNull { it["id"]?.jsonPrimitive?.content == FIXTURE_ID }
        assertNotNull("fixture manifest has no entry '$FIXTURE_ID'", entry)

        val file = File(fixtureDir, entry!!["file"]!!.jsonPrimitive.content)
        assertTrue("missing fixture at ${file.absolutePath}", file.exists())
        val bytes = file.readBytes()

        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        assertEquals(
            "fixture '$FIXTURE_ID' does not match the SHA-256 recorded in manifest.json — the " +
                "shared artifact changed underneath this test. Do NOT run " +
                "scripts/check_fixture_hashes.sh --update to make this pass unless you meant to " +
                "change the fixture; see packages/fixtures/canonicalization/README.md",
            entry["sha256"]!!.jsonPrimitive.content, digest,
        )
        return bytes
    }

    private fun fixtureRows(): List<Row> {
        val rows = Json.parseToJsonElement(String(fixtureBytes(), Charsets.UTF_8))
            .jsonObject["rows"]!!.jsonArray
            .map { element ->
                val obj = element.jsonObject
                Row(
                    id = obj["id"]!!.jsonPrimitive.content,
                    metricId = obj["metricId"]!!.jsonPrimitive.content,
                    value = obj["value"]!!.jsonPrimitive.content.toDouble(),
                    unit = obj["unit"]!!.jsonPrimitive.content,
                    canonicalUnit = obj["canonicalUnit"]!!.jsonPrimitive.content,
                    canonicalValue = obj["canonicalValue"]!!.jsonPrimitive.content.toDouble(),
                    emittedBy = obj["emittedBy"]!!.jsonArray.map { it.jsonPrimitive.content },
                )
            }
        // An empty read reads as "everything passed" to every loop above. The floor is the
        // fourteen rows this fixture started life with, so a truncated file fails rather than
        // vacuously succeeding.
        assertTrue("shared fixture parsed to only ${rows.size} rows", rows.size >= 14)
        return rows
    }

    private fun fixtureDivergences(): List<Divergence> =
        Json.parseToJsonElement(String(fixtureBytes(), Charsets.UTF_8))
            .jsonObject["knownDivergences"]!!.jsonArray
            .map { element ->
                val obj = element.jsonObject
                Divergence(
                    id = obj["id"]!!.jsonPrimitive.content,
                    value = obj["value"]!!.jsonPrimitive.content.toDouble(),
                    unit = obj["unit"]!!.jsonPrimitive.content,
                    canonicalUnit = obj["canonicalUnit"]!!.jsonPrimitive.content,
                    android = obj["android"]!!.jsonPrimitive.content,
                    fix = obj["fix"]!!.jsonPrimitive.content,
                )
            }

    private companion object {
        const val FIXTURE_ID = "canonical-rows-v1"
        const val HC_PREFIX = "HcTypeMap:"
    }
}
