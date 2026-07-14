import Foundation

/// Normalizes a user-typed numeric string before handing it to `Double`/`Int`'s own parser.
///
/// Every numeric log field in the app (water, weight, workout minutes/kcal/distance, nutrition
/// macros) previously parsed with a bare `Double(text.replacingOccurrences(of: ",", with: "."))`,
/// which silently rejects anything typed with Eastern-Arabic digits (٠–٩, U+0660–0669),
/// Extended Arabic-Indic digits (۰–۹, U+06F0–06F9), or the Arabic decimal separator ٫
/// (U+066B) — all of which a device set to Arabic can produce from its own number pad
/// (BUG-15). This is the single, pure, testable place that folds all of that to plain ASCII
/// before parsing, so every call site shares identical, verified behavior.
public enum DecimalParsing {
    /// Parses a possibly Arabic-digit / Arabic-separator numeric string as a `Double`. Returns
    /// `nil` for anything that isn't a valid number after normalization (matching `Double.init`'s
    /// own contract) — callers keep their own additional validation (e.g. `value > 0`).
    public static func parse(_ text: String) -> Double? {
        Double(normalize(text))
    }

    /// Same normalization, resolved as an `Int` — for whole-number fields (e.g. workout minutes)
    /// that use `Int.init` directly rather than rounding a parsed `Double`.
    public static func parseInt(_ text: String) -> Int? {
        Int(normalize(text))
    }

    /// Folds Eastern-Arabic and Extended Arabic-Indic digits to ASCII `0`–`9`, maps the Arabic
    /// decimal separator ٫ (U+066B) and a Western comma `,` to `.`, drops the Arabic thousands
    /// separator ٬ (U+066C) entirely, and trims surrounding whitespace. Exposed separately from
    /// `parse`/`parseInt` so tests can assert on the normalized text directly.
    public static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: // Eastern Arabic-Indic digits ٠-٩
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x0660 + 48)!)
            case 0x06F0...0x06F9: // Extended Arabic-Indic digits ۰-۹ (Persian/Urdu variants)
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 48)!)
            case 0x066B: // Arabic decimal separator ٫
                result.append(".")
            case 0x066C: // Arabic thousands separator ٬ — not a value-bearing character
                continue
            case 0x002C: // Western comma ',' — treated as a decimal separator, matching the
                         // pre-fix behavior this replaces (`replacingOccurrences(of: ",", with: ".")`)
                result.append(".")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
