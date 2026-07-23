import Foundation

/// The shared commit path for the GPX/TCX/CSV file importers (EPIC-43 ACC-005). Mirrors
/// `AppleHealthArchiveImporter`'s shape deliberately: parse to DTOs, stage/resume an
/// `ImportBatch`, flush the DTOs through the SAME `IngestionPipeline.ingest(from:range:origin:
/// .fileImport(batchId:))` live HealthKit sync uses, checkpoint, complete. There is no separate
/// review/mapping/confirm UI step — this is the direct-commit shape the reference importer
/// establishes, not a parallel pipeline.
///
/// Unlike the Apple Health archive (which can be hundreds of MB and is streamed with a bounded
/// buffer), a GPX/TCX/CSV file a person picks by hand is small enough to parse to DTOs in memory
/// in one pass and commit in a single `ingest` call — `IngestionPipeline` already batches its own
/// writes internally (`writeBatchSize`), so a second buffering layer here would add complexity
/// with no user-visible benefit.
///
/// One instance handles all three formats — `format` is a parameter of `importFile`, not of
/// `init` — so `FileImportScreen` can hold a single `FileImporter` regardless of which picker the
/// person used, exactly as it holds a single `@Observable` model for the three.
final class FileImporter {
    private let pipeline: IngestionPipeline
    private let batches: ImportBatchRepository
    private let clock: Clock
    private let routeConsent: RouteConsentProviding
    /// Optional, matching `AppleHealthArchiveImporter`'s own `derivation` parameter: without it,
    /// this importer still commits and undoes correctly, it simply does not backfill scores over
    /// the imported span. `AppEnvironment.makeFileImporter()` always wires the real one.
    private let derivation: DerivationCoordinator?

    init(pipeline: IngestionPipeline, batches: ImportBatchRepository, clock: Clock,
         routeConsent: RouteConsentProviding = RouteConsentStore(),
         derivation: DerivationCoordinator? = nil) {
        self.pipeline = pipeline
        self.batches = batches
        self.clock = clock
        self.routeConsent = routeConsent
        self.derivation = derivation
    }

    /// Parse `fileURL` as `format` and commit it. `fileName` is the identity `existingBatch` dedups
    /// on (resume/re-import), matching `AppleHealthArchiveImporter.importExportXML`'s own contract
    /// — pass the picked file's own display name, not a temp path.
    @discardableResult
    func importFile(format: FileImportFormat, fileURL: URL, fileName: String) throws -> FileImportResult {
        let now = clock.now()

        // Resume (or re-import) under the file's existing batch, else stage a fresh one — see
        // `ImportBatchRepository.existingBatch`'s doc for why this is not restricted to
        // unfinished batches (resume, re-import, and re-import-after-undo all need the same id).
        let resumed = try batches.existingBatch(sourceKind: format.sourceKind, fileName: fileName)
        let batchId = resumed?.id ?? ULID.newID()
        if resumed == nil {
            try batches.create(id: batchId, sourceKind: format.sourceKind, fileName: fileName,
                               state: ImportBatch.stateRunning, createdAt: now)
        } else {
            try batches.setState(id: batchId, ImportBatch.stateRunning)
        }

        let parsed: ParsedFileImport
        do {
            parsed = try format.parse(fileURL: fileURL)
        } catch {
            try? batches.setState(id: batchId, ImportBatch.stateFailed)
            throw error
        }

        // Apply the LIVE route-consent decision here, at commit time — never whatever a pure
        // parser guessed (every parser stamps `.denied` as a placeholder; see their docs). This
        // mirrors how `HealthKitAdapter` consults consent at read time (EPIC-03): the same single
        // standing toggle gates whether BADAN writes GPS rows to `workout_routes`, regardless of
        // whether the geometry came from a live HealthKit sync or an imported GPX/TCX file. A
        // person who has never turned that toggle on gets their workout imported without its
        // route rather than the route silently landing over a toggle they never agreed to.
        let liveConsent = routeConsent.routeConsent()
        let workouts = parsed.workouts.map { workout -> WorkoutDTO in
            guard let route = workout.route else { return workout }
            var updated = workout
            updated.route = RouteDTO(externalId: route.externalId, points: route.points, consent: liveConsent)
            return updated
        }

        let store = FileImportHealthStore(descriptors: parsed.descriptors, samples: parsed.samples,
                                          intervals: parsed.intervals, workouts: workouts)
        let range = Self.range(store: store, now: now)

        do {
            let summary = try pipeline.ingest(from: store, range: range, origin: .fileImport(batchId: batchId))
            let counts: [String: Int] = [
                "samples": summary.samples, "intervals": summary.intervals,
                "workouts": summary.workouts, "routes": summary.routes, "suppressed": summary.suppressed,
            ]
            try batches.checkpoint(id: batchId, recordsProcessed: parsed.recordsProcessed, counts: counts)
            try batches.setState(id: batchId, ImportBatch.stateCompleted)

            if let derivation {
                let span = Self.measuredRange(store: store)
                if let span { try derivation.backfill(from: span.from, to: span.to) }
            }

            return FileImportResult(batchId: batchId, fileName: fileName,
                                    recordsProcessed: parsed.recordsProcessed, counts: counts)
        } catch {
            try? batches.setState(id: batchId, ImportBatch.stateFailed)
            throw error
        }
    }

    /// Take back everything one import wrote and re-derive scores over the window it covered —
    /// identical contract to `AppleHealthArchiveImporter.undo`.
    @discardableResult
    func undo(batchId: String) throws -> ImportBatchRepository.UndoResult {
        let result = try batches.undo(id: batchId, now: clock.now())
        if let derivation, let range = result.affectedRange {
            try derivation.backfill(from: range.from, to: range.to)
        }
        return result
    }

    /// The window `ingest` should treat as "in scope" for this run — every DTO's own span, since a
    /// hand-picked file has no separate "requested range" the way a HealthKit query does.
    private static func range(store: FileImportHealthStore, now: Date) -> HealthDateRange {
        let starts = store.samples.map(\.start) + store.intervals.map(\.start) + store.workouts.map(\.start)
        let ends = store.intervals.map(\.end) + store.workouts.map(\.end) + store.samples.compactMap { $0.end }
        let lo = starts.min() ?? now
        let hi = (ends + starts).max() ?? now
        return HealthDateRange(start: lo, end: hi)
    }

    /// The real min/max across every DTO, for the derivation backfill window — `nil` when the
    /// parse produced nothing (an empty file), so no backfill is attempted over a meaningless span.
    private static func measuredRange(store: FileImportHealthStore) -> (from: Date, to: Date)? {
        let starts = store.samples.map(\.start) + store.intervals.map(\.start) + store.workouts.map(\.start)
        guard !starts.isEmpty else { return nil }
        let ends = store.intervals.map(\.end) + store.workouts.map(\.end) + store.samples.compactMap { $0.end }
        let lo = starts.min()!
        let hi = (ends + starts).max()!
        return (lo, hi)
    }
}

/// The outcome of one completed file import — batch id (for undo), how many records were read,
/// and per-family row counts. Mirrors `AppleHealthImportResult`'s shape.
struct FileImportResult: Equatable {
    let batchId: String
    let fileName: String
    let recordsProcessed: Int
    let counts: [String: Int]
}

/// A `HealthStorePort` over one file's already-parsed DTOs, mirroring
/// `AppleHealthArchiveImporter`'s private `ArchiveHealthStore` — `ingest` reads through this
/// exactly as it reads the real HealthKit adapter, so nothing about the pipeline path differs for
/// a file import.
private final class FileImportHealthStore: HealthStorePort {
    let descriptors: [SourceDescriptor]
    let samples: [SampleDTO]
    let intervals: [IntervalDTO]
    let workouts: [WorkoutDTO]

    init(descriptors: [SourceDescriptor], samples: [SampleDTO], intervals: [IntervalDTO], workouts: [WorkoutDTO]) {
        self.descriptors = descriptors
        self.samples = samples
        self.intervals = intervals
        self.workouts = workouts
    }

    func availability() -> HealthAvailability { .available }
    func sourceDescriptors() -> [SourceDescriptor] { descriptors }
    func readSamples(_ range: HealthDateRange) -> [SampleDTO] { samples }
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { intervals }
    func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] { workouts }
}
