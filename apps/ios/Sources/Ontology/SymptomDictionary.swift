import Foundation

public struct SymptomDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var category: String

    public var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }
}

/// The canonical, localized symptom vocabulary (symptoms.json). Chip-first logging draws
/// from this; free-text custom labels are still allowed for anything not listed.
final class SymptomDictionary {
    static let shared = SymptomDictionary()

    let all: [SymptomDefinition]
    private let byId: [String: SymptomDefinition]

    private struct File: Decodable { let symptoms: [SymptomDefinition] }

    init(symptoms: [SymptomDefinition]? = nil) {
        let loaded = symptoms ?? BundleJSON.load(File.self, "symptoms")?.symptoms ?? []
        self.all = loaded
        self.byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func definition(_ id: String) -> SymptomDefinition? { byId[id] }

    func displayName(forId id: String?, customLabel: String?) -> LocalizedString {
        if let id, let def = byId[id] { return def.displayName }
        if let customLabel { return LocalizedString(en: customLabel, ar: customLabel) }
        return LocalizedString(en: "Symptom", ar: "عرض")
    }

    var categories: [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for s in all where !seen.contains(s.category) { seen.insert(s.category); ordered.append(s.category) }
        return ordered
    }

    func inCategory(_ category: String) -> [SymptomDefinition] { all.filter { $0.category == category } }

    func search(_ query: String) -> [SymptomDefinition] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.nameEn.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
                || $0.nameAr.contains(query)
        }
    }
}
