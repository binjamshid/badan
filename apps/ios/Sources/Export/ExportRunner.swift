import Foundation
import CryptoKit

/// Runs a fully offline export: gathers scoped records from the repositories, renders them
/// (CSV split into raw/derived files, or one JSON bundle), checksums every file, writes a
/// versioned manifest, and records the completed `ExportJob`. No networking or entitlement
/// imports live on this path — Foundation + CryptoKit only (D-8).
final class ExportRunner {

    /// The artifact produced by a run: the persisted job (with manifest), the written files,
    /// and the total exported record count.
    struct ExportResult {
        let job: ExportJob
        let fileURLs: [URL]
        let rowCount: Int
    }

    private let measurements: MeasurementRepository
    private let derivation: DerivationRepository
    private let logging: LoggingRepository
    private let exportJobs: ExportJobRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let appVersion: String
    private let deviceId: String

    init(measurements: MeasurementRepository, derivation: DerivationRepository,
         logging: LoggingRepository, exportJobs: ExportJobRepository,
         registry: MetricRegistry, clock: Clock, appVersion: String, deviceId: String) {
        self.measurements = measurements
        self.derivation = derivation
        self.logging = logging
        self.exportJobs = exportJobs
        self.registry = registry
        self.clock = clock
        self.appVersion = appVersion
        self.deviceId = deviceId
    }

    // MARK: - Entry point

    func run(scope: ExportScope, format: ExportFormat) throws -> ExportResult {
        // Best-effort housekeeping for folders orphaned by a past interrupted export (a crash
        // or force-quit mid-run never reaches the cleanup below) — never blocks this run
        // (EDGE-02c).
        sweepOrphanedExportFolders()

        let startedAt = clock.now()
        let exportId = ULID.newID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-\(exportId)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Record the attempt immediately (status .running) so a crash or memory-pressure
        // termination mid-export is diagnosable via `export_jobs` rather than the attempt
        // vanishing entirely; `insert` is an upsert keyed by `exportId`, so the same row is
        // updated to .completed/.failed below rather than duplicated (PERF-176).
        let runningJob = ExportJob(id: exportId, scope: scope, format: format, status: .running,
                                   outputPath: folder.path, startedAt: startedAt, createdAt: startedAt)
        try exportJobs.insert(runningJob)

        do {
            let ids = metricIdsInScope(scope)
            let rangeStart = scope.startDate ?? Date(timeIntervalSince1970: 0)
            let rangeEnd = scope.endDate ?? startedAt
            let wantRaw = scope.includeRaw

            // Snapshot-isolate the whole gather phase against a concurrent ingest (EDGE-03).
            // `measurements` and `derivation` share the same main-DB `SQLiteConnection` (see
            // `AppEnvironment` init), and `SQLiteConnection.transaction` joins a same-thread
            // nested call onto the same transaction rather than starting a second one, so
            // wrapping every main-DB read in one `measurements.transaction { ... }` block gives
            // all of raw/derived/workouts/nutrition one consistent snapshot. Symptom/adherence
            // reads go through `LoggingRepository`'s separate `sensitive` connection/file — a
            // pre-existing, documented architectural split (see
            // `LoggingRepository.transactionMain`/`transactionSensitive`) that a single
            // in-process transaction can't span, so those two reads stay outside this block.
            let gathered = try measurements.transaction { () -> GatheredMainDB in
                var rawSamples: [RawSample] = []
                var intervalRecords: [IntervalRecord] = []
                if scope.includeRaw {
                    for id in ids where metricAllowed(id, scope) {
                        rawSamples += try measurements
                            .rawSamples(metricId: id, from: scope.startDate, to: scope.endDate, includeSuppressed: scope.includeSuppressed)
                            .filter { sourceAllowed($0.provenance, scope) }
                        intervalRecords += try measurements
                            .intervalRecords(metricId: id, from: scope.startDate, to: scope.endDate, includeSuppressed: scope.includeSuppressed)
                            .filter { sourceAllowed($0.provenance, scope) }
                    }
                }

                var sessions: [Session] = []
                if scope.includeRaw {
                    sessions = try measurements
                        .sessions(kind: nil, from: scope.startDate, to: scope.endDate, includeSuppressed: scope.includeSuppressed)
                        .filter { sessionInScope($0, scope) && sourceAllowed($0.provenance, scope) }
                }

                // Rows whose period key couldn't be parsed as a `day:` key are still included
                // (best-effort) when a date range was requested, but counted so the manifest can
                // disclose that they weren't actually range-verified (OPT-143).
                var derivedValues: [DerivedValue] = []
                var baselines: [Baseline] = []
                var derivedRangeFallbackCount = 0
                if scope.includeDerived {
                    for id in ids where metricAllowed(id, scope) {
                        for v in try derivation.latestDerivedSeries(metricId: id) where derivedInRange(v, scope) {
                            derivedValues.append(v)
                            if derivedIncludedByRangeFallback(v, scope) { derivedRangeFallbackCount += 1 }
                        }
                        if registry.definition(id)?.baselineEligible == true,
                           let baseline = try derivation.latestBaseline(metricId: id) {
                            baselines.append(baseline)
                        }
                    }
                }

                // Structured logs kept in the main DB (workouts/nutrition are normal-class).
                let workouts = (wantRaw && logFamilyIncluded("activity", scope))
                    ? try logging.workouts(from: rangeStart, to: rangeEnd) : []
                let nutrition = (wantRaw && logFamilyIncluded("nutrition", scope))
                    ? try logging.nutrition(from: rangeStart, to: rangeEnd) : []

                return GatheredMainDB(rawSamples: rawSamples, intervalRecords: intervalRecords, sessions: sessions,
                                      derivedValues: derivedValues, baselines: baselines,
                                      derivedRangeFallbackCount: derivedRangeFallbackCount,
                                      workouts: workouts, nutrition: nutrition)
            }

            // Sensitive-class logs (medications/symptoms) — separate `sensitive` DB connection,
            // additionally gated by `includeSensitive` (matches the JSON bundle's existing gate).
            let symptoms = (wantRaw && scope.includeSensitive && logFamilyIncluded("symptoms", scope))
                ? try logging.symptoms(from: rangeStart, to: rangeEnd) : []
            let adherence = (wantRaw && scope.includeSensitive && logFamilyIncluded("medications", scope))
                ? try logging.adherence(from: rangeStart, to: rangeEnd) : []

            switch format {
            case .csv:
                return try runCSV(scope: scope, exportId: exportId, folder: folder, startedAt: startedAt,
                                  rawSamples: gathered.rawSamples, intervalRecords: gathered.intervalRecords,
                                  sessions: gathered.sessions, derivedValues: gathered.derivedValues,
                                  baselines: gathered.baselines,
                                  derivedRangeFallbackCount: gathered.derivedRangeFallbackCount,
                                  symptoms: symptoms, adherence: adherence,
                                  workouts: gathered.workouts, nutrition: gathered.nutrition)
            case .json:
                return try runJSON(scope: scope, exportId: exportId, folder: folder, startedAt: startedAt,
                                   rawSamples: gathered.rawSamples, intervalRecords: gathered.intervalRecords,
                                   sessions: gathered.sessions, derivedValues: gathered.derivedValues,
                                   baselines: gathered.baselines,
                                   derivedRangeFallbackCount: gathered.derivedRangeFallbackCount,
                                   symptoms: symptoms, adherence: adherence,
                                   workouts: gathered.workouts, nutrition: gathered.nutrition)
            }
        } catch {
            let failedJob = ExportJob(id: exportId, scope: scope, format: format, status: .failed,
                                      outputPath: folder.path, startedAt: startedAt,
                                      finishedAt: clock.now(), createdAt: startedAt)
            try? exportJobs.insert(failedJob)
            // Nothing left behind from a failed run (EDGE-02c).
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The main-DB portion of one run's gathered records — everything read inside the single
    /// `measurements.transaction { ... }` snapshot in `run(scope:format:)` (EDGE-03).
    private struct GatheredMainDB {
        let rawSamples: [RawSample]
        let intervalRecords: [IntervalRecord]
        let sessions: [Session]
        let derivedValues: [DerivedValue]
        let baselines: [Baseline]
        let derivedRangeFallbackCount: Int
        let workouts: [WorkoutEntry]
        let nutrition: [NutritionEntry]
    }

    /// Deletes `badan-export-*` temp folders older than `days` — orphaned by an interrupted
    /// export whose own cleanup never ran (app killed, crash). Best-effort and silent: a
    /// failure here must never block the export this call is part of (EDGE-02c).
    private func sweepOrphanedExportFolders(olderThan days: Int = 7) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = clock.now().addingTimeInterval(-Double(days) * 86_400)
        for url in items where url.lastPathComponent.hasPrefix("badan-export-") {
            guard let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if modDate < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - CSV

    private func runCSV(scope: ExportScope, exportId: String, folder: URL, startedAt: Date,
                        rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
                        derivedValues: [DerivedValue], baselines: [Baseline],
                        derivedRangeFallbackCount: Int, symptoms: [SymptomEntry], adherence: [AdherenceEvent],
                        workouts: [WorkoutEntry], nutrition: [NutritionEntry]) throws -> ExportResult {
        let generatedAt = clock.now()
        let writer = CSVWriter()

        // Route measured rows to raw.csv, engine-computed rows to derived.csv, and structured
        // logs (medications/symptoms/workouts/nutrition) to their own events.csv — the CSV
        // export previously omitted logs entirely even though the Sensitive toggle's own copy
        // promises them (DATA-03); JSON already carried them in its `logs` section.
        let rawRows = rawSamples.map { rowFor(sample: $0, scope) }
            + intervalRecords.map { rowFor(interval: $0, scope) }
            + sessions.map { rowFor(session: $0, scope) }
        let derivedRows = derivedValues.map { rowFor(derived: $0, scope) }
            + baselines.map { rowFor(baseline: $0, scope) }
        let regimenNames = Self.regimenNameLookup(adherence: adherence, logging: logging)
        let eventRows = symptoms.map { rowForEvent(symptom: $0, scope) }
            + adherence.map { rowForEvent(adherence: $0, regimenNames: regimenNames, scope) }
            + workouts.map { rowForEvent(workout: $0, scope) }
            + nutrition.map { rowForEvent(nutrition: $0, scope) }

        // Written and hashed directly, chunk by chunk, so the full CSV is never simultaneously
        // resident as a `String` and a second `Data` copy, and doesn't need a separate
        // whole-buffer hashing pass afterward (PERF-168/170).
        let rawURL = folder.appendingPathComponent("raw.csv")
        let derivedURL = folder.appendingPathComponent("derived.csv")
        let eventsURL = folder.appendingPathComponent("events.csv")
        let rawChecksum = try Self.streamWrite(rawRows, using: writer, to: rawURL)
        let derivedChecksum = try Self.streamWrite(derivedRows, using: writer, to: derivedURL)
        let eventsChecksum = try Self.streamWrite(eventRows, using: writer, to: eventsURL)

        let checksums = [
            "raw.csv": rawChecksum,
            "derived.csv": derivedChecksum,
            "events.csv": eventsChecksum
        ]
        var counts: [String: Int] = [:]
        addCounts(rawRows.map { $0.metricId }, into: &counts)
        addCounts(derivedRows.map { $0.metricId }, into: &counts)
        addCounts(eventRows.map { $0.metricId }, into: &counts)
        let rowCount = rawRows.count + derivedRows.count + eventRows.count

        let manifest = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                    checksums: checksums, perMetricRowCounts: counts,
                                    derivedRangeFallbackCount: derivedRangeFallbackCount)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONCoding.encoder.encode(manifest).write(to: manifestURL)

        let job = ExportJob(id: exportId, scope: scope, format: .csv, status: .completed,
                            manifest: manifest, outputPath: folder.path, rowCount: rowCount,
                            startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        return ExportResult(job: job, fileURLs: [rawURL, derivedURL, eventsURL, manifestURL], rowCount: rowCount)
    }

    // MARK: - JSON

    private func runJSON(scope: ExportScope, exportId: String, folder: URL, startedAt: Date,
                         rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
                         derivedValues: [DerivedValue], baselines: [Baseline],
                         derivedRangeFallbackCount: Int, symptoms: [SymptomEntry], adherence: [AdherenceEvent],
                         workouts: [WorkoutEntry], nutrition: [NutritionEntry]) throws -> ExportResult {
        let generatedAt = clock.now()

        var counts: [String: Int] = [:]
        addCounts(rawSamples.map { $0.metricId }, into: &counts)
        addCounts(intervalRecords.map { $0.metricId }, into: &counts)
        addCounts(sessions.map { sessionMetricId($0.kind) }, into: &counts)
        addCounts(derivedValues.map { $0.metricId }, into: &counts)
        addCounts(baselines.map { $0.metricId }, into: &counts)
        addCounts(symptoms.map { _ in "symptoms.entry" }, into: &counts)
        addCounts(adherence.map { _ in "medications.adherence" }, into: &counts)
        addCounts(workouts.map { _ in "activity.workout" }, into: &counts)
        addCounts(nutrition.map { _ in "nutrition.entry" }, into: &counts)
        let rowCount = rawSamples.count + intervalRecords.count + sessions.count
            + derivedValues.count + baselines.count
            + symptoms.count + adherence.count + workouts.count + nutrition.count

        // A single self-contained file cannot checksum itself, so the embedded manifest carries
        // no checksums; the file-level SHA is recorded on the persisted job below.
        let embedded = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                    checksums: [:], perMetricRowCounts: counts,
                                    derivedRangeFallbackCount: derivedRangeFallbackCount)
        let bundleData = try JSONBundleWriter().data(
            manifest: embedded, rawSamples: rawSamples, intervalRecords: intervalRecords,
            sessions: sessions, derivedValues: derivedValues, baselines: baselines,
            symptoms: symptoms, adherence: adherence, workouts: workouts, nutrition: nutrition)
        let bundleURL = folder.appendingPathComponent("bundle.json")
        try bundleData.write(to: bundleURL)

        let checksums = ["bundle.json": Self.sha256Hex(bundleData)]
        let persisted = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                     checksums: checksums, perMetricRowCounts: counts,
                                     derivedRangeFallbackCount: derivedRangeFallbackCount)
        let job = ExportJob(id: exportId, scope: scope, format: .json, status: .completed,
                            manifest: persisted, outputPath: folder.path, rowCount: rowCount,
                            startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        return ExportResult(job: job, fileURLs: [bundleURL], rowCount: rowCount)
    }

    // MARK: - Manifest

    private func makeManifest(exportId: String, scope: ExportScope, generatedAt: Date,
                              checksums: [String: String], perMetricRowCounts: [String: Int],
                              derivedRangeFallbackCount: Int = 0) -> ExportManifest {
        ExportManifest(
            exportId: exportId,
            schemaVersion: "0.1.0",
            appVersion: appVersion,
            platform: "iOS",
            generatedAt: generatedAt,
            scope: scope,
            dateRange: dateRangeString(scope),
            displayLanguage: scope.language.rawValue,
            unitProfile: scope.unitProfile.rawValue,
            timezonePolicy: "timestamps carry original offsets; day boundaries computed in tz-at-measurement",
            dedupPolicy: dedupPolicyNote(scope),
            perMetricRowCounts: perMetricRowCounts,
            checksums: checksums,
            dataQualityNote: dataQualityNote(derivedRangeFallbackCount: derivedRangeFallbackCount)
        )
    }

    private static let dataQualityNote =
        "Rows reflect stored records only; coverage gaps are not backfilled. Interval aggregates "
        + "carry a 0–1 coverage fraction in the JSON bundle. Derived values and baselines are "
        + "engine-computed, physically separated from raw, and each carries its algorithm id and version."

    /// The base data-quality note, plus a disclosure of how many derived rows in a date-bounded
    /// export were included via best-effort period-key matching rather than a confirmed in-range
    /// check (OPT-143) — today only reachable if a non-`day:`-keyed derived value is ever
    /// produced, since every derived value currently uses `day:` period keys.
    private func dataQualityNote(derivedRangeFallbackCount: Int) -> String {
        guard derivedRangeFallbackCount > 0 else { return Self.dataQualityNote }
        return Self.dataQualityNote
            + " \(derivedRangeFallbackCount) derived row(s) were included without date-range "
            + "verification because their period key could not be parsed as a calendar day."
    }

    private func dedupPolicyNote(_ scope: ExportScope) -> String {
        let inclusion = scope.includeSuppressed
            ? "included (each keeps suppressed_by = winning record_id)"
            : "excluded"
        return "suppress-not-delete; identity (metric_id, external_id, source_id), latest-wins; "
            + "suppressed duplicates \(inclusion)."
    }

    private func dateRangeString(_ scope: ExportScope) -> String {
        switch (scope.startDate, scope.endDate) {
        case (nil, nil):
            return "all"
        case let (start, end):
            let lower = start.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? ".."
            let upper = end.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? ".."
            return "\(lower)/\(upper)"
        }
    }

    // MARK: - Row builders

    private func rowFor(sample s: RawSample, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: s.metricId, canonicalValue: s.value, canonicalUnit: s.unit, scope)
        return ExportRow(
            recordId: s.id,
            recordKind: "sample",
            metricId: s.metricId,
            metricDisplay: metricDisplay(s.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(s.value),
            canonicalUnit: s.unit,
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.startAt, tzId: s.tzId),
            timestampEnd: s.endAt.map { CSVWriter.iso8601($0, tzId: s.tzId) },
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.provenance.recordedAt, tzId: s.tzId),
            sourceApp: s.provenance.sourceId,
            sourceDevice: s.provenance.deviceId,
            ingestionPath: s.provenance.ingestionPath.rawValue,
            sourceExternalId: s.provenance.externalId,
            importBatchId: s.provenance.importBatchId,
            qualityFlags: qualityFlagsString(s.provenance.qualityFlags, tzId: s.tzId),
            suppressedBy: s.provenance.suppressedBy
        )
    }

    private func rowFor(interval r: IntervalRecord, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: r.metricId, canonicalValue: r.value, canonicalUnit: r.unit, scope)
        return ExportRow(
            recordId: r.id,
            recordKind: "interval",
            metricId: r.metricId,
            metricDisplay: metricDisplay(r.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(r.value),
            canonicalUnit: r.unit,
            valueType: "aggregate",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(r.startAt, tzId: r.tzId),
            timestampEnd: CSVWriter.iso8601(r.endAt, tzId: r.tzId),
            timezone: r.tzId,
            recordedAt: CSVWriter.iso8601(r.provenance.recordedAt, tzId: r.tzId),
            sourceApp: r.provenance.sourceId,
            sourceDevice: r.provenance.deviceId,
            ingestionPath: r.provenance.ingestionPath.rawValue,
            sourceExternalId: r.provenance.externalId,
            importBatchId: r.provenance.importBatchId,
            qualityFlags: qualityFlagsString(r.provenance.qualityFlags, tzId: r.tzId),
            suppressedBy: r.provenance.suppressedBy
        )
    }

    private func rowFor(session s: Session, _ scope: ExportScope) -> ExportRow {
        let metricId = sessionMetricId(s.kind)
        return ExportRow(
            recordId: s.id,
            recordKind: "session",
            metricId: metricId,
            metricDisplay: sessionDisplay(s.kind, scope.language),
            value: CSVWriter.decimal(s.durationSeconds),
            unit: "s",
            canonicalValue: CSVWriter.decimal(s.durationSeconds),
            canonicalUnit: "s",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.startAt, tzId: s.tzId),
            timestampEnd: CSVWriter.iso8601(s.endAt, tzId: s.tzId),
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.provenance.recordedAt, tzId: s.tzId),
            sourceApp: s.provenance.sourceId,
            sourceDevice: s.provenance.deviceId,
            ingestionPath: s.provenance.ingestionPath.rawValue,
            sourceExternalId: s.provenance.externalId,
            importBatchId: s.provenance.importBatchId,
            qualityFlags: qualityFlagsString(s.provenance.qualityFlags, tzId: s.tzId),
            suppressedBy: s.provenance.suppressedBy
        )
    }

    private func rowFor(derived v: DerivedValue, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: v.metricId, canonicalValue: v.value, canonicalUnit: v.unit, scope)
        let start = periodStartDate(v.periodKey) ?? v.computedAt
        return ExportRow(
            recordId: v.id,
            recordKind: "derived",
            metricId: v.metricId,
            metricDisplay: metricDisplay(v.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(v.value),
            canonicalUnit: v.unit,
            valueType: "derived",
            isDerived: true,
            timestampStart: CSVWriter.iso8601(start, tzId: "UTC"),
            timezone: "UTC",
            recordedAt: CSVWriter.iso8601(v.updatedAt, tzId: "UTC"),
            sourceDevice: v.originDeviceId,
            ingestionPath: IngestionPath.derived.rawValue,
            qualityFlags: v.provisional ? QualityFlag.estimate.rawValue : nil,
            confidence: v.confidence.map { CSVWriter.decimal($0) },
            algorithmId: v.algorithmId,
            algorithmVersion: v.algorithmVersion
        )
    }

    private func rowFor(baseline b: Baseline, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: b.metricId, canonicalValue: b.center, canonicalUnit: b.unit, scope)
        return ExportRow(
            recordId: b.id,
            recordKind: "baseline",
            metricId: b.metricId,
            metricDisplay: metricDisplay(b.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(b.center),
            canonicalUnit: b.unit,
            valueType: "derived",
            isDerived: true,
            timestampStart: CSVWriter.iso8601(b.validFrom, tzId: "UTC"),
            timezone: "UTC",
            recordedAt: CSVWriter.iso8601(b.computedAt, tzId: "UTC"),
            ingestionPath: IngestionPath.derived.rawValue,
            qualityFlags: b.provisional ? QualityFlag.provisionalBaseline.rawValue : nil,
            algorithmId: "baseline.\(b.method.rawValue)",
            algorithmVersion: b.algorithmVersion
        )
    }

    // MARK: - Events (structured logs projected onto the CSV contract, DATA-03)

    /// `record_kind = "event"` rows for the four structured-log types, mapped onto the same
    /// 24-column contract used by samples/intervals/sessions/derived/baselines. Mapping choices
    /// (documented per type below) favor a defensible, always-populated `value`/`unit` over
    /// perfect fidelity — richer detail (triggers, notes, all six macros) already lives in the
    /// JSON bundle's `logs` section; this file exists so a CSV-only export isn't missing the
    /// records its own Sensitive-toggle copy promises.

    /// Symptom entries: `value` is the 0–10 severity (the one number a symptom entry always
    /// has); `metric_display` is the symptom's own bilingual name (or the free-text custom
    /// label). No physical unit applies, so `unit`/`canonical_unit` use "level" — an ordinal
    /// scale token, distinct from "score" (reserved for derived/baseline scores elsewhere in
    /// this contract).
    private func rowForEvent(symptom s: SymptomEntry, _ scope: ExportScope) -> ExportRow {
        let display = SymptomDictionary.shared.displayName(forId: s.symptomId, customLabel: s.customLabel)
            .resolved(scope.language)
        return ExportRow(
            recordId: s.id,
            recordKind: "event",
            metricId: "symptoms.entry",
            metricDisplay: display,
            value: CSVWriter.decimal(Double(s.severity)),
            unit: "level",
            canonicalValue: CSVWriter.decimal(Double(s.severity)),
            canonicalUnit: "level",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.occurredAt, tzId: s.tzId),
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.updatedAt, tzId: s.tzId),
            sourceDevice: s.originDeviceId,
            ingestionPath: IngestionPath.manual.rawValue
        )
    }

    /// Adherence events: `value` is 1 for a taken/late dose, 0 for a skip — "was this dose
    /// taken" is the one boolean every adherence event answers unambiguously. The actual status
    /// (and skip reason, if any) is preserved in `quality_flags` rather than discarded, since
    /// the contract has no dedicated status column for events. `metric_display` resolves the
    /// regimen's name via `regimenNames` (looked up once per run, not per row).
    private func rowForEvent(adherence e: AdherenceEvent, regimenNames: [String: String], _ scope: ExportScope) -> ExportRow {
        let display = regimenNames[e.regimenId] ?? e.regimenId
        let taken = e.kind == .taken || e.kind == .late
        var flags = e.kind.rawValue
        if let reason = e.skipReason { flags += ";skip_reason:\(reason.rawValue)" }
        return ExportRow(
            recordId: e.id,
            recordKind: "event",
            metricId: "medications.adherence",
            metricDisplay: display,
            value: CSVWriter.decimal(taken ? 1 : 0),
            unit: "bool",
            canonicalValue: CSVWriter.decimal(taken ? 1 : 0),
            canonicalUnit: "bool",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(e.scheduledFor ?? e.occurredAt, tzId: e.tzId),
            timezone: e.tzId,
            recordedAt: CSVWriter.iso8601(e.occurredAt, tzId: e.tzId),
            sourceDevice: e.originDeviceId,
            ingestionPath: IngestionPath.manual.rawValue,
            qualityFlags: flags
        )
    }

    /// Workouts: `value` is the session duration in seconds — the one measurement every workout
    /// always has (kcal/distance are optional). Unlike sleep/HealthKit sessions (already routed
    /// to raw.csv's "session" rows via `MeasurementRepository.sessions`), manually-logged
    /// `WorkoutEntry` rows were never represented in CSV at all before this fix, so there's no
    /// duplication risk in choosing the same duration-based shape here. Optional kcal/distance
    /// are preserved in `quality_flags` rather than silently dropped.
    private func rowForEvent(workout w: WorkoutEntry, _ scope: ExportScope) -> ExportRow {
        var flags: [String] = []
        if let kcal = w.energyKcal { flags.append("kcal:\(CSVWriter.decimal(kcal))") }
        if let distance = w.distanceM { flags.append("distance_m:\(CSVWriter.decimal(distance))") }
        return ExportRow(
            recordId: w.id,
            recordKind: "event",
            metricId: "activity.workout",
            metricDisplay: WorkoutActivity.label(forStored: w.activityType).resolved(scope.language),
            value: CSVWriter.decimal(w.durationSeconds),
            unit: "s",
            canonicalValue: CSVWriter.decimal(w.durationSeconds),
            canonicalUnit: "s",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(w.startAt, tzId: w.tzId),
            timestampEnd: CSVWriter.iso8601(w.endAt, tzId: w.tzId),
            timezone: w.tzId,
            recordedAt: CSVWriter.iso8601(w.updatedAt, tzId: w.tzId),
            sourceDevice: w.originDeviceId,
            ingestionPath: w.ingestionPath.rawValue,
            qualityFlags: flags.isEmpty ? nil : flags.joined(separator: ";")
        )
    }

    /// Nutrition entries: `value` is kcal (0 when not entered — the meal was still logged, just
    /// without an energy estimate; `low_detail` in `quality_flags` distinguishes that from a
    /// confirmed zero). `metric_display` is the entry's own description, mapped through
    /// `WaterEntryIdentity` so a quick-logged water entry reads as "Water"/"ماء" in the export's
    /// own `scope.language` rather than whatever language it happened to be logged in (EDGE-17).
    private func rowForEvent(nutrition n: NutritionEntry, _ scope: ExportScope) -> ExportRow {
        var flags: [String] = ["meal:\(n.mealType.rawValue)"]
        if n.lowDetail { flags.append("low_detail") }
        return ExportRow(
            recordId: n.id,
            recordKind: "event",
            metricId: "nutrition.entry",
            metricDisplay: WaterEntryIdentity.displayDescription(n.description, language: scope.language),
            value: CSVWriter.decimal(n.energyKcal ?? 0),
            unit: "kcal",
            canonicalValue: CSVWriter.decimal(n.energyKcal ?? 0),
            canonicalUnit: "kcal",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(n.occurredAt, tzId: n.tzId),
            timezone: n.tzId,
            recordedAt: CSVWriter.iso8601(n.updatedAt, tzId: n.tzId),
            sourceDevice: n.originDeviceId,
            ingestionPath: IngestionPath.manual.rawValue,
            qualityFlags: flags.joined(separator: ";")
        )
    }

    /// Regimen id -> name, resolved once per run instead of once per adherence row. Best-effort:
    /// a lookup failure (or a since-deleted regimen) falls back to the bare regimen id rather
    /// than failing the export.
    private static func regimenNameLookup(adherence: [AdherenceEvent], logging: LoggingRepository) -> [String: String] {
        guard !adherence.isEmpty else { return [:] }
        let regimens = (try? logging.regimens(activeOnly: false)) ?? []
        return Dictionary(uniqueKeysWithValues: regimens.map { ($0.id, $0.name) })
    }

    // MARK: - Unit profile & display

    /// The (value, unit) for the display columns. Canonical unless the scope asks for the display
    /// profile, in which case the metric's primary display unit is used; canonical columns are
    /// unaffected. Unknown/incompatible units fall back to canonical rather than fail the export.
    private func displayValueUnit(metricId: String, canonicalValue: Double, canonicalUnit: String,
                                  _ scope: ExportScope) -> (value: Double, unit: String) {
        guard scope.unitProfile == .display else { return (canonicalValue, canonicalUnit) }
        let target = registry.definitionOrFallback(metricId).primaryDisplayUnit
        guard !target.isEmpty, target != canonicalUnit,
              let converted = try? Units.convert(canonicalValue, from: canonicalUnit, to: target) else {
            return (canonicalValue, canonicalUnit)
        }
        return (converted, target)
    }

    private func metricDisplay(_ metricId: String, _ scope: ExportScope) -> String {
        registry.definitionOrFallback(metricId).displayName.resolved(scope.language)
    }

    /// Renders a row's quality flags, also appending `.tzAssumed` when `tzId` doesn't
    /// resolve to a real time zone — `CSVWriter.iso8601`/`TimestampFormatting` silently render
    /// such rows in UTC, and this makes that substitution visible on the row itself rather than
    /// a silent, undisclosed correction (OPT-151).
    private func qualityFlagsString(_ flags: [QualityFlag], tzId: String) -> String? {
        var all = flags
        if TimeZone(identifier: tzId) == nil, !all.contains(.tzAssumed) {
            all.append(.tzAssumed)
        }
        return all.isEmpty ? nil : all.map { $0.rawValue }.joined(separator: ";")
    }

    // MARK: - Scope helpers

    /// The metric ids to query, honoring an explicit metric picklist and/or a family filter.
    private func metricIdsInScope(_ scope: ExportScope) -> [String] {
        if let picked = scope.metricIds, !picked.isEmpty {
            guard let families = scope.families, !families.isEmpty else { return picked }
            let familySet = Set(families)
            return picked.filter { registry.definition($0).map { familySet.contains($0.family) } ?? true }
        }
        var defs = registry.all
        if let families = scope.families, !families.isEmpty {
            let familySet = Set(families)
            defs = defs.filter { familySet.contains($0.family) }
        }
        return defs.map { $0.metricId }
    }

    /// Sensitive-class metrics are only gathered when the scope opts into sensitive data.
    private func metricAllowed(_ metricId: String, _ scope: ExportScope) -> Bool {
        if scope.includeSensitive { return true }
        return registry.definition(metricId)?.sensitiveClass != .sensitivePlus
    }

    private func sourceAllowed(_ provenance: Provenance, _ scope: ExportScope) -> Bool {
        guard let sources = scope.sourceIds, !sources.isEmpty else { return true }
        return sources.contains(provenance.sourceId)
    }

    private func sessionInScope(_ session: Session, _ scope: ExportScope) -> Bool {
        let metricId = sessionMetricId(session.kind)
        if let picked = scope.metricIds, !picked.isEmpty, !picked.contains(metricId) { return false }
        if let families = scope.families, !families.isEmpty {
            if !families.contains(sessionFamily(metricId)) { return false }
        }
        return true
    }

    /// The family for a (possibly synthetic) session metric id, routed through the registry —
    /// the single authoritative source also used by `metricIdsInScope` — rather than re-deriving
    /// it from a hand-rolled string split. Synthetic session ids (`sleep.session`,
    /// `activity.workout_session`) aren't registered as real metrics, so they fall back to the
    /// dot-prefix convention (OPT-145).
    private func sessionFamily(_ metricId: String) -> String {
        if let family = registry.definition(metricId)?.family { return family }
        return metricId.split(separator: ".").first.map(String.init) ?? "other"
    }

    /// A narrowed metric picklist excludes logs entirely; a family filter includes a log
    /// category only when its family is selected; an unnarrowed scope includes all logs.
    private func logFamilyIncluded(_ family: String, _ scope: ExportScope) -> Bool {
        if let picked = scope.metricIds, !picked.isEmpty { return false }
        if let families = scope.families, !families.isEmpty { return families.contains(family) }
        return true
    }

    /// Best-effort period date filter: applies the scope range only when a day-keyed period can
    /// be parsed; otherwise the value is included (its period is not a simple calendar day).
    private func derivedInRange(_ v: DerivedValue, _ scope: ExportScope) -> Bool {
        guard scope.startDate != nil || scope.endDate != nil else { return true }
        guard let day = periodStartDate(v.periodKey) else { return true }
        if let start = scope.startDate, day < start { return false }
        if let end = scope.endDate, day > end { return false }
        return true
    }

    /// True when `v` passed `derivedInRange` only via its best-effort fallback — a date range
    /// was requested but `v.periodKey` couldn't be parsed as a `day:` key, so it was included
    /// without actually being range-checked. Counted so the manifest can disclose how many rows
    /// in a date-bounded export weren't confirmed to be in range (OPT-143).
    private func derivedIncludedByRangeFallback(_ v: DerivedValue, _ scope: ExportScope) -> Bool {
        guard scope.startDate != nil || scope.endDate != nil else { return false }
        return periodStartDate(v.periodKey) == nil
    }

    // MARK: - Synthetic ids & period parsing

    private func sessionMetricId(_ kind: SessionKind) -> String {
        switch kind {
        case .sleepPrimary, .sleepNap: return "sleep.session"
        case .workout: return "activity.workout_session"
        }
    }

    private func sessionDisplay(_ kind: SessionKind, _ language: AppLanguage) -> String {
        switch kind {
        case .sleepPrimary: return language == .ar ? "نوم" : "Sleep"
        case .sleepNap: return language == .ar ? "قيلولة" : "Nap"
        case .workout: return language == .ar ? "تمرين" : "Workout"
        }
    }

    /// Parses the calendar day from a `day:YYYY-MM-DD` period key (UTC midnight). Other period
    /// shapes (session:, week:) return nil and are treated as always-in-range. Delegates to
    /// `DayAttribution`'s existing `DateComponents`-based parser instead of constructing a fresh
    /// `DateFormatter` per call, which otherwise dominates large derived-value-heavy exports
    /// (PERF-161/171/197).
    private func periodStartDate(_ periodKey: String) -> Date? {
        guard periodKey.hasPrefix("day:") else { return nil }
        let day = String(periodKey.dropFirst("day:".count))
        return DayAttribution.date(fromDayKey: day, tz: "UTC")
    }

    // MARK: - Counting & checksums

    private func addCounts(_ metricIds: [String], into counts: inout [String: Int]) {
        for id in metricIds { counts[id, default: 0] += 1 }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates `url`, streams `rows` to it via `writer.write(_:to:)`, and returns the
    /// incrementally-computed SHA-256 hex digest (PERF-168/170).
    private static func streamWrite(_ rows: [ExportRow], using writer: CSVWriter, to url: URL) throws -> String {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        return try writer.write(rows, to: handle)
    }
}
