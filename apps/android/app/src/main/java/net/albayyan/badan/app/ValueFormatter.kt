package net.albayyan.badan.app

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Numerals
import net.albayyan.badan.core.Units
import net.albayyan.badan.domain.CustomizationProfile
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.ontology.MetricRegistry
import kotlin.math.abs

/**
 * Formats a canonical metric value for display: applies the user's unit profile / per-metric
 * unit override, converts from canonical, formats digits in the current language (with the
 * Arabic-digit preference), and special-cases durations. Screens use this so every number in
 * the app reads consistently. Faithful port of the iOS `ValueFormatter`.
 */
class ValueFormatter(
    private val profile: CustomizationProfile,
    private val registry: MetricRegistry,
) {
    private val language: AppLanguage get() = profile.language
    private val arabicDigits: Boolean get() = profile.arabicDigits

    fun displayUnit(def: MetricDefinition): String {
        if (profile.unitProfile == UnitProfileMode.CANONICAL) return def.canonicalUnit
        return profile.unitOverrides[def.metricId] ?: def.primaryDisplayUnit
    }

    /** The hero number as shown (may embed units for durations, e.g. "7h 12m"). */
    fun heroValue(metricId: String, canonicalValue: Double): String {
        val def = registry.definitionOrFallback(metricId)
        if (def.canonicalUnit == "s") return duration(canonicalValue, displayUnit(def))
        val unit = displayUnit(def)
        val converted = runCatching { Units.convert(canonicalValue, def.canonicalUnit, unit) }
            .getOrDefault(canonicalValue)
        return number(converted, fractionDigits(unit, converted))
    }

    /** The unit label to show beside the hero number, or null when the value is self-describing. */
    fun unitLabel(metricId: String): String? {
        val def = registry.definitionOrFallback(metricId)
        if (def.canonicalUnit == "s") return null
        val unit = displayUnit(def)
        return if (unit.isEmpty()) null else localizedUnit(unit)
    }

    /** A compact one-line value+unit, e.g. "56 bpm" or "7h 12m". */
    fun full(metricId: String, canonicalValue: Double): String {
        val hero = heroValue(metricId, canonicalValue)
        val u = unitLabel(metricId)
        return if (u != null) "$hero $u" else hero
    }

    fun number(value: Double, fraction: Int = 0): String =
        Numerals.format(value, language, arabicDigits, fraction)

    fun integer(value: Int): String =
        Numerals.format(value, language, arabicDigits)

    fun duration(seconds: Double, unit: String = "h"): String {
        val total = Math.round(seconds).toInt()
        if (unit == "min") {
            return "${integer(total / 60)}${if (language == AppLanguage.AR) " د" else "m"}"
        }
        val h = total / 3600
        val m = (total % 3600) / 60
        val hLabel = if (language == AppLanguage.AR) "س" else "h"
        val mLabel = if (language == AppLanguage.AR) "د" else "m"
        if (h == 0) return "${integer(m)}$mLabel"
        return "${integer(h)}$hLabel ${integer(m)}$mLabel"
    }

    private fun fractionDigits(unit: String, value: Double): Int = when (unit) {
        "kg", "lb", "km", "mi", "L", "mL/kg/min", "kg/m^2" -> 1
        "%", "percent", "bpm", "ms", "count", "steps", "kcal", "kJ", "m", "mmHg", "breaths/min" -> 0
        else -> if (abs(value) < 10) 1 else 0
    }

    private fun localizedUnit(unit: String): String {
        if (language != AppLanguage.AR) return unit
        return when (unit) {
            "bpm" -> "ن/د"
            "ms" -> "مي.ث"
            "%", "percent" -> "٪"
            "kg" -> "كجم"
            "lb" -> "رطل"
            "km" -> "كم"
            "mi" -> "ميل"
            "steps", "count" -> ""
            "kcal" -> "سعرة"
            "kJ" -> "كيلوجول"
            "breaths/min" -> "نفس/د"
            "mmHg" -> "ملم زئبق"
            else -> unit
        }
    }
}
