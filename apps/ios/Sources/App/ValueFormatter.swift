import Foundation

/// Formats a canonical metric value for display: applies the user's unit profile / per-metric
/// unit override, converts from canonical, formats digits in the current language (with the
/// Arabic-digit preference), and special-cases durations and clock-like values. Screens use
/// this so every number in the app reads consistently.
struct ValueFormatter {
    let profile: CustomizationProfile
    let registry: MetricRegistry

    private var language: AppLanguage { profile.language }
    private var arabicDigits: Bool { profile.arabicDigits }

    func displayUnit(for def: MetricDefinition) -> String {
        if profile.unitProfile == .canonical { return def.canonicalUnit }
        return profile.unitOverrides[def.metricId] ?? def.primaryDisplayUnit
    }

    /// The hero number as shown (may embed units for durations, e.g. "7h 12m").
    func heroValue(metricId: String, canonicalValue: Double) -> String {
        let def = registry.definitionOrFallback(metricId)
        if def.canonicalUnit == "s" { return duration(seconds: canonicalValue, unit: displayUnit(for: def)) }
        let unit = displayUnit(for: def)
        let converted = (try? Units.convert(canonicalValue, from: def.canonicalUnit, to: unit)) ?? canonicalValue
        return number(converted, fraction: fractionDigits(unit: unit, value: converted))
    }

    /// The unit label to show beside the hero number, or nil when the value is self-describing.
    func unitLabel(metricId: String) -> String? {
        let def = registry.definitionOrFallback(metricId)
        if def.canonicalUnit == "s" { return nil }
        let unit = displayUnit(for: def)
        return unit.isEmpty ? nil : localizedUnit(unit)
    }

    /// A compact one-line value+unit, e.g. "56 bpm" or "7h 12m".
    func full(metricId: String, canonicalValue: Double) -> String {
        let hero = heroValue(metricId: metricId, canonicalValue: canonicalValue)
        if let u = unitLabel(metricId: metricId) { return "\(hero) \(u)" }
        return hero
    }

    func number(_ value: Double, fraction: Int = 0) -> String {
        Numerals.format(value, language: language, arabicDigits: arabicDigits, fractionDigits: fraction)
    }

    func integer(_ value: Int) -> String {
        Numerals.format(value, language: language, arabicDigits: arabicDigits)
    }

    func duration(seconds: Double, unit: String = "h") -> String {
        let total = Int(seconds.rounded())
        if unit == "min" {
            return "\(integer(total / 60))\(language == .ar ? " د" : "m")"
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        let hLabel = language == .ar ? "س" : "h"
        let mLabel = language == .ar ? "د" : "m"
        if h == 0 { return "\(integer(m))\(mLabel)" }
        return "\(integer(h))\(hLabel) \(integer(m))\(mLabel)"
    }

    private func fractionDigits(unit: String, value: Double) -> Int {
        switch unit {
        case "kg", "lb", "km", "mi", "L", "mL/kg/min", "kg/m^2": return 1
        case "%", "percent", "bpm", "ms", "count", "steps", "kcal", "kJ", "m", "mmHg", "breaths/min": return 0
        default: return abs(value) < 10 ? 1 : 0
        }
    }

    private func localizedUnit(_ unit: String) -> String {
        guard language == .ar else { return unit }
        switch unit {
        case "bpm": return "ن/د"
        case "ms": return "مي.ث"
        case "%", "percent": return "٪"
        case "kg": return "كجم"
        case "lb": return "رطل"
        case "km": return "كم"
        case "mi": return "ميل"
        case "steps", "count": return ""
        case "kcal": return "سعرة"
        case "kJ": return "كيلوجول"
        case "breaths/min": return "نفس/د"
        case "mmHg": return "ملم زئبق"
        default: return unit
        }
    }
}
