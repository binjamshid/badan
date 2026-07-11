package net.albayyan.badan.core

/**
 * Unit normalization — a faithful port of the iOS `Units`. This is one of the few pieces of
 * duplicated cross-platform logic (D-4), fixture-guarded so it cannot drift from iOS. Every
 * stored `canonicalValue` is in the metric's SI canonical unit; display conversion happens only
 * at the presentation edge. Table-driven: `canonical = value * factor + offset`.
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
        // mass (base: kg)
        "kg" to Spec("kg", 1.0, 0.0),
        "g" to Spec("kg", 0.001, 0.0),
        "lb" to Spec("kg", 0.45359237, 0.0),
        "st" to Spec("kg", 6.35029318, 0.0),
        // length (base: m)
        "m" to Spec("m", 1.0, 0.0),
        "cm" to Spec("m", 0.01, 0.0),
        "km" to Spec("m", 1000.0, 0.0),
        "mi" to Spec("m", 1609.344, 0.0),
        "ft" to Spec("m", 0.3048, 0.0),
        // energy (base: kcal)
        "kcal" to Spec("kcal", 1.0, 0.0),
        "kJ" to Spec("kcal", 0.239005736, 0.0),
        // rate (base: count/min; bpm alias)
        "count/min" to Spec("count/min", 1.0, 0.0),
        "bpm" to Spec("count/min", 1.0, 0.0),
        "brpm" to Spec("count/min", 1.0, 0.0),
        // ratio (base: fraction 0..1)
        "fraction" to Spec("fraction", 1.0, 0.0),
        "%" to Spec("fraction", 0.01, 0.0),
        // temperature (base: celsius)
        "degC" to Spec("degC", 1.0, 0.0),
        "degF" to Spec("degC", 5.0 / 9.0, -32.0 * 5.0 / 9.0),
        // pressure (base: mmHg)
        "mmHg" to Spec("mmHg", 1.0, 0.0),
        "kPa" to Spec("mmHg", 7.50061683, 0.0),
        // volume (base: L)
        "L" to Spec("L", 1.0, 0.0),
        "mL" to Spec("L", 0.001, 0.0),
        // dimensionless / already-canonical scores
        "score" to Spec("score", 1.0, 0.0),
        "index" to Spec("index", 1.0, 0.0),
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
