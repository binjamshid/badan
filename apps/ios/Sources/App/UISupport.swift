import SwiftUI

/// Small shared glue every screen uses. `LText` resolves a `LocalizedString` against the live
/// app language; `env.s(...)` does the same where a `String` is needed. This is how screens
/// stay bilingual without threading the language everywhere.
extension AppEnvironment {
    /// Resolve a localized string to the current language.
    func s(_ ls: LocalizedString) -> String { ls.resolved(language) }

    /// The shared value formatter bound to the current profile.
    var format: ValueFormatter { ValueFormatter(profile: profile, registry: registry) }

    /// The greeting for the current hour.
    var greeting: LocalizedString {
        let hour = Calendar.current.component(.hour, from: now())
        return Loc.greeting(forHour: hour)
    }
}

/// A `Text` that resolves a `LocalizedString` via the environment's app language.
struct LText: View {
    @Environment(AppEnvironment.self) private var env
    let value: LocalizedString
    init(_ value: LocalizedString) { self.value = value }
    var body: Text { Text(value.resolved(env.language)) }
}

extension Text {
    init(_ ls: LocalizedString, language: AppLanguage) { self.init(ls.resolved(language)) }
}

/// Applies the app's theme (light/dark) and layout direction (RTL for Arabic) plus the base
/// background. The whole app is wrapped in this so a language/theme change re-skins instantly.
extension View {
    func badanChrome(_ env: AppEnvironment) -> some View {
        self
            .environment(\.layoutDirection, env.language.layoutDirection)
            .environment(\.locale, Locale(identifier: env.language.localeIdentifier))
            .badanTheme(env.profile.theme, language: env.language)
            .tint(BadanColor.primary)
    }
}
