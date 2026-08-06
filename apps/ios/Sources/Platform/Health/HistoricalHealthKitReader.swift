import Foundation
import HealthKit

/// Reads a bounded historical window out of HealthKit, for D-35 item 2b's "Fetch Health history".
///
/// ## Why a separate type and not a mode flag on `HealthKitAdapter`
///
/// This type holds no anchors. It cannot advance one, cannot buffer one, and cannot commit one,
/// because it has no `pendingAnchors` property to put one in — `commitPendingAnchors()` falls
/// through to `HealthStorePort`'s default no-op. "A historical import leaves `read_anchors`
/// byte-identical" is therefore structural rather than a rule someone has to keep following, and
/// `HistoricalImportTests` asserts it.
///
/// That property is worth the separate type. The anchored path's incremental deletion feed only
/// exists relative to an anchor HealthKit has already issued; a historical fetch that quietly
/// advanced one would silently skip everything between the old anchor and the new on the next live
/// sync — data loss with no error and no way to notice.
///
/// ## Why resetting anchors was not the answer
///
/// Resetting them does not fetch older-than-90-day data at all: the anchored predicate is still
/// `now − historyDays`, so the reset just re-delivers the same window. It also destroys the
/// deletion feed described above. Per-window anchor namespaces would need a `read_anchors` schema
/// change, a garbage-collection rule and a second copy of DATA-08's two-phase commit discipline —
/// all replaced here by one persisted date cursor in `HistoricalImportRequestStore`.
///
/// ## What each data class does
///
/// - **Samples / anchored intervals / workouts** — plain `HKSampleQuery` over
///   `predicateForSamples(withStart:end:options:.strictStartDate)`, mapped through the shared
///   `HKSampleMapping` so the external ids match the anchored path's byte for byte. Same id means a
///   re-fetch upserts in place; a different one would silently double every row.
/// - **Cumulative dailies** — `HealthKitAdapter.readDailySum` unchanged. It is already anchor-free
///   and recomputes any window idempotently from day-keyed external ids.
/// - **Sleep** — the anchored delta signal is deliberately NOT used. Every night in the window is
///   enumerated and rebuilt through `HealthKitAdapter.sessionsForNight`, reusing the night-keyed
///   identity and the `disambiguateWithinNight` ordinal discipline. A second clustering path here
///   is the single most likely source of duplicate sleep sessions.
/// - **Deletions** — always empty. A deletion is an incremental-feed concept; a historical fetch
///   has no basis for claiming any and must not fabricate them.
///
/// Synchronous, like every other `HealthStorePort`: callers already run ingestion off the main
/// actor, so bridging HealthKit's completion handlers with a semaphore is safe here for the same
/// reason it is in `HealthKitAdapter`.
final class HistoricalHealthKitReader: HealthStorePort {
    private let store = HKHealthStore()
    private let tz: String

    init(tz: String = TimeZone.current.identifier) {
        self.tz = tz
    }

    func availability() -> HealthAvailability {
        HKHealthStore.isHealthDataAvailable() ? .available : .unsupported
    }

    /// Historical import never introduces a source the live path has not already discovered — it
    /// reads the same types from the same store. Returning nothing lets `IngestionPipeline` keep
    /// using the source rows live sync already wrote, rather than this path racing to author them.
    ///
    /// (AUDIT 2026-08-06, INGESTION-01) That was true of the source CATALOG and false of the dedup
    /// PRIORITY MAP, which `IngestionPipeline.upsertSourcesAndDevices` used to build from the
    /// current run's descriptors alone. Returning `[]` therefore handed `dedup(night:)` an empty
    /// map, every source resolved to 0, and `DedupLite` fell through to "longest duration wins" —
    /// silently re-deciding every night in the import window, live-synced nights included, in
    /// favour of whichever source recorded the longest span. The pipeline now seeds that map from
    /// the stored catalog, so this method's contract finally holds for both meanings of "keep
    /// using the source rows live sync already wrote".
    func sourceDescriptors() -> [SourceDescriptor] { [] }

    func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out: [SampleDTO] = []
        for entry in HKTypeMap.anchoredSampleEntries {
            guard let metricId = entry.metricId, let type = entry.quantityType else { continue }
            out += fetch(type: type, range: range).compactMap {
                HKSampleMapping.sampleDTO($0, entry: entry, metricId: metricId, fallbackTz: tz)
            }
        }
        return out
    }

    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out: [IntervalDTO] = []
        for entry in HKTypeMap.anchoredIntervalEntries {
            guard case .anchoredInterval(let aggregation) = entry.strategy,
                  let metricId = entry.metricId, let type = entry.quantityType else { continue }
            out += fetch(type: type, range: range).compactMap {
                HKSampleMapping.intervalDTO($0, entry: entry, metricId: metricId,
                                            aggregation: aggregation, fallbackTz: tz)
            }
        }
        // Unchanged and shared: already anchor-free, already idempotent per day.
        for entry in HKTypeMap.cumulativeEntries {
            out += HealthKitAdapter.readDailySum(entry, range: range, store: store, tz: tz)
        }
        return out
    }

    /// Every night the window touches, rebuilt in full through the live path's own night seam.
    ///
    /// Walks by local day via `DayAttribution` (DST-safe) rather than by adding 86,400 seconds, so
    /// a multi-year import does not drift a night at every clock change. The window is widened by
    /// one day at each end because a night is named for the day it ends on, and sleep that begins
    /// before `range.start` still belongs to a night inside it.
    ///
    /// (AUDIT 2026-08-06, SLEEP-H2) This type deliberately does NOT conform to
    /// `SleepNightRebuilding`, even though it rebuilds nights in exactly the same way and mints
    /// exactly the same ids. The pipeline's prune deletes whatever a rebuilt night no longer
    /// claims, and HealthKit never reveals a denied READ — an unauthorized sleep type answers with
    /// an empty sample set, not an error (see `fetch` below). On the anchored path a delta sample
    /// or a reported deletion has already proved HealthKit is answering before any night is
    /// rebuilt; here nothing has, so a user who runs "Fetch Health history" without sleep
    /// permission would have every night in the window tombstoned. Upsert-only is the safe
    /// behaviour for a path that cannot tell "no sleep" from "no permission".
    func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        var out: [SessionDTO] = []
        var day = DayAttribution.addingDays(-1, to: DayAttribution.startOfDay(range.start, tz: tz), tz: tz)
        let last = DayAttribution.addingDays(1, to: DayAttribution.startOfDay(range.end, tz: tz), tz: tz)
        while day <= last {
            // `nil` means the night could not be read at all; skipping it leaves whatever is
            // already stored for that night untouched, which is the only safe reading here.
            out += HealthKitAdapter.sessionsForNight(DayAttribution.localDayKey(day, tz: tz),
                                                     categoryType: type, store: store, tz: tz) ?? []
            day = DayAttribution.addingDays(1, to: day, tz: tz)
        }
        return out
    }

    /// Workouts in the window. Routes are deliberately not read: the route-consent gate is a
    /// live-sync concern, and a bulk historical fetch is the wrong place to start pulling GPS
    /// traces the user consented to for a different purpose.
    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return fetch(type: HKObjectType.workoutType(), range: range).compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            return HKSampleMapping.workoutDTO(workout, totals: HealthKitAdapter.totals(for: workout),
                                              route: nil, fallbackTz: tz)
        }
    }

    /// Always empty — see the type doc. A historical fetch has no deletion feed and must not
    /// invent one.
    func deletions(_ range: HealthDateRange) -> HealthStoreDeletions { HealthStoreDeletions() }

    // `commitPendingAnchors()` is intentionally not implemented: the protocol's default no-op is
    // the correct and only safe behaviour here, and having no override is what makes it impossible
    // to write an anchor from this path.

    // MARK: - The one query shape this type uses

    /// A plain, non-anchored date-range query. `predicateForSamples(withStart:end:options:)` has
    /// existed since iOS 8 — there is no newer bulk/import API in HealthKit to prefer over it (the
    /// iOS 26 additions are medications, clinical coding, hypertension events and VO₂-max test
    /// types), and this file claims none.
    private func fetch(type: HKSampleType, range: HealthDateRange) -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end,
                                                    options: .strictStartDate)
        let semaphore = DispatchSemaphore(value: 0)
        var out: [HKSample] = []
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
            defer { semaphore.signal() }
            // Same failable-graceful contract as the live adapter: a denied or restricted type
            // resolves to empty rather than throwing, because HealthKit never tells an app that a
            // READ was denied. "Nothing came back" is the only signal available, which is exactly
            // why the import surface must not claim to know why a window was empty.
            guard error == nil else { return }
            out = samples ?? []
        }
        store.execute(query)
        semaphore.wait()
        return out
    }
}
