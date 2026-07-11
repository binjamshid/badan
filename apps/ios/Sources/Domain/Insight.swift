import Foundation

/// A deterministic, template-rendered interpretation. MVP generation is rules + templates
/// (no LLM); the entity exists so the explainability contract is proven before any engine.
/// Every insight ties back to the derived values and records that justify it.
public struct Insight: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var insightType: String        // e.g. "statusExplanation"
    public var templateId: String
    public var templateVersion: String
    public var metricIds: [String]
    public var periodKey: String
    public var depthVariant: DepthPolicy
    public var renderedText: LocalizedString
    public var evidenceRefs: [String]      // derived-value + record ids
    public var generatedAt: Date
    public var algorithmVersion: String?
    public var feedback: Int?              // -1 / 0 / +1

    public init(id: String, insightType: String, templateId: String, templateVersion: String,
                metricIds: [String], periodKey: String, depthVariant: DepthPolicy,
                renderedText: LocalizedString, evidenceRefs: [String], generatedAt: Date,
                algorithmVersion: String? = nil, feedback: Int? = nil) {
        self.id = id; self.insightType = insightType; self.templateId = templateId
        self.templateVersion = templateVersion; self.metricIds = metricIds
        self.periodKey = periodKey; self.depthVariant = depthVariant
        self.renderedText = renderedText; self.evidenceRefs = evidenceRefs
        self.generatedAt = generatedAt; self.algorithmVersion = algorithmVersion
        self.feedback = feedback
    }
}

/// A wellness-safe sentence template loaded from `insight_templates.json`. `{metric}`,
/// `{value}`, `{baseline}` placeholders are filled in both languages simultaneously.
public struct InsightTemplate: Codable, Hashable, Sendable, Identifiable {
    public var templateId: String
    public var metricFamily: String
    public var conditionEn: String
    public var textEn: String
    public var textAr: String

    public var id: String { templateId }

    private enum CodingKeys: String, CodingKey {
        case templateId = "id", metricFamily, conditionEn, textEn, textAr
    }

    public var text: LocalizedString { LocalizedString(en: textEn, ar: textAr) }
}
