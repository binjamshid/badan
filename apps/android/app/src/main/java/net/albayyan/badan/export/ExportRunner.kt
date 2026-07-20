package net.albayyan.badan.export

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.core.Units
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportJob
import net.albayyan.badan.domain.ExportJobStatus
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.ExportJobRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Thrown by [ExportRunner.run] when `scope.includeSensitive` is set without a passphrase meeting
 * [ExportPassphrasePolicy] — the runner's own defense-in-depth so a caller that bypassed the
 * export screen's passphrase fields (a future automation surface, a test, a bug in the UI's
 * disable logic) still cannot produce an unencrypted sensitive export.
 *
 * Mirror of iOS `ExportRunError.sensitiveExportRequiresPassphrase` (ADR-0008). Sealed rather than
 * a bare exception so the export UI can branch on the reason without string-matching a message.
 */
sealed class ExportRunException(message: String) : Exception(message) {
    object SensitiveExportRequiresPassphrase : ExportRunException(
        "a sensitive export requires a passphrase of at least " +
            "${ExportPassphrasePolicy.MINIMUM_LENGTH} characters",
    )
}

/**
 * Runs a fully offline export: gathers scoped records from the repositories, renders them (CSV
 * split into raw/derived files, or one JSON bundle), checksums every file, writes a versioned
 * manifest, and records the completed [ExportJob]. No networking or entitlement imports live on
 * this path (D-8). Mirror of iOS `ExportRunner`.
 */
class ExportRunner(
    private val measurements: MeasurementRepository,
    private val derivation: DerivationRepository,
    private val logging: LoggingRepository,
    private val exportJobs: ExportJobRepository,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val appVersion: String,
    private val deviceId: String,
) {

    /**
     * The artifact produced by a run: the persisted job (with manifest), the written files, and
     * the total exported record count.
     */
    data class ExportResult(
        val job: ExportJob,
        val files: List<File>,
        val rowCount: Int,
    )

    // MARK: - Entry point

    /**
     * [passphrase] is required (and validated against [ExportPassphrasePolicy]) whenever
     * `scope.includeSensitive` is true — a sensitive export can no longer leave this function as
     * plaintext (ADR-0008, EPIC-06). Ignored (and may be omitted) for a non-sensitive scope, which
     * stays exactly the unencrypted behavior it always was.
     */
    suspend fun run(
        scope: ExportScope,
        format: ExportFormat,
        outputDir: File,
        passphrase: String? = null,
    ): ExportResult {
        if (scope.includeSensitive && (passphrase == null || !ExportPassphrasePolicy.isValid(passphrase))) {
            throw ExportRunException.SensitiveExportRequiresPassphrase
        }

        val startedAt = clock.now()
        val exportId = Ulid.newId()
        outputDir.mkdirs()

        // Measurement + derived chain (shared by both formats).
        val ids = metricIdsInScope(scope)

        val rawSamples = mutableListOf<RawSample>()
        val intervalRecords = mutableListOf<IntervalRecord>()
        if (scope.includeRaw) {
            for (id in ids) {
                // A user backing out of the export screen mid-run should actually stop the work
                // (PERF-275) rather than silently finishing in the background.
                coroutineContext.ensureActive()
                if (!metricAllowed(id, scope)) continue
                rawSamples += measurements
                    .rawSamples(id, scope.startDate, scope.endDate, scope.includeSuppressed)
                    .filter { sourceAllowed(it.provenance, scope) }
                intervalRecords += measurements
                    .intervalRecords(id, scope.startDate, scope.endDate, scope.includeSuppressed)
                    .filter { sourceAllowed(it.provenance, scope) }
            }
        }

        val sessions: List<Session> = if (scope.includeRaw) {
            measurements
                .sessions(null, scope.startDate, scope.endDate, scope.includeSuppressed)
                .filter { sessionInScope(it, scope) && sourceAllowed(it.provenance, scope) }
        } else {
            emptyList()
        }

        val derivedValues = mutableListOf<DerivedValue>()
        val baselines = mutableListOf<Baseline>()
        if (scope.includeDerived) {
            for (id in ids) {
                coroutineContext.ensureActive()
                if (!metricAllowed(id, scope)) continue
                derivedValues += derivation.latestDerivedSeries(id).filter { derivedInRange(it, scope) }
                if (registry.definition(id)?.baselineEligible == true) {
                    derivation.latestBaseline(id)?.let { baselines.add(it) }
                }
            }
        }

        val result = when (format) {
            ExportFormat.CSV -> runCsv(
                scope, exportId, outputDir, startedAt,
                rawSamples, intervalRecords, sessions, derivedValues, baselines,
            )
            ExportFormat.JSON -> runJson(
                scope, exportId, outputDir, startedAt,
                rawSamples, intervalRecords, sessions, derivedValues, baselines,
            )
        }

        if (!scope.includeSensitive || passphrase == null) return result
        return try {
            encryptResult(result, exportId, outputDir, scope, format, startedAt, passphrase)
        } catch (e: Throwable) {
            // A sensitive export must never survive half-encrypted: the plaintext files are on
            // disk at this point, so a failure between here and the container write would leave
            // exactly the artifact ADR-0008 exists to remove. Recorded as a failed job for the
            // same reason iOS does — export history should show the attempt, not a gap.
            //
            // Deletes the files this run produced rather than the folder, which is where this
            // diverges from iOS on purpose: the iOS runner creates its own temp folder and so owns
            // it outright, whereas `outputDir` here is supplied by the caller. A `deleteRecursively`
            // on a directory we did not create is a footgun aimed at whoever eventually passes a
            // shared path. The empty folder left behind is swept by the export screen's own prune.
            for (file in result.files) file.delete()
            File(outputDir, ExportEncryptor.CONTAINER_FILE_NAME).delete()
            runCatching {
                exportJobs.insert(
                    ExportJob(
                        id = exportId, scope = scope, format = format, status = ExportJobStatus.FAILED,
                        outputPath = outputDir.path, startedAt = startedAt,
                        finishedAt = clock.now(), createdAt = startedAt,
                    ),
                )
            }
            throw e
        }
    }

    // MARK: - Encryption (includeSensitive only)

    /**
     * Wraps every file [runCsv]/[runJson] just wrote into one [ExportEncryptor] container, writes
     * it as [ExportEncryptor.CONTAINER_FILE_NAME] in the same folder, deletes the plaintext
     * originals, and re-persists the job with `manifest.encrypted = true` pointing at the
     * container instead. The manifest's checksums are left exactly as computed — they describe the
     * real plaintext content, which is the thing a user actually wants to verify after decrypting
     * (ADR-0008) — so only `encrypted`/`encryptedContainerName` change.
     *
     * Reading each file back off disk rather than threading the in-memory bytes through the two
     * writers keeps this step decoupled from both (CSV's files stream straight to an
     * `OutputStream` and are never held as one in-memory array, PERF-252/254) at the cost of one
     * extra read pass — acceptable for a step that already pays a ~600k-round KDF.
     *
     * Byte-for-byte the same container iOS's `encryptResult` produces; that equivalence is what
     * the fixtures under `packages/fixtures/encryption/` assert, in both directions.
     */
    private fun encryptResult(
        result: ExportResult,
        exportId: String,
        folder: File,
        scope: ExportScope,
        format: ExportFormat,
        startedAt: Long,
        passphrase: String,
    ): ExportResult {
        val files = result.files.map { ExportContainerFile(it.name, it.readBytes()) }
        val containerData = ExportEncryptor.encrypt(files, passphrase)
        val containerFile = File(folder, ExportEncryptor.CONTAINER_FILE_NAME)
        containerFile.writeBytes(containerData)

        // The plaintext files have a durable encrypted replacement now, so they have no further
        // reason to sit in the app's cache directory waiting for the next prune.
        for (file in result.files) file.delete()

        val manifest = result.job.manifest?.copy(
            encrypted = true,
            encryptedContainerName = ExportEncryptor.CONTAINER_FILE_NAME,
        )
        val job = ExportJob(
            id = exportId, scope = scope, format = format, status = ExportJobStatus.COMPLETED,
            manifest = manifest, outputPath = folder.path, rowCount = result.rowCount,
            startedAt = startedAt, finishedAt = clock.now(), createdAt = startedAt,
        )
        // Replaces the row runCsv/runJson just inserted for this same export id, so history shows
        // one completed encrypted job rather than a plaintext job shadowed by an encrypted one.
        exportJobs.insert(job)
        return ExportResult(job, listOf(containerFile), result.rowCount)
    }

    // MARK: - CSV

    private fun runCsv(
        scope: ExportScope,
        exportId: String,
        folder: File,
        startedAt: Long,
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sessions: List<Session>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
    ): ExportResult {
        val generatedAt = clock.now()
        val writer = CsvWriter()

        // Route measured rows to raw.csv, engine-computed rows to derived.csv. Per-metric row
        // counts are accumulated in the same pass that builds each row rather than as separate
        // full-list passes afterward (PERF-278).
        val counts = HashMap<String, Int>()
        val rawRows = ArrayList<ExportRow>(rawSamples.size + intervalRecords.size + sessions.size)
        for (s in rawSamples) rawRows += rowForSample(s, scope).also { counts.bump(it.metricId) }
        for (r in intervalRecords) rawRows += rowForInterval(r, scope).also { counts.bump(it.metricId) }
        for (s in sessions) rawRows += rowForSession(s, scope).also { counts.bump(it.metricId) }
        val derivedRows = ArrayList<ExportRow>(derivedValues.size + baselines.size)
        for (v in derivedValues) derivedRows += rowForDerived(v, scope).also { counts.bump(it.metricId) }
        for (b in baselines) derivedRows += rowForBaseline(b, scope).also { counts.bump(it.metricId) }

        // Rows stream directly to each file (rather than being fully rendered into one in-memory
        // string first) with the SHA-256 checksum computed incrementally in the same pass
        // (PERF-252/PERF-254).
        val rawDigest = MessageDigest.getInstance("SHA-256")
        val derivedDigest = MessageDigest.getInstance("SHA-256")
        val rawFile = File(folder, "raw.csv")
        val derivedFile = File(folder, "derived.csv")
        writer.writeTo(rawRows, rawFile.outputStream(), rawDigest)
        writer.writeTo(derivedRows, derivedFile.outputStream(), derivedDigest)

        val checksums = mapOf(
            "raw.csv" to hex(rawDigest.digest()),
            "derived.csv" to hex(derivedDigest.digest()),
        )
        val rowCount = rawRows.size + derivedRows.size

        val manifest = makeManifest(exportId, scope, generatedAt, checksums, counts)
        val manifestFile = File(folder, "manifest.json")
        manifestFile.writeText(JsonCoding.encode(manifest))

        val job = ExportJob(
            id = exportId, scope = scope, format = ExportFormat.CSV, status = ExportJobStatus.COMPLETED,
            manifest = manifest, outputPath = folder.path, rowCount = rowCount,
            startedAt = startedAt, finishedAt = generatedAt, createdAt = startedAt,
        )
        exportJobs.insert(job)
        return ExportResult(job, listOf(rawFile, derivedFile, manifestFile), rowCount)
    }

    // MARK: - JSON

    private fun runJson(
        scope: ExportScope,
        exportId: String,
        folder: File,
        startedAt: Long,
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sessions: List<Session>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
    ): ExportResult {
        val generatedAt = clock.now()

        // Structured logs travel only in the JSON bundle's dedicated logs section. Symptoms and
        // adherence are sensitive-class and additionally gated by includeSensitive.
        val rangeStart = scope.startDate ?: 0L
        val rangeEnd = scope.endDate ?: generatedAt
        val wantRaw = scope.includeRaw
        val symptoms = if (wantRaw && scope.includeSensitive && logFamilyIncluded("symptoms", scope)) {
            logging.symptoms(rangeStart, rangeEnd)
        } else {
            emptyList()
        }
        val adherence = if (wantRaw && scope.includeSensitive && logFamilyIncluded("medications", scope)) {
            logging.adherence(rangeStart, rangeEnd)
        } else {
            emptyList()
        }
        val workouts = if (wantRaw && logFamilyIncluded("activity", scope)) {
            logging.workouts(rangeStart, rangeEnd)
        } else {
            emptyList()
        }
        val nutrition = if (wantRaw && logFamilyIncluded("nutrition", scope)) {
            logging.nutrition(rangeStart, rangeEnd)
        } else {
            emptyList()
        }

        // Per-metric row counts accumulate in a single pass per collection (a plain `.bump` per
        // element) instead of a `.map { it.metricId }` pass followed by a separate `addCounts`
        // pass over the mapped list (PERF-278).
        val counts = HashMap<String, Int>()
        for (s in rawSamples) counts.bump(s.metricId)
        for (r in intervalRecords) counts.bump(r.metricId)
        for (s in sessions) counts.bump(sessionMetricId(s.kind))
        for (v in derivedValues) counts.bump(v.metricId)
        for (b in baselines) counts.bump(b.metricId)
        for (unused in symptoms) counts.bump("symptoms.entry")
        for (unused in adherence) counts.bump("medications.adherence")
        for (unused in workouts) counts.bump("activity.workout")
        for (unused in nutrition) counts.bump("nutrition.entry")
        val rowCount = rawSamples.size + intervalRecords.size + sessions.size +
            derivedValues.size + baselines.size +
            symptoms.size + adherence.size + workouts.size + nutrition.size

        // A single self-contained file cannot checksum itself, so the embedded manifest carries no
        // checksums; the file-level SHA is recorded on the persisted job below.
        val embedded = makeManifest(exportId, scope, generatedAt, emptyMap(), counts)
        // Streams the bundle's JSON encoding directly to the file (rather than fully materializing
        // the JSON string and its byte array first) with the SHA-256 checksum computed
        // incrementally in the same pass (PERF-253/PERF-254).
        val bundleDigest = MessageDigest.getInstance("SHA-256")
        val bundleFile = File(folder, "bundle.json")
        JsonBundleWriter().writeTo(
            manifest = embedded, rawSamples = rawSamples, intervalRecords = intervalRecords,
            sessions = sessions, derivedValues = derivedValues, baselines = baselines,
            symptoms = symptoms, adherence = adherence, workouts = workouts, nutrition = nutrition,
            outputStream = bundleFile.outputStream(), digest = bundleDigest,
        )

        val checksums = mapOf("bundle.json" to hex(bundleDigest.digest()))
        val persisted = makeManifest(exportId, scope, generatedAt, checksums, counts)
        val job = ExportJob(
            id = exportId, scope = scope, format = ExportFormat.JSON, status = ExportJobStatus.COMPLETED,
            manifest = persisted, outputPath = folder.path, rowCount = rowCount,
            startedAt = startedAt, finishedAt = generatedAt, createdAt = startedAt,
        )
        exportJobs.insert(job)
        return ExportResult(job, listOf(bundleFile), rowCount)
    }

    // MARK: - Manifest

    private fun makeManifest(
        exportId: String,
        scope: ExportScope,
        generatedAt: Long,
        checksums: Map<String, String>,
        perMetricRowCounts: Map<String, Int>,
    ): ExportManifest = ExportManifest(
        exportId = exportId,
        schemaVersion = "0.1.0",
        appVersion = appVersion,
        platform = "Android",
        generatedAt = generatedAt,
        scope = scope,
        dateRange = dateRangeString(scope),
        displayLanguage = scope.language.code,
        unitProfile = scope.unitProfile.code,
        timezonePolicy = "timestamps carry original offsets; day boundaries computed in tz-at-measurement",
        dedupPolicy = dedupPolicyNote(scope),
        perMetricRowCounts = perMetricRowCounts,
        checksums = checksums,
        dataQualityNote = DATA_QUALITY_NOTE,
    )

    private fun dedupPolicyNote(scope: ExportScope): String {
        val inclusion = if (scope.includeSuppressed) {
            "included (each keeps suppressed_by = winning record_id)"
        } else {
            "excluded"
        }
        return "suppress-not-delete; identity (metric_id, external_id, source_id), latest-wins; " +
            "suppressed duplicates $inclusion."
    }

    private fun dateRangeString(scope: ExportScope): String {
        val start = scope.startDate
        val end = scope.endDate
        if (start == null && end == null) return "all"
        val lower = start?.let { CsvWriter.iso8601(it, "UTC") } ?: ".."
        val upper = end?.let { CsvWriter.iso8601(it, "UTC") } ?: ".."
        return "$lower/$upper"
    }

    // MARK: - Row builders

    private fun rowForSample(s: RawSample, scope: ExportScope): ExportRow {
        val (value, unit) = displayValueUnit(s.metricId, s.value, s.unit, scope)
        return ExportRow(
            recordId = s.id,
            recordKind = RecordKind.SAMPLE,
            metricId = s.metricId,
            metricDisplay = metricDisplay(s.metricId, scope),
            value = CsvWriter.decimal(value),
            unit = unit,
            canonicalValue = CsvWriter.decimal(s.value),
            canonicalUnit = s.unit,
            valueType = ValueType.RAW,
            isDerived = false,
            timestampStart = CsvWriter.iso8601(s.startAt, s.tzId),
            timestampEnd = s.endAt?.let { CsvWriter.iso8601(it, s.tzId) },
            timezone = s.tzId,
            recordedAt = CsvWriter.iso8601(s.provenance.recordedAt, s.tzId),
            sourceApp = s.provenance.sourceId,
            sourceDevice = s.provenance.deviceId,
            ingestionPath = s.provenance.ingestionPath.code,
            sourceExternalId = s.provenance.externalId,
            importBatchId = s.provenance.importBatchId,
            qualityFlags = qualityFlagsString(s.provenance.qualityFlags),
            suppressedBy = s.provenance.suppressedBy,
        )
    }

    private fun rowForInterval(r: IntervalRecord, scope: ExportScope): ExportRow {
        val (value, unit) = displayValueUnit(r.metricId, r.value, r.unit, scope)
        return ExportRow(
            recordId = r.id,
            recordKind = RecordKind.INTERVAL,
            metricId = r.metricId,
            metricDisplay = metricDisplay(r.metricId, scope),
            value = CsvWriter.decimal(value),
            unit = unit,
            canonicalValue = CsvWriter.decimal(r.value),
            canonicalUnit = r.unit,
            valueType = ValueType.AGGREGATE,
            isDerived = false,
            timestampStart = CsvWriter.iso8601(r.startAt, r.tzId),
            timestampEnd = CsvWriter.iso8601(r.endAt, r.tzId),
            timezone = r.tzId,
            recordedAt = CsvWriter.iso8601(r.provenance.recordedAt, r.tzId),
            sourceApp = r.provenance.sourceId,
            sourceDevice = r.provenance.deviceId,
            ingestionPath = r.provenance.ingestionPath.code,
            sourceExternalId = r.provenance.externalId,
            importBatchId = r.provenance.importBatchId,
            qualityFlags = qualityFlagsString(r.provenance.qualityFlags),
            suppressedBy = r.provenance.suppressedBy,
        )
    }

    private fun rowForSession(s: Session, scope: ExportScope): ExportRow {
        val metricId = sessionMetricId(s.kind)
        return ExportRow(
            recordId = s.id,
            recordKind = RecordKind.SESSION,
            metricId = metricId,
            metricDisplay = sessionDisplay(s.kind, scope.language),
            value = CsvWriter.decimal(s.durationSeconds),
            unit = "s",
            canonicalValue = CsvWriter.decimal(s.durationSeconds),
            canonicalUnit = "s",
            valueType = ValueType.RAW,
            isDerived = false,
            timestampStart = CsvWriter.iso8601(s.startAt, s.tzId),
            timestampEnd = CsvWriter.iso8601(s.endAt, s.tzId),
            timezone = s.tzId,
            recordedAt = CsvWriter.iso8601(s.provenance.recordedAt, s.tzId),
            sourceApp = s.provenance.sourceId,
            sourceDevice = s.provenance.deviceId,
            ingestionPath = s.provenance.ingestionPath.code,
            sourceExternalId = s.provenance.externalId,
            importBatchId = s.provenance.importBatchId,
            qualityFlags = qualityFlagsString(s.provenance.qualityFlags),
            suppressedBy = s.provenance.suppressedBy,
        )
    }

    private fun rowForDerived(v: DerivedValue, scope: ExportScope): ExportRow {
        val (value, unit) = displayValueUnit(v.metricId, v.value, v.unit, scope)
        val start = periodStartDate(v.periodKey) ?: v.computedAt
        return ExportRow(
            recordId = v.id,
            recordKind = RecordKind.DERIVED,
            metricId = v.metricId,
            metricDisplay = metricDisplay(v.metricId, scope),
            value = CsvWriter.decimal(value),
            unit = unit,
            canonicalValue = CsvWriter.decimal(v.value),
            canonicalUnit = v.unit,
            valueType = ValueType.DERIVED,
            isDerived = true,
            timestampStart = CsvWriter.iso8601(start, "UTC"),
            timezone = "UTC",
            recordedAt = CsvWriter.iso8601(v.updatedAt, "UTC"),
            sourceDevice = v.originDeviceId,
            ingestionPath = IngestionPath.DERIVED.code,
            qualityFlags = if (v.provisional) QualityFlag.ESTIMATE.code else null,
            confidence = v.confidence?.let { CsvWriter.decimal(it) },
            algorithmId = v.algorithmId,
            algorithmVersion = v.algorithmVersion,
        )
    }

    private fun rowForBaseline(b: Baseline, scope: ExportScope): ExportRow {
        val (value, unit) = displayValueUnit(b.metricId, b.center, b.unit, scope)
        return ExportRow(
            recordId = b.id,
            recordKind = RecordKind.BASELINE,
            metricId = b.metricId,
            metricDisplay = metricDisplay(b.metricId, scope),
            value = CsvWriter.decimal(value),
            unit = unit,
            canonicalValue = CsvWriter.decimal(b.center),
            canonicalUnit = b.unit,
            valueType = ValueType.DERIVED,
            isDerived = true,
            timestampStart = CsvWriter.iso8601(b.validFrom, "UTC"),
            timezone = "UTC",
            recordedAt = CsvWriter.iso8601(b.computedAt, "UTC"),
            ingestionPath = IngestionPath.DERIVED.code,
            qualityFlags = if (b.provisional) QualityFlag.PROVISIONAL_BASELINE.code else null,
            algorithmId = "baseline.${b.method.code}",
            algorithmVersion = b.algorithmVersion,
        )
    }

    // MARK: - Unit profile & display

    /**
     * The (value, unit) for the display columns. Canonical unless the scope asks for the display
     * profile, in which case the metric's primary display unit is used; canonical columns are
     * unaffected. Unknown/incompatible units fall back to canonical rather than fail the export.
     */
    private fun displayValueUnit(
        metricId: String,
        canonicalValue: Double,
        canonicalUnit: String,
        scope: ExportScope,
    ): Pair<Double, String> {
        if (scope.unitProfile != UnitProfileMode.DISPLAY) return Pair(canonicalValue, canonicalUnit)
        val target = registry.definitionOrFallback(metricId).primaryDisplayUnit
        if (target.isEmpty() || target == canonicalUnit) return Pair(canonicalValue, canonicalUnit)
        val converted = runCatching { Units.convert(canonicalValue, canonicalUnit, target) }.getOrNull()
            ?: return Pair(canonicalValue, canonicalUnit)
        return Pair(converted, target)
    }

    private fun metricDisplay(metricId: String, scope: ExportScope): String =
        registry.definitionOrFallback(metricId).displayName.resolved(scope.language)

    private fun qualityFlagsString(flags: List<QualityFlag>): String? =
        if (flags.isEmpty()) null else flags.joinToString(";") { it.code }

    // MARK: - Scope helpers

    /** The metric ids to query, honoring an explicit metric picklist and/or a family filter. */
    private fun metricIdsInScope(scope: ExportScope): List<String> {
        val picked = scope.metricIds
        if (picked != null && picked.isNotEmpty()) {
            val families = scope.families
            if (families == null || families.isEmpty()) return picked
            val familySet = families.toSet()
            return picked.filter { id -> registry.definition(id)?.let { familySet.contains(it.family) } ?: true }
        }
        var defs = registry.all
        val families = scope.families
        if (families != null && families.isNotEmpty()) {
            val familySet = families.toSet()
            defs = defs.filter { familySet.contains(it.family) }
        }
        return defs.map { it.metricId }
    }

    /** Sensitive-class metrics are only gathered when the scope opts into sensitive data. */
    private fun metricAllowed(metricId: String, scope: ExportScope): Boolean {
        if (scope.includeSensitive) return true
        return registry.definition(metricId)?.sensitiveClass != SensitiveClass.SENSITIVE_PLUS
    }

    private fun sourceAllowed(provenance: Provenance, scope: ExportScope): Boolean {
        val sources = scope.sourceIds
        if (sources == null || sources.isEmpty()) return true
        return sources.contains(provenance.sourceId)
    }

    private fun sessionInScope(session: Session, scope: ExportScope): Boolean {
        val metricId = sessionMetricId(session.kind)
        val picked = scope.metricIds
        if (picked != null && picked.isNotEmpty() && !picked.contains(metricId)) return false
        val families = scope.families
        if (families != null && families.isNotEmpty()) {
            val family = metricId.split(".").firstOrNull() ?: "other"
            if (!families.contains(family)) return false
        }
        return true
    }

    /**
     * A narrowed metric picklist excludes logs entirely; a family filter includes a log category
     * only when its family is selected; an unnarrowed scope includes all logs.
     */
    private fun logFamilyIncluded(family: String, scope: ExportScope): Boolean {
        val picked = scope.metricIds
        if (picked != null && picked.isNotEmpty()) return false
        val families = scope.families
        if (families != null && families.isNotEmpty()) return families.contains(family)
        return true
    }

    /**
     * Best-effort period date filter: applies the scope range only when a day-keyed period can be
     * parsed; otherwise the value is included (its period is not a simple calendar day).
     */
    private fun derivedInRange(v: DerivedValue, scope: ExportScope): Boolean {
        if (scope.startDate == null && scope.endDate == null) return true
        val day = periodStartDate(v.periodKey) ?: return true
        val start = scope.startDate
        if (start != null && day < start) return false
        val end = scope.endDate
        if (end != null && day > end) return false
        return true
    }

    // MARK: - Synthetic ids & period parsing

    private fun sessionMetricId(kind: SessionKind): String = when (kind) {
        SessionKind.SLEEP_PRIMARY, SessionKind.SLEEP_NAP -> "sleep.session"
        SessionKind.WORKOUT -> "activity.workout_session"
    }

    private fun sessionDisplay(kind: SessionKind, language: AppLanguage): String = when (kind) {
        SessionKind.SLEEP_PRIMARY -> if (language == AppLanguage.AR) "نوم" else "Sleep"
        SessionKind.SLEEP_NAP -> if (language == AppLanguage.AR) "قيلولة" else "Nap"
        SessionKind.WORKOUT -> if (language == AppLanguage.AR) "تمرين" else "Workout"
    }

    /**
     * Parses the calendar day from a `day:YYYY-MM-DD` period key (UTC midnight, epoch-millis).
     * Other period shapes (session:, week:) return null and are treated as always-in-range.
     */
    private fun periodStartDate(periodKey: String): Long? {
        if (!periodKey.startsWith("day:")) return null
        val day = periodKey.removePrefix("day:")
        val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
            isLenient = false
        }
        return runCatching { formatter.parse(day)?.time }.getOrNull()
    }

    // MARK: - Counting & checksums

    /** Increments this metric id's row count by one (PERF-278: one pass, no intermediate list). */
    private fun MutableMap<String, Int>.bump(metricId: String) {
        this[metricId] = (this[metricId] ?: 0) + 1
    }

    /** Hex-encodes an already-finalized digest (streamed writers compute it incrementally). */
    private fun hex(digestBytes: ByteArray): String =
        buildString { for (b in digestBytes) append("%02x".format(b.toInt() and 0xFF)) }

    companion object {
        private const val DATA_QUALITY_NOTE =
            "Rows reflect stored records only; coverage gaps are not backfilled. Interval aggregates " +
                "carry a 0–1 coverage fraction in the JSON bundle. Derived values and baselines are " +
                "engine-computed, physically separated from raw, and each carries its algorithm id and version."
    }
}
