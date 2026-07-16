import Foundation

/// Deterministic, offline health source that stands in for HealthKit/Health Connect on the
/// simulator. All variation comes from an FNV-1a hash of "metricKey:dayIndex", so output is
/// stable and reproducible regardless of call order — the ingestion pipeline and downstream
/// insights get truthful, repeatable data (two overlapping sleep sources exercise dedup, a
/// mild "rough patch" gives the narrative something honest to say).
final class FakeHealthStore: HealthStorePort {
    private let clock: Clock
    private let historyDays: Int
    private let tz: String

    // Source identity (device wins dedup ties by priority — I4).
    private static let watchSource = "src_watch"
    private static let watchDevice = "watch-0001"
    private static let phoneSource = "src_iphone"
    private static let phoneDevice = "iphone-0001"
    /// Bundle id for both simulated sources — BADAN's own namespace, never Apple's. See
    /// `sourceDescriptors`.
    static let sampleBundleId = "com.badan.sampledata"

    // Full history generated once at init; reads just filter by the requested range.
    private let allSessions: [SessionDTO]
    private let allIntervals: [IntervalDTO]
    private let allSamples: [SampleDTO]

    // Generation is a pure function of (historyDays, tz, today's local day) — a fresh
    // FakeHealthStore built with unchanged inputs (e.g. every "Reset demo data" tap within the
    // same day) produces byte-identical output, so cache it instead of regenerating.
    private struct GeneratedData {
        let sessions: [SessionDTO]
        let intervals: [IntervalDTO]
        let samples: [SampleDTO]
    }
    private static let cacheLock = NSLock()
    private static var cache: [String: GeneratedData] = [:]

    init(clock: Clock, historyDays: Int = 90, tz: String = TimeZone.current.identifier) {
        self.clock = clock
        self.historyDays = max(1, historyDays)
        self.tz = tz

        let now = clock.now()
        let todayStart = DayAttribution.startOfDay(now, tz: tz)
        let cacheKey = "\(self.historyDays)|\(tz)|\(DayAttribution.localDayKey(todayStart, tz: tz))"

        Self.cacheLock.lock()
        let cached = Self.cache[cacheKey]
        Self.cacheLock.unlock()

        if let cached {
            self.allSessions = cached.sessions
            self.allIntervals = cached.intervals
            self.allSamples = cached.samples
            return
        }

        var sessions: [SessionDTO] = []
        var intervals: [IntervalDTO] = []
        var samples: [SampleDTO] = []

        // Pure, order-independent helpers (local funcs so they don't touch `self` mid-init).
        // FNV-1a (64-bit) of "metricKey:salt" mapped into [0, 1) — the sole source of variation.
        // Hashes metricKey then ":" then salt as raw bytes (equivalent to hashing
        // "\(metricKey):\(salt)".utf8) without allocating a fresh interpolated String per call —
        // this closure runs 1,000+ times per generation.
        func unit(_ metricKey: String, _ salt: String) -> Double {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in metricKey.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= UInt64(UInt8(ascii: ":"))
            hash = hash &* 0x100000001b3
            for byte in salt.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            return Double(hash >> 11) * (1.0 / 9007199254740992.0) // / 2^53
        }
        func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
        func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

        let cal = DayAttribution.calendar(tz: tz)

        for dayIndex in 0..<self.historyDays {
            let daysAgo = self.historyDays - 1 - dayIndex
            let dayStart = DayAttribution.addingDays(-daysAgo, to: todayStart, tz: tz)
            let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)
            let dayKey = DayAttribution.localDayKey(dayStart, tz: tz)
            let weekday = cal.component(.weekday, from: dayStart)
            let isWeekend = (weekday == 1 || weekday == 7)
            let roughPatch = (10...14).contains(daysAgo)

            let weekly = sin(2.0 * .pi * Double(dayIndex) / 7.0)

            // Sleep window: bed ~23:00 (prev evening), wake ~06:45, both jittered; the rough
            // patch pushes bedtime later and wake earlier so total sleep truthfully drops.
            let bedBase = dayStart.addingTimeInterval(-3600)                    // 23:00 prev day
            let bedJitter = (unit(dayKey, "bedtime") - 0.5) * 2 * 40 * 60       // +/- 40 min
            let bedtime = bedBase.addingTimeInterval(bedJitter + (roughPatch ? 40 * 60 : 0))
            let wakeBase = dayStart.addingTimeInterval(6 * 3600 + 45 * 60)      // 06:45
            let wakeJitter = (unit(dayKey, "wake") - 0.5) * 2 * 30 * 60         // +/- 30 min
            let wake = wakeBase.addingTimeInterval(wakeJitter - (roughPatch ? 35 * 60 : 0))
            let inBed = wake.timeIntervalSince(bedtime)

            // --- Watch primary sleep, with realistic stage breakdown ---
            let (stages, asleep) = Self.buildStages(bedtime: bedtime, wake: wake,
                                                    inBed: inBed, rough: roughPatch)
            sessions.append(SessionDTO(
                kind: .sleepPrimary, start: bedtime, end: wake, tz: tz,
                sourceId: Self.watchSource, deviceId: Self.watchDevice,
                externalId: "watch-sleep-\(dayKey)", stages: stages,
                timeAsleepSeconds: asleep, timeInBedSeconds: inBed))

            // --- iPhone rougher duplicate: overlapping (>=70%) boundaries, no stages ---
            let inset1 = 480.0 + unit(dayKey, "ip1") * 300                      // 8-13 min
            let inset2 = 360.0 + unit(dayKey, "ip2") * 300                      // 6-11 min
            let ipStart = bedtime.addingTimeInterval(inset1)
            let ipEnd = wake.addingTimeInterval(-inset2)
            let ipInBed = ((ipEnd.timeIntervalSince(ipStart)) / 900).rounded() * 900  // ~15 min
            let ipAsleep = (ipInBed * 0.88 / 600).rounded() * 600                     // coarse
            sessions.append(SessionDTO(
                kind: .sleepPrimary, start: ipStart, end: ipEnd, tz: tz,
                sourceId: Self.phoneSource, deviceId: Self.phoneDevice,
                externalId: "iphone-sleep-\(dayKey)", stages: [],
                timeAsleepSeconds: ipAsleep, timeInBedSeconds: ipInBed))

            // --- Daily interval metrics (watch) ---
            func daily(_ metricId: String, _ unitStr: String, _ agg: Aggregation, _ value: Double) {
                intervals.append(IntervalDTO(
                    metricId: metricId, value: value, unit: unitStr, start: dayStart, end: dayEnd,
                    tz: tz, aggregation: agg, sourceId: Self.watchSource, deviceId: Self.watchDevice,
                    externalId: "watch-\(metricId)-\(dayKey)"))
            }

            let rhr = clamp(57 + 2 * weekly + (unit(dayKey, "rhr") - 0.5) * 4 + (roughPatch ? 5 : 0), 48, 72)
            daily(MetricID.restingHeartRate, "bpm", .mean, round(rhr))

            let hrv = clamp(58 + 6 * weekly + (unit(dayKey, "hrv") - 0.5) * 16 - (roughPatch ? 12 : 0), 30, 85)
            daily(MetricID.hrv, "ms", .mean, round(hrv))

            let steps = clamp(8000 + (unit(dayKey, "steps") - 0.5) * 7000 + (isWeekend ? 1500 : 0) - (roughPatch ? 1500 : 0), 2000, 15000)
            daily(MetricID.steps, "count", .sum, round(steps))

            // Canonical energy is kJ; emitting kcal deliberately exercises unit conversion.
            let energy = clamp(420 + (unit(dayKey, "energy") - 0.5) * 360 + (isWeekend ? 80 : 0) - (roughPatch ? 60 : 0), 200, 750)
            daily(MetricID.activeEnergy, "kcal", .sum, round(energy))

            let distance = clamp(6000 + (unit(dayKey, "distance") - 0.5) * 5000 + (isWeekend ? 800 : 0), 2500, 10000)
            daily(MetricID.distance, "m", .sum, round(distance))

            let exercise = clamp(32 + (unit(dayKey, "exercise") - 0.5) * 44 + (isWeekend ? 8 : 0) - (roughPatch ? 10 : 0), 0, 90)
            daily(MetricID.exerciseMinutes, "min", .sum, round(exercise))

            // Respiratory rate is a nightly mean over the sleep window.
            let resp = round1(clamp(14.3 + (unit(dayKey, "resp") - 0.5) * 1.8 + (roughPatch ? 0.7 : 0), 11, 20))
            intervals.append(IntervalDTO(
                metricId: MetricID.respiratoryRate, value: resp, unit: "breaths/min",
                start: bedtime, end: wake, tz: tz, aggregation: .mean,
                sourceId: Self.watchSource, deviceId: Self.watchDevice,
                externalId: "watch-respiratory.rate-\(dayKey)"))

            // --- Sub-daily samples (watch) ---
            // SpO2: two nightly readings.
            for (i, hour) in [2.5, 4.5].enumerated() {
                let spo2 = round1(clamp(97.6 + (unit(dayKey, "spo2\(i)") - 0.5) * 2.2 - (roughPatch ? 0.5 : 0), 93, 100))
                let at = dayStart.addingTimeInterval(hour * 3600)
                samples.append(SampleDTO(
                    metricId: MetricID.spo2, value: spo2, unit: "%", start: at, tz: tz,
                    sourceId: Self.watchSource, deviceId: Self.watchDevice,
                    externalId: "watch-respiratory.spo2-\(dayKey)-\(i)"))
            }

            // Weight: every 3rd day, slow upward trend ~78 -> ~80 kg, measured mid-morning.
            if dayIndex % 3 == 0 {
                let trend = Double(dayIndex) / Double(max(1, self.historyDays - 1)) * 2.0
                let weight = round1(78.0 + trend + (unit(dayKey, "weight") - 0.5) * 0.8)
                let at = dayStart.addingTimeInterval(7 * 3600 + 10 * 60)
                samples.append(SampleDTO(
                    metricId: MetricID.weight, value: weight, unit: "kg", start: at, tz: tz,
                    sourceId: Self.watchSource, deviceId: Self.watchDevice,
                    externalId: "watch-body.weight-\(dayKey)"))
            }

            // Heart rate: four spot readings across the day.
            let hrHours = [8, 12, 16, 20]
            let hrBase = [70.0, 88.0, 96.0, 76.0]
            for i in 0..<hrHours.count {
                let hr = clamp(hrBase[i] + (unit(dayKey, "hr\(i)") - 0.5) * 24, 55, 120)
                let minute = unit(dayKey, "hrm\(i)") * 3540
                let at = dayStart.addingTimeInterval(Double(hrHours[i]) * 3600 + minute)
                samples.append(SampleDTO(
                    metricId: MetricID.heartRate, value: round(hr), unit: "bpm", start: at, tz: tz,
                    sourceId: Self.watchSource, deviceId: Self.watchDevice,
                    externalId: "watch-heart.hr-\(dayKey)-\(i)"))
            }
        }

        // Every row this type produces is invented, so every row says so (`.sampleData`).
        // Stamped once here — the single point where fabrication finishes — rather than at the
        // seven construction sites above, so a metric added to the generator later cannot
        // silently ship unflagged. Doing it before the cache write means the early-return cache
        // path is covered too.
        for i in sessions.indices { sessions[i].qualityFlags.append(.sampleData) }
        for i in intervals.indices { intervals[i].qualityFlags.append(.sampleData) }
        for i in samples.indices { samples[i].qualityFlags.append(.sampleData) }

        self.allSessions = sessions
        self.allIntervals = intervals
        self.allSamples = samples

        let generated = GeneratedData(sessions: sessions, intervals: intervals, samples: samples)
        Self.cacheLock.lock()
        Self.cache[cacheKey] = generated
        Self.cacheLock.unlock()
    }

    // MARK: HealthStorePort

    func availability() -> HealthAvailability { .available }

    /// The simulated devices behind the sample data.
    ///
    /// These deliberately do NOT claim `com.apple.health`, and they say "sample" in the name
    /// users and exports actually see. They used to be branded plain "Apple Watch"/"iPhone" under
    /// Apple's real bundle id, which put a fabricated but entirely credible Apple Health
    /// attribution on every sample row — visible in the provenance sheet, and carried into
    /// exported CSV/JSON as `source_app`. The in-app banner made the *screen* honest while the
    /// *data* still claimed a measurement that never happened.
    ///
    /// The watch/phone shape (and the priority gap between them) is kept: it's what exercises the
    /// pipeline's real wearable-beats-phone dedup path, which is the reason two overlapping sleep
    /// sources exist here at all.
    func sourceDescriptors() -> [SourceDescriptor] {
        [
            SourceDescriptor(id: Self.watchSource, displayName: "Sample watch (simulated)",
                             type: .healthkit, bundleId: Self.sampleBundleId, deviceId: Self.watchDevice,
                             deviceName: "Sample watch (simulated)", deviceModel: "BADAN sample data",
                             priority: 100),
            SourceDescriptor(id: Self.phoneSource, displayName: "Sample phone (simulated)",
                             type: .healthkit, bundleId: Self.sampleBundleId, deviceId: Self.phoneDevice,
                             deviceName: "Sample phone (simulated)", deviceModel: "BADAN sample data",
                             priority: 50),
        ]
    }

    func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
        allSamples.filter { $0.start >= range.start && $0.start <= range.end }
    }

    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        allIntervals.filter { $0.start >= range.start && $0.start <= range.end }
    }

    func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
        // Attributed to the morning they end (the "last night" key).
        allSessions.filter { $0.end >= range.start && $0.end <= range.end }
    }

    // `deletions(_:)` and `commitPendingAnchors()` are intentionally not overridden: this store
    // is a fully-regenerated deterministic snapshot with no incremental read cursor and no
    // delete signal, so `HealthStorePort`'s default no-op/empty implementations (BUG-10,
    // DATA-08) are already exactly correct here.

    // MARK: Deterministic generation helpers

    /// Contiguous stage segments tiling [bedtime, wake] with a realistic cycle pattern; the
    /// rough-patch variant carries more awake time and less deep/REM. Returns the stages plus
    /// total time asleep (sum of non-awake segments).
    private static func buildStages(bedtime: Date, wake: Date, inBed: Double, rough: Bool)
        -> (stages: [StageDTO], asleep: Double) {
        let pattern: [(SleepStage, Double)] = rough
            ? [(.awake, 0.05), (.light, 0.11), (.deep, 0.06), (.light, 0.10),
               (.rem, 0.05), (.light, 0.10), (.awake, 0.04), (.light, 0.10),
               (.deep, 0.05), (.light, 0.10), (.rem, 0.05), (.light, 0.08),
               (.awake, 0.03), (.rem, 0.04), (.awake, 0.04)]
            : [(.awake, 0.03), (.light, 0.10), (.deep, 0.09), (.light, 0.08),
               (.rem, 0.06), (.light, 0.10), (.deep, 0.06), (.light, 0.09),
               (.rem, 0.07), (.light, 0.10), (.awake, 0.02), (.light, 0.06),
               (.rem, 0.09), (.light, 0.03), (.awake, 0.02)]

        var stages: [StageDTO] = []
        var asleep = 0.0
        var cursor = bedtime
        var cum = 0.0
        for (idx, seg) in pattern.enumerated() {
            cum += seg.1
            let end = (idx == pattern.count - 1) ? wake : bedtime.addingTimeInterval(cum * inBed)
            guard end > cursor else { continue }
            stages.append(StageDTO(stage: seg.0, start: cursor, end: end))
            if seg.0 != .awake { asleep += end.timeIntervalSince(cursor) }
            cursor = end
        }
        return (stages, asleep)
    }
}
