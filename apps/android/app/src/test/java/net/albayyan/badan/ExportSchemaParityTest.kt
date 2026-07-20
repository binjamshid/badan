package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.BaselineMethod
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionDetail
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SkipReason
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.domain.WorkoutDetail
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.domain.WorkoutTotals
import net.albayyan.badan.export.CsvWriter
import net.albayyan.badan.export.ExportRow
import net.albayyan.badan.export.ExportSchema
import net.albayyan.badan.export.JsonBundleWriter
import net.albayyan.badan.export.RecordKind
import net.albayyan.badan.export.ValueType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The Android half of the cross-platform export-schema fixture (Phase-1 exit criterion: "the same
 * store and scope produce byte-identical output on both platforms").
 *
 * What this pins is the *serialization contract* at export schema 1.0.0: given one frozen set of
 * records, what exact bytes does BADAN write? That is the layer where the two platforms diverge
 * silently and expensively — `JSONEncoder` sorts keys while kotlinx emits them in declaration
 * order, Swift prints an integral `Double` as `512` and Kotlin as `512.0`, one platform escapes a
 * zero UTC offset as `Z` and the other as `+00:00` — and none of it is visible from inside one
 * platform, because each file parses perfectly well on the machine that wrote it.
 *
 * The golden artifacts are `packages/fixtures/export/bundle-v1.json`, `raw-v1.csv` and
 * `derived-v1.csv`, read from the repo. The iOS half is
 * `apps/ios/Tests/ExportSchemaParityTests.swift`, which reads the SAME files, builds the SAME
 * records from `export-input-v1.json`, and must produce the same bytes through its own writers.
 * Neither test is sufficient alone: a shared misunderstanding still round-trips within one
 * platform, which is exactly how a format divergence survives a green suite on both sides.
 *
 * Fixtures are read from disk rather than copied into either platform's test sources: a copy is
 * one more thing that can drift from the artifact it is supposed to police (same reasoning as
 * `ExportEncryptorTest` and `HealthConnectCanonicalParityTest`).
 *
 * ## Regenerating (rare — read `packages/fixtures/export/README.md` first)
 *
 * `BADAN_REGENERATE_EXPORT_GOLDENS=true ./gradlew :app:testDebugUnitTest` rewrites the three
 * golden files from THIS platform's output and fails the run so the rewrite can never be mistaken
 * for a pass. A regenerated golden is not a verified golden: iOS must then be run against it
 * unchanged. Regenerating to make a failure go away converts a real cross-platform disagreement
 * into a silent one-platform contract, which is the whole failure this fixture exists to prevent.
 */
class ExportSchemaParityTest {

    // Unit tests run with the module dir (`apps/android/app`) as the working directory.
    private val fixtureDir = File("../../../packages/fixtures/export")
    // An environment variable, not a system property: Gradle's Test task does not forward the
    // build JVM's `-D` flags to the forked test JVM, so a `-Dbadan...=true` invocation would run
    // as a normal comparison and report a confusing pass/fail rather than regenerating anything.
    private val regenerating = System.getenv("BADAN_REGENERATE_EXPORT_GOLDENS") == "true"

    // ===== The acceptance criterion =====

    /**
     * The JSON bundle, byte for byte.
     *
     * Compared as raw bytes rather than as parsed JSON on purpose. A parsed comparison passes
     * when key order, number spelling and escaping all differ — which is precisely the set of
     * things schema 1.0.0 promises are identical, and precisely what a downstream consumer
     * checksumming the file cares about. `manifest.checksums` exists because BADAN tells people
     * these files are verifiable; two platforms producing different bytes for the same data would
     * make that promise vacuous.
     */
    @Test fun jsonBundleMatchesTheSharedGoldenByte() {
        val input = fixture()
        val produced = JsonBundleWriter().data(
            manifest = manifest(input),
            rawSamples = rawSamples(input),
            intervalRecords = intervalRecords(input),
            sessions = sessions(input),
            derivedValues = derivedValues(input),
            baselines = baselines(input),
            symptoms = symptoms(input),
            adherence = adherence(input),
            workouts = workoutLogs(input),
            nutrition = nutrition(input),
            // Routes stay off: `route_ref` must be absent from a golden that represents a normal
            // export, so a regression that starts leaking route references fails here loudly.
            includeRoutes = false,
            sampleDataRowCount = input.jsonObject.getValue("bundleManifest")
                .jsonObject.getValue("sampleDataRowCount").jsonPrimitive.int,
        ).toString(Charsets.UTF_8)

        assertGolden("bundle-v1.json", produced)
    }

    /**
     * The two CSV files, byte for byte, including the CRLF line endings and the trailing newline.
     *
     * Raw and derived rows are written to SEPARATE files (I5) — the split is asserted here rather
     * than assumed, because "raw and derived never share a file" is a product guarantee, not an
     * implementation detail, and a writer change that merged them would otherwise only show up as
     * a row count nobody checks.
     */
    @Test fun csvFilesMatchTheSharedGoldensByte() {
        val rows = csvRows(fixture())
        val writer = CsvWriter()
        assertGolden("raw-v1.csv", writer.render(rows.filter { !it.isDerived }))
        assertGolden("derived-v1.csv", writer.render(rows.filter { it.isDerived }))
    }

    /** Raw and derived rows never share a file, and every row says which it is. */
    @Test fun rawAndDerivedNeverShareAFile() {
        val raw = File(fixtureDir, "raw-v1.csv").readText()
        val derived = File(fixtureDir, "derived-v1.csv").readText()
        assertTrue("raw-v1.csv must not contain a derived row", !raw.contains(",derived,true,"))
        assertTrue("derived-v1.csv must not contain a raw row", !derived.contains(",raw,false,"))
        for (text in listOf(raw, derived)) {
            val header = text.substringBefore(CsvWriter.NEWLINE).split(",")
            assertTrue("value_type must be present in every file", header.contains("value_type"))
            assertTrue("is_derived must be present in every file", header.contains("is_derived"))
        }
    }

    // ===== The primitives the goldens are built out of =====

    /**
     * Number formatting, pinned case by case.
     *
     * This is the single highest-value assertion in the file. Every number in every CSV cell and
     * every JSON value goes through `CsvWriter.decimal`, so one disagreement here diverges an
     * entire export — and the disagreements are not hypothetical: before EPIC-08 this function
     * fell back to `Double.toString()`, which renders 1e-9 as `1.0E-9` where iOS renders `0`.
     */
    @Test fun decimalFormattingMatchesTheSharedCases() {
        for (case in fixture().jsonObject.getValue("decimalCases").jsonArray) {
            val obj = case.jsonObject
            val id = obj.getValue("id").jsonPrimitive.content
            val value = obj.getValue("value").jsonPrimitive.content.toDouble()
            assertEquals(id, obj.getValue("expected").jsonPrimitive.content, CsvWriter.decimal(value))
        }
    }

    /**
     * Timestamp rendering, pinned case by case — including the zero-offset case, which is the one
     * that changed at 1.0.0 (`Z` -> `+00:00`, §22.1 "numeric offset") and the one an unknown tz id
     * falls back to.
     */
    @Test fun timestampFormattingMatchesTheSharedCases() {
        for (case in fixture().jsonObject.getValue("timestampCases").jsonArray) {
            val obj = case.jsonObject
            val id = obj.getValue("id").jsonPrimitive.content
            val millis = obj.getValue("epochMillis").jsonPrimitive.content.toLong()
            val tz = obj.getValue("tzId").jsonPrimitive.content
            assertEquals(id, obj.getValue("expected").jsonPrimitive.content, CsvWriter.iso8601(millis, tz))
        }
    }

    /** The 26 columns, in contract order, with the two 1.0.0 additions last (A1). */
    @Test fun csvColumnsAreTheContractOrder() {
        val contract = Json.parseToJsonElement(File("../../../packages/export-schemas/csv_columns.json").readText())
            .jsonObject
        assertEquals("1.0.0", contract.getValue("version").jsonPrimitive.content)
        assertEquals(ExportSchema.VERSION, contract.getValue("version").jsonPrimitive.content)
        val expected = contract.getValue("csvColumns").jsonArray.map { it.jsonObject.getValue("name").jsonPrimitive.content }
        assertEquals(expected, CsvWriter.columns)
        assertEquals(26, CsvWriter.columns.size)
        assertEquals(listOf("granularity", "aggregation_method"), CsvWriter.columns.takeLast(2))
    }

    /**
     * The divergences the fixture declares must still describe THIS platform. Stated as a test so
     * a known gap cannot quietly become a stale note — whoever closes one gets a failure here
     * telling them to delete the entry.
     *
     * `energyKj` is referenced by name below rather than described in a comment: if someone
     * renames the field to `energyKcal` to close the divergence, this file stops compiling, which
     * is the loudest possible reminder that the entry and the golden both need updating.
     */
    @Test fun declaredDivergencesStillDescribeThisPlatform() {
        val ids = fixture().jsonObject.getValue("knownDivergences").jsonArray
            .map { it.jsonObject.getValue("id").jsonPrimitive.content }
        assertTrue(
            "the fixture must declare the workout energy-unit divergence while WorkoutTotals stores kJ",
            ids.contains("workout-totals-energy-unit"),
        )
        assertEquals("this platform stores workout energy in kilojoules", 2000.0, WorkoutTotals(energyKj = 2000.0).energyKj)
        assertTrue(ids.contains("workout-hr-series-ref"))
        assertTrue(ids.contains("manifest-sample-data-row-count"))
    }

    // ===== Fixture loading =====

    /**
     * Reads a shared fixture and checks its SHA-256 against the manifest before parsing.
     *
     * A missing file or a bad digest FAILS here; it never skips. Without the digest check, a
     * fixture mangled in transit (a text-mode checkout, a bad merge, a well-meaning reformat)
     * surfaces as a byte mismatch in the goldens — technically true, and exactly the wrong thing
     * to hand someone debugging a cross-platform disagreement.
     */
    private fun readVerified(fileName: String): ByteArray {
        val manifestFile = File(fixtureDir, "manifest.json")
        assertTrue("missing ${manifestFile.path} — see packages/fixtures/export/README.md", manifestFile.isFile)
        val entry = Json.parseToJsonElement(manifestFile.readText()).jsonObject
            .getValue("files").jsonArray
            .map { it.jsonObject }
            .firstOrNull { it.getValue("file").jsonPrimitive.content == fileName }
        requireNotNull(entry) { "fixture manifest has no entry for '$fileName'" }

        val file = File(fixtureDir, fileName)
        assertTrue("missing fixture at ${file.path}", file.isFile)
        val bytes = file.readBytes()
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        assertEquals(
            "fixture '$fileName' does not match the SHA-256 in manifest.json — the shared artifact " +
                "changed underneath this test. Do NOT run scripts/check_fixture_hashes.sh --update to " +
                "make this pass unless you meant to change the fixture.",
            entry.getValue("sha256").jsonPrimitive.content,
            digest,
        )
        return bytes
    }

    private fun fixture(): JsonObject =
        Json.parseToJsonElement(readVerified("export-input-v1.json").toString(Charsets.UTF_8)).jsonObject

    /**
     * A run with the regeneration switch on is ALWAYS red, whatever the goldens ended up
     * containing.
     *
     * A switch that rewrote the fixtures and then reported success would let a broken run end
     * green, and nobody afterwards could tell a verified artifact from one that was overwritten by
     * whatever the code happened to emit that afternoon. This is a separate test rather than a
     * `fail()` inside [assertGolden] so that every golden gets written in one pass — failing at the
     * first one would rewrite `raw-v1.csv` and leave `derived-v1.csv` stale, which is worse than
     * not regenerating at all.
     */
    @Test fun regenerationSwitchIsNeverAPass() {
        if (regenerating) {
            org.junit.Assert.fail(
                "goldens were regenerated from THIS platform's output. Run " +
                    "scripts/check_fixture_hashes.sh --update, then run BOTH suites with the switch " +
                    "OFF. A golden verified on one platform is not a parity fixture.",
            )
        }
    }

    /** Byte comparison, or a rewrite when [regenerating]. */
    private fun assertGolden(fileName: String, produced: String) {
        if (regenerating) {
            File(fixtureDir, fileName).writeBytes(produced.toByteArray(Charsets.UTF_8))
            return
        }
        val expected = readVerified(fileName).toString(Charsets.UTF_8)
        assertEquals("$fileName is not byte-identical to what this platform's writer produced", expected, produced)
    }

    // ===== Fixture -> domain =====

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.strOrNull(key: String): String? =
        get(key)?.takeIf { it != JsonNull }?.jsonPrimitive?.content

    // Doubles and epoch-millis arrive as strings and are parsed with `toDouble`/`toLong` — see the
    // fixture README. A bare JSON number would go through each platform's own number handling,
    // which is a difference in the harness rather than in the thing under test.
    private fun JsonObject.dbl(key: String): Double = str(key).toDouble()
    private fun JsonObject.dblOrNull(key: String): Double? = strOrNull(key)?.toDouble()
    private fun JsonObject.millis(key: String): Long = str(key).toLong()
    private fun JsonObject.millisOrNull(key: String): Long? = strOrNull(key)?.toLong()
    private fun JsonObject.rows(key: String): List<JsonObject> = getValue(key).jsonArray.map { it.jsonObject }

    private fun provenance(obj: JsonObject): Provenance = Provenance(
        sourceId = obj.str("sourceId"),
        deviceId = obj.strOrNull("deviceId"),
        ingestionPath = IngestionPath.fromCode(obj.str("ingestionPath")),
        externalId = obj.strOrNull("externalId"),
        importBatchId = obj.strOrNull("importBatchId"),
        measuredAt = obj.millis("measuredAtMillis"),
        measuredTimezone = obj.str("measuredTimezone"),
        recordedAt = obj.millis("recordedAtMillis"),
        ingestedAt = obj.millis("ingestedAtMillis"),
        algorithmVersionId = obj.strOrNull("algorithmVersionId"),
        qualityFlags = obj.getValue("qualityFlags").jsonArray.map { QualityFlag.fromCode(it.jsonPrimitive.content) },
        suppressedBy = obj.strOrNull("suppressedBy"),
    )

    private fun manifest(input: JsonObject): ExportManifest {
        val m = input.getValue("bundleManifest").jsonObject
        val s = m.getValue("scope").jsonObject
        return ExportManifest(
            exportId = m.str("exportId"),
            // Deliberately the OLD version: the bundle's own `export_schema_version` must come
            // from the writer's constant, not from whatever a stored manifest happens to carry.
            // If the writer ever starts echoing this field instead, the golden breaks here.
            schemaVersion = "0.1.0",
            appVersion = m.str("appVersion"),
            platform = m.str("platform"),
            generatedAt = m.millis("generatedAtMillis"),
            scope = ExportScope(
                metricIds = (s["metricIds"] as? JsonArray)?.map { it.jsonPrimitive.content },
                families = (s["families"] as? JsonArray)?.map { it.jsonPrimitive.content },
                startDate = s.millisOrNull("startDateMillis"),
                endDate = s.millisOrNull("endDateMillis"),
                sourceIds = (s["sourceIds"] as? JsonArray)?.map { it.jsonPrimitive.content },
                includeRaw = s.getValue("includeRaw").jsonPrimitive.boolean,
                includeDerived = s.getValue("includeDerived").jsonPrimitive.boolean,
                includeSuppressed = s.getValue("includeSuppressed").jsonPrimitive.boolean,
                includeSensitive = s.getValue("includeSensitive").jsonPrimitive.boolean,
                unitProfile = UnitProfileMode.fromCode(s.str("unitProfile")),
                language = AppLanguage.entries.first { it.code == s.str("language") },
            ),
            dateRange = m.str("dateRange"),
            displayLanguage = m.str("displayLanguage"),
            unitProfile = m.str("unitProfile"),
            timezonePolicy = m.str("timezonePolicy"),
            dedupPolicy = m.str("dedupPolicy"),
            perMetricRowCounts = m.getValue("perMetricRowCounts").jsonObject.mapValues { it.value.jsonPrimitive.int },
            checksums = m.getValue("checksums").jsonObject.mapValues { it.value.jsonPrimitive.content },
            dataQualityNote = m.str("dataQualityNote"),
            encrypted = m.getValue("encrypted").jsonPrimitive.boolean,
        )
    }

    private fun rawSamples(input: JsonObject): List<RawSample> = input.rows("rawSamples").map {
        RawSample(
            id = it.str("id"), metricId = it.str("metricId"),
            value = it.dbl("value"), unit = it.str("unit"),
            originalValue = it.dbl("originalValue"), originalUnit = it.str("originalUnit"),
            startAt = it.millis("startAtMillis"), endAt = it.millisOrNull("endAtMillis"),
            tzId = it.str("tzId"), provenance = provenance(it.getValue("provenance").jsonObject),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun intervalRecords(input: JsonObject): List<IntervalRecord> = input.rows("intervalRecords").map {
        IntervalRecord(
            id = it.str("id"), metricId = it.str("metricId"),
            value = it.dbl("value"), unit = it.str("unit"),
            startAt = it.millis("startAtMillis"), endAt = it.millis("endAtMillis"),
            tzId = it.str("tzId"), aggregation = Aggregation.fromCode(it.str("aggregation")),
            coverage = it.dbl("coverage"), provenance = provenance(it.getValue("provenance").jsonObject),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun sessions(input: JsonObject): List<Session> = input.rows("sessions").map {
        val d = it.getValue("detail").jsonObject
        val w = d["workout"]?.jsonObject
        Session(
            id = it.str("id"), kind = SessionKind.fromCode(it.str("kind")),
            subtype = it.strOrNull("subtype"),
            startAt = it.millis("startAtMillis"), endAt = it.millis("endAtMillis"),
            tzId = it.str("tzId"), localNight = it.strOrNull("localNight"),
            detail = SessionDetail(
                mergedFrom = d.getValue("mergedFrom").jsonArray.map { m -> m.jsonPrimitive.content },
                timeAsleepSeconds = d.dblOrNull("timeAsleepSeconds"),
                timeInBedSeconds = d.dblOrNull("timeInBedSeconds"),
                stageSummarySeconds = d.getValue("stageSummarySeconds").jsonObject
                    .mapValues { s -> s.value.jsonPrimitive.content.toDouble() },
                workout = w?.let { detail ->
                    val t = detail.getValue("totals").jsonObject
                    WorkoutDetail(
                        activityType = detail.strOrNull("activityType"),
                        // No energy total: the two platforms store this in different units, which
                        // is a declared divergence the fixture routes around rather than hides.
                        totals = WorkoutTotals(
                            distanceM = t.dblOrNull("distanceM"),
                            avgHrBpm = t.dblOrNull("avgHr"),
                            maxHrBpm = t.dblOrNull("maxHr"),
                            elevationGainM = t.dblOrNull("elevationGainM"),
                        ),
                        sourceWorkoutId = detail.strOrNull("sourceWorkoutId"),
                        routeRef = detail.strOrNull("routeRef"),
                    )
                },
            ),
            provenance = provenance(it.getValue("provenance").jsonObject),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun derivedValues(input: JsonObject): List<DerivedValue> = input.rows("derivedValues").map {
        DerivedValue(
            id = it.str("id"), metricId = it.str("metricId"), value = it.dbl("value"),
            unit = it.str("unit"), periodKey = it.str("periodKey"),
            confidence = it.dblOrNull("confidence"),
            provisional = it.getValue("provisional").jsonPrimitive.boolean,
            algorithmId = it.str("algorithmId"), algorithmVersion = it.str("algorithmVersion"),
            inputManifestId = it.strOrNull("inputManifestId"),
            computedAt = it.millis("computedAtMillis"), updatedAt = it.millis("updatedAtMillis"),
            originDeviceId = it.str("originDeviceId"), deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun baselines(input: JsonObject): List<Baseline> = input.rows("baselines").map {
        Baseline(
            id = it.str("id"), metricId = it.str("metricId"),
            covariateContext = it.str("covariateContext"),
            windowDays = it.getValue("windowDays").jsonPrimitive.int,
            method = BaselineMethod.fromCode(it.str("method")),
            center = it.dbl("center"), spread = it.dbl("spread"),
            bandLow = it.dbl("bandLow"), bandHigh = it.dbl("bandHigh"),
            nPoints = it.getValue("nPoints").jsonPrimitive.int,
            provisional = it.getValue("provisional").jsonPrimitive.boolean,
            algorithmVersion = it.str("algorithmVersion"),
            validFrom = it.millis("validFromMillis"), computedAt = it.millis("computedAtMillis"),
            unit = it.str("unit"),
        )
    }

    private fun symptoms(input: JsonObject): List<SymptomEntry> = input.rows("symptoms").map {
        SymptomEntry(
            id = it.str("id"), symptomId = it.strOrNull("symptomId"),
            customLabel = it.strOrNull("customLabel"),
            severity = it.getValue("severity").jsonPrimitive.int,
            occurredAt = it.millis("occurredAtMillis"), tzId = it.str("tzId"),
            durationSeconds = it.dblOrNull("durationSeconds"),
            bodyLocation = it.strOrNull("bodyLocation"),
            triggers = it.getValue("triggers").jsonArray.map { t -> t.jsonPrimitive.content },
            note = it.strOrNull("note"),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun adherence(input: JsonObject): List<AdherenceEvent> = input.rows("adherence").map {
        AdherenceEvent(
            id = it.str("id"), regimenId = it.str("regimenId"),
            kind = AdherenceKind.entries.first { k -> k.code == it.str("kind") },
            scheduledFor = it.millisOrNull("scheduledForMillis"),
            occurredAt = it.millis("occurredAtMillis"), tzId = it.str("tzId"),
            skipReason = it.strOrNull("skipReason")?.let { r -> SkipReason.entries.first { s -> s.code == r } },
            skipNote = it.strOrNull("skipNote"),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun workoutLogs(input: JsonObject): List<WorkoutEntry> = input.rows("workoutLogs").map {
        WorkoutEntry(
            id = it.str("id"), activityType = it.str("activityType"),
            startAt = it.millis("startAtMillis"), endAt = it.millis("endAtMillis"),
            tzId = it.str("tzId"), energyKcal = it.dblOrNull("energyKcal"),
            distanceM = it.dblOrNull("distanceM"), avgHr = it.dblOrNull("avgHr"),
            maxHr = it.dblOrNull("maxHr"),
            perceivedEffort = it.get("perceivedEffort")?.takeIf { p -> p != JsonNull }?.jsonPrimitive?.int,
            note = it.strOrNull("note"),
            ingestionPath = IngestionPath.fromCode(it.str("ingestionPath")),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun nutrition(input: JsonObject): List<NutritionEntry> = input.rows("nutrition").map {
        NutritionEntry(
            id = it.str("id"), description = it.str("description"),
            mealType = MealType.entries.first { m -> m.code == it.str("mealType") },
            energyKcal = it.dblOrNull("energyKcal"), proteinG = it.dblOrNull("proteinG"),
            carbsG = it.dblOrNull("carbsG"), fatG = it.dblOrNull("fatG"),
            fiberG = it.dblOrNull("fiberG"), waterMl = it.dblOrNull("waterMl"),
            caffeineMg = it.dblOrNull("caffeineMg"),
            lowDetail = it.getValue("lowDetail").jsonPrimitive.boolean,
            occurredAt = it.millis("occurredAtMillis"), tzId = it.str("tzId"),
            note = it.strOrNull("note"),
            updatedAt = it.millis("updatedAtMillis"), originDeviceId = it.str("originDeviceId"),
            deletedAt = it.millisOrNull("deletedAtMillis"),
        )
    }

    private fun csvRows(input: JsonObject): List<ExportRow> = input.rows("csvRows").map {
        ExportRow(
            recordId = it.str("recordId"),
            recordKind = RecordKind.entries.first { k -> k.code == it.str("recordKind") },
            metricId = it.str("metricId"), metricDisplay = it.str("metricDisplay"),
            value = it.str("value"), unit = it.str("unit"),
            canonicalValue = it.str("canonicalValue"), canonicalUnit = it.str("canonicalUnit"),
            valueType = ValueType.entries.first { v -> v.code == it.str("valueType") },
            isDerived = it.getValue("isDerived").jsonPrimitive.boolean,
            timestampStart = it.str("timestampStart"), timestampEnd = it.strOrNull("timestampEnd"),
            timezone = it.str("timezone"), recordedAt = it.str("recordedAt"),
            sourceApp = it.strOrNull("sourceApp"), sourceDevice = it.strOrNull("sourceDevice"),
            ingestionPath = it.str("ingestionPath"),
            sourceExternalId = it.strOrNull("sourceExternalId"),
            importBatchId = it.strOrNull("importBatchId"),
            qualityFlags = it.strOrNull("qualityFlags"), confidence = it.strOrNull("confidence"),
            algorithmId = it.strOrNull("algorithmId"), algorithmVersion = it.strOrNull("algorithmVersion"),
            suppressedBy = it.strOrNull("suppressedBy"),
            granularity = it.strOrNull("granularity")
                ?.let { g -> ExportSchema.Granularity.entries.first { e -> e.code == g } },
            aggregationMethod = it.strOrNull("aggregationMethod")
                ?.let { a -> ExportSchema.AggregationMethod.entries.first { e -> e.code == a } },
        )
    }
}
