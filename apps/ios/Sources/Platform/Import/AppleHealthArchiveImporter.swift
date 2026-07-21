import Foundation
import HealthKit

/// Imports a user's exported Apple Health archive (`export.zip` → `export.xml`) into BADAN by
/// routing every row through the SAME `IngestionPipeline.ingest` that live HealthKit sync uses
/// (plan §19). It never writes measurement rows directly: that is the pipeline's own type-doc
/// requirement, and it is what makes an import deduped, provenanced (I1) and idempotent by the
/// identical pass as a sync — overlapping imported and live-synced sleep is reconciled per-night
/// by dedup-lite rather than double-counted, and re-importing the same archive is a no-op.
///
/// **Memory + resumability.** The archives are large (a heavy user's `export.xml` is hundreds of
/// MB), so the XML is parsed as a stream (SAX, `XMLParser`) and never held whole. Three of the
/// four families stream straight through: instantaneous samples, discrete intervals and workouts
/// accumulate into a buffer that is flushed through `ingest` and emptied every `flushThreshold`
/// records, so their peak cost is the threshold, not the archive. The other two are aggregated,
/// and their bounds differ — stated separately because rounding them together would overstate the
/// guarantee:
///
/// - Cumulative daily totals hold one running sum per (metric, day, source) — bounded by days ×
///   sources, negligible even for a decade of history.
/// - Sleep stage segments are held for the whole archive, because a night's session cannot be
///   emitted until its last segment has been seen and the export is not guaranteed to be ordered.
///   That is bounded by *segments*, i.e. a few tens per night — a decade of nightly staged sleep
///   is on the order of 10⁵ small structs, not the 10⁷ raw samples the same archive carries.
///
/// Progress is reported per flush, and the whole import is one `import_batches` row: an
/// interruption leaves it `running`, and resuming re-runs from the start — safe because every
/// upsert is idempotent, exactly the resume model `SeedController` uses.
///
/// **Provenance & undo (I1).** Every row is stamped `ingestionPath = .import` and carries the
/// batch id (`IngestOrigin.fileImport`), so `undo(batchId:)` takes back precisely what one import
/// added — by tombstoning those rows, so an incremental export can report the removal — and a later
/// live sync is never confused with imported history.
///
/// **Reconciliation limits, stated honestly.** Apple's `export.xml` carries no per-sample UUIDs
/// and no source bundle ids, so imported rows cannot share upstream identity with live-synced
/// ones for the families the pipeline keys by UUID (instantaneous samples, discrete intervals,
/// workouts): re-import is idempotent, but an import that OVERLAPS a live-sync window can leave a
/// second copy of those families (they have no cross-source dedup pass — only sleep and
/// workout-vs-manual do). The intended use is importing history OLDER than live sync reaches; the
/// cumulative daily totals sidestep this by writing under live sync's own per-day identity so
/// they collapse instead of doubling. See `AppleHealthMapping`.
final class AppleHealthArchiveImporter {
    private let pipeline: IngestionPipeline
    private let batches: ImportBatchRepository
    private let registry: MetricRegistry
    private let derivation: DerivationCoordinator?
    private let clock: Clock
    private let fileManager: FileManager

    /// How many buffered records trigger a flush through `ingest`. Large enough that per-flush
    /// overhead (source upserts, a transaction) is amortized; small enough that the in-memory
    /// buffer for a multi-hundred-MB archive stays a few thousand small structs.
    private let flushThreshold: Int

    init(pipeline: IngestionPipeline, batches: ImportBatchRepository, registry: MetricRegistry,
         derivation: DerivationCoordinator?, clock: Clock,
         fileManager: FileManager = .default, flushThreshold: Int = 5_000) {
        self.pipeline = pipeline
        self.batches = batches
        self.registry = registry
        self.derivation = derivation
        self.clock = clock
        self.fileManager = fileManager
        self.flushThreshold = max(1, flushThreshold)
    }

    // MARK: - Public API

    /// Import the standard Apple Health `export.zip`: locate `export.xml` inside it, stream it out
    /// to a temp file, and import that. The extracted temp file is removed when done.
    @discardableResult
    func importArchive(zipURL: URL, fileName: String? = nil,
                       progress: ((AppleHealthImportProgress) -> Void)? = nil,
                       isCancelled: (() -> Bool)? = nil) throws -> AppleHealthImportResult {
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("badan-ah-import-\(UUID().uuidString).xml")
        defer { try? fileManager.removeItem(at: temp) }
        do {
            try ZipArchiveReader.extract(entryNamed: "export.xml", from: zipURL, to: temp)
        } catch ZipArchiveReader.ReaderError.entryNotFound {
            throw AppleHealthImportError.noExportXML
        }
        return try importExportXML(xmlURL: temp, fileName: fileName ?? zipURL.lastPathComponent,
                                   progress: progress, isCancelled: isCancelled)
    }

    /// Import an already-extracted `export.xml`. The load-bearing path — `importArchive` is a thin
    /// unzip front-end over this, and tests drive this directly with a small XML fixture.
    @discardableResult
    func importExportXML(xmlURL: URL, fileName: String,
                         progress: ((AppleHealthImportProgress) -> Void)? = nil,
                         isCancelled: (() -> Bool)? = nil) throws -> AppleHealthImportResult {
        let now = clock.now()

        // Resume (or re-import) under the file's existing batch, else stage a fresh one. Reusing
        // the id keeps every row this archive contributes under ONE batch, so undo covers the whole
        // import even across an interruption or a repeat import — see `existingBatch`.
        let resumed = try batches.existingBatch(sourceKind: ImportBatch.appleHealthSourceKind, fileName: fileName)
        let batchId = resumed?.id ?? ULID.newID()
        if resumed == nil {
            try batches.create(id: batchId, sourceKind: ImportBatch.appleHealthSourceKind,
                               fileName: fileName, state: ImportBatch.stateRunning, createdAt: now)
        } else {
            try batches.setState(id: batchId, ImportBatch.stateRunning)
        }

        let state = ParseState(batchId: batchId, now: now)
        let delegate = AppleHealthParserDelegate(importer: self, state: state,
                                                 flushThreshold: flushThreshold,
                                                 progress: progress, isCancelled: isCancelled)

        guard let stream = InputStream(url: xmlURL) else { throw AppleHealthImportError.cannotReadXML }
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        let parsedOK = parser.parse()

        if let error = state.thrownError {
            try? batches.setState(id: batchId, ImportBatch.stateFailed)
            throw error
        }
        if state.wasCancelled {
            // Leave the batch `running` so it is resumable; committed rows are idempotent.
            try? batches.setState(id: batchId, ImportBatch.stateRunning)
            throw AppleHealthImportError.cancelled
        }
        if !parsedOK, let parseError = parser.parserError {
            try? batches.setState(id: batchId, ImportBatch.stateFailed)
            throw AppleHealthImportError.malformedXML(parseError.localizedDescription)
        }

        // Finalize: flush the streamed tail, then the aggregated sleep + cumulative families.
        do {
            try flushStreamed(state)
            try finalizeSleep(state)
            try finalizeCumulative(state)
        } catch {
            try? batches.setState(id: batchId, ImportBatch.stateFailed)
            throw error
        }

        try batches.checkpoint(id: batchId, recordsProcessed: state.recordsProcessed, counts: state.counts)
        try batches.setState(id: batchId, ImportBatch.stateCompleted)
        progress?(state.snapshot(phase: .deriving))

        // Backfill scores over the imported span so historical days are scored, and so imported
        // history feeds baselines. Each resulting `DerivedValue` is written with the period it
        // describes and the instant it was computed, which is what makes
        // `BaselineEngine.isRetroactive` answer true for it — a day scored weeks after the fact is
        // recognisably "computed later from history", and the import tests assert that on the rows
        // this backfill actually writes.
        //
        // Stated plainly, because the flag is easy to over-claim: `QualityFlag.retroactive` is a
        // READ-TIME label (see its doc), and no read or export path attaches it yet — Phase 2A
        // defined the flag and the predicate, not a surface that shows them. So imported history is
        // scored and the data supports the label; it is not yet displayed or exported as such.
        if let derivation, let range = state.measuredRange {
            try derivation.backfill(from: range.from, to: range.to)
        }

        let result = AppleHealthImportResult(batchId: batchId, fileName: fileName,
                                             recordsProcessed: state.recordsProcessed,
                                             counts: state.counts, dateRange: state.measuredRange)
        progress?(state.snapshot(phase: .done))
        return result
    }

    /// Take back everything one import wrote (see `ImportBatchRepository.undo`) and re-derive scores
    /// over the window it covered so baselines/scores no longer reflect the removed history.
    ///
    /// The rows are TOMBSTONED, not erased: nothing an undo removes is visible to any read path
    /// (every query filters `deleted_at IS NULL`), and the tombstone is what lets an incremental
    /// export tell a downstream store the record went away. Re-importing the same archive revives
    /// exactly those rows.
    @discardableResult
    func undo(batchId: String) throws -> ImportBatchRepository.UndoResult {
        let result = try batches.undo(id: batchId, now: clock.now())
        if let derivation, let range = result.affectedRange {
            try derivation.backfill(from: range.from, to: range.to)
        }
        return result
    }

    // MARK: - Flushing (called by the delegate + finalize)

    /// Route the current streamed buffers through `ingest`, then clear them and checkpoint. This
    /// is the ONLY place the importer touches storage — via the pipeline, never a direct write.
    fileprivate func flushStreamed(_ state: ParseState) throws {
        guard !state.sampleBuffer.isEmpty || !state.intervalBuffer.isEmpty || !state.workoutBuffer.isEmpty else { return }
        let store = ArchiveHealthStore(descriptors: state.allDescriptors(),
                                       samples: state.sampleBuffer, intervals: state.intervalBuffer,
                                       sessions: [], workouts: state.workoutBuffer)
        try ingest(store, state: state)
        state.sampleBuffer.removeAll(keepingCapacity: true)
        state.intervalBuffer.removeAll(keepingCapacity: true)
        state.workoutBuffer.removeAll(keepingCapacity: true)
        try batches.checkpoint(id: state.batchId, recordsProcessed: state.recordsProcessed, counts: state.counts)
    }

    /// Build one sleep session per (source, night, cluster) from the accumulated segments and
    /// route them through `ingest` so dedup-lite reconciles them per night against any live data.
    private func finalizeSleep(_ state: ParseState) throws {
        let sessions = state.buildSleepSessions()
        guard !sessions.isEmpty else { return }
        for chunk in sessions.badanChunked(flushThreshold) {
            let store = ArchiveHealthStore(descriptors: state.allDescriptors(),
                                           samples: [], intervals: [], sessions: Array(chunk), workouts: [])
            try ingest(store, state: state)
        }
        try batches.checkpoint(id: state.batchId, recordsProcessed: state.recordsProcessed, counts: state.counts)
    }

    /// Emit the cumulative daily totals (steps, energy, distance, floors) under live sync's own
    /// per-day identity so they collapse with — rather than double — a later live sync.
    private func finalizeCumulative(_ state: ParseState) throws {
        let intervals = state.buildCumulativeIntervals()
        guard !intervals.isEmpty else { return }
        // Ensure the `healthkit` merged-total source resolves to a cataloged Source (mirrors
        // HealthKitAdapter.fallbackDescriptor — honest: this data DID come from Apple Health).
        state.ensureHealthKitSource()
        for chunk in intervals.badanChunked(flushThreshold) {
            let store = ArchiveHealthStore(descriptors: state.allDescriptors(),
                                           samples: [], intervals: Array(chunk), sessions: [], workouts: [])
            try ingest(store, state: state)
        }
        try batches.checkpoint(id: state.batchId, recordsProcessed: state.recordsProcessed, counts: state.counts)
    }

    private func ingest(_ store: ArchiveHealthStore, state: ParseState) throws {
        let range = state.bufferRange(store: store)
        let summary = try pipeline.ingest(from: store, range: range,
                                          origin: .fileImport(batchId: state.batchId))
        state.counts["samples", default: 0] += summary.samples
        state.counts["intervals", default: 0] += summary.intervals
        state.counts["sessions", default: 0] += summary.sessions
        state.counts["workouts", default: 0] += summary.workouts
        state.counts["suppressed", default: 0] += summary.suppressed
    }

    fileprivate var registryRef: MetricRegistry { registry }
}

// MARK: - Result / progress / errors

/// The outcome of a completed import — batch id (for undo), how many records were read, per-family
/// row counts, and the span of imported history.
struct AppleHealthImportResult: Equatable {
    let batchId: String
    let fileName: String
    let recordsProcessed: Int
    let counts: [String: Int]
    let dateRange: (from: Date, to: Date)?

    static func == (l: AppleHealthImportResult, r: AppleHealthImportResult) -> Bool {
        l.batchId == r.batchId && l.fileName == r.fileName && l.recordsProcessed == r.recordsProcessed
            && l.counts == r.counts && l.dateRange?.from == r.dateRange?.from && l.dateRange?.to == r.dateRange?.to
    }
}

/// Live progress for the UI. `recordsProcessed` climbs as the stream is read; `counts` is the
/// per-family running total of rows actually written.
struct AppleHealthImportProgress: Equatable {
    enum Phase: Equatable { case parsing, deriving, done }
    var phase: Phase
    var recordsProcessed: Int
    var counts: [String: Int]
}

enum AppleHealthImportError: Error, Equatable {
    /// The zip did not contain an `export.xml`.
    case noExportXML
    /// The `export.xml` file could not be opened as a stream.
    case cannotReadXML
    /// `XMLParser` reported the document was not well-formed.
    case malformedXML(String)
    /// The user cancelled; the batch is left resumable.
    case cancelled
}

// MARK: - Parse state (one import's mutable accumulation)

/// All mutable state for a single import. Held off the importer so the importer stays reentrant-
/// safe by construction (a fresh state per call) and so the delegate and finalize steps share one
/// object. Not thread-safe: an import runs on one queue.
private final class ParseState {
    let batchId: String
    let now: Date

    var sampleBuffer: [SampleDTO] = []
    var intervalBuffer: [IntervalDTO] = []
    var workoutBuffer: [WorkoutDTO] = []

    /// All sleep stage segments, keyed by source slug; grouped into sessions at finalize.
    var sleepSegments: [String: [StageDTO]] = [:]
    /// Cumulative canonical daily sums, keyed by (metricId, dayKey, sourceSlug).
    var cumulative: [CumulativeKey: CumulativeAgg] = [:]

    /// Discovered sources by id (source slug), in first-seen order via `descriptorOrder`.
    var descriptors: [String: SourceDescriptor] = [:]
    private var descriptorOrder: [String] = []

    var counts: [String: Int] = [:]
    var recordsProcessed = 0
    var measuredMin: Date?
    var measuredMax: Date?

    var thrownError: Error?
    var wasCancelled = false

    init(batchId: String, now: Date) { self.batchId = batchId; self.now = now }

    func note(measured date: Date) {
        measuredMin = measuredMin.map { min($0, date) } ?? date
        measuredMax = measuredMax.map { max($0, date) } ?? date
    }

    var measuredRange: (from: Date, to: Date)? {
        guard let lo = measuredMin, let hi = measuredMax else { return nil }
        return (lo, hi)
    }

    func registerDescriptor(_ descriptor: SourceDescriptor) {
        // Keep the first descriptor seen for a source (its device info is as good as any later
        // record's); do not overwrite, so priority/device stay stable across the import.
        guard descriptors[descriptor.id] == nil else { return }
        descriptorOrder.append(descriptor.id)
        descriptors[descriptor.id] = descriptor
    }

    func allDescriptors() -> [SourceDescriptor] { descriptorOrder.compactMap { descriptors[$0] } }

    func ensureHealthKitSource() {
        registerDescriptor(SourceDescriptor(
            id: AppleHealthMapping.mergedTotalSourceId, displayName: "Apple Health", type: .healthkit,
            bundleId: "com.apple.health", priority: 80))
    }

    func priority(forSourceId id: String) -> Int { descriptors[id]?.priority ?? 0 }

    func bufferRange(store: ArchiveHealthStore) -> HealthDateRange {
        let starts = store.samples.map(\.start) + store.intervals.map(\.start)
            + store.sessions.map(\.start) + store.workouts.map(\.start)
        let ends = store.intervals.map(\.end) + store.sessions.map(\.end) + store.workouts.map(\.end)
            + store.samples.compactMap { $0.end }
        let lo = starts.min() ?? now
        let hi = (ends + starts).max() ?? now
        return HealthDateRange(start: lo, end: hi)
    }

    func snapshot(phase: AppleHealthImportProgress.Phase) -> AppleHealthImportProgress {
        AppleHealthImportProgress(phase: phase, recordsProcessed: recordsProcessed, counts: counts)
    }

    // MARK: Sleep -> sessions

    /// Group each source's segments by local night, split within a night on a >3h gap (mirroring
    /// live sync's cluster rule), and build one primary/nap session per cluster. External ids are
    /// night-keyed with an ordinal suffix for extra clusters, so a re-import upserts in place.
    func buildSleepSessions() -> [SessionDTO] {
        var out: [SessionDTO] = []
        let gap: TimeInterval = 3 * 3600
        let primaryMin: TimeInterval = 3 * 3600
        for (sourceId, segments) in sleepSegments {
            let sorted = segments.sorted { $0.start < $1.start }
            // Cluster on wake gaps first.
            var clusters: [[StageDTO]] = []
            var current: [StageDTO] = []
            for seg in sorted {
                if let last = current.last, seg.start.timeIntervalSince(last.end) > gap {
                    clusters.append(current); current = []
                }
                current.append(seg)
            }
            if !current.isEmpty { clusters.append(current) }

            // Assign a stable ordinal per night so external ids are deterministic.
            var nightOrdinal: [String: Int] = [:]
            for cluster in clusters {
                guard let start = cluster.map(\.start).min(), let end = cluster.map(\.end).max() else { continue }
                let tz = sleepTZ(for: sourceId)
                let night = DayAttribution.localNight(sessionEnd: end, tz: tz)
                let ordinal = nightOrdinal[night, default: 0]
                nightOrdinal[night] = ordinal + 1
                var externalId = "ah-sleep-\(sourceId)-\(night)"
                if ordinal > 0 { externalId += "-\(ordinal)" }

                var asleep: TimeInterval = 0
                for seg in cluster where seg.stage != .awake && seg.stage != .inBed {
                    asleep += seg.end.timeIntervalSince(seg.start)
                }
                let kind: SessionKind = asleep >= primaryMin ? .sleepPrimary : .sleepNap
                out.append(SessionDTO(
                    kind: kind, start: start, end: end, tz: tz,
                    sourceId: sourceId, deviceId: descriptors[sourceId]?.deviceId, externalId: externalId,
                    stages: cluster, timeAsleepSeconds: asleep,
                    timeInBedSeconds: end.timeIntervalSince(start), qualityFlags: [.tzAssumed]))
            }
        }
        return out
    }

    /// Sleep segments do not carry a tz of their own here; the source's records supply one at
    /// parse time, stashed per source. Falls back to UTC (flagged `.tzAssumed` on the session).
    private var sleepTZBySource: [String: String] = [:]
    func recordSleepTZ(_ tz: String, forSource id: String) { if sleepTZBySource[id] == nil { sleepTZBySource[id] = tz } }
    private func sleepTZ(for id: String) -> String { sleepTZBySource[id] ?? "GMT" }

    // MARK: Cumulative -> intervals

    func buildCumulativeIntervals() -> [IntervalDTO] {
        // For each (metricId, dayKey) pick the highest-priority contributing source, so a phone +
        // watch that both logged steps don't sum to a doubled day (device-wins, I4-aligned).
        var winnerByDay: [String: (key: CumulativeKey, agg: CumulativeAgg, priority: Int)] = [:]
        for (key, agg) in cumulative {
            let dayId = key.metricId + "|" + key.dayKey
            let prio = priority(forSourceId: key.sourceSlug)
            if let existing = winnerByDay[dayId] {
                if prio > existing.priority || (prio == existing.priority && agg.sum > existing.agg.sum) {
                    winnerByDay[dayId] = (key, agg, prio)
                }
            } else {
                winnerByDay[dayId] = (key, agg, prio)
            }
        }
        var out: [IntervalDTO] = []
        for (_, winner) in winnerByDay {
            guard let entry = AppleHealthMapping.cumulativeEntry(forMetric: winner.key.metricId),
                  let def = registryCanonicalUnit(winner.key.metricId),
                  let dayStart = DayAttribution.date(fromDayKey: winner.key.dayKey, tz: winner.agg.tz) else { continue }
            let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: winner.agg.tz)
            out.append(IntervalDTO(
                metricId: winner.key.metricId, value: winner.agg.sum, unit: def,
                start: dayStart, end: dayEnd, tz: winner.agg.tz, aggregation: .sum,
                sourceId: AppleHealthMapping.mergedTotalSourceId, deviceId: nil,
                externalId: entry.dailyTotalExternalId(dayKey: winner.key.dayKey),
                qualityFlags: [.tzAssumed], isRecomputedDailyTotal: true))
        }
        return out
    }

    /// Filled in by the importer before finalize so the state can resolve canonical units without
    /// holding the registry itself.
    var canonicalUnitByMetric: [String: String] = [:]
    private func registryCanonicalUnit(_ metricId: String) -> String? { canonicalUnitByMetric[metricId] }
}

private struct CumulativeKey: Hashable { let metricId: String; let dayKey: String; let sourceSlug: String }
private struct CumulativeAgg { var sum: Double; var tz: String }

// MARK: - The buffer-backed HealthStorePort

/// A `HealthStorePort` over one flush's worth of already-parsed DTOs. `ingest` reads through this
/// exactly as it reads the real HealthKit adapter, so nothing about the pipeline path differs for
/// an import; `range` is ignored because the buffer is pre-scoped to what this flush holds.
private final class ArchiveHealthStore: HealthStorePort {
    let descriptors: [SourceDescriptor]
    let samples: [SampleDTO]
    let intervals: [IntervalDTO]
    let sessions: [SessionDTO]
    let workouts: [WorkoutDTO]

    init(descriptors: [SourceDescriptor], samples: [SampleDTO], intervals: [IntervalDTO],
         sessions: [SessionDTO], workouts: [WorkoutDTO]) {
        self.descriptors = descriptors; self.samples = samples; self.intervals = intervals
        self.sessions = sessions; self.workouts = workouts
    }

    func availability() -> HealthAvailability { .available }
    func sourceDescriptors() -> [SourceDescriptor] { descriptors }
    func readSamples(_ range: HealthDateRange) -> [SampleDTO] { samples }
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { intervals }
    func readSessions(_ range: HealthDateRange) -> [SessionDTO] { sessions }
    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] { workouts }
}

// MARK: - SAX delegate

/// Streams `export.xml`, turning `<Record>` / `<Workout>` elements into DTOs and flushing the
/// importer's buffers periodically. Delegate methods can't throw, so a thrown error is captured
/// into `state.thrownError` and the parse is aborted; the importer rethrows it afterwards.
private final class AppleHealthParserDelegate: NSObject, XMLParserDelegate {
    private unowned let importer: AppleHealthArchiveImporter
    private let state: ParseState
    private let progress: ((AppleHealthImportProgress) -> Void)?
    private let isCancelled: (() -> Bool)?
    private let flushThreshold: Int

    /// A workout being assembled across its child `<WorkoutStatistics>` elements.
    private var pendingWorkout: PendingWorkout?

    /// `flushThreshold` is handed in rather than read off `importer`: it is a `private` stored
    /// property there, and Swift's `private` does not reach across two types in one file. Passing
    /// it keeps one number in charge of both the parse-time flush cadence and the finalize-time
    /// chunking — a second, hardcoded copy here would silently ignore the caller's setting.
    init(importer: AppleHealthArchiveImporter, state: ParseState, flushThreshold: Int,
         progress: ((AppleHealthImportProgress) -> Void)?, isCancelled: (() -> Bool)?) {
        self.importer = importer
        self.state = state
        self.progress = progress
        self.isCancelled = isCancelled
        self.flushThreshold = max(1, flushThreshold)
        super.init()
        // Cache canonical units so `ParseState` can build cumulative intervals without the registry.
        for entry in HKTypeMap.table {
            if let metricId = entry.metricId, let def = importer.registryRef.definition(metricId) {
                state.canonicalUnitByMetric[metricId] = def.canonicalUnit
            }
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if let isCancelled, isCancelled() {
            state.wasCancelled = true
            parser.abortParsing()
            return
        }
        do {
            switch elementName {
            case "Record": try handleRecord(attributeDict)
            case "Workout": try startWorkout(attributeDict)
            case "WorkoutStatistics": addWorkoutStatistic(attributeDict)
            default: break   // HealthData, ExportDate, Me, MetadataEntry, WorkoutEvent, WorkoutRoute, etc.
            }
        } catch {
            state.thrownError = error
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard elementName == "Workout" else { return }
        do { try finishWorkout() }
        catch { state.thrownError = error; parser.abortParsing() }
    }

    // MARK: Records

    private func handleRecord(_ attrs: [String: String]) throws {
        guard let type = attrs["type"] else { return }
        state.recordsProcessed += 1

        if type == AppleHealthMapping.sleepType {
            handleSleepRecord(attrs)
        } else if let entry = AppleHealthMapping.quantityEntry(forType: type), let metricId = entry.metricId {
            try handleQuantityRecord(attrs, entry: entry, metricId: metricId)
        }
        // Unknown/unsupported types (blood pressure, audio exposure, clinical, ...) are skipped —
        // honestly not imported rather than mis-mapped.

        try maybeFlush()
    }

    private func handleQuantityRecord(_ attrs: [String: String], entry: HKTypeMap.Entry, metricId: String) throws {
        guard let valueStr = attrs["value"], let value = Double(valueStr),
              let startStr = attrs["startDate"], let start = AppleHealthMapping.parseDate(startStr) else { return }
        let end = attrs["endDate"].flatMap(AppleHealthMapping.parseDate)?.date
        let source = source(from: attrs)
        state.registerDescriptor(source.descriptor)
        state.note(measured: start.date)

        let unit = AppleHealthMapping.importUnit(metricId: metricId, xmlUnit: attrs["unit"],
                                                 canonical: state.canonicalUnitByMetric[metricId])

        switch entry.strategy {
        case .statisticsCumulative:
            // Aggregate a canonical daily sum; emitted under live-sync identity at finalize.
            let canonical = state.canonicalUnitByMetric[metricId] ?? unit
            let canonicalValue = Units.toCanonical(value, from: unit, canonical: canonical)
            let dayKey = DayAttribution.localDayKey(start.date, tz: start.tz)
            let key = CumulativeKey(metricId: metricId, dayKey: dayKey, sourceSlug: source.descriptor.id)
            if var agg = state.cumulative[key] { agg.sum += canonicalValue; state.cumulative[key] = agg }
            else { state.cumulative[key] = CumulativeAgg(sum: canonicalValue, tz: start.tz) }

        case .anchoredInterval(let aggregation):
            let external = "ah-\(metricId)-\(source.descriptor.id)-\(millis(start.date))-\(valueStr)"
            state.intervalBuffer.append(IntervalDTO(
                metricId: metricId, value: value, unit: unit, start: start.date, end: end ?? start.date,
                tz: start.tz, aggregation: aggregation, sourceId: source.descriptor.id,
                deviceId: source.descriptor.deviceId, externalId: external, qualityFlags: [.tzAssumed]))

        case .anchoredSample:
            let external = "ah-\(metricId)-\(source.descriptor.id)-\(millis(start.date))-\(valueStr)"
            state.sampleBuffer.append(SampleDTO(
                metricId: metricId, value: value, unit: unit, start: start.date, end: end,
                tz: start.tz, sourceId: source.descriptor.id, deviceId: source.descriptor.deviceId,
                externalId: external, qualityFlags: [.tzAssumed]))

        case .authorizationOnly:
            break
        }
    }

    private func handleSleepRecord(_ attrs: [String: String]) {
        guard let valueStr = attrs["value"], let stage = AppleHealthMapping.sleepStage(valueStr),
              let startStr = attrs["startDate"], let start = AppleHealthMapping.parseDate(startStr),
              let endStr = attrs["endDate"], let end = AppleHealthMapping.parseDate(endStr) else { return }
        let source = source(from: attrs)
        state.registerDescriptor(source.descriptor)
        state.recordSleepTZ(start.tz, forSource: source.descriptor.id)
        state.note(measured: start.date)
        state.sleepSegments[source.descriptor.id, default: []]
            .append(StageDTO(stage: stage, start: start.date, end: end.date))
    }

    // MARK: Workouts

    private func startWorkout(_ attrs: [String: String]) throws {
        state.recordsProcessed += 1
        guard let typeStr = attrs["workoutActivityType"],
              let startStr = attrs["startDate"], let start = AppleHealthMapping.parseDate(startStr),
              let endStr = attrs["endDate"], let end = AppleHealthMapping.parseDate(endStr) else {
            pendingWorkout = nil
            return
        }
        let source = source(from: attrs)
        state.registerDescriptor(source.descriptor)
        state.note(measured: start.date)

        var totals = WorkoutTotals()
        if let d = attrs["totalDistance"], let v = Double(d) {
            totals.distanceMeters = Units.toCanonical(v, from: AppleHealthMapping.lengthUnit(attrs["totalDistanceUnit"]), canonical: "m")
        }
        if let e = attrs["totalEnergyBurned"], let v = Double(e) {
            totals.energyKcal = Units.toCanonical(v, from: AppleHealthMapping.energyUnit(attrs["totalEnergyBurnedUnit"]), canonical: "kcal")
        }
        pendingWorkout = PendingWorkout(
            activitySlug: AppleHealthMapping.activitySlug(for: typeStr),
            start: start.date, end: end.date, tz: start.tz, source: source.descriptor,
            externalId: "ah-workout-\(source.descriptor.id)-\(millis(start.date))-\(AppleHealthMapping.activitySlug(for: typeStr))",
            totals: totals)
        try maybeFlush()
    }

    /// `<WorkoutStatistics>` (iOS 16+) carries distance/energy as children rather than attributes.
    private func addWorkoutStatistic(_ attrs: [String: String]) {
        guard var pending = pendingWorkout, let type = attrs["type"] else { return }
        let sum = attrs["sum"].flatMap(Double.init)
        switch type {
        case "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierDistanceCycling",
             "HKQuantityTypeIdentifierDistanceSwimming", "HKQuantityTypeIdentifierDistanceDownhillSnowSports":
            if let sum, pending.totals.distanceMeters == nil {
                pending.totals.distanceMeters = Units.toCanonical(sum, from: AppleHealthMapping.lengthUnit(attrs["unit"]), canonical: "m")
            }
        case "HKQuantityTypeIdentifierActiveEnergyBurned":
            if let sum, pending.totals.energyKcal == nil {
                pending.totals.energyKcal = Units.toCanonical(sum, from: AppleHealthMapping.energyUnit(attrs["unit"]), canonical: "kcal")
            }
        case "HKQuantityTypeIdentifierHeartRate":
            if let avg = attrs["average"].flatMap(Double.init) { pending.totals.avgHeartRateBpm = avg }
            if let mx = attrs["maximum"].flatMap(Double.init) { pending.totals.maxHeartRateBpm = mx }
        default: break
        }
        pendingWorkout = pending
    }

    private func finishWorkout() throws {
        guard let pending = pendingWorkout else { return }
        pendingWorkout = nil
        state.workoutBuffer.append(WorkoutDTO(
            activityType: pending.activitySlug, start: pending.start, end: pending.end, tz: pending.tz,
            sourceId: pending.source.id, deviceId: pending.source.deviceId, externalId: pending.externalId,
            sourceWorkoutUUID: pending.externalId, totals: pending.totals, qualityFlags: [.tzAssumed]))
        try maybeFlush()
    }

    // MARK: Helpers

    private struct PendingWorkout {
        let activitySlug: String
        let start: Date
        let end: Date
        let tz: String
        let source: SourceDescriptor
        let externalId: String
        var totals: WorkoutTotals
    }

    private func source(from attrs: [String: String]) -> (descriptor: SourceDescriptor, name: String) {
        AppleHealthMapping.sourceDescriptor(sourceName: attrs["sourceName"], device: attrs["device"])
    }

    private func millis(_ date: Date) -> Int64 { date.epochMillis }

    private func maybeFlush() throws {
        let buffered = state.sampleBuffer.count + state.intervalBuffer.count + state.workoutBuffer.count
        guard buffered >= flushThreshold else { return }
        try importer.flushStreamed(state)
        progress?(state.snapshot(phase: .parsing))
    }
}
