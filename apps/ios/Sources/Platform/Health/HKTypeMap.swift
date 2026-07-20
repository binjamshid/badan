import Foundation
import HealthKit

/// The data-driven HealthKit-type ↔ BADAN-metric table (PERF-181, EPIC-01).
///
/// This is the TODO that used to sit on `HealthKitAdapter.readTypes`: the read set was a
/// hand-maintained `Set<HKObjectType>` and every unit/metric mapping lived inline in whichever
/// read method happened to need it, so adding a type meant editing four places and remembering
/// a fifth (the anchor key). Everything a type needs is now one row here — read set,
/// authorization bundle, metric id, unit label, read strategy, anchor key, backfill caveat —
/// and `HealthKitAdapter` iterates the table instead of repeating itself per type.
///
/// Deliberately NOT derived from `registry.json` at runtime, which is what the old TODO
/// speculated about. The registry is the *ontology* (what a metric means, its canonical unit,
/// how it is displayed); this table is the *platform binding* (which Apple identifier feeds it,
/// which `HKUnit` to read it out of, which query shape resolves cross-source overlap correctly).
/// Those are different facts with different review audiences, and folding the second into the
/// shared cross-platform contract would put `HKQuantityTypeIdentifier` strings into a file
/// Android also loads. The registry stays the authority on units — `IngestionPipeline` converts
/// every value read here into `MetricDefinition.canonicalUnit` — so the two cannot silently
/// disagree about what a stored value means.
enum HKTypeMap {

    // MARK: - Read strategy

    /// How one type is read, and therefore which DTO it becomes. See plan §13.2.
    enum ReadStrategy: Equatable {
        /// `HKAnchoredObjectQuery` → `SampleDTO` → `raw_samples`. For genuinely instantaneous
        /// readings where each sample is its own fact (heart rate, SpO2, a weigh-in).
        case anchoredSample
        /// `HKAnchoredObjectQuery` → `IntervalDTO` → `interval_records`, carrying the sample's
        /// own span. For types HealthKit emits as already-summarized discrete samples (resting
        /// heart rate is one value per day; VO2 max is one estimate per workout-ish event).
        ///
        /// See the caveat in `HealthKitAdapter.readAnchoredIntervals` about types that emit
        /// MANY samples per day (HRV, respiratory rate) landing as several interval rows for
        /// one day — that is a known, documented limitation of this shape, not an accident.
        case anchoredInterval(Aggregation)
        /// `HKStatisticsCollectionQuery` with `.cumulativeSum`, bucketed per local day →
        /// `IntervalDTO`. The ONLY correct shape for cumulative types that more than one source
        /// double-writes (Watch and iPhone both logging the same walk): summing raw per-source
        /// samples ourselves double-counts, and only HealthKit's own aggregation resolves the
        /// overlap. Costs the incremental anchor (each ingest recomputes the range) — safe
        /// because these upsert idempotently by (metric, day, source). See `readDailySum`.
        case statisticsCumulative
        /// Requested in the authorization bundle, but deliberately NOT turned into measurement
        /// rows by this epic. See `NoIngestReason` — every use of this case states which of the
        /// two reasons applies and what would have to be true to promote it.
        ///
        /// (Audit 2026-07-20, finding #8) This used to say "and observed for background
        /// delivery", which was never true: `HealthKitObserverRegistrar.observedTypes()` skips
        /// every row whose `metricId` is nil, on purpose — an observer wake spent re-querying a
        /// type nothing stores counts against the three-strikes background budget for no
        /// possible benefit. Authorization and observation are separate sets here, and the
        /// comment claiming otherwise is what made "wrist temperature already has a warm
        /// observer" look like a settled fact when nothing had ever registered one.
        case authorizationOnly(NoIngestReason)
    }

    /// Why a type BADAN asks permission to read produces no rows yet. Both cases are real
    /// product decisions, not laziness, and both would be a data-integrity bug to "fix" by
    /// simply writing the value somewhere.
    enum NoIngestReason: Equatable {
        /// BADAN models this as a profile attribute, not a time series. Height lives on
        /// `UserProfile.heightMeters` (see `Domain/Sources.swift`) because it is a demographic
        /// input to derivations like BMI, not something whose daily history anyone charts —
        /// and correspondingly there is no `body.height` id in the metric registry to write to.
        /// Promoting this means wiring `ProfileRepository`, not adding a metric row.
        case profileAttribute
        /// HealthKit exposes an ABSOLUTE reading; the registry metric is a DEVIATION from the
        /// person's own usual level, and the two are not the same number.
        ///
        /// `appleSleepingWristTemperature` is an absolute wrist temperature (~35 °C).
        /// `body.wrist_temp_deviation`'s own explainer says it is "how far your overnight wrist
        /// temperature sat from your own usual level, rather than an absolute reading", and
        /// plan §4.9 ("no false precision") names temperature deviation specifically as the
        /// thing that must not be presented as an absolute. Writing 35.2 into a metric the UI
        /// labels "deviation" would put a nonsense number in front of the user with full
        /// provenance attached, which is worse than showing nothing.
        ///
        /// The missing piece is a personal-baseline derivation (deviation = reading − the
        /// user's own trailing baseline), which belongs to the derivation layer under its own
        /// `AlgorithmVersion` — it is an I2 append-only derived value, and an adapter has
        /// neither the history nor the versioning to compute it honestly. The type stays in the
        /// read set so the derivation epic inherits granted permission rather than having to
        /// re-prompt.
        ///
        /// (Audit 2026-07-20) Re-examined against the "≥25 metrics flowing" Phase-0 metric and
        /// deliberately left deferred, because promoting it needs three things that live outside
        /// this file and outside the adapter layer entirely:
        ///   1. somewhere to put the ABSOLUTE reading. `registry.json` v0.2.0 has
        ///      `body.wrist_temp_deviation` and no absolute-temperature id, so there is no row a
        ///      baseline could be computed over — `IngestionPipeline.writeSamples` would
        ///      `continue` past an unknown id and store nothing.
        ///   2. an entry in `packages/contracts/algorithms/algorithms.json`. No algorithm there
        ///      produces `body.wrist_temp_deviation`; that file is the authority on algorithm
        ///      identity and semver, and inventing an id in Swift instead would put a derived
        ///      value on disk citing an `algorithmVersionId` the contract has never heard of.
        ///   3. ~30 nights of history before the first deviation means anything, per how the
        ///      baseline is defined rather than per any shortcut here.
        /// Writing this row without (1) and (2) would satisfy a metric count while putting an
        /// unfounded number in front of the user, which is the exact trade plan §4.9 forbids.
        case awaitingDerivation
    }

    // MARK: - Table

    /// One HealthKit quantity type's complete binding.
    struct Entry {
        let identifier: HKQuantityTypeIdentifier
        /// `nil` exactly when `strategy` is `.authorizationOnly` — the two are kept consistent
        /// by `validate()` below rather than by convention.
        let metricId: String?
        /// The `HKUnit` values are read out of. Chosen per type to need the least arithmetic on
        /// our side: whatever HealthKit hands back in this unit is passed to the pipeline
        /// labelled `badanUnit`, and `Units` does the rest.
        let hkUnit: HKUnit
        /// BADAN's spelling of `hkUnit`, as `Units.table` knows it. MUST be a unit that converts
        /// to the metric's `canonicalUnit` — a mismatch is not a crash, it is worse: the value
        /// passes through unconverted stamped `.estimate` (see
        /// `IngestionPipeline.canonicalValue`).
        /// `HealthAdapterFixTests.testTypeMapRowsAllResolveToRegistryMetricsWithConvertibleUnits`
        /// asserts every row converts. (Audit 2026-07-20, finding #8: this cited a class
        /// `HKTypeMapTests` that has never existed in the tree — a reader checking the claim
        /// found nothing and had no way to tell whether the assertion was missing or merely
        /// misfiled.)
        let badanUnit: String
        let strategy: ReadStrategy
        /// The honest caveat about how much history this type can actually produce, surfaced by
        /// `HealthKitAdapter.backfillWindows` — see `BackfillCaveat`.
        let caveat: BackfillCaveat
        /// Overrides the slug used to build a `.statisticsCumulative` row's per-day external id
        /// (`healthkit-<slug>-<dayKey>`). Defaults to the metric id.
        ///
        /// Exists for exactly one row: steps shipped before this table did, under the hand-built
        /// id `healthkit-steps-<dayKey>`. External id IS the upsert identity for
        /// `interval_records`, so letting the generalized builder derive `activity.steps` from
        /// the metric id would not "rename" anything — it would orphan every stored steps row and
        /// insert a second row for every day the user already has, silently doubling their step
        /// history at the next sync. Do not remove this override to tidy the table up.
        let dailyTotalSlug: String?

        /// The key this type's anchor is filed under in `read_anchors`, and the `platformType`
        /// passed to `HealthKitAdapter.runAnchoredQuery`.
        ///
        /// `rawValue` is byte-identical to the string literals the pre-PERF-181 adapter wrote by
        /// hand (`"HKQuantityTypeIdentifierHeartRate"` etc.), which is what makes moving heart
        /// rate and resting heart rate onto this table a no-op for existing installs: their
        /// persisted anchors are still found, so nobody re-scans 90 days on upgrade. Pinned by
        /// `testAnchorKeysMatchTheLiteralsWrittenBeforeTheTypeMap`.
        var platformType: String { identifier.rawValue }

        var quantityType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: identifier) }

        init(identifier: HKQuantityTypeIdentifier, metricId: String?, hkUnit: HKUnit,
             badanUnit: String, strategy: ReadStrategy, caveat: BackfillCaveat,
             dailyTotalSlug: String? = nil) {
            self.identifier = identifier; self.metricId = metricId; self.hkUnit = hkUnit
            self.badanUnit = badanUnit; self.strategy = strategy; self.caveat = caveat
            self.dailyTotalSlug = dailyTotalSlug
        }

        /// The `interval_records.external_id` for this type's total on `dayKey`. Stable across
        /// syncs by construction — that stability is what makes the recompute-every-time
        /// statistics strategy idempotent instead of duplicating.
        func dailyTotalExternalId(dayKey: String) -> String {
            "healthkit-\(dailyTotalSlug ?? metricId ?? platformType)-\(dayKey)"
        }
    }

    /// Per-type backfill honesty (EPIC-01 task 8, plan §4.9/§16).
    ///
    /// A first connect asks HealthKit for 90 days, and the Sources screen used to imply it got
    /// 90 days of everything. It never does: respiratory rate and wrist temperature are only
    /// written while you sleep wearing a watch that supports them, VO2 max lands every week or
    /// so, body composition only exists if you own a smart scale. This is the machine-readable
    /// half of saying so — `HealthKitAdapter.backfillWindows` pairs it with the earliest sample
    /// HealthKit will actually hand over, so the UI can state a real date instead of a promise.
    enum BackfillCaveat: Equatable {
        /// Continuously recorded whenever the device is worn; the requested window is usually
        /// achievable in full.
        case continuous
        /// Only recorded during sleep, and only by hardware that supports it.
        case sleepOnly
        /// Recorded sporadically (an estimate produced every few days at best).
        case sporadic
        /// Only exists if the user owns and uses a separate measuring device (a smart scale).
        case requiresAccessory

        /// Wellness-safe, non-alarmist, en+ar. States a limitation of the *data*, never a
        /// judgement about the person or their device.
        var explainer: LocalizedString {
            switch self {
            case .continuous:
                return LocalizedString(
                    en: "Recorded throughout the day while your device is worn.",
                    ar: "يُسجَّل طوال اليوم أثناء ارتداء جهازك.")
            case .sleepOnly:
                return LocalizedString(
                    en: "Recorded only during sleep, and only by devices that support it, so history starts when those nights begin.",
                    ar: "يُسجَّل أثناء النوم فقط، وبالأجهزة التي تدعمه، لذا يبدأ السجل من تلك الليالي.")
            case .sporadic:
                return LocalizedString(
                    en: "Estimated occasionally rather than every day, so days without a reading are expected.",
                    ar: "يُقدَّر من حين لآخر لا يوميًا، لذا من الطبيعي وجود أيام بلا قراءة.")
            case .requiresAccessory:
                return LocalizedString(
                    en: "Comes from a connected scale or similar device, so it appears only for days you measured.",
                    ar: "يأتي من ميزان متصل أو جهاز مشابه، لذا يظهر فقط في الأيام التي قِست فيها.")
            }
        }
    }

    /// Every quantity type BADAN reads, in a stable order (the order the authorization sheet and
    /// the Sources screen list them in).
    ///
    /// Adding a row here is the entire change needed to ingest a new quantity type — but it is
    /// NOT the entire change needed to *ship* one: `project.yml`'s
    /// `NSHealthShareUsageDescription` and both `InfoPlist.strings` name the read set in plain
    /// language, and a type present here but absent there overstates nothing while a type absent
    /// here but named there understates the ask. That three-file coupling is called out in
    /// `project.yml` and is checked at review, not by the compiler.
    static let table: [Entry] = [
        // --- Heart -------------------------------------------------------------------------
        Entry(identifier: .heartRate, metricId: MetricID.heartRate,
              hkUnit: .count().unitDivided(by: .minute()), badanUnit: "bpm",
              strategy: .anchoredSample, caveat: .continuous),
        // HealthKit computes exactly one resting heart rate per day, so the "discrete sample"
        // it hands back is already a daily aggregate — hence `.anchoredInterval(.mean)` rather
        // than a raw sample. This row reproduces the pre-PERF-181 behavior exactly.
        Entry(identifier: .restingHeartRate, metricId: MetricID.restingHeartRate,
              hkUnit: .count().unitDivided(by: .minute()), badanUnit: "bpm",
              strategy: .anchoredInterval(.mean), caveat: .continuous),
        // SDNN is delivered in seconds by HealthKit; reading it out in milliseconds matches
        // `heart.hrv`'s canonical unit exactly and avoids a lossy round trip through `s`.
        Entry(identifier: .heartRateVariabilitySDNN, metricId: MetricID.hrv,
              hkUnit: .secondUnit(with: .milli), badanUnit: "ms",
              strategy: .anchoredInterval(.mean), caveat: .continuous),
        Entry(identifier: .vo2Max, metricId: MetricID.vo2Max,
              hkUnit: Self.vo2MaxUnit, badanUnit: "mL/kg/min",
              // `.latest`, not `.mean`: VO2 max is an estimate that supersedes the previous one
              // rather than a quantity to average across a day.
              strategy: .anchoredInterval(.latest), caveat: .sporadic),

        // --- Respiratory -------------------------------------------------------------------
        // HealthKit spells this unit `count/min`; the thing being counted is breaths, which is
        // what `respiratory.rate`'s canonical `breaths/min` means. Labelling it `breaths/min`
        // here (rather than `count/min`) is deliberate and is what keeps the conversion an
        // identity instead of a cross-dimension throw that would stamp every reading
        // `.estimate` — `count/min` and `breaths/min` are separate dimensions in `Units.table`
        // on purpose, so a heart-rate value can never silently become a breathing rate.
        Entry(identifier: .respiratoryRate, metricId: MetricID.respiratoryRate,
              hkUnit: .count().unitDivided(by: .minute()), badanUnit: "breaths/min",
              strategy: .anchoredInterval(.mean), caveat: .sleepOnly),
        // (DATA-02) `HKUnit.percent()` yields a FRACTION: a 97% reading reads back as 0.97, not
        // 97. Labelling it `fraction` lets `Units` scale it to the registry's `percent`
        // canonical (0.97 → 97), which is the same 0–100 number `FakeHealthStore` produces via
        // `"%"`. Labelling it `percent` here instead would store 0.97 as "97 percent" — a
        // hundredfold error that no flag would catch, because the conversion would "succeed".
        Entry(identifier: .oxygenSaturation, metricId: MetricID.spo2,
              hkUnit: .percent(), badanUnit: "fraction",
              strategy: .anchoredSample, caveat: .sleepOnly),

        // --- Activity ----------------------------------------------------------------------
        // `dailyTotalSlug: "steps"` preserves the pre-EPIC-01 external id — see the field's doc.
        Entry(identifier: .stepCount, metricId: MetricID.steps,
              hkUnit: .count(), badanUnit: "count",
              strategy: .statisticsCumulative, caveat: .continuous, dailyTotalSlug: "steps"),
        Entry(identifier: .activeEnergyBurned, metricId: MetricID.activeEnergy,
              hkUnit: .kilocalorie(), badanUnit: "kcal",
              strategy: .statisticsCumulative, caveat: .continuous),
        Entry(identifier: .basalEnergyBurned, metricId: MetricID.restingEnergy,
              hkUnit: .kilocalorie(), badanUnit: "kcal",
              strategy: .statisticsCumulative, caveat: .continuous),
        Entry(identifier: .distanceWalkingRunning, metricId: MetricID.distance,
              hkUnit: .meter(), badanUnit: "m",
              strategy: .statisticsCumulative, caveat: .continuous),
        Entry(identifier: .flightsClimbed, metricId: MetricID.floors,
              hkUnit: .count(), badanUnit: "count",
              strategy: .statisticsCumulative, caveat: .continuous),

        // --- Body --------------------------------------------------------------------------
        Entry(identifier: .bodyMass, metricId: MetricID.weight,
              hkUnit: .gramUnit(with: .kilo), badanUnit: "kg",
              strategy: .anchoredSample, caveat: .requiresAccessory),
        // Same `HKUnit.percent()` fraction semantics as SpO2 above.
        Entry(identifier: .bodyFatPercentage, metricId: MetricID.bodyFatPercentage,
              hkUnit: .percent(), badanUnit: "fraction",
              strategy: .anchoredSample, caveat: .requiresAccessory),
        Entry(identifier: .leanBodyMass, metricId: MetricID.leanMass,
              hkUnit: .gramUnit(with: .kilo), badanUnit: "kg",
              strategy: .anchoredSample, caveat: .requiresAccessory),
        Entry(identifier: .height, metricId: nil,
              hkUnit: .meter(), badanUnit: "m",
              strategy: .authorizationOnly(.profileAttribute), caveat: .sporadic),
        Entry(identifier: .appleSleepingWristTemperature, metricId: nil,
              hkUnit: .degreeCelsius(), badanUnit: "degC",
              strategy: .authorizationOnly(.awaitingDerivation), caveat: .sleepOnly),
    ]

    /// `mL/(kg·min)`, built from components rather than `HKUnit(from:)` so a typo in the unit
    /// string fails at compile time instead of trapping at runtime — `HKUnit(from:)` raises an
    /// `NSException` on an unparseable string, which Swift cannot catch.
    private static let vo2MaxUnit: HKUnit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    // MARK: - Derived views

    static func entry(for identifier: HKQuantityTypeIdentifier) -> Entry? {
        table.first { $0.identifier == identifier }
    }

    static var anchoredSampleEntries: [Entry] {
        table.filter { $0.strategy == .anchoredSample }
    }

    static var anchoredIntervalEntries: [Entry] {
        table.filter { if case .anchoredInterval = $0.strategy { return true } else { return false } }
    }

    static var cumulativeEntries: [Entry] {
        table.filter { $0.strategy == .statisticsCumulative }
    }

    /// Every type in the initial authorization bundle: the quantity types above plus sleep
    /// analysis and workouts.
    ///
    /// Workout ROUTES are deliberately absent. Routes are location data behind their own consent
    /// screen (plan §13.1/§4.11) and `project.yml` states in as many words that naming them in
    /// the first prompt would ask for something that prompt does not explain — see
    /// `HealthKitAdapter.routeReadTypes`, which is requested separately and only after the user
    /// has seen the route explainer.
    static var authorizationReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for entry in table {
            if let quantityType = entry.quantityType { types.insert(quantityType) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    /// Sample types worth asking "which sources have written to this?" — i.e. everything the
    /// adapter actually ingests, so `sourceDescriptors` discovers a smart scale that only ever
    /// writes `bodyMass` as well as a watch that writes everything.
    ///
    /// `.authorizationOnly` rows are excluded on purpose: discovering a source we will never
    /// store a row from would catalog a `Source` with no measurements attached to it, which
    /// reads as a broken connection in the Sources screen rather than as an honest one.
    static var sourceDiscoveryTypes: [HKSampleType] {
        table.compactMap { entry in
            guard entry.metricId != nil else { return nil }
            return entry.quantityType
        }
    }

    // MARK: - Workout activity types

    /// Apple's `HKWorkoutActivityType` is a numeric enum whose raw values are an Apple
    /// implementation detail. Every stored/exported workout carries a BADAN slug from this table
    /// instead, so a `sessions.detail` JSON written today still means "running" after Apple
    /// renumbers or extends the enum, and so the Android mirror (Health Connect's
    /// `ExerciseSessionRecord.EXERCISE_TYPE_*`) can map onto the same vocabulary rather than
    /// onto Apple's integers.
    ///
    /// Unmapped types fall back to `other_<rawValue>` rather than to a bare "other": the raw
    /// value is the only remaining evidence of what the workout actually was, and discarding it
    /// would make the row permanently unrecoverable if the slug is added later. Deliberately not
    /// exhaustive — `HKWorkoutActivityType` has ~80 cases and enumerating all of them here would
    /// be churn with no reader; the common ones are named and the rest round-trip.
    static func activitySlug(for type: HKWorkoutActivityType) -> String {
        Self.activitySlugs[type] ?? "other_\(type.rawValue)"
    }

    private static let activitySlugs: [HKWorkoutActivityType: String] = [
        .walking: "walking",
        .running: "running",
        .cycling: "cycling",
        .swimming: "swimming",
        .hiking: "hiking",
        .rowing: "rowing",
        .elliptical: "elliptical",
        .stairClimbing: "stair_climbing",
        .highIntensityIntervalTraining: "hiit",
        .traditionalStrengthTraining: "strength_training",
        .functionalStrengthTraining: "functional_strength",
        .coreTraining: "core_training",
        .yoga: "yoga",
        .pilates: "pilates",
        .flexibility: "flexibility",
        .mindAndBody: "mind_and_body",
        // `.dance` is deprecated in favour of these two; both map to the same BADAN slug because
        // the distinction Apple drew (cardio vs. social) is not one BADAN's vocabulary makes,
        // and a workout recorded under the old case still round-trips via `other_<rawValue>`.
        .cardioDance: "dance",
        .socialDance: "dance",
        .soccer: "soccer",
        .basketball: "basketball",
        .tennis: "tennis",
        .badminton: "badminton",
        .tableTennis: "table_tennis",
        .volleyball: "volleyball",
        .golf: "golf",
        .boxing: "boxing",
        .martialArts: "martial_arts",
        .climbing: "climbing",
        .skatingSports: "skating",
        .snowSports: "snow_sports",
        .surfingSports: "surfing",
        .waterFitness: "water_fitness",
        .cooldown: "cooldown",
        .preparationAndRecovery: "preparation_and_recovery",
        .other: "other",
    ]

    // MARK: - Self-check

    /// Structural problems with the table that the type system cannot express, returned as
    /// human-readable strings (empty means healthy).
    ///
    /// Exists for the same reason `Units.unknownUnits(in:)` does: the failure modes here are all
    /// silent at runtime. A row whose `badanUnit` does not convert to its metric's canonical unit
    /// still "works" — it stores an unconverted number stamped `.estimate`, and nobody notices
    /// until a chart is wrong by a factor of 4.184. A row naming a metric id the registry has
    /// never heard of is worse: `IngestionPipeline.writeSamples` skips unknown metric ids with a
    /// bare `continue`, so the type reads successfully, costs a query every sync, and writes
    /// nothing at all.
    /// `HealthAdapterFixTests.testTypeMapRowsAllResolveToRegistryMetricsWithConvertibleUnits`
    /// fails the build on either. (Audit 2026-07-20, finding #8: this named `HKTypeMapTests`,
    /// which does not exist — the self-check looked enforced when the only thing pointing at it
    /// was a dead reference.)
    static func validate(registry: MetricRegistry) -> [String] {
        var problems: [String] = []
        var seen = Set<HKQuantityTypeIdentifier>()
        for entry in table {
            if !seen.insert(entry.identifier).inserted {
                problems.append("\(entry.platformType): duplicated in the table")
            }
            switch entry.strategy {
            case .authorizationOnly:
                if entry.metricId != nil {
                    problems.append("\(entry.platformType): .authorizationOnly rows must carry no metricId")
                }
                continue
            case .anchoredSample, .anchoredInterval, .statisticsCumulative:
                break
            }
            guard let metricId = entry.metricId else {
                problems.append("\(entry.platformType): ingesting strategy with no metricId")
                continue
            }
            guard let definition = registry.definition(metricId) else {
                problems.append("\(entry.platformType): metric id '\(metricId)' is not in the registry")
                continue
            }
            if (try? Units.convert(1, from: entry.badanUnit, to: definition.canonicalUnit)) == nil {
                problems.append("\(entry.platformType): unit '\(entry.badanUnit)' does not convert to canonical '\(definition.canonicalUnit)'")
            }
        }
        return problems
    }
}
