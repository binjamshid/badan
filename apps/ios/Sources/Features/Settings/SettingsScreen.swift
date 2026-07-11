import SwiftUI
import UserNotifications

// MARK: - Screen

/// The configuration tree. Every control edits the single `CustomizationProfile` through
/// `env.update { ... }`, which persists and — because `AppEnvironment` is `@Observable`
/// re-skins the whole app instantly (language flips RTL, theme flips colour scheme, depth
/// reveals/hides power affordances). Same one model, presented at two altitudes.
///
/// Pushed/tab screen: it relies on a parent `NavigationStack` supplied by the app shell.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showPurgeConfirm = false
    @State private var showResetConfirm = false
    @State private var showUnitsInfo = false
    @State private var showWhatsNew = false
    @State private var showAbout = false
    @State private var searchQuery = ""
    @State private var sortedHomeModules: [HomeModule] = []
    @State private var notificationsDeniedAtSystemLevel = false
    /// A brief, self-dismissing note surfaced after an action whose effect isn't visible on
    /// this screen (e.g. depth changes, re-enabling sensitive records) — see `showTransientNotice`.
    @State private var transientNotice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                if matchesSearch(["appearance", "theme", "dark", "light", "مظهر"]) {
                    appearanceSection
                }
                if matchesSearch(["language", "arabic", "digits", "لغة", "أرقام"]) {
                    languageSection
                }
                if matchesSearch(["depth", "detail", "simple", "balanced", "power", "تفصيل", "مستوى"]) {
                    detailSection
                }
                if env.depth.showsPowerDetail, matchesSearch(["units", "canonical", "display", "وحدات"]) {
                    unitsSection
                }
                if matchesSearch(["modules", "home", "readiness", "sleep", "activity", "heart",
                                   "meds", "nutrition", "timeline", "وحدات الشاشة"]) {
                    modulesSection
                        .padding(.top, BadanSpace.space3)
                }
                if matchesSearch(["notifications", "reminders", "digest", "morning", "إشعارات", "تذكيرات"]) {
                    notificationsSection
                }
                if matchesSearch(["sensitive", "medication", "symptom", "حساسة", "أدوية", "أعراض"]) {
                    sensitiveSection
                        .padding(.top, BadanSpace.space3)
                }
                if matchesSearch(["privacy", "export", "sources", "خصوصية", "تصدير", "مصادر"]) {
                    privacySection
                }
                if matchesSearch(["reset", "demo", "data management", "إعادة تعيين", "إدارة البيانات"]) {
                    dataManagementSection
                }
                if matchesSearch(["about", "version", "what's new", "resources", "حول", "الإصدار", "الموارد"]) {
                    resourcesSection
                }
            }
            .padding(BadanSpace.space4)
        }
        .searchable(text: $searchQuery, prompt: Text(Loc.search, language: env.language))
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.settingsTitle))
        .overlay(alignment: .bottom) {
            if let notice = transientNotice {
                transientNoticeView(notice)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: transientNotice)
        // Purge is a real file deletion (the sensitive store is a separate DB) — confirm honestly.
        .confirmationDialog(
            env.s(SettingsStrings.purgeConfirmTitle),
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(SettingsStrings.purgeConfirmAction), role: .destructive) {
                env.update { $0.sensitiveModulesEnabled = false }
                try? env.database.purgeSensitiveNamespace()
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
            Button(env.s(Loc.resetDemo), role: .destructive) {
                Task { await env.resetDemoData() }
            }
            Button(env.s(Loc.cancel), role: .cancel) { }
        } message: {
            Text(env.s(SettingsStrings.resetConfirmMessage))
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.appearance))
            SettingsRadioGroup(
                options: AppTheme.allCases,
                title: { $0.displayName.resolved(env.language) },
                subtitle: { SettingsStrings.themeSubtitle($0).resolved(env.language) },
                isOn: { $0 == env.profile.theme }
            ) { theme in
                withAnimation(.easeInOut(duration: 0.2)) {
                    env.update { $0.theme = theme }
                }
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.language))
            // Arabic digits only makes sense in the context of the language choice, so it lives
            // as a trailing row in the same card rather than a visually detached second card.
            BadanCard {
                VStack(spacing: 0) {
                    SettingsRadioRows(
                        options: AppLanguage.allCases,
                        title: { $0.displayName },
                        subtitle: { SettingsStrings.languageSubtitle($0).resolved(env.language) },
                        isOn: { $0 == env.language },
                        onSelect: { lang in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                env.update { $0.language = lang }
                            }
                        },
                        trailingDivider: true
                    )
                    SettingsToggleRow(
                        title: Loc.arabicDigits,
                        subtitle: arabicDigitsSubtitle,
                        isOn: binding(\.arabicDigits)
                    )
                }
            }
        }
    }

    /// Notes that the toggle only takes visible effect once Arabic is selected, rather than
    /// reading as broken while the interface language is still English.
    private var arabicDigitsSubtitle: LocalizedString {
        env.language == .en ? SettingsStrings.arabicDigitsHintPrimed : SettingsStrings.arabicDigitsHint
    }

    // MARK: Detail level (depth)

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            // No trailing DepthBadge here — the radio group's own checkmark one row below
            // already communicates the current selection without redundant header chrome.
            SectionHeader(env.s(Loc.depthLevel))
            SettingsRadioGroup(
                options: DepthPolicy.allCases,
                title: { $0.displayName.resolved(env.language) },
                subtitle: { SettingsStrings.depthSubtitle($0).resolved(env.language) },
                isOn: { $0 == env.depth },
                badgeText: { $0 == .balanced ? SettingsStrings.recommendedTag.resolved(env.language) : nil }
            ) { depth in
                withAnimation(.easeInOut(duration: 0.2)) {
                    env.update { $0.depthPolicy = depth }
                }
                // The whole value of this choice is visible on Home/Body/MetricDetail, not here.
                showTransientNotice(SettingsStrings.depthChangeNotice)
            }
        }
    }

    // MARK: Units (power only)

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.units)) {
                Button { showUnitsInfo = true } label: {
                    Image(systemName: "info.circle")
                        .imageScale(.medium)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(env.s(SettingsStrings.unitsInfoAccessibilityLabel))
            }
            SettingsRadioGroup(
                options: [UnitProfileMode.display, UnitProfileMode.canonical],
                title: { SettingsStrings.unitModeTitle($0).resolved(env.language) },
                subtitle: { SettingsStrings.unitModeSubtitle($0).resolved(env.language) },
                isOn: { $0 == env.profile.unitProfile }
            ) { mode in
                env.update { $0.unitProfile = mode }
            }
        }
        .sheet(isPresented: $showUnitsInfo) { UnitsExplainerSheet() }
    }

    // MARK: Home modules

    private var modulesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.modules))
            Text(env.s(SettingsStrings.modulesOrderCaption))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            BadanCard {
                VStack(spacing: 0) {
                    ForEach(Array(sortedHomeModules.enumerated()), id: \.element.id) { index, module in
                        SettingsToggleRow(
                            title: homeModuleLabel(module.id),
                            subtitle: nil,
                            isOn: Binding(
                                get: { env.profile.module(module.id)?.visible ?? module.visible },
                                set: { newValue in setModuleVisible(module.id, newValue) }
                            )
                        )
                        if index < sortedHomeModules.count - 1 { settingsDivider }
                    }
                }
            }
        }
        .onAppear { sortedHomeModules = env.profile.homeModules.sorted { $0.order < $1.order } }
        .onChange(of: env.profile.homeModules) { _, newValue in
            sortedHomeModules = newValue.sorted { $0.order < $1.order }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.notifications))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    VStack(spacing: 0) {
                        SettingsToggleRow(title: SettingsStrings.notifMorning, subtitle: SettingsStrings.notifMorningSubtitle,
                                          isOn: notificationBinding(\.morningNarrative))
                        settingsDivider
                        SettingsToggleRow(title: SettingsStrings.notifWeekly, subtitle: SettingsStrings.notifWeeklySubtitle,
                                          isOn: notificationBinding(\.weeklyDigest))
                        settingsDivider
                        SettingsToggleRow(title: SettingsStrings.notifMeds, subtitle: SettingsStrings.notifMedsSubtitle,
                                          isOn: notificationBinding(\.medicationReminders))
                        settingsDivider
                        SettingsToggleRow(title: SettingsStrings.notifPaused, subtitle: SettingsStrings.notifPausedSubtitle,
                                          isOn: notificationBinding(\.dataPausedAlerts))
                    }
                    // A toggle that's on here but blocked at the OS level would otherwise fail
                    // silently, with no way for the user to tell why from this screen.
                    if notificationsDeniedAtSystemLevel && anyNotificationPreferenceEnabled {
                        HStack(alignment: .top, spacing: BadanSpace.space2) {
                            Image(systemName: "bell.slash")
                                .imageScale(.small)
                                .foregroundStyle(BadanColor.outOfBand)
                                .accessibilityHidden(true)
                            LText(SettingsStrings.systemNotificationsOffNote)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .task { await refreshSystemNotificationAuthorization() }
    }

    private var anyNotificationPreferenceEnabled: Bool {
        let n = env.profile.notifications
        return n.morningNarrative || n.weeklyDigest || n.medicationReminders || n.dataPausedAlerts
    }

    private func refreshSystemNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDeniedAtSystemLevel = settings.authorizationStatus == .denied
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
                        Image(systemName: "arrow.counterclockwise")
                            .imageScale(.medium)
                            // Warning-toned, not the same neutral tint as a harmless toggle —
                            // this is a destructive, confirm-gated action.
                            .foregroundStyle(BadanColor.outOfBand)
                            .accessibilityHidden(true)
                        LText(Loc.resetDemo)
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

    private var settingsDivider: some View {
        Rectangle()
            .fill(BadanColor.separator)
            .frame(height: 1)
            .padding(.vertical, BadanSpace.space1)
    }

    /// Only search when there's a live query — every section is visible by default.
    private func matchesSearch(_ keywords: [String]) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Shows a brief, self-dismissing note near the bottom of the screen — for actions whose
    /// effect isn't visible on Settings itself (see EASE-169, EASE-228).
    private func showTransientNotice(_ notice: LocalizedString) {
        transientNotice = notice
        Task {
            try? await Task.sleep(for: .seconds(3))
            if transientNotice == notice { transientNotice = nil }
        }
    }

    private func transientNoticeView(_ notice: LocalizedString) -> some View {
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
    }

    /// A persisted binding onto a scalar field of the profile.
    private func binding(_ keyPath: WritableKeyPath<CustomizationProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { env.profile[keyPath: keyPath] },
            set: { newValue in env.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// A persisted binding onto a field of the nested notification preferences.
    private func notificationBinding(_ keyPath: WritableKeyPath<NotificationPreference, Bool>) -> Binding<Bool> {
        Binding(
            get: { env.profile.notifications[keyPath: keyPath] },
            set: { newValue in env.update { $0.notifications[keyPath: keyPath] = newValue } }
        )
    }

    private func setModuleVisible(_ id: String, _ visible: Bool) {
        env.update { profile in
            if let index = profile.homeModules.firstIndex(where: { $0.id == id }) {
                profile.homeModules[index].visible = visible
            }
        }
    }

    private func homeModuleLabel(_ id: String) -> LocalizedString {
        switch id {
        case "readiness": return Loc.readiness
        case "sleep": return LocalizedString(en: "Sleep", ar: "النوم")
        case "activity": return LocalizedString(en: "Activity", ar: "النشاط")
        case "heart": return LocalizedString(en: "Heart", ar: "القلب")
        case "meds": return Loc.logMedication
        case "nutrition": return LocalizedString(en: "Nutrition", ar: "التغذية")
        case "timeline": return Loc.timeline
        // A raw, un-translated id would leak English/id text into the Arabic UI; capitalizing
        // both sides keeps the fallback at least presentable in either language.
        default: return LocalizedString(en: id.capitalized, ar: id.capitalized)
        }
    }
}

// MARK: - Reusable single-select rows (no card — for embedding inside a shared card)

/// The bare rows of a mutually-exclusive choice list, without the enclosing `BadanCard` —
/// factored out of `SettingsRadioGroup` so a caller (e.g. `languageSection`) can place a
/// related, non-radio row inside the *same* card as the options themselves.
private struct SettingsRadioRows<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    let subtitle: ((Option) -> String)?
    let isOn: (Option) -> Bool
    var badgeText: ((Option) -> String?)? = nil
    let onSelect: (Option) -> Void
    /// Whether a divider should also render after the last option (the caller has more rows
    /// below it in the same card).
    var trailingDivider: Bool = false

    var body: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            let selected = isOn(option)
            Button { onSelect(option) } label: {
                HStack(spacing: BadanSpace.space3) {
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        HStack(spacing: BadanSpace.space2) {
                            Text(title(option))
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            if let badge = badgeText?(option), !badge.isEmpty {
                                Text(badge)
                                    .font(BadanFont.chip)
                                    .foregroundStyle(BadanColor.primary)
                                    .padding(.horizontal, BadanSpace.space2)
                                    .padding(.vertical, 2)
                                    .background(BadanColor.primary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        if let subtitle, !subtitle(option).isEmpty {
                            Text(subtitle(option))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.medium)
                        .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BadanSpace.touchMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if index < options.count - 1 || trailingDivider {
                Rectangle()
                    .fill(BadanColor.separator)
                    .frame(height: 1)
                    .padding(.vertical, BadanSpace.space1)
            }
        }
    }
}

// MARK: - Reusable single-select group (radio rows in their own card)

/// A calm list of mutually-exclusive choices. Uses a checkmark, never colour alone, and reads
/// correctly in both LTR and RTL because it relies on leading/trailing layout.
private struct SettingsRadioGroup<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    let subtitle: ((Option) -> String)?
    let isOn: (Option) -> Bool
    var badgeText: ((Option) -> String?)? = nil
    let onSelect: (Option) -> Void

    var body: some View {
        BadanCard {
            VStack(spacing: 0) {
                SettingsRadioRows(options: options, title: title, subtitle: subtitle,
                                  isOn: isOn, badgeText: badgeText, onSelect: onSelect)
            }
        }
    }
}

// MARK: - Reusable toggle row

private struct SettingsToggleRow: View {
    @Environment(AppEnvironment.self) private var env
    let title: LocalizedString
    let subtitle: LocalizedString?
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(title, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                if let subtitle {
                    Text(subtitle, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(BadanColor.primary)
        .frame(minHeight: BadanSpace.touchMin)
    }
}

// MARK: - Navigation row label

private struct SettingsNavRowLabel: View {
    @Environment(AppEnvironment.self) private var env
    let icon: String
    let title: LocalizedString

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(title, language: env.language)
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
}

// MARK: - Units explainer sheet

/// A single worked example distinguishing canonical (source-faithful) from display (converted)
/// units — reachable via the info button next to the Units section header.
private struct UnitsExplainerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space3) {
                            LText(SettingsStrings.unitsExplainerIntro)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            LText(SettingsStrings.unitsExplainerExample)
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.units))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - What's new sheet

/// A minimal, locally-bundled release-notes surface (FEAT-226) — a static, bilingual list, no
/// network or new resource file required, consistent with ADR-0002.
private struct WhatsNewSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let version: String
        let notes: LocalizedString
    }

    private let entries: [Entry] = [
        Entry(version: "0.1.0", notes: LocalizedString(
            en: "First release: Today, Body, Log, Insights and Settings, with local-only storage and full export.",
            ar: "الإصدار الأول: الرئيسية، الجسم، التسجيل، الملاحظات والإعدادات، مع تخزين محلي بالكامل وتصدير كامل."))
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    ForEach(entries) { entry in
                        BadanCard {
                            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                                Text(entry.version)
                                    .font(BadanFont.body.weight(.semibold))
                                    .foregroundStyle(BadanColor.textPrimary)
                                Text(entry.notes, language: env.language)
                                    .font(BadanFont.bodyCompact)
                                    .foregroundStyle(BadanColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(SettingsStrings.whatsNewTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - About sheet

/// A simple, always-available diagnostic panel (FEAT-298) — app version and build number only;
/// contract/schema version strings aren't exposed by `MetricRegistry`/`InsightTemplateStore`
/// today, so surfacing those is left for a follow-up that adds that accessor.
private struct AboutSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    BadanCard {
                        VStack(spacing: 0) {
                            aboutRow(label: SettingsStrings.aboutVersion, value: env.appVersion)
                            Rectangle()
                                .fill(BadanColor.separator)
                                .frame(height: 1)
                                .padding(.vertical, BadanSpace.space1)
                            aboutRow(label: SettingsStrings.aboutBuild, value: buildNumber)
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(SettingsStrings.aboutTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }

    private func aboutRow(label: LocalizedString, value: String) -> some View {
        HStack {
            Text(label, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer()
            Text(value)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }
}

// MARK: - Strings (screen-local, always bilingual)

private enum SettingsStrings {
    static let arabicDigitsHint = LocalizedString(
        en: "Show numbers using Arabic-Indic digits.",
        ar: "عرض الأرقام بالصيغة العربية الهندية.")
    static let arabicDigitsHintPrimed = LocalizedString(
        en: "Show numbers using Arabic-Indic digits — applies once Arabic is selected.",
        ar: "عرض الأرقام بالصيغة العربية الهندية — يُطبَّق عند اختيار اللغة العربية.")

    static let sensitiveHeader = LocalizedString(en: "Sensitive records", ar: "السجلات الحساسة")
    static let sensitiveSubtitle = LocalizedString(
        en: "Kept in a separate store on this device.",
        ar: "تُحفظ في مخزن منفصل على هذا الجهاز.")
    static let sensitivePurgeNote = LocalizedString(
        en: "Turning this off removes all medication and symptom records from this device.",
        ar: "إيقاف هذا يزيل جميع سجلات الأدوية والأعراض من هذا الجهاز.")
    static let sensitiveReenableNotice = LocalizedString(
        en: "Sensitive records are back on. Previously removed data is not restored.",
        ar: "عادت السجلات الحساسة إلى العمل. البيانات التي أُزيلت سابقاً لن تعود.")

    static let purgeConfirmTitle = LocalizedString(
        en: "Turn off and remove meds & symptoms?",
        ar: "إيقاف وإزالة الأدوية والأعراض؟")
    static let purgeConfirmMessage = LocalizedString(
        en: "This permanently removes every medication and symptom record from this device.",
        ar: "يزيل هذا نهائياً كل سجلات الأدوية والأعراض من هذا الجهاز.")
    static let purgeConfirmAction = LocalizedString(en: "Turn off & remove", ar: "إيقاف وإزالة")

    static let resetConfirmTitle = LocalizedString(en: "Reset demo data?", ar: "إعادة تعيين بيانات العرض؟")
    static let resetConfirmMessage = LocalizedString(
        en: "This restores the sample data set on this device.",
        ar: "يعيد هذا مجموعة البيانات التجريبية على هذا الجهاز.")

    static let dataManagementHeader = LocalizedString(en: "Data management", ar: "إدارة البيانات")

    static let notifMorning = LocalizedString(en: "Morning summary", ar: "ملخّص الصباح")
    static let notifMorningSubtitle = LocalizedString(
        en: "A calm recap each morning.", ar: "ملخّص هادئ كل صباح.")
    static let notifWeekly = LocalizedString(en: "Weekly digest", ar: "الملخّص الأسبوعي")
    static let notifWeeklySubtitle = LocalizedString(
        en: "A weekly look back at your trends.", ar: "نظرة أسبوعية على اتجاهاتك.")
    static let notifMeds = LocalizedString(en: "Medication reminders", ar: "تذكيرات الأدوية")
    static let notifMedsSubtitle = LocalizedString(
        en: "A nudge when a dose is due.", ar: "تذكير عند حلول موعد الجرعة.")
    static let notifPaused = LocalizedString(en: "Data-paused reminders", ar: "تذكيرات توقّف البيانات")
    static let notifPausedSubtitle = LocalizedString(
        en: "A nudge if a data source goes quiet for a while.", ar: "تذكير إذا توقّف مصدر بياناتك لفترة.")
    static let systemNotificationsOffNote = LocalizedString(
        en: "Notifications are off at the system level. Enable them in iOS Settings to receive these.",
        ar: "الإشعارات متوقفة على مستوى النظام. فعّلها من إعدادات iOS لتصلك هذه التذكيرات.")

    static let recommendedTag = LocalizedString(en: "Recommended", ar: "موصى به")
    static let depthChangeNotice = LocalizedString(
        en: "Applied — you'll see the change on Home and other screens.",
        ar: "تم التطبيق — سترى التغيير في الرئيسية وشاشات أخرى.")

    static let modulesOrderCaption = LocalizedString(
        en: "Shown in Home screen order.", ar: "تظهر بترتيب الشاشة الرئيسية.")

    static let unitsInfoAccessibilityLabel = LocalizedString(en: "About units", ar: "حول الوحدات")
    static let unitsExplainerIntro = LocalizedString(
        en: "Canonical units are exactly what your source recorded — nothing is converted, so provenance "
            + "stays exact. Display units convert everything to the units you prefer to read.",
        ar: "الوحدات الأصلية هي ما سجّله مصدرك تماماً — دون أي تحويل، فيبقى المصدر دقيقاً. أما الوحدات "
            + "المعروضة فتحوّل كل شيء إلى الوحدات التي تفضّل قراءتها.")
    static let unitsExplainerExample = LocalizedString(
        en: "Example: your Apple Health source recorded 6.2 mi. Canonical mode shows 6.2 mi, unchanged. "
            + "Display mode (if you prefer km) shows 10 km instead.",
        ar: "مثال: سجّل مصدر Apple Health مسافة 6.2 ميل. يعرضها الوضع الأصلي 6.2 ميل دون تغيير. أما وضع "
            + "العرض (إن كنت تفضّل الكيلومتر) فيعرض 10 كم بدلاً منها.")

    static let resourcesHeader = LocalizedString(en: "Resources", ar: "الموارد")
    static let whatsNewTitle = LocalizedString(en: "What's new", ar: "ما الجديد")
    static let aboutTitle = LocalizedString(en: "About", ar: "حول التطبيق")
    static let aboutVersion = LocalizedString(en: "Version", ar: "الإصدار")
    static let aboutBuild = LocalizedString(en: "Build", ar: "رقم البناء")

    static func depthSubtitle(_ depth: DepthPolicy) -> LocalizedString {
        switch depth {
        case .casual: return LocalizedString(en: "Calm and minimal.", ar: "هادئ ومبسّط.")
        case .balanced: return LocalizedString(en: "A little more context.", ar: "سياق أكثر قليلاً.")
        case .power: return LocalizedString(en: "Raw values, lineage and tables.",
                                            ar: "القيم الخام والمصدر والجداول.")
        }
    }

    static func themeSubtitle(_ theme: AppTheme) -> LocalizedString {
        switch theme {
        case .system: return LocalizedString(en: "Follows your device's appearance.", ar: "يتبع مظهر جهازك.")
        case .light: return LocalizedString(en: "Always light.", ar: "فاتح دائماً.")
        case .dark: return LocalizedString(en: "Always dark.", ar: "داكن دائماً.")
        }
    }

    static func languageSubtitle(_ lang: AppLanguage) -> LocalizedString {
        switch lang {
        case .en: return LocalizedString(en: "English interface, left to right.",
                                         ar: "واجهة إنجليزية، من اليسار إلى اليمين.")
        case .ar: return LocalizedString(en: "Arabic interface, right to left.",
                                         ar: "واجهة عربية، من اليمين إلى اليسار.")
        }
    }

    static func unitModeTitle(_ mode: UnitProfileMode) -> LocalizedString {
        switch mode {
        case .display: return LocalizedString(en: "My display units", ar: "وحداتي المعروضة")
        case .canonical: return LocalizedString(en: "Original units", ar: "الوحدات الأصلية")
        }
    }

    static func unitModeSubtitle(_ mode: UnitProfileMode) -> LocalizedString {
        switch mode {
        case .display: return LocalizedString(en: "Convert to the units you prefer — e.g. kg becomes lb.",
                                              ar: "تحويل إلى الوحدات التي تفضّلها — مثلاً كغ تصبح رطل.")
        case .canonical: return LocalizedString(en: "Show source units, unchanged — e.g. stays in kg as recorded.",
                                                ar: "عرض وحدات المصدر كما هي — مثلاً تبقى كغ كما سُجّلت.")
        }
    }
}
