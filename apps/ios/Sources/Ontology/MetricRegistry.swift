import Foundation
import os

/// The compiled metric ontology (registry.json → MetricDefinition). Single source of every
/// metric's identity, units, names (en+ar), labels, chart hint, baseline eligibility, and
/// sensitivity. The catalog is large on purpose — most of it is browsable in the All-Metrics
/// surface while a curated subset carries data (the "300 metrics behind curated surfaces"
/// idea, right-sized for MVP).
final class MetricRegistry {
    static let shared = MetricRegistry()

    /// Below this many loaded metrics the registry is treated as corrupted/missing rather than
    /// legitimately small. `assertionFailure` alone is a no-op in Release, so a broken
    /// `scripts/sync_ios_resources.sh` mirror step could otherwise ship an empty registry with
    /// no runtime signal — this logs the failure via `Logger` so it's visible in Release too.
    ///
    /// Raised 40 -> 60 with registry v0.2.0 (EPIC-07), which took the catalog from 44 to 72
    /// metrics. This is deliberately a floor well BELOW the real count, not an equality check:
    /// it exists to catch a truncated/empty/missing mirror, and pinning it to the exact count
    /// would turn every legitimate registry addition into a code change in two apps — which is
    /// exactly the coupling the data-driven ontology exists to avoid.
    private static let minimumHealthyMetricCount = 60
    private static let logger = Logger(subsystem: "net.albayyan.badan", category: "Ontology")

    let all: [MetricDefinition]
    let baselineEligible: [MetricDefinition]
    private let byId: [String: MetricDefinition]
    private let byFamily: [MetricFamily: [MetricDefinition]]
    private let foldedNameEn: [String: String]
    private let foldedNameAr: [String: String]
    private let foldedPreciseLabel: [String: String]

    private struct File: Decodable { let version: String; let metrics: [MetricDefinition] }

    init(metrics: [MetricDefinition]? = nil) {
        let loaded = metrics ?? BundleJSON.load(File.self, "registry")?.metrics ?? []
        self.all = loaded.sorted { $0.metricId < $1.metricId }
        self.byId = Dictionary(loaded.map { ($0.metricId, $0) }, uniquingKeysWith: { a, _ in a })
        self.baselineEligible = loaded.filter { $0.baselineEligible }
        self.byFamily = Dictionary(grouping: loaded, by: { $0.familyGroup })
        self.foldedNameEn = Dictionary(
            loaded.map { ($0.metricId, Self.searchFold($0.nameEn)) },
            uniquingKeysWith: { a, _ in a })
        // Arabic names were previously compared as exact substrings while English got case/
        // diacritic folding (FIX-13) — a tashkeel-bearing query (e.g. typed via an IME that adds
        // vowel marks) silently failed to match. Folding both sides with the same helper keeps
        // the two languages' search behavior consistent.
        self.foldedNameAr = Dictionary(
            loaded.map { ($0.metricId, Self.searchFold($0.nameAr)) },
            uniquingKeysWith: { a, _ in a })
        self.foldedPreciseLabel = Dictionary(
            loaded.map { ($0.metricId, Self.searchFold($0.preciseLabel)) },
            uniquingKeysWith: { a, _ in a })

        if loaded.count < Self.minimumHealthyMetricCount {
            Self.logger.fault("MetricRegistry loaded only \(loaded.count) metrics (expected >= \(Self.minimumHealthyMetricCount)) — bundled registry.json may be missing or corrupted")
        }
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
        byFamily[family] ?? []
    }

    func metrics(family: String) -> [MetricDefinition] {
        all.filter { $0.family == family }
    }

    /// Families present in the registry, in a stable display order.
    var families: [MetricFamily] {
        let present = Set(all.map { $0.familyGroup })
        return MetricFamily.allCases.filter { present.contains($0) }
    }

    /// Case/diacritic-insensitive search over English + Arabic names and the id. Only the
    /// (short) query is folded per call; candidate names are folded once at load time.
    func search(_ query: String) -> [MetricDefinition] {
        let q = Self.searchFold(query)
        guard !q.isEmpty else { return all }
        return all.filter {
            (foldedNameEn[$0.metricId] ?? "").contains(q)
                || (foldedNameAr[$0.metricId] ?? "").contains(q)
                || $0.metricId.contains(q)
                || (foldedPreciseLabel[$0.metricId] ?? "").contains(q)
        }
    }

    /// Shared search normalization for names and queries. `.diacriticInsensitive` folding
    /// handles Latin diacritics but does NOT strip Arabic harakat (fatha/damma/kasra/sukun,
    /// U+064B–065F), superscript alef (U+0670), or tatweel (U+0640) — verified by test — so
    /// those are removed explicitly to make tashkeel-bearing queries match plain stored names.
    static func searchFold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { scalar in
            !(0x064B...0x065F).contains(scalar.value) && scalar.value != 0x0670 && scalar.value != 0x0640
        }))
    }
}
