import Foundation

/// A pass-through `HealthStorePort` that records how many DTOs went through it.
///
/// Exists so `HistoricalImportCoordinator` can tell "Health handed over nothing" apart from "Health
/// handed over rows we already had" without querying the store twice. `IngestionPipeline.ingest`
/// already reads every DTO in its phase 1; a second counting pass would double the HealthKit round
/// trips for every month of a potentially multi-year walk.
///
/// The distinction it enables is not cosmetic. An empty window and a fully-duplicate window both
/// produce an all-zero `IngestSummary`, and reporting the second as "nothing there" would tell a
/// user their history is missing when it is in fact already imported. Reporting the first as
/// "already up to date" would be worse still — it would imply BADAN knows the window is empty, when
/// HealthKit never reveals whether a read was denied.
///
/// Forwards `commitPendingAnchors()` unchanged, so wrapping a store never changes its anchor
/// behaviour — a historical reader wrapped here still commits nothing, and a live adapter wrapped
/// here would still commit normally.
final class CountingHealthStore: HealthStorePort {
    private let wrapped: HealthStorePort
    private(set) var dtosReturned = 0

    init(wrapping wrapped: HealthStorePort) { self.wrapped = wrapped }

    func availability() -> HealthAvailability { wrapped.availability() }
    func sourceDescriptors() -> [SourceDescriptor] { wrapped.sourceDescriptors() }

    func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
        let out = wrapped.readSamples(range)
        dtosReturned += out.count
        return out
    }

    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        let out = wrapped.readIntervals(range)
        dtosReturned += out.count
        return out
    }

    func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
        let out = wrapped.readSessions(range)
        dtosReturned += out.count
        return out
    }

    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] {
        let out = wrapped.readWorkouts(range)
        dtosReturned += out.count
        return out
    }

    func backfillWindows(_ range: HealthDateRange) -> [HealthBackfillWindow] {
        wrapped.backfillWindows(range)
    }

    /// Deliberately not counted: a deletion is not a DTO Health "returned" for the window, and
    /// counting one would let an empty window look non-empty.
    func deletions(_ range: HealthDateRange) -> HealthStoreDeletions { wrapped.deletions(range) }

    func commitPendingAnchors() { wrapped.commitPendingAnchors() }
}
