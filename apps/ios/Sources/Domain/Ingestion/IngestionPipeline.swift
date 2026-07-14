import Foundation

/// The single path health data takes to become BADAN facts: register sources/devices, pull
/// samples/intervals/sessions from a `HealthStorePort`, canonicalize units, stamp embedded
/// provenance, then run dedup-lite over each affected night. Every write is idempotent by
/// upstream identity (metric/external/source), so re-ingesting the same range is a no-op —
/// no duplicate rows and no duplicate reconciliation decisions. Any future importer (Apple
/// Health export, vendor file, etc.) must route its rows through this same `ingest` entry
/// point rather than writing directly, so overlapping live-sync and import data are
/// reconciled by the identical dedup-lite pass instead of silently double-counting.
final class IngestionPipeline {
    private let measurements: MeasurementRepository
    private let catalog: CatalogRepository
    private let reconciliation: ReconciliationRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String

    init(measurements: MeasurementRepository, catalog: CatalogRepository,
         reconciliation: ReconciliationRepository, registry: MetricRegistry,
         clock: Clock, deviceId: String) {
        self.measurements = measurements
        self.catalog = catalog
        self.reconciliation = reconciliation
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
    }

    /// New rows created this run, per family (derived rollups are excluded — they are a
    /// side effect for charts, not upstream facts). A clean re-ingest returns all zeros.
    struct IngestSummary {
        var samples: Int = 0
        var intervals: Int = 0
        var sessions: Int = 0
        var suppressed: Int = 0
    }

    func ingest(from port: HealthStorePort, range: HealthDateRange) throws -> IngestSummary {
        // `measurements`, `catalog`, and `reconciliation` all share the same main-DB connection,
        // so wrapping the whole ingest body here (rather than committing per row/session/night as
        // before) turns what used to be hundreds of implicit WAL commit+fsyncs into one
        // (PERF-02 (audit 2026-07-12)).
        return try measurements.transaction {
            try ingestUnbatched(from: port, range: range)
        }
    }

    // MARK: - Ingest body (runs inside `measurements.transaction` above)

    private func ingestUnbatched(from port: HealthStorePort, range: HealthDateRange) throws -> IngestSummary {
        let now = clock.now()
        var summary = IngestSummary()

        // (a) Register sources + devices and build the dedup priority map from descriptors.
        let descriptors = port.sourceDescriptors()
        let priorityBySource = try upsertSourcesAndDevices(descriptors, now: now)

        // (b) Pull raw payloads.
        let samples = port.readSamples(range)
        let intervals = port.readIntervals(range)
        let sessionDTOs = port.readSessions(range)

        // (c) Instant readings -> raw_samples (canonicalized, provenance stamped).
        for dto in samples {
            guard let def = registry.definition(dto.metricId) else { continue }
            let (value, flags) = canonicalValue(dto.value, from: dto.unit, canonical: def.canonicalUnit)
            let sample = RawSample(
                id: ULID.newID(), metricId: dto.metricId, value: value, unit: def.canonicalUnit,
                originalValue: dto.value, originalUnit: dto.unit, startAt: dto.start, endAt: dto.end,
                tzId: dto.tz,
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                                externalId: dto.externalId, measuredAt: dto.start,
                                                tz: dto.tz, now: now, qualityFlags: flags),
                updatedAt: now, originDeviceId: deviceId)
            if try measurements.upsertRawSample(sample) { summary.samples += 1 }
        }

        // (c) Normalized aggregates -> interval_records.
        for dto in intervals {
            guard let def = registry.definition(dto.metricId) else { continue }
            let (value, flags) = canonicalValue(dto.value, from: dto.unit, canonical: def.canonicalUnit)
            let record = IntervalRecord(
                id: ULID.newID(), metricId: dto.metricId, value: value, unit: def.canonicalUnit,
                startAt: dto.start, endAt: dto.end, tzId: dto.tz, aggregation: dto.aggregation,
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                                externalId: dto.externalId, measuredAt: dto.start,
                                                tz: dto.tz, now: now, qualityFlags: flags),
                updatedAt: now, originDeviceId: deviceId)
            if try measurements.upsertIntervalRecord(record) { summary.intervals += 1 }
        }

        // (d) Episodes -> sessions (+ stages). Record which nights this run touched.
        // Invariant this scoping relies on: `range` must be a superset of any night whose
        // dedup state could need re-evaluation. True today (a fixed 90-day re-ingest always
        // re-covers every prior night), but re-verify before incremental/delta sync ships,
        // since a partial-range sync could otherwise skip re-dedup for an untouched night.
        var affectedNights = Set<String>()
        for dto in sessionDTOs {
            let night = DayAttribution.localNight(sessionEnd: dto.end, tz: dto.tz)
            affectedNights.insert(night)
            let session = Session(
                id: ULID.newID(), kind: dto.kind, subtype: dto.subtype, startAt: dto.start,
                endAt: dto.end, tzId: dto.tz, localNight: night,
                detail: SessionDetail(timeAsleepSeconds: dto.timeAsleepSeconds,
                                      timeInBedSeconds: dto.timeInBedSeconds,
                                      stageSummarySeconds: stageSummary(dto.stages)),
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                               externalId: dto.externalId, measuredAt: dto.start,
                                               tz: dto.tz, now: now),
                updatedAt: now, originDeviceId: deviceId)
            let stages = dto.stages.enumerated().map { i, s in
                SessionStage(sessionId: session.id, seq: i, stage: s.stage, startAt: s.start, endAt: s.end)
            }
            if try measurements.upsertSession(session, stages: stages) { summary.sessions += 1 }
        }

        // (e)+(f) Dedup each affected night, then rebuild its daily sleep rollups.
        let batchId = ULID.newID()
        for night in affectedNights.sorted() {
            summary.suppressed += try dedup(night: night, priorityBySource: priorityBySource,
                                            batchId: batchId, now: now)
        }

        return summary
    }

    // MARK: - Dedup + derived rollups

    /// Reconcile one night and return how many *new* suppressions were journaled.
    ///
    /// Primary sleep and naps are reconciled as two independent same-kind competitions
    /// (never mixed into one winner pool): the downstream daily-sleep rollup
    /// (`measurements.primarySleep`) only ever reads `sleepPrimary`, so a long/high-priority
    /// nap must never be able to out-rank the night's actual primary sleep session.
    private func dedup(night: String, priorityBySource: [String: Int],
                       batchId: String, now: Date) throws -> Int {
        let sessions = try measurements.allSleepSessions(localNight: night, includeSuppressed: true)
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let priority: (String) -> Int = { priorityBySource[$0] ?? 0 }
        let primaryOutcome = DedupLite.reconcile(sessions: sessions.filter { $0.kind == .sleepPrimary },
                                                 priorityForSource: priority)
        let napOutcome = DedupLite.reconcile(sessions: sessions.filter { $0.kind == .sleepNap },
                                             priorityForSource: priority)

        var newSuppressions = 0
        for outcome in [primaryOutcome, napOutcome] {
            for sup in outcome.suppressed {
                // Idempotent: already suppressed by this winner -> don't re-suppress or re-journal.
                if byId[sup.loserId]?.provenance.suppressedBy == sup.winnerId { continue }
                try measurements.setSuppressed(table: "sessions", recordId: sup.loserId,
                                               by: sup.winnerId, updatedAt: now)
                try reconciliation.insert(ReconciliationDecision(
                    id: ULID.newID(), batchId: batchId, rule: DedupLite.ruleId, ruleVersion: "v1",
                    keptRecordId: sup.winnerId, suppressedRecordId: sup.loserId, score: sup.score,
                    decidedAt: now, detail: sup.detail))
                newSuppressions += 1
            }
        }

        // Compensate: un-suppress any session whose recorded suppressor is stale under this
        // run's fresh outcome (e.g. a device-name/priority change flipped which source wins).
        // Without this, an old winner's suppression could outlive the winner that caused it,
        // leaving two simultaneously-visible "surviving" sessions for the same night.
        let currentLoserIds = Set(primaryOutcome.suppressed.map { $0.loserId } + napOutcome.suppressed.map { $0.loserId })
        for s in sessions where s.provenance.suppressedBy != nil && !currentLoserIds.contains(s.id) {
            try measurements.setSuppressed(table: "sessions", recordId: s.id, by: nil, updatedAt: now)
        }

        // Record lineage on the primary-sleep winner (which raw sessions were merged into it).
        if let winnerId = primaryOutcome.winnerId {
            let loserIds = primaryOutcome.suppressed.map { $0.loserId }.sorted()
            if !loserIds.isEmpty, var winner = byId[winnerId],
               Set(winner.detail.mergedFrom) != Set(loserIds) {
                winner.detail.mergedFrom = loserIds
                winner.updatedAt = now
                try measurements.upsertSession(winner)
            }
        }

        // (e) Rebuild the night's daily sleep rollups from the surviving primary sleep so
        // charts/baselines read one uniform interval regardless of how many sources reported.
        if let primary = try measurements.primarySleep(localNight: night) {
            try upsertDailySleepInterval(metricId: "sleep.time_asleep",
                                         seconds: primary.detail.timeAsleepSeconds,
                                         winner: primary, night: night, now: now)
            try upsertDailySleepInterval(metricId: "sleep.time_in_bed",
                                         seconds: primary.detail.timeInBedSeconds,
                                         winner: primary, night: night, now: now)
        }
        return newSuppressions
    }

    /// Upsert one derived daily sleep interval (unit "s"), keyed idempotently by night so a
    /// re-ingest updates in place.
    ///
    /// (DATA-01) The contract (`DayAttribution.localNight`) attributes a sleep session to the
    /// morning it ENDS. But every downstream day-keying — `BaselineEngine.latestPerDay` and
    /// `InsightEngine`'s day windowing, both via `MeasurementRepository.intervalRecords(from:to:)`
    /// which filters on `start_at` — keys off this row's `startAt`. Storing the winner's real
    /// bedtime there (the previous evening) silently shifted night N's sleep facts onto day
    /// N-1. Fixed by anchoring `startAt`/`endAt` to the *stored night's* day boundaries
    /// (`DayAttribution.date(fromDayKey:)`) instead of the session's real start/end — this row
    /// is a daily fact, not the session record, so it doesn't need to carry the literal
    /// bedtime/wake instants; that lineage already lives on the `Session` itself and is what
    /// the Metric Detail provenance row shows via `provenance.measuredAt` below, which we keep
    /// pointed at the real bedtime on purpose (verified no UI reads this row's own `startAt` as
    /// a clock time — only as a day-bucketing key).
    private func upsertDailySleepInterval(metricId: String, seconds: Double?,
                                          winner: Session, night: String, now: Date) throws {
        guard let seconds else { return }
        guard let dayStart = DayAttribution.date(fromDayKey: night, tz: winner.tzId) else { return }
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: winner.tzId)
        let externalId = "derived.\(metricId).\(night)"

        // Provenance is derived from the winning session; `measuredAt` intentionally keeps the
        // real bedtime (unlike `startAt` on the record itself) so lineage/provenance UI can
        // still show when sleep actually began.
        let provenance = Provenance(
            sourceId: winner.provenance.sourceId, deviceId: winner.provenance.deviceId,
            ingestionPath: .derived, externalId: externalId,
            measuredAt: winner.startAt, measuredTimezone: winner.tzId,
            recordedAt: now, ingestedAt: now, algorithmVersionId: DedupLite.ruleId)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: seconds, unit: "s",
            startAt: dayStart, endAt: dayEnd, tzId: winner.tzId,
            aggregation: .duration, provenance: provenance, updatedAt: now, originDeviceId: deviceId)
        try measurements.upsertIntervalRecord(record)

        // (DATA-05) The upsert identity is (metric_id, external_id, source_id). `externalId`
        // above is fixed per night, but `sourceId` is the dedup winner's — so a winner flip
        // across re-ingests (a device-priority/name change, or new data reversing last night's
        // decision) can't match the prior row under `ON CONFLICT`, leaving a stale rollup
        // stranded under the old source alongside the fresh one (two visible intervals for one
        // night). Rather than inventing a synthetic source id (which would blur the real
        // winning device's name out of the Metric Detail lineage row — verified that row reads
        // this exact `provenance.sourceId`), find every rollup row still carrying tonight's
        // `externalId` and suppress every one that isn't tonight's winner, un-suppressing the
        // winner's own row in case an earlier flip had suppressed it (mirrors the session-level
        // compensation loop in `dedup(night:...)` above).
        let rowsForNight = try measurements.intervalRecords(metricId: metricId, from: dayStart, to: dayEnd, includeSuppressed: true)
            .filter { $0.provenance.externalId == externalId }
        guard let currentRow = rowsForNight.first(where: { $0.provenance.sourceId == winner.provenance.sourceId }) else { return }
        for r in rowsForNight {
            let shouldBeSuppressed = r.id != currentRow.id
            if shouldBeSuppressed, r.provenance.suppressedBy != currentRow.id {
                try measurements.setSuppressed(table: "interval_records", recordId: r.id, by: currentRow.id, updatedAt: now)
            } else if !shouldBeSuppressed, r.provenance.suppressedBy != nil {
                try measurements.setSuppressed(table: "interval_records", recordId: r.id, by: nil, updatedAt: now)
            }
        }
    }

    // MARK: - Sources / devices

    /// Upsert a Source (and Device, when present) per descriptor and return the sourceId ->
    /// dedup-priority map. Explicit descriptor priority wins; otherwise a wrist device
    /// outranks a phone (watch > phone), falling back to 0.
    private func upsertSourcesAndDevices(_ descriptors: [SourceDescriptor], now: Date) throws -> [String: Int] {
        var priorityBySource: [String: Int] = [:]
        // Fetch the known device set once instead of re-querying per descriptor — devices
        // rarely change between ingest calls, and this runs on every sync, not just the first.
        let allDevices = try catalog.devices()
        for d in descriptors {
            let existing = try catalog.source(id: d.id)
            try catalog.upsertSource(Source(
                id: d.id, type: .healthkit, displayName: d.displayName, platformBundleId: d.bundleId,
                status: .active, connectedAt: existing?.connectedAt ?? now, lastDeliveryAt: now,
                updatedAt: now, originDeviceId: deviceId))

            if let deviceKey = d.deviceId {
                let priorDevice = allDevices.first { $0.sourceId == d.id && $0.id == deviceKey }
                try catalog.upsertDevice(Device(
                    id: deviceKey, sourceId: d.id, name: d.deviceName ?? d.displayName, model: d.deviceModel,
                    firstSeen: priorDevice?.firstSeen ?? now, lastSeen: now, updatedAt: now, originDeviceId: deviceId))
            }

            priorityBySource[d.id] = inferredPriority(d)
        }
        return priorityBySource
    }

    /// Non-Apple wearable keywords recognized as a wrist/ring-class device (same tier as
    /// "watch"): without this, any two of these default to priority 0 and are reconciled by
    /// arbitrary id tie-breaking instead of a meaningful source-quality signal.
    private static let wearableKeywords = ["watch", "ring", "band", "oura", "whoop", "fenix", "garmin", "fitbit", "polar"]

    private func inferredPriority(_ d: SourceDescriptor) -> Int {
        if d.priority != 0 { return d.priority }
        let hay = ((d.deviceName ?? "") + " " + (d.deviceModel ?? "") + " " + d.displayName).lowercased()
        if Self.wearableKeywords.contains(where: hay.contains) { return 2 }
        if hay.contains("phone") { return 1 }
        return 0
    }

    // MARK: - Helpers

    private func platformProvenance(sourceId: String, deviceId: String?, externalId: String,
                                    measuredAt: Date, tz: String, now: Date,
                                    qualityFlags: [QualityFlag] = []) -> Provenance {
        Provenance(sourceId: sourceId, deviceId: deviceId, ingestionPath: .platformStore,
                   externalId: externalId, measuredAt: measuredAt, measuredTimezone: tz,
                   recordedAt: now, ingestedAt: now, qualityFlags: qualityFlags)
    }

    /// Convert an as-received value into `canonical`, explicitly (not silently) marking the
    /// value `.estimate` when the conversion fails (unknown/incompatible unit) so a malformed
    /// source unit never masquerades as a valid canonical value with zero trace.
    private func canonicalValue(_ value: Double, from unit: String, canonical: String) -> (Double, [QualityFlag]) {
        if let converted = try? Units.convert(value, from: unit, to: canonical) {
            return (converted, [])
        }
        return (value, [.estimate])
    }

    private func stageSummary(_ stages: [StageDTO]) -> [String: Double] {
        var summary: [String: Double] = [:]
        for s in stages {
            summary[s.stage.rawValue, default: 0] += s.end.timeIntervalSince(s.start)
        }
        return summary
    }
}
