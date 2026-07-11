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
        let startedAt = clock.now()
        let exportId = ULID.newID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-\(exportId)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Measurement + derived chain (shared by both formats).
        let ids = metricIdsInScope(scope)

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

        var derivedValues: [DerivedValue] = []
        var baselines: [Baseline] = []
        if scope.includeDerived {
            for id in ids where metricAllowed(id, scope) {
                derivedValues += try derivation.latestDerivedSeries(metricId: id)
                    .filter { derivedInRange($0, scope) }
                if registry.definition(id)?.baselineEligible == true,
                   let baseline = try derivation.latestBaseline(metricId: id) {
                    baselines.append(baseline)
                }
            }
        }

        switch format {
        case .csv:
            return try runCSV(scope: scope, exportId: exportId, folder: folder, startedAt: startedAt,
                              rawSamples: rawSamples, intervalRecords: intervalRecords, sessions: sessions,
                              derivedValues: derivedValues, baselines: baselines)
        case .json:
            return try runJSON(scope: scope, exportId: exportId, folder: folder, startedAt: startedAt,
                               rawSamples: rawSamples, intervalRecords: intervalRecords, sessions: sessions,
                               derivedValues: derivedValues, baselines: baselines)
        }
    }

    // MARK: - CSV

    private func runCSV(scope: ExportScope, exportId: String, folder: URL, startedAt: Date,
                        rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
                        derivedValues: [DerivedValue], baselines: [Baseline]) throws -> ExportResult {
        let generatedAt = clock.now()
        let writer = CSVWriter()

        // Route measured rows to raw.csv, engine-computed rows to derived.csv.
        let rawRows = rawSamples.map { rowFor(sample: $0, scope) }
            + intervalRecords.map { rowFor(interval: $0, scope) }
            + sessions.map { rowFor(session: $0, scope) }
        let derivedRows = derivedValues.map { rowFor(derived: $0, scope) }
            + baselines.map { rowFor(baseline: $0, scope) }

        let rawData = Data(writer.render(rawRows).utf8)
        let derivedData = Data(writer.render(derivedRows).utf8)
        let rawURL = folder.appendingPathComponent("raw.csv")
        let derivedURL = folder.appendingPathComponent("derived.csv")
        try rawData.write(to: rawURL)
        try derivedData.write(to: derivedURL)

        let checksums = [
            "raw.csv": Self.sha256Hex(rawData),
            "derived.csv": Self.sha256Hex(derivedData)
        ]
        var counts: [String: Int] = [:]
        addCounts(rawRows.map { $0.metricId }, into: &counts)
        addCounts(derivedRows.map { $0.metricId }, into: &counts)
        let rowCount = rawRows.count + derivedRows.count

        let manifest = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                    checksums: checksums, perMetricRowCounts: counts)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONCoding.encoder.encode(manifest).write(to: manifestURL)

        let job = ExportJob(id: exportId, scope: scope, format: .csv, status: .completed,
                            manifest: manifest, outputPath: folder.path, rowCount: rowCount,
                            startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        return ExportResult(job: job, fileURLs: [rawURL, derivedURL, manifestURL], rowCount: rowCount)
    }

    // MARK: - JSON

    private func runJSON(scope: ExportScope, exportId: String, folder: URL, startedAt: Date,
                         rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
                         derivedValues: [DerivedValue], baselines: [Baseline]) throws -> ExportResult {
        let generatedAt = clock.now()

        // Structured logs travel only in the JSON bundle's dedicated logs section. Symptoms and
        // adherence are sensitive-class and additionally gated by includeSensitive.
        let rangeStart = scope.startDate ?? Date(timeIntervalSince1970: 0)
        let rangeEnd = scope.endDate ?? generatedAt
        let wantRaw = scope.includeRaw
        let symptoms = (wantRaw && scope.includeSensitive && logFamilyIncluded("symptoms", scope))
            ? try logging.symptoms(from: rangeStart, to: rangeEnd) : []
        let adherence = (wantRaw && scope.includeSensitive && logFamilyIncluded("medications", scope))
            ? try logging.adherence(from: rangeStart, to: rangeEnd) : []
        let workouts = (wantRaw && logFamilyIncluded("activity", scope))
            ? try logging.workouts(from: rangeStart, to: rangeEnd) : []
        let nutrition = (wantRaw && logFamilyIncluded("nutrition", scope))
            ? try logging.nutrition(from: rangeStart, to: rangeEnd) : []

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
                                    checksums: [:], perMetricRowCounts: counts)
        let bundleData = try JSONBundleWriter().data(
            manifest: embedded, rawSamples: rawSamples, intervalRecords: intervalRecords,
            sessions: sessions, derivedValues: derivedValues, baselines: baselines,
            symptoms: symptoms, adherence: adherence, workouts: workouts, nutrition: nutrition)
        let bundleURL = folder.appendingPathComponent("bundle.json")
        try bundleData.write(to: bundleURL)

        let checksums = ["bundle.json": Self.sha256Hex(bundleData)]
        let persisted = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                     checksums: checksums, perMetricRowCounts: counts)
        let job = ExportJob(id: exportId, scope: scope, format: .json, status: .completed,
                            manifest: persisted, outputPath: folder.path, rowCount: rowCount,
                            startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        return ExportResult(job: job, fileURLs: [bundleURL], rowCount: rowCount)
    }

    // MARK: - Manifest

    private func makeManifest(exportId: String, scope: ExportScope, generatedAt: Date,
                              checksums: [String: String], perMetricRowCounts: [String: Int]) -> ExportManifest {
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
            dataQualityNote: Self.dataQualityNote
        )
    }

    private static let dataQualityNote =
        "Rows reflect stored records only; coverage gaps are not backfilled. Interval aggregates "
        + "carry a 0–1 coverage fraction in the JSON bundle. Derived values and baselines are "
        + "engine-computed, physically separated from raw, and each carries its algorithm id and version."

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
            qualityFlags: qualityFlagsString(s.provenance.qualityFlags),
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
            qualityFlags: qualityFlagsString(r.provenance.qualityFlags),
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
            qualityFlags: qualityFlagsString(s.provenance.qualityFlags),
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

    private func qualityFlagsString(_ flags: [QualityFlag]) -> String? {
        flags.isEmpty ? nil : flags.map { $0.rawValue }.joined(separator: ";")
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
            let family = metricId.split(separator: ".").first.map(String.init) ?? "other"
            if !families.contains(family) { return false }
        }
        return true
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
    /// shapes (session:, week:) return nil and are treated as always-in-range.
    private func periodStartDate(_ periodKey: String) -> Date? {
        guard periodKey.hasPrefix("day:") else { return nil }
        let day = String(periodKey.dropFirst("day:".count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    // MARK: - Counting & checksums

    private func addCounts(_ metricIds: [String], into counts: inout [String: Int]) {
        for id in metricIds { counts[id, default: 0] += 1 }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
