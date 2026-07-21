package net.albayyan.badan.export

import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.hydration.BeverageDefinition
import net.albayyan.badan.domain.hydration.HydrationDailySummary
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportSuppressionCorrection
import net.albayyan.badan.domain.ExportTombstone
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.JournalEntry
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.WorkoutEntry
import java.io.OutputStream
import java.security.DigestOutputStream
import java.security.MessageDigest

/**
 * A JSON value the export writer controls end to end. Mirror of iOS `CanonicalJSON`.
 *
 * The bundle is built as one of these and rendered by [render], rather than being handed to
 * kotlinx-serialization, because schema 1.1.0 promises the same store and scope produce
 * byte-identical output on iOS and Android — and the two platforms' encoders do not agree on the
 * two things that decide those bytes. Key order is one (Swift's `.sortedKeys` sorts, kotlinx
 * emits in declaration order); number rendering is the worse one (Swift prints an integral
 * `Double` as `512`, Kotlin as `512.0`, and the two diverge again on magnitudes that tip into
 * scientific notation). Neither is reachable through the encoders' configuration, so the encoding
 * is done here where both platforms can be held to the same rules.
 *
 * This replaces the 0.1.0 approach of `@Serializable` mirrors of the domain: those emitted
 * camelCase keys and epoch-millis integers, which is the *storage* shape leaking into the public
 * face. 1.0.0's public face is snake_case with ISO-8601 offsets (§22.1) while storage is
 * unchanged — this type is the seam that lets those two differ without a migration.
 */
sealed interface CanonicalJson {
    data class Str(val value: String) : CanonicalJson
    data class Num(val value: Double) : CanonicalJson
    data class Int64(val value: Long) : CanonicalJson
    data class Bool(val value: Boolean) : CanonicalJson
    data object Null : CanonicalJson
    data class Arr(val values: List<CanonicalJson>) : CanonicalJson
    data class Obj(val members: Map<String, CanonicalJson>) : CanonicalJson

    /**
     * Renders compact JSON with no insignificant whitespace and no trailing newline — so the file
     * has exactly one line-ending policy (none) and cannot be reformatted by a checkout.
     */
    fun render(): String = StringBuilder().also { write(it) }.toString()

    fun write(out: StringBuilder) {
        when (this) {
            is Null -> out.append("null")
            is Bool -> out.append(if (value) "true" else "false")
            is Int64 -> out.append(value.toString())
            // JSON has no NaN or Infinity. Emitting `null` states "there is no number here",
            // which is true and parseable; emitting `NaN` would produce a file no conformant
            // reader accepts, and emitting 0 would invent a measurement.
            is Num -> out.append(if (value.isFinite()) CsvWriter.decimal(value) else "null")
            is Str -> writeString(value, out)
            is Arr -> {
                out.append("[")
                values.forEachIndexed { index, value ->
                    if (index > 0) out.append(",")
                    value.write(out)
                }
                out.append("]")
            }
            is Obj -> {
                out.append("{")
                // Sorted by UTF-8 bytes explicitly rather than by `String`'s default ordering,
                // which is locale- and normalization-sensitive on one platform and code-unit
                // ordering on the other. Every key in this schema is ASCII, so the three
                // orderings agree today — pinning it means they still agree the day a key is not.
                members.keys.sortedWith(UTF8_ORDER).forEachIndexed { index, key ->
                    if (index > 0) out.append(",")
                    writeString(key, out)
                    out.append(":")
                    members.getValue(key).write(out)
                }
                out.append("}")
            }
        }
    }

    companion object {
        /**
         * `null` in, [Null] out — so an optional domain field maps to an explicit JSON null
         * rather than a missing key. Present-with-null and absent are different claims to a
         * consumer, and the schema marks which fields are which; this keeps the choice deliberate
         * at each call site instead of falling out of whether someone wrote `?.let`.
         */
        fun str(value: String?): CanonicalJson = value?.let { Str(it) } ?: Null
        fun num(value: Double?): CanonicalJson = value?.let { Num(it) } ?: Null
        fun int(value: Int?): CanonicalJson = value?.let { Int64(it.toLong()) } ?: Null

        private val UTF8_ORDER = Comparator<String> { a, b ->
            val x = a.toByteArray(Charsets.UTF_8)
            val y = b.toByteArray(Charsets.UTF_8)
            var i = 0
            while (i < x.size && i < y.size) {
                val diff = (x[i].toInt() and 0xFF) - (y[i].toInt() and 0xFF)
                if (diff != 0) return@Comparator diff
                i++
            }
            x.size - y.size
        }

        /**
         * RFC 8259 string escaping, pinned.
         *
         * Only the two mandatory escapes (`"`, `\`) and the C0 control range are escaped; `/` is
         * left bare and non-ASCII is emitted as raw UTF-8. That last part is deliberate and is
         * why this does not defer to a platform encoder: Arabic content stays readable in an
         * exported file instead of becoming a wall of escape sequences, and the two platforms
         * cannot disagree about the case of the hex digits in an escape neither of them emits.
         */
        private fun writeString(value: String, out: StringBuilder) {
            out.append('"')
            for (ch in value) {
                when (ch) {
                    '"' -> out.append("\\\"")
                    '\\' -> out.append("\\\\")
                    '\n' -> out.append("\\n")
                    '\r' -> out.append("\\r")
                    '\t' -> out.append("\\t")
                    '\b' -> out.append("\\b")
                    '\u000C' -> out.append("\\f")
                    else ->
                        if (ch.code < 0x20) out.append(String.format(java.util.Locale.US, "\\u%04x", ch.code))
                        else out.append(ch)
                }
            }
            out.append('"')
        }
    }
}

/**
 * Serializes a full export as one self-describing JSON bundle at export schema 1.1.0 (execution
 * plan §22.2). Mirror of iOS `JSONBundleWriter`.
 *
 * Raw and derived are **physically separated** into distinct top-level arrays and never share a
 * row shape (I5), and the manifest travels inside the bundle so the artifact is reproducible from
 * its own description (D-8).
 *
 * Three shape decisions that are contract, not style:
 *
 * - **Workouts are parents, not rows.** A workout session is promoted out of `sessions` into
 *   `workouts` with `hr_series_ref` — a *query descriptor* into `raw_samples`, never a copy of
 *   the series. A promoted workout is not also left in `sessions`; one episode, one home. (This
 *   platform cannot emit `hr_series_ref` yet: `WorkoutDetail` has no `hrSeriesRef` field. That is
 *   a declared divergence, not an omission — see `packages/fixtures/export/README.md`.)
 * - **Routes are opt-in at the writer.** `route_ref` is omitted unless [includeRoutes] is passed,
 *   which defaults to false. Location gates independently of every other health class (plan
 *   §4.11), so the default has to be deny — a caller that forgets the flag leaks nothing.
 * - **Dictionaries are derived from the bundle's own contents.** Metric, source, algorithm and
 *   unit dictionaries are built from the records being written rather than from the registry, so
 *   the file stays self-describing when read years later on a machine that has neither the app
 *   nor `registry.json`.
 */
class JsonBundleWriter {

    /**
     * Deterministic UTF-8 bytes for the assembled bundle.
     *
     * The parameter list up to `nutrition` is unchanged from 0.1.0 so existing callers keep
     * compiling; everything after it is a §22.5/§22.2 field with a default that states the truth
     * for a caller that has not been migrated yet.
     */
    fun data(
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
        includeRoutes: Boolean = false,
        sampleDataRowCount: Int = 0,
        isDelta: Boolean = false,
        cursorBefore: Long? = null,
        cursorAfter: Long? = null,
        previousManifestSha: String? = null,
        additionalDeletions: List<ExportTombstone> = emptyList(),
        corrections: List<ExportSuppressionCorrection> = emptyList(),
        destination: Pair<String, String>? = null,
        config: Map<String, CanonicalJson>? = null,
        hydration: HydrationExportPayload? = null,
        hydrationRedaction: HydrationRedactionPolicy = HydrationRedactionPolicy.DEFAULT,
        journal: JournalExportPayload? = null,
    ): ByteArray = bundle(
        manifest, rawSamples, intervalRecords, sessions, derivedValues, baselines, symptoms,
        adherence, workouts, nutrition, includeRoutes, sampleDataRowCount, isDelta, cursorBefore,
        cursorAfter, previousManifestSha, additionalDeletions, corrections, destination, config,
        hydration, hydrationRedaction, journal,
    ).render().toByteArray(Charsets.UTF_8)

    /**
     * Streams the assembled bundle to [outputStream] through a digest so the checksum is computed
     * in the same pass. Takes ownership of [outputStream] and closes it.
     *
     * Unlike 0.1.0 this materializes the rendered string before writing. Canonical rendering has
     * to decide key order across a whole object before it can emit any of it, so a true streaming
     * encoder is not available here; the row-level objects were already fully built in memory
     * before (PERF-253 removed the *double* materialization, string + bytes, which this keeps
     * removed). If a large export regresses on memory, the fix is a chunked renderer that walks
     * the tree — not a return to a platform encoder, which would reintroduce the byte divergence
     * this whole type exists to close.
     */
    fun writeTo(
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
        outputStream: OutputStream,
        digest: MessageDigest,
        includeRoutes: Boolean = false,
        sampleDataRowCount: Int = 0,
    ) {
        val bytes = data(
            manifest, rawSamples, intervalRecords, sessions, derivedValues, baselines, symptoms,
            adherence, workouts, nutrition, includeRoutes, sampleDataRowCount,
        )
        DigestOutputStream(outputStream, digest).use { it.write(bytes) }
    }

    /** The assembled envelope, before rendering. Exposed so tests can assert structure. */
    fun bundle(
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
        includeRoutes: Boolean = false,
        sampleDataRowCount: Int = 0,
        isDelta: Boolean = false,
        cursorBefore: Long? = null,
        cursorAfter: Long? = null,
        previousManifestSha: String? = null,
        additionalDeletions: List<ExportTombstone> = emptyList(),
        corrections: List<ExportSuppressionCorrection> = emptyList(),
        destination: Pair<String, String>? = null,
        config: Map<String, CanonicalJson>? = null,
        hydration: HydrationExportPayload? = null,
        hydrationRedaction: HydrationRedactionPolicy = HydrationRedactionPolicy.DEFAULT,
        journal: JournalExportPayload? = null,
    ): CanonicalJson {
        // A workout session lives in `workouts`, not `sessions`. Split before anything counts
        // rows, so `row_counts` describes what was actually serialized rather than what was
        // handed in.
        val workoutSessions = sessions.filter { it.kind == SessionKind.WORKOUT }
        val sleepSessions = sessions.filter { it.kind != SessionKind.WORKOUT }

        // Absent, not empty: a null-or-empty hydration payload contributes NOTHING to the envelope —
        // no `logs.hydration` block and no `logs.hydration` row count. An empty `"hydration":[]` would
        // assert "the user logged no drinks", which the writer cannot claim when the module may simply
        // be hidden or unbuilt for this install. Mirrors the top-level `config` rule and keeps a
        // pre-hydration golden byte-identical without a fixture regeneration.
        val hydrationPayload = if (hydration != null && !hydration.isEmpty) hydration else null

        // Same absent-not-empty rule, for the same reason plus a sharper one (EPIC-29): the two
        // journal families are sensitive-plus, so an empty `"journal": []` in a default export would
        // both assert "this user logged no behaviors" AND advertise that the journal exists and was
        // consulted. Each key is added only when its OWN array has rows, so a user who declared a
        // travel status but tapped no chips gets `context_statuses` and no `journal`.
        val journalEntries = journal?.entries.orEmpty()
        val journalStatuses = journal?.statuses.orEmpty()

        val rowCounts: MutableMap<String, CanonicalJson> = linkedMapOf(
            "raw_samples" to CanonicalJson.Int64(rawSamples.size.toLong()),
            "interval_records" to CanonicalJson.Int64(intervalRecords.size.toLong()),
            "sessions" to CanonicalJson.Int64(sleepSessions.size.toLong()),
            "workouts" to CanonicalJson.Int64(workoutSessions.size.toLong()),
            "derived_values" to CanonicalJson.Int64(derivedValues.size.toLong()),
            "baselines" to CanonicalJson.Int64(baselines.size.toLong()),
            "logs.symptoms" to CanonicalJson.Int64(symptoms.size.toLong()),
            "logs.adherence" to CanonicalJson.Int64(adherence.size.toLong()),
            "logs.workouts" to CanonicalJson.Int64(workouts.size.toLong()),
            "logs.nutrition" to CanonicalJson.Int64(nutrition.size.toLong()),
        )
        if (hydrationPayload != null) rowCounts["logs.hydration"] = CanonicalJson.Int64(hydrationPayload.entries.size.toLong())
        if (journalEntries.isNotEmpty()) rowCounts["logs.journal"] = CanonicalJson.Int64(journalEntries.size.toLong())
        if (journalStatuses.isNotEmpty()) {
            rowCounts["logs.context_statuses"] = CanonicalJson.Int64(journalStatuses.size.toLong())
        }

        val members: LinkedHashMap<String, CanonicalJson> = linkedMapOf(
            "export_schema_version" to CanonicalJson.Str(ExportSchema.VERSION),
            "generated_at" to CanonicalJson.Str(utc(manifest.generatedAt)),
            "app" to CanonicalJson.Obj(
                mapOf(
                    "name" to CanonicalJson.Str("BADAN"),
                    "version" to CanonicalJson.Str(manifest.appVersion),
                    // The schema pins this to `ios`/`android`; the domain manifest stores the
                    // display spelling, so it is lowercased here rather than by editing a stored
                    // field that older persisted jobs also carry.
                    "platform" to CanonicalJson.Str(manifest.platform.lowercase()),
                ),
            ),
            "manifest" to manifest(
                manifest, rowCounts, includeRoutes, sampleDataRowCount, isDelta, cursorBefore,
                cursorAfter, previousManifestSha, destination,
            ),
            "dictionaries" to dictionaries(rawSamples, intervalRecords, derivedValues, baselines, sessions),
            "raw_samples" to CanonicalJson.Arr(rawSamples.map(::rawSample)),
            "interval_records" to CanonicalJson.Arr(intervalRecords.map(::intervalRecord)),
            "sessions" to CanonicalJson.Arr(sleepSessions.map(::session)),
            "workouts" to CanonicalJson.Arr(workoutSessions.map { workout(it, includeRoutes) }),
            "derived_values" to CanonicalJson.Arr(derivedValues.map(::derivedValue)),
            "baselines" to CanonicalJson.Arr(baselines.map(::baseline)),
            "logs" to CanonicalJson.Obj(
                logs(
                    symptoms, adherence, workouts, nutrition, hydrationPayload, hydrationRedaction,
                    journalEntries, journalStatuses,
                ),
            ),
            "deletions" to deletions(
                rawSamples, intervalRecords, sleepSessions, workoutSessions, derivedValues,
                symptoms, adherence, workouts, nutrition, additionalDeletions,
            ),
        )
        // Absent, not empty (§22.6): a delta run with no dedup flips carries NO `corrections` key at
        // all, exactly as `config`/`logs.hydration` stay absent when empty — so a non-delta bundle,
        // and the byte-pinned no-corrections golden, are untouched. `{"corrections": []}` would
        // assert "we checked and nothing flipped", a claim a full (non-delta) run cannot make.
        if (corrections.isNotEmpty()) members["corrections"] = corrections(corrections)
        // Absent, not empty: `{"export_templates": []}` would assert the user has no templates,
        // which is a claim this writer is in no position to make.
        if (config != null) members["config"] = CanonicalJson.Obj(config)
        return CanonicalJson.Obj(members)
    }

    // ===== Manifest (§22.5) =====

    private fun manifest(
        manifest: ExportManifest,
        rowCounts: Map<String, CanonicalJson>,
        includeRoutes: Boolean,
        sampleDataRowCount: Int,
        isDelta: Boolean,
        cursorBefore: Long?,
        cursorAfter: Long?,
        previousManifestSha: String?,
        destination: Pair<String, String>?,
    ): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "export_id" to CanonicalJson.Str(manifest.exportId),
            // Read from the constant, not from `manifest.schemaVersion`: this key describes the
            // SHAPE of the bytes around it, and the shape is decided by the code in this file. A
            // stored manifest can legitimately carry an older version — it records the run it
            // came from — but a 1.0.0 envelope labelled 0.1.0 would be a file that lies about how
            // to read it.
            "export_schema_version" to CanonicalJson.Str(ExportSchema.VERSION),
            "app_version" to CanonicalJson.Str(manifest.appVersion),
            "platform" to CanonicalJson.Str(manifest.platform),
            "generated_at" to CanonicalJson.Str(utc(manifest.generatedAt)),
            "scope" to scope(manifest.scope, includeRoutes),
            "date_range" to CanonicalJson.Str(manifest.dateRange),
            "display_language" to CanonicalJson.Str(manifest.displayLanguage),
            "unit_profile" to CanonicalJson.Str(manifest.unitProfile),
            "timezone_policy_note" to CanonicalJson.Str(manifest.timezonePolicy),
            "dedup_policy_note" to CanonicalJson.Str(manifest.dedupPolicy),
            "per_metric_row_counts" to CanonicalJson.Obj(
                manifest.perMetricRowCounts.mapValues { CanonicalJson.Int64(it.value.toLong()) },
            ),
            "row_counts" to CanonicalJson.Obj(rowCounts),
            "checksums" to CanonicalJson.Obj(manifest.checksums.mapValues { CanonicalJson.Str(it.value) }),
            "data_quality_note" to CanonicalJson.Str(manifest.dataQualityNote),
            // A writer parameter rather than a manifest field: this platform's `ExportManifest`
            // has no `sampleDataRowCount` (iOS's does). Defaulting to 0 without the caller
            // supplying it is the honest reading of "this writer was not told", and the gap is
            // closed by whoever wires `ExportRunner`, not by inventing a count here.
            "sample_data_row_count" to CanonicalJson.Int64(sampleDataRowCount.toLong()),
            "is_delta" to CanonicalJson.Bool(isDelta),
            "cursor_before" to (cursorBefore?.let { CanonicalJson.Str(utc(it)) } ?: CanonicalJson.Null),
            "cursor_after" to (cursorAfter?.let { CanonicalJson.Str(utc(it)) } ?: CanonicalJson.Null),
            "previous_manifest_sha" to CanonicalJson.str(previousManifestSha),
            // Name and kind only. A manifest travels with the file it describes, so anything
            // secret-bearing recorded here leaves the device the moment the export does.
            "destination" to (
                destination?.let {
                    CanonicalJson.Obj(
                        mapOf("name" to CanonicalJson.Str(it.first), "kind" to CanonicalJson.Str(it.second)),
                    )
                } ?: CanonicalJson.Null
                ),
            "encryption" to CanonicalJson.Str(if (manifest.encrypted) "badanenc-v1" else "none"),
        ),
    )

    private fun scope(scope: ExportScope, includeRoutes: Boolean): CanonicalJson {
        // A null list means "all" and an empty list means "none" — mapping the nullable to an
        // empty array here would turn an unrestricted export into one that claims to have
        // selected nothing.
        fun list(values: List<String>?): CanonicalJson =
            values?.let { CanonicalJson.Arr(it.map { v -> CanonicalJson.Str(v) }) } ?: CanonicalJson.Null
        return CanonicalJson.Obj(
            mapOf(
                "metric_ids" to list(scope.metricIds),
                "families" to list(scope.families),
                "start_date" to (scope.startDate?.let { CanonicalJson.Str(utc(it)) } ?: CanonicalJson.Null),
                "end_date" to (scope.endDate?.let { CanonicalJson.Str(utc(it)) } ?: CanonicalJson.Null),
                "source_ids" to list(scope.sourceIds),
                "include_raw" to CanonicalJson.Bool(scope.includeRaw),
                "include_derived" to CanonicalJson.Bool(scope.includeDerived),
                "include_suppressed" to CanonicalJson.Bool(scope.includeSuppressed),
                "include_sensitive" to CanonicalJson.Bool(scope.includeSensitive),
                // `ExportScope` has no route field yet (routes gate at the writer, EPIC-08);
                // echoing the flag actually used keeps the scope echo honest rather than
                // aspirational.
                "include_routes" to CanonicalJson.Bool(includeRoutes),
                "unit_profile" to CanonicalJson.Str(scope.unitProfile.code),
                "language" to CanonicalJson.Str(scope.language.code),
            ),
        )
    }

    // ===== Records =====

    private fun rawSample(sample: RawSample): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(sample.id),
            "metric_id" to CanonicalJson.Str(sample.metricId),
            // `value`/`canonical_value` carry the same number by construction: the bundle
            // publishes canonical units only and does not apply a display unit profile (that is
            // CSV's `value` column). Both keys are still emitted so a consumer can use one field
            // name across formats, and `original_*` is what the source actually said.
            "value" to CanonicalJson.Num(sample.value),
            "unit" to CanonicalJson.Str(sample.unit),
            "canonical_value" to CanonicalJson.Num(sample.value),
            "canonical_unit" to CanonicalJson.Str(sample.unit),
            "original_value" to CanonicalJson.Num(sample.originalValue),
            "original_unit" to CanonicalJson.Str(sample.originalUnit),
            "start_at" to CanonicalJson.Str(TimestampFormatting.string(sample.startAt, sample.tzId)),
            "end_at" to iso(sample.endAt, sample.tzId),
            "timezone" to CanonicalJson.Str(sample.tzId),
            "granularity" to CanonicalJson.Str(ExportSchema.Granularity.RAW.code),
            "aggregation_method" to CanonicalJson.Str(ExportSchema.AggregationMethod.NONE.code),
            "value_type" to CanonicalJson.Str("raw"),
            "is_derived" to CanonicalJson.Bool(false),
            "provenance" to provenance(sample.provenance, sample.tzId),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(sample.updatedAt, sample.tzId)),
            "origin_device_id" to CanonicalJson.Str(sample.originDeviceId),
            "deleted_at" to iso(sample.deletedAt, sample.tzId),
        ),
    )

    private fun intervalRecord(record: IntervalRecord): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(record.id),
            "metric_id" to CanonicalJson.Str(record.metricId),
            "value" to CanonicalJson.Num(record.value),
            "unit" to CanonicalJson.Str(record.unit),
            "canonical_value" to CanonicalJson.Num(record.value),
            "canonical_unit" to CanonicalJson.Str(record.unit),
            "start_at" to CanonicalJson.Str(TimestampFormatting.string(record.startAt, record.tzId)),
            "end_at" to CanonicalJson.Str(TimestampFormatting.string(record.endAt, record.tzId)),
            "timezone" to CanonicalJson.Str(record.tzId),
            "coverage" to CanonicalJson.Num(record.coverage),
            "granularity" to CanonicalJson.str(
                granularity(windowSeconds = (record.endAt - record.startAt) / 1000.0)?.code,
            ),
            "aggregation_method" to CanonicalJson.Str(aggregationMethod(record.aggregation).code),
            "value_type" to CanonicalJson.Str("aggregate"),
            "is_derived" to CanonicalJson.Bool(false),
            "provenance" to provenance(record.provenance, record.tzId),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(record.updatedAt, record.tzId)),
            "origin_device_id" to CanonicalJson.Str(record.originDeviceId),
            "deleted_at" to iso(record.deletedAt, record.tzId),
        ),
    )

    private fun session(session: Session): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(session.id),
            "kind" to CanonicalJson.Str(session.kind.code),
            "subtype" to CanonicalJson.str(session.subtype),
            "start_at" to CanonicalJson.Str(TimestampFormatting.string(session.startAt, session.tzId)),
            "end_at" to CanonicalJson.Str(TimestampFormatting.string(session.endAt, session.tzId)),
            "timezone" to CanonicalJson.Str(session.tzId),
            "local_night" to CanonicalJson.str(session.localNight),
            "detail" to CanonicalJson.Obj(
                mapOf(
                    "merged_from" to CanonicalJson.Arr(session.detail.mergedFrom.map { CanonicalJson.Str(it) }),
                    "time_asleep_seconds" to CanonicalJson.num(session.detail.timeAsleepSeconds),
                    "time_in_bed_seconds" to CanonicalJson.num(session.detail.timeInBedSeconds),
                    "stage_summary_seconds" to CanonicalJson.Obj(
                        session.detail.stageSummarySeconds.mapValues { CanonicalJson.Num(it.value) },
                    ),
                ),
            ),
            "value_type" to CanonicalJson.Str("raw"),
            "is_derived" to CanonicalJson.Bool(false),
            "provenance" to provenance(session.provenance, session.tzId),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(session.updatedAt, session.tzId)),
            "origin_device_id" to CanonicalJson.Str(session.originDeviceId),
            "deleted_at" to iso(session.deletedAt, session.tzId),
        ),
    )

    private fun workout(session: Session, includeRoutes: Boolean): CanonicalJson {
        val detail = session.detail.workout
        val totals = linkedMapOf<String, CanonicalJson>()
        // Absent stays absent. "0 kJ" and "not recorded" are different claims and only one of
        // them is true, so an unreported total contributes no key at all.
        //
        // `energy_kj`, not `energy_kcal`: this platform's `WorkoutTotals` stores kilojoules while
        // iOS stores kilocalories. The key names the unit rather than a conversion being applied
        // here, because converting would put float residue into a record whose entire job is to
        // preserve what the source said. Declared as a divergence in
        // packages/fixtures/export/README.md; the fix is a domain change, not a writer change.
        detail?.totals?.energyKj?.let { totals["energy_kj"] = CanonicalJson.Num(it) }
        detail?.totals?.distanceM?.let { totals["distance_m"] = CanonicalJson.Num(it) }
        detail?.totals?.avgHrBpm?.let { totals["avg_hr"] = CanonicalJson.Num(it) }
        detail?.totals?.maxHrBpm?.let { totals["max_hr"] = CanonicalJson.Num(it) }
        detail?.totals?.elevationGainM?.let { totals["elevation_gain_m"] = CanonicalJson.Num(it) }

        val members: LinkedHashMap<String, CanonicalJson> = linkedMapOf(
            "record_id" to CanonicalJson.Str(session.id),
            // `subtype` is the fallback only because a session written before EPIC-03's typed
            // detail existed has no `workout` payload; a missing activity type is recorded as
            // "unknown" rather than guessed from duration or metric mix.
            "activity_type" to CanonicalJson.Str(detail?.activityType ?: session.subtype ?: "unknown"),
            "start_at" to CanonicalJson.Str(TimestampFormatting.string(session.startAt, session.tzId)),
            "end_at" to CanonicalJson.Str(TimestampFormatting.string(session.endAt, session.tzId)),
            "timezone" to CanonicalJson.Str(session.tzId),
            "local_night" to CanonicalJson.str(session.localNight),
            "totals" to CanonicalJson.Obj(totals),
            "source_workout_id" to CanonicalJson.str(detail?.sourceWorkoutId),
            "detail_version" to CanonicalJson.str(detail?.version),
            "value_type" to CanonicalJson.Str("raw"),
            "is_derived" to CanonicalJson.Bool(false),
            "provenance" to provenance(session.provenance, session.tzId),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(session.updatedAt, session.tzId)),
            "origin_device_id" to CanonicalJson.Str(session.originDeviceId),
            "deleted_at" to iso(session.deletedAt, session.tzId),
        )
        // Default-deny. Without the explicit opt-in the key is absent, so even the existence of a
        // GPS trace is not disclosed by a Quick Export.
        if (includeRoutes) {
            detail?.routeRef?.let { members["route_ref"] = CanonicalJson.Str("route_$it.gpx") }
        }
        // `hr_series_ref` is deliberately not emitted: WorkoutDetail on this platform has no
        // hrSeriesRef field to read one from. Fabricating `{"metric_id": "heart.hr"}` would
        // assert a linkage BADAN never recorded on this device.
        return CanonicalJson.Obj(members)
    }

    private fun derivedValue(value: DerivedValue): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(value.id),
            "metric_id" to CanonicalJson.Str(value.metricId),
            "value" to CanonicalJson.Num(value.value),
            "unit" to CanonicalJson.Str(value.unit),
            "period_key" to CanonicalJson.Str(value.periodKey),
            "granularity" to CanonicalJson.str(granularity(periodKey = value.periodKey)?.code),
            // Not "mean": an algorithm output is not an aggregation of like readings, and saying
            // otherwise would misdescribe how the number was produced. The composition is
            // published under `algorithm_id` in docs/algorithms/.
            "aggregation_method" to CanonicalJson.Str(ExportSchema.AggregationMethod.NONE.code),
            "value_type" to CanonicalJson.Str("derived"),
            "is_derived" to CanonicalJson.Bool(true),
            "confidence" to CanonicalJson.num(value.confidence),
            "provisional" to CanonicalJson.Bool(value.provisional),
            "algorithm_id" to CanonicalJson.Str(value.algorithmId),
            "algorithm_version" to CanonicalJson.Str(value.algorithmVersion),
            "input_manifest_ref" to CanonicalJson.str(value.inputManifestId),
            // Derived values have no measurement timezone of their own, so their timestamps
            // render at +00:00. The period they describe is in `period_key`, which is already
            // expressed in the user's local calendar.
            "computed_at" to CanonicalJson.Str(utc(value.computedAt)),
            "updated_at" to CanonicalJson.Str(utc(value.updatedAt)),
            "origin_device_id" to CanonicalJson.Str(value.originDeviceId),
            "deleted_at" to (value.deletedAt?.let { CanonicalJson.Str(utc(it)) } ?: CanonicalJson.Null),
        ),
    )

    private fun baseline(baseline: Baseline): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(baseline.id),
            "metric_id" to CanonicalJson.Str(baseline.metricId),
            "unit" to CanonicalJson.Str(baseline.unit),
            "covariate_context" to CanonicalJson.Str(baseline.covariateContext),
            "window_days" to CanonicalJson.Int64(baseline.windowDays.toLong()),
            "method" to CanonicalJson.Str(baseline.method.code),
            "center" to CanonicalJson.Num(baseline.center),
            "spread" to CanonicalJson.Num(baseline.spread),
            "band_low" to CanonicalJson.Num(baseline.bandLow),
            "band_high" to CanonicalJson.Num(baseline.bandHigh),
            "n_points" to CanonicalJson.Int64(baseline.nPoints.toLong()),
            "provisional" to CanonicalJson.Bool(baseline.provisional),
            "algorithm_version" to CanonicalJson.Str(baseline.algorithmVersion),
            "valid_from" to CanonicalJson.Str(utc(baseline.validFrom)),
            "computed_at" to CanonicalJson.Str(utc(baseline.computedAt)),
            "value_type" to CanonicalJson.Str("derived"),
            "is_derived" to CanonicalJson.Bool(true),
        ),
    )

    // ===== Logs =====

    /**
     * The `logs` sub-object. Symptoms/adherence/workouts/nutrition are always present. `hydration` is
     * the exception: added ONLY when a non-empty payload is supplied, so a build without the module
     * (or an export whose scope caught no drinks) produces the exact bytes it did before EPIC-38.
     * When present it carries its own redaction manifest (§7A.1).
     */
    private fun logs(
        symptoms: List<SymptomEntry>, adherence: List<AdherenceEvent>, workouts: List<WorkoutEntry>,
        nutrition: List<NutritionEntry>, hydration: HydrationExportPayload?, hydrationRedaction: HydrationRedactionPolicy,
        journalEntries: List<JournalEntry> = emptyList(),
        contextStatuses: List<ContextStatus> = emptyList(),
    ): Map<String, CanonicalJson> {
        val members: LinkedHashMap<String, CanonicalJson> = linkedMapOf(
            "symptoms" to CanonicalJson.Arr(symptoms.map(::symptom)),
            "adherence" to CanonicalJson.Arr(adherence.map(::adherence)),
            "workouts" to CanonicalJson.Arr(workouts.map(::workoutLog)),
            "nutrition" to CanonicalJson.Arr(nutrition.map(::nutrition)),
        )
        if (hydration != null) members["hydration"] = hydrationLog(hydration, hydrationRedaction)
        // EPIC-29: same absent-when-empty rule as hydration, each keyed off its own array — these
        // are sensitive-plus, so an empty array in a default export would both make a claim about
        // the user's behavior log and disclose that the log was read at all.
        if (journalEntries.isNotEmpty()) members["journal"] = CanonicalJson.Arr(journalEntries.map(::journalEntry))
        if (contextStatuses.isNotEmpty()) {
            members["context_statuses"] = CanonicalJson.Arr(contextStatuses.map(::contextStatus))
        }
        return members
    }

    // ===== logs.journal / logs.context_statuses (EPIC-29, §9.9 / §9.10) =====
    // Byte-equivalent to iOS `JournalExportJSON`. Reuses this class's provenance/timestamp
    // rendering so a journal entry's `provenance` block is byte-identical to a raw sample's.

    /**
     * One behavior tag.
     *
     * `value`/`unit` are null for a boolean tag rather than coerced to 1/"bool": the bundle should
     * say what the row says, and a boolean tag asserts "this happened", not "this happened once".
     * `value_kind` is what tells a reader which of the three shapes to expect.
     *
     * `recalled` is emitted beside the two timestamps it comes from, so a consumer can see an entry
     * was logged after the fact without re-implementing the comparison — and can still check it,
     * because `occurred_at` and the full provenance (carrying `recorded_at`) are both right there.
     * It is DISCLOSURE, not a discount: a recalled entry counts exactly like a live one.
     */
    private fun journalEntry(e: JournalEntry): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(e.id),
            "behavior_id" to CanonicalJson.str(e.behaviorId),
            "custom_label" to CanonicalJson.str(e.customLabel),
            "value_kind" to CanonicalJson.Str(e.valueKind.code),
            "value" to CanonicalJson.num(e.value),
            "unit" to CanonicalJson.str(e.unit),
            "occurred_at" to CanonicalJson.Str(TimestampFormatting.string(e.occurredAt, e.tzId)),
            "timezone" to CanonicalJson.Str(e.tzId),
            "recalled" to CanonicalJson.Bool(e.isRecalled),
            "note" to CanonicalJson.str(e.note),
            "provenance" to provenance(e.provenance, e.tzId),
            "value_type" to CanonicalJson.Str("raw"),
            "is_derived" to CanonicalJson.Bool(false),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(e.updatedAt, e.tzId)),
            "origin_device_id" to CanonicalJson.Str(e.originDeviceId),
            "deleted_at" to iso(e.deletedAt, e.tzId),
        ),
    )

    /**
     * One declared interval.
     *
     * `end_at` is null exactly when the status is still open, and that null is the fact — an export
     * must not close an interval the user never closed by substituting "now" or the export
     * timestamp, which would put an end date the user never declared into a file they may hand to
     * someone else.
     *
     * No confidence, ceiling or adjustment is serialized: a status annotates how a value should be
     * READ (§9.10) and never alters one, so the artifact carries the user's declaration and nothing
     * computed from it.
     */
    private fun contextStatus(s: ContextStatus): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(s.id),
            "status_id" to CanonicalJson.str(s.statusId),
            "custom_label" to CanonicalJson.str(s.customLabel),
            "start_at" to CanonicalJson.Str(TimestampFormatting.string(s.startAt, s.tzId)),
            "end_at" to iso(s.endAt, s.tzId),
            "open_ended" to CanonicalJson.Bool(s.isOpenEnded),
            "timezone" to CanonicalJson.Str(s.tzId),
            "note" to CanonicalJson.str(s.note),
            "provenance" to provenance(s.provenance, s.tzId),
            "value_type" to CanonicalJson.Str("raw"),
            "is_derived" to CanonicalJson.Bool(false),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(s.updatedAt, s.tzId)),
            "origin_device_id" to CanonicalJson.Str(s.originDeviceId),
            "deleted_at" to iso(s.deletedAt, s.tzId),
        ),
    )

    // ===== logs.hydration (EPIC-38, §9.14 / §7A.1) =====
    // Reuses this class's own provenance/timestamp rendering so a hydration entry's `provenance`
    // block is byte-identical to a raw sample's, and its redaction manifest byte-matches the one
    // HydrationCsvWriter writes. Redaction is structural: the default policy withholds `note` (the
    // key is absent, not blanked). Byte-equivalent to iOS `HydrationExportJSON`.

    private fun hydrationLog(payload: HydrationExportPayload, policy: HydrationRedactionPolicy): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "redaction" to HydrationExportJson.redaction(policy),
            "entries" to CanonicalJson.Arr(payload.entries.map { hydrationEntry(it, policy) }),
            "summaries" to CanonicalJson.Arr(payload.summaries.map(::hydrationSummary)),
            "goals" to CanonicalJson.Arr(payload.goals.map(::hydrationGoal)),
            "beverages" to CanonicalJson.Arr(payload.beverages.map(::hydrationBeverage)),
            "sources" to hydrationSources(payload.entries),
        ),
    )

    private fun hydrationEntry(e: HydrationEntry, policy: HydrationRedactionPolicy): CanonicalJson {
        val members: LinkedHashMap<String, CanonicalJson> = linkedMapOf(
            "record_id" to CanonicalJson.Str(e.id),
            "original_id" to CanonicalJson.Str(e.originalId),
            "supersedes" to CanonicalJson.str(e.supersedes),
            "revision" to CanonicalJson.Int64(e.revision.toLong()),
            "volume_ml" to CanonicalJson.Num(e.volumeMl),
            "canonical_unit" to CanonicalJson.Str("mL"),
            "fluid_type" to CanonicalJson.Str(e.fluidType),
            "beverage_id" to CanonicalJson.str(e.beverageId),
            "container_id" to CanonicalJson.str(e.containerId),
            "occurred_at" to CanonicalJson.Str(TimestampFormatting.string(e.occurredAt, e.tzId)),
            "timezone" to CanonicalJson.Str(e.tzId),
            "value_type" to CanonicalJson.Str("raw"),
            "is_derived" to CanonicalJson.Bool(false),
            "provenance" to provenance(e.provenance, e.tzId),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(e.updatedAt, e.tzId)),
            "origin_device_id" to CanonicalJson.Str(e.originDeviceId),
            "deleted_at" to (e.deletedAt?.let { CanonicalJson.Str(TimestampFormatting.string(it, e.tzId)) } ?: CanonicalJson.Null),
        )
        if (policy.includeNotes) members["note"] = CanonicalJson.str(e.note)
        return CanonicalJson.Obj(members)
    }

    private fun hydrationSummary(s: HydrationDailySummary): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "day_key" to CanonicalJson.Str(s.dayKey),
            "timezone" to CanonicalJson.Str(s.tzId),
            "manual_ml" to CanonicalJson.Num(s.manualMl),
            "imported_ml" to CanonicalJson.Num(s.importedMl),
            "estimated_ml" to CanonicalJson.Num(s.estimatedMl),
            "total_ml" to CanonicalJson.Num(s.totalMl),
            "entry_count" to CanonicalJson.Int64(s.entryCount.toLong()),
            "goal_kind" to CanonicalJson.Str(s.goalKind.code),
            "goal_target_ml" to CanonicalJson.num(s.goalTargetMl),
            // Null, never 0, for a no-goal day — a percentage of nothing is the framing §7A.1 rejects.
            "goal_progress_pct" to CanonicalJson.num(s.goalProgressPct),
            "value_type" to CanonicalJson.Str("derived"),
            "is_derived" to CanonicalJson.Bool(true),
            "updated_at" to CanonicalJson.Str(utc(s.updatedAt)),
            "origin_device_id" to CanonicalJson.Str(s.originDeviceId),
        ),
    )

    private fun hydrationGoal(g: HydrationGoal): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "goal_id" to CanonicalJson.Str(g.id),
            "kind" to CanonicalJson.Str(g.kind.code),
            // Null target is the equal-status no-goal, not a missing value.
            "target_ml" to CanonicalJson.num(g.targetMl),
            "day_type" to CanonicalJson.str(g.dayType),
            "active" to CanonicalJson.Bool(g.active),
            "created_at" to CanonicalJson.Str(utc(g.createdAt)),
        ),
    )

    private fun hydrationBeverage(b: BeverageDefinition): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "beverage_id" to CanonicalJson.Str(b.id),
            "name_en" to CanonicalJson.Str(b.nameEn),
            "name_ar" to CanonicalJson.Str(b.nameAr),
            "fluid_type" to CanonicalJson.Str(b.fluidType),
            "default_volume_ml" to CanonicalJson.num(b.defaultVolumeMl),
            "is_builtin" to CanonicalJson.Bool(b.isBuiltin),
            // Display metadata only — carried so a reader sees the catalog fact, never read into a
            // hydration total or a "net hydration" multiplier (§7A.1 Reject).
            "caffeine_mg_per_100ml" to CanonicalJson.num(b.caffeineMgPer100ml),
            "alcohol_pct" to CanonicalJson.num(b.alcoholPct),
            "electrolyte_note" to CanonicalJson.str(b.electrolyteNote),
        ),
    )

    private fun hydrationSources(entries: List<HydrationEntry>): CanonicalJson {
        val paths = HashMap<String, MutableSet<String>>()
        val counts = HashMap<String, Int>()
        for (e in entries) {
            paths.getOrPut(e.provenance.sourceId) { mutableSetOf() }.add(e.provenance.ingestionPath.code)
            counts[e.provenance.sourceId] = (counts[e.provenance.sourceId] ?: 0) + 1
        }
        val rows = paths.keys.sorted().map { sourceId ->
            CanonicalJson.Obj(
                mapOf(
                    "source_app" to CanonicalJson.Str(sourceId),
                    "ingestion_paths" to CanonicalJson.Arr(paths[sourceId]!!.sorted().map { CanonicalJson.Str(it) }),
                    "entry_count" to CanonicalJson.Int64((counts[sourceId] ?: 0).toLong()),
                ),
            )
        }
        return CanonicalJson.Arr(rows)
    }

    private fun symptom(entry: SymptomEntry): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(entry.id),
            "symptom_id" to CanonicalJson.str(entry.symptomId),
            "custom_label" to CanonicalJson.str(entry.customLabel),
            "severity" to CanonicalJson.Int64(entry.severity.toLong()),
            "occurred_at" to CanonicalJson.Str(TimestampFormatting.string(entry.occurredAt, entry.tzId)),
            "timezone" to CanonicalJson.Str(entry.tzId),
            "duration_seconds" to CanonicalJson.num(entry.durationSeconds),
            "body_location" to CanonicalJson.str(entry.bodyLocation),
            "triggers" to CanonicalJson.Arr(entry.triggers.map { CanonicalJson.Str(it) }),
            "note" to CanonicalJson.str(entry.note),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(entry.updatedAt, entry.tzId)),
            "origin_device_id" to CanonicalJson.Str(entry.originDeviceId),
            "deleted_at" to iso(entry.deletedAt, entry.tzId),
        ),
    )

    private fun adherence(event: AdherenceEvent): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(event.id),
            "regimen_id" to CanonicalJson.Str(event.regimenId),
            "kind" to CanonicalJson.Str(event.kind.code),
            "scheduled_for" to iso(event.scheduledFor, event.tzId),
            "occurred_at" to CanonicalJson.Str(TimestampFormatting.string(event.occurredAt, event.tzId)),
            "timezone" to CanonicalJson.Str(event.tzId),
            "skip_reason" to CanonicalJson.str(event.skipReason?.code),
            "skip_note" to CanonicalJson.str(event.skipNote),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(event.updatedAt, event.tzId)),
            "origin_device_id" to CanonicalJson.Str(event.originDeviceId),
            "deleted_at" to iso(event.deletedAt, event.tzId),
        ),
    )

    private fun workoutLog(entry: WorkoutEntry): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(entry.id),
            "activity_type" to CanonicalJson.Str(entry.activityType),
            "start_at" to CanonicalJson.Str(TimestampFormatting.string(entry.startAt, entry.tzId)),
            "end_at" to CanonicalJson.Str(TimestampFormatting.string(entry.endAt, entry.tzId)),
            "timezone" to CanonicalJson.Str(entry.tzId),
            "energy_kcal" to CanonicalJson.num(entry.energyKcal),
            "distance_m" to CanonicalJson.num(entry.distanceM),
            "avg_hr" to CanonicalJson.num(entry.avgHr),
            "max_hr" to CanonicalJson.num(entry.maxHr),
            "perceived_effort" to CanonicalJson.int(entry.perceivedEffort),
            "note" to CanonicalJson.str(entry.note),
            "ingestion_path" to CanonicalJson.Str(entry.ingestionPath.code),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(entry.updatedAt, entry.tzId)),
            "origin_device_id" to CanonicalJson.Str(entry.originDeviceId),
            "deleted_at" to iso(entry.deletedAt, entry.tzId),
        ),
    )

    private fun nutrition(entry: NutritionEntry): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "record_id" to CanonicalJson.Str(entry.id),
            "description" to CanonicalJson.Str(entry.description),
            "meal_type" to CanonicalJson.Str(entry.mealType.code),
            "energy_kcal" to CanonicalJson.num(entry.energyKcal),
            "protein_g" to CanonicalJson.num(entry.proteinG),
            "carbs_g" to CanonicalJson.num(entry.carbsG),
            "fat_g" to CanonicalJson.num(entry.fatG),
            "fiber_g" to CanonicalJson.num(entry.fiberG),
            "water_ml" to CanonicalJson.num(entry.waterMl),
            "caffeine_mg" to CanonicalJson.num(entry.caffeineMg),
            "low_detail" to CanonicalJson.Bool(entry.lowDetail),
            "occurred_at" to CanonicalJson.Str(TimestampFormatting.string(entry.occurredAt, entry.tzId)),
            "timezone" to CanonicalJson.Str(entry.tzId),
            "note" to CanonicalJson.str(entry.note),
            "updated_at" to CanonicalJson.Str(TimestampFormatting.string(entry.updatedAt, entry.tzId)),
            "origin_device_id" to CanonicalJson.Str(entry.originDeviceId),
            "deleted_at" to iso(entry.deletedAt, entry.tzId),
        ),
    )

    // ===== Provenance =====

    private fun provenance(provenance: Provenance, tzId: String): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            // `source_app`/`source_device` rather than the domain's `sourceId`/`deviceId`, so the
            // JSON names match the CSV columns describing the same two facts.
            "source_app" to CanonicalJson.Str(provenance.sourceId),
            "source_device" to CanonicalJson.str(provenance.deviceId),
            "ingestion_path" to CanonicalJson.Str(provenance.ingestionPath.code),
            "external_id" to CanonicalJson.str(provenance.externalId),
            "import_batch_id" to CanonicalJson.str(provenance.importBatchId),
            "measured_at" to CanonicalJson.Str(
                TimestampFormatting.string(provenance.measuredAt, provenance.measuredTimezone),
            ),
            "measured_timezone" to CanonicalJson.Str(provenance.measuredTimezone),
            "recorded_at" to CanonicalJson.Str(TimestampFormatting.string(provenance.recordedAt, tzId)),
            "ingested_at" to CanonicalJson.Str(TimestampFormatting.string(provenance.ingestedAt, tzId)),
            "algorithm_version_id" to CanonicalJson.str(provenance.algorithmVersionId),
            "quality_flags" to CanonicalJson.Arr(provenance.qualityFlags.map { CanonicalJson.Str(it.code) }),
            "suppressed_by" to CanonicalJson.str(provenance.suppressedBy),
        ),
    )

    // ===== Deletions (§22.6) =====

    /**
     * `additional` (§22.6) is the delta path's tombstone slice: rows soft-deleted since the cursor
     * that are NOT in the data arrays (a delta gathers only live rows, so a removal would otherwise
     * be invisible). The two sources are unioned and the whole array is sorted by `record_id`, so
     * the output is deterministic regardless of gather order and identical across platforms — the
     * no-op case (a single row-derived tombstone, no `additional`) leaves the byte-pinned golden
     * unchanged because sorting one element is the identity. Mirror of iOS `deletions`.
     *
     * `record_id` alone is a TOTAL order here (unlike [corrections], which needs a tiebreaker): ids
     * are ULIDs unique across every table (I8), and the two sources cannot collide because a delta
     * gathers live rows only (`deleted_at IS NULL`) while `additional` is tombstones only.
     */
    private fun deletions(
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sleepSessions: List<Session>,
        workoutSessions: List<Session>,
        derivedValues: List<DerivedValue>,
        symptoms: List<SymptomEntry>,
        adherence: List<AdherenceEvent>,
        workoutLogs: List<WorkoutEntry>,
        nutrition: List<NutritionEntry>,
        additional: List<ExportTombstone> = emptyList(),
    ): CanonicalJson {
        val entries = mutableListOf<Pair<String, CanonicalJson>>()
        fun add(recordId: String, entity: String, deletedAt: Long?, tzId: String) {
            if (deletedAt == null) return
            entries.add(
                recordId to CanonicalJson.Obj(
                    mapOf(
                        "record_id" to CanonicalJson.Str(recordId),
                        "entity" to CanonicalJson.Str(entity),
                        "deleted_at" to CanonicalJson.Str(TimestampFormatting.string(deletedAt, tzId)),
                    ),
                ),
            )
        }
        rawSamples.forEach { add(it.id, "raw_sample", it.deletedAt, it.tzId) }
        intervalRecords.forEach { add(it.id, "interval_record", it.deletedAt, it.tzId) }
        sleepSessions.forEach { add(it.id, "session", it.deletedAt, it.tzId) }
        workoutSessions.forEach { add(it.id, "workout", it.deletedAt, it.tzId) }
        derivedValues.forEach { add(it.id, "derived_value", it.deletedAt, "UTC") }
        symptoms.forEach { add(it.id, "symptom", it.deletedAt, it.tzId) }
        adherence.forEach { add(it.id, "adherence", it.deletedAt, it.tzId) }
        workoutLogs.forEach { add(it.id, "workout_log", it.deletedAt, it.tzId) }
        nutrition.forEach { add(it.id, "nutrition", it.deletedAt, it.tzId) }
        additional.forEach { add(it.recordId, it.entity, it.deletedAt, it.tzId) }
        return CanonicalJson.Arr(entries.sortedBy { it.first }.map { it.second })
    }

    /**
     * The `corrections[]` section (§22.6): suppression flips since the cursor.
     *
     * Ordering is [ExportSuppressionCorrection.exportSorted] — the ONE comparator every format
     * uses, so this array and `corrections.csv` (the CSV delta's twin table, written by
     * [ExportDeltaCsvWriter]) list the same flips in the same sequence. Its doc explains why the
     * order is a total one rather than `record_id` alone.
     *
     * A null `suppressedBy` renders as JSON `null` — the record's suppression was CLEARED (it wins
     * again) — never as an empty string, so a consumer can tell "no longer suppressed" from
     * "suppressed by <id>". Mirror of iOS `corrections`.
     */
    private fun corrections(corrections: List<ExportSuppressionCorrection>): CanonicalJson =
        CanonicalJson.Arr(
            ExportSuppressionCorrection.exportSorted(corrections).map { c ->
                CanonicalJson.Obj(
                    mapOf(
                        "record_id" to CanonicalJson.Str(c.recordId),
                        "suppressed_by" to CanonicalJson.str(c.suppressedBy),
                        "changed_at" to CanonicalJson.Str(TimestampFormatting.string(c.changedAt, "UTC")),
                    ),
                )
            },
        )

    // ===== Dictionaries =====

    /**
     * Built from the records being written, not from `registry.json`, so the artifact stays
     * self-describing on a machine that has neither BADAN nor the contract files. Every array is
     * sorted by its own id: an unordered dictionary would make two byte-identical data sets
     * produce two different files.
     */
    private fun dictionaries(
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
        sessions: List<Session>,
    ): CanonicalJson {
        val metricUnits = linkedMapOf<String, String>()
        val metricArrays = linkedMapOf<String, MutableSet<String>>()
        fun note(metricId: String, unit: String, array: String) {
            metricUnits[metricId] = unit
            metricArrays.getOrPut(metricId) { mutableSetOf() }.add(array)
        }
        rawSamples.forEach { note(it.metricId, it.unit, "raw_samples") }
        intervalRecords.forEach { note(it.metricId, it.unit, "interval_records") }
        derivedValues.forEach { note(it.metricId, it.unit, "derived_values") }
        baselines.forEach { note(it.metricId, it.unit, "baselines") }

        val metrics = metricUnits.keys.sorted().map { metricId ->
            CanonicalJson.Obj(
                mapOf(
                    "metric_id" to CanonicalJson.Str(metricId),
                    "canonical_unit" to CanonicalJson.Str(metricUnits.getValue(metricId)),
                    "appears_in" to CanonicalJson.Arr(
                        metricArrays.getValue(metricId).sorted().map { CanonicalJson.Str(it) },
                    ),
                ),
            )
        }

        val devices = linkedMapOf<String, MutableSet<String>>()
        val paths = linkedMapOf<String, MutableSet<String>>()
        fun noteSource(provenance: Provenance) {
            provenance.deviceId?.let { devices.getOrPut(provenance.sourceId) { mutableSetOf() }.add(it) }
            paths.getOrPut(provenance.sourceId) { mutableSetOf() }.add(provenance.ingestionPath.code)
        }
        rawSamples.forEach { noteSource(it.provenance) }
        intervalRecords.forEach { noteSource(it.provenance) }
        sessions.forEach { noteSource(it.provenance) }

        val sources = paths.keys.sorted().map { sourceId ->
            CanonicalJson.Obj(
                mapOf(
                    "source_app" to CanonicalJson.Str(sourceId),
                    "devices" to CanonicalJson.Arr(
                        (devices[sourceId] ?: emptySet<String>()).sorted().map { CanonicalJson.Str(it) },
                    ),
                    "ingestion_paths" to CanonicalJson.Arr(
                        paths.getValue(sourceId).sorted().map { CanonicalJson.Str(it) },
                    ),
                ),
            )
        }

        // Two versions of one algorithm in one bundle is normal, not a conflict: derived values
        // append and never overwrite (I2), so a recomputation leaves both rows in place.
        val algorithmVersions = linkedMapOf<String, MutableSet<String>>()
        derivedValues.forEach {
            algorithmVersions.getOrPut(it.algorithmId) { mutableSetOf() }.add(it.algorithmVersion)
        }
        baselines.forEach {
            algorithmVersions.getOrPut("baseline." + it.method.code) { mutableSetOf() }.add(it.algorithmVersion)
        }
        val algorithms = algorithmVersions.keys.sorted().map { algorithmId ->
            CanonicalJson.Obj(
                mapOf(
                    "algorithm_id" to CanonicalJson.Str(algorithmId),
                    "versions" to CanonicalJson.Arr(
                        algorithmVersions.getValue(algorithmId).sorted().map { CanonicalJson.Str(it) },
                    ),
                ),
            )
        }

        val unitMetrics = linkedMapOf<String, MutableSet<String>>()
        metricUnits.forEach { (metricId, unit) -> unitMetrics.getOrPut(unit) { mutableSetOf() }.add(metricId) }
        val units = unitMetrics.keys.sorted().map { unit ->
            CanonicalJson.Obj(
                mapOf(
                    "unit" to CanonicalJson.Str(unit),
                    "metric_ids" to CanonicalJson.Arr(
                        unitMetrics.getValue(unit).sorted().map { CanonicalJson.Str(it) },
                    ),
                ),
            )
        }

        return CanonicalJson.Obj(
            mapOf(
                "metrics" to CanonicalJson.Arr(metrics),
                "sources" to CanonicalJson.Arr(sources),
                "algorithms" to CanonicalJson.Arr(algorithms),
                "units" to CanonicalJson.Arr(units),
            ),
        )
    }

    private fun iso(millis: Long?, tzId: String): CanonicalJson =
        millis?.let { CanonicalJson.Str(TimestampFormatting.string(it, tzId)) } ?: CanonicalJson.Null

    /**
     * For instants that belong to no single measurement timezone (manifest generation, derived
     * values, baselines). Still a numeric offset, never `Z`.
     */
    private fun utc(millis: Long): String = TimestampFormatting.string(millis, "UTC")

    companion object {
        /**
         * The whole calendar unit an interval covers, or null when it covers none.
         *
         * Exact matches only. A classifier with ranges would label a 20-minute window "hour",
         * which is precisely the kind of confident-and-wrong claim `granularity` exists to
         * replace. The 82800/90000 and 601200/608400 entries are the DST-short and DST-long
         * spellings of a day and a week — a local day that crosses a transition is still a day,
         * and dropping those would make the column go blank twice a year in half the world's
         * timezones.
         */
        fun granularity(windowSeconds: Double): ExportSchema.Granularity? = when (windowSeconds) {
            1.0 -> ExportSchema.Granularity.SECOND
            60.0 -> ExportSchema.Granularity.MINUTE
            3600.0 -> ExportSchema.Granularity.HOUR
            82800.0, 86400.0, 90000.0 -> ExportSchema.Granularity.DAY
            601200.0, 604800.0, 608400.0 -> ExportSchema.Granularity.WEEK
            else -> null
        }

        /**
         * A derived value's granularity comes from its period key's prefix, which is what the
         * derivation engine actually keyed the value by — not from a duration, which a derived
         * value does not have. `session:` keys have no calendar unit and yield null.
         */
        fun granularity(periodKey: String): ExportSchema.Granularity? =
            when (periodKey.substringBefore(':', missingDelimiterValue = "")) {
                "day" -> ExportSchema.Granularity.DAY
                "week" -> ExportSchema.Granularity.WEEK
                "month" -> ExportSchema.Granularity.MONTH
                "year" -> ExportSchema.Granularity.YEAR
                else -> null
            }

        /**
         * The domain's [Aggregation] is a strict subset of the schema's `aggregation_method`, so
         * this total mapping never needs a fallback — `none` and `min_avg_max` exist in the
         * schema for row kinds [IntervalRecord] does not cover.
         */
        fun aggregationMethod(aggregation: Aggregation): ExportSchema.AggregationMethod = when (aggregation) {
            Aggregation.SUM -> ExportSchema.AggregationMethod.SUM
            Aggregation.MEAN -> ExportSchema.AggregationMethod.MEAN
            Aggregation.MIN -> ExportSchema.AggregationMethod.MIN
            Aggregation.MAX -> ExportSchema.AggregationMethod.MAX
            Aggregation.DURATION -> ExportSchema.AggregationMethod.DURATION
            Aggregation.LATEST -> ExportSchema.AggregationMethod.LATEST
        }
    }
}
