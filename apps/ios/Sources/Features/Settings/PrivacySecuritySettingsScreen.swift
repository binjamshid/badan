import SwiftUI
import UserNotifications

/// Settings -> Privacy & security. The sensitive-records gate (turning it off is a real file
/// deletion), the data sources and policy, and "Delete all data".
///
/// Export moved to Backup & restore, and Diagnostics to Support — both were living under
/// "Data & privacy" because there was nowhere else for them.
struct PrivacySecuritySettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPurgeConfirm = false
    @State private var showResetConfirm = false
    @State private var transientNotice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                sensitiveSection
                privacySection
                dataManagementSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.privacy.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice = transientNotice { SettingsTransientNotice(notice: notice) }
        }
        .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: transientNotice)
        // Purge is a real file deletion (the sensitive store is a separate DB) — confirm honestly.
        .confirmationDialog(
            env.s(SettingsStrings.purgeConfirmTitle),
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(SettingsStrings.purgeConfirmAction), role: .destructive) {
                // EDGE-01: `purgeSensitiveNamespace()` now throws on a genuine delete failure
                // instead of silently swallowing it — on that path, keep the toggle on (nothing
                // was actually removed) and say so, rather than claiming success either way.
                do {
                    try env.database.purgeSensitiveNamespace()
                    env.update { $0.sensitiveModulesEnabled = false }
                    // BUG-05: every medication regimen just vanished with the sensitive DB —
                    // cancel/reconcile any reminders still scheduled against them.
                    Task { await env.refreshMedicationReminders() }
                } catch {
                    showTransientNotice(SettingsStrings.purgeFailedNotice)
                }
            }
            Button(env.s(Loc.cancel), role: .cancel) { }
        } message: {
            Text(env.s(SettingsStrings.purgeConfirmMessage))
        }
        .confirmationDialog(
            env.s(SettingsStrings.resetConfirmTitle),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(Loc.deleteAllData), role: .destructive) {
                Task { await env.resetDemoData() }
            }
            Button(env.s(Loc.cancel), role: .cancel) { }
        } message: {
            Text(env.s(SettingsStrings.resetConfirmMessage(connected: env.isHealthKitConnected)))
        }
        // BUG-17: `resetError` used to be set with no UI ever reading it — a failed/partial
        // "Delete all data" looked identical to a successful one.
        .onChange(of: env.resetError == nil) { _, isNil in
            if !isNil { showTransientNotice(SettingsStrings.resetFailedNotice) }
        }
    }

    private func showTransientNotice(_ notice: LocalizedString) {
        transientNotice = notice
        Announce.failure(env.s(notice))
        Task {
            try? await Task.sleep(for: .seconds(3))
            if transientNotice == notice { transientNotice = nil }
        }
    }

    // MARK: Sensitive records (meds & symptoms)

    private var sensitiveSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(SettingsStrings.sensitiveHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SettingsToggleRow(
                        title: Loc.includeSensitive,
                        subtitle: SettingsStrings.sensitiveSubtitle,
                        // Turning ON is immediate; turning OFF routes through a confirm + purge.
                        isOn: Binding(
                            get: { env.profile.sensitiveModulesEnabled },
                            set: { newValue in
                                if newValue {
                                    env.update { $0.sensitiveModulesEnabled = true }
                                    // Re-enabling never restores a prior purge — say so once, plainly.
                                    showTransientNotice(SettingsStrings.sensitiveReenableNotice)
                                } else {
                                    showPurgeConfirm = true
                                }
                            }
                        )
                    )
                    // Only relevant while the toggle is actually on — otherwise it's a warning
                    // about an action that isn't currently available.
                    if env.profile.sensitiveModulesEnabled {
                        HStack(alignment: .top, spacing: BadanSpace.space2) {
                            Image(systemName: "exclamationmark.triangle")
                                .imageScale(.small)
                                .foregroundStyle(BadanColor.outOfBand)
                                .accessibilityHidden(true)
                            LText(SettingsStrings.sensitivePurgeNote)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Data & privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.privacy))
            BadanCard {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "lock.shield")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space2) {
                        LText(Loc.deviceOnly)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(Loc.localFirstNote)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            BadanCard {
                VStack(spacing: 0) {
                    NavigationLink { SourcesScreen() } label: {
                        SettingsNavRowLabel(icon: "antenna.radiowaves.left.and.right",
                                            title: Loc.dataSources)
                    }
                    .buttonStyle(.plain)
                    settingsDivider
                    NavigationLink { ExportCenterScreen() } label: {
                        SettingsNavRowLabel(icon: "square.and.arrow.up",
                                            title: Loc.exportTitle)
                    }
                    .buttonStyle(.plain)
                    settingsDivider
                    // COMP-04: the full policy, rendered in-app and bilingually (no hosted URL —
                    // the app is offline-first). Hosting it and entering that URL in App Store
                    // Connect is a documented owner step before public submission (docs/TESTFLIGHT.md).
                    NavigationLink { PrivacyPolicyScreen() } label: {
                        SettingsNavRowLabel(icon: "lock.doc",
                                            title: SettingsStrings.privacyPolicyTitle)
                    }
                    .buttonStyle(.plain)
                    settingsDivider
                    // (G2) The support surface a local-first app needs: no crash SDK means no
                    // other way to learn anything about a beta user's install.
                    NavigationLink { DiagnosticsScreen() } label: {
                        SettingsNavRowLabel(icon: "stethoscope",
                                            title: SettingsStrings.diagnosticsTitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Data management (reset)

    private var dataManagementSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(SettingsStrings.dataManagementHeader))
            BadanCard {
                Button { showResetConfirm = true } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "trash")
                            .imageScale(.medium)
                            // Warning-toned, not the same neutral tint as a harmless toggle —
                            // this is a destructive, confirm-gated action.
                            .foregroundStyle(BadanColor.outOfBand)
                            .accessibilityHidden(true)
                        LText(Loc.deleteAllData)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
