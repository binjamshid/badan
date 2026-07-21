package net.albayyan.badan

import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.domain.derivation.DayValue
import net.albayyan.badan.domain.derivation.DeviationEngine
import net.albayyan.badan.domain.derivation.TempDirection
import net.albayyan.badan.domain.derivation.VitalReading
import net.albayyan.badan.domain.derivation.VitalState
import net.albayyan.badan.ontology.SensorQualityFile
import net.albayyan.badan.ontology.SensorQualityLevel
import net.albayyan.badan.ontology.SensorQualityMap
import net.albayyan.badan.storage.JsonCoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * EPIC-27 — the pure half of the DeviationEngine, and the parity anchor for the iOS
 * `DeviationEngineTests`. The tile a given input produces, and the bilingual copy it carries, must be
 * byte-identical across platforms. Android has no DB-backed test harness (see
 * `BaselineEngineGoldenTest`'s note), so the read-model assembly (`buildReadModel`) is exercised on
 * iOS; what runs here is `makeTile` + `tempDirection` + `buildSparkline` + `resolveSourceQuality` and
 * the authored copy, asserted against the SAME expected states and strings as iOS.
 */
class DeviationEngineTest {

    private fun rhrDef() = MetricDefinition(
        metricId = MetricId.restingHeartRate, family = "heart", canonicalUnit = "bpm",
        nameEn = "Resting heart rate", nameAr = "معدل ضربات القلب أثناء الراحة",
    )

    private fun tempDef() = MetricDefinition(
        metricId = MetricId.wristTempDeviation, family = "body", canonicalUnit = "degC",
        nameEn = "Wrist temperature deviation", nameAr = "انحراف حرارة المعصم",
    )

    private fun band(center: Double, low: Double, high: Double, provisional: Boolean) = Baseline(
        id = "baseline-1", metricId = MetricId.restingHeartRate, windowDays = 14, center = center,
        spread = 2.0, bandLow = low, bandHigh = high, nPoints = if (provisional) 4 else 14,
        provisional = provisional, algorithmVersion = "baseline.rolling_median_mad@2.0.0",
        validFrom = 0L, computedAt = 0L, unit = "bpm",
    )

    private fun map(): SensorQualityMap {
        val assetFile = File("src/main/assets/sensor_quality.json")
        assertTrue("sensor_quality.json must be readable", assetFile.exists())
        return SensorQualityMap(JsonCoding.json.decodeFromString<SensorQualityFile>(assetFile.readText()))
    }

    // MARK: - Band classification (mirror of DeviationEngineTests.swift)

    @Test fun withinBandProducesNoAnnotation() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = DayValue("2026-07-20", 57.0),
            band = band(55.0, 50.0, 60.0, provisional = false),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.WithinBand, tile.state)
        assertNull("within the band is calm silence, not a note", tile.annotation)
        assertFalse(tile.isStale)
        assertEquals(VitalReading.Absolute(57.0), tile.reading)
        assertEquals("baseline-1", tile.band?.baselineId)
    }

    @Test fun aboveBandProducesCalmAnnotation() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = DayValue("2026-07-20", 65.0),
            band = band(55.0, 50.0, 60.0, provisional = false),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.AboveBand, tile.state)
        assertEquals(DeviationEngine.bandAnnotation(Baseline.Position.ABOVE), tile.annotation)
    }

    @Test fun belowBandProducesCalmAnnotation() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = DayValue("2026-07-20", 45.0),
            band = band(55.0, 50.0, 60.0, provisional = false),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.BelowBand, tile.state)
        assertEquals(DeviationEngine.bandAnnotation(Baseline.Position.BELOW), tile.annotation)
    }

    @Test fun provisionalBandIsCalibratingNotClassified() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = DayValue("2026-07-20", 65.0),
            band = band(55.0, 50.0, 60.0, provisional = true),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.Calibrating, tile.state)
        assertNull(tile.annotation)
        assertEquals(true, tile.band?.provisional)
    }

    @Test fun absentBandIsCalibrating() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = DayValue("2026-07-20", 65.0),
            band = null, sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.Calibrating, tile.state)
        assertNull(tile.band)
    }

    @Test fun noReadingIsNoDataNotZero() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = null,
            band = band(55.0, 50.0, 60.0, provisional = false),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.NoData, tile.state)
        assertNull("no data is a first-class state, never a fake zero", tile.reading)
        assertNull(tile.asOfDay)
        assertFalse(tile.isStale)
    }

    @Test fun staleReadingKeepsPositionButSuppressesAnnotation() {
        val tile = DeviationEngine.makeTile(
            def = rhrDef(), latest = DayValue("2026-07-17", 65.0),
            band = band(55.0, 50.0, 60.0, provisional = false),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-20",
        )
        assertTrue(tile.isStale)
        assertEquals(VitalState.AboveBand, tile.state)
        assertNull("the 'latest reading' note is suppressed on a stale tile", tile.annotation)
        assertEquals("2026-07-17", tile.asOfDay)
    }

    // MARK: - Temperature is deviation-only by construction

    @Test fun temperatureIsAlwaysDeviationNeverAbsolute() {
        // Even handed a band, a deviation vital gets no band and a Deviation reading.
        val tile = DeviationEngine.makeTile(
            def = tempDef(), latest = DayValue("2026-07-20", 0.3),
            band = band(36.5, 36.0, 37.0, provisional = false),
            sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalReading.Deviation(0.3), tile.reading)
        assertNull("temperature never carries a band, even if one is passed in", tile.band)
        assertEquals(VitalState.Deviation(TempDirection.ABOVE_USUAL), tile.state)
        assertEquals(DeviationEngine.tempAnnotation(TempDirection.ABOVE_USUAL), tile.annotation)
        assertTrue("temperature must never be an absolute reading", tile.reading !is VitalReading.Absolute)
    }

    @Test fun temperatureDirectionFromSign() {
        assertEquals(TempDirection.ABOVE_USUAL, DeviationEngine.tempDirection(0.3))
        assertEquals(TempDirection.BELOW_USUAL, DeviationEngine.tempDirection(-0.2))
        assertEquals(TempDirection.AT_USUAL, DeviationEngine.tempDirection(0.0))

        val atUsual = DeviationEngine.makeTile(
            def = tempDef(), latest = DayValue("2026-07-20", 0.0),
            band = null, sparkline = emptyList(), sourceQuality = null, staleCutoffDay = "2026-07-18",
        )
        assertEquals(VitalState.Deviation(TempDirection.AT_USUAL), atUsual.state)
        assertNull("at the usual level carries no note", atUsual.annotation)
    }

    // MARK: - Sparkline gaps are holes, not zeros

    @Test fun sparklinePreservesGapsAsNull() {
        val points = DeviationEngine.buildSparkline(
            axisDays = listOf("2026-07-18", "2026-07-19", "2026-07-20"),
            byDay = mapOf("2026-07-18" to 50.0, "2026-07-20" to 52.0),
        )
        assertEquals(listOf(50.0, null, 52.0), points.map { it.value })
        assertEquals(listOf("2026-07-18", "2026-07-19", "2026-07-20"), points.map { it.day })
    }

    // MARK: - Per-source sensor quality resolves from the contract

    @Test fun sourceQualityResolvesPerSourceAndFamily() {
        val map = map()
        val watch = Source(id = "src-watch", type = SourceType.HEALTHKIT, displayName = "Apple Watch",
            updatedAt = 0L, originDeviceId = "d")
        val device = Device(id = "dev-1", sourceId = "src-watch", name = "Apple Watch",
            firstSeen = 0L, lastSeen = 0L, updatedAt = 0L, originDeviceId = "d")

        val heart = DeviationEngine.resolveSourceQuality(watch, listOf(device), MetricFamily.HEART, map)
        assertEquals("wrist_wearable", heart?.sourceClassId)
        assertEquals(SensorQualityLevel.HIGH, heart?.level)
        assertEquals("Apple Watch", heart?.sourceDisplayName)

        val body = DeviationEngine.resolveSourceQuality(watch, listOf(device), MetricFamily.BODY, map)
        assertEquals("wrist temperature is a low (inferred) label for this class",
            SensorQualityLevel.LOW, body?.level)

        assertNull("no source to attribute → no label, never a guess",
            DeviationEngine.resolveSourceQuality(null, emptyList(), MetricFamily.HEART, map))
    }

    // MARK: - Copy: the mandatory footer exists and the notes stay wellness-safe

    @Test fun disclaimerIsThePersistentMedicalFooter() {
        assertTrue("the persistent 'not a medical evaluation' footer is mandatory",
            DeviationEngine.disclaimer.en.contains("not a medical evaluation"))
        assertTrue(DeviationEngine.disclaimer.ar.contains("تقييماً طبياً"))
        assertFalse(DeviationEngine.disclaimer.en.isEmpty())
        assertFalse(DeviationEngine.disclaimer.ar.isEmpty())
    }

    /**
     * A concrete copy lint over the authored annotations: they must never carry alarm or diagnosis
     * frames. This is the "assert the copy exists and is linted" acceptance made mechanical, and it is
     * byte-identical to the iOS `testAnnotationsCarryNoAlarmOrDiagnosisFrames`.
     */
    @Test fun annotationsCarryNoAlarmOrDiagnosisFrames() {
        val bannedEn = listOf("you may have", "signs of", "abnormal", "diagnos", "disease",
            "do not", "don't", "stop ", "risk", "warning", "danger", "urgent")
        val bannedAr = listOf("تشخيص", "مرض", "خطر", "توقف", "تحذير", "عاجل")
        val annotations = listOf(
            DeviationEngine.bandAnnotation(Baseline.Position.ABOVE)!!,
            DeviationEngine.bandAnnotation(Baseline.Position.BELOW)!!,
            DeviationEngine.tempAnnotation(TempDirection.ABOVE_USUAL)!!,
            DeviationEngine.tempAnnotation(TempDirection.BELOW_USUAL)!!,
        )
        for (a in annotations) {
            val en = a.en.lowercase()
            for (phrase in bannedEn) {
                assertFalse("annotation \"${a.en}\" contains banned frame \"$phrase\"", en.contains(phrase))
            }
            for (phrase in bannedAr) {
                assertFalse("annotation \"${a.ar}\" contains banned frame \"$phrase\"", a.ar.contains(phrase))
            }
        }
        assertNull(DeviationEngine.bandAnnotation(Baseline.Position.WITHIN))
        assertNull(DeviationEngine.tempAnnotation(TempDirection.AT_USUAL))
    }
}
