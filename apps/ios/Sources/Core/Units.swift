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
    // kcal (energy), count/min (rate incl. bpm), fraction (ratio; % and "percent" are both
    // 0.01 — see (DATA-02) below), celsius (temperature), mmHg (pressure), L (volume),
    // m/s (speed), kg/m^2 (BMI), mL/kg/min (VO2 max), breaths/min, score_0_100,
    // ordinal_scale (self-report scales), time_of_day (clock position).
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
        "floors": Spec(base: "count", factor: 1, offset: 0),
        // mass (base: kg)
        "kg":     Spec(base: "kg", factor: 1, offset: 0),
        "g":      Spec(base: "kg", factor: 0.001, offset: 0),
        "mg":     Spec(base: "kg", factor: 0.000001, offset: 0),
        "lb":     Spec(base: "kg", factor: 0.45359237, offset: 0),
        "st":     Spec(base: "kg", factor: 6.35029318, offset: 0),
        "oz":     Spec(base: "kg", factor: 0.028349523125, offset: 0),
        // length (base: m)
        "m":      Spec(base: "m", factor: 1, offset: 0),
        "cm":     Spec(base: "m", factor: 0.01, offset: 0),
        "km":     Spec(base: "m", factor: 1000, offset: 0),
        "mi":     Spec(base: "m", factor: 1609.344, offset: 0),
        "ft":     Spec(base: "m", factor: 0.3048, offset: 0),
        "in":     Spec(base: "m", factor: 0.0254, offset: 0),
        // energy (base: kcal)
        "kcal":   Spec(base: "kcal", factor: 1, offset: 0),
        "kJ":     Spec(base: "kcal", factor: 0.239005736, offset: 0),
        // rate (base: count/min; bpm is an alias)
        "count/min": Spec(base: "count/min", factor: 1, offset: 0),
        "bpm":       Spec(base: "count/min", factor: 1, offset: 0),
        "brpm":      Spec(base: "count/min", factor: 1, offset: 0),
        // ratio (base: fraction 0..1). (DATA-02) registry canonicals spell this "percent"
        // (SpO2, body fat %, sleep efficiency) while some display/legacy code spells it "%" —
        // both must resolve to the same base or every percent-canonical metric throws
        // .unknownUnit at ingestion and silently falls back tagged `.estimate`.
        "fraction": Spec(base: "fraction", factor: 1, offset: 0),
        "%":        Spec(base: "fraction", factor: 0.01, offset: 0),
        "percent":  Spec(base: "fraction", factor: 0.01, offset: 0),
        // temperature (base: celsius)
        "degC":   Spec(base: "degC", factor: 1, offset: 0),
        "degF":   Spec(base: "degC", factor: 5.0 / 9.0, offset: -32.0 * 5.0 / 9.0),
        // pressure (base: mmHg)
        "mmHg":   Spec(base: "mmHg", factor: 1, offset: 0),
        "kPa":    Spec(base: "mmHg", factor: 7.50061683, offset: 0),
        // volume (base: L)
        "L":      Spec(base: "L", factor: 1, offset: 0),
        "mL":     Spec(base: "L", factor: 0.001, offset: 0),
        "fl_oz":  Spec(base: "L", factor: 0.0295735295625, offset: 0),
        // speed (base: m/s) — activity.walking_speed's canonical, displayed as km/h or mph.
        "m/s":    Spec(base: "m/s", factor: 1, offset: 0),
        "km/h":   Spec(base: "m/s", factor: 1000.0 / 3600.0, offset: 0),
        "mph":    Spec(base: "m/s", factor: 0.44704, offset: 0),
        // body mass index (base: kg/m^2) — identity; no other unit expresses BMI.
        "kg/m^2": Spec(base: "kg/m^2", factor: 1, offset: 0),
        // cardiorespiratory fitness (base: mL/kg/min) — identity; VO2 max has one unit.
        "mL/kg/min": Spec(base: "mL/kg/min", factor: 1, offset: 0),
        // breathing rate (base: breaths/min) — identity; respiratory.rate has one unit.
        "breaths/min": Spec(base: "breaths/min", factor: 1, offset: 0),
        // 0-100 composite scores (base: score_0_100) — sleep.score; "points" is its display
        // spelling, same numeric value.
        "score_0_100": Spec(base: "score_0_100", factor: 1, offset: 0),
        "points":      Spec(base: "score_0_100", factor: 1, offset: 0),
        // self-report ordinal scales (base: ordinal_scale) — mood/energy/perceived_stress
        // (scale_1_5), soreness/symptom severity (scale_0_10), all displayed as "level". These
        // never convert *between* each other (a 1-5 mood value is never rendered as a 0-10
        // scale or vice versa) — each metric only ever converts its own canonical to its own
        // display unit — so sharing one identity (factor 1) base for all three symbols is safe
        // and avoids `%`-style base collisions, since "level" is reused across differently
        // ranged canonicals.
        "scale_1_5":  Spec(base: "ordinal_scale", factor: 1, offset: 0),
        "scale_0_10": Spec(base: "ordinal_scale", factor: 1, offset: 0),
        "level":      Spec(base: "ordinal_scale", factor: 1, offset: 0),
        // clock position (base: time_of_day) — sleep.midpoint. clock_24h/clock_12h are display
        // spellings (AM/PM formatting happens at the presentation edge, not here) of the same
        // numeric instant, so factor 1 for all three.
        "time_of_day": Spec(base: "time_of_day", factor: 1, offset: 0),
        "clock_24h":   Spec(base: "time_of_day", factor: 1, offset: 0),
        "clock_12h":   Spec(base: "time_of_day", factor: 1, offset: 0),
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

    /// Returns the subset of `units` that have no `Units.table` entry. Intended for a
    /// startup/test-time consistency check against the metric registry's `canonicalUnit`/
    /// `primaryDisplayUnit` values, so a registry unit with no table entry (which would
    /// otherwise silently pass through unconverted via `toCanonical`'s `?? value` fallback)
    /// fails loudly instead.
    public static func unknownUnits(in units: some Sequence<String>) -> Set<String> {
        Set(units.filter { table[$0] == nil })
    }
}
