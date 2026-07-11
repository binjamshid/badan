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
    public static func format(
        _ value: Double,
        language: AppLanguage,
        arabicDigits: Bool,
        fractionDigits: Int = 0
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        formatter.locale = Locale(identifier: language == .ar && arabicDigits ? "ar" : "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func format(
        _ value: Int,
        language: AppLanguage,
        arabicDigits: Bool
    ) -> String {
        format(Double(value), language: language, arabicDigits: arabicDigits, fractionDigits: 0)
    }
}
