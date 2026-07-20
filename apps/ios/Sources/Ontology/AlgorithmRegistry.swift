import Foundation
import os

/// The compiled algorithm contract (`packages/contracts/algorithms/algorithms.json`), loaded
/// exactly like `MetricRegistry`/`SensorQualityMap` so both platforms read the same ids, the same
/// semvers, and the same tuning constants from one file (plan §9 "AlgorithmVersion gains a bundled
/// registry file", §15 "algorithm constants/params live in packages/contracts/algorithms").
///
/// **Why this type exists at all — audit finding #5.** The contract's own `note` claimed "both
/// platforms load this file and ... the loading path is fixed in Phase 0". Neither platform had a
/// loader: nothing anywhere referenced `algorithms.json`, while the sync scripts mirrored it into
/// both bundles and CI gated the mirrors for drift. The file therefore *looked* load-bearing at
/// review — it was mirrored, it was gated, it was documented — and was in fact inert, which is the
/// worst of both worlds: the review cost of a shared contract with none of the guarantees.
/// Deleting this type (or reducing it to a struct nobody constructs) puts the claim back into that
/// state. The Phase-2 score engines are the real consumers; what Phase 0 owes them is a path that
/// is proven to resolve an id and a param, which `AlgorithmRegistryTests` asserts against the
/// bundled file rather than a fixture.
///
/// This loads a versioned *contract*, not remote configuration. Plan §15 rules that out: the file
/// ships in the app binary, so an algorithm change is always an app update with a changelog and
/// never a behaviour change pushed at a user who did not install one.
final class AlgorithmRegistry {
    static let shared = AlgorithmRegistry()

    private static let logger = Logger(subsystem: "net.albayyan.badan", category: "Ontology")

    /// The contract file's own `version`, carried so a diagnostic can state which revision of the
    /// constants produced a number. Not the semver of any one algorithm — that lives per entry,
    /// and it is the per-entry semver that is written onto a `DerivedValue`.
    let version: String
    let all: [AlgorithmDefinition]
    private let byId: [String: AlgorithmDefinition]

    private struct File: Decodable {
        let version: String
        let algorithms: [AlgorithmDefinition]
    }

    /// `file` is an injection point for tests that need to exercise decoding of content that is
    /// deliberately not in the shipped contract (mirrors `SensorQualityMap.init(file:)`).
    init(file: Data? = nil) {
        let loaded: File?
        if let file {
            loaded = try? JSONDecoder().decode(File.self, from: file)
        } else {
            loaded = BundleJSON.load(File.self, "algorithms")
        }
        self.version = loaded?.version ?? "0"
        let entries = loaded?.algorithms ?? []
        self.all = entries.sorted { $0.algorithmId < $1.algorithmId }
        self.byId = Dictionary(entries.map { ($0.algorithmId, $0) }, uniquingKeysWith: { a, _ in a })

        if entries.isEmpty {
            // Same reasoning as `MetricRegistry.minimumHealthyMetricCount` and
            // `SensorQualityMap`'s empty check: `assertionFailure` is a no-op in Release, so a
            // broken `scripts/sync_ios_resources.sh` mirror would otherwise ship an empty registry
            // and every `param(...)` lookup would return nil — an engine falling back to a
            // hardcoded default is exactly the two-drifting-constant-tables outcome this contract
            // exists to prevent.
            Self.logger.fault("AlgorithmRegistry loaded no algorithms — bundled algorithms.json may be missing or corrupted")
        }
    }

    func definition(_ algorithmId: String) -> AlgorithmDefinition? { byId[algorithmId] }

    /// The frozen `AlgorithmVersion` a derived value should be stamped with. Deliberately
    /// optional: an engine asking for an id the contract does not carry is a bug in the engine,
    /// and inventing an `AlgorithmVersion` with empty params here would let it compute a number
    /// from defaults and stamp it with a version that never described those defaults (I2 makes
    /// that row permanent).
    func algorithmVersion(_ algorithmId: String) -> AlgorithmVersion? {
        byId[algorithmId]?.algorithmVersion
    }

    /// One tuning constant. Returns nil rather than a fallback for the same reason as above — a
    /// silent default is indistinguishable, on the stored row, from an authored constant.
    func param(_ algorithmId: String, _ name: String) -> Double? {
        byId[algorithmId]?.params[name]
    }

    /// Algorithms that claim to produce `metricId`. `producesMetricIds: ["*"]` (the baseline
    /// algorithm, which runs over every baseline-eligible metric) matches everything.
    func producers(of metricId: String) -> [AlgorithmDefinition] {
        all.filter { $0.producesMetricIds.contains("*") || $0.producesMetricIds.contains(metricId) }
    }
}

/// One entry in the algorithm contract.
///
/// `params` is `[String: Double]` on purpose and the contract says so: `AlgorithmVersion.params` is
/// numeric-only on both platforms, so a non-numeric constant has nowhere to live and must be
/// expressed numerically (`includeWarmupSets: 0.0`) or moved to a sibling field. Decoding into
/// `Double` is what enforces that claim — a string smuggled into `params` fails the decode here
/// rather than diverging silently from Kotlin's `Map<String, Double>`.
struct AlgorithmDefinition: Decodable, Identifiable, Hashable {
    let algorithmId: String
    let semver: String
    let introducedIn: String
    /// True while the constants are a stated default that has not been validated against data.
    /// Carried through onto `DerivedValue.provisional` by the engines, so the surface can say so.
    let provisional: Bool
    let producesMetricIds: [String]
    let inputMetricIds: [String]
    let methodologyUrl: String
    let summaryEn: String
    let params: [String: Double]
    /// English-only prose about individual constants, for `docs/algorithms/` and review — never
    /// rendered to a user, which is why it has no Arabic counterpart (the same rule
    /// `SensorQualityMap` applies to the contract's `familyNotes`).
    let paramNotes: [String: String]

    var id: String { algorithmId }

    var algorithmVersion: AlgorithmVersion {
        AlgorithmVersion(algorithmId: algorithmId, semver: semver, params: params,
                         introducedIn: introducedIn)
    }

    /// Written out rather than synthesized so the descriptive fields can be absent without taking
    /// the whole contract down (`composite.sleep_efficiency` carries no `paramNotes` because it
    /// has no params to annotate). The identity fields — id, semver, introducedIn, params — stay
    /// required: an entry missing one of those cannot stamp a `DerivedValue`, and accepting it
    /// with a placeholder would produce rows that claim a provenance they do not have (I1).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        algorithmId = try c.decode(String.self, forKey: .algorithmId)
        semver = try c.decode(String.self, forKey: .semver)
        introducedIn = try c.decode(String.self, forKey: .introducedIn)
        params = try c.decode([String: Double].self, forKey: .params)
        // Absent `provisional` reads as provisional, not as validated. An entry that forgot the
        // flag must not be presented to a user as a settled number.
        provisional = try c.decodeIfPresent(Bool.self, forKey: .provisional) ?? true
        producesMetricIds = try c.decodeIfPresent([String].self, forKey: .producesMetricIds) ?? []
        inputMetricIds = try c.decodeIfPresent([String].self, forKey: .inputMetricIds) ?? []
        methodologyUrl = try c.decodeIfPresent(String.self, forKey: .methodologyUrl) ?? ""
        summaryEn = try c.decodeIfPresent(String.self, forKey: .summaryEn) ?? ""
        paramNotes = try c.decodeIfPresent([String: String].self, forKey: .paramNotes) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case algorithmId, semver, introducedIn, provisional
        case producesMetricIds, inputMetricIds, methodologyUrl, summaryEn, params, paramNotes
    }
}
