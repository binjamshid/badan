package net.albayyan.badan.export

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.WorkoutEntry
import java.security.MessageDigest

/**
 * EPIC-18 — full backup & restore. Mirror of iOS `BackupBundle` (plan §12 EPIC-18).
 *
 * A *backup* is one artifact holding everything BADAN keeps for the user: the full-scope JSON v1.0
 * data bundle (every namespace the caller gathered, with consent), the configuration that shapes
 * it (`export_templates`, `automation_schedules`, `customization`, and — encrypted only —
 * `export_destinations` sans-secrets), a human-readable `DATA_DICTIONARY.md`, and a top-level
 * manifest binding those files with per-file SHA-256. A backup is the same data an export produces;
 * its added value is that it is *restorable*.
 *
 * **Byte-parity across platforms is the load-bearing property** (plan §4.6). A backup written on
 * Android must restore on iOS and vice-versa, so both the plaintext wrapper and the encrypted
 * container are assembled from the same deterministic primitives the export writers already share:
 * [CanonicalJson] for every JSON byte and [ExportEncryptor] for the encrypted container (whose
 * byte-exact format reached iOS/Android parity in Phase 0). This type adds no encoder of its own.
 *
 * This object is a pure transform: [build] takes materialized records + config and returns bytes;
 * [parse]/[preview]/[plan] take bytes and return staged, inspectable models. It reads no repository
 * and touches no database, which keeps the byte-parity fixtures able to drive it directly and keeps
 * restore's *commit* — the only destructive step — out of the pure core and behind the host's
 * staged-import machinery (see [RestorePlan]).
 */
object BackupBundle {

    // MARK: - Format constants

    /** The backup wrapper/manifest schema version, independent of [ExportSchema.VERSION]. */
    const val VERSION: String = "1.0"

    const val MANIFEST_FILE_NAME: String = "backup_manifest.json"
    const val DICTIONARY_FILE_NAME: String = "DATA_DICTIONARY.md"
    const val BUNDLE_FILE_NAME: String = "bundle.json"

    const val NAME_PREFIX: String = "BADAN_backup_"
    const val PLAINTEXT_EXTENSION: String = "json"
    const val ENCRYPTED_EXTENSION: String = "badanenc"

    /**
     * The ceiling on an encrypted backup's declared PBKDF2 rounds, enforced at restore before the
     * KDF runs (see [RestoreException.KdfCostTooHigh]). [ExportEncryptor]'s own doc comment is
     * explicit that whoever builds an import path must add this cap, on both platforms together.
     * Restore is that import path. ~6.6× the 600k default written today; raise the write-side
     * default past this only in a change that raises this too, on both platforms.
     */
    const val MAX_KDF_ITERATIONS: Long = 4_000_000L

    const val PREVIEWED_STATE: String = "previewed"
    const val RESTORE_SOURCE_KIND: String = "backup"

    private val lenientJson = Json { ignoreUnknownKeys = true; isLenient = false }

    // MARK: - Errors

    /**
     * Typed restore failures. Every case means "do not import anything" — there is no
     * partial-restore case (plan §12 EPIC-18 requirement 6).
     */
    sealed class RestoreException(message: String) : Exception(message) {
        /** Written by a newer backup schema major version than this build understands (req 6). */
        data class SchemaTooNew(val found: String, val supported: String) :
            RestoreException("backup schema $found is newer than supported $supported")

        /** Not a BADAN backup at all. */
        object NotABackup : RestoreException("not a BADAN backup")

        /** Structurally broken (missing file, unreadable wrapper). */
        data class Malformed(val reason: String) : RestoreException("malformed backup: $reason")

        /** A file's bytes do not match the SHA-256 the manifest recorded. */
        data class ChecksumMismatch(val file: String) : RestoreException("checksum mismatch: $file")

        /** Encrypted and no/wrong passphrase (or altered bytes — indistinguishable by design). */
        data class Encrypted(val reason: ExportEncryptionException) :
            RestoreException("encrypted backup: ${reason.message}")

        /** Declares a PBKDF2 iteration count above [MAX_KDF_ITERATIONS] (DoS cap, req from ADR-0008). */
        data class KdfCostTooHigh(val iterations: Long, val cap: Long) :
            RestoreException("KDF cost $iterations exceeds cap $cap")
    }

    // MARK: - Build

    /** The bytes to write, plus the recovered-on-restore logical files for tests/callers. */
    data class Artifact(
        val fileName: String,
        val data: ByteArray,
        val encrypted: Boolean,
        val logicalFiles: List<ExportContainerFile>,
    )

    /**
     * Assemble one backup artifact.
     *
     * The data lists mirror [JsonBundleWriter.data] one-for-one and are serialized through it, so a
     * backup's `bundle.json` is byte-identical to the ordinary JSON export for the same records.
     *
     * [passphrase] decides the variant: non-null wraps the whole artifact (every namespace *and*
     * the config — §12 EPIC-18 requirement 2) in an [ExportEncryptor] container; null produces the
     * plaintext JSON wrapper. Validated against [ExportPassphrasePolicy] when present.
     *
     * Destinations are handled structurally (requirement 3): echoed only into an encrypted bundle,
     * only through [destinationSansSecrets], which has no field a secret fits into.
     *
     * [hydration] is the drink slice (EPIC-38): the full ledger the caller gathered for a backup —
     * entries with their revision chains, day summaries, goals, and referenced beverages. It is
     * carried **whole, with notes**, unlike the redacted default export: a backup is the user's
     * complete data for their own device migration, and the bundle already carries symptom, workout
     * and nutrition notes unconditionally, so dropping only *water* notes would be arbitrary. A
     * null/empty payload writes no `logs.hydration` at all, so the pre-hydration goldens stay
     * byte-identical.
     */
    fun build(
        manifest: ExportManifest,
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sessions: List<Session>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
        symptoms: List<SymptomEntry>,
        adherence: List<AdherenceEvent>,
        workouts: List<WorkoutEntry>,
        nutrition: List<NutritionEntry>,
        templates: List<ExportTemplate>,
        destinations: List<ExportDestination>,
        customization: CanonicalJson,
        schedules: List<CanonicalJson>,
        createdAt: Long,
        appVersion: String,
        platform: String,
        hydration: HydrationExportPayload? = null,
        includeRoutes: Boolean = false,
        passphrase: String? = null,
    ): Artifact {
        val encrypting = passphrase != null
        if (passphrase != null && !ExportPassphrasePolicy.isValid(passphrase)) {
            throw RestoreException.Encrypted(ExportEncryptionException.IncorrectPassphraseOrTamperedData)
        }

        val config = configObject(templates, destinations, customization, schedules, encrypting)

        val bundleData = JsonBundleWriter().data(
            manifest, rawSamples, intervalRecords, sessions, derivedValues, baselines, symptoms,
            adherence, workouts, nutrition, includeRoutes = includeRoutes, config = config,
            // A backup carries the drink ledger WHOLE — notes included — because it is the user's
            // complete data, and the bundle already carries every other log's notes unredacted.
            hydration = hydration, hydrationRedaction = HydrationRedactionPolicy(includeNotes = true),
        )
        val dictionaryData = dataDictionaryMarkdown().toByteArray(Charsets.UTF_8)

        // The manifest checksums the OTHER two files, never itself.
        val manifestData = backupManifest(
            bundleData, dictionaryData, createdAt, appVersion, platform, encrypting,
            templates, destinations, schedules, customization != CanonicalJson.Obj(emptyMap()),
            symptoms.size, adherence.size,
        ).render().toByteArray(Charsets.UTF_8)

        val files = listOf(
            ExportContainerFile(DICTIONARY_FILE_NAME, dictionaryData),
            ExportContainerFile(MANIFEST_FILE_NAME, manifestData),
            ExportContainerFile(BUNDLE_FILE_NAME, bundleData),
        ).sortedWith { a, b -> compareUtf8(a.name, b.name) }

        val range = dayStamp(createdAt)
        return if (passphrase != null) {
            val container = ExportEncryptor.encrypt(files, passphrase)
            Artifact("$NAME_PREFIX$range.$ENCRYPTED_EXTENSION", container, true, files)
        } else {
            val wrapper = plaintextWrapper(files).render().toByteArray(Charsets.UTF_8)
            Artifact("$NAME_PREFIX$range.$PLAINTEXT_EXTENSION", wrapper, false, files)
        }
    }

    // MARK: - Config echo

    /**
     * The `config` object embedded in `bundle.json`. `export_destinations` appears only when
     * encrypting, and each row goes through [destinationSansSecrets] (requirement 3).
     */
    fun configObject(
        templates: List<ExportTemplate>,
        destinations: List<ExportDestination>,
        customization: CanonicalJson,
        schedules: List<CanonicalJson>,
        encrypting: Boolean,
    ): Map<String, CanonicalJson> {
        val config = linkedMapOf<String, CanonicalJson>(
            "export_templates" to CanonicalJson.Arr(templates.sortedBy { it.id }.map(::templateObject)),
            "automation_schedules" to CanonicalJson.Arr(schedules),
            "customization" to customization,
        )
        if (encrypting) {
            config["export_destinations"] =
                CanonicalJson.Arr(destinations.sortedBy { it.id }.map(::destinationSansSecrets))
        }
        return config
    }

    private fun templateObject(t: ExportTemplate): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "id" to CanonicalJson.Str(t.id),
            "name" to CanonicalJson.Str(t.name),
            "scope" to scopeObject(t.scope),
            "range_rule" to CanonicalJson.Str(t.rangeRule.storageValue),
            "format" to CanonicalJson.Str(t.format.code),
            "aggregation" to CanonicalJson.Str(
                t.aggregation.storageMethod?.let { "${t.aggregation.storageGranularity}:$it" }
                    ?: t.aggregation.storageGranularity
            ),
            "layout" to CanonicalJson.Str(t.layout.code),
            "include_schema_docs" to CanonicalJson.Bool(t.includeSchemaDocs),
            "destination_id" to CanonicalJson.str(t.destinationId),
            "is_preset" to CanonicalJson.Bool(t.isPreset),
            "created_at" to CanonicalJson.Str(TimestampFormatting.string(t.createdAt, "UTC")),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(t.updatedAt, "UTC")),
            "origin_device_id" to CanonicalJson.Str(t.originDeviceId),
            "deleted_at" to (t.deletedAt?.let { CanonicalJson.Str(TimestampFormatting.string(it, "UTC")) }
                ?: CanonicalJson.Null),
        )
    )

    private fun scopeObject(scope: ExportScope): CanonicalJson {
        fun list(values: List<String>?): CanonicalJson =
            values?.let { CanonicalJson.Arr(it.map { v -> CanonicalJson.Str(v) }) } ?: CanonicalJson.Null
        return CanonicalJson.Obj(
            mapOf(
                "metric_ids" to list(scope.metricIds),
                "families" to list(scope.families),
                "start_date" to (scope.startDate?.let { CanonicalJson.Str(TimestampFormatting.string(it, "UTC")) }
                    ?: CanonicalJson.Null),
                "end_date" to (scope.endDate?.let { CanonicalJson.Str(TimestampFormatting.string(it, "UTC")) }
                    ?: CanonicalJson.Null),
                "source_ids" to list(scope.sourceIds),
                "include_raw" to CanonicalJson.Bool(scope.includeRaw),
                "include_derived" to CanonicalJson.Bool(scope.includeDerived),
                "include_suppressed" to CanonicalJson.Bool(scope.includeSuppressed),
                "include_sensitive" to CanonicalJson.Bool(scope.includeSensitive),
                "unit_profile" to CanonicalJson.Str(scope.unitProfile.code),
                "language" to CanonicalJson.Str(scope.language.code),
            )
        )
    }

    /**
     * The **only** projection of a destination allowed into a bundle, and it is structural: no
     * branch here emits `credentialRef`, `folderBookmarkRef` or `providerAccountRef`. Adding one
     * means editing this function — the review requirement 3 forces.
     */
    fun destinationSansSecrets(d: ExportDestination): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "id" to CanonicalJson.Str(d.id),
            "kind" to CanonicalJson.Str(d.kind.code),
            "display_name" to CanonicalJson.Str(d.displayName),
            "tls_policy" to CanonicalJson.Str(d.tlsPolicy.code),
            "status" to CanonicalJson.Str(d.status.code),
            "endpoint_url" to CanonicalJson.str(d.config.endpointURL),
            "http_method" to CanonicalJson.str(d.config.httpMethod),
            "provider_id" to CanonicalJson.str(d.config.providerId),
            "header_template_ids" to CanonicalJson.Arr(d.config.headerTemplateIds.sorted().map { CanonicalJson.Str(it) }),
            "created_at" to CanonicalJson.Str(TimestampFormatting.string(d.createdAt, "UTC")),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(d.updatedAt, "UTC")),
            "origin_device_id" to CanonicalJson.Str(d.originDeviceId),
            "deleted_at" to (d.deletedAt?.let { CanonicalJson.Str(TimestampFormatting.string(it, "UTC")) }
                ?: CanonicalJson.Null),
        )
    )

    // MARK: - Backup manifest

    private fun backupManifest(
        bundleData: ByteArray,
        dictionaryData: ByteArray,
        createdAt: Long,
        appVersion: String,
        platform: String,
        encrypted: Boolean,
        templates: List<ExportTemplate>,
        destinations: List<ExportDestination>,
        schedules: List<CanonicalJson>,
        hasCustomization: Boolean,
        symptomCount: Int,
        adherenceCount: Int,
    ): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "backup_schema_version" to CanonicalJson.Str(VERSION),
            "export_schema_version" to CanonicalJson.Str(ExportSchema.VERSION),
            "created_at" to CanonicalJson.Str(TimestampFormatting.string(createdAt, "UTC")),
            "app" to CanonicalJson.Obj(
                mapOf(
                    "name" to CanonicalJson.Str("BADAN"),
                    "version" to CanonicalJson.Str(appVersion),
                    "platform" to CanonicalJson.Str(platform),
                )
            ),
            "encryption" to CanonicalJson.Str(if (encrypted) "badanenc-v1" else "none"),
            "files" to CanonicalJson.Obj(
                mapOf(
                    BUNDLE_FILE_NAME to CanonicalJson.Obj(
                        mapOf(
                            "sha256" to CanonicalJson.Str(sha256Hex(bundleData)),
                            "bytes" to CanonicalJson.Int64(bundleData.size.toLong()),
                        )
                    ),
                    DICTIONARY_FILE_NAME to CanonicalJson.Obj(
                        mapOf(
                            "sha256" to CanonicalJson.Str(sha256Hex(dictionaryData)),
                            "bytes" to CanonicalJson.Int64(dictionaryData.size.toLong()),
                        )
                    ),
                )
            ),
            "config" to CanonicalJson.Obj(
                mapOf(
                    "export_templates" to CanonicalJson.Int64(templates.size.toLong()),
                    // A count only when encrypted; a plaintext manifest must not even disclose how
                    // many destinations exist, matching the config echo's own exclusion.
                    "export_destinations" to if (encrypted) CanonicalJson.Int64(destinations.size.toLong()) else CanonicalJson.Null,
                    "automation_schedules" to CanonicalJson.Int64(schedules.size.toLong()),
                    "customization" to CanonicalJson.Bool(hasCustomization),
                )
            ),
            "sensitive_present" to CanonicalJson.Bool(symptomCount > 0 || adherenceCount > 0),
        )
    )

    // MARK: - Plaintext wrapper

    /**
     * The on-disk shape of a plaintext backup: one JSON object listing the logical files as escaped
     * strings. Files travel as *strings*, not nested objects, so the transported bytes are the
     * bytes the manifest checksummed and cross-platform equality is a property of [CanonicalJson]'s
     * string escaper alone.
     */
    fun plaintextWrapper(files: List<ExportContainerFile>): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "backup_schema_version" to CanonicalJson.Str(VERSION),
            "encryption" to CanonicalJson.Str("none"),
            "files" to CanonicalJson.Arr(
                files.sortedWith { a, b -> compareUtf8(a.name, b.name) }.map { file ->
                    CanonicalJson.Obj(
                        mapOf(
                            "name" to CanonicalJson.Str(file.name),
                            "content" to CanonicalJson.Str(String(file.data, Charsets.UTF_8)),
                        )
                    )
                }
            ),
        )
    )

    // MARK: - Parse

    /** A parsed, checksum-verified, schema-checked backup. */
    data class RestoreBundle(
        val schemaVersion: String,
        val createdAt: String,
        val originPlatform: String,
        val originAppVersion: String,
        val encrypted: Boolean,
        val logicalFiles: List<ExportContainerFile>,
        val bundle: JsonObject,
    )

    /**
     * Recover a backup from bytes. [passphrase] is required iff the bytes are an encrypted
     * container. The schema-version gate runs before any file is verified or the data bundle is
     * parsed (requirement 6).
     */
    fun parse(data: ByteArray, passphrase: String? = null): RestoreBundle {
        val files = recoverFiles(data, passphrase)

        val manifestFile = files.firstOrNull { it.name == MANIFEST_FILE_NAME }
            ?: throw RestoreException.Malformed("missing $MANIFEST_FILE_NAME")
        val manifest = runCatching {
            lenientJson.parseToJsonElement(String(manifestFile.data, Charsets.UTF_8)).jsonObject
        }.getOrElse { throw RestoreException.Malformed("unreadable $MANIFEST_FILE_NAME") }

        val foundVersion = manifest["backup_schema_version"]?.jsonPrimitive?.contentOrNull ?: ""
        if (!isReadable(foundVersion)) {
            throw RestoreException.SchemaTooNew(foundVersion, VERSION)
        }

        (manifest["files"] as? JsonObject)?.forEach { (name, spec) ->
            val file = files.firstOrNull { it.name == name }
                ?: throw RestoreException.Malformed("manifest names a missing file: $name")
            val expected = (spec as? JsonObject)?.get("sha256")?.jsonPrimitive?.contentOrNull ?: ""
            if (sha256Hex(file.data) != expected) throw RestoreException.ChecksumMismatch(name)
        }

        val bundleFile = files.firstOrNull { it.name == BUNDLE_FILE_NAME }
            ?: throw RestoreException.Malformed("missing $BUNDLE_FILE_NAME")
        val bundle = runCatching {
            lenientJson.parseToJsonElement(String(bundleFile.data, Charsets.UTF_8)).jsonObject
        }.getOrElse { throw RestoreException.Malformed("unreadable $BUNDLE_FILE_NAME") }

        val app = manifest["app"] as? JsonObject
        return RestoreBundle(
            schemaVersion = foundVersion,
            createdAt = manifest["created_at"]?.jsonPrimitive?.contentOrNull ?: "",
            originPlatform = app?.get("platform")?.jsonPrimitive?.contentOrNull ?: "",
            originAppVersion = app?.get("version")?.jsonPrimitive?.contentOrNull ?: "",
            encrypted = (manifest["encryption"]?.jsonPrimitive?.contentOrNull ?: "none") != "none",
            logicalFiles = files,
            bundle = bundle,
        )
    }

    private fun recoverFiles(data: ByteArray, passphrase: String?): List<ExportContainerFile> {
        if (isEncryptedContainer(data)) {
            passphrase ?: throw RestoreException.Encrypted(ExportEncryptionException.IncorrectPassphraseOrTamperedData)
            val iterations = declaredIterations(data)
            if (iterations != null && iterations > MAX_KDF_ITERATIONS) {
                throw RestoreException.KdfCostTooHigh(iterations, MAX_KDF_ITERATIONS)
            }
            return try {
                ExportEncryptor.decrypt(data, passphrase)
            } catch (e: ExportEncryptionException) {
                throw RestoreException.Encrypted(e)
            }
        }
        val wrapper = runCatching {
            lenientJson.parseToJsonElement(String(data, Charsets.UTF_8)).jsonObject
        }.getOrElse { throw RestoreException.NotABackup }
        if (wrapper["backup_schema_version"] == null || wrapper["files"] == null) {
            throw RestoreException.NotABackup
        }
        return (wrapper["files"] as? JsonArray).orEmpty().mapNotNull { entry ->
            val obj = entry as? JsonObject ?: return@mapNotNull null
            val name = obj["name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            val content = obj["content"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            ExportContainerFile(name, content.toByteArray(Charsets.UTF_8))
        }
    }

    fun isEncryptedContainer(data: ByteArray): Boolean {
        if (data.size < ExportEncryptor.MAGIC.size) return false
        for (i in ExportEncryptor.MAGIC.indices) if (data[i] != ExportEncryptor.MAGIC[i]) return false
        return true
    }

    /**
     * The PBKDF2 iteration count an encrypted container declares, read from the fixed header
     * (`magic(4) version(1) kdfId(1) iterations(4 BE) …`). Null if too short.
     */
    fun declaredIterations(data: ByteArray): Long? {
        if (data.size < 10) return null
        return ((data[6].toLong() and 0xFF) shl 24) or ((data[7].toLong() and 0xFF) shl 16) or
            ((data[8].toLong() and 0xFF) shl 8) or (data[9].toLong() and 0xFF)
    }

    /**
     * Readable iff the major version is ≤ ours. A higher minor is tolerated; a higher major means
     * an incompatible shape and the honest answer is to refuse (requirement 6).
     */
    fun isReadable(found: String): Boolean {
        val foundMajor = found.substringBefore(".").toIntOrNull() ?: Int.MAX_VALUE
        val ourMajor = VERSION.substringBefore(".").toIntOrNull() ?: 0
        return foundMajor <= ourMajor
    }

    // MARK: - Preview

    /** What a backup claims to contain, for the confirm-before-commit screen. */
    data class RestorePreview(
        val schemaVersion: String,
        val createdAt: String,
        val originPlatform: String,
        val originAppVersion: String,
        val encrypted: Boolean,
        val namespaceCounts: Map<String, Int>,
        val sensitivePresent: Boolean,
        val configCounts: Map<String, Int>,
        val hasCustomization: Boolean,
    )

    fun preview(bundle: RestoreBundle): RestorePreview {
        fun count(key: String): Int = (bundle.bundle[key] as? JsonArray)?.size ?: 0
        val logs = bundle.bundle["logs"] as? JsonObject
        fun logCount(key: String): Int = (logs?.get(key) as? JsonArray)?.size ?: 0

        val symptoms = logCount("symptoms")
        val adherence = logCount("adherence")
        // `logs.hydration` is an object (redaction/entries/summaries/…), so its record count is the
        // length of its `entries` array. A backup with no drinks has no `hydration` key → 0, the
        // same absent-not-empty rule the writer follows.
        val hydrationEntries = ((logs?.get("hydration") as? JsonObject)?.get("entries") as? JsonArray)?.size ?: 0

        val config = bundle.bundle["config"] as? JsonObject
        fun configArray(key: String): Int = (config?.get(key) as? JsonArray)?.size ?: 0
        val customization = config?.get("customization") as? JsonObject

        return RestorePreview(
            schemaVersion = bundle.schemaVersion,
            createdAt = bundle.createdAt,
            originPlatform = bundle.originPlatform,
            originAppVersion = bundle.originAppVersion,
            encrypted = bundle.encrypted,
            namespaceCounts = mapOf(
                "raw_samples" to count("raw_samples"),
                "interval_records" to count("interval_records"),
                "sessions" to count("sessions"),
                "workouts" to count("workouts"),
                "derived_values" to count("derived_values"),
                "baselines" to count("baselines"),
                "logs.symptoms" to symptoms,
                "logs.adherence" to adherence,
                "logs.workouts" to logCount("workouts"),
                "logs.nutrition" to logCount("nutrition"),
                "logs.hydration" to hydrationEntries,
            ),
            sensitivePresent = symptoms > 0 || adherence > 0,
            configCounts = mapOf(
                "export_templates" to configArray("export_templates"),
                "export_destinations" to configArray("export_destinations"),
                "automation_schedules" to configArray("automation_schedules"),
            ),
            hasCustomization = customization != null && customization.isNotEmpty(),
        )
    }

    // MARK: - Restore plan (staged import)

    /**
     * The user's decision, given at restore time, for the sensitive class. §12 EPIC-18 requirement
     * 5: a sensitive namespace requires its consent toggle at *restore* time, not only at backup
     * time. Default deny.
     */
    data class RestoreConsent(val includeSensitive: Boolean = false)

    /**
     * A staged, inspectable import descriptor. Holds the batch id every restored row will carry in
     * its provenance (I1), the source/file, the per-namespace counts that WILL import (sensitive
     * excluded unless consented), and the state. It deliberately does not perform the write — the
     * destructive commit belongs behind the `import_batches` machinery so "preview before commit"
     * and "batch undo" (requirement 4) are structural.
     */
    data class RestorePlan(
        val batchId: String,
        val sourceKind: String,
        val fileName: String,
        val state: String,
        val counts: Map<String, Int>,
        val includesSensitive: Boolean,
        val createdAt: Long,
    ) {
        val countsJson: String
            get() = CanonicalJson.Obj(counts.mapValues { CanonicalJson.Int64(it.value.toLong()) }).render()

        /** The `import_batches` row this plan stages (the column set migration v1 reserved). */
        val importBatchRow: ImportBatchRow
            get() = ImportBatchRow(batchId, sourceKind, fileName, state, null, countsJson, createdAt)
    }

    data class ImportBatchRow(
        val id: String,
        val sourceKind: String,
        val fileName: String,
        val state: String,
        val chunkCursor: String?,
        val countsJson: String,
        val createdAt: Long,
    )

    /**
     * Build the staged plan from a preview + consent. The sensitive gate is applied here, once, by
     * zeroing the sensitive namespace counts when consent is withheld.
     */
    fun plan(
        preview: RestorePreview,
        consent: RestoreConsent,
        batchId: String,
        fileName: String,
        now: Long,
    ): RestorePlan {
        val counts = preview.namespaceCounts.toMutableMap()
        if (!consent.includeSensitive) {
            counts["logs.symptoms"] = 0
            counts["logs.adherence"] = 0
        }
        return RestorePlan(
            batchId = batchId,
            sourceKind = RESTORE_SOURCE_KIND,
            fileName = fileName,
            state = PREVIEWED_STATE,
            counts = counts,
            includesSensitive = consent.includeSensitive && preview.sensitivePresent,
            createdAt = now,
        )
    }

    // MARK: - DATA_DICTIONARY.md

    /**
     * The human-readable schema companion carried inside every backup. Static content (no
     * per-export values) so it contributes a stable checksum and leaks nothing about the person.
     * Mirror of iOS `dataDictionaryMarkdown` — the two must stay byte-identical.
     */
    fun dataDictionaryMarkdown(): String =
        """
        # BADAN backup — data dictionary

        This file travels inside every BADAN backup. It documents the layout of `bundle.json`
        (export schema ${ExportSchema.VERSION}) and the backup wrapper (backup schema $VERSION) so the
        data stays readable without the app.

        ## The backup

        A backup contains three files:

        - `backup_manifest.json` — backup schema version, creation time, originating app/platform,
          per-file SHA-256, and a summary of contents.
        - `DATA_DICTIONARY.md` — this file.
        - `bundle.json` — the full-scope data bundle plus a `config` section.

        A plaintext backup is a single JSON object whose `files` array carries the three files as
        text. An encrypted backup is a `badanenc-v1` container (AES-256-GCM, PBKDF2-HMAC-SHA256)
        holding the same three files; the passphrase covers the whole backup, not only sensitive
        records.

        ## bundle.json — data

        Raw and derived values are physically separate and never share a row shape:

        - `raw_samples` — point-in-time measurements, each with full provenance.
        - `interval_records` — aggregates over a window, with a 0–1 `coverage` fraction.
        - `sessions` — sleep and other non-workout episodes.
        - `workouts` — workout episodes; `hr_series_ref` is a query descriptor into `raw_samples`,
          not a copy of the series.
        - `derived_values` — engine-computed values; each carries `algorithm_id` and
          `algorithm_version`.
        - `baselines` — personal baselines with center/spread/band and `n_points`.
        - `logs.symptoms`, `logs.adherence` — the sensitive namespace (present only with consent).
        - `logs.workouts`, `logs.nutrition` — manual logs.
        - `logs.hydration` — the drink ledger: entries (with their revision chains), day summaries,
          goals, and referenced beverages. Carried whole in a backup, notes included.
        - `deletions` — tombstones (id + `deleted_at`) so a consumer can reconcile removals.

        Every timestamp is ISO-8601 with a numeric offset (never `Z`). Every value is in its
        canonical unit; `original_value`/`original_unit` record what the source reported.

        ## bundle.json — config

        - `export_templates` — saved export configurations.
        - `automation_schedules` — saved automation entries.
        - `customization` — presentation preferences (language, depth, units).
        - `export_destinations` — present in encrypted backups only, and always without any
          credential or credential reference. Destinations must be re-authorized after a restore.

        ## Restore

        Restoring stages the bundle as an import batch with a preview before anything is written,
        matches records you already have rather than duplicating them, and keeps the sensitive
        namespace behind its own consent toggle. A backup written by a newer version of BADAN than
        the one restoring it is refused rather than partially imported.
        """.trimIndent()

    // MARK: - Helpers

    fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    private fun compareUtf8(a: String, b: String): Int {
        val x = a.toByteArray(Charsets.UTF_8)
        val y = b.toByteArray(Charsets.UTF_8)
        var i = 0
        while (i < x.size && i < y.size) {
            val diff = (x[i].toInt() and 0xFF) - (y[i].toInt() and 0xFF)
            if (diff != 0) return diff
            i++
        }
        return x.size - y.size
    }

    /** `YYYYMMDD` in UTC, for the single-day range in a snapshot's file name. */
    private fun dayStamp(dateMillis: Long): String {
        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
        cal.timeInMillis = dateMillis
        return "%04d%02d%02d".format(
            cal.get(java.util.Calendar.YEAR),
            cal.get(java.util.Calendar.MONTH) + 1,
            cal.get(java.util.Calendar.DAY_OF_MONTH),
        )
    }
}
