import Foundation

/// Loads the wellness-safe insight templates (insight_templates.json). The insight engine
/// selects a template by condition and fills `{metric}`/`{value}`/`{baseline}` in both
/// languages. Wellness-language rules are carried for reference and lint tooling.
final class InsightTemplateStore {
    static let shared = InsightTemplateStore()

    let templates: [InsightTemplate]
    let wellnessRules: [String]
    private let byId: [String: InsightTemplate]

    private struct File: Decodable {
        let templates: [InsightTemplate]
        let wellnessRules: [String]?
    }

    init(templates: [InsightTemplate]? = nil, wellnessRules: [String] = []) {
        let file = BundleJSON.load(File.self, "insight_templates")
        self.templates = templates ?? file?.templates ?? []
        self.wellnessRules = wellnessRules.isEmpty ? (file?.wellnessRules ?? []) : wellnessRules
        self.byId = Dictionary(self.templates.map { ($0.templateId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func template(_ id: String) -> InsightTemplate? { byId[id] }
}
