import SwiftUI

/// The standard surface for grouped content. One card style everywhere means casual and
/// power are two altitudes over a single container, never two designs.
struct BadanCard<Content: View>: View {
    var padding: CGFloat
    @ViewBuilder var content: () -> Content

    init(padding: CGFloat = BadanSpace.cardPadding, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                    .strokeBorder(BadanColor.separator, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 6)
    }
}

/// A titled section header with an optional trailing action (e.g. "See all", a menu).
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            Text(title)
                .font(BadanFont.sectionTitle)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// Applies the user's theme and language as environment: colour scheme, layout direction
/// and locale. RTL is a first-order concern, so language flips chrome direction here in one
/// place rather than per screen.
struct BadanThemeModifier: ViewModifier {
    var theme: AppTheme
    var language: AppLanguage

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferredColorScheme)
            .environment(\.layoutDirection, language.layoutDirection)
            .environment(\.locale, Locale(identifier: language.localeIdentifier))
    }

    private var preferredColorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension View {
    /// Apply BADAN's theme + language chrome (colour scheme, RTL direction, locale).
    func badanTheme(_ theme: AppTheme, language: AppLanguage) -> some View {
        modifier(BadanThemeModifier(theme: theme, language: language))
    }
}
