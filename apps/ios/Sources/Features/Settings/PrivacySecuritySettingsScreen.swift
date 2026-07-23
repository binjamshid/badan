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
    @State private var showingDataChoice = false
    @State private var transientNotice: LocalizedString?

    // STUB-01/COMP-06 (post-onboarding data choice): a second, Settings-side entry point to
    // `DataConnectionChoiceScreen` alongside the tappable `SampleDataBanner` — shown only while
    // sample data is actually active, so a connected real user never sees an irrelevant row.
    private static let manageSampleDataTitle = LocalizedString(
        en: "Manage sample data", ar: "إدارة البيانات التجريبية")

    // EPIC-43: Device Hub's entry point.
    private static let manageDevicesTitle = LocalizedString(en: "Manage devices", ar: "إدارة الأجهزة")

    // EPIC-33 (Phase 3D). Kept local to this screen (like `manageDevicesTitle` above) rather than
    // added to the shared `SettingsStrings` enum in `SettingsScreen.swift` — this lane's owned
    // files are scoped to avoid touching that file while other Phase 3D lanes may be editing
    // Settings screens concurrently.
    private static let widgetsHeader = LocalizedString(en: "Widgets", ar: "الأدوات")
    private static let widgetMedsDueTitle = LocalizedString(
        en: "Medication reminders on widgets", ar: "تذكيرات الأدوية في الأدوات")
    private static let widgetMedsDueSubtitle = LocalizedString(
        en: "Show your medication reminders on your Home Screen widgets. For your privacy, "
            + "medication details never appear on Lock Screen or StandBy widgets.",
        ar: "أظهر تذكيرات أدويتك على أدوات الشاشة الرئيسية. لخصوصيتك، لا تظهر تفاصيل الأدوية "
            + "أبداً على أدوات شاشة القفل أو StandBy.")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                sensitiveSection
                widgetsSection
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
                    // FIX-1 (Phase 3D audit): a purge can delete a medication whose name is
                    // already sitting in the shared widget snapshot (MedsDueWidget) — bypass the
                    // ordinary write debounce, same as the widget-consent-toggle handler below,
                    // and for the same reason: a user who just explicitly asked to erase their
                    // sensitive records should not keep seeing a purged medication name on their
                    // Home Screen for up to 30s (or longer — the debounce only resets on the NEXT
                    // unrelated bump) behind the ordinary derivation-triggered write.
                    let language = env.language
                    let now = env.now()
                    let medsDueConsentGranted = env.profile.consentWidgetMedsDue
                    let writer = env.ambientSnapshotWriter
                    Task.detached(priority: .utility) {
                        _ = await writer.forceWrite(now: now, tz: TimeZone.current.identifier,
                                                    language: language, medsDueConsentGranted: medsDueConsentGranted)
                    }
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

    // MARK: Widgets (EPIC-33 / Phase 3D)

    /// The one new toggle this slice adds: `consent.widget.medsDue`, default OFF (see
    /// `CustomizationProfile.consentWidgetMedsDue`'s doc). A plain persisted toggle — unlike the
    /// sensitive-records switch above, turning this off never deletes anything; it only stops
    /// `AmbientSnapshotWriter` from including medication names in the shared widget snapshot on
    /// its next write.
    private var widgetsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Self.widgetsHeader))
            BadanCard {
                SettingsToggleRow(
                    title: Self.widgetMedsDueTitle,
                    subtitle: Self.widgetMedsDueSubtitle,
                    isOn: Binding(
                        get: { env.profile.consentWidgetMedsDue },
                        set: { newValue in
                            env.update { $0.consentWidgetMedsDue = newValue }
                            // Bypasses the ordinary write debounce: revoking consent should stop a
                            // medication name appearing in the shared widget snapshot promptly,
                            // not linger for up to 30s behind the next derivation-triggered write.
                            let language = env.language
                            let now = env.now()
                            let writer = env.ambientSnapshotWriter
                            Task.detached(priority: .utility) {
                                _ = await writer.forceWrite(now: now, tz: TimeZone.current.identifier,
                                                            language: language, medsDueConsentGranted: newValue)
                            }
                        }
                    )
                )
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
                    // EPIC-43. `SourcesScreen` above stays the casual, read-only projection
                    // ("what's connected") exactly as it is — this is the additional, more
                    // powerful view: per-device health (healthy/needs-attention/disconnected),
                    // sync history, a raw data browser, and the reconciliation ledger ("why am I
                    // seeing this value?"). One new entry point, so it's never a screen with no
                    // real path from a user tap.
                    NavigationLink { DeviceHubScreen() } label: {
                        SettingsNavRowLabel(icon: "point.3.connected.trianglepath.dotted",
                                            title: Self.manageDevicesTitle)
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
                VStack(spacing: 0) {
                    // STUB-01/COMP-06: only shown while sample data is actually active — a
                    // connected real user has nothing here to manage. Mirrors the tappable
                    // `SampleDataBanner` entry point for anyone who dismissed/never saw the
                    // banner but is looking in Settings for a way to act on it.
                    if SeedController.isDemoDataActive {
                        Button { showingDataChoice = true } label: {
                            HStack(spacing: BadanSpace.space3) {
                                Image(systemName: "info.circle")
                                    .imageScale(.medium)
                                    .foregroundStyle(BadanColor.info)
                                    .accessibilityHidden(true)
                                LText(Self.manageSampleDataTitle)
                                    .font(BadanFont.body)
                                    .foregroundStyle(BadanColor.textPrimary)
                                Spacer(minLength: BadanSpace.space2)
                                Image(systemName: "chevron.forward")
                                    .imageScale(.small)
                                    .foregroundStyle(BadanColor.textSecondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: BadanSpace.touchMin)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        settingsDivider
                    }

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
        .sheet(isPresented: $showingDataChoice) {
            NavigationStack {
                DataConnectionChoiceScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(env.s(Loc.close)) { showingDataChoice = false }
                        }
                    }
            }
        }
    }
}
