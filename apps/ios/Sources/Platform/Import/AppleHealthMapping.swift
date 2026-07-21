import Foundation
import HealthKit

/// Translates Apple Health `export.xml` vocabulary into BADAN's DTO vocabulary. Kept out of the
/// importer so the two concerns stay separable: the importer owns streaming/flushing/lineage, this
/// owns "what does `HKQuantityTypeIdentifierHeartRate` / `unit="count/min"` / a sleep value string
/// mean here". It leans on `HKTypeMap` — whose `platformType` is exactly the string an export
/// `Record`'s `type` attribute carries — so the metric ids, read strategies and unit expectations
/// an import uses are the SAME table live HealthKit sync uses, never a second, drifting copy.
enum AppleHealthMapping {
    /// Sleep is the one category type BADAN ingests; everything else is a quantity type.
    static let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"

    /// The source id merged daily totals (steps/energy/distance/floors) are attributed to — the
    /// SAME token `HealthKitAdapter.fallbackSourceId` uses, so an imported daily total and a
    /// live-synced one share `(external_id, source_id)` and collapse on upsert instead of doubling.
    /// Honest: this data genuinely came from the user's Apple Health.
    static let mergedTotalSourceId = "healthkit"

    // MARK: - Type lookup

    /// The `HKTypeMap` row whose `platformType` matches an export `Record`'s `type`, if BADAN
    /// ingests that type. Returns `.authorizationOnly` rows too (height, wrist temp); the caller
    /// guards on `metricId == nil` and skips them.
    static func quantityEntry(forType type: String) -> HKTypeMap.Entry? {
        HKTypeMap.table.first { $0.platformType == type }
    }

    /// The cumulative row for a metric, used to build its per-day external id at finalize.
    static func cumulativeEntry(forMetric metricId: String) -> HKTypeMap.Entry? {
        HKTypeMap.table.first { $0.metricId == metricId && $0.strategy == .statisticsCumulative }
    }

    // MARK: - Units

    /// The unit an imported value should be labelled with so `IngestionPipeline`'s canonicalizer
    /// converts it correctly. Type-driven rather than trusting the export's `unit` string blindly,
    /// because that string is ambiguous or misleading for several families:
    ///
    /// - Percent types (SpO2, body fat) export the FRACTION (`0.98`) under `unit="%"`; labelling
    ///   that `"%"` would apply a spurious ×0.01. They are labelled `"fraction"` — the exact
    ///   representation `HKTypeMap` reads from `HKUnit.percent()`, so imports match live sync.
    /// - Respiratory rate exports `unit="count/min"`, but the registry canonical is a SEPARATE
    ///   `breaths/min` dimension (see `Units`); `"count/min"` would throw `.incompatible`. Labelled
    ///   `"breaths/min"`.
    /// - VO2 max exports `mL/min·kg` (middle dot), which `Units` does not know; normalized to
    ///   `"mL/kg/min"`.
    /// - Heart rate / RHR / HRV / steps / floors have one unchanging unit; fixed directly.
    ///
    /// Mass, energy and distance DO honor the export unit (Apple respects the user's locale there —
    /// weight can be `kg` or `lb`, distance `km` or `mi`), falling back to the metric's canonical
    /// unit when the export unit is unknown or a different dimension.
    static func importUnit(metricId: String, xmlUnit: String?, canonical: String?) -> String {
        switch metricId {
        case MetricID.heartRate, MetricID.restingHeartRate: return "bpm"
        case MetricID.hrv: return "ms"
        case MetricID.vo2Max: return "mL/kg/min"
        case MetricID.respiratoryRate: return "breaths/min"
        case MetricID.spo2, MetricID.bodyFatPercentage: return "fraction"
        case MetricID.steps, MetricID.floors: return "count"
        default:
            if let xmlUnit {
                let normalized = normalizeUnit(xmlUnit)
                if let x = Units.table[normalized], let canonical, let c = Units.table[canonical], x.base == c.base {
                    return normalized
                }
            }
            return canonical ?? (xmlUnit.map(normalizeUnit) ?? "")
        }
    }

    /// Apple unit spellings that differ from `Units.table`'s keys.
    static func normalizeUnit(_ unit: String) -> String {
        switch unit {
        case "Cal", "Calorie", "Calories": return "kcal"   // Apple's dietary Calorie == kcal
        case "mL/min·kg", "mL/min/kg", "ml/min·kg", "ml/min/kg": return "mL/kg/min"
        default: return unit
        }
    }

    /// A workout distance unit, defaulting to `km` (Apple's usual) when absent/unknown.
    static func lengthUnit(_ unit: String?) -> String {
        guard let unit else { return "km" }
        let n = normalizeUnit(unit)
        return (Units.table[n]?.base == "m") ? n : "km"
    }

    /// A workout energy unit, defaulting to `kcal` when absent/unknown.
    static func energyUnit(_ unit: String?) -> String {
        guard let unit else { return "kcal" }
        let n = normalizeUnit(unit)
        return (Units.table[n]?.base == "kcal") ? n : "kcal"
    }

    // MARK: - Sleep

    /// Apple's sleep-analysis value strings -> BADAN `SleepStage`. Mirrors
    /// `HealthKitAdapter.mapSleepStage`: `AsleepCore` is light, unspecified/legacy "asleep" is
    /// `asleepUnspecified`. Unknown strings return nil and the segment is skipped.
    static func sleepStage(_ value: String) -> SleepStage? {
        switch value {
        case "HKCategoryValueSleepAnalysisInBed": return .inBed
        case "HKCategoryValueSleepAnalysisAwake": return .awake
        case "HKCategoryValueSleepAnalysisAsleepCore": return .light
        case "HKCategoryValueSleepAnalysisAsleepDeep": return .deep
        case "HKCategoryValueSleepAnalysisAsleepREM": return .rem
        case "HKCategoryValueSleepAnalysisAsleepUnspecified", "HKCategoryValueSleepAnalysisAsleep": return .asleepUnspecified
        default: return nil
        }
    }

    // MARK: - Workout activity

    /// `HKWorkoutActivityTypeRunning` -> `"running"`, reusing the same BADAN slug vocabulary the
    /// live path uses (`HKTypeMap.activitySlug`), which the export can't reach directly because it
    /// carries the string name, not Apple's numeric enum. Unmapped names keep their evidence:
    /// `other_<lowercased-name>`, so a slug added later can still recover what the workout was.
    static func activitySlug(for activityTypeName: String) -> String {
        if let slug = activitySlugs[activityTypeName] { return slug }
        let stripped = activityTypeName.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        return "other_" + stripped.lowercased()
    }

    private static let activitySlugs: [String: String] = [
        "HKWorkoutActivityTypeWalking": "walking",
        "HKWorkoutActivityTypeRunning": "running",
        "HKWorkoutActivityTypeCycling": "cycling",
        "HKWorkoutActivityTypeSwimming": "swimming",
        "HKWorkoutActivityTypeHiking": "hiking",
        "HKWorkoutActivityTypeRowing": "rowing",
        "HKWorkoutActivityTypeElliptical": "elliptical",
        "HKWorkoutActivityTypeStairClimbing": "stair_climbing",
        "HKWorkoutActivityTypeHighIntensityIntervalTraining": "hiit",
        "HKWorkoutActivityTypeTraditionalStrengthTraining": "strength_training",
        "HKWorkoutActivityTypeFunctionalStrengthTraining": "functional_strength",
        "HKWorkoutActivityTypeCoreTraining": "core_training",
        "HKWorkoutActivityTypeYoga": "yoga",
        "HKWorkoutActivityTypePilates": "pilates",
        "HKWorkoutActivityTypeFlexibility": "flexibility",
        "HKWorkoutActivityTypeMindAndBody": "mind_and_body",
        "HKWorkoutActivityTypeCardioDance": "dance",
        "HKWorkoutActivityTypeSocialDance": "dance",
        "HKWorkoutActivityTypeSoccer": "soccer",
        "HKWorkoutActivityTypeBasketball": "basketball",
        "HKWorkoutActivityTypeTennis": "tennis",
        "HKWorkoutActivityTypeBadminton": "badminton",
        "HKWorkoutActivityTypeTableTennis": "table_tennis",
        "HKWorkoutActivityTypeVolleyball": "volleyball",
        "HKWorkoutActivityTypeGolf": "golf",
        "HKWorkoutActivityTypeBoxing": "boxing",
        "HKWorkoutActivityTypeMartialArts": "martial_arts",
        "HKWorkoutActivityTypeClimbing": "climbing",
        "HKWorkoutActivityTypeSkatingSports": "skating",
        "HKWorkoutActivityTypeSnowSports": "snow_sports",
        "HKWorkoutActivityTypeSurfingSports": "surfing",
        "HKWorkoutActivityTypeWaterFitness": "water_fitness",
        "HKWorkoutActivityTypeCooldown": "cooldown",
        "HKWorkoutActivityTypePreparationAndRecovery": "preparation_and_recovery",
        "HKWorkoutActivityTypeOther": "other",
    ]

    // MARK: - Sources

    /// Build a `SourceDescriptor` for an export row's `sourceName` (+ optional `device` string).
    /// The id is a slug prefixed `ah:` so an imported source is a distinct catalog entry from any
    /// live-sync source (the two still reconcile per-night for sleep via dedup-lite).
    ///
    /// The device-class priority is resolved HERE rather than left at 0 for
    /// `IngestionPipeline.inferredPriority` to fill in, because the importer itself needs it too:
    /// picking which source's daily total represents a day (device wins, I4) happens before any
    /// DTO reaches the pipeline. Setting it explicitly means both readings of "is this a watch?"
    /// come from one answer instead of two heuristics that could disagree — and the pipeline
    /// honours a non-zero priority as given.
    static func sourceDescriptor(sourceName: String?, device: String?) -> (descriptor: SourceDescriptor, name: String) {
        let name = (sourceName?.isEmpty == false) ? sourceName! : "Apple Health"
        let parsed = parseDevice(device)
        let descriptor = SourceDescriptor(
            id: "ah:" + slugify(name), displayName: name, type: .healthkit, bundleId: nil,
            deviceId: nil, deviceName: parsed.name ?? name, deviceModel: parsed.model,
            priority: devicePriority(name: name, deviceName: parsed.name, model: parsed.model))
        return (descriptor, name)
    }

    /// Mirrors `IngestionPipeline.inferredPriority` / `HealthKitAdapter.sourcePriority`: a wrist- or
    /// ring-class device outranks a phone, everything else is unranked. Arabic keywords included for
    /// the same reason `HealthKitAdapter` includes them (FIX-09) — an Arabic-named source must not
    /// fall to 0 purely because of language.
    static func devicePriority(name: String, deviceName: String?, model: String?) -> Int {
        let hay = [name, deviceName ?? "", model ?? ""].joined(separator: " ").lowercased()
        if wearableKeywords.contains(where: hay.contains) { return 2 }
        if hay.contains("phone") || hay.contains("هاتف") || hay.contains("جوال") { return 1 }
        return 0
    }

    private static let wearableKeywords = [
        "watch", "ring", "band", "oura", "whoop", "fenix", "garmin", "fitbit", "polar",
        "ساعة", "خاتم", "سوار",
    ]

    /// Extract `name:` and `model:`/`hardware:` from Apple's `device` attribute, e.g.
    /// `<<HKDevice: 0x…>, name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch6,1, …>`.
    private static func parseDevice(_ device: String?) -> (name: String?, model: String?) {
        guard let device else { return (nil, nil) }
        var fields: [String: String] = [:]
        // Split on commas, then take the first "key:value" on each side. `hardware:Watch6,1`
        // contains a comma, so read greedily to end-of-token by re-joining unknown fragments.
        for part in device.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: " >"))
            if fields[key] == nil { fields[key] = value }
        }
        return (fields["name"], fields["hardware"] ?? fields["model"])
    }

    private static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        // Collapse runs of "-" and trim, so "Binjamshid's iPhone" -> "binjamshid-s-iphone".
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "source" : collapsed
    }

    // MARK: - Dates

    /// Apple export timestamps are `yyyy-MM-dd HH:mm:ss ±HHMM`. Returns the absolute instant plus
    /// an IANA-parseable fixed-offset tz identifier (e.g. `GMT-0800`) — the export carries only the
    /// numeric offset, never the zone name, so imports flag the tz `.tzAssumed`.
    static func parseDate(_ string: String) -> (date: Date, tz: String)? {
        guard let date = dateFormatter.date(from: string) else { return nil }
        return (date, timeZoneIdentifier(from: string))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    static func timeZoneIdentifier(from string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.lastIndex(of: " ") else { return "GMT" }
        let token = String(trimmed[trimmed.index(after: spaceIdx)...])   // "±HHMM"
        guard token.count == 5, let sign = token.first, sign == "+" || sign == "-",
              let hh = Int(token.dropFirst().prefix(2)), let mm = Int(token.dropFirst(3).prefix(2)) else { return "GMT" }
        let seconds = (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60)
        return TimeZone(secondsFromGMT: seconds)?.identifier ?? "GMT"
    }
}
