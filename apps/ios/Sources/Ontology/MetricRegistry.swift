import Foundation

/// The compiled metric ontology (registry.json → MetricDefinition). Single source of every
/// metric's identity, units, names (en+ar), labels, chart hint, baseline eligibility, and
/// sensitivity. The catalog is large on purpose — most of it is browsable in the All-Metrics
/// surface while a curated subset carries data (the "300 metrics behind curated surfaces"
/// idea, right-sized for MVP).
final class MetricRegistry {
    static let shared = MetricRegistry()

    let all: [MetricDefinition]
    private let byId: [String: MetricDefinition]

    private struct File: Decodable { let version: String; let metrics: [MetricDefinition] }

    init(metrics: [MetricDefinition]? = nil) {
        let loaded = metrics ?? BundleJSON.load(File.self, "registry")?.metrics ?? []
        self.all = loaded.sorted { $0.metricId < $1.metricId }
        self.byId = Dictionary(loaded.map { ($0.metricId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func definition(_ metricId: String) -> MetricDefinition? { byId[metricId] }

    /// A definition for an id that might not be in the registry (defensive fallback so an
    /// unknown metric still renders a name rather than crashing).
    func definitionOrFallback(_ metricId: String) -> MetricDefinition {
        byId[metricId] ?? MetricDefinition(
            metricId: metricId, family: metricId.split(separator: ".").first.map(String.init) ?? "other",
            kind: .rawSample, canonicalUnit: "", displayUnits: [], nameEn: metricId, nameAr: metricId,
            casualLabel: metricId, preciseLabel: metricId, chartHint: .line, baselineEligible: false,
            sensitiveClass: .normal)
    }

    func metrics(in family: MetricFamily) -> [MetricDefinition] {
        all.filter { $0.familyGroup == family }
    }

    func metrics(family: String) -> [MetricDefinition] {
        all.filter { $0.family == family }
    }

    /// Families present in the registry, in a stable display order.
    var families: [MetricFamily] {
        let present = Set(all.map { $0.familyGroup })
        return MetricFamily.allCases.filter { present.contains($0) }
    }

    var baselineEligible: [MetricDefinition] { all.filter { $0.baselineEligible } }

    /// Case/diacritic-insensitive search over English + Arabic names and the id.
    func search(_ query: String) -> [MetricDefinition] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.nameEn.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
                || $0.nameAr.contains(query)
                || $0.metricId.contains(q)
                || $0.preciseLabel.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
    }
}
