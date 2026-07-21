import Foundation

/// Makes BADAN runnable and inspectable immediately: on first launch it ingests a deterministic
/// 90-day health history from the FakeHealthStore (exercising the real ingestion + dedup path),
/// seeds a handful of manual logs, and computes baselines + insights. Gated by an explicit
/// `seedCompleted` marker, not merely the presence of sources (BUG-16 — a crash mid-seed used to
/// leave a permanently half-seeded database that looked done); `Settings → Reset demo data`
/// calls `seed` after a wipe.
final class SeedController {
    private let catalog: CatalogRepository
    private let ingestion: IngestionPipeline
    private let logging: LoggingRepository
    private let measurements: MeasurementRepository
    private let baselines: BaselineEngine
    private let insightEngine: InsightEngine
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String
    private let tz: String
    /// EPIC-23. The ordered score pipeline (baselines → sleep → readiness → effort). When present,
    /// `deriveAndGenerateInsights` runs it INSTEAD of the bare `baselines.recomputeAll`, so every
    /// ingest→derive path (first-run seed, connect backfill, foreground/background sync) computes the
    /// full score cluster in the published order. Optional so the headless lifecycle/labeling tests
    /// that construct a `SeedController` without the score engines keep their existing baseline-only
    /// behavior unchanged; the composition root always injects it.
    private let derivationCoordinator: DerivationCoordinator?

    /// BUG-16: written only once every step of `seed()` has actually completed — see
    /// `seedIfNeeded`.
    static let seedCompletedKey = "badan.seedCompleted"
    /// BUG-01: set alongside `seedCompletedKey` — marks that the manual-log rows `seed()` just
    /// wrote (workouts/nutrition/notes/medications/symptoms) are demo content, so the *first*
    /// `AppEnvironment.connectHealthKit()` afterwards knows it's safe to also clear them before
    /// the real backfill starts (see `Database.purgeDemoManualLogs`). Cleared there once acted
    /// upon and never set again after a real connect, so a connected user's own manual logs are
    /// never at risk from that path.
    static let demoSeedActiveKey = "badan.demoSeedActive"

    /// STUB-01/COMP-06: whether the app is currently showing the bootstrap sample dataset rather
    /// than a connected user's own data — i.e. `demoSeedActiveKey` is set and hasn't yet been
    /// cleared by a real connect (`AppEnvironment.connectHealthKit()`) or by `markStartEmpty()`.
    /// A bare `UserDefaults` read, not an `@Observable` property, since this lives outside
    /// `AppEnvironment` by design (see `RootView`, which re-reads it reactively instead).
    static var isDemoDataActive: Bool {
        UserDefaults.standard.bool(forKey: demoSeedActiveKey)
    }

    init(catalog: CatalogRepository, ingestion: IngestionPipeline, logging: LoggingRepository,
         measurements: MeasurementRepository, baselines: BaselineEngine, insightEngine: InsightEngine,
         registry: MetricRegistry, clock: Clock, deviceId: String,
         derivationCoordinator: DerivationCoordinator? = nil) {
        self.catalog = catalog; self.ingestion = ingestion; self.logging = logging
        self.measurements = measurements; self.baselines = baselines; self.insightEngine = insightEngine
        self.registry = registry; self.clock = clock; self.deviceId = deviceId
        self.derivationCoordinator = derivationCoordinator
        self.tz = TimeZone.current.identifier
    }

    /// BUG-16: the old gate (`catalog.sources().isEmpty == false`) is written by step 1 of
    /// `seed()` (the FakeHealthStore ingest), so a crash between that and the later manual-log
    /// or derive/insight steps left a database that looked "seeded" (non-empty sources) forever,
    /// while the demo medications/symptoms/workouts/notes and insights those later steps write
    /// were silently never there. An explicit completion marker — set only at the very end of
    /// `seed()`, once every step has run — distinguishes "fully seeded" from "partially seeded,"
    /// so an interrupted first run actually resumes instead of looking done forever.
    ///
    /// Re-running the whole of `seed()` on resume is safe: ingestion is already idempotent
    /// (dedup on external id/source), insight regeneration deletes-then-rebuilds each day
    /// (`InsightEngine.generate`), and every manual-log write below now uses a deterministic id
    /// (verified this was NOT true before this fix — every seeded row used a fresh
    /// `ULID.newID()`, so a naive re-run would have duplicated every demo workout/medication/
    /// symptom/note instead of safely overwriting it).
    func seedIfNeeded(asOf now: Date) throws {
        if UserDefaults.standard.bool(forKey: Self.seedCompletedKey) { return }
        try seed(asOf: now)
    }

    /// STUB-01/COMP-06 (ONB "Start empty"): the honest alternative to the bootstrap demo seed —
    /// purge whatever demo content `AppEnvironment.bootstrap()` already wrote before onboarding
    /// even reached the connect screen (bootstrap demo-seeds unconditionally for a disconnected
    /// user), then mark onboarding's data state as "done, deliberately empty" rather than
    /// "not yet seeded." Static and takes `database` as a parameter — mirroring
    /// `ingestHealthData(from:...)` taking its `HealthStorePort` collaborator as a parameter —
    /// rather than a stored property, so this doesn't require changing `SeedController`'s
    /// constructor (and every existing call site, notably `AppEnvironment.init`).
    ///
    /// Sets `seedCompletedKey` so `seedIfNeeded` never demo-seeds later, and clears
    /// `demoSeedActiveKey` so `SeedController.isDemoDataActive` (and the sample-data banner it
    /// drives) immediately reads false. Reuses the exact three wave-1 purge primitives
    /// (`Database.purgeIngestedData`/`purgeDemoManualLogs`/`purgeSensitiveNamespace`) that
    /// `AppEnvironment.connectHealthKit()` already relies on for the same "clear the demo seed"
    /// job, so a device that starts empty and one that starts empty via a real connect end up in
    /// the identical, verified-empty state.
    static func markStartEmpty(database: Database) throws {
        try database.purgeIngestedData()
        try database.purgeDemoManualLogs()
        try database.purgeSensitiveNamespace()
        UserDefaults.standard.set(true, forKey: seedCompletedKey)
        UserDefaults.standard.removeObject(forKey: demoSeedActiveKey)
    }

    /// Whether a connected user's real backfill needs to (re)run — i.e. `sources` is still
    /// empty, meaning a prior `connectHealthKit()`/`resetDemoData()` backfill never completed
    /// (crash, app killed mid-ingest). Never demo-seeds; the caller (`AppEnvironment.bootstrap`)
    /// re-runs the real ingest→derive chain instead (BUG-07) — a connected user's empty sources
    /// must never be mistaken for "needs the demo seed."
    func needsBackfillResume() throws -> Bool {
        try catalog.sources().isEmpty
    }

    /// Re-seeds sensitive-namespace manual logs (medications/symptoms) independently of the
    /// main-DB seed gate. The sensitive DB is separately purgeable (`Settings` → purge
    /// sensitive data), and `seedIfNeeded`'s `catalog.sources()` check never notices that
    /// purge — without this, re-enabling the sensitive module after a purge leaves medications
    /// and symptoms permanently empty (OPT-200).
    func seedSensitiveIfNeeded(asOf now: Date) throws {
        if try logging.allSymptoms().isEmpty == false { return }
        // Batched into one sensitive-DB transaction rather than ~20 individual commit+fsyncs
        // (PERF-02 (audit 2026-07-12)).
        try logging.transactionSensitive {
            try seedMedications(now: now)
            try seedSymptoms(now: now)
        }
    }

    func seed(asOf now: Date) throws {
        let signpostState = PerformanceLog.signposter.beginInterval("SeedController.seed")
        defer { PerformanceLog.signposter.endInterval("SeedController.seed", signpostState) }

        // 1. Ingest 90 days of device data (sources/devices, samples, intervals, sessions, dedup).
        // `ingest` batches its own writes into one transaction internally (PERF-02).
        let store = FakeHealthStore(clock: clock, historyDays: 90, tz: tz)
        _ = try ingestHealthData(from: store, historyDays: 90, asOf: now)

        // 2+3. Main-DB seed writes (profile, workouts, nutrition, note) batched into one
        // transaction. Medications/symptoms are excluded here — they write to the *sensitive*
        // DB, a separate connection/file, so they get their own transaction below rather than
        // silently running outside this one (PERF-02 (audit 2026-07-12)).
        try logging.transactionMain {
            // 2. User profile (height for BMI context). Deterministic id (BUG-16) — see
            // `seedIfNeeded`.
            try catalog.saveUserProfile(UserProfile(id: "demo-user-profile", displayName: nil, heightMeters: 1.75,
                                                    birthYear: 1990, createdAt: now, updatedAt: now))

            // 3. Manual logs (main-DB ones).
            try seedWorkouts(now: now)
            try seedNutrition(now: now)
            try logging.upsertNote(NoteEntry(id: "demo-note-midweek",
                                             text: "Felt a bit run down midweek; slept early to catch up.",
                                             occurredAt: DayAttribution.addingDays(-2, to: now, tz: tz), tzId: tz,
                                             updatedAt: now, originDeviceId: deviceId))
        }

        // 3b. Manual logs (sensitive-DB ones) — separate transaction, separate connection
        // (PERF-02 (audit 2026-07-12)).
        try logging.transactionSensitive {
            try seedMedications(now: now)
            try seedSymptoms(now: now)
        }

        // 4. Derivations + insights.
        try deriveAndGenerateInsights(asOf: now)

        // BUG-16/BUG-01: only set once every step above has actually completed — see
        // `seedIfNeeded` and `Database.purgeDemoManualLogs`.
        UserDefaults.standard.set(true, forKey: Self.seedCompletedKey)
        UserDefaults.standard.set(true, forKey: Self.demoSeedActiveKey)
    }

    // MARK: - Shared ingest/derive chain (FEAT-01)
    //
    // Both the demo seed above and the real HealthKit connect flow (`AppEnvironment.
    // connectHealthKit`, `AppEnvironment.resetDemoData`) funnel through these two entry points
    // rather than duplicating the ingest→derive→insight sequence per source — the only thing
    // that differs between "demo" and "real" is which `HealthStorePort` is passed in, and
    // whether the demo-only manual-log seeding (medications, workouts, nutrition, …) runs in
    // between. `seed(asOf:)` above still runs the exact same operations in the exact same order
    // it always has; this split is a refactor, not a behavior change.

    /// Ingest `historyDays` of data from `port` (source/device registration, samples, intervals,
    /// sessions, dedup — see `IngestionPipeline`). `ingest` batches its own writes into one
    /// transaction internally (PERF-02).
    @discardableResult
    func ingestHealthData(from port: HealthStorePort, historyDays: Int, asOf now: Date) throws -> IngestionPipeline.IngestSummary {
        // DATA-11: DST-safe day arithmetic — `addingTimeInterval(-N * 86_400)` silently drifts
        // by an hour whenever a DST transition falls inside the window; `DayAttribution.
        // addingDays` goes through `Calendar`, which is DST-aware.
        let start = DayAttribution.addingDays(-historyDays, to: now, tz: tz)
        let range = HealthDateRange(start: start, end: now)
        return try ingestion.ingest(from: port, range: range)
    }

    /// Recompute baselines and (re)generate the last 14 days of insights. Must run *after* all
    /// of a run's ingestion + manual-log seeding (baselines read whatever is in the DB at call
    /// time). `generate` is a handful of narrow, indexed lookups per key metric (see
    /// `InsightEngine`), so 14 days stays cheap while making the Insights feed actually reflect
    /// a meaningful slice of history instead of looking sparse next to it (EASE-134).
    func deriveAndGenerateInsights(asOf now: Date) throws {
        // The score pipeline (EPIC-23/24/25/26) when wired, else the interim baseline-only recompute.
        // The coordinator runs `baselines.recomputeAll` first itself, so this is a superset of the old
        // behavior in the defined cross-metric order, not a second baseline pass.
        if let derivationCoordinator {
            try derivationCoordinator.recompute(asOf: now, tz: tz)
        } else {
            try baselines.recomputeAll(asOf: now)
        }
        // DATA-11: DST-safe day iteration — see `ingestHealthData` above.
        for dayOffset in 0..<14 {
            let day = DayAttribution.addingDays(-dayOffset, to: now, tz: tz)
            try? insightEngine.generate(forDay: day, tz: tz)
        }
    }

    // MARK: - Manual log seeds

    // Every id below is a fixed, deterministic string rather than a fresh `ULID.newID()` — see
    // `seedIfNeeded` (BUG-16): re-running `seed()` after an interrupted first run needs each
    // `INSERT OR REPLACE` to land on the *same* row, not mint a duplicate.

    private func seedMedications(now: Date) throws {
        let vitD = MedicationRegimen(id: "demo-med-vitamin-d", name: "Vitamin D", strength: "1000 IU", form: "capsule",
                                     schedule: .daily(times: ["09:00"]), startedAt: DayAttribution.addingDays(-60, to: now, tz: tz),
                                     updatedAt: now, originDeviceId: deviceId)
        let mag = MedicationRegimen(id: "demo-med-magnesium", name: "Magnesium", strength: "200 mg", form: "tablet",
                                    schedule: .daily(times: ["21:00"]), startedAt: DayAttribution.addingDays(-30, to: now, tz: tz),
                                    updatedAt: now, originDeviceId: deviceId)
        try logging.upsertRegimen(vitD)
        try logging.upsertRegimen(mag)

        // A week of adherence: mostly taken, one honest skip (no guilt).
        for day in 0..<7 {
            // DATA-11: DST-safe day arithmetic (see `ingestHealthData`); the small same-day
            // offsets below (600s/300s) stay as plain `addingTimeInterval` — they're a
            // time-of-day nudge within an already-resolved calendar day, not day arithmetic.
            let base = DayAttribution.addingDays(-day, to: now, tz: tz)
            try logging.insertAdherence(AdherenceEvent(id: "demo-adherence-vitd-\(day)", regimenId: vitD.id, kind: .taken,
                                                       scheduledFor: base, occurredAt: base.addingTimeInterval(600),
                                                       tzId: tz, updatedAt: now, originDeviceId: deviceId))
            if day == 3 {
                try logging.insertAdherence(AdherenceEvent(id: "demo-adherence-mag-\(day)", regimenId: mag.id, kind: .skipped,
                                                           scheduledFor: base, occurredAt: base, tzId: tz,
                                                           skipReason: .forgot, updatedAt: now, originDeviceId: deviceId))
            } else {
                try logging.insertAdherence(AdherenceEvent(id: "demo-adherence-mag-\(day)", regimenId: mag.id, kind: .taken,
                                                           scheduledFor: base, occurredAt: base.addingTimeInterval(300),
                                                           tzId: tz, updatedAt: now, originDeviceId: deviceId))
            }
        }
    }

    private func seedSymptoms(now: Date) throws {
        let samples: [(String, Int, Int)] = [  // (symptomId, severity, daysAgo)
            ("headache", 4, 1), ("fatigue", 6, 3), ("poor_sleep", 5, 4),
            ("muscle_ache", 3, 5), ("nasal_congestion", 4, 8),
        ]
        for (id, severity, daysAgo) in samples {
            let day = DayAttribution.addingDays(-daysAgo, to: now, tz: tz)
            try logging.insertSymptom(SymptomEntry(id: "demo-symptom-\(id)", symptomId: id, severity: severity,
                                                   occurredAt: day.addingTimeInterval(40_000),
                                                   tzId: tz, updatedAt: now, originDeviceId: deviceId))
        }
    }

    private func seedWorkouts(now: Date) throws {
        let items: [(String, Double, Int, Double, Int)] = [ // (type, minutes, daysAgo, kcal, rpe)
            ("Run", 34, 1, 320, 6), ("Strength", 48, 3, 260, 7), ("Walk", 52, 4, 180, 3),
        ]
        for (type, minutes, daysAgo, kcal, rpe) in items {
            let day = DayAttribution.addingDays(-daysAgo, to: now, tz: tz)
            let start = day.addingTimeInterval(30_000)
            try logging.upsertWorkout(WorkoutEntry(id: "demo-workout-\(type.lowercased())", activityType: type, startAt: start,
                                                   endAt: start.addingTimeInterval(minutes * 60), tzId: tz,
                                                   energyKcal: kcal, distanceM: type == "Run" ? 5200 : nil,
                                                   avgHr: type == "Run" ? 148 : 120, perceivedEffort: rpe,
                                                   updatedAt: now, originDeviceId: deviceId))
        }
    }

    private func seedNutrition(now: Date) throws {
        let meals: [(String, String, MealType, Double, Double, Int)] = [ // (id, desc, type, kcal, protein, hoursAgo)
            ("demo-nutrition-breakfast", "Oats with yogurt and dates", .breakfast, 420, 18, 6),
            ("demo-nutrition-lunch", "Grilled chicken and rice", .lunch, 640, 45, 2),
            ("demo-nutrition-coffee", "Coffee", .drink, 5, 0, 7),
        ]
        for (id, desc, type, kcal, protein, hoursAgo) in meals {
            // Hours-ago, not days-ago, so plain `addingTimeInterval` stays DST-safe here.
            try logging.upsertNutrition(NutritionEntry(id: id, description: desc, mealType: type,
                                                       energyKcal: kcal, proteinG: protein,
                                                       occurredAt: now.addingTimeInterval(Double(-hoursAgo) * 3600),
                                                       tzId: tz, updatedAt: now, originDeviceId: deviceId))
        }
        // Water intake for today.
        try logging.upsertNutrition(NutritionEntry(id: "demo-nutrition-water", description: "Water", mealType: .drink,
                                                   waterMl: 1500, occurredAt: now.addingTimeInterval(-3600),
                                                   tzId: tz, updatedAt: now, originDeviceId: deviceId))
    }
}
