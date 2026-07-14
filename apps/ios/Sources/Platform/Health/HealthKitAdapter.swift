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
    /// Fallback measured-timezone (DATA-07): the *current* device zone at adapter construction,
    /// used only when a sample carries no valid `HKMetadataKeyTimeZone` of its own — see
    /// `measuredTimeZone(for:)`. No longer stamped unconditionally on every DTO the way it used
    /// to be, since that attributed a post-travel backfill's historical nights to today's zone.
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
                // (DATA-06b) Cheapest correct point to learn this source's device: one
                // newest-sample lookup per distinct source (deduped by the guard above), not a
                // per-record query — see `representativeInfo(for:sampleType:)`.
                let info = representativeInfo(for: source, sampleType: sampleType)
                byBundleId[bundleId] = SourceDescriptor(
                    id: bundleId, displayName: source.name, type: .healthkit, bundleId: bundleId,
                    deviceId: info.device?.localIdentifier ?? info.device?.name,
                    deviceName: info.device?.name,
                    deviceModel: info.device?.model ?? info.productType,
                    priority: Self.sourcePriority(bundleId: bundleId, deviceModel: info.device?.model,
                                                  deviceProductType: info.productType, displayName: source.name))
            }
        }
        // (DATA-06a) File the merged step total's source (the `fallbackSourceId` used
        // unconditionally by `readDailySteps`) even when real per-device sources exist, so its
        // `source_id` always resolves to a cataloged Source row instead of dangling. Dedupe by
        // id in the unlikely case a real source ever shared this bundle id.
        if byBundleId[Self.fallbackSourceId] == nil {
            byBundleId[Self.fallbackSourceId] = Self.fallbackDescriptor
        }
        return byBundleId.values.sorted { $0.id < $1.id }
    }

    private static let fallbackDescriptor = SourceDescriptor(
        id: fallbackSourceId, displayName: "Apple Health", type: .healthkit,
        bundleId: "com.apple.health", priority: 80)

    /// The device info (and hardware `productType`) behind one real HealthKit source, learned
    /// from its single newest sample rather than a per-record query (DATA-06b). `HKSourceQuery`
    /// (`querySources`) returns bare `HKSource` values with no device attached, and HealthKit
    /// has no "device for this source" lookup — a representative sample is the cheapest place
    /// this is actually exposed. `productType` (e.g. "Watch6,1", "iPhone14,5") comes from
    /// `HKSourceRevision`, not `HKDevice` (which only has the human-readable `model`, e.g.
    /// "Watch") — both feed `sourcePriority` below.
    private struct RepresentativeInfo {
        var device: HKDevice? = nil
        var productType: String? = nil
    }

    private func representativeInfo(for source: HKSource, sampleType: HKSampleType) -> RepresentativeInfo {
        let predicate = HKQuery.predicateForObjects(from: source)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        let semaphore = DispatchSemaphore(value: 0)
        var info = RepresentativeInfo()
        let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: 1, sortDescriptors: sort) { _, samplesOrNil, _ in
            let sample = samplesOrNil?.first
            info = RepresentativeInfo(device: sample?.device, productType: sample?.sourceRevision.productType)
            semaphore.signal()
        }
        store.execute(query)
        semaphore.wait()
        return info
    }

    /// Non-Apple wearable/wrist-class keywords, English and their Arabic equivalents (FIX-09):
    /// mirrors `IngestionPipeline.wearableKeywords` (`IngestionPipeline.swift:243`), which is
    /// English-only, plus "ساعة" (watch), "خاتم" (ring), "سوار" (band) so an Arabic-named
    /// third-party source doesn't fall through to priority 0 purely because of language.
    private static let wearableNameKeywords = [
        "watch", "ring", "band", "oura", "whoop", "fenix", "garmin", "fitbit", "polar",
        "ساعة", "خاتم", "سوار",
    ]

    /// Locale-independent dedup priority for a HealthKit source (FIX-09). `IngestionPipeline`'s
    /// own `inferredPriority` (`IngestionPipeline.swift:245-251`) only recognizes English
    /// keywords in `displayName`/`deviceName`/`deviceModel`, so a wearable with an Arabic name
    /// ties at priority 0 against, say, a phone's longer in-bed sleep estimate — violating I4
    /// (device wins dedup ties by source priority) and Arabic-first. Confirmed by reading
    /// `inferredPriority`: it only derives its own value when the descriptor's `priority` is
    /// still 0 (`if d.priority != 0 { return d.priority }`), so any nonzero value this method
    /// returns wins outright and is never re-derived from (English-only) text — no pipeline
    /// change needed for that to hold.
    ///
    /// Produces the same 0/1/2 scale the pipeline does (wearable=2, phone=1, unknown=0),
    /// preferring, in order: (1) the `com.apple.health.*` bundle-id namespace paired with a
    /// watch-class device/productType — the shape real Apple Watch sources take; (2) the
    /// device model/productType string alone, independent of bundle id ("watch" -> wearable,
    /// "iphone" -> phone); (3) name keywords, English then Arabic, as the weakest, last-resort
    /// signal.
    static func sourcePriority(bundleId: String, deviceModel: String?, deviceProductType: String?,
                              displayName: String) -> Int {
        let modelHay = ((deviceModel ?? "") + " " + (deviceProductType ?? "")).lowercased()
        if bundleId.hasPrefix("com.apple.health"), modelHay.contains("watch") { return 2 }
        if modelHay.contains("watch") { return 2 }
        if modelHay.contains("iphone") { return 1 }
        let nameHay = displayName.lowercased()
        if Self.wearableNameKeywords.contains(where: nameHay.contains) { return 2 }
        if nameHay.contains("phone") || displayName.contains("هاتف") { return 1 }
        return 0
    }

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
                                 unit: "bpm", start: qs.startDate, end: qs.endDate, tz: measuredTimeZone(for: qs),
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
                                       unit: "bpm", start: qs.startDate, end: qs.endDate, tz: measuredTimeZone(for: qs),
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
                // (DATA-07) `stats` is a same-day cumulative sum across every contributing
                // sample/source (see the type doc above) — HKStatisticsCollectionQuery exposes
                // no per-contributing-sample metadata, so there is no single "the" measured
                // timezone to read here the way `measuredTimeZone(for:)` does for individual
                // HKSamples elsewhere in this file. `tz` (current device zone) is used as-is;
                // this bucket is honestly an assumption on backfill-after-travel, which is
                // exactly what `.tzAssumed` exists to flag (see `measuredTimeZone(for:)`'s doc
                // comment for why that flag can't be threaded onto this DTO today).
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
        return SessionDTO(kind: kind, start: start, end: end, tz: measuredTimeZone(for: samples[0]),
                          sourceId: sourceId, deviceId: deviceId,
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

    /// The timezone a sample was actually measured in (DATA-07), not whatever zone this device
    /// happens to be in right now: HealthKit stamps `HKMetadataKeyTimeZone` on a sample when the
    /// recording device knew its own zone at write time (Apple Watch and most first-party
    /// sources do), which is what `DayAttribution`'s "timezone at measurement" contract needs
    /// for correct day/night bucketing after travel — attributing a post-trip backfill to
    /// today's zone silently misfiles historical nights. Falls back to the adapter's captured
    /// `tz` (current device zone, see the `tz` property doc) only when no valid per-sample zone
    /// is present.
    ///
    /// NOTE (DATA-07, partial fix): a sample that falls back to `tz` here should also carry the
    /// `.tzAssumed` quality flag on its `Provenance` — the same way `.estimate` is stamped for a
    /// failed unit conversion in `IngestionPipeline.canonicalValue`. That threading is NOT
    /// implemented: `SampleDTO`/`IntervalDTO`/`SessionDTO` (`HealthStorePort.swift`) carry no
    /// quality-flag field an adapter can populate, and `IngestionPipeline.platformProvenance`
    /// (`IngestionPipeline.swift`) would need to merge an adapter-supplied flag into the
    /// `qualityFlags` it stamps — both files are out of scope for this fix (see this task's
    /// report for the exact change needed in each).
    private func measuredTimeZone(for sample: HKSample) -> String {
        if let raw = sample.metadata?[HKMetadataKeyTimeZone] as? String, TimeZone(identifier: raw) != nil {
            return raw
        }
        return tz
    }
}
