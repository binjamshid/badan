import Foundation
import HealthKit

/// Real HealthKit integration boundary (FEAT-01). Reads sleep, heart rate, resting heart rate,
/// and step count via `HKAnchoredObjectQuery` (steps via `HKStatisticsCollectionQuery` — see
/// `readIntervals`), mapped to the exact DTO shapes `FakeHealthStore` produces so
/// `IngestionPipeline` treats both sources identically. `HealthStorePort`'s read methods are
/// synchronous by contract (mirrored by `FakeHealthStore` and depended on by every ingestion
/// test), so each one bridges HealthKit's completion-handler queries onto the calling thread
/// with a `DispatchSemaphore` rather than exposing `async` — callers already run ingestion off
/// the main actor (`AppEnvironment.connectHealthKit`, `SeedController`), so blocking there is
/// safe and never touches the UI thread.
///
/// Every read is failable-graceful: an unavailable store, a denied/restricted type, or a query
/// error all resolve to an empty result rather than throwing or crashing — HealthKit's read
/// authorization is deliberately opaque (apps are never told whether a *read* grant was denied,
/// only whether the request sheet completed), so "empty" is the only honest signal available.
final class HealthKitAdapter: HealthStorePort {
    private let store = HKHealthStore()
    private let anchors: ReadAnchorRepository
    private let tz: String

    /// The single `store` key under which every HealthKit anchor/permission-state row is filed
    /// (matches `SourcesScreen`'s `"healthkit"` permission-store label) and the sourceId used
    /// for values HealthKit only ever returns pre-merged across sources (see `readDailySteps`)
    /// or when no data has synced yet (see `sourceDescriptors`) — using this shared token rather
    /// than fabricating a device-specific id keeps provenance honest in both cases.
    private static let fallbackSourceId = "healthkit"

    init(anchors: ReadAnchorRepository, tz: String = TimeZone.current.identifier) {
        self.anchors = anchors
        self.tz = tz
    }

    /// The MVP read set. Built once (rather than per `requestAuthorization` call) since each
    /// type is a pure lookup of a fixed identifier. TODO(PERF-181): once more of the 44-metric
    /// ontology gets real HealthKit backing, derive this from `MetricDefinition` instead of
    /// hand-maintaining it here — that's a `registry.json` contract change (Android-affecting
    /// too) and belongs to a dedicated ontology-expansion effort, not this cache-only fix.
    private static let readTypes: Set<HKObjectType> = {
        var read = Set<HKObjectType>()
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { read.insert(t) }
        return read
    }()

    func availability() -> HealthAvailability {
        HKHealthStore.isHealthDataAvailable() ? .available : .unsupported
    }

    /// Ask to READ the MVP types, awaiting the system sheet. `true` means the request completed
    /// without error — for read-only requests HealthKit intentionally never reveals per-type
    /// grant/deny (privacy), so this is "connect went through," not "every type was granted";
    /// the read methods below degrade to empty results regardless of the real per-type outcome.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: Self.readTypes) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Discover which real HealthKit sources have contributed data for our read types, so
    /// dedup priority (watch vs. phone) and per-record provenance reflect the device that
    /// actually recorded each reading rather than a single fabricated "Apple Health" stand-in.
    /// Falls back to one generic descriptor when nothing has synced yet (denied, no data, or
    /// the simulator) — `IngestionPipeline` always needs at least one source row to attach to.
    func sourceDescriptors() -> [SourceDescriptor] {
        guard HKHealthStore.isHealthDataAvailable() else { return [Self.fallbackDescriptor] }
        var byBundleId: [String: SourceDescriptor] = [:]
        for type in Self.readTypes {
            guard let sampleType = type as? HKSampleType else { continue }
            for source in querySources(for: sampleType) {
                let bundleId = source.bundleIdentifier
                guard byBundleId[bundleId] == nil else { continue }
                byBundleId[bundleId] = SourceDescriptor(
                    id: bundleId, displayName: source.name, type: .healthkit,
                    bundleId: bundleId, priority: 0) // priority inferred from name by IngestionPipeline.
            }
        }
        guard !byBundleId.isEmpty else { return [Self.fallbackDescriptor] }
        return byBundleId.values.sorted { $0.id < $1.id }
    }

    private static let fallbackDescriptor = SourceDescriptor(
        id: fallbackSourceId, displayName: "Apple Health", type: .healthkit,
        bundleId: "com.apple.health", priority: 80)

    // MARK: - HealthStorePort reads

    /// Instant heart-rate readings -> raw samples (bpm), matching `FakeHealthStore`'s shape for
    /// `MetricID.heartRate`. `restingHeartRate` is intentionally *not* here — HealthKit emits it
    /// as one already-computed value per day, which is an interval (see `readIntervals`), not an
    /// instant sample; `FakeHealthStore` draws the same distinction (`daily(...)` vs. per-reading
    /// samples).
    func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        return runAnchoredQuery(type: type, range: range, platformType: "HKQuantityTypeIdentifierHeartRate")
            .compactMap { sample -> SampleDTO? in
                guard let qs = sample as? HKQuantitySample else { return nil }
                let (sourceId, deviceId) = provenanceIds(for: qs)
                return SampleDTO(metricId: MetricID.heartRate, value: qs.quantity.doubleValue(for: bpmUnit),
                                 unit: "bpm", start: qs.startDate, end: qs.endDate, tz: tz,
                                 sourceId: sourceId, deviceId: deviceId, externalId: qs.uuid.uuidString)
            }
    }

    /// Resting heart rate (daily, mean) + steps (daily, sum) -> interval DTOs, matching
    /// `FakeHealthStore`'s `daily(...)` shape.
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out: [IntervalDTO] = []
        if let rhrType = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            out += runAnchoredQuery(type: rhrType, range: range, platformType: "HKQuantityTypeIdentifierRestingHeartRate")
                .compactMap { sample -> IntervalDTO? in
                    guard let qs = sample as? HKQuantitySample else { return nil }
                    let (sourceId, deviceId) = provenanceIds(for: qs)
                    return IntervalDTO(metricId: MetricID.restingHeartRate, value: qs.quantity.doubleValue(for: bpmUnit),
                                       unit: "bpm", start: qs.startDate, end: qs.endDate, tz: tz,
                                       aggregation: .mean, sourceId: sourceId, deviceId: deviceId,
                                       externalId: qs.uuid.uuidString)
                }
        }
        out += readDailySteps(range)
        return out
    }

    /// Sleep analysis -> session DTOs with stages, matching `FakeHealthStore`'s `SessionDTO`
    /// shape. HealthKit has no first-class "session" object for sleep — Apple Watch (and most
    /// third-party apps) write one category sample per stage segment — so segments are grouped
    /// into episodes here (see `groupIntoSessions`).
    func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let samples = runAnchoredQuery(type: type, range: range, platformType: "HKCategoryTypeIdentifierSleepAnalysis")
            .compactMap { $0 as? HKCategorySample }
        return groupIntoSessions(samples)
    }

    // MARK: - Steps (HKStatisticsCollectionQuery — no per-sample anchor)

    /// Steps use `HKStatisticsCollectionQuery` with `.cumulativeSum` rather than the
    /// anchored-then-bucket-locally approach used for the other types: a cumulative quantity
    /// like steps is commonly double-written by more than one real source (Watch *and* iPhone
    /// both logging the same walk), and only HealthKit's own statistics aggregation resolves
    /// that overlap correctly — summing raw per-source samples ourselves would double-count.
    /// The tradeoff is no incremental anchor for this one type: each ingest recomputes the full
    /// requested day range, which stays cheap (one grouped query, not one row per step sample)
    /// and is safe because `interval_records` upserts are idempotent by (metric, day, source).
    /// The merged sum has no single attributable HealthKit source, so it's filed under the same
    /// generic `"healthkit"` id used when no source has synced yet — an honest label for a
    /// cross-source total, not a fabricated device.
    private func readDailySteps(_ range: HealthDateRange) -> [IntervalDTO] {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
        let cal = DayAttribution.calendar(tz: tz)
        var interval = DateComponents()
        interval.day = 1
        let anchorDate = cal.startOfDay(for: range.start)

        let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: .cumulativeSum, anchorDate: anchorDate,
                                                intervalComponents: interval)
        let semaphore = DispatchSemaphore(value: 0)
        var out: [IntervalDTO] = []
        query.initialResultsHandler = { [tz] _, results, error in
            defer { semaphore.signal() }
            guard error == nil, let results else { return }
            results.enumerateStatistics(from: range.start, to: range.end) { stats, _ in
                guard let sum = stats.sumQuantity() else { return }
                let value = sum.doubleValue(for: .count())
                guard value > 0 else { return }
                let dayKey = DayAttribution.localDayKey(stats.startDate, tz: tz)
                out.append(IntervalDTO(metricId: MetricID.steps, value: value, unit: "count",
                                       start: stats.startDate, end: stats.endDate, tz: tz,
                                       aggregation: .sum, sourceId: Self.fallbackSourceId,
                                       externalId: "healthkit-steps-\(dayKey)"))
            }
        }
        store.execute(query)
        semaphore.wait()
        return out
    }

    // MARK: - Sleep session grouping

    /// A gap this long between one stage segment's end and the next one's start starts a new
    /// sleep episode (rather than treating a brief wake-and-back-to-sleep gap, or an
    /// end-of-night rounding gap, as two separate episodes).
    private static let sleepClusterGapSeconds: TimeInterval = 3 * 3600
    /// Episodes with at least this much total asleep time count as the primary sleep for their
    /// night; shorter clusters are treated as naps — mirrors `DedupLite`'s separate
    /// `sleepPrimary`/`sleepNap` reconciliation pools (`IngestionPipeline.dedup`), which must
    /// never let a long/high-priority nap outrank the night's actual primary sleep.
    private static let sleepPrimaryMinSeconds: TimeInterval = 3 * 3600

    private func groupIntoSessions(_ samples: [HKCategorySample]) -> [SessionDTO] {
        guard !samples.isEmpty else { return [] }
        let bySource = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }
        var out: [SessionDTO] = []
        for (_, sourceSamples) in bySource {
            let sorted = sourceSamples.sorted { $0.startDate < $1.startDate }
            var cluster: [HKCategorySample] = []
            func flush() {
                guard let first = cluster.first,
                      let last = cluster.max(by: { $0.endDate < $1.endDate }) else { cluster = []; return }
                out.append(makeSession(from: cluster, start: first.startDate, end: last.endDate))
                cluster = []
            }
            for sample in sorted {
                if let previous = cluster.last,
                   sample.startDate.timeIntervalSince(previous.endDate) > Self.sleepClusterGapSeconds {
                    flush()
                }
                cluster.append(sample)
            }
            flush()
        }
        return out
    }

    private func makeSession(from samples: [HKCategorySample], start: Date, end: Date) -> SessionDTO {
        let (sourceId, deviceId) = provenanceIds(for: samples[0])
        var stages: [StageDTO] = []
        var asleep: TimeInterval = 0
        for sample in samples {
            guard let stage = Self.mapSleepStage(sample.value) else { continue }
            stages.append(StageDTO(stage: stage, start: sample.startDate, end: sample.endDate))
            if stage != .awake && stage != .inBed {
                asleep += sample.endDate.timeIntervalSince(sample.startDate)
            }
        }
        let inBedSeconds = end.timeIntervalSince(start)
        let kind: SessionKind = asleep >= Self.sleepPrimaryMinSeconds ? .sleepPrimary : .sleepNap
        return SessionDTO(kind: kind, start: start, end: end, tz: tz, sourceId: sourceId, deviceId: deviceId,
                          externalId: "healthkit-sleep-\(sourceId)-\(Int(start.timeIntervalSince1970))",
                          stages: stages, timeAsleepSeconds: asleep, timeInBedSeconds: inBedSeconds)
    }

    /// HealthKit's stage vocabulary -> BADAN's `SleepStage`. `.asleep` (deprecated, generic
    /// "asleep") shares its raw value with `.asleepUnspecified` and is covered by the same case.
    private static func mapSleepStage(_ rawValue: Int) -> SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepCore: return .light
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        case .asleepUnspecified: return .asleepUnspecified
        default: return nil
        }
    }

    // MARK: - Anchored query + anchor persistence

    /// Run one `HKAnchoredObjectQuery` synchronously (bridged via semaphore — see the type
    /// doc), scoped to `range` (the caller's backfill window; a fixed 90 days on first connect),
    /// resuming from whatever anchor persisted last time so a later call only returns what's new
    /// within that same window. The refreshed anchor is persisted before returning so a query
    /// that fails downstream (e.g. `IngestionPipeline` throwing) doesn't replay from scratch —
    /// the upserts it feeds are idempotent by external id, so at-least-once redelivery here is
    /// safe either way.
    private func runAnchoredQuery(type: HKSampleType, range: HealthDateRange, platformType: String) -> [HKSample] {
        let anchor = loadAnchor(platformType: platformType)
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
        let semaphore = DispatchSemaphore(value: 0)
        var resultSamples: [HKSample] = []
        var resultAnchor = anchor
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                          limit: HKObjectQueryNoLimit) { _, samplesOrNil, _, newAnchor, error in
            if error == nil {
                resultSamples = samplesOrNil ?? []
                resultAnchor = newAnchor ?? anchor
            }
            semaphore.signal()
        }
        store.execute(query)
        semaphore.wait()
        saveAnchor(resultAnchor, platformType: platformType)
        return resultSamples
    }

    private func loadAnchor(platformType: String) -> HKQueryAnchor? {
        guard let data = (try? anchors.anchor(store: Self.fallbackSourceId, platformType: platformType)) ?? nil
        else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor?, platformType: String) {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        else { return }
        try? anchors.setAnchor(store: Self.fallbackSourceId, platformType: platformType, data: data, updatedAt: Date())
    }

    private func querySources(for type: HKSampleType) -> Set<HKSource> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Set<HKSource> = []
        let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sourcesOrNil, _ in
            result = sourcesOrNil ?? []
            semaphore.signal()
        }
        store.execute(query)
        semaphore.wait()
        return result
    }

    // MARK: - Provenance

    /// Real device info where HealthKit provides it, never fabricated: `localIdentifier` is the
    /// closest thing `HKDevice` has to a stable id (falls back to its human-readable `name`).
    private func provenanceIds(for sample: HKSample) -> (sourceId: String, deviceId: String?) {
        let bundleId = sample.sourceRevision.source.bundleIdentifier
        let sourceId = bundleId.isEmpty ? Self.fallbackSourceId : bundleId
        let deviceId = sample.device?.localIdentifier ?? sample.device?.name
        return (sourceId, deviceId)
    }
}
