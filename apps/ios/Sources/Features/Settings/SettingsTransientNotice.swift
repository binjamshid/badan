import SwiftUI

/// A brief, self-dismissing note near the bottom of a settings page — for actions whose effect
/// isn't visible on the page itself (a depth change, a re-enabled sensitive gate, a failed purge).
///
/// Extracted when Settings split into categories: the notice used to be a private helper on the
/// one Settings screen, and three category pages now raise it. Presentational only; the owning
/// screen holds the state and does the announcing (see `Announce`), because *what* to say and
/// *when* it clears are the screen's business, not this view's.
struct SettingsTransientNotice: View {
    @Environment(AppEnvironment.self) private var env
    let notice: LocalizedString

    var body: some View {
        Text(notice, language: env.language)
            .font(BadanFont.bodyCompact)
            .foregroundStyle(BadanColor.textPrimary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, BadanSpace.space4)
            .padding(.vertical, BadanSpace.space3)
            .background(BadanColor.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            .badanElevation()
            .padding(.horizontal, BadanSpace.space4)
            .padding(.bottom, BadanSpace.space4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
    }
}
