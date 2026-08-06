package net.albayyan.badan.core

/**
 * Unit normalization — a faithful port of the iOS `Units`. This is one of the few pieces of
 * deliberately duplicated cross-platform logic (D-4). Every stored `canonicalValue` is in the
 * metric's SI canonical unit; display conversion happens only at the presentation edge.
 * Table-driven: `canonical = value * factor + offset`.
 *
 * This doc used to claim the table was "fixture-guarded so it cannot drift from iOS". No such
 * guard existed, and it had drifted badly: 20 of the registry's 40 units were missing here —
 * every speed, BMI, VO2 max, breathing rate, score, self-report scale and clock unit, plus
 * "percent" (the spelling registry canonicals actually use). `ValueFormatter` catches the
 * resulting `UnknownUnit` throw and falls back to rendering the raw canonical number under the
 * *display* unit's label, so a walking speed of 1.5 m/s was shown to the user as "1.5 km/h" —
 * wrong by a factor of 3.6, with no error anywhere. A claim of a guard is worse than no guard:
 * it is why nobody looked.
 *
 * `UnitsRegistryParityTest` is now that guard, for real — it loads `registry.json` and asserts
 * every unit in it resolves here.
 */
object Units {
    private data class Spec(val base: String, val factor: Double, val offset: Double)

    private val table: Map<String, Spec> = mapOf(
        // duration (base: seconds)
        "s" to Spec("s", 1.0, 0.0),
        "sec" to Spec("s", 1.0, 0.0),
        "min" to Spec("s", 60.0, 0.0),
        "h" to Spec("s", 3600.0, 0.0),
        "hr" to Spec("s", 3600.0, 0.0),
        "ms" to Spec("s", 0.001, 0.0),
        // count
        "count" to Spec("count", 1.0, 0.0),
        "steps" to Spec("count", 1.0, 0.0),
        "floors" to Spec("count", 1.0, 0.0),
        // mass (base: kg)
        "kg" to Spec("kg", 1.0, 0.0),
        "g" to Spec("kg", 0.001, 0.0),
        "mg" to Spec("kg", 0.000001, 0.0),
        "lb" to Spec("kg", 0.45359237, 0.0),
        "st" to Spec("kg", 6.35029318, 0.0),
        "oz" to Spec("kg", 0.028349523125, 0.0),
        // length (base: m)
        "m" to Spec("m", 1.0, 0.0),
        "cm" to Spec("m", 0.01, 0.0),
        "km" to Spec("m", 1000.0, 0.0),
        "mi" to Spec("m", 1609.344, 0.0),
        "ft" to Spec("m", 0.3048, 0.0),
        "in" to Spec("m", 0.0254, 0.0),
        // energy (base: kcal)
        "kcal" to Spec("kcal", 1.0, 0.0),
        "kJ" to Spec("kcal", 0.239005736, 0.0),
        // rate (base: count/min; bpm alias)
        "count/min" to Spec("count/min", 1.0, 0.0),
        "bpm" to Spec("count/min", 1.0, 0.0),
        // ratio (base: fraction 0..1). (DATA-02) registry canonicals spell this "percent" while
        // adapters emit "%" — both must resolve to the same base or every percent-canonical
        // metric throws.
        "fraction" to Spec("fraction", 1.0, 0.0),
        "%" to Spec("fraction", 0.01, 0.0),
        "percent" to Spec("fraction", 0.01, 0.0),
        // temperature (base: celsius)
        "degC" to Spec("degC", 1.0, 0.0),
        "degF" to Spec("degC", 5.0 / 9.0, -32.0 * 5.0 / 9.0),
        // pressure (base: mmHg)
        "mmHg" to Spec("mmHg", 1.0, 0.0),
        "kPa" to Spec("mmHg", 7.50061683, 0.0),
        // volume (base: L)
        "L" to Spec("L", 1.0, 0.0),
        "mL" to Spec("L", 0.001, 0.0),
        "fl_oz" to Spec("L", 0.0295735295625, 0.0),
        // speed (base: m/s) — activity.walking_speed's canonical, displayed as km/h or mph.
        "m/s" to Spec("m/s", 1.0, 0.0),
        "km/h" to Spec("m/s", 1000.0 / 3600.0, 0.0),
        "mph" to Spec("m/s", 0.44704, 0.0),
        // BMI (base: kg/m^2) — identity; body.bmi has one unit.
        "kg/m^2" to Spec("kg/m^2", 1.0, 0.0),
        // cardiorespiratory fitness (base: mL/kg/min) — identity; VO2 max has one unit.
        // (EPIC-01) `ml/kg/min` is the same unit with a lowercase L, which is how HealthKit and
        // most vendor payloads spell it. Aliased for the same reason `%` and `percent` both
        // exist: an unlisted spelling does not throw anywhere visible, it falls through
        // `toCanonical`'s `?: value` and stores an unconverted number tagged ESTIMATE — a silent
        // quality downgrade over a capital letter. Delete this row and VO2 max from any
        // lowercase-spelling source is stamped ESTIMATE while reading correctly on screen.
        "mL/kg/min" to Spec("mL/kg/min", 1.0, 0.0),
        "ml/kg/min" to Spec("mL/kg/min", 1.0, 0.0),
        // breathing rate (base: breaths/min) — deliberately its OWN dimension, not an alias of
        // `count/min`. Sharing a base with `bpm` would let a heart rate convert cleanly into a
        // breathing rate with no ESTIMATE flag to show for it — a mislabelled source would land
        // 60 "breaths per minute" on a chart as a valid-looking reading.
        //
        // (EPIC-01) `brpm` moved here from the `count/min` dimension, where it had sat since the
        // table was written. It is an alias spelling of breaths-per-minute, so filing it under
        // heart rate's base made `convert(v, "brpm", "breaths/min")` throw Incompatible and every
        // brpm-labelled reading was stored unconverted and stamped ESTIMATE. Move it back and
        // that bug returns — latent until something in-tree emits that spelling, then silent.
        // iOS's `Units.swift` carries the identical pairing; the two tables are asserted against
        // one shared golden (`packages/fixtures/canonicalization/canonical-rows-v1.json`).
        "breaths/min" to Spec("breaths/min", 1.0, 0.0),
        "brpm" to Spec("breaths/min", 1.0, 0.0),
        // 0-100 composite scores (base: score_0_100) — sleep.score; "points" is its display
        // spelling, same numeric value.
        "score_0_100" to Spec("score_0_100", 1.0, 0.0),
        "points" to Spec("score_0_100", 1.0, 0.0),
        // self-report ordinal scales (base: ordinal_scale) — mood/energy/perceived_stress
        // (scale_1_5), soreness/symptom severity (scale_0_10), all displayed as "level". These
        // never convert *between* each other (a 1-5 mood value is never rendered as a 0-10 scale
        // or vice versa) — each metric only ever converts its own canonical to its own display
        // unit — so sharing one identity (factor 1) base for all three symbols is safe and avoids
        // `%`-style base collisions, since "level" is reused across differently ranged canonicals.
        "scale_1_5" to Spec("ordinal_scale", 1.0, 0.0),
        "scale_0_10" to Spec("ordinal_scale", 1.0, 0.0),
        "level" to Spec("ordinal_scale", 1.0, 0.0),
        // clock position (base: time_of_day) — sleep.midpoint. clock_24h/clock_12h are display
        // spellings (AM/PM formatting happens at the presentation edge, not here) of the same
        // numeric instant, so factor 1 for all three.
        "time_of_day" to Spec("time_of_day", 1.0, 0.0),
        "clock_24h" to Spec("time_of_day", 1.0, 0.0),
        "clock_12h" to Spec("time_of_day", 1.0, 0.0),
        // dimensionless / already-canonical scores
        "score" to Spec("score", 1.0, 0.0),
        "index" to Spec("index", 1.0, 0.0),
        // blood glucose (base: mmol/L — the registry's canonical, matching the blueprint's own
        // unit table and Arabic/RTL-first readership). mg/dL is the US-conventional display
        // alternative; 18.0182 is the standard clinical mmol/L<->mg/dL conversion factor (a 5.0
        // mmol/L fasting reading is ~90 mg/dL). A21/D-26.
        "mmol/L" to Spec("mmol/L", 1.0, 0.0),
        "mg/dL" to Spec("mmol/L", 1.0 / 18.0182, 0.0),
    )

    sealed class ConversionError(message: String) : Exception(message) {
        class UnknownUnit(val unit: String) : ConversionError("unknown unit: $unit")
        class Incompatible(val from: String, val to: String) : ConversionError("incompatible: $from -> $to")
    }

    /** Convert a value between two units of the same dimension. Throws on unknown/incompatible. */
    fun convert(value: Double, from: String, to: String): Double {
        if (from == to) return value
        val f = table[from] ?: throw ConversionError.UnknownUnit(from)
        val t = table[to] ?: throw ConversionError.UnknownUnit(to)
        if (f.base != t.base) throw ConversionError.Incompatible(from, to)
        val inBase = value * f.factor + f.offset
        return (inBase - t.offset) / t.factor
    }

    /** Convert an as-received value to canonical; unknown/incompatible units pass through. */
    fun toCanonical(value: Double, from: String, canonical: String): Double =
        try { convert(value, from, canonical) } catch (_: ConversionError) { value }
}
