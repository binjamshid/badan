import SwiftUI

/// The ONE reusable disclaimer component every pregnancy content surface must render — PREG-03's
/// "mandatory, identically-rendered disclaimer footer" (see `Domain/Pregnancy/PregnancyContentModels
/// .swift`'s own header). A single shared view, not copy-pasted text per screen, so a future content
/// screen literally cannot render pregnancy content without also rendering this — and so a future
/// wording change happens in exactly one place.
struct PregnancyContentDisclaimerFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "info.circle")
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(PregnancyContentDisclaimer.footer, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, BadanSpace.space2)
    }
}
