import Foundation

/// Makes BADAN runnable and inspectable immediately: on first launch it ingests a deterministic
/// 90-day health history from the FakeHealthStore (exercising the real ingestion + dedup path),
/// seeds a handful of manual logs, and computes baselines + insights. Idempotent by presence of
/// sources; `Settings → Reset demo data` calls `seed` after a wipe.
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

    init(catalog: CatalogRepository, ingestion: IngestionPipeline, logging: LoggingRepository,
         measurements: MeasurementRepository, baselines: BaselineEngine, insightEngine: InsightEngine,
         registry: MetricRegistry, clock: Clock, deviceId: String) {
        self.catalog = catalog; self.ingestion = ingestion; self.logging = logging
        self.measurements = measurements; self.baselines = baselines; self.insightEngine = insightEngine
        self.registry = registry; self.clock = clock; self.deviceId = deviceId
        self.tz = TimeZone.current.identifier
    }

    func seedIfNeeded(asOf now: Date) throws {
        if try catalog.sources().isEmpty == false { return }
        try seed(asOf: now)
    }

    /// Re-seeds sensitive-namespace manual logs (medications/symptoms) independently of the
    /// main-DB seed gate. The sensitive DB is separately purgeable (`Settings` → purge
    /// sensitive data), and `seedIfNeeded`'s `catalog.sources()` check never notices that
    /// purge — without this, re-enabling the sensitive module after a purge leaves medications
    /// and symptoms permanently empty (OPT-200).
    func seedSensitiveIfNeeded(asOf now: Date) throws {
        if try logging.allSymptoms().isEmpty == false { return }
        try seedMedications(now: now)
        try seedSymptoms(now: now)
    }

    func seed(asOf now: Date) throws {
        let signpostState = PerformanceLog.signposter.beginInterval("SeedController.seed")
        defer { PerformanceLog.signposter.endInterval("SeedController.seed", signpostState) }

        // 1. Ingest 90 days of device data (sources/devices, samples, intervals, sessions, dedup).
        let store = FakeHealthStore(clock: clock, historyDays: 90, tz: tz)
        let range = HealthDateRange(start: now.addingTimeInterval(-90 * 86_400), end: now)
        _ = try ingestion.ingest(from: store, range: range)

        // 2. User profile (height for BMI context).
        try catalog.saveUserProfile(UserProfile(id: ULID.newID(), displayName: nil, heightMeters: 1.75,
                                                birthYear: 1990, createdAt: now, updatedAt: now))

        // 3. Manual logs.
        try seedMedications(now: now)
        try seedSymptoms(now: now)
        try seedWorkouts(now: now)
        try seedNutrition(now: now)
        try logging.upsertNote(NoteEntry(id: ULID.newID(),
                                         text: "Felt a bit run down midweek; slept early to catch up.",
                                         occurredAt: now.addingTimeInterval(-2 * 86_400), tzId: tz,
                                         updatedAt: now, originDeviceId: deviceId))

        // 4. Derivations + insights. `generate` is a handful of narrow, indexed lookups per key
        // metric (see InsightEngine), so widening this from the prior 4 days to 14 stays cheap
        // while making the Insights feed actually reflect a meaningful slice of the 90-day
        // seeded history instead of looking sparse next to it (EASE-134).
        try baselines.recomputeAll(asOf: now)
        for dayOffset in 0..<14 {
            try? insightEngine.generate(forDay: now.addingTimeInterval(Double(-dayOffset) * 86_400), tz: tz)
        }
    }

    // MARK: - Manual log seeds

    private func seedMedications(now: Date) throws {
        let vitD = MedicationRegimen(id: ULID.newID(), name: "Vitamin D", strength: "1000 IU", form: "capsule",
                                     schedule: .daily(times: ["09:00"]), startedAt: now.addingTimeInterval(-60 * 86_400),
                                     updatedAt: now, originDeviceId: deviceId)
        let mag = MedicationRegimen(id: ULID.newID(), name: "Magnesium", strength: "200 mg", form: "tablet",
                                    schedule: .daily(times: ["21:00"]), startedAt: now.addingTimeInterval(-30 * 86_400),
                                    updatedAt: now, originDeviceId: deviceId)
        try logging.upsertRegimen(vitD)
        try logging.upsertRegimen(mag)

        // A week of adherence: mostly taken, one honest skip (no guilt).
        for day in 0..<7 {
            let base = now.addingTimeInterval(Double(-day) * 86_400)
            try logging.insertAdherence(AdherenceEvent(id: ULID.newID(), regimenId: vitD.id, kind: .taken,
                                                       scheduledFor: base, occurredAt: base.addingTimeInterval(600),
                                                       tzId: tz, updatedAt: now, originDeviceId: deviceId))
            if day == 3 {
                try logging.insertAdherence(AdherenceEvent(id: ULID.newID(), regimenId: mag.id, kind: .skipped,
                                                           scheduledFor: base, occurredAt: base, tzId: tz,
                                                           skipReason: .forgot, updatedAt: now, originDeviceId: deviceId))
            } else {
                try logging.insertAdherence(AdherenceEvent(id: ULID.newID(), regimenId: mag.id, kind: .taken,
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
            try logging.insertSymptom(SymptomEntry(id: ULID.newID(), symptomId: id, severity: severity,
                                                   occurredAt: now.addingTimeInterval(Double(-daysAgo) * 86_400 + 40_000),
                                                   tzId: tz, updatedAt: now, originDeviceId: deviceId))
        }
    }

    private func seedWorkouts(now: Date) throws {
        let items: [(String, Double, Int, Double, Int)] = [ // (type, minutes, daysAgo, kcal, rpe)
            ("Run", 34, 1, 320, 6), ("Strength", 48, 3, 260, 7), ("Walk", 52, 4, 180, 3),
        ]
        for (type, minutes, daysAgo, kcal, rpe) in items {
            let start = now.addingTimeInterval(Double(-daysAgo) * 86_400 + 30_000)
            try logging.upsertWorkout(WorkoutEntry(id: ULID.newID(), activityType: type, startAt: start,
                                                   endAt: start.addingTimeInterval(minutes * 60), tzId: tz,
                                                   energyKcal: kcal, distanceM: type == "Run" ? 5200 : nil,
                                                   avgHr: type == "Run" ? 148 : 120, perceivedEffort: rpe,
                                                   updatedAt: now, originDeviceId: deviceId))
        }
    }

    private func seedNutrition(now: Date) throws {
        let meals: [(String, MealType, Double, Double, Int)] = [ // (desc, type, kcal, protein, hoursAgo)
            ("Oats with yogurt and dates", .breakfast, 420, 18, 6),
            ("Grilled chicken and rice", .lunch, 640, 45, 2),
            ("Coffee", .drink, 5, 0, 7),
        ]
        for (desc, type, kcal, protein, hoursAgo) in meals {
            try logging.upsertNutrition(NutritionEntry(id: ULID.newID(), description: desc, mealType: type,
                                                       energyKcal: kcal, proteinG: protein,
                                                       occurredAt: now.addingTimeInterval(Double(-hoursAgo) * 3600),
                                                       tzId: tz, updatedAt: now, originDeviceId: deviceId))
        }
        // Water intake for today.
        try logging.upsertNutrition(NutritionEntry(id: ULID.newID(), description: "Water", mealType: .drink,
                                                   waterMl: 1500, occurredAt: now.addingTimeInterval(-3600),
                                                   tzId: tz, updatedAt: now, originDeviceId: deviceId))
    }
}
