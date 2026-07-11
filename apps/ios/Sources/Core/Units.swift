import Foundation

/// Unit normalization is one of BADAN's few pieces of duplicated cross-platform logic
/// (D-4 duplicated-logic budget). Every stored `canonicalValue` is in the metric's SI
/// canonical unit; display conversion happens only at the presentation edge.
///
/// Conversions are table-driven: each known unit maps to (base unit, factor, offset)
/// where `canonical = value * factor + offset`. Temperature is the only offset case.
public enum Units {
    /// A unit's relationship to its dimension's base (SI) unit.
    struct Spec {
        let base: String     // the canonical/base unit symbol for this dimension
        let factor: Double   // multiply a value in `unit` by this to reach base
        let offset: Double   // then add this (only non-zero for temperature)
    }

    // symbol -> spec. Base units: s (duration), count, kg (mass), m (length),
    // kcal (energy), count/min (rate incl. bpm), fraction (ratio; % is 0.01),
    // celsius (temperature), mmHg (pressure), L (volume).
    static let table: [String: Spec] = [
        // duration (base: seconds)
        "s":      Spec(base: "s", factor: 1, offset: 0),
        "sec":    Spec(base: "s", factor: 1, offset: 0),
        "min":    Spec(base: "s", factor: 60, offset: 0),
        "h":      Spec(base: "s", factor: 3600, offset: 0),
        "hr":     Spec(base: "s", factor: 3600, offset: 0),
        "ms":     Spec(base: "s", factor: 0.001, offset: 0),
        // count (base: count)
        "count":  Spec(base: "count", factor: 1, offset: 0),
        "steps":  Spec(base: "count", factor: 1, offset: 0),
        // mass (base: kg)
        "kg":     Spec(base: "kg", factor: 1, offset: 0),
        "g":      Spec(base: "kg", factor: 0.001, offset: 0),
        "lb":     Spec(base: "kg", factor: 0.45359237, offset: 0),
        "st":     Spec(base: "kg", factor: 6.35029318, offset: 0),
        // length (base: m)
        "m":      Spec(base: "m", factor: 1, offset: 0),
        "cm":     Spec(base: "m", factor: 0.01, offset: 0),
        "km":     Spec(base: "m", factor: 1000, offset: 0),
        "mi":     Spec(base: "m", factor: 1609.344, offset: 0),
        "ft":     Spec(base: "m", factor: 0.3048, offset: 0),
        // energy (base: kcal)
        "kcal":   Spec(base: "kcal", factor: 1, offset: 0),
        "kJ":     Spec(base: "kcal", factor: 0.239005736, offset: 0),
        // rate (base: count/min; bpm is an alias)
        "count/min": Spec(base: "count/min", factor: 1, offset: 0),
        "bpm":       Spec(base: "count/min", factor: 1, offset: 0),
        "brpm":      Spec(base: "count/min", factor: 1, offset: 0),
        // ratio (base: fraction 0..1)
        "fraction": Spec(base: "fraction", factor: 1, offset: 0),
        "%":        Spec(base: "fraction", factor: 0.01, offset: 0),
        // temperature (base: celsius)
        "degC":   Spec(base: "degC", factor: 1, offset: 0),
        "degF":   Spec(base: "degC", factor: 5.0 / 9.0, offset: -32.0 * 5.0 / 9.0),
        // pressure (base: mmHg)
        "mmHg":   Spec(base: "mmHg", factor: 1, offset: 0),
        "kPa":    Spec(base: "mmHg", factor: 7.50061683, offset: 0),
        // volume (base: L)
        "L":      Spec(base: "L", factor: 1, offset: 0),
        "mL":     Spec(base: "L", factor: 0.001, offset: 0),
        // dimensionless / already-canonical scores
        "score":  Spec(base: "score", factor: 1, offset: 0),
        "index":  Spec(base: "index", factor: 1, offset: 0),
    ]

    public enum ConversionError: Error, Equatable {
        case unknownUnit(String)
        case incompatible(from: String, to: String)
    }

    /// Convert a value between two units of the same dimension.
    public static func convert(_ value: Double, from: String, to: String) throws -> Double {
        if from == to { return value }
        guard let f = table[from] else { throw ConversionError.unknownUnit(from) }
        guard let t = table[to] else { throw ConversionError.unknownUnit(to) }
        guard f.base == t.base else { throw ConversionError.incompatible(from: from, to: to) }
        let inBase = value * f.factor + f.offset
        return (inBase - t.offset) / t.factor
    }

    /// Convert an as-received value into the metric's canonical (SI) unit. Non-throwing
    /// helper for ingestion: unknown/incompatible units pass through unchanged and are
    /// flagged upstream, never crash the pipeline.
    public static func toCanonical(_ value: Double, from unit: String, canonical: String) -> Double {
        (try? convert(value, from: unit, to: canonical)) ?? value
    }
}
