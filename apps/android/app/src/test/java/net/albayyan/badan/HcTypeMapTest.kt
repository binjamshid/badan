package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.Units
import net.albayyan.badan.platform.health.HcTypeMap
import net.albayyan.badan.platform.health.HealthConnectAdapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneOffset

/**
 * Guards for the Health Connect record-type table (EPIC-02).
 *
 * `HealthConnectAdapter` is not JVM-testable — it needs a `Context`, a provider, and a live
 * `HealthConnectClient` — so `HcTypeMap` exists precisely to hold the decisions that can be wrong
 * on the other side of that line: which metric a record becomes, in which unit, under which
 * permission, at which anchor key. These are those decisions, pinned.
 *
 * Unit tests run with the module dir (`apps/android/app`) as the working directory, which is what
 * lets the manifest and registry assertions below read the real files rather than a copy that
 * could drift from the thing it is policing.
 */
class HcTypeMapTest {

    // --- Table integrity ---

    @Test fun platformTypeKeysAreUniqueAndStable() {
        val keys = HcTypeMap.entries.map { it.platformType }
        assertEquals("platform_type is a persisted anchor key; duplicates orphan tokens", keys.size, keys.toSet().size)
        // Spot-check the exact spelling of a few. These strings live in `read_anchors` on real
        // devices; renaming one silently forces a full re-read for every existing install, so a
        // rename should have to break this test first.
        assertNotNull(HcTypeMap.entry("StepsRecord"))
        assertNotNull(HcTypeMap.entry("ExerciseSessionRecord"))
        assertNotNull(HcTypeMap.entry("SkinTemperatureRecord"))
    }

    @Test fun everyEntryEitherIngestsOrExplainsWhyNot() {
        for (entry in HcTypeMap.entries) {
            if (entry.isIngested) {
                assertNull(
                    "${entry.platformType}: an ingested entry must not carry a deferral reason",
                    entry.deferredReason,
                )
            } else {
                assertNull(
                    "${entry.platformType}: a deferred entry must not claim a metric",
                    entry.metricId,
                )
                assertTrue(
                    "${entry.platformType}: a deferred type must say why, or it reads as an oversight",
                    (entry.deferredReason ?: "").length > 20,
                )
            }
        }
    }

    /**
     * The nine types Android shipped with must still be ingested. This epic widened the record
     * set; a regression here would mean the widening silently dropped something that was working.
     */
    @Test fun originalNineRecordTypesStillIngest() {
        val original = listOf(
            "StepsRecord", "ActiveCaloriesBurnedRecord", "DistanceRecord", "HeartRateRecord",
            "RestingHeartRateRecord", "HeartRateVariabilityRmssdRecord", "RespiratoryRateRecord",
            "OxygenSaturationRecord", "SleepSessionRecord",
        )
        for (type in original) {
            val entry = HcTypeMap.entry(type)
            assertNotNull("$type was ingested before EPIC-02 and must still be", entry)
            assertTrue("$type must still be ingested", entry!!.isIngested)
        }
    }

    @Test fun epic02AddedTheTypesThePlanLists() {
        // Plan §14 line 1092, minus the cycle types (Phase 3, deliberately absent).
        val added = listOf(
            "ExerciseSessionRecord", "Vo2MaxRecord", "WeightRecord", "BodyFatRecord",
            "LeanBodyMassRecord", "SkinTemperatureRecord", "FloorsClimbedRecord",
        )
        for (type in added) {
            assertTrue("$type must be ingested", HcTypeMap.entry(type)?.isIngested == true)
        }
        // Menstruation/cycle types are Phase 3. Their absence is a decision, so it is asserted
        // rather than left to be noticed.
        assertTrue(
            "cycle types are Phase 3 and must not be read yet",
            HcTypeMap.entries.none { it.platformType.contains("Menstruation") || it.platformType.contains("Period") },
        )
    }

    // --- Units ---

    @Test fun everyEmittedUnitResolvesInUnits() {
        for (entry in HcTypeMap.entries) {
            assertTrue(
                "${entry.platformType} emits '${entry.unit}', which Units cannot convert",
                runCatching { Units.convert(1.0, entry.unit, entry.unit) }.isSuccess,
            )
        }
    }

    /**
     * Energy is emitted in kJ because the registry canonical is kJ, so the common path performs no
     * conversion at all. If someone "simplifies" this to kilocalories the numbers still come out
     * right — `Units` converts — but every energy row acquires a floating-point round trip and an
     * `original_unit` that disagrees with the other platform's fixtures for no reason.
     */
    @Test fun energyIsEmittedInTheRegistryCanonicalUnit() {
        assertEquals("kJ", HcTypeMap.entry("ActiveCaloriesBurnedRecord")!!.unit)
        assertEquals(4.184, Units.convert(1.0, "kcal", "kJ"), 0.001)
    }

    /**
     * The single most dangerous unit decision in the table. `Units`' degF spec carries the
     * freezing-point offset, which is correct for a temperature and wrong for a temperature
     * *difference*: a +0.5 degF deviation would canonicalize to roughly -17.5 degC — a plausible
     * looking number with the wrong sign and a 35-degree error. Skin temperature must stay degC.
     */
    @Test fun skinTemperatureDeviationIsCelsiusNotFahrenheit() {
        assertEquals("degC", HcTypeMap.entry("SkinTemperatureRecord")!!.unit)
        // Demonstrates the trap this guards, so the next reader does not have to take it on faith.
        assertEquals(-17.5, Units.convert(0.5, "degF", "degC"), 0.01)
    }

    // --- Permissions ---

    /**
     * A permission the adapter requests but the manifest does not declare fails silently at
     * request time — the user grants it and nothing happens. The two lists are only ever correct
     * together, so they are only ever checked together.
     */
    @Test fun everyRequestedPermissionIsDeclaredInTheManifest() {
        val missing = HcTypeMap.permissions.filterNot { it in declaredHealthPermissions() }.sorted()
        assertTrue("requested but not declared in AndroidManifest.xml: $missing", missing.isEmpty())
    }

    /**
     * The other direction, which nothing checked and which was wrong (audit finding #7): the
     * manifest declared READ_TOTAL_CALORIES_BURNED while this table deferred
     * `TotalCaloriesBurnedRecord` and documented, in as many words, why asking for a permission
     * BADAN does not act on is unacceptable.
     *
     * This is not a tidiness assertion. The Play Data Safety form is built from the manifest, so a
     * declaration here is a public statement that BADAN collects that data type — for a type that
     * never entered the app. `deferredTypesAreNotRequested` above only proved the adapter would not
     * *prompt* for it, which is the smaller half of the problem.
     */
    @Test fun deferredTypePermissionsAreNotDeclaredInTheManifest() {
        val declared = declaredHealthPermissions()
        val deferred = HcTypeMap.entries.filterNot { it.isIngested }
        assertTrue("sanity: the fixture assumes at least one deferred type", deferred.isNotEmpty())
        val overDeclared = deferred.filter { it.readPermission in declared }
            .map { "${it.platformType} -> ${it.readPermission}" }
            .sorted()
        assertTrue(
            "declared in AndroidManifest.xml but never ingested, so Play Data Safety would " +
                "disclose a data type that never enters the app: $overDeclared",
            overDeclared.isEmpty(),
        )
    }

    private fun declaredHealthPermissions(): Set<String> {
        val manifest = File("src/main/AndroidManifest.xml")
        assertTrue("manifest must be readable at ${manifest.absolutePath}", manifest.exists())
        // Digits are part of the character class because they are part of real permission names —
        // READ_VO2_MAX. An `[A-Z_]+` class silently fails to capture it, and the test then reports
        // a manifest omission that is really a bug in the test.
        //
        // Comment bodies are stripped first: the manifest explains *why* READ_TOTAL_CALORIES_BURNED
        // is absent, and naming it there must not read as declaring it.
        val body = manifest.readText().replace(Regex("""(?s)<!--.*?-->"""), "")
        return Regex("""android:name="(android\.permission\.health\.[A-Z0-9_]+)"""")
            .findAll(body)
            .map { it.groupValues[1] }
            .toSet()
    }

    @Test fun deferredTypesAreNotRequested() {
        val deferred = HcTypeMap.entries.filterNot { it.isIngested }
        assertTrue("sanity: the fixture assumes at least one deferred type", deferred.isNotEmpty())
        for (entry in deferred) {
            assertFalse(
                "${entry.platformType} is not ingested, so asking for it spends trust on nothing",
                entry.readPermission in HcTypeMap.permissions,
            )
        }
    }

    @Test fun adapterExposesTheTypeMapPermissions() {
        assertEquals(HcTypeMap.permissions, HealthConnectAdapter.permissions)
    }

    @Test fun familyPermissionsPartitionTheWholeSet() {
        val union = HcTypeMap.Family.entries.flatMap { HcTypeMap.permissions(it) }.toSet()
        assertEquals("staged consent must be able to ask for everything", HcTypeMap.permissions, union)
    }

    // --- Registry alignment ---

    private fun contractRegistryIds(): Set<String> {
        // The contract file, not the bundled asset: this is the source of truth both platforms
        // build against, and it is what determines whether a mapping is *correct*. Whether the
        // asset mirror has caught up is a separate question, asserted below.
        val file = File("../../../packages/metric-ontology/registry.json")
        assertTrue("contract registry must be readable at ${file.absolutePath}", file.exists())
        return Json.parseToJsonElement(file.readText()).jsonObject["metrics"]!!.jsonArray
            .map { it.jsonObject["metricId"]!!.jsonPrimitive.content }
            .toSet()
    }

    private fun assetRegistryIds(): Set<String> {
        val file = File("src/main/assets/registry.json")
        assertTrue("asset registry must be readable at ${file.absolutePath}", file.exists())
        return Json.parseToJsonElement(file.readText()).jsonObject["metrics"]!!.jsonArray
            .map { it.jsonObject["metricId"]!!.jsonPrimitive.content }
            .toSet()
    }

    @Test fun everyMappedMetricExistsInTheContractRegistry() {
        val ids = contractRegistryIds()
        val unknown = HcTypeMap.entries.mapNotNull { it.metricId }.filterNot { it in ids }.sorted()
        assertTrue("HcTypeMap maps metric ids the contract registry does not define: $unknown", unknown.isEmpty())
    }

    /**
     * The bundled asset is a mirror of the contract file, and `IngestionPipeline` skips any metric
     * id the bundled registry does not define (counting it as `unmapped`), so a mapping that exists
     * only in the contract does not actually flow on device.
     *
     * The gap this test was written for is closed: the doc here used to say the asset was v0.1.0
     * against a v0.2.0 contract with `body.wrist_temp_deviation` stranded on the far side. Both
     * files are v0.2.0 and define the same 72 ids today — checked, not assumed — so [knownGap] is
     * empty and this now asserts the mirror is whole rather than tracking how far behind it is.
     *
     * Kept as a subset assertion rather than switched to an exact match: an exact match would turn
     * a *correct* mirror refresh into a failing build. This fails only when a NEW mapping misses
     * the asset — a metric the table claims to ingest that would silently be counted `unmapped` on
     * device — which is the failure actually worth interrupting someone for. The mirror is
     * refreshed by `scripts/sync_android_assets.sh`, not by hand here.
     */
    @Test fun noNewMappingSilentlyMissesTheBundledAsset() {
        val knownGap = emptySet<String>()
        val asset = assetRegistryIds()
        val missing = HcTypeMap.entries.mapNotNull { it.metricId }.filterNot { it in asset }.toSortedSet()
        val unexpected = missing - knownGap
        assertTrue(
            "these mapped metrics are absent from the bundled registry and would be dropped at " +
                "ingest as `unmapped`: $unexpected — run scripts/sync_android_assets.sh",
            unexpected.isEmpty(),
        )
    }

    // --- Multi-writer priority ---

    @Test fun knownWritersOutrankUnknownOnesAndHealthConnectItself() {
        val samsung = HcTypeMap.writerPriority("com.sec.android.app.shealth")
        val unknown = HcTypeMap.writerPriority("com.example.somefitnessapp")
        val hcItself = HcTypeMap.writerPriority("com.google.android.apps.healthdata")
        assertTrue("a known sensor owner should outrank an unknown writer", samsung > unknown)
        assertTrue("Health Connect itself is the re-publisher of last resort", unknown > hcItself)
    }

    @Test fun wristDeviceBonusBeatsPhoneForTheSameWriter() {
        val onWatch = HcTypeMap.writerPriority("com.sec.android.app.shealth", deviceTypeWatch)
        val onPhone = HcTypeMap.writerPriority("com.sec.android.app.shealth", deviceTypePhone)
        assertTrue("watch-recorded data should outrank phone-recorded from the same app", onWatch > onPhone)
    }

    /**
     * An override replaces the computed value outright rather than nudging it. A user who says
     * "trust Garmin over Samsung Health" must not be quietly outvoted by a device bonus they never
     * saw — which is exactly what would happen if overrides were additive.
     */
    @Test fun overrideIsAbsoluteNotAdditive() {
        val overridden = HcTypeMap.writerPriority(
            "com.sec.android.app.shealth", deviceTypeWatch, mapOf("com.sec.android.app.shealth" to 5),
        )
        assertEquals(5, overridden)
    }

    /**
     * The bug this table was added to fix: before EPIC-02 every real writer package fell through
     * `IngestionPipeline.inferredPriority`'s English substring match ("watch"/"phone") and tied at
     * zero, so sleep dedup between two apps was decided by ULID ordering. No package name may
     * resolve to 0 now.
     */
    @Test fun noWriterResolvesToZeroPriority() {
        val packages = HcTypeMap.writerPriorityDefaults.keys + "com.example.unknown"
        for (pkg in packages) {
            assertTrue("$pkg must not tie at priority 0", HcTypeMap.writerPriority(pkg) > 0)
        }
    }

    // --- Identity + timezone ---

    @Test fun sampleIdsAreUniquePerSampleNotPerRecord() {
        val recordId = "abc-123"
        assertEquals(recordId, HcTypeMap.externalId(recordId))
        val a = HcTypeMap.sampleExternalId(recordId, 1_000L)
        val b = HcTypeMap.sampleExternalId(recordId, 2_000L)
        assertNotEquals("a 500-sample record would collapse to one stored reading", a, b)
        // Keyed by time, not index: Health Connect does not guarantee sample order within a
        // record, and an index-keyed id would reshuffle every row's identity on re-read.
        assertEquals(a, HcTypeMap.sampleExternalId(recordId, 1_000L))
    }

    @Test fun routeIdIsDerivedFromItsSessionSoReReadsReplace() {
        assertEquals(
            HcTypeMap.routeExternalId("session-1"),
            HcTypeMap.routeExternalId("session-1"),
        )
        assertNotEquals(HcTypeMap.routeExternalId("session-1"), HcTypeMap.routeExternalId("session-2"))
    }

    /**
     * A fixed-offset zone id, in the "GMT+hh:mm" form `java.util.TimeZone` actually parses.
     * `ZoneOffset.getId()` alone yields "+03:00", which `TimeZone.getTimeZone` does not recognise
     * and silently resolves to GMT — misfiling every night by the offset, with no error anywhere.
     */
    @Test fun zoneIdRoundTripsThroughTimeZone() {
        val id = HcTypeMap.zoneId(ZoneOffset.ofHours(3))!!
        assertEquals("GMT+03:00", id)
        assertEquals(3 * 60 * 60 * 1000, java.util.TimeZone.getTimeZone(id).rawOffset)

        assertEquals("GMT", HcTypeMap.zoneId(ZoneOffset.UTC))
        assertEquals(0, java.util.TimeZone.getTimeZone(HcTypeMap.zoneId(ZoneOffset.UTC)!!).rawOffset)

        val negative = HcTypeMap.zoneId(ZoneOffset.ofHours(-8))!!
        assertEquals(-8 * 60 * 60 * 1000, java.util.TimeZone.getTimeZone(negative).rawOffset)
    }

    @Test fun absentOffsetIsNullSoTheCallerCanFlagTheAssumption() {
        assertNull("null is what makes TZ_ASSUMED stampable rather than guessed", HcTypeMap.zoneId(null))
    }

    // --- History honesty ---

    @Test fun achievableWindowIsThirtyDaysForEveryType() {
        // BADAN does not request READ_HEALTH_DATA_HISTORY (see AndroidManifest), so 30 days is the
        // real ceiling regardless of the 90-day range the connect flow asks for.
        assertEquals(30, HcTypeMap.defaultHistoryWindowDays)
        for (entry in HcTypeMap.ingested) {
            assertEquals(30, HcTypeMap.achievableWindowDays(entry))
        }
    }

    private companion object {
        // androidx.health.connect.client.records.metadata.Device.TYPE_WATCH / TYPE_PHONE, spelled
        // numerically so this fixture does not load an SDK class purely to name two ints. Verified
        // against the connect-client 1.1.0 aar, not assumed.
        const val deviceTypeWatch = 1
        const val deviceTypePhone = 2
    }
}
