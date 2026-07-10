import Foundation

public enum TimelineEventType: String, Sendable, CaseIterable, Codable {
    case sleep, workout, meal, medication, symptom, measurement, note, insight

    public var symbolName: String {
        switch self {
        case .sleep: return "moon.stars.fill"
        case .workout: return "figure.run"
        case .meal: return "fork.knife"
        case .medication: return "pills.fill"
        case .symptom: return "bandage.fill"
        case .measurement: return "ruler"
        case .note: return "note.text"
        case .insight: return "sparkles"
        }
    }

    public var displayName: LocalizedString {
        switch self {
        case .sleep: return LocalizedString(en: "Sleep", ar: "نوم")
        case .workout: return LocalizedString(en: "Workout", ar: "تمرين")
        case .meal: return LocalizedString(en: "Meal", ar: "وجبة")
        case .medication: return LocalizedString(en: "Medication", ar: "دواء")
        case .symptom: return LocalizedString(en: "Symptom", ar: "عرض")
        case .measurement: return LocalizedString(en: "Measurement", ar: "قياس")
        case .note: return LocalizedString(en: "Note", ar: "ملاحظة")
        case .insight: return LocalizedString(en: "Insight", ar: "ملاحظة تحليلية")
        }
    }
}

/// A unified, chronological read-model row assembled at query time from sessions, logs and
/// notable samples — BADAN's anti-fragmentation spine (the Timeline screen). Not persisted.
public struct TimelineEvent: Identifiable, Sendable, Hashable {
    public var id: String
    public var type: TimelineEventType
    public var occurredAt: Date
    public var tzId: String
    public var title: LocalizedString
    public var subtitle: LocalizedString?
    public var valueText: String?
    public var sourceRecordId: String?
    public var ingestionPath: IngestionPath?
    public var sensitive: Bool
    /// Auto-ingested rows are provenance-locked and not user-deletable.
    public var deletable: Bool

    public init(id: String, type: TimelineEventType, occurredAt: Date, tzId: String,
                title: LocalizedString, subtitle: LocalizedString? = nil, valueText: String? = nil,
                sourceRecordId: String? = nil, ingestionPath: IngestionPath? = nil,
                sensitive: Bool = false, deletable: Bool = true) {
        self.id = id; self.type = type; self.occurredAt = occurredAt; self.tzId = tzId
        self.title = title; self.subtitle = subtitle; self.valueText = valueText
        self.sourceRecordId = sourceRecordId; self.ingestionPath = ingestionPath
        self.sensitive = sensitive; self.deletable = deletable
    }

    public var symbolName: String { type.symbolName }
}
