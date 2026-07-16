import SwiftUI
import UserNotifications

/// Settings -> Support. Diagnostics (the support surface a local-first app needs — no crash SDK
/// means this is the only way to learn anything about an install), plus what's new and about.
struct SupportSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showWhatsNew = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                diagnosticsSection
                resourcesSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.support.title))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
        .sheet(isPresented: $showAbout) { AboutSheet() }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(SettingsStrings.diagnosticsTitle))
            BadanCard {
                NavigationLink { DiagnosticsScreen() } label: {
                    SettingsNavRowLabel(icon: "stethoscope", title: SettingsStrings.diagnosticsTitle)
                }
                .buttonStyle(.plain)
            }
            LText(SettingsStrings.diagnosticsBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Resources (what's new / about)

    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(SettingsStrings.resourcesHeader))
            BadanCard {
                VStack(spacing: 0) {
                    Button { showWhatsNew = true } label: {
                        SettingsNavRowLabel(icon: "sparkles", title: SettingsStrings.whatsNewTitle)
                    }
                    .buttonStyle(.plain)
                    settingsDivider
                    Button { showAbout = true } label: {
                        SettingsNavRowLabel(icon: "info.circle", title: SettingsStrings.aboutTitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
        .sheet(isPresented: $showAbout) { AboutSheet() }
    }

    // MARK: - Local helpers


    /// Only search when there's a live query — every section is visible by default.
}
