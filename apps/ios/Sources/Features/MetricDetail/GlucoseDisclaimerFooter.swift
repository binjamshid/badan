import SwiftUI

/// The ONE reusable disclaimer component every glucose-value surface must render (A21/ADR-0010,
/// D-26) — mirrors `PregnancyContentDisclaimerFooter`'s shape exactly, including its reason: a
/// single shared view, not copy-pasted text per screen, so a future glucose surface literally
/// cannot render a glucose value without also rendering this, and a future wording change happens
/// in exactly one place (`GlucoseDisclaimer.text`).
struct GlucoseDisclaimerFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(GlucoseDisclaimer.text, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, BadanSpace.space2)
    }
}
