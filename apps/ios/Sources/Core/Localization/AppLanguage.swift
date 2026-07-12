import Foundation
import SwiftUI

/// BADAN treats language as a structural, in-app concern (not a bundle-only `.lproj`
/// switch) so Arabic/RTL is demonstrable at runtime and every shipped string carries
/// both languages. This is the mechanism behind VS-5 ("Arabic is not a locale file").
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case en
    case ar

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .en: return "English"
        case .ar: return "العربية"
        }
    }

    public var layoutDirection: LayoutDirection {
        switch self {
        case .en: return .leftToRight
        case .ar: return .rightToLeft
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .en: return "en_US"
        case .ar: return "ar"
        }
    }

    public var isRTL: Bool { layoutDirection == .rightToLeft }

    private static let enLocale = Locale(identifier: "en_US")
    private static let arLocale = Locale(identifier: "ar")

    /// Memoized `Locale` for this language — avoids every call site re-resolving locale
    /// data from `Locale(identifier:)` independently (PERF-013).
    public var locale: Locale {
        switch self {
        case .en: return Self.enLocale
        case .ar: return Self.arLocale
        }
    }
}

/// A string that always carries both languages. Prevents the classic failure where a
/// screen ships English-only and Arabic is retrofitted; a `LocalizedString` cannot be
/// constructed without both values.
public struct LocalizedString: Codable, Hashable, Sendable {
    public let en: String
    public let ar: String

    public init(en: String, ar: String) {
        self.en = en
        self.ar = ar
    }

    public func resolved(_ language: AppLanguage) -> String {
        switch language {
        case .en: return en
        case .ar: return ar
        }
    }
}

public extension LocalizedString {
    /// Interpolate `{name}` placeholders in both languages simultaneously.
    func filling(_ values: [String: String]) -> LocalizedString {
        func apply(_ template: String) -> String {
            var out = template
            for (key, value) in values {
                out = out.replacingOccurrences(of: "{\(key)}", with: value)
            }
            return out
        }
        return LocalizedString(en: apply(en), ar: apply(ar))
    }
}

/// Number formatting that honours the user's language and Arabic-digit preference.
public enum Numerals {
    // The two possible number-formatting locales, precomputed once instead of being
    // re-resolved from `Locale(identifier:)` on every `format` call (PERF-012).
    private static let arDigitsLocale = Locale(identifier: "ar")
    private static let latinDigitsLocale = Locale(identifier: "en_US_POSIX")

    // `NumberFormatter` construction (locale resolution, digit symbol tables) is
    // comparatively expensive; cache one per (language, arabicDigits, fractionDigits)
    // combination instead of allocating fresh on every call (PERF-011). Formatting now
    // runs off the main actor from background screen fetches (PERF-01), so the cache is
    // guarded by a lock to keep concurrent read/write safe.
    private static let cacheLock = NSLock()
    private static var formatterCache: [String: NumberFormatter] = [:]

    private static func cachedFormatter(
        language: AppLanguage,
        arabicDigits: Bool,
        fractionDigits: Int
    ) -> NumberFormatter {
        let key = "\(language.rawValue)-\(arabicDigits)-\(fractionDigits)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = formatterCache[key] { return existing }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        formatter.locale = language == .ar && arabicDigits ? arDigitsLocale : latinDigitsLocale
        formatterCache[key] = formatter
        return formatter
    }

    public static func format(
        _ value: Double,
        language: AppLanguage,
        arabicDigits: Bool,
        fractionDigits: Int = 0
    ) -> String {
        let formatter = cachedFormatter(language: language, arabicDigits: arabicDigits, fractionDigits: fractionDigits)
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func format(
        _ value: Int,
        language: AppLanguage,
        arabicDigits: Bool
    ) -> String {
        format(Double(value), language: language, arabicDigits: arabicDigits, fractionDigits: 0)
    }

    /// Spoken-safe Latin-numeral rendering, independent of the user's `arabicDigits`
    /// display preference. Intended for use as an `accessibilityLabel`/`accessibilityValue`
    /// override wherever Arabic-Indic digit glyphs are shown on screen, so VoiceOver
    /// announces the correct number even if the device's speech language doesn't map
    /// Eastern Arabic-Indic digit glyphs to spoken numbers (FEAT-244). Callers that render
    /// Arabic-Indic digits should pair the visible glyph string with this as the
    /// accessibility label.
    public static func accessibleSpokenForm(_ value: Double, fractionDigits: Int = 0) -> String {
        format(value, language: .en, arabicDigits: false, fractionDigits: fractionDigits)
    }
}
