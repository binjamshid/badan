package net.albayyan.badan

import kotlinx.serialization.json.Json
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.ontology.SensorQualityFile
import net.albayyan.badan.ontology.SensorQualityLevel
import net.albayyan.badan.ontology.SensorQualityMap
import net.albayyan.badan.ontology.sensorQualityKey
import net.albayyan.badan.storage.JsonCoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The sensor-quality contract loader (`packages/contracts/sensor_quality.json`, plan §15 / §4
 * principle 9). Mirror of the iOS `SensorQualityTests`.
 *
 * Audit finding #6: this contract was consumed on iOS and had no Android consumer at all, while
 * `scripts/sync_android_assets.sh` bundled it into `assets/` and CI gated the mirror for parity —
 * a file the app never opened, policed on every push. These tests are what keep the Android side
 * of it real; if `SensorQualityMap` or the `SourcesScreen` section is removed, this fails rather
 * than the asset quietly going inert again.
 *
 * Reads the real bundled asset rather than a fixture, for the same reason `UnitsRegistryParityTest`
 * does: a broken mirror otherwise still "works", it just labels everything with the fallback.
 */
class SensorQualityTest {

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private val assetFile = File("src/main/assets/sensor_quality.json")

    /**
     * Decodes through the same `JsonCoding.json` the app uses, so this exercises the real decode
     * path (`ignoreUnknownKeys` skipping the English-only `familyNotes`, the lenient level
     * serializer) rather than a test-local parser. Only the `AssetManager` open() call is
     * substituted — there is no AssetManager on the JVM.
     */
    private fun map(): SensorQualityMap {
        assertTrue("sensor_quality.json must be readable at ${assetFile.absolutePath}", assetFile.exists())
        return SensorQualityMap(JsonCoding.json.decodeFromString<SensorQualityFile>(assetFile.readText()))
    }

    private fun source(type: SourceType, name: String = "Health Connect") =
        Source(id = "src", type = type, displayName = name, updatedAt = 0L, originDeviceId = "dev")

    private fun device(name: String, model: String? = null) = Device(
        id = "d-$name", sourceId = "src", name = name, model = model,
        firstSeen = 0L, lastSeen = 0L, updatedAt = 0L, originDeviceId = "dev",
    )

    // MARK: - Loading

    /** Catches a broken/missing `sync_android_assets.sh` mirror. */
    @Test fun contractLoads() {
        val map = map()
        assertFalse("sensor_quality.json failed to load or is empty", map.orderedClasses.isEmpty())
        assertNotEquals(SensorQualityMap.MISSING_VERSION, map.version)
        assertNotNull(map.sourceClass("wrist_wearable"))
        assertNotNull(map.sourceClass("unknown"))
    }

    /**
     * The Android asset is byte-identical to the canonical contract iOS reads. CI already compares
     * both mirrors, but that check lives in a workflow file; this one fails in the unit-test run a
     * developer actually watches. Compared as parsed JSON so formatting is not mistaken for drift.
     */
    @Test fun androidAssetMatchesTheCanonicalContract() {
        val canonical = File("../../../packages/contracts/sensor_quality.json")
        assertTrue(
            "canonical sensor_quality.json must be readable at ${canonical.absolutePath}",
            canonical.exists(),
        )
        assertEquals(
            "assets/sensor_quality.json has drifted from packages/contracts/sensor_quality.json " +
                "— run scripts/sync_android_assets.sh",
            Json.parseToJsonElement(canonical.readText()),
            Json.parseToJsonElement(assetFile.readText()),
        )
    }

    /**
     * Every quality key the contract authors must be reachable from some [MetricFamily].
     *
     * This is the test that was missing on iOS when it mattered. The contract declared entries for
     * `workout`, `cycle`, `hydration` and `lab` while the enum mapping had no case for any of them,
     * so all four resolved to `"unmapped"` and returned `defaultQuality` instead of the authored
     * level — a source the contract calls `unsupported` for a family was labelled "medium", on a
     * screen whose entire job is honesty about sensors. The reverse direction is deliberately NOT
     * asserted: a family with no contract entry is legitimate (see `sensorQualityKey`) and degrades
     * to `defaultQuality` by design.
     */
    @Test fun everyContractQualityKeyIsReachableFromAFamily() {
        val declared = map().orderedClasses.flatMap { it.quality.keys }.toSet()
        val reachable = MetricFamily.entries.map { it.sensorQualityKey }.toSet()
        val orphaned = (declared - reachable).sorted()

        assertEquals(
            "sensor_quality.json authors quality levels for $orphaned that no MetricFamily maps " +
                "to, so those levels can never be shown and every lookup silently returns " +
                "defaultQuality. Add the MetricFamily case (or its sensorQualityKey mapping).",
            emptyList<String>(), orphaned,
        )
    }

    /**
     * The contract's own resolution rule: a family with no entry for a class falls back to
     * `defaultQuality`, never to `high`. An unlabelled new family must degrade toward caution.
     */
    @Test fun unknownFamilyFallsBackToDefaultNotHigh() {
        val map = map()
        // MEDICATIONS maps to the deliberately-unmapped key, so no class has an entry for it.
        val level = map.level("wrist_wearable", MetricFamily.MEDICATIONS)
        assertEquals(map.defaultQuality, level)
        assertNotEquals(SensorQualityLevel.HIGH, level)
    }

    @Test fun unknownSourceClassFallsBackToDefault() {
        val map = map()
        assertEquals(map.defaultQuality, map.level("not_a_real_class", MetricFamily.HEART))
    }

    /**
     * Spot-checks of the contract's actual content, identical to the iOS assertions — a bad merge
     * into the shared JSON that inverts a claim is caught on both sides.
     */
    @Test fun knownClassLevelsMatchTheContract() {
        val map = map()
        assertEquals(SensorQualityLevel.HIGH, map.level("wrist_wearable", MetricFamily.HEART))
        assertEquals(SensorQualityLevel.LOW, map.level("wrist_wearable", MetricFamily.BODY))
        assertEquals(SensorQualityLevel.UNSUPPORTED, map.level("phone_handset", MetricFamily.HEART))
        assertEquals(SensorQualityLevel.MEDIUM, map.level("smart_scale", MetricFamily.BODY))
    }

    // MARK: - Classification

    @Test fun watchAndBandClassifyAsWristWearables() {
        val map = map()
        val hc = source(SourceType.HEALTH_CONNECT)
        assertEquals("wrist_wearable", map.classId(hc, listOf(device("Galaxy Watch", "SM-R900"))))
        assertEquals("wrist_wearable", map.classId(hc, listOf(device("Mi Band 8"))))
    }

    /**
     * An Arabic-named device must classify identically to its English equivalent — otherwise the
     * same watch is labelled `high` for activity in English and `medium` in Arabic, purely because
     * of the user's language.
     */
    @Test fun arabicDeviceNamesClassifyTheSameAsEnglish() {
        val map = map()
        val hc = source(SourceType.HEALTH_CONNECT)
        assertEquals("wrist_wearable", map.classId(hc, listOf(device("ساعة أبل"))))
        assertEquals("phone_handset", map.classId(hc, listOf(device("هاتف"))))
        assertEquals("smart_scale", map.classId(hc, listOf(device("ميزان ذكي"))))
    }

    /** An unrecognized device falls through to the source type's default rather than to a guess. */
    @Test fun unrecognisedDeviceFallsBackToSourceTypeDefault() {
        val map = map()
        assertEquals(
            "unknown",
            map.classId(source(SourceType.HEALTH_CONNECT), listOf(device("Zephyr 9000"))),
        )
        assertEquals("manual_entry", map.classId(source(SourceType.MANUAL), emptyList()))
        assertEquals("file_import", map.classId(source(SourceType.FILE_IMPORT), emptyList()))
    }

    /**
     * A source with no devices yet (freshly connected, nothing synced) is `unknown`, not an
     * optimistic assumption about hardware nobody has seen.
     */
    @Test fun sourceWithNoDevicesIsUnknown() {
        assertEquals("unknown", map().classId(source(SourceType.HEALTH_CONNECT), emptyList()))
    }

    /**
     * Every `SourceType` the domain can produce resolves to a class the contract actually declares.
     * A `sourceTypeDefaults` entry naming a class that does not exist would send every source of
     * that type through the unknown-class path and back out to `defaultQuality`, silently.
     */
    @Test fun everySourceTypeDefaultsToADeclaredClass() {
        val map = map()
        for (type in SourceType.entries) {
            val classId = map.classId(source(type), emptyList())
            assertNotNull(
                "SourceType.$type resolves to sensor class '$classId', which sensor_quality.json " +
                    "does not declare",
                map.sourceClass(classId),
            )
        }
    }

    // MARK: - Presentation

    /**
     * Class names come straight from the contract, which carries both languages precisely so this
     * surface doesn't have to invent Arabic for hardware categories.
     */
    @Test fun classNamesAndDescriptionsAreBilingual() {
        for (sourceClass in map().orderedClasses) {
            assertFalse("${sourceClass.sourceClassId} has no English name", sourceClass.nameEn.isEmpty())
            assertFalse("${sourceClass.sourceClassId} has no Arabic name", sourceClass.nameAr.isEmpty())
            assertNotEquals(
                "${sourceClass.sourceClassId}'s name is untranslated",
                sourceClass.nameEn, sourceClass.nameAr,
            )
            assertFalse(sourceClass.descriptionEn.isEmpty())
            assertFalse(sourceClass.descriptionAr.isEmpty())
        }
    }

    /**
     * Level copy is authored in Kotlin (the contract's own level descriptions are English-only), so
     * it gets the same bilingual check every other authored string does — and the same
     * judgemental-vocabulary check as iOS. The label vocabulary describes METHOD, never merit: a
     * grade ("poor", "bad", "weak") would read as a verdict on the user's equipment and, by
     * implication, on them.
     */
    @Test fun levelLabelsAreBilingualAndNonJudgemental() {
        val banned = listOf("poor", "bad", "weak", "unreliable", "inaccurate", "worse", "inferior")
        for (level in SensorQualityLevel.entries) {
            assertFalse(level.label.en.isEmpty())
            assertNotEquals(level.label.en, level.label.ar)
            assertTrue(
                "${level.code}'s Arabic label contains no Arabic script",
                level.label.ar.any { it.code in 0x0600..0x06FF },
            )
            assertFalse(level.explainer.en.isEmpty())
            assertNotEquals(level.explainer.en, level.explainer.ar)

            val lowered = "${level.label.en} ${level.explainer.en}".lowercase()
            for (word in banned) {
                assertFalse("${level.code} copy uses the judgemental word '$word'", lowered.contains(word))
            }
        }
    }

    // MARK: - Decoding

    /**
     * Lenient decode: an unrecognized level string from a newer iOS release must not fail the whole
     * file's decode and blank the map.
     */
    @Test fun unknownLevelStringDecodesToMediumRatherThanThrowing() {
        val json = """
        {
          "version": "test",
          "defaultQuality": "medium",
          "sourceTypeDefaults": {"healthConnect": "unknown"},
          "sourceClasses": [
            {"sourceClassId": "future_device", "nameEn": "Future", "nameAr": "مستقبلي",
             "descriptionEn": "d", "descriptionAr": "و",
             "quality": {"heart": "extremely_high"}}
          ]
        }
        """.trimIndent()

        val parsed = SensorQualityMap(JsonCoding.json.decodeFromString<SensorQualityFile>(json))
        assertNotNull(
            "One unknown level string must not take the whole contract down with it",
            parsed.sourceClass("future_device"),
        )
        assertEquals(SensorQualityLevel.MEDIUM, parsed.level("future_device", MetricFamily.HEART))
    }

    /** A missing/unreadable file yields an empty map and the sentinel version, not a crash. */
    @Test fun absentContractYieldsAnEmptyMap() {
        val empty = SensorQualityMap(file = null)
        assertTrue(empty.orderedClasses.isEmpty())
        assertEquals(SensorQualityMap.MISSING_VERSION, empty.version)
        assertNull(empty.sourceClass("wrist_wearable"))
        assertEquals(SensorQualityLevel.MEDIUM, empty.level("wrist_wearable", MetricFamily.HEART))
    }
}
