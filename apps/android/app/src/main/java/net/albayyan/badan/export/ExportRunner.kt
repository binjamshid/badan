package net.albayyan.badan.export

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.core.Units
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.ExportAggregation
import net.albayyan.badan.domain.ExportAggregationMethod
import net.albayyan.badan.domain.ExportBucket
import net.albayyan.badan.domain.ExportCursor
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportErrorDetail
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportJob
import net.albayyan.badan.domain.ExportJobStatus
import net.albayyan.badan.domain.ExportLayout
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportRowCounts
import net.albayyan.badan.domain.ExportRun
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportStage
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.ManifestDigest
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.domain.SensitiveRunConsent
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.export.destinations.ExportArtifact
import net.albayyan.badan.export.destinations.ExportArtifactNaming
import net.albayyan.badan.export.destinations.ExportDeliveryReceipt
import net.albayyan.badan.export.destinations.ExportDeliveryRequest
import net.albayyan.badan.export.destinations.ExportDestinationDelivering
import net.albayyan.badan.export.destinations.DestinationMessages
import net.albayyan.badan.export.destinations.deliveringDetail
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.ExportCursorRepository
import net.albayyan.badan.storage.repositories.ExportDestinationRepository
import net.albayyan.badan.storage.repositories.ExportJobRepository
import net.albayyan.badan.storage.repositories.ExportRunRepository
import net.albayyan.badan.storage.repositories.ExportTemplateRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import net.albayyan.badan.storage.repositories.RouteRepository
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
    // EPIC-09/13/14/17 template-run collaborators. All nullable/defaulted so the existing
    // `ExportRunner(measurements, …, deviceId)` construction — `AppEnvironment` and every Phase-0/1
    // test — compiles and behaves exactly as before. `runTemplate` guards on their presence; the
    // plain `run(scope, format, outputDir)` path never touches them, so a runner built without them
    // keeps producing artifacts and `ExportJob` rows unchanged. Mirror of iOS's optional deps.
    private val templates: ExportTemplateRepository? = null,
    private val destinations: ExportDestinationRepository? = null,
    private val runs: ExportRunRepository? = null,
    private val cursors: ExportCursorRepository? = null,
    private val routes: RouteRepository? = null,
    /**
     * One [ExportDestinationDelivering] per non-local destination kind. `shareSheet` is handled
     * in-process (the artifacts stay in the temp folder for the UI's share sheet) and needs no
     * entry here; a kind with no registered deliverer fails loudly as `failedDelivery` rather than
     * silently writing the user's data nowhere.
     */
    private val deliverers: List<ExportDestinationDelivering> = emptyList(),
) {

    /**
     * The artifact produced by a run: the persisted job (with manifest), the written files, and
     * the total exported record count.
     */
    data class ExportResult(
        val job: ExportJob,
        val files: List<File>,
        val rowCount: Int,
        /**
         * The largest `provenance.ingestedAt` among the raw/interval/session rows this export
         * actually wrote — the cursor watermark a successful `sinceLastRun` delivery advances to
         * (EPIC-17). null when the export contained no ingested measurement rows, so a delta run
         * leaves the cursor untouched rather than inventing a watermark from a non-ingested axis.
         */
        val maxIngestedAt: Long? = null,
        /** Row counts by record class for the `ExportRun` ledger (§9.5) — by class, never metric. */
        val rowCounts: ExportRowCounts? = null,
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
        ingestedSince: Long? = null,
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
                    .filter { sourceAllowed(it.provenance, scope) && ingestedAfter(it.provenance.ingestedAt, ingestedSince) }
                intervalRecords += measurements
                    .intervalRecords(id, scope.startDate, scope.endDate, scope.includeSuppressed)
                    .filter { sourceAllowed(it.provenance, scope) && ingestedAfter(it.provenance.ingestedAt, ingestedSince) }
            }
        }

        val sessions: List<Session> = if (scope.includeRaw) {
            measurements
                .sessions(null, scope.startDate, scope.endDate, scope.includeSuppressed)
                .filter {
                    sessionInScope(it, scope) && sourceAllowed(it.provenance, scope) &&
                        ingestedAfter(it.provenance.ingestedAt, ingestedSince)
                }
        } else {
            emptyList()
        }

        val derivedValues = mutableListOf<DerivedValue>()
        val baselines = mutableListOf<Baseline>()
        if (scope.includeDerived) {
            for (id in ids) {
                coroutineContext.ensureActive()
                if (!metricAllowed(id, scope)) continue
                // A derived value carries no `ingested_at` (computed here, not ingested), so its
                // delta axis is `updatedAt`/`computedAt` — "recomputed since the last run" — never
                // the raw watermark. The cursor only ever advances on the raw ingested axis (see
                // `maxIngestedAt`), so a baseline recomputation cannot drag the watermark forward.
                derivedValues += derivation.latestDerivedSeries(id)
                    .filter { derivedInRange(it, scope) && ingestedAfter(it.updatedAt, ingestedSince) }
                if (registry.definition(id)?.baselineEligible == true) {
                    derivation.latestBaseline(id)?.takeIf { ingestedAfter(it.computedAt, ingestedSince) }
                        ?.let { baselines.add(it) }
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
                rawSamples, intervalRecords, sessions, derivedValues, baselines, ingestedSince,
            )
        }

        // The delta watermark and ledger row counts, over the rows the file actually contains.
        // `maxIngestedAt` is the ingested axis a `sinceLastRun` cursor advances on (raw/interval/
        // session only); logs are derived from the total so the JSON path's log rows are counted.
        val ingestMax = (rawSamples.map { it.provenance.ingestedAt } +
            intervalRecords.map { it.provenance.ingestedAt } +
            sessions.map { it.provenance.ingestedAt }).maxOrNull()
        val suppressedCount = rawSamples.count { it.provenance.isSuppressed } +
            intervalRecords.count { it.provenance.isSuppressed } +
            sessions.count { it.provenance.isSuppressed }
        val chainCount = rawSamples.size + intervalRecords.size + sessions.size +
            derivedValues.size + baselines.size
        val counts = ExportRowCounts(
            measurements = rawSamples.size, intervals = intervalRecords.size, sessions = sessions.size,
            logs = maxOf(0, result.rowCount - chainCount),
            derived = derivedValues.size + baselines.size, suppressed = suppressedCount,
        )

        if (!scope.includeSensitive || passphrase == null) {
            return result.copy(maxIngestedAt = ingestMax, rowCounts = counts)
        }
        return try {
            encryptResult(result, exportId, outputDir, scope, format, startedAt, passphrase)
                .copy(maxIngestedAt = ingestMax, rowCounts = counts)
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
        ingestedSince: Long? = null,
    ): ExportResult {
        val generatedAt = clock.now()

        // Structured logs travel only in the JSON bundle's dedicated logs section. Symptoms and
        // adherence are sensitive-class and additionally gated by includeSensitive. Each is also
        // held to the incremental delta filter (EPIC-17) on its `updatedAt` — the log analog of
        // the ingested axis, since manual log entries carry no `provenance.ingestedAt`.
        val rangeStart = scope.startDate ?: 0L
        val rangeEnd = scope.endDate ?: generatedAt
        val wantRaw = scope.includeRaw
        val symptoms = if (wantRaw && scope.includeSensitive && logFamilyIncluded("symptoms", scope)) {
            logging.symptoms(rangeStart, rangeEnd).filter { ingestedAfter(it.updatedAt, ingestedSince) }
        } else {
            emptyList()
        }
        val adherence = if (wantRaw && scope.includeSensitive && logFamilyIncluded("medications", scope)) {
            logging.adherence(rangeStart, rangeEnd).filter { ingestedAfter(it.updatedAt, ingestedSince) }
        } else {
            emptyList()
        }
        val workouts = if (wantRaw && logFamilyIncluded("activity", scope)) {
            logging.workouts(rangeStart, rangeEnd).filter { ingestedAfter(it.updatedAt, ingestedSince) }
        } else {
            emptyList()
        }
        val nutrition = if (wantRaw && logFamilyIncluded("nutrition", scope)) {
            logging.nutrition(rangeStart, rangeEnd).filter { ingestedAfter(it.updatedAt, ingestedSince) }
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

    private fun sha256Hex(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    // MARK: - EPIC-09/13/14/15/17: template-driven runs, delivery, and the ExportRun ledger
    //
    // Everything below turns a saved `ExportTemplate` into an artifact that has actually been
    // delivered and recorded. It sits ON TOP of `run(scope, format, outputDir, passphrase,
    // ingestedSince)` above — that function is still the one place gather + generation + encryption
    // happen, unchanged for the plain UI export path. This layer adds what a *template* run needs:
    // range/cursor resolution, run-time sensitive re-confirmation, delivery, the `ExportRun` trust
    // ledger, and the incremental cursor. Mirror of iOS `ExportRunner`'s template-run extension.
    //
    // Two disciplines run through all of it and are load-bearing, not stylistic:
    //  1. EVERY attempt writes exactly one `ExportRun` (§9.5), including one refused before a byte
    //     was generated — a run that leaves no ledger row is the HAE failure this exists to prevent.
    //  2. The cursor advances ONLY after a delta run both succeeded AND was delivered, and only to
    //     the max `ingested_at` this run actually wrote (`result.maxIngestedAt`). Same two-phase
    //     commit as Phase 0's HealthKit anchors (DATA-08) / Health Connect change tokens: never
    //     move a watermark past data not durably handed off. Phase 0's audit found Android advancing
    //     a cursor past dropped records — the guard here is what keeps that from recurring.

    /**
     * The outcome of one template run. `run` is ALWAYS present and already persisted (discipline 1).
     */
    data class TemplateRunResult(
        val run: ExportRun,
        val result: ExportResult?,
        val receipt: ExportDeliveryReceipt?,
        /**
         * Set when a `sinceLastRun` template ran with no cursor and fell back to `lastNDays`. The
         * caller MUST surface this — a silent fallback is exactly the HAE failure §12 EPIC-09's
         * input rule forbids. Also recorded machine-readably as `run.errorCode == CURSOR_MISSING`
         * on the (successful) ledger row, so the notice reaches Export Health and a backup.
         */
        val cursorFallbackNotice: Boolean = false,
    )

    /**
     * Run one template end to end: resolve → deliver → record. Never throws — every failure mode is
     * a recorded `ExportRun`, because a thrown error a caller might swallow is the opposite of the
     * trust ledger this returns.
     */
    suspend fun runTemplate(
        template: ExportTemplate,
        trigger: ExportTrigger,
        baseDir: File,
        consent: SensitiveRunConsent? = null,
        passphrase: String? = null,
        timeZone: TimeZone = TimeZone.getDefault(),
        attempt: Int = 0,
    ): TemplateRunResult {
        val startedAt = clock.now()
        val runId = Ulid.newId()
        val runs = this.runs
        val cursors = this.cursors
        val destinations = this.destinations
        if (runs == null || cursors == null || destinations == null) {
            val run = ExportRun(
                id = runId, templateId = template.id, trigger = trigger, startedAt = startedAt,
                finishedAt = clock.now(), outcome = ExportOutcome.FAILED_GENERATION,
                errorCode = ExportErrorCode.UNKNOWN,
                errorDetail = ExportErrorDetail(ExportStage.FINALIZING, attempt = attempt),
            )
            return TemplateRunResult(run, null, null)
        }

        // 1. Destination. A template need not pin one; absent, it is the share sheet (§9.4).
        val destinationId = template.destinationId ?: ExportDestination.SHARE_SHEET_ID
        val destination = destinations.destination(destinationId)
        if (destination == null) {
            // The row was deleted out from under the template. Fail loudly rather than silently
            // redirecting the user's data. No `destinationMissing` code exists; UNREACHABLE is the
            // honest reading — BADAN cannot reach a destination that is not there.
            val run = record(runs, runId, template, trigger, jobId = null, startedAt = startedAt,
                outcome = ExportOutcome.FAILED_GENERATION, errorCode = ExportErrorCode.DESTINATION_UNREACHABLE,
                stage = ExportStage.FINALIZING, attempt = attempt, destinationId = destinationId)
            return TemplateRunResult(run, null, null)
        }

        // 2. Run-time sensitive re-confirmation (§9.3). `scopeForRun` throws rather than silently
        //    narrowing — a quietly de-sensitized export would hand the user a file missing exactly
        //    the records they asked for, with nothing saying so.
        val resolvedScope: ExportScope = try {
            template.scopeForRun(consent, startedAt)
        } catch (e: Throwable) {
            val run = record(runs, runId, template, trigger, jobId = null, startedAt = startedAt,
                outcome = ExportOutcome.FAILED_GENERATION,
                errorCode = ExportErrorCode.SENSITIVE_CONFIRMATION_MISSING, stage = ExportStage.GATHERING,
                attempt = attempt, destinationId = destinationId)
            return TemplateRunResult(run, null, null)
        }

        // 3. Range + cursor. `sinceLastRun` with no cursor falls back to `lastNDays` WITH A NOTICE.
        val cursor = cursors.cursor(template.id, destinationId)
        val plan = resolveRange(template.rangeRule, resolvedScope, cursor, startedAt)

        // 4. Generate. `.raw` templates reuse `run` verbatim; `.bucketed` route through the
        //    aggregation path. A `sinceLastRun` delta passes its ingested watermark (and a date-less
        //    scope) so the delta is taken on the ingested axis, never the measured one.
        val folder = File(baseDir, "badan-export-$runId")
        val result: ExportResult = try {
            when (val agg = template.aggregation) {
                is ExportAggregation.Raw ->
                    run(plan.scope, template.format, folder, passphrase, plan.ingestedSince)
                is ExportAggregation.Bucketed ->
                    runAggregated(plan.scope, template, agg.bucket, agg.method, passphrase,
                        plan.ingestedSince, folder, startedAt)
            }
        } catch (e: ExportRunException.SensitiveExportRequiresPassphrase) {
            val run = record(runs, runId, template, trigger, jobId = null, startedAt = startedAt,
                outcome = ExportOutcome.FAILED_GENERATION, errorCode = ExportErrorCode.PASSPHRASE_MISSING,
                stage = ExportStage.ENCRYPTING, attempt = attempt, destinationId = destinationId,
                cursorBefore = plan.cursorBefore)
            return TemplateRunResult(run, null, null)
        } catch (e: Throwable) {
            val run = record(runs, runId, template, trigger, jobId = null, startedAt = startedAt,
                outcome = ExportOutcome.FAILED_GENERATION, errorCode = ExportErrorCode.WRITE_FAILED,
                stage = ExportStage.WRITING, attempt = attempt, destinationId = destinationId,
                cursorBefore = plan.cursorBefore)
            return TemplateRunResult(run, null, null)
        }

        // 5. Deliver.
        val receipt = deliver(result, template, destination, plan, startedAt, timeZone, attempt)

        if (destination.kind.leavesDevice || receipt.destinationStatus != ExportDestinationStatus.OK) {
            destinations.updateStatus(destinationId, receipt.destinationStatus, clock.now())
        }

        // 6. Ledger + cursor (two-phase commit).
        val manifestSha = result.job.manifest?.let { ManifestDigest.of(sha256Hex(JsonCoding.encode(it).toByteArray())) }
        // A delivered run that carried no rows is "there was nothing to export" (§9.5
        // skippedNoData), not a plain success — so an automation that legitimately had nothing to do
        // is distinguishable in Export Health from one that moved data. Matches
        // `ExportManageService`'s rowCount==0 mapping.
        val effectiveOutcome =
            if (receipt.outcome == ExportOutcome.SUCCESS && result.rowCount == 0) ExportOutcome.SKIPPED_NO_DATA
            else receipt.outcome

        var cursorAfter: Long? = null
        val advanced = effectiveOutcome == ExportOutcome.SUCCESS &&
            template.rangeRule is ExportRangeRule.SinceLastRun &&
            !plan.fellBackFromSinceLastRun
        val ingestMax = result.maxIngestedAt
        if (advanced && ingestMax != null) {
            // TWO-PHASE COMMIT (the DATA-08 parallel): the watermark moves only now, after a
            // delivery that fully succeeded, and only to a value computed over the rows the file
            // actually contains. `advance` is itself forward-only, so an out-of-order retry
            // reporting an older watermark is refused, not obeyed.
            cursors.advance(template.id, destinationId, ingestMax, runId, manifestSha, clock.now())
            cursorAfter = ingestMax
        }

        // A `sinceLastRun` fallback rides a SUCCESS row as CURSOR_MISSING — a note, not a failure
        // (`ExportOutcome.isFailure` excludes it) — so the notice is durable, not just returned.
        val noticeCode = if (plan.fellBackFromSinceLastRun) ExportErrorCode.CURSOR_MISSING else receipt.errorCode
        val run = ExportRun(
            id = runId, templateId = template.id, jobId = result.job.id, trigger = trigger,
            startedAt = startedAt, finishedAt = clock.now(), outcome = effectiveOutcome,
            errorCode = noticeCode, errorDetail = receipt.errorDetail,
            bytesWritten = receipt.bytesDelivered, rowCounts = result.rowCounts,
            destinationId = destinationId, deliveredAt = receipt.deliveredAt,
            cursorBefore = plan.cursorBefore, cursorAfter = cursorAfter, manifestSha256 = manifestSha,
        )
        runs.insert(run)
        return TemplateRunResult(run, result, receipt, plan.fellBackFromSinceLastRun)
    }

    /**
     * The concrete window one run uses, plus the delta filter and cursor bookkeeping. `internal`
     * (with [resolveRange] and [ingestedAfter] in the companion) so the delta/fallback decision —
     * the safety-critical half of EPIC-17 — is unit-testable without a database, which this module's
     * JVM test source set cannot open. The DB-backed end-to-end path is covered on iOS by
     * `ExportRunnerTemplateTests`.
     */
    internal data class ResolvedRun(
        val scope: ExportScope,
        val ingestedSince: Long?,
        val cursorBefore: Long?,
        val fellBackFromSinceLastRun: Boolean,
    )

    private suspend fun deliver(
        result: ExportResult,
        template: ExportTemplate,
        destination: ExportDestination,
        plan: ResolvedRun,
        runDate: Long,
        timeZone: TimeZone,
        attempt: Int,
    ): ExportDeliveryReceipt {
        val artifacts = destinationArtifacts(result, template.name, plan, runDate, timeZone)

        // The share sheet is delivered in-process: the artifacts stay in the runner's temp folder
        // for the UI to hand off. Nothing for this layer to copy, and no network deliverer is (or
        // should be) registered for it.
        if (destination.kind == ExportDestinationKind.SHARE_SHEET) {
            val bytes = artifacts.sumOf { it.byteCount }
            return ExportDeliveryReceipt(
                outcome = ExportOutcome.SUCCESS,
                errorDetail = deliveringDetail(filesWritten = artifacts.size, filesExpected = artifacts.size),
                bytesDelivered = bytes, deliveredAt = clock.now(),
                destinationStatus = ExportDestinationStatus.OK,
                // Inline en+ar (sanctioned for this module): the share sheet is delivered by the UI,
                // so the receipt only says the files are ready — never that they arrived anywhere.
                message = LocalizedString(en = "Your export is ready to share.", ar = "تصديرك جاهز للمشاركة."),
            )
        }

        val deliverer = deliverers.firstOrNull { it.kind == destination.kind }
            ?: return ExportDeliveryReceipt(
                outcome = ExportOutcome.FAILED_DELIVERY, errorCode = ExportErrorCode.DESTINATION_UNREACHABLE,
                errorDetail = deliveringDetail(filesWritten = 0, filesExpected = artifacts.size),
                bytesDelivered = 0, destinationStatus = destination.status,
                message = DestinationMessages.destinationNotConfigured,
            )

        return deliverer.deliver(
            ExportDeliveryRequest(destination, artifacts, runDate, timeZone), clock.now())
    }

    /**
     * Maps the runner's temp files onto the names they carry at the destination. A single-file
     * export (a JSON bundle, or the one encrypted container) uses the bare house name; a multi-file
     * export keeps each file's role as a discriminator (`…_raw.csv`, `…_manifest.json`) because raw
     * and derived must never collapse into one name (I5). The role suffix reuses the same
     * `slug`/`dateStamp` atoms `fileName` is built from, so it cannot drift from the house convention
     * the parity fixtures pin.
     */
    private fun destinationArtifacts(
        result: ExportResult,
        label: String,
        plan: ResolvedRun,
        runDate: Long,
        timeZone: TimeZone,
    ): List<ExportArtifact> {
        val start = plan.scope.startDate ?: 0L
        val end = plan.scope.endDate ?: runDate
        val single = result.files.size == 1
        val slug = ExportArtifactNaming.slug(label)
        val startStamp = ExportArtifactNaming.dateStamp(start, timeZone)
        val endStamp = ExportArtifactNaming.dateStamp(end, timeZone)
        return result.files.map { file ->
            val ext = file.extension
            val name = if (single) {
                ExportArtifactNaming.fileName(label, start, end, ext, timeZone)
            } else {
                val role = file.nameWithoutExtension // raw | derived | events | manifest | bundle
                "${ExportArtifactNaming.ROOT_FOLDER}_${slug}_$startStamp-${endStamp}_$role.$ext"
            }
            ExportArtifact(source = file, fileName = name, byteCount = file.length())
        }
    }

    /** Append one pre-generation or failed `ExportRun` and return it. */
    private fun record(
        runs: ExportRunRepository, id: String, template: ExportTemplate, trigger: ExportTrigger,
        jobId: String?, startedAt: Long, outcome: ExportOutcome, errorCode: ExportErrorCode?,
        stage: ExportStage, attempt: Int, destinationId: String?, cursorBefore: Long? = null,
    ): ExportRun {
        val run = ExportRun(
            id = id, templateId = template.id, jobId = jobId, trigger = trigger, startedAt = startedAt,
            finishedAt = clock.now(), outcome = outcome, errorCode = errorCode,
            errorDetail = ExportErrorDetail(stage, attempt = attempt),
            destinationId = destinationId, cursorBefore = cursorBefore,
        )
        runs.insert(run)
        return run
    }

    // MARK: - EPIC-13: aggregated CSV generation (bucketed templates)
    //
    // A `.bucketed` template rolls raw measurements up into hour/day/week/month buckets instead of
    // one row per reading. CSV-only: the JSON bundle is the full-fidelity archival format and its
    // schema defines no bucketed shape, so `runTemplate` routes a bucketed JSON template through
    // ordinary raw generation (raw data is never withheld). Aggregation is over the measurement
    // chain (raw + interval) only; the sensitive namespace is logs, not measurements, so an
    // aggregated file never contains meds/symptoms regardless of `includeSensitive` (which still
    // triggers encryption for defense in depth, matching `run`).

    private fun runAggregated(
        scope: ExportScope,
        template: ExportTemplate,
        bucket: ExportBucket,
        method: ExportAggregationMethod,
        passphrase: String?,
        ingestedSince: Long?,
        folder: File,
        startedAt: Long,
    ): ExportResult {
        if (scope.includeSensitive && (passphrase == null || !ExportPassphrasePolicy.isValid(passphrase))) {
            throw ExportRunException.SensitiveExportRequiresPassphrase
        }
        val exportId = Ulid.newId()
        folder.mkdirs()
        exportJobs.insert(
            ExportJob(id = exportId, scope = scope, format = ExportFormat.CSV,
                status = ExportJobStatus.RUNNING, outputPath = folder.path, startedAt = startedAt,
                createdAt = startedAt))

        try {
            val gathered = gatherAggregateInputs(scope, ingestedSince)
            val granularity = when (bucket) {
                ExportBucket.HOUR -> AggregateGranularity.HOUR
                ExportBucket.DAY -> AggregateGranularity.DAY
                ExportBucket.WEEK -> AggregateGranularity.WEEK
                ExportBucket.MONTH -> AggregateGranularity.MONTH
            }
            val definitions = registry.all.associateBy { it.metricId }
            val records = MetricAggregator().aggregate(gathered.first, granularity, method, definitions)

            val generatedAt = clock.now()
            val file = File(folder, "aggregated.csv")
            val checksum: String = if (template.layout == ExportLayout.WIDE) {
                val bytes = WideCsvProjector().render(records).toByteArray()
                file.writeBytes(bytes)
                sha256Hex(bytes)
            } else {
                val digest = MessageDigest.getInstance("SHA-256")
                file.outputStream().use { CsvWriter().writeTo(records.map { r -> aggregateRow(r, scope) }, it, digest) }
                hex(digest.digest())
            }

            val counts = HashMap<String, Int>()
            for (record in records) counts.bump(record.metricId)
            val manifest = makeManifest(exportId, scope, generatedAt, mapOf("aggregated.csv" to checksum), counts)
            val manifestFile = File(folder, "manifest.json")
            manifestFile.writeText(JsonCoding.encode(manifest))

            val job = ExportJob(
                id = exportId, scope = scope, format = ExportFormat.CSV, status = ExportJobStatus.COMPLETED,
                manifest = manifest, outputPath = folder.path, rowCount = records.size,
                startedAt = startedAt, finishedAt = generatedAt, createdAt = startedAt)
            exportJobs.insert(job)

            // Aggregate buckets are interval aggregates in `ExportRowCounts`' vocabulary (a bucket
            // IS an interval aggregate), reported under `intervals` rather than an invented class.
            val rowCounts = ExportRowCounts(intervals = records.size)
            var result = ExportResult(job, listOf(file, manifestFile), records.size,
                maxIngestedAt = gathered.second, rowCounts = rowCounts)
            if (scope.includeSensitive && passphrase != null) {
                result = encryptResult(result, exportId, folder, scope, ExportFormat.CSV, startedAt, passphrase)
                    .copy(maxIngestedAt = gathered.second, rowCounts = rowCounts)
            }
            return result
        } catch (e: Throwable) {
            runCatching {
                exportJobs.insert(ExportJob(id = exportId, scope = scope, format = ExportFormat.CSV,
                    status = ExportJobStatus.FAILED, outputPath = folder.path, startedAt = startedAt,
                    finishedAt = clock.now(), createdAt = startedAt))
            }
            for (f in folder.listFiles() ?: emptyArray()) f.delete()
            throw e
        }
    }

    /**
     * The raw + interval rows in scope, projected onto `AggregateInputRow` for `MetricAggregator`,
     * plus the max `ingested_at` over them (the delta watermark). Aggregation happens in canonical
     * units only (the aggregator's contract), so `value`/`unit` are the canonical ones.
     */
    private fun gatherAggregateInputs(scope: ExportScope, ingestedSince: Long?): Pair<List<AggregateInputRow>, Long?> {
        val rows = mutableListOf<AggregateInputRow>()
        var ingestMax: Long? = null
        fun note(t: Long) { if (ingestMax == null || t > ingestMax!!) ingestMax = t }
        for (id in metricIdsInScope(scope)) {
            if (!metricAllowed(id, scope)) continue
            for (s in measurements.rawSamples(id, scope.startDate, scope.endDate, scope.includeSuppressed)) {
                if (!sourceAllowed(s.provenance, scope) || !ingestedAfter(s.provenance.ingestedAt, ingestedSince)) continue
                rows += AggregateInputRow(s.metricId, s.value, s.unit, s.startAt, s.endAt, s.tzId)
                note(s.provenance.ingestedAt)
            }
            for (r in measurements.intervalRecords(id, scope.startDate, scope.endDate, scope.includeSuppressed)) {
                if (!sourceAllowed(r.provenance, scope) || !ingestedAfter(r.provenance.ingestedAt, ingestedSince)) continue
                rows += AggregateInputRow(r.metricId, r.value, r.unit, r.startAt, r.endAt, r.tzId, r.aggregation)
                note(r.provenance.ingestedAt)
            }
        }
        return rows to ingestMax
    }

    /**
     * One aggregated bucket as a tidy CSV row. `record_kind` is `interval` and `value_type` is
     * `aggregate` — a bucket IS an interval aggregate, and `interval` keeps the row inside the
     * frozen 6-value record_kind vocabulary — while `ingestion_path` is `derived` (the bucket was
     * computed by BADAN) and `is_derived` stays false (a rollup of RAW, kept separable from
     * engine-derived values — I5). Columns 25/26 carry the granularity and method that make the
     * number self-describing. `sample_count` and the multi-zone flag have no column in the 26-column
     * contract and are dropped here.
     */
    private fun aggregateRow(record: AggregateRecord, scope: ExportScope): ExportRow {
        val (value, unit) = displayValueUnit(record.metricId, record.value, record.unit, scope)
        return ExportRow(
            recordId = "${record.metricId}|${record.bucketKey}|${record.stat.name.lowercase()}",
            recordKind = RecordKind.INTERVAL,
            metricId = record.metricId,
            metricDisplay = metricDisplay(record.metricId, scope),
            value = CsvWriter.decimal(value),
            unit = unit,
            canonicalValue = CsvWriter.decimal(record.value),
            canonicalUnit = record.unit,
            valueType = ValueType.AGGREGATE,
            isDerived = false,
            timestampStart = CsvWriter.iso8601(record.bucketStartMillis, record.tzId),
            timestampEnd = CsvWriter.iso8601(record.bucketEndMillis, record.tzId),
            timezone = record.tzId,
            recordedAt = CsvWriter.iso8601(record.bucketStartMillis, record.tzId),
            ingestionPath = IngestionPath.DERIVED.code,
            granularity = record.granularity.csvGranularity,
            aggregationMethod = record.stat.csvMethod,
        )
    }

    // MARK: - EPIC-12: GPX route export
    //
    // Routes can NOT ride the template path: `ExportFormat` has no `gpx` case, and routes are
    // excluded from Quick Export structurally. GPX gets its own entry point, gated the way §22.4 /
    // §4.11 require: the route-export toggle AND a per-run confirmation that fingerprints the exact
    // routes being written (both in `GpxWriter.artifacts`). This turns that output into a recorded
    // export — an `ExportJob` and an `ExportRun`. Delivery is the share sheet (the explicit route
    // flow); a folder destination for routes is a later follow-up.

    fun runRouteExport(
        workouts: List<GpxWorkout>,
        routeExportEnabled: Boolean,
        confirmation: RouteExportConfirmation,
        baseDir: File,
        trigger: ExportTrigger = ExportTrigger.MANUAL,
        attempt: Int = 0,
    ): TemplateRunResult {
        val startedAt = clock.now()
        val runId = Ulid.newId()
        // Routes are location data; the manifest records a raw, non-sensitive-namespace scope (the
        // sensitive namespace is meds/symptoms — routes are their own class, gated above).
        val scope = ExportScope(includeRaw = true, includeDerived = false)
        val runs = this.runs
            ?: return TemplateRunResult(
                ExportRun(id = runId, trigger = trigger, startedAt = startedAt, finishedAt = clock.now(),
                    outcome = ExportOutcome.FAILED_GENERATION, errorCode = ExportErrorCode.UNKNOWN,
                    errorDetail = ExportErrorDetail(ExportStage.FINALIZING, attempt = attempt)),
                null, null)

        val artifacts = try {
            GpxWriter(appVersion, startedAt).artifacts(workouts, routeExportEnabled, confirmation)
        } catch (e: Throwable) {
            // Map the two gate failures onto the closed ledger vocabulary: the toggle being off is a
            // permission refusal; a stale confirmation is a missing run-time confirmation.
            val code = when (e) {
                is GpxExportException.RouteExportNotEnabled -> ExportErrorCode.PERMISSION_DENIED
                is GpxExportException.ConfirmationStale -> ExportErrorCode.SENSITIVE_CONFIRMATION_MISSING
                else -> ExportErrorCode.WRITE_FAILED
            }
            val run = ExportRun(id = runId, trigger = trigger, startedAt = startedAt, finishedAt = clock.now(),
                outcome = ExportOutcome.FAILED_GENERATION, errorCode = code,
                errorDetail = ExportErrorDetail(ExportStage.GATHERING, attempt = attempt))
            runs.insert(run)
            return TemplateRunResult(run, null, null)
        }

        val exportId = Ulid.newId()
        val folder = File(baseDir, "badan-export-$runId")
        try {
            folder.mkdirs()
            exportJobs.insert(ExportJob(id = exportId, scope = scope, format = ExportFormat.CSV,
                status = ExportJobStatus.RUNNING, outputPath = folder.path, startedAt = startedAt,
                createdAt = startedAt))

            val files = mutableListOf<File>()
            val checksums = HashMap<String, String>()
            var bytes = 0L
            for (artifact in artifacts) {
                val file = File(folder, artifact.fileName)
                val data = artifact.gpx.toByteArray()
                file.writeBytes(data)
                checksums[artifact.fileName] = sha256Hex(data)
                bytes += data.size
                files += file
            }

            val generatedAt = clock.now()
            val manifest = makeManifest(exportId, scope, generatedAt, checksums, emptyMap())
            val manifestFile = File(folder, "manifest.json")
            manifestFile.writeText(JsonCoding.encode(manifest))
            files += manifestFile

            val pointCount = workouts.sumOf { w -> w.routes.sumOf { it.points.size } }
            val job = ExportJob(id = exportId, scope = scope, format = ExportFormat.CSV,
                status = ExportJobStatus.COMPLETED, manifest = manifest, outputPath = folder.path,
                rowCount = pointCount, startedAt = startedAt, finishedAt = generatedAt, createdAt = startedAt)
            exportJobs.insert(job)

            val result = ExportResult(job, files, pointCount)
            val run = ExportRun(id = runId, jobId = exportId, trigger = trigger, startedAt = startedAt,
                finishedAt = generatedAt, outcome = ExportOutcome.SUCCESS, bytesWritten = bytes,
                rowCounts = ExportRowCounts(sessions = workouts.size), deliveredAt = generatedAt,
                manifestSha256 = ManifestDigest.of(sha256Hex(JsonCoding.encode(manifest).toByteArray())))
            runs.insert(run)
            return TemplateRunResult(run, result, null)
        } catch (e: Throwable) {
            runCatching {
                exportJobs.insert(ExportJob(id = exportId, scope = scope, format = ExportFormat.CSV,
                    status = ExportJobStatus.FAILED, outputPath = folder.path, startedAt = startedAt,
                    finishedAt = clock.now(), createdAt = startedAt))
            }
            for (f in folder.listFiles() ?: emptyArray()) f.delete()
            val run = ExportRun(id = runId, jobId = exportId, trigger = trigger, startedAt = startedAt,
                finishedAt = clock.now(), outcome = ExportOutcome.FAILED_GENERATION,
                errorCode = ExportErrorCode.WRITE_FAILED,
                errorDetail = ExportErrorDetail(ExportStage.WRITING, attempt = attempt))
            runs.insert(run)
            return TemplateRunResult(run, null, null)
        }
    }

    companion object {
        private const val DAY_MS = 86_400_000L

        /**
         * How many days a `sinceLastRun` template falls back to when it has no cursor yet. Matches
         * the Last-30 Quick Export preset (and `ExportManageService`'s own fallback) so a first
         * delta run produces a familiar-sized file rather than all of history.
         */
        const val CURSOR_MISSING_FALLBACK_DAYS = 30

        /**
         * The incremental-export inclusion test (EPIC-17). A null watermark (every non-delta run)
         * includes everything, so the plain export path is unchanged. Strictly greater than the
         * watermark, matching `ExportCursorRepository.advance`'s forward-only guard: the cursor is
         * advanced to the max `ingested_at` this run *included*, so the next run's `> watermark`
         * window starts exactly one past the last row already delivered — a row can neither be
         * skipped (the query has no upper bound) nor duplicated (the boundary row is `== watermark`,
         * not `>`).
         */
        internal fun ingestedAfter(ingestedAt: Long, watermark: Long?): Boolean =
            watermark == null || ingestedAt > watermark

        /**
         * Resolve a template's [ExportRangeRule] into one run's concrete window + delta filter.
         * Pure and static so it is unit-testable without a database (see [ResolvedRun]).
         *
         * `sinceLastRun` with no cursor falls back to `lastNDays` WITH A NOTICE (never a silent
         * all-history dump) and, crucially, does NOT establish a delta watermark: the bounded
         * fallback filters on the MEASURED axis, so advancing an ingested-axis cursor from it could
         * skip a historical row ingested recently but measured outside the window — the exact
         * DATA-08 loss. The cursor is only ever established/advanced by a run that already had one
         * (`runTemplate`'s two-phase commit), so a first `sinceLastRun` stays disclosed-bounded
         * until an explicit checkpoint exists.
         */
        internal fun resolveRange(
            rule: ExportRangeRule,
            scope: ExportScope,
            cursor: ExportCursor?,
            now: Long,
        ): ResolvedRun = when (rule) {
            is ExportRangeRule.Fixed ->
                ResolvedRun(scope, null, null, false)
            is ExportRangeRule.LastNDays ->
                ResolvedRun(
                    scope.copy(startDate = now - rule.safeDays.toLong() * DAY_MS, endDate = now),
                    null, null, false)
            is ExportRangeRule.AllTime ->
                ResolvedRun(scope.copy(startDate = null, endDate = null), null, null, false)
            is ExportRangeRule.SinceLastRun ->
                if (cursor == null) {
                    ResolvedRun(
                        scope.copy(startDate = now - CURSOR_MISSING_FALLBACK_DAYS.toLong() * DAY_MS, endDate = now),
                        null, null, true)
                } else {
                    // Delta: clear the measured-date window entirely and filter on the ingested
                    // axis, so a late-arriving row (measured before the watermark, ingested after
                    // it) is included rather than dropped forever.
                    ResolvedRun(scope.copy(startDate = null, endDate = null), cursor.highWatermark,
                        cursor.highWatermark, false)
                }
        }

        private const val DATA_QUALITY_NOTE =
            "Rows reflect stored records only; coverage gaps are not backfilled. Interval aggregates " +
                "carry a 0–1 coverage fraction in the JSON bundle. Derived values and baselines are " +
                "engine-computed, physically separated from raw, and each carries its algorithm id and version."
    }
}
