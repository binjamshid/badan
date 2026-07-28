import CoreLocation
import Foundation
import HealthKit

/// Real HealthKit integration boundary (FEAT-01, widened by PERF-181/EPIC-01 and EPIC-03).
/// Reads the vitals, activity, body and workout families described by `HKTypeMap` — discrete
/// types via `HKAnchoredObjectQuery`, cumulative types via `HKStatisticsCollectionQuery` (see
/// `readDailySum`), sleep via its own night-rebuild seam, workouts as sessions, and workout
/// routes only behind their own consent gate — mapped to the exact DTO shapes `FakeHealthStore`
/// produces so `IngestionPipeline` treats both sources identically. `HealthStorePort`'s
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
    /// Consulted at the instant a route would be read (plan §4.11). Fail-closed by default —
    /// see `DeniedRouteConsent`'s doc for why the default is "no routes" rather than an optional
    /// that could be forgotten.
    private let routeConsent: RouteConsentProviding
    /// Fallback measured-timezone (DATA-07): the *current* device zone at adapter construction,
    /// used only when a sample carries no valid `HKMetadataKeyTimeZone` of its own — see
    /// `measuredTimeZone(for:)`. No longer stamped unconditionally on every DTO the way it used
    /// to be, since that attributed a post-travel backfill's historical nights to today's zone.
    private let tz: String

    /// Deletions collected by the most recent `readSamples`/`readIntervals` calls, drained by
    /// `deletions(_:)` (BUG-10). Populated in-process rather than by re-running the same
    /// anchored HealthKit queries a second time just to recover their `deletedObjects` — cheap,
    /// and correct as long as `deletions(_:)` is called right after the read* calls for the same
    /// range within one ingest pass, which is exactly how `IngestionPipeline.ingest` calls it.
    private var pendingDeletions = HealthStoreDeletions()

    /// Anchors advanced by the most recent read* calls, held in memory until `commitPendingAnchors()`
    /// (DATA-08): persisting them here immediately (the old behavior) assumed the anchor write
    /// shared a transaction with the ingest write, which stopped being true once HealthKit reads
    /// moved outside `IngestionPipeline`'s write transaction (see `runAnchoredQuery`'s doc).
    private var pendingAnchors: [String: HKQueryAnchor] = [:]

    /// The single `store` key under which every HealthKit anchor/permission-state row is filed
    /// (matches `SourcesScreen`'s `"healthkit"` permission-store label) and the sourceId used
    /// for values HealthKit only ever returns pre-merged across sources (see `readDailySteps`)
    /// or when no data has synced yet (see `sourceDescriptors`) — using this shared token rather
    /// than fabricating a device-specific id keeps provenance honest in both cases.
    private static let fallbackSourceId = HKSampleMapping.fallbackSourceId

    init(anchors: ReadAnchorRepository, tz: String = TimeZone.current.identifier,
         routeConsent: RouteConsentProviding = DeniedRouteConsent()) {
        self.anchors = anchors
        self.tz = tz
        self.routeConsent = routeConsent
    }

    /// The main read set, now derived from `HKTypeMap` rather than hand-maintained here — this
    /// is the TODO(PERF-181) that used to sit on this property. See `HKTypeMap`'s type doc for
    /// why the binding table is its own file and deliberately not read out of `registry.json`.
    ///
    /// Built once (rather than per `requestAuthorization` call) since each row is a pure lookup
    /// of a fixed identifier.
    private static let readTypes: Set<HKObjectType> = HKTypeMap.authorizationReadTypes

    /// Workout routes, requested SEPARATELY and only from the route-consent screen (plan
    /// §13.1). Keeping them out of `readTypes` is what makes the first authorization sheet match
    /// the usage string `project.yml` ships: that string describes vitals, activity, body
    /// measurements and workouts, and says nothing about location — asking for routes in the
    /// same prompt would request something the prompt never explains.
    static let routeReadTypes: Set<HKObjectType> = [HKSeriesType.workoutRoute()]

    func availability() -> HealthAvailability {
        HKHealthStore.isHealthDataAvailable() ? .available : .unsupported
    }

    /// Ask to READ the main types, awaiting the system sheet. `true` means the request completed
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

    /// Ask to READ workout routes. Called ONLY by the route-consent screen, after its explainer
    /// — never from onboarding's connect step, and never implicitly as a side effect of a sync.
    ///
    /// Returns the same "the sheet completed" signal `requestAuthorization` does, and for the
    /// same reason it cannot mean more than that. Note that HealthKit permission and BADAN's own
    /// route toggle are two independent gates: this grants the platform's side, while
    /// `RouteConsentProviding` is what actually decides whether `readWorkouts` reads a trace. A
    /// user who grants the system sheet and then switches BADAN's toggle off gets no route rows,
    /// which is the correct reading of "off".
    func requestRouteAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: Self.routeReadTypes) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Discover which real HealthKit sources have contributed data for our read types, so
    /// dedup priority (watch vs. phone) and per-record provenance reflect the device that
    /// actually recorded each reading rather than a single fabricated "Apple Health" stand-in.
    /// Falls back to one generic descriptor when nothing has synced yet (denied, no data, or
    /// the simulator) — `IngestionPipeline` always needs at least one source row to attach to.
    ///
    /// (EPIC-01) Scans every ingesting type rather than a representative subset, which matters
    /// now that the read set spans four families: a smart scale writes `bodyMass` and nothing
    /// else, so probing only heart/sleep types would leave it undiscovered and its readings
    /// attributed to a dangling source id. The cost is one `HKSourceQuery` per ingesting type
    /// per sync (~14 round trips, each cheap and index-backed); the per-source
    /// `representativeInfo` lookup is still bounded by the number of distinct sources thanks to
    /// the dedupe guard below, not by the number of types. If this ever shows up in a sync
    /// profile, cache the descriptor set across syncs rather than narrowing the type list —
    /// narrowing reintroduces the undiscovered-scale bug.
    func sourceDescriptors() -> [SourceDescriptor] {
        guard HKHealthStore.isHealthDataAvailable() else { return [Self.fallbackDescriptor] }
        var byBundleId: [String: SourceDescriptor] = [:]
        var discoveryTypes: [HKSampleType] = HKTypeMap.sourceDiscoveryTypes
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { discoveryTypes.append(sleep) }
        discoveryTypes.append(HKObjectType.workoutType())
        for sampleType in discoveryTypes {
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

    /// Body-composition instruments — smart scales and the vendor apps that front them (EPIC-01
    /// task 9, plan §10 "extend priority table to energy/distance").
    ///
    /// Without this tier a Withings or Renpho scale matches neither the wearable nor the phone
    /// keywords and lands at priority 0, so `IngestionPipeline.inferredPriority` leaves it there
    /// and a weight it actually measured is reconciled against a phone's hand-typed figure by
    /// arbitrary id tie-breaking. A scale is a purpose-built measuring instrument for exactly the
    /// three metrics it writes (weight, body fat, lean mass) and reports nothing else, so giving
    /// it the same tier as a wrist device is safe: the two never compete for a metric, because a
    /// watch does not weigh you.
    ///
    /// (Note this is orthogonal to I4's "manual wins for weight" rule — that compares a manual
    /// entry against a device reading and is decided by ingestion path, not by this number, which
    /// only orders devices against each other.)
    ///
    /// The cumulative activity families (energy, distance, flights) need no tier of their own:
    /// they are read via `HKStatisticsCollectionQuery`, which resolves cross-source overlap
    /// inside HealthKit and returns a pre-merged total filed under `fallbackSourceId` — there is
    /// no per-device competition left for a priority to settle. See `readDailySum`.
    private static let bodyCompositionKeywords = [
        "scale", "withings", "renpho", "eufy", "tanita", "omron", "fitindex", "wyze",
        "ميزان",
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
        // Checked after the wearable keywords and before the phone fallback: a source matching
        // both (a vendor app named "Withings Health Mate" that also fronts a watch) is already
        // resolved as a wearable above, and a scale must never fall through to the phone tier.
        if Self.bodyCompositionKeywords.contains(where: modelHay.contains)
            || Self.bodyCompositionKeywords.contains(where: nameHay.contains)
            || displayName.contains("ميزان") { return 2 }
        if nameHay.contains("phone") || displayName.contains("هاتف") { return 1 }
        return 0
    }

    // MARK: - HealthStorePort reads

    /// Instantaneous readings -> raw samples, one anchored query per `.anchoredSample` row of
    /// `HKTypeMap` (heart rate, SpO2, weight, body fat, lean mass), matching `FakeHealthStore`'s
    /// shapes for the same metrics.
    ///
    /// `restingHeartRate` is intentionally *not* here — HealthKit emits it as one
    /// already-computed value per day, which is an interval (see `readAnchoredIntervals`), not an
    /// instant sample; `FakeHealthStore` draws the same distinction (`daily(...)` vs. per-reading
    /// samples).
    ///
    /// (DATA-08) Every type goes through `runAnchoredQuery`, so every type's refreshed anchor
    /// lands in `pendingAnchors` and is only persisted by `commitPendingAnchors()` after the
    /// write transaction commits. That discipline is not per-type opt-in and there is no path
    /// here that writes an anchor directly — adding one would silently reintroduce DATA-08 for
    /// whichever type took the shortcut.
    func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out: [SampleDTO] = []
        for entry in HKTypeMap.anchoredSampleEntries {
            guard let metricId = entry.metricId, let type = entry.quantityType else { continue }
            let result = runAnchoredQuery(type: type, range: range, platformType: entry.platformType)
            // Shared with `HistoricalHealthKitReader` (D-35 item 2b) — see `HKSampleMapping`'s doc
            // for why the two paths must not each own a copy of this.
            out += result.samples.compactMap {
                HKSampleMapping.sampleDTO($0, entry: entry, metricId: metricId, fallbackTz: tz)
            }
            // (BUG-10a) A deleted sample's UUID *is* the externalId it was ingested under, so
            // the mapping back to a soft-deletable row is exact, not a guess. Extended verbatim
            // from heart rate to every discrete type: the property that makes it exact (HealthKit
            // UUIDs are globally unique regardless of source) is not heart-rate-specific.
            pendingDeletions.samples += result.deletedUUIDs.map {
                DeletedExternalRecord(metricId: metricId, externalId: $0)
            }
        }
        return out
    }

    /// Interval DTOs, matching `FakeHealthStore`'s `daily(...)` shape: the already-summarized
    /// discrete types (resting heart rate, HRV, VO2 max, respiratory rate) followed by the
    /// cumulative types recomputed per day (steps, active/basal energy, distance, flights).
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out = readAnchoredIntervals(range)
        for entry in HKTypeMap.cumulativeEntries {
            out += readDailySum(entry, range: range)
        }
        return out
    }

    /// The `.anchoredInterval` rows of `HKTypeMap`: discrete HealthKit samples that are already
    /// summaries in their own right, carried through with their own span.
    ///
    /// Known limitation, stated plainly because it is visible in the product: resting heart rate
    /// and VO2 max are emitted by HealthKit at most once per day, so each becomes exactly one
    /// interval row per day — but HRV and respiratory rate can be written many times a day (the
    /// Watch samples both repeatedly overnight), and each of those samples becomes its own
    /// interval row. `BaselineEngine.latestPerDay` then picks ONE of that day's rows rather than
    /// averaging them, which makes the day's baseline input an arbitrary (if deterministic —
    /// see DATA-09) reading rather than the day's mean.
    ///
    /// The right fix is a derived daily rollup owned by the derivation layer — the same shape
    /// `IngestionPipeline.upsertDailySleepInterval` already uses for sleep: an append-only (I2)
    /// derived row carrying its own `AlgorithmVersion`, computed from the stored samples. It is
    /// deliberately NOT done here, because an adapter has neither the history nor the versioning
    /// to compute a defensible daily aggregate, and folding an unversioned average into an
    /// ingestion read would make a derived number indistinguishable from a measured one (I5).
    /// Until then every reading is stored faithfully and nothing is lost — only the daily
    /// summary is coarser than it will eventually be.
    private func readAnchoredIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        var out: [IntervalDTO] = []
        for entry in HKTypeMap.anchoredIntervalEntries {
            guard case .anchoredInterval(let aggregation) = entry.strategy,
                  let metricId = entry.metricId, let type = entry.quantityType else { continue }
            let result = runAnchoredQuery(type: type, range: range, platformType: entry.platformType)
            out += result.samples.compactMap {
                HKSampleMapping.intervalDTO($0, entry: entry, metricId: metricId,
                                            aggregation: aggregation, fallbackTz: tz)
            }
            // (BUG-10a) Same exact-UUID mapping as the raw samples above.
            pendingDeletions.intervals += result.deletedUUIDs.map {
                DeletedExternalRecord(metricId: metricId, externalId: $0)
            }
        }
        return out
    }

    /// Deletions surfaced by the `readSamples`/`readIntervals` calls above, for this same
    /// `range` (BUG-10). See the `pendingDeletions` property doc for why this drains an
    /// in-process buffer instead of re-querying HealthKit.
    func deletions(_ range: HealthDateRange) -> HealthStoreDeletions {
        defer { pendingDeletions = HealthStoreDeletions() }
        return pendingDeletions
    }

    /// Persists every anchor advanced by the read* calls since the last commit (DATA-08). See
    /// the `pendingAnchors` property doc and `runAnchoredQuery`'s doc for why this is deferred
    /// rather than persisted eagerly inside the read itself.
    func commitPendingAnchors() {
        for (platformType, anchor) in pendingAnchors {
            saveAnchor(anchor, platformType: platformType)
        }
        pendingAnchors.removeAll()
    }

    /// Sleep analysis -> session DTOs with stages, matching `FakeHealthStore`'s `SessionDTO`
    /// shape. HealthKit has no first-class "session" object for sleep — Apple Watch (and most
    /// third-party apps) write one category sample per stage segment — so segments are grouped
    /// into episodes here (see `groupIntoSessions`).
    ///
    /// (BUG-11b) The anchored delta below is used ONLY as a signal for which local nights
    /// changed this sync — never clustered into sessions directly. Clustering only the delta
    /// would slice one real night's sleep into two partial sessions whenever it's delivered
    /// across two anchored-query batches (e.g. the Watch syncs mid-morning and the phone
    /// catches up hours later), and could flip a cluster's primary/nap classification on
    /// redelivery without ever correcting the earlier session it should have replaced. Instead,
    /// once an affected night is known, `sessionsForNight` re-queries HealthKit for that whole
    /// night's COMPLETE current sample set (a cheap, bounded per-night `HKSampleQuery`) and
    /// re-clusters from that, so every re-ingest reflects everything HealthKit has for the
    /// night, not just what changed.
    ///
    /// Known limitation: if EVERY sample for a night is deleted (none remain), that night never
    /// appears in `deltaSamples` (deletions carry no date — see `HealthStoreDeletions`'s doc —
    /// so there is nothing to derive an affected night from), and its stale session row is not
    /// rebuilt or removed by this path. Out of scope for BUG-11/BUG-10 as specified: the
    /// tractable, testable fix here is night-keyed identity + full-night rebuild + the
    /// conflict-target migration; a fully-wiped night needs a different signal HealthKit's
    /// anchored-query API doesn't provide.
    func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let deltaResult = runAnchoredQuery(type: type, range: range, platformType: "HKCategoryTypeIdentifierSleepAnalysis")
        let deltaSamples = deltaResult.samples.compactMap { $0 as? HKCategorySample }

        var affectedNights = Set(deltaSamples.map { sample in
            DayAttribution.localNight(sessionEnd: sample.endDate, tz: measuredTimeZone(for: sample).tz)
        })

        // (F4) A sync can carry deletions and no samples — trim a sleep segment in Health, or
        // delete a nap outright, and nothing is re-added. The old `guard !deltaSamples.isEmpty`
        // returned early on exactly that sync, so the stale session survived indefinitely: BADAN
        // kept showing sleep the user had already removed from Health, which is both wrong and
        // the opposite of the deletion promise.
        //
        // Deletions carry no date (see `HealthStoreDeletions`), so there is no night to derive
        // from them — that is the limitation documented above. But their COUNT is a signal: if
        // sleep rows were deleted, rebuild the recent nights and let the full-night re-cluster
        // notice what is gone. Bounded to `deletionRebuildNights` so this stays a handful of
        // cheap per-night queries rather than a 90-day rescan, and clamped to the caller's range
        // so a narrow sync doesn't reach outside it.
        if !deltaResult.deletedUUIDs.isEmpty {
            affectedNights.formUnion(recentNights(in: range, count: Self.deletionRebuildNights))
        }

        guard !affectedNights.isEmpty else { return [] }

        var sessions: [SessionDTO] = []
        for night in affectedNights.sorted() {
            sessions += sessionsForNight(night, categoryType: type)
        }
        return sessions
    }

    /// How many recent nights a deletion-only sleep sync rebuilds (F4). Sleep is edited close to
    /// when it happened — a week covers retroactive trimming and nap deletion without turning
    /// every deletion into a full-history rescan.
    private static let deletionRebuildNights = 7

    /// The last `count` local night keys ending at `range.end`, never starting before
    /// `range.start`.
    private func recentNights(in range: HealthDateRange, count: Int) -> Set<String> {
        var nights: Set<String> = []
        for offset in 0..<count {
            let day = DayAttribution.addingDays(-offset, to: range.end, tz: tz)
            guard day >= range.start else { break }
            nights.insert(DayAttribution.localDayKey(day, tz: tz))
        }
        return nights
    }

    /// Re-cluster one local night's sleep from HealthKit's COMPLETE current sample set (not
    /// just an anchored delta) — see `readSessions`'s doc for why. The query window pads the
    /// night's calendar day by `sleepClusterGapSeconds` on each side (sleep can start the
    /// evening before its attributed day and, rarely, run past the day boundary the next
    /// morning); results are then filtered back down to clusters actually attributed to THIS
    /// night, since a wide window can also catch the tail of an adjacent night.
    private func sessionsForNight(_ night: String, categoryType: HKCategoryType) -> [SessionDTO] {
        Self.sessionsForNight(night, categoryType: categoryType, store: store, tz: tz)
    }

    /// `static` for the same reason as `readDailySum` above — see its doc.
    ///
    /// This is the ONLY way a historical import is allowed to build sleep sessions. Re-clustering
    /// from a fresh query would be the single most likely source of duplicate nights: identity here
    /// is night-keyed plus a within-night ordinal (`disambiguateWithinNight`), and any second
    /// clustering path would have to reproduce both exactly or silently double every night it
    /// touched.
    static func sessionsForNight(_ night: String, categoryType: HKCategoryType,
                                 store: HKHealthStore, tz: String) -> [SessionDTO] {
        guard let dayStart = DayAttribution.date(fromDayKey: night, tz: tz) else { return [] }
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
        let windowStart = dayStart.addingTimeInterval(-Self.sleepClusterGapSeconds - 12 * 3600)
        let windowEnd = dayEnd.addingTimeInterval(Self.sleepClusterGapSeconds)
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)
        let semaphore = DispatchSemaphore(value: 0)
        var samples: [HKCategorySample] = []
        let query = HKSampleQuery(sampleType: categoryType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samplesOrNil, error in
            defer { semaphore.signal() }
            guard error == nil else { return }
            samples = (samplesOrNil as? [HKCategorySample]) ?? []
        }
        store.execute(query)
        semaphore.wait()
        let forThisNight = groupIntoSessions(samples, tz: tz)
            .filter { DayAttribution.localNight(sessionEnd: $0.end, tz: $0.tz) == night }
        return Self.disambiguateWithinNight(forThisNight)
    }

    /// (F1) Give every cluster beyond the first in a given (source, night) a distinct
    /// `externalId`.
    ///
    /// `makeSession` keys identity by night alone, which is right for the redelivery case
    /// BUG-11a fixed but wrong the moment one source reports more than one cluster for the same
    /// night — exactly what `groupIntoSessions` is built to emit (naps, or sleep broken by a
    /// wake gap longer than `sleepClusterGapSeconds`). Since migration v3 dropped `kind` from
    /// the sessions identity index, those clusters collided on `(external_id, source_id)` and
    /// the last one written silently overwrote the earlier ones via `ON CONFLICT DO UPDATE` —
    /// a nap could erase the night's primary sleep. Apple Watch tracks naps by default, so this
    /// reached ordinary users.
    ///
    /// The disambiguator is the cluster's ordinal by start within the night rather than its
    /// start instant: a cluster's start moves earlier as more of a night syncs (the case
    /// BUG-11a's comment describes), which would make an instant-keyed id insert a duplicate
    /// instead of updating in place, whereas the ordinal is stable because `sessionsForNight`
    /// always re-clusters the night's COMPLETE current sample set. It is assigned here — after
    /// the caller's night filter — and not inside `groupIntoSessions`, because that query window
    /// deliberately over-fetches adjacent nights; counting clusters that are about to be
    /// filtered out would make the ordinals depend on neighbouring nights' data.
    ///
    /// The first cluster keeps the bare night-keyed id it has always had, so sessions already
    /// stored by earlier builds keep upserting in place instead of being orphaned next to a
    /// newly-suffixed row. If a night's cluster ordering later changes (HealthKit delivers an
    /// earlier nap), rows re-shuffle across ids but no cluster is lost: the full-night rebuild
    /// rewrites all of them together.
    ///
    /// Kept a static pure function (and internal rather than private) for the same reason
    /// `sourcePriority` is: everything around it needs a live `HKHealthStore`, so this is the
    /// only seam at which the clustering identity rule can be unit-tested at all.
    static func disambiguateWithinNight(_ sessions: [SessionDTO]) -> [SessionDTO] {
        var out: [SessionDTO] = []
        for (_, group) in Dictionary(grouping: sessions, by: { $0.externalId }) {
            // Ties broken by end then stage count so the ordering is total and deterministic
            // across rebuilds; two clusters from one source can't really share a start instant,
            // but an unstable sort here would silently churn identities if they did.
            let ordered = group.sorted {
                ($0.start, $0.end, $0.stages.count) < ($1.start, $1.end, $1.stages.count)
            }
            for (ordinal, session) in ordered.enumerated() {
                var session = session
                if ordinal > 0 { session.externalId += "-\(ordinal)" }
                out.append(session)
            }
        }
        return out
    }

    // MARK: - Cumulative daily totals (HKStatisticsCollectionQuery — no per-sample anchor)

    /// Cumulative types (steps, active energy, basal energy, distance, flights) use
    /// `HKStatisticsCollectionQuery` with `.cumulativeSum` rather than the anchored-then-
    /// bucket-locally approach used for the discrete types: a cumulative quantity like steps or
    /// active energy is commonly double-written by more than one real source (Watch *and* iPhone
    /// both logging the same walk), and only HealthKit's own statistics aggregation resolves
    /// that overlap correctly — summing raw per-source samples ourselves would double-count.
    /// The tradeoff is no incremental anchor for these types: each ingest recomputes the full
    /// requested day range, which stays cheap (one grouped query per type, not one row per
    /// sample) and is safe because `interval_records` upserts are idempotent by
    /// (metric, day, source). The merged sum has no single attributable HealthKit source, so
    /// it's filed under the same generic `"healthkit"` id used when no source has synced yet —
    /// an honest label for a cross-source total, not a fabricated device.
    ///
    /// (EPIC-01) Generalized from the steps-only `readDailySteps`. Every behavior below —
    /// BUG-10b's unconditional zero-day emission, DATA-07's honest `.tzAssumed`, the day-keyed
    /// external id — applies identically to the energy/distance/flights families, because each
    /// one is the same kind of thing: a cross-source daily total with no per-sample metadata.
    private func readDailySum(_ entry: HKTypeMap.Entry, range: HealthDateRange) -> [IntervalDTO] {
        Self.readDailySum(entry, range: range, store: store, tz: tz)
    }

    /// `static` so `HistoricalHealthKitReader` can reuse it without holding an adapter (D-35 item
    /// 2b). That matters: a type with no access to `pendingAnchors` cannot advance or commit a
    /// live-sync anchor by accident, which is what makes "a historical import leaves `read_anchors`
    /// byte-identical" a structural property rather than a convention.
    ///
    /// Safe to share precisely because this read is already anchor-free and idempotent — it
    /// recomputes any window from day-keyed external ids, so running it over an overlapping range
    /// upserts in place rather than doubling.
    static func readDailySum(_ entry: HKTypeMap.Entry, range: HealthDateRange,
                             store: HKHealthStore, tz: String) -> [IntervalDTO] {
        guard let metricId = entry.metricId, let type = entry.quantityType else { return [] }
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
                let value = stats.sumQuantity()?.doubleValue(for: entry.hkUnit) ?? 0
                let dayKey = DayAttribution.localDayKey(stats.startDate, tz: tz)
                // (BUG-10b) Always emit one interval per day in range, INCLUDING zero-sum days
                // — the old `guard value > 0 else { return }` here meant a day that went from N
                // steps to 0 (every contributing sample deleted since the last sync) kept its
                // stale positive total forever, since no DTO ever arrived to correct it.
                // `IngestionPipeline` is the one that decides whether a *fresh* zero-valued day
                // is worth writing at all (only when a row already exists for that identity —
                // i.e. this is a correction, not the first-connect 90-day backfill discovering
                // 90 days most of which the user never owned a phone/watch for) so emitting
                // unconditionally here can't manufacture backfill noise on its own.
                //
                // `isRecomputedDailyTotal` is how the pipeline knows this row is a full
                // recompute (so a zero means "summed to zero", not "no data"). It used to infer
                // that from `metricId == steps`; now that four more families take this path,
                // the adapter states the property instead of the pipeline guessing it from an
                // id list it would have to keep in sync.
                //
                // (DATA-07) `stats` is a same-day cumulative sum across every contributing
                // sample/source (see the type doc above) — HKStatisticsCollectionQuery exposes
                // no per-contributing-sample metadata, so there is no single "the" measured
                // timezone to read here the way `measuredTimeZone(for:)` does for individual
                // HKSamples elsewhere in this file. `tz` (current device zone) is used as-is, so
                // this bucket is honestly always a `.tzAssumed` assumption (relevant on
                // backfill-after-travel) — now that `IntervalDTO` carries a quality-flags field,
                // that can finally be threaded through instead of just noted in a comment.
                out.append(IntervalDTO(metricId: metricId, value: value, unit: entry.badanUnit,
                                       start: stats.startDate, end: stats.endDate, tz: tz,
                                       aggregation: .sum, sourceId: Self.fallbackSourceId,
                                       externalId: entry.dailyTotalExternalId(dayKey: dayKey),
                                       qualityFlags: [.tzAssumed], isRecomputedDailyTotal: true))
            }
        }
        store.execute(query)
        semaphore.wait()
        return out
    }

    // MARK: - Workouts (EPIC-03)

    /// Ingested workout episodes -> `WorkoutDTO`, and — only under route consent — each one's
    /// GPS trace.
    ///
    /// Uses the same `runAnchoredQuery` + two-phase anchor discipline as every other type
    /// (DATA-08): a workout whose session row fails to commit must be re-delivered on the next
    /// sync, not skipped forever because its anchor advanced first. This matters more for
    /// workouts than for a heart-rate sample — losing one HR reading out of thousands is
    /// invisible, losing a workout loses a whole session, its totals and its route.
    ///
    /// Totals are read via `HKWorkout.statistics(for:)` rather than the `totalEnergyBurned` /
    /// `totalDistance` convenience properties. Those are deprecated in recent SDKs, and the
    /// statistics API is also the more correct source: it reports what was actually recorded per
    /// quantity type, including average and maximum heart rate, without a second query per
    /// workout.
    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let workoutType = HKObjectType.workoutType()
        let result = runAnchoredQuery(type: workoutType, range: range,
                                      platformType: Self.workoutPlatformType)

        // Read consent ONCE per pass rather than per workout, so a toggle flipped mid-backfill
        // cannot produce a half-consented batch where some workouts carry traces and others
        // don't for no reason the user could explain. The snapshot recorded on each route row is
        // this same value, which is what makes `consent_snapshot` a true statement about the
        // batch rather than about whichever instant a given row happened to be written.
        let consent = routeConsent.routeConsent()

        var out: [WorkoutDTO] = []
        for sample in result.samples {
            guard let workout = sample as? HKWorkout else { continue }
            // Routes are read only with consent — the query is never even issued otherwise, so
            // there is no code path on which an unconsented trace exists in memory. Guarding at
            // the read (rather than filtering before the write) is deliberate: it is the only
            // placement where "off" also means "we did not look".
            let route = consent.granted ? readRoute(for: workout, consent: consent) : nil
            // Shared with `HistoricalHealthKitReader`, so both paths derive the same external id.
            out.append(HKSampleMapping.workoutDTO(workout, totals: Self.totals(for: workout),
                                                  route: route, fallbackTz: tz))
        }

        // (BUG-10a, extended) Unlike sleep, a deleted workout maps to exactly one session row:
        // its `externalId` embeds this same UUID. See `HealthStoreDeletions`'s doc for why sleep
        // cannot do this and workouts can.
        pendingDeletions.sessions += result.deletedUUIDs.map {
            DeletedExternalRecord(externalId: HKSampleMapping.workoutExternalId(uuid: $0))
        }
        return out
    }

    /// Anchor key for the workout type. `HKObjectType.workoutType()` has no
    /// `HKQuantityTypeIdentifier`, so this is spelled out rather than derived from `HKTypeMap` —
    /// it matches the `identifier` HealthKit itself uses for the type, so it reads the same as
    /// every other key in `read_anchors`.
    private static let workoutPlatformType = "HKWorkoutTypeIdentifier"

    /// Totals as the recording device reported them, in as-reported units (see `WorkoutTotals`).
    ///
    /// Distance is probed across the activity-appropriate quantity types because HealthKit files
    /// it under a different one per sport — a swim's distance is `distanceSwimming`, a ride's is
    /// `distanceCycling`. Reading only `distanceWalkingRunning` (the obvious choice) would report
    /// every bike ride and every swim as having no distance at all, which reads as a broken
    /// import rather than as the wrong query.
    static func totals(for workout: HKWorkout) -> WorkoutTotals {
        let kcal = HKQuantityType(.activeEnergyBurned)
        let hr = HKQuantityType(.heartRate)
        let bpm = HKUnit.count().unitDivided(by: .minute())

        var distance: Double?
        for identifier in Self.distanceIdentifiers {
            if let meters = workout.statistics(for: HKQuantityType(identifier))?
                .sumQuantity()?.doubleValue(for: .meter()) {
                distance = meters
                break
            }
        }

        let hrStats = workout.statistics(for: hr)
        // `HKMetadataKeyElevationAscended` is the only place elevation gain is exposed for a
        // workout; it is absent for most indoor and phone-recorded sessions, which is reported
        // as absent rather than as zero.
        let elevation = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
            .doubleValue(for: .meter())

        return WorkoutTotals(
            energyKcal: workout.statistics(for: kcal)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            distanceMeters: distance,
            avgHeartRateBpm: hrStats?.averageQuantity()?.doubleValue(for: bpm),
            maxHeartRateBpm: hrStats?.maximumQuantity()?.doubleValue(for: bpm),
            elevationGainMeters: elevation)
    }

    /// Probed in order; the first type with a recorded sum wins. Walking/running first because
    /// it is by far the most common, then the sports that file distance elsewhere.
    private static let distanceIdentifiers: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        .distanceWheelchair, .distanceDownhillSnowSports,
    ]

    // MARK: - Routes (EPIC-03, consent-gated)

    /// Read one workout's GPS trace. Called ONLY when `routeConsent.routeConsent().granted` is
    /// true — see `readWorkouts`.
    ///
    /// Two queries, in the order HealthKit requires: an `HKAnchoredObjectQuery` scoped to this
    /// workout finds the route OBJECTS, then one `HKWorkoutRouteQuery` per object streams the
    /// locations. The route objects are read with a nil anchor and are deliberately NOT filed in
    /// `pendingAnchors` — a route is re-read in full whenever its workout is re-delivered, and
    /// `RouteRepository.upsert` replaces the trace wholesale, so an incremental cursor here would
    /// buy nothing and would introduce a second, independently-advancing anchor that could drift
    /// out of step with the workout's own.
    private func readRoute(for workout: HKWorkout, consent: RouteConsent) -> RouteDTO? {
        let routeObjects = queryRouteObjects(for: workout)
        guard !routeObjects.isEmpty else { return nil }

        // A workout can carry more than one route object (a paused-and-resumed session). They
        // are concatenated into one trace in start order — the user recorded one outing, and
        // splitting it into fragments would make the map preview and any GPX export lie about
        // what happened.
        var accumulator = RouteAccumulator()
        for routeObject in routeObjects.sorted(by: { $0.startDate < $1.startDate }) {
            accumulator.append(contentsOf: streamLocations(of: routeObject))
        }
        let points = accumulator.finish()
        guard !points.isEmpty else { return nil }
        return RouteDTO(externalId: "healthkit-route-\(workout.uuid.uuidString)",
                        points: points, consent: consent)
    }

    private func queryRouteObjects(for workout: HKWorkout) -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let semaphore = DispatchSemaphore(value: 0)
        var routes: [HKWorkoutRoute] = []
        let query = HKAnchoredObjectQuery(type: HKSeriesType.workoutRoute(), predicate: predicate,
                                          anchor: nil, limit: HKObjectQueryNoLimit) { _, samples, _, _, error in
            defer { semaphore.signal() }
            guard error == nil else { return }
            routes = (samples as? [HKWorkoutRoute]) ?? []
        }
        store.execute(query)
        semaphore.wait()
        return routes
    }

    /// Drain one `HKWorkoutRoute` into points.
    ///
    /// (EPIC-03 risk: "HK route chunk callbacks (multi-batch)") `HKWorkoutRouteQuery`'s handler
    /// fires REPEATEDLY — HealthKit streams a long trace in several batches and only sets `done`
    /// on the last one. Signalling the semaphore on the first callback (the obvious mistake, and
    /// the shape every other query in this file legitimately uses) would return a truncated
    /// route and leave the query running against a dead continuation. So: accumulate on every
    /// callback, signal exactly once — on `done`, or on an error, whichever comes first.
    ///
    /// An error mid-stream discards the partial trace rather than storing it. A route is a claim
    /// about where someone went; half of one, stored with no marker saying so, would render as a
    /// complete path that simply stops — indistinguishable from the user having stopped there.
    /// Dropping it means the next sync re-reads the workout and tries again, which is the
    /// recoverable outcome.
    private func streamLocations(of route: HKWorkoutRoute) -> [RoutePointDTO] {
        let semaphore = DispatchSemaphore(value: 0)
        var accumulator = RouteAccumulator()
        var failed = false
        var signalled = false

        // The error is deliberately not logged: this file logs nothing, and a route error's
        // userInfo can name the sample it failed on. The recovery is the same either way — drop
        // the partial trace and let the next sync re-read the workout.
        let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
            if error != nil {
                failed = true
                if !signalled { signalled = true; semaphore.signal() }
                return
            }
            if let locations {
                accumulator.append(contentsOf: locations.map(Self.point(from:)))
            }
            if done, !signalled { signalled = true; semaphore.signal() }
        }
        store.execute(query)
        semaphore.wait()
        return failed ? [] : accumulator.finish()
    }

    /// `CLLocation` -> BADAN's flat point value. Invalid accuracies (`< 0`, CoreLocation's
    /// "unknown") are stored as absent rather than as a negative metre count, so a reader can
    /// tell "not reported" from "reported as poor".
    private static func point(from location: CLLocation) -> RoutePointDTO {
        RoutePointDTO(latitude: location.coordinate.latitude,
                      longitude: location.coordinate.longitude,
                      altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
                      horizontalAccuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                      timestamp: location.timestamp)
    }

    /// Assembles a route from however many callback batches HealthKit delivers it in.
    ///
    /// Trivial on its face, and factored out anyway for the same reason `disambiguateWithinNight`
    /// and `sourcePriority` are: everything around it needs a live `HKHealthStore` and a real
    /// recorded workout, so this is the only seam at which multi-batch assembly can be tested at
    /// all. The properties it exists to guarantee — batches concatenate in arrival order, nothing
    /// is dropped between them, and one batch is not a special case of zero or many — are exactly
    /// the ones a single-callback implementation would appear to satisfy right up until a user
    /// records a long enough ride.
    ///
    /// Ordering note: points are kept in the order HealthKit delivered them and are NOT re-sorted
    /// by timestamp. `HKWorkoutRouteQuery` documents chronological delivery, and re-sorting would
    /// silently "repair" a genuinely out-of-order trace into a plausible-looking one instead of
    /// preserving what was recorded.
    struct RouteAccumulator {
        private var points: [RoutePointDTO] = []

        init() {}

        mutating func append(contentsOf batch: [RoutePointDTO]) {
            points.append(contentsOf: batch)
        }

        var count: Int { points.count }

        func finish() -> [RoutePointDTO] { points }
    }

    // MARK: - Backfill honesty (EPIC-01 task 8)

    /// The earliest sample each read type can actually produce inside `range`, so a surface can
    /// state a real starting date per type instead of implying the full requested window exists
    /// for all of them. See `HealthBackfillWindow`.
    ///
    /// One bounded `HKSampleQuery` per ingesting type (`limit: 1`, ascending), which is why this
    /// is NOT called from `ingest` — see `HealthStorePort.backfillWindows`'s doc.
    func backfillWindows(_ range: HealthDateRange) -> [HealthBackfillWindow] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return HKTypeMap.table.compactMap { entry in
            guard entry.metricId != nil, let type = entry.quantityType else { return nil }
            return HealthBackfillWindow(
                platformType: entry.platformType, metricId: entry.metricId,
                requestedStart: range.start,
                earliestAvailable: earliestSampleDate(of: type, in: range))
        }
    }

    private func earliestSampleDate(of type: HKSampleType, in range: HealthDateRange) -> Date? {
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let semaphore = DispatchSemaphore(value: 0)
        var earliest: Date?
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: sort) { _, samples, _ in
            earliest = samples?.first?.startDate
            semaphore.signal()
        }
        store.execute(query)
        semaphore.wait()
        return earliest
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

    private static func groupIntoSessions(_ samples: [HKCategorySample], tz: String) -> [SessionDTO] {
        guard !samples.isEmpty else { return [] }
        let bySource = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }
        var out: [SessionDTO] = []
        for (_, sourceSamples) in bySource {
            let sorted = sourceSamples.sorted { $0.startDate < $1.startDate }
            var cluster: [HKCategorySample] = []
            func flush() {
                guard let first = cluster.first,
                      let last = cluster.max(by: { $0.endDate < $1.endDate }) else { cluster = []; return }
                out.append(makeSession(from: cluster, start: first.startDate, end: last.endDate, tz: tz))
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

    private static func makeSession(from samples: [HKCategorySample], start: Date, end: Date, tz: String) -> SessionDTO {
        let (sourceId, deviceId) = HKSampleMapping.provenanceIds(for: samples[0])
        let (tzId, tzAssumed) = HKSampleMapping.measuredTimeZone(for: samples[0], fallbackTz: tz)
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
        // (BUG-11a) Keyed by the NIGHT, not the cluster's absolute start instant: the old
        // `Int(start.timeIntervalSince1970)` suffix meant a night delivered across two anchored
        // batches clustered into two independently-keyed "sessions" that could never match each
        // other on upsert, creating a duplicate instead of updating the first. Night-keying
        // mirrors `FakeHealthStore`'s existing day-keyed scheme (`"watch-sleep-<dayKey>"`) and,
        // combined with `sessionsForNight`'s full-night rebuild and the migration removing
        // `kind` from the sessions identity index (see `Migrations.swift` v3), means a
        // redelivered/reclassified cluster always upserts in place rather than duplicating.
        //
        // (F1) This id is the night-level BASE only, and is deliberately not unique on its own:
        // one source can report several clusters for one night (naps). `sessionsForNight` runs
        // every cluster through `disambiguateWithinNight`, which suffixes all but the first, so
        // nothing reaches `MeasurementRepository.upsertSession` sharing an identity. Do not
        // treat the value built here as final.
        let night = DayAttribution.localNight(sessionEnd: end, tz: tzId)
        return SessionDTO(kind: kind, start: start, end: end, tz: tzId,
                          sourceId: sourceId, deviceId: deviceId,
                          externalId: "healthkit-sleep-\(sourceId)-\(night)",
                          stages: stages, timeAsleepSeconds: asleep, timeInBedSeconds: inBedSeconds,
                          qualityFlags: tzAssumed ? [.tzAssumed] : [])
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

    /// One `HKAnchoredObjectQuery`'s raw result: the samples it returned, the UUIDs of anything
    /// deleted since the last query, and the refreshed anchor (not yet persisted — see
    /// `runAnchoredQuery`'s doc).
    private struct AnchoredQueryResult {
        var samples: [HKSample] = []
        var deletedUUIDs: [String] = []
        var anchor: HKQueryAnchor?
    }

    /// Run one `HKAnchoredObjectQuery` synchronously (bridged via semaphore — see the type
    /// doc), scoped to `range` (the caller's backfill window; a fixed 90 days on first connect),
    /// resuming from whatever anchor persisted last time so a later call only returns what's new
    /// within that same window.
    ///
    /// (DATA-08) The refreshed anchor is deliberately NOT persisted here anymore — it's stashed
    /// in `pendingAnchors` and only written by `commitPendingAnchors()`, which
    /// `IngestionPipeline` calls after its write transaction has actually committed. The old
    /// comment here claimed persisting eagerly was safe "so a failed ingest doesn't replay from
    /// scratch" — that was only true by accident, because the anchor repo happened to share the
    /// same DB connection/transaction as the ingest write. Once HealthKit reads run outside that
    /// transaction (this fix), persisting the anchor here would let it advance past data whose
    /// write could still fail to commit, silently and permanently dropping that data on the next
    /// sync instead of safely retrying it.
    private func runAnchoredQuery(type: HKSampleType, range: HealthDateRange, platformType: String) -> AnchoredQueryResult {
        let anchor = loadAnchor(platformType: platformType)
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
        let semaphore = DispatchSemaphore(value: 0)
        var result = AnchoredQueryResult(anchor: anchor)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                          limit: HKObjectQueryNoLimit) { _, samplesOrNil, deletedObjectsOrNil, newAnchor, error in
            if error == nil {
                result.samples = samplesOrNil ?? []
                result.deletedUUIDs = (deletedObjectsOrNil ?? []).map { $0.uuid.uuidString }
                result.anchor = newAnchor ?? anchor
            }
            semaphore.signal()
        }
        store.execute(query)
        semaphore.wait()
        if let toPersist = result.anchor {
            pendingAnchors[platformType] = toPersist
        }
        return result
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
        HKSampleMapping.provenanceIds(for: sample)
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
    /// Returns the measured zone plus whether it's a fallback (i.e. `.tzAssumed` should be
    /// stamped): a sample that falls back to `tz` carries the `.tzAssumed` quality flag on its
    /// `Provenance`, the same way `.estimate` is stamped for a failed unit conversion in
    /// `IngestionPipeline.canonicalValue`. (Completes wave-1 DATA-07: `SampleDTO`/`IntervalDTO`/
    /// `SessionDTO` now carry a `qualityFlags` field an adapter can populate, and
    /// `IngestionPipeline.platformProvenance` merges it into the `qualityFlags` it stamps.)
    private func measuredTimeZone(for sample: HKSample) -> (tz: String, assumed: Bool) {
        HKSampleMapping.measuredTimeZone(for: sample, fallbackTz: tz)
    }
}
