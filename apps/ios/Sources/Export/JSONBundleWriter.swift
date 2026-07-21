import Foundation

/// A JSON value the export writer controls end to end.
///
/// The bundle is built as one of these and rendered by `CanonicalJSON.render`, rather than being
/// handed to `JSONEncoder`, because schema 1.0.0 promises the same store and scope produce
/// byte-identical output on iOS and Android — and `JSONEncoder`/kotlinx do not agree on the two
/// things that decide those bytes. Key order is one (`.sortedKeys` sorts, kotlinx emits in
/// declaration order); number rendering is the worse one (Swift prints an integral `Double` as
/// `512`, Kotlin as `512.0`, and the two diverge again on magnitudes that tip into scientific
/// notation). Neither is reachable through the encoders' configuration, so the encoding is done
/// here where both platforms can be held to the same rules.
///
/// This replaces the 0.1.0 approach of `Codable` structs mirroring the domain: those emitted
/// camelCase keys and epoch-millis integers, which is the *storage* shape leaking into the
/// public face. 1.0.0's public face is snake_case with ISO-8601 offsets (§22.1) while storage is
/// unchanged — this type is the seam that lets those two differ without a migration.
indirect enum CanonicalJSON {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([CanonicalJSON])
    case object([String: CanonicalJSON])

    /// `nil` in, `.null` out — so an optional domain field maps to an explicit JSON null rather
    /// than a missing key. Present-with-null and absent are different claims to a consumer, and
    /// the schema marks which fields are which; this keeps the choice deliberate at each call
    /// site instead of falling out of whether someone wrote `if let`.
    static func string(nullable value: String?) -> CanonicalJSON {
        guard let value else { return .null }
        return .string(value)
    }
    static func number(nullable value: Double?) -> CanonicalJSON {
        guard let value else { return .null }
        return .number(value)
    }
    static func integer(nullable value: Int?) -> CanonicalJSON {
        guard let value else { return .null }
        return .integer(value)
    }

    /// Renders compact JSON with no insignificant whitespace and no trailing newline — so the
    /// file has exactly one line-ending policy (none) and cannot be reformatted by a checkout.
    func render() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .integer(let value):
            out += String(value)
        case .number(let value):
            // JSON has no NaN or Infinity. Emitting `null` states "there is no number here",
            // which is true and parseable; emitting `nan` would produce a file no conformant
            // reader accepts, and emitting 0 would invent a measurement.
            out += value.isFinite ? CSVWriter.decimal(value) : "null"
        case .string(let value):
            Self.writeString(value, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            // Sorted by UTF-8 bytes explicitly rather than by `String`'s default ordering, which
            // is locale- and normalization-sensitive on one platform and code-unit ordering on
            // the other. Every key in this schema is ASCII, so the three orderings agree today —
            // pinning it means they still agree the day a key is not.
            let keys = members.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                members[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    /// RFC 8259 string escaping, pinned.
    ///
    /// Only the two mandatory escapes (`"`, `\`) and the C0 control range are escaped; `/` is
    /// left bare and non-ASCII is emitted as raw UTF-8. That last part is deliberate and is why
    /// this does not defer to a platform encoder: Arabic content stays readable in an exported
    /// file instead of becoming a wall of `ا` sequences, and the two platforms cannot
    /// disagree about the case of the hex digits in an escape neither of them emits.
    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// Serializes a full export as one self-describing JSON bundle at export schema 1.0.0
/// (execution plan §22.2).
///
/// Raw and derived are **physically separated** into distinct top-level arrays and never share a
/// row shape (I5), and the manifest travels inside the bundle so the artifact is reproducible
/// from its own description (D-8).
///
/// Three shape decisions that are contract, not style:
///
/// - **Workouts are parents, not rows.** A workout session is promoted out of `sessions` into
///   `workouts` with `hr_series_ref` — a *query descriptor* into `raw_samples`, never a copy of
///   the series. Duplicating a few thousand HR samples per workout would double the store's
///   largest array to answer a question the reader can already answer by filtering on the
///   window. A promoted workout is not also left in `sessions`; one episode, one home.
/// - **Routes are opt-in at the writer.** `route_ref` is omitted unless `includeRoutes` is
///   passed, which defaults to false. Location gates independently of every other health class
///   (plan §4.11), so the default has to be deny — a caller that forgets the flag leaks nothing.
/// - **Dictionaries are derived from the bundle's own contents.** Metric, source, algorithm and
///   unit dictionaries are built from the records being written rather than from the registry,
///   so the file stays self-describing when read years later on a machine that has neither the
///   app nor `registry.json`.
struct JSONBundleWriter {

    init() {}

    // MARK: - Entry points

    /// Deterministic bytes for the assembled bundle.
    ///
    /// The parameter list up to `nutrition` is unchanged from 0.1.0 so existing callers keep
    /// compiling; everything after it is a §22.5/§22.2 field with a default that states the
    /// truth for a caller that has not been migrated yet (no delta, no cursors, no chained
    /// manifest, no named destination, no routes, no config echo).
    func data(
        manifest: ExportManifest,
        rawSamples: [RawSample],
        intervalRecords: [IntervalRecord],
        sessions: [Session],
        derivedValues: [DerivedValue],
        baselines: [Baseline],
        symptoms: [SymptomEntry],
        adherence: [AdherenceEvent],
        workouts: [WorkoutEntry],
        nutrition: [NutritionEntry],
        includeRoutes: Bool = false,
        isDelta: Bool = false,
        cursorBefore: Date? = nil,
        cursorAfter: Date? = nil,
        previousManifestSha: String? = nil,
        destination: (name: String, kind: String)? = nil,
        config: [String: CanonicalJSON]? = nil,
        hydration: HydrationExportPayload? = nil,
        hydrationRedaction: HydrationRedactionPolicy = .default
    ) throws -> Data {
        let json = bundle(
            manifest: manifest, rawSamples: rawSamples, intervalRecords: intervalRecords,
            sessions: sessions, derivedValues: derivedValues, baselines: baselines,
            symptoms: symptoms, adherence: adherence, workouts: workouts, nutrition: nutrition,
            includeRoutes: includeRoutes, isDelta: isDelta, cursorBefore: cursorBefore,
            cursorAfter: cursorAfter, previousManifestSha: previousManifestSha,
            destination: destination, config: config,
            hydration: hydration, hydrationRedaction: hydrationRedaction
        )
        return Data(json.render().utf8)
    }

    /// The assembled envelope, before rendering. Exposed so tests can assert structure without
    /// re-parsing the bytes they are also asserting.
    func bundle(
        manifest: ExportManifest,
        rawSamples: [RawSample],
        intervalRecords: [IntervalRecord],
        sessions: [Session],
        derivedValues: [DerivedValue],
        baselines: [Baseline],
        symptoms: [SymptomEntry],
        adherence: [AdherenceEvent],
        workouts: [WorkoutEntry],
        nutrition: [NutritionEntry],
        includeRoutes: Bool = false,
        isDelta: Bool = false,
        cursorBefore: Date? = nil,
        cursorAfter: Date? = nil,
        previousManifestSha: String? = nil,
        destination: (name: String, kind: String)? = nil,
        config: [String: CanonicalJSON]? = nil,
        hydration: HydrationExportPayload? = nil,
        hydrationRedaction: HydrationRedactionPolicy = .default
    ) -> CanonicalJSON {
        // A workout session lives in `workouts`, not `sessions`. Split before anything counts
        // rows, so `row_counts` describes what was actually serialized rather than what was
        // handed in.
        let workoutSessions = sessions.filter { $0.kind == .workout }
        let sleepSessions = sessions.filter { $0.kind != .workout }

        // Absent, not empty: a nil-or-empty hydration payload contributes NOTHING to the envelope —
        // no `logs.hydration` block and no `logs.hydration` row count. An empty `"hydration":[]`
        // would assert "the user logged no drinks", which the writer cannot claim when the module may
        // simply be hidden or unbuilt for this install. This mirrors the top-level `config` rule and
        // is what keeps a pre-hydration golden byte-identical without a fixture regeneration.
        let hydrationPayload = (hydration?.isEmpty == false) ? hydration : nil

        var rowCounts: [String: CanonicalJSON] = [
            "raw_samples": .integer(rawSamples.count),
            "interval_records": .integer(intervalRecords.count),
            "sessions": .integer(sleepSessions.count),
            "workouts": .integer(workoutSessions.count),
            "derived_values": .integer(derivedValues.count),
            "baselines": .integer(baselines.count),
            "logs.symptoms": .integer(symptoms.count),
            "logs.adherence": .integer(adherence.count),
            "logs.workouts": .integer(workouts.count),
            "logs.nutrition": .integer(nutrition.count)
        ]
        if let hydrationPayload { rowCounts["logs.hydration"] = .integer(hydrationPayload.entries.count) }

        var members: [String: CanonicalJSON] = [
            "export_schema_version": .string(ExportSchema.version),
            "generated_at": .string(Self.utc(manifest.generatedAt)),
            "app": .object([
                "name": .string("BADAN"),
                "version": .string(manifest.appVersion),
                // The schema pins this to `ios`/`android`; the domain manifest stores the
                // display spelling ("iOS"), so it is lowercased here rather than by editing a
                // stored field that older persisted jobs also carry.
                "platform": .string(manifest.platform.lowercased())
            ]),
            "manifest": Self.manifest(manifest, rowCounts: rowCounts, includeRoutes: includeRoutes,
                                      isDelta: isDelta, cursorBefore: cursorBefore,
                                      cursorAfter: cursorAfter,
                                      previousManifestSha: previousManifestSha,
                                      destination: destination),
            "dictionaries": Self.dictionaries(rawSamples: rawSamples, intervalRecords: intervalRecords,
                                              derivedValues: derivedValues, baselines: baselines,
                                              sessions: sessions),
            "raw_samples": .array(rawSamples.map(Self.rawSample)),
            "interval_records": .array(intervalRecords.map(Self.intervalRecord)),
            "sessions": .array(sleepSessions.map(Self.session)),
            "workouts": .array(workoutSessions.map { Self.workout($0, includeRoutes: includeRoutes) }),
            "derived_values": .array(derivedValues.map(Self.derivedValue)),
            "baselines": .array(baselines.map(Self.baseline)),
            "logs": .object(Self.logs(symptoms: symptoms, adherence: adherence, workouts: workouts,
                                      nutrition: nutrition, hydration: hydrationPayload,
                                      hydrationRedaction: hydrationRedaction)),
            "deletions": Self.deletions(rawSamples: rawSamples, intervalRecords: intervalRecords,
                                        sleepSessions: sleepSessions, workoutSessions: workoutSessions,
                                        derivedValues: derivedValues, symptoms: symptoms,
                                        adherence: adherence, workoutLogs: workouts,
                                        nutrition: nutrition)
        ]
        // Absent, not empty: `{"export_templates": []}` would assert the user has no templates,
        // which is a claim this writer is in no position to make.
        if let config { members["config"] = .object(config) }
        return .object(members)
    }

    // MARK: - Manifest (§22.5)

    private static func manifest(_ manifest: ExportManifest, rowCounts: [String: CanonicalJSON],
                                 includeRoutes: Bool, isDelta: Bool, cursorBefore: Date?,
                                 cursorAfter: Date?, previousManifestSha: String?,
                                 destination: (name: String, kind: String)?) -> CanonicalJSON {
        .object([
            "export_id": .string(manifest.exportId),
            // Read from the constant, not from `manifest.schemaVersion`: this key describes the
            // SHAPE of the bytes around it, and the shape is decided by the code in this file.
            // A stored manifest can legitimately carry an older version — it records the run it
            // came from — but a 1.0.0 envelope labelled 0.1.0 would be a file that lies about
            // how to read it.
            "export_schema_version": .string(ExportSchema.version),
            "app_version": .string(manifest.appVersion),
            "platform": .string(manifest.platform),
            "generated_at": .string(utc(manifest.generatedAt)),
            "scope": scope(manifest.scope, includeRoutes: includeRoutes),
            "date_range": .string(manifest.dateRange),
            "display_language": .string(manifest.displayLanguage),
            "unit_profile": .string(manifest.unitProfile),
            "timezone_policy_note": .string(manifest.timezonePolicy),
            "dedup_policy_note": .string(manifest.dedupPolicy),
            "per_metric_row_counts": .object(manifest.perMetricRowCounts.mapValues { CanonicalJSON.integer($0) }),
            "row_counts": .object(rowCounts),
            "checksums": .object(manifest.checksums.mapValues { CanonicalJSON.string($0) }),
            "data_quality_note": .string(manifest.dataQualityNote),
            "sample_data_row_count": .integer(manifest.sampleDataRowCount),
            "is_delta": .bool(isDelta),
            "cursor_before": cursorBefore.map { CanonicalJSON.string(utc($0)) } ?? .null,
            "cursor_after": cursorAfter.map { CanonicalJSON.string(utc($0)) } ?? .null,
            "previous_manifest_sha": .string(nullable: previousManifestSha),
            // Name and kind only. A manifest travels with the file it describes, so anything
            // secret-bearing recorded here leaves the device the moment the export does.
            "destination": destination.map {
                CanonicalJSON.object(["name": .string($0.name), "kind": .string($0.kind)])
            } ?? .null,
            "encryption": .string(manifest.encrypted ? "badanenc-v1" : "none")
        ])
    }

    private static func scope(_ scope: ExportScope, includeRoutes: Bool) -> CanonicalJSON {
        // A null list means "all" and an empty list means "none" — mapping the optional to `[]`
        // here would turn an unrestricted export into one that claims to have selected nothing.
        func list(_ values: [String]?) -> CanonicalJSON {
            values.map { CanonicalJSON.array($0.map { CanonicalJSON.string($0) }) } ?? .null
        }
        return .object([
            "metric_ids": list(scope.metricIds),
            "families": list(scope.families),
            "start_date": scope.startDate.map { CanonicalJSON.string(utc($0)) } ?? .null,
            "end_date": scope.endDate.map { CanonicalJSON.string(utc($0)) } ?? .null,
            "source_ids": list(scope.sourceIds),
            "include_raw": .bool(scope.includeRaw),
            "include_derived": .bool(scope.includeDerived),
            "include_suppressed": .bool(scope.includeSuppressed),
            "include_sensitive": .bool(scope.includeSensitive),
            // `ExportScope` has no route field yet (routes gate at the writer, EPIC-08); echoing
            // the flag actually used keeps the scope echo honest rather than aspirational.
            "include_routes": .bool(includeRoutes),
            "unit_profile": .string(scope.unitProfile.rawValue),
            "language": .string(scope.language.rawValue)
        ])
    }

    // MARK: - Records

    private static func rawSample(_ sample: RawSample) -> CanonicalJSON {
        .object([
            "record_id": .string(sample.id),
            "metric_id": .string(sample.metricId),
            // `value`/`canonical_value` carry the same number by construction: the bundle
            // publishes canonical units only and does not apply a display unit profile (that is
            // CSV's `value` column). Both keys are still emitted so a consumer can use one
            // field name across formats, and `original_*` is what the source actually said.
            "value": .number(sample.value),
            "unit": .string(sample.unit),
            "canonical_value": .number(sample.value),
            "canonical_unit": .string(sample.unit),
            "original_value": .number(sample.originalValue),
            "original_unit": .string(sample.originalUnit),
            "start_at": .string(TimestampFormatting.string(sample.startAt, tzId: sample.tzId)),
            "end_at": sample.endAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: sample.tzId)) } ?? .null,
            "timezone": .string(sample.tzId),
            "granularity": .string(ExportSchema.Granularity.raw.rawValue),
            "aggregation_method": .string(ExportSchema.AggregationMethod.none.rawValue),
            "value_type": .string("raw"),
            "is_derived": .bool(false),
            "provenance": provenance(sample.provenance, tzId: sample.tzId),
            "updated_at": .string(TimestampFormatting.string(sample.updatedAt, tzId: sample.tzId)),
            "origin_device_id": .string(sample.originDeviceId),
            "deleted_at": sample.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: sample.tzId)) } ?? .null
        ])
    }

    private static func intervalRecord(_ record: IntervalRecord) -> CanonicalJSON {
        .object([
            "record_id": .string(record.id),
            "metric_id": .string(record.metricId),
            "value": .number(record.value),
            "unit": .string(record.unit),
            "canonical_value": .number(record.value),
            "canonical_unit": .string(record.unit),
            "start_at": .string(TimestampFormatting.string(record.startAt, tzId: record.tzId)),
            "end_at": .string(TimestampFormatting.string(record.endAt, tzId: record.tzId)),
            "timezone": .string(record.tzId),
            "coverage": .number(record.coverage),
            "granularity": .string(nullable: granularity(windowSeconds: record.endAt.timeIntervalSince(record.startAt))?.rawValue),
            "aggregation_method": .string(aggregationMethod(record.aggregation).rawValue),
            "value_type": .string("aggregate"),
            "is_derived": .bool(false),
            "provenance": provenance(record.provenance, tzId: record.tzId),
            "updated_at": .string(TimestampFormatting.string(record.updatedAt, tzId: record.tzId)),
            "origin_device_id": .string(record.originDeviceId),
            "deleted_at": record.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: record.tzId)) } ?? .null
        ])
    }

    private static func session(_ session: Session) -> CanonicalJSON {
        .object([
            "record_id": .string(session.id),
            "kind": .string(session.kind.rawValue),
            "subtype": .string(nullable: session.subtype),
            "start_at": .string(TimestampFormatting.string(session.startAt, tzId: session.tzId)),
            "end_at": .string(TimestampFormatting.string(session.endAt, tzId: session.tzId)),
            "timezone": .string(session.tzId),
            "local_night": .string(nullable: session.localNight),
            "detail": .object([
                "merged_from": .array(session.detail.mergedFrom.map { CanonicalJSON.string($0) }),
                "time_asleep_seconds": .number(nullable: session.detail.timeAsleepSeconds),
                "time_in_bed_seconds": .number(nullable: session.detail.timeInBedSeconds),
                "stage_summary_seconds": .object(session.detail.stageSummarySeconds.mapValues { CanonicalJSON.number($0) })
            ]),
            "value_type": .string("raw"),
            "is_derived": .bool(false),
            "provenance": provenance(session.provenance, tzId: session.tzId),
            "updated_at": .string(TimestampFormatting.string(session.updatedAt, tzId: session.tzId)),
            "origin_device_id": .string(session.originDeviceId),
            "deleted_at": session.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: session.tzId)) } ?? .null
        ])
    }

    private static func workout(_ session: Session, includeRoutes: Bool) -> CanonicalJSON {
        let detail = session.detail.workout
        var totals: [String: CanonicalJSON] = [:]
        // Absent stays absent. "0 kcal" and "not recorded" are different claims and only one of
        // them is true, so an unreported total contributes no key at all.
        if let value = detail?.totals.energyKcal { totals["energy_kcal"] = .number(value) }
        if let value = detail?.totals.distanceMeters { totals["distance_m"] = .number(value) }
        if let value = detail?.totals.avgHeartRateBpm { totals["avg_hr"] = .number(value) }
        if let value = detail?.totals.maxHeartRateBpm { totals["max_hr"] = .number(value) }
        if let value = detail?.totals.elevationGainMeters { totals["elevation_gain_m"] = .number(value) }

        var members: [String: CanonicalJSON] = [
            "record_id": .string(session.id),
            // `subtype` is the fallback only because a session written before EPIC-03's typed
            // detail existed has no `workout` payload; a missing activity type is recorded as
            // "unknown" rather than guessed from duration or metric mix.
            "activity_type": .string(detail?.activityType ?? session.subtype ?? "unknown"),
            "start_at": .string(TimestampFormatting.string(session.startAt, tzId: session.tzId)),
            "end_at": .string(TimestampFormatting.string(session.endAt, tzId: session.tzId)),
            "timezone": .string(session.tzId),
            "local_night": .string(nullable: session.localNight),
            "totals": .object(totals),
            "source_workout_id": .string(nullable: detail?.sourceWorkoutUUID),
            // Rendered into the shared spelling both platforms publish. iOS stores the workout
            // detail version as an `Int` and Android as the string "workout.detail.v1"; they are
            // the same fact recorded two ways, so the contract picks one spelling and each
            // platform renders into it rather than the bundle exposing which platform wrote it.
            "detail_version": .string(nullable: detail.map { "workout.detail.v\($0.schemaVersion)" }),
            "value_type": .string("raw"),
            "is_derived": .bool(false),
            "provenance": provenance(session.provenance, tzId: session.tzId),
            "updated_at": .string(TimestampFormatting.string(session.updatedAt, tzId: session.tzId)),
            "origin_device_id": .string(session.originDeviceId),
            "deleted_at": session.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: session.tzId)) } ?? .null
        ]
        // A query descriptor, not a copy: metric id plus the window to filter `raw_samples` on.
        if let metricId = detail?.hrSeriesRef {
            members["hr_series_ref"] = .object([
                "metric_id": .string(metricId),
                "start_at": .string(TimestampFormatting.string(session.startAt, tzId: session.tzId)),
                "end_at": .string(TimestampFormatting.string(session.endAt, tzId: session.tzId))
            ])
        }
        // Default-deny. Without the explicit opt-in the key is absent, so even the existence of
        // a GPS trace is not disclosed by a Quick Export.
        if includeRoutes, let routeRef = detail?.routeRef {
            members["route_ref"] = .string("route_\(routeRef).gpx")
        }
        return .object(members)
    }

    private static func derivedValue(_ value: DerivedValue) -> CanonicalJSON {
        .object([
            "record_id": .string(value.id),
            "metric_id": .string(value.metricId),
            "value": .number(value.value),
            "unit": .string(value.unit),
            "period_key": .string(value.periodKey),
            "granularity": .string(nullable: granularity(periodKey: value.periodKey)?.rawValue),
            // Not "mean": an algorithm output is not an aggregation of like readings, and saying
            // otherwise would misdescribe how the number was produced. The composition is
            // published under `algorithm_id` in docs/algorithms/.
            "aggregation_method": .string(ExportSchema.AggregationMethod.none.rawValue),
            "value_type": .string("derived"),
            "is_derived": .bool(true),
            "confidence": .number(nullable: value.confidence),
            "provisional": .bool(value.provisional),
            "algorithm_id": .string(value.algorithmId),
            "algorithm_version": .string(value.algorithmVersion),
            "input_manifest_ref": .string(nullable: value.inputManifestId),
            // Derived values have no measurement timezone of their own, so their timestamps
            // render at +00:00. The period they describe is in `period_key`, which is already
            // expressed in the user's local calendar.
            "computed_at": .string(utc(value.computedAt)),
            "updated_at": .string(utc(value.updatedAt)),
            "origin_device_id": .string(value.originDeviceId),
            "deleted_at": value.deletedAt.map { CanonicalJSON.string(utc($0)) } ?? .null
        ])
    }

    private static func baseline(_ baseline: Baseline) -> CanonicalJSON {
        .object([
            "record_id": .string(baseline.id),
            "metric_id": .string(baseline.metricId),
            "unit": .string(baseline.unit),
            "covariate_context": .string(baseline.covariateContext),
            "window_days": .integer(baseline.windowDays),
            "method": .string(baseline.method.rawValue),
            "center": .number(baseline.center),
            "spread": .number(baseline.spread),
            "band_low": .number(baseline.bandLow),
            "band_high": .number(baseline.bandHigh),
            "n_points": .integer(baseline.nPoints),
            "provisional": .bool(baseline.provisional),
            "algorithm_version": .string(baseline.algorithmVersion),
            "valid_from": .string(utc(baseline.validFrom)),
            "computed_at": .string(utc(baseline.computedAt)),
            "value_type": .string("derived"),
            "is_derived": .bool(true)
        ])
    }

    // MARK: - Logs

    private static func symptom(_ entry: SymptomEntry) -> CanonicalJSON {
        .object([
            "record_id": .string(entry.id),
            "symptom_id": .string(nullable: entry.symptomId),
            "custom_label": .string(nullable: entry.customLabel),
            "severity": .integer(entry.severity),
            "occurred_at": .string(TimestampFormatting.string(entry.occurredAt, tzId: entry.tzId)),
            "timezone": .string(entry.tzId),
            "duration_seconds": .number(nullable: entry.durationSeconds),
            "body_location": .string(nullable: entry.bodyLocation),
            "triggers": .array(entry.triggers.map { CanonicalJSON.string($0) }),
            "note": .string(nullable: entry.note),
            "updated_at": .string(TimestampFormatting.string(entry.updatedAt, tzId: entry.tzId)),
            "origin_device_id": .string(entry.originDeviceId),
            "deleted_at": entry.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: entry.tzId)) } ?? .null
        ])
    }

    private static func adherence(_ event: AdherenceEvent) -> CanonicalJSON {
        .object([
            "record_id": .string(event.id),
            "regimen_id": .string(event.regimenId),
            "kind": .string(event.kind.rawValue),
            "scheduled_for": event.scheduledFor.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: event.tzId)) } ?? .null,
            "occurred_at": .string(TimestampFormatting.string(event.occurredAt, tzId: event.tzId)),
            "timezone": .string(event.tzId),
            "skip_reason": .string(nullable: event.skipReason?.rawValue),
            "skip_note": .string(nullable: event.skipNote),
            "updated_at": .string(TimestampFormatting.string(event.updatedAt, tzId: event.tzId)),
            "origin_device_id": .string(event.originDeviceId),
            "deleted_at": event.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: event.tzId)) } ?? .null
        ])
    }

    private static func workoutLog(_ entry: WorkoutEntry) -> CanonicalJSON {
        .object([
            "record_id": .string(entry.id),
            "activity_type": .string(entry.activityType),
            "start_at": .string(TimestampFormatting.string(entry.startAt, tzId: entry.tzId)),
            "end_at": .string(TimestampFormatting.string(entry.endAt, tzId: entry.tzId)),
            "timezone": .string(entry.tzId),
            "energy_kcal": .number(nullable: entry.energyKcal),
            "distance_m": .number(nullable: entry.distanceM),
            "avg_hr": .number(nullable: entry.avgHr),
            "max_hr": .number(nullable: entry.maxHr),
            "perceived_effort": .integer(nullable: entry.perceivedEffort),
            "note": .string(nullable: entry.note),
            "ingestion_path": .string(entry.ingestionPath.rawValue),
            "updated_at": .string(TimestampFormatting.string(entry.updatedAt, tzId: entry.tzId)),
            "origin_device_id": .string(entry.originDeviceId),
            "deleted_at": entry.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: entry.tzId)) } ?? .null
        ])
    }

    private static func nutrition(_ entry: NutritionEntry) -> CanonicalJSON {
        .object([
            "record_id": .string(entry.id),
            "description": .string(entry.description),
            "meal_type": .string(entry.mealType.rawValue),
            "energy_kcal": .number(nullable: entry.energyKcal),
            "protein_g": .number(nullable: entry.proteinG),
            "carbs_g": .number(nullable: entry.carbsG),
            "fat_g": .number(nullable: entry.fatG),
            "fiber_g": .number(nullable: entry.fiberG),
            "water_ml": .number(nullable: entry.waterMl),
            "caffeine_mg": .number(nullable: entry.caffeineMg),
            "low_detail": .bool(entry.lowDetail),
            "occurred_at": .string(TimestampFormatting.string(entry.occurredAt, tzId: entry.tzId)),
            "timezone": .string(entry.tzId),
            "note": .string(nullable: entry.note),
            "updated_at": .string(TimestampFormatting.string(entry.updatedAt, tzId: entry.tzId)),
            "origin_device_id": .string(entry.originDeviceId),
            "deleted_at": entry.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: entry.tzId)) } ?? .null
        ])
    }

    // MARK: - Logs

    /// The `logs` sub-object. Symptoms/adherence/workouts/nutrition are always present (an empty log
    /// family is a real claim — "no rows in scope" — for a family the app always tracks). `hydration`
    /// is the exception: it is added ONLY when a non-empty payload is supplied, so a build without the
    /// module, or an export whose scope caught no drinks, produces the exact bytes it did before
    /// EPIC-38. When present it carries its own redaction manifest (§7A.1).
    static func logs(symptoms: [SymptomEntry], adherence: [AdherenceEvent], workouts: [WorkoutEntry],
                     nutrition: [NutritionEntry], hydration: HydrationExportPayload?,
                     hydrationRedaction: HydrationRedactionPolicy) -> [String: CanonicalJSON] {
        var members: [String: CanonicalJSON] = [
            "symptoms": .array(symptoms.map(Self.symptom)),
            "adherence": .array(adherence.map(Self.adherence)),
            "workouts": .array(workouts.map(Self.workoutLog)),
            "nutrition": .array(nutrition.map(Self.nutrition))
        ]
        if let hydration { members["hydration"] = HydrationExportJSON.log(hydration, policy: hydrationRedaction) }
        return members
    }

    // MARK: - Provenance

    static func provenance(_ provenance: Provenance, tzId: String) -> CanonicalJSON {
        .object([
            // `source_app`/`source_device` rather than the domain's `sourceId`/`deviceId`, so the
            // JSON names match the CSV columns describing the same two facts.
            "source_app": .string(provenance.sourceId),
            "source_device": .string(nullable: provenance.deviceId),
            "ingestion_path": .string(provenance.ingestionPath.rawValue),
            "external_id": .string(nullable: provenance.externalId),
            "import_batch_id": .string(nullable: provenance.importBatchId),
            "measured_at": .string(TimestampFormatting.string(provenance.measuredAt, tzId: provenance.measuredTimezone)),
            "measured_timezone": .string(provenance.measuredTimezone),
            "recorded_at": .string(TimestampFormatting.string(provenance.recordedAt, tzId: tzId)),
            "ingested_at": .string(TimestampFormatting.string(provenance.ingestedAt, tzId: tzId)),
            "algorithm_version_id": .string(nullable: provenance.algorithmVersionId),
            "quality_flags": .array(provenance.qualityFlags.map { CanonicalJSON.string($0.rawValue) }),
            "suppressed_by": .string(nullable: provenance.suppressedBy)
        ])
    }

    // MARK: - Deletions (§22.6)

    private static func deletions(rawSamples: [RawSample], intervalRecords: [IntervalRecord],
                                  sleepSessions: [Session], workoutSessions: [Session],
                                  derivedValues: [DerivedValue], symptoms: [SymptomEntry],
                                  adherence: [AdherenceEvent], workoutLogs: [WorkoutEntry],
                                  nutrition: [NutritionEntry]) -> CanonicalJSON {
        var entries: [CanonicalJSON] = []
        func add(_ recordId: String, _ entity: String, _ deletedAt: Date?, tzId: String) {
            guard let deletedAt else { return }
            entries.append(.object([
                "record_id": .string(recordId),
                "entity": .string(entity),
                "deleted_at": .string(TimestampFormatting.string(deletedAt, tzId: tzId))
            ]))
        }
        for row in rawSamples { add(row.id, "raw_sample", row.deletedAt, tzId: row.tzId) }
        for row in intervalRecords { add(row.id, "interval_record", row.deletedAt, tzId: row.tzId) }
        for row in sleepSessions { add(row.id, "session", row.deletedAt, tzId: row.tzId) }
        for row in workoutSessions { add(row.id, "workout", row.deletedAt, tzId: row.tzId) }
        for row in derivedValues { add(row.id, "derived_value", row.deletedAt, tzId: "UTC") }
        for row in symptoms { add(row.id, "symptom", row.deletedAt, tzId: row.tzId) }
        for row in adherence { add(row.id, "adherence", row.deletedAt, tzId: row.tzId) }
        for row in workoutLogs { add(row.id, "workout_log", row.deletedAt, tzId: row.tzId) }
        for row in nutrition { add(row.id, "nutrition", row.deletedAt, tzId: row.tzId) }
        return .array(entries)
    }

    // MARK: - Dictionaries

    /// Built from the records being written, not from `registry.json`, so the artifact stays
    /// self-describing on a machine that has neither BADAN nor the contract files. Every array is
    /// sorted by its own id: an unordered dictionary would make two byte-identical data sets
    /// produce two different files.
    private static func dictionaries(rawSamples: [RawSample], intervalRecords: [IntervalRecord],
                                     derivedValues: [DerivedValue], baselines: [Baseline],
                                     sessions: [Session]) -> CanonicalJSON {
        var metricUnits: [String: String] = [:]
        var metricArrays: [String: Set<String>] = [:]
        func note(_ metricId: String, _ unit: String, _ array: String) {
            metricUnits[metricId] = unit
            metricArrays[metricId, default: []].insert(array)
        }
        for row in rawSamples { note(row.metricId, row.unit, "raw_samples") }
        for row in intervalRecords { note(row.metricId, row.unit, "interval_records") }
        for row in derivedValues { note(row.metricId, row.unit, "derived_values") }
        for row in baselines { note(row.metricId, row.unit, "baselines") }

        let metrics = metricUnits.keys.sorted().map { metricId in
            CanonicalJSON.object([
                "metric_id": .string(metricId),
                "canonical_unit": .string(metricUnits[metricId]!),
                "appears_in": .array(metricArrays[metricId]!.sorted().map { CanonicalJSON.string($0) })
            ])
        }

        var devices: [String: Set<String>] = [:]
        var paths: [String: Set<String>] = [:]
        func noteSource(_ provenance: Provenance) {
            if let device = provenance.deviceId { devices[provenance.sourceId, default: []].insert(device) }
            paths[provenance.sourceId, default: []].insert(provenance.ingestionPath.rawValue)
        }
        for row in rawSamples { noteSource(row.provenance) }
        for row in intervalRecords { noteSource(row.provenance) }
        for row in sessions { noteSource(row.provenance) }

        let sources = paths.keys.sorted().map { sourceId in
            CanonicalJSON.object([
                "source_app": .string(sourceId),
                "devices": .array((devices[sourceId] ?? []).sorted().map { CanonicalJSON.string($0) }),
                "ingestion_paths": .array(paths[sourceId]!.sorted().map { CanonicalJSON.string($0) })
            ])
        }

        // Two versions of one algorithm in one bundle is normal, not a conflict: derived values
        // append and never overwrite (I2), so a recomputation leaves both rows in place.
        var algorithmVersions: [String: Set<String>] = [:]
        for row in derivedValues { algorithmVersions[row.algorithmId, default: []].insert(row.algorithmVersion) }
        for row in baselines { algorithmVersions["baseline." + row.method.rawValue, default: []].insert(row.algorithmVersion) }
        let algorithms = algorithmVersions.keys.sorted().map { algorithmId in
            CanonicalJSON.object([
                "algorithm_id": .string(algorithmId),
                "versions": .array(algorithmVersions[algorithmId]!.sorted().map { CanonicalJSON.string($0) })
            ])
        }

        var unitMetrics: [String: Set<String>] = [:]
        for (metricId, unit) in metricUnits { unitMetrics[unit, default: []].insert(metricId) }
        let units = unitMetrics.keys.sorted().map { unit in
            CanonicalJSON.object([
                "unit": .string(unit),
                "metric_ids": .array(unitMetrics[unit]!.sorted().map { CanonicalJSON.string($0) })
            ])
        }

        return .object([
            "metrics": .array(metrics),
            "sources": .array(sources),
            "algorithms": .array(algorithms),
            "units": .array(units)
        ])
    }

    // MARK: - Granularity / aggregation derivation

    /// The whole calendar unit an interval covers, or `nil` when it covers none.
    ///
    /// Exact matches only. A classifier with ranges would label a 20-minute window "hour", which
    /// is precisely the kind of confident-and-wrong claim `granularity` exists to replace. The
    /// 82800/90000 and 601200/608400 entries are the DST-short and DST-long spellings of a day
    /// and a week — a local day that crosses a transition is still a day, and dropping those
    /// would make the column go blank twice a year in half the world's timezones.
    static func granularity(windowSeconds: Double) -> ExportSchema.Granularity? {
        switch windowSeconds {
        case 1: return .second
        case 60: return .minute
        case 3600: return .hour
        case 82800, 86400, 90000: return .day
        case 601200, 604800, 608400: return .week
        default: return nil
        }
    }

    /// A derived value's granularity comes from its period key's prefix, which is what the
    /// derivation engine actually keyed the value by — not from a duration, which a derived
    /// value does not have. `session:` keys have no calendar unit and yield `nil`.
    static func granularity(periodKey: String) -> ExportSchema.Granularity? {
        guard let separator = periodKey.firstIndex(of: ":") else { return nil }
        switch String(periodKey[periodKey.startIndex..<separator]) {
        case "day": return .day
        case "week": return .week
        case "month": return .month
        case "year": return .year
        default: return nil
        }
    }

    /// The domain's `Aggregation` is a strict subset of the schema's `aggregation_method`, so
    /// this total mapping never needs a fallback — `none` and `min_avg_max` exist in the schema
    /// for row kinds `IntervalRecord` does not cover.
    static func aggregationMethod(_ aggregation: Aggregation) -> ExportSchema.AggregationMethod {
        switch aggregation {
        case .sum: return .sum
        case .mean: return .mean
        case .min: return .min
        case .max: return .max
        case .duration: return .duration
        case .latest: return .latest
        }
    }

    /// For instants that belong to no single measurement timezone (manifest generation, derived
    /// values, baselines). Still a numeric offset, never `Z`.
    static func utc(_ date: Date) -> String {
        TimestampFormatting.string(date, tzId: "UTC")
    }
}

/// The `logs.hydration` serializer (EPIC-38, §9.14 / §7A.1). Kept adjacent to `JSONBundleWriter` so
/// it reuses the same `CanonicalJSON`, provenance rendering and timestamp formatting — a hydration
/// entry's `provenance` block is byte-identical to a raw sample's, and its redaction manifest byte-
/// matches the one `HydrationCSVWriter` writes.
///
/// REDACTION is structural: the default policy withholds `note` (the key is absent, not blanked) and
/// the manifest names every field a default file leaves out. The Android mirror
/// (`HydrationExportJson`) produces the same bytes from the same payload.
enum HydrationExportJSON {

    /// The full `logs.hydration` object: the redaction manifest first (so a reader knows what is
    /// missing before reading what is present), then the entries, day summaries, goals, referenced
    /// beverage catalog, and provenance sources.
    static func log(_ payload: HydrationExportPayload, policy: HydrationRedactionPolicy) -> CanonicalJSON {
        .object([
            "redaction": redaction(policy),
            "entries": .array(payload.entries.map { entry($0, policy: policy) }),
            "summaries": .array(payload.summaries.map(summary)),
            "goals": .array(payload.goals.map(goal)),
            "beverages": .array(payload.beverages.map(beverage)),
            "sources": sources(payload.entries)
        ])
    }

    /// The machine-readable statement of what a default hydration export excludes (§7A.1). Also
    /// emitted standalone by `HydrationCSVWriter.redactionManifest` — one renderer, identical bytes.
    static func redaction(_ policy: HydrationRedactionPolicy) -> CanonicalJSON {
        .object([
            "notes_included": .bool(policy.includeNotes),
            "excluded_by_default": .array(policy.excludedFields.map { CanonicalJSON.string($0) })
        ])
    }

    private static func entry(_ e: HydrationEntry, policy: HydrationRedactionPolicy) -> CanonicalJSON {
        var members: [String: CanonicalJSON] = [
            "record_id": .string(e.id),
            "original_id": .string(e.originalId),
            "supersedes": .string(nullable: e.supersedes),
            "revision": .integer(e.revision),
            "volume_ml": .number(e.volumeMl),
            "canonical_unit": .string("mL"),
            "fluid_type": .string(e.fluidType),
            "beverage_id": .string(nullable: e.beverageId),
            "container_id": .string(nullable: e.containerId),
            "occurred_at": .string(TimestampFormatting.string(e.occurredAt, tzId: e.tzId)),
            "timezone": .string(e.tzId),
            "value_type": .string("raw"),
            "is_derived": .bool(false),
            "provenance": JSONBundleWriter.provenance(e.provenance, tzId: e.tzId),
            "updated_at": .string(TimestampFormatting.string(e.updatedAt, tzId: e.tzId)),
            "origin_device_id": .string(e.originDeviceId),
            "deleted_at": e.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: e.tzId)) } ?? .null
        ]
        // Structural redaction: the note key exists only when explicitly opted in.
        if policy.includeNotes { members["note"] = .string(nullable: e.note) }
        return .object(members)
    }

    private static func summary(_ s: HydrationDailySummary) -> CanonicalJSON {
        .object([
            "day_key": .string(s.dayKey),
            "timezone": .string(s.tzId),
            "manual_ml": .number(s.manualMl),
            "imported_ml": .number(s.importedMl),
            "estimated_ml": .number(s.estimatedMl),
            "total_ml": .number(s.totalMl),
            "entry_count": .integer(s.entryCount),
            "goal_kind": .string(s.goalKind.rawValue),
            "goal_target_ml": .number(nullable: s.goalTargetMl),
            // Null, never 0, for a no-goal day — a percentage of nothing is the streak-guilt framing
            // §7A.1 rejects.
            "goal_progress_pct": .number(nullable: s.goalProgressPct),
            "value_type": .string("derived"),
            "is_derived": .bool(true),
            "updated_at": .string(JSONBundleWriter.utc(s.updatedAt)),
            "origin_device_id": .string(s.originDeviceId)
        ])
    }

    private static func goal(_ g: HydrationGoal) -> CanonicalJSON {
        .object([
            "goal_id": .string(g.id),
            "kind": .string(g.kind.rawValue),
            // Null target is the equal-status no-goal, not a missing value.
            "target_ml": .number(nullable: g.targetMl),
            "day_type": .string(nullable: g.dayType),
            "active": .bool(g.active),
            "created_at": .string(JSONBundleWriter.utc(g.createdAt))
        ])
    }

    private static func beverage(_ b: BeverageDefinition) -> CanonicalJSON {
        .object([
            "beverage_id": .string(b.id),
            "name_en": .string(b.nameEn),
            "name_ar": .string(b.nameAr),
            "fluid_type": .string(b.fluidType),
            "default_volume_ml": .number(nullable: b.defaultVolumeMl),
            "is_builtin": .bool(b.isBuiltin),
            // Display metadata only — carried so a reader sees the catalog fact, never read into a
            // hydration total or a "net hydration" multiplier (§7A.1 Reject).
            "caffeine_mg_per_100ml": .number(nullable: b.caffeineMgPer100ml),
            "alcohol_pct": .number(nullable: b.alcoholPct),
            "electrolyte_note": .string(nullable: b.electrolyteNote)
        ])
    }

    /// The provenance apps/paths the entries came from, aggregated and sorted — the hydration-scoped
    /// answer to "where did this come from" (I1), matching the CSV `hydration_sources.csv`.
    private static func sources(_ entries: [HydrationEntry]) -> CanonicalJSON {
        var paths: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for e in entries {
            paths[e.provenance.sourceId, default: []].insert(e.provenance.ingestionPath.rawValue)
            counts[e.provenance.sourceId, default: 0] += 1
        }
        let rows = paths.keys.sorted().map { sourceId in
            CanonicalJSON.object([
                "source_app": .string(sourceId),
                "ingestion_paths": .array(paths[sourceId]!.sorted().map { CanonicalJSON.string($0) }),
                "entry_count": .integer(counts[sourceId] ?? 0)
            ])
        }
        return .array(rows)
    }
}
