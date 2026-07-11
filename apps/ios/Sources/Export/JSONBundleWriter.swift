import Foundation

/// Serializes a full export as one self-describing JSON bundle. Raw and derived are **physically
/// separated** into distinct top-level arrays (never merged into shared columns), and the manifest
/// travels inside the bundle so the artifact is reproducible from its own description (D-8).
///
/// Encoding is deterministic (`sortedKeys` + `millisecondsSince1970`) so identical data yields
/// identical bytes — the property the manifest checksum relies on.
struct JSONBundleWriter {

    /// User-entered structured logs, kept apart from the measurement chain. Symptoms and
    /// adherence are sensitive-class; workouts and nutrition are normal-class.
    struct Logs: Codable {
        let symptoms: [SymptomEntry]
        let adherence: [AdherenceEvent]
        let workouts: [WorkoutEntry]
        let nutrition: [NutritionEntry]
    }

    /// The bundle envelope. Top-level keys are snake_case to match the export contract; nested
    /// domain objects keep their own natural encoding.
    struct Bundle: Codable {
        let manifest: ExportManifest
        let rawSamples: [RawSample]
        let intervalRecords: [IntervalRecord]
        let sessions: [Session]
        let derivedValues: [DerivedValue]
        let baselines: [Baseline]
        let logs: Logs

        enum CodingKeys: String, CodingKey {
            case manifest
            case rawSamples = "raw_samples"
            case intervalRecords = "interval_records"
            case sessions
            case derivedValues = "derived_values"
            case baselines
            case logs
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    init() {}

    /// Assemble the bundle from its already-scoped parts.
    func makeBundle(
        manifest: ExportManifest,
        rawSamples: [RawSample],
        intervalRecords: [IntervalRecord],
        sessions: [Session],
        derivedValues: [DerivedValue],
        baselines: [Baseline],
        symptoms: [SymptomEntry],
        adherence: [AdherenceEvent],
        workouts: [WorkoutEntry],
        nutrition: [NutritionEntry]
    ) -> Bundle {
        Bundle(
            manifest: manifest,
            rawSamples: rawSamples,
            intervalRecords: intervalRecords,
            sessions: sessions,
            derivedValues: derivedValues,
            baselines: baselines,
            logs: Logs(symptoms: symptoms, adherence: adherence, workouts: workouts, nutrition: nutrition)
        )
    }

    /// Deterministic bytes for the assembled bundle.
    func data(
        manifest: ExportManifest,
        rawSamples: [RawSample],
        intervalRecords: [IntervalRecord],
        sessions: [Session],
        derivedValues: [DerivedValue],
        baselines: [Baseline],
        symptoms: [SymptomEntry],
        adherence: [AdherenceEvent],
        workouts: [WorkoutEntry],
        nutrition: [NutritionEntry]
    ) throws -> Data {
        let bundle = makeBundle(
            manifest: manifest,
            rawSamples: rawSamples,
            intervalRecords: intervalRecords,
            sessions: sessions,
            derivedValues: derivedValues,
            baselines: baselines,
            symptoms: symptoms,
            adherence: adherence,
            workouts: workouts,
            nutrition: nutrition
        )
        return try Self.encoder.encode(bundle)
    }
}
