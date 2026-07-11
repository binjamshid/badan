import Foundation

// MARK: - Medications (sensitivePlus)

/// A medication schedule. No dosing advice lives anywhere near this type — BADAN records,
/// it never prescribes. Enum-with-associated-values gets automatic Codable synthesis.
public enum MedicationSchedule: Codable, Hashable, Sendable {
    case asNeeded
    case daily(times: [String])                 // "HH:mm" local times
    case weekly(days: [Int], times: [String])   // days 1=Mon ... 7=Sun

    public var isScheduled: Bool { if case .asNeeded = self { return false }; return true }

    /// Local "HH:mm" slots this regimen is due on a given weekday (1=Mon...7=Sun).
    public func dueTimes(onWeekday weekday: Int) -> [String] {
        switch self {
        case .asNeeded: return []
        case .daily(let times): return times
        case .weekly(let days, let times): return days.contains(weekday) ? times : []
        }
    }
}

public struct MedicationRegimen: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var strength: String?
    public var form: String?          // tablet, capsule, ml...
    public var schedule: MedicationSchedule
    public var startedAt: Date
    public var endedAt: Date?
    public var notes: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var isActive: Bool { endedAt == nil }

    public init(id: String, name: String, strength: String? = nil, form: String? = nil,
                schedule: MedicationSchedule, startedAt: Date, endedAt: Date? = nil,
                notes: String? = nil, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.strength = strength; self.form = form
        self.schedule = schedule; self.startedAt = startedAt; self.endedAt = endedAt
        self.notes = notes; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

public enum AdherenceKind: String, Codable, Hashable, Sendable {
    case taken, skipped, late
}

/// Skip-with-reason is a first-class equal of "taken" — non-punitive by design (no guilt).
public enum SkipReason: String, Codable, Hashable, Sendable, CaseIterable {
    case forgot, sideEffects, ranOut, doctorAdvice, notNeeded, other

    public var displayLabel: LocalizedString {
        switch self {
        case .forgot: return LocalizedString(en: "Forgot", ar: "نسيت")
        case .sideEffects: return LocalizedString(en: "Side effects", ar: "آثار جانبية")
        case .ranOut: return LocalizedString(en: "Ran out", ar: "نفد")
        case .doctorAdvice: return LocalizedString(en: "Doctor's advice", ar: "بناءً على نصيحة الطبيب")
        case .notNeeded: return LocalizedString(en: "Not needed", ar: "غير ضروري")
        case .other: return LocalizedString(en: "Other", ar: "أخرى")
        }
    }
}

public struct AdherenceEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var regimenId: String
    public var kind: AdherenceKind
    public var scheduledFor: Date?
    public var occurredAt: Date
    public var tzId: String
    public var skipReason: SkipReason?
    public var skipNote: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, regimenId: String, kind: AdherenceKind, scheduledFor: Date? = nil,
                occurredAt: Date, tzId: String, skipReason: SkipReason? = nil, skipNote: String? = nil,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.regimenId = regimenId; self.kind = kind; self.scheduledFor = scheduledFor
        self.occurredAt = occurredAt; self.tzId = tzId; self.skipReason = skipReason
        self.skipNote = skipNote; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

// MARK: - Symptoms (sensitivePlus)

public struct SymptomEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var symptomId: String?      // canonical dictionary id
    public var customLabel: String?    // when not in the dictionary
    public var severity: Int           // 0...10 (scale origin preserved)
    public var occurredAt: Date
    public var tzId: String
    public var durationSeconds: Double?
    public var bodyLocation: String?
    public var triggers: [String]
    public var note: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, symptomId: String? = nil, customLabel: String? = nil, severity: Int,
                occurredAt: Date, tzId: String, durationSeconds: Double? = nil, bodyLocation: String? = nil,
                triggers: [String] = [], note: String? = nil, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.symptomId = symptomId; self.customLabel = customLabel
        self.severity = severity; self.occurredAt = occurredAt; self.tzId = tzId
        self.durationSeconds = durationSeconds; self.bodyLocation = bodyLocation
        self.triggers = triggers; self.note = note; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - Workouts (normal sensitivity)

public struct WorkoutEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var activityType: String
    public var startAt: Date
    public var endAt: Date
    public var tzId: String
    public var energyKcal: Double?
    public var distanceM: Double?
    public var avgHr: Double?
    public var maxHr: Double?
    public var perceivedEffort: Int?   // RPE 1...10
    public var note: String?
    public var ingestionPath: IngestionPath
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public var durationSeconds: Double { endAt.timeIntervalSince(startAt) }

    public init(id: String, activityType: String, startAt: Date, endAt: Date, tzId: String,
                energyKcal: Double? = nil, distanceM: Double? = nil, avgHr: Double? = nil,
                maxHr: Double? = nil, perceivedEffort: Int? = nil, note: String? = nil,
                ingestionPath: IngestionPath = .manual, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.activityType = activityType; self.startAt = startAt; self.endAt = endAt
        self.tzId = tzId; self.energyKcal = energyKcal; self.distanceM = distanceM
        self.avgHr = avgHr; self.maxHr = maxHr; self.perceivedEffort = perceivedEffort
        self.note = note; self.ingestionPath = ingestionPath; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - Nutrition (normal sensitivity)

public enum MealType: String, Codable, Hashable, Sendable, CaseIterable {
    case breakfast, lunch, dinner, snack, drink

    public var displayName: LocalizedString {
        switch self {
        case .breakfast: return LocalizedString(en: "Breakfast", ar: "الفطور")
        case .lunch: return LocalizedString(en: "Lunch", ar: "الغداء")
        case .dinner: return LocalizedString(en: "Dinner", ar: "العشاء")
        case .snack: return LocalizedString(en: "Snack", ar: "وجبة خفيفة")
        case .drink: return LocalizedString(en: "Drink", ar: "مشروب")
        }
    }

    public var symbolName: String {
        switch self {
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.fill"
        case .snack: return "carrot.fill"
        case .drink: return "cup.and.saucer.fill"
        }
    }
}

public struct NutritionEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var description: String
    public var mealType: MealType
    public var energyKcal: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    public var fiberG: Double?
    public var waterMl: Double?
    public var caffeineMg: Double?
    public var lowDetail: Bool          // "quick calories" honestly flagged
    public var occurredAt: Date
    public var tzId: String
    public var note: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, description: String, mealType: MealType, energyKcal: Double? = nil,
                proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil, fiberG: Double? = nil,
                waterMl: Double? = nil, caffeineMg: Double? = nil, lowDetail: Bool = false,
                occurredAt: Date, tzId: String, note: String? = nil, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.description = description; self.mealType = mealType
        self.energyKcal = energyKcal; self.proteinG = proteinG; self.carbsG = carbsG
        self.fatG = fatG; self.fiberG = fiberG; self.waterMl = waterMl; self.caffeineMg = caffeineMg
        self.lowDetail = lowDetail; self.occurredAt = occurredAt; self.tzId = tzId; self.note = note
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

// MARK: - Conditions (sensitivePlus) & Notes (normal)

public enum ConditionStatus: String, Codable, Hashable, Sendable {
    case active, resolved, episodic
}

/// User-declared only — BADAN never infers a condition.
public struct Condition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var status: ConditionStatus
    public var onsetAt: Date?
    public var linkedRegimenIds: [String]
    public var linkedSymptomIds: [String]
    public var notes: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, label: String, status: ConditionStatus, onsetAt: Date? = nil,
                linkedRegimenIds: [String] = [], linkedSymptomIds: [String] = [], notes: String? = nil,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.label = label; self.status = status; self.onsetAt = onsetAt
        self.linkedRegimenIds = linkedRegimenIds; self.linkedSymptomIds = linkedSymptomIds
        self.notes = notes; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}

public struct NoteEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var occurredAt: Date
    public var tzId: String
    public var tags: [String]
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, text: String, occurredAt: Date, tzId: String, tags: [String] = [],
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.text = text; self.occurredAt = occurredAt; self.tzId = tzId
        self.tags = tags; self.updatedAt = updatedAt; self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}
