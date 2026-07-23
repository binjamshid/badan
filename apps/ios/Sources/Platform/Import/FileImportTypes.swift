import Foundation

/// EPIC-43 ACC-005: shared vocabulary for the GPX/TCX/CSV file importers. Kept separate from
/// `FileImporter` (the commit path) and the three parsers so all four files can see one shared,
/// tiny contract without importing each other in a cycle.
///
/// **Scope note, stated once here for the whole feature**: FIT (Garmin's binary ANT+ format) is
/// deliberately NOT one of `FileImportFormat`'s cases. It is a complex binary protocol (global
/// message definitions, developer fields, CRC validation) that risks a fragile, incorrect
/// implementation if rushed into this slice alongside three text/XML formats — it is being
/// deferred as its own dedicated follow-up, never bundled in here.

/// The result one parser hands back — exactly the DTO families `IngestionPipeline.ingest` already
/// knows how to write (the same ones `AppleHealthArchiveImporter` buffers before a flush). A
/// parser only ever populates the families its format actually carries: GPX/TCX produce
/// `workouts` (TCX also produces heart-rate `samples`); CSV produces `samples` only (see
/// `CSVFileParser`'s own doc for why intervals are out of scope). `intervals` exists on this type
/// for symmetry with `HealthStorePort` and so a future parser needn't invent a second shape.
struct ParsedFileImport {
    var descriptors: [SourceDescriptor] = []
    var samples: [SampleDTO] = []
    var intervals: [IntervalDTO] = []
    var workouts: [WorkoutDTO] = []
    /// How many source rows/points/trackpoints were actually read — reported to the user and
    /// checkpointed on the batch, mirroring `AppleHealthImportResult.recordsProcessed`. Distinct
    /// from `samples.count`/`workouts.count`: a GPX track's `recordsProcessed` is its point count,
    /// not its (one) workout count, so the number on screen means "how much of the file was read"
    /// rather than "how many database rows resulted".
    var recordsProcessed: Int = 0
}

/// Every way a parser can honestly fail. Never a crash: `FileImporter` catches whichever of these
/// a parser throws, marks the batch `.failed`, and rethrows — the same shape
/// `AppleHealthArchiveImporter` uses for `AppleHealthImportError`.
enum FileImportError: Error, Equatable {
    /// The file couldn't be opened/read at all (permissions, a moved/deleted file, bad encoding).
    case cannotReadFile
    /// The file's own syntax is broken — unparseable XML, or a CSV row that violates the header
    /// contract. The associated string is a short, human-readable reason (row number, element).
    case malformed(String)
    /// A CSV file with no non-blank rows at all (not even a header).
    case emptyFile
    /// A CSV header is missing one or more of the required contract columns.
    case missingColumns(String)
}

/// The three file formats this slice supports, and the one place that decides which pure parser
/// handles which. `sourceKind` feeds `ImportBatchRepository.existingBatch`/`create` so each format
/// dedups against its own file/batch lineage, never another format's.
enum FileImportFormat: String, CaseIterable, Sendable {
    case gpx, tcx, csv

    var sourceKind: String {
        switch self {
        case .gpx: return ImportBatch.gpxSourceKind
        case .tcx: return ImportBatch.tcxSourceKind
        case .csv: return ImportBatch.csvSourceKind
        }
    }

    /// Dispatches to the one pure, format-specific parser. Each parser is a plain function over a
    /// file URL with no database or consent access — see `FileImporter.importFile` for where the
    /// live route-consent decision and the batch/pipeline plumbing are applied instead.
    func parse(fileURL: URL) throws -> ParsedFileImport {
        switch self {
        case .gpx: return try GPXFileParser.parse(fileURL: fileURL)
        case .tcx: return try TCXFileParser.parse(fileURL: fileURL)
        case .csv: return try CSVFileParser.parse(fileURL: fileURL)
        }
    }
}
