import SwiftUI

// MARK: - Screen

/// The configuration tree. Every control edits the single `CustomizationProfile` through
/// `env.update { ... }`, which persists and — because `AppEnvironment` is `@Observable` —
/// re-skins the whole app instantly (language flips RTL, theme flips colour scheme, depth
/// reveals/hides power affordances). Same one model, presented at two altitudes.
///
/// Pushed/tab screen: it relies on a parent `NavigationStack` supplied by the app shell.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showPurgeConfirm = false
    @State private var showResetConfirm = false
    @State private var iconController = AppIconController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                appearanceSection
                appIconSection
                languageSection
                detailSection
                if env.depth.showsPowerDetail {
                    unitsSection
                }
                modulesSection
                notificationsSection
                sensitiveSection
                privacySection
                dataManagementSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.settingsTitle))
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
                subtitle: nil,
                isOn: { $0 == env.profile.theme }
            ) { theme in
                withAnimation(.easeInOut(duration: 0.2)) {
                    env.update { $0.theme = theme }
                }
            }
        }
    }

    // MARK: App icon

    private var appIconSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.appIcon))
            BadanCard {
                VStack(spacing: 0) {
                    let options = AppIconOption.allCases
                    ForEach(Array(options.enumerated()), id: \.element) { index, option in
                        let selected = option == iconController.current
                        Button {
                            Task { await iconController.select(option) }
                        } label: {
                            HStack(spacing: BadanSpace.space3) {
                                Image(option.previewAsset)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                                            .strokeBorder(BadanColor.separator, lineWidth: 1)
                                    )
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                                    Text(option.title, language: env.language)
                                        .font(BadanFont.body)
                                        .foregroundStyle(BadanColor.textPrimary)
                                    Text(option.subtitle, language: env.language)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
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

                        if index < options.count - 1 { settingsDivider }
                    }
                }
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.language))
            SettingsRadioGroup(
                options: AppLanguage.allCases,
                title: { $0.displayName },
                subtitle: nil,
                isOn: { $0 == env.language }
            ) { lang in
                withAnimation(.easeInOut(duration: 0.25)) {
                    env.update { $0.language = lang }
                }
            }
            BadanCard {
                SettingsToggleRow(
                    title: Loc.arabicDigits,
                    subtitle: SettingsStrings.arabicDigitsHint,
                    isOn: binding(\.arabicDigits)
                )
            }
        }
    }

    // MARK: Detail level (depth)

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.depthLevel)) {
                DepthBadge(env.depth, language: env.language)
            }
            SettingsRadioGroup(
                options: DepthPolicy.allCases,
                title: { $0.displayName.resolved(env.language) },
                subtitle: { SettingsStrings.depthSubtitle($0).resolved(env.language) },
                isOn: { $0 == env.depth }
            ) { depth in
                withAnimation(.easeInOut(duration: 0.2)) {
                    env.update { $0.depthPolicy = depth }
                }
            }
        }
    }

    // MARK: Units (power only)

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.units))
            SettingsRadioGroup(
                options: [UnitProfileMode.display, UnitProfileMode.canonical],
                title: { SettingsStrings.unitModeTitle($0).resolved(env.language) },
                subtitle: { SettingsStrings.unitModeSubtitle($0).resolved(env.language) },
                isOn: { $0 == env.profile.unitProfile }
            ) { mode in
                env.update { $0.unitProfile = mode }
            }
        }
    }

    // MARK: Home modules

    private var modulesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.modules))
            BadanCard {
                VStack(spacing: 0) {
                    let modules = env.profile.homeModules.sorted { $0.order < $1.order }
                    ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                        SettingsToggleRow(
                            title: homeModuleLabel(module.id),
                            subtitle: nil,
                            isOn: Binding(
                                get: { env.profile.module(module.id)?.visible ?? module.visible },
                                set: { newValue in setModuleVisible(module.id, newValue) }
                            )
                        )
                        if index < modules.count - 1 { settingsDivider }
                    }
                }
            }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.notifications))
            BadanCard {
                VStack(spacing: 0) {
                    SettingsToggleRow(title: SettingsStrings.notifMorning, subtitle: nil,
                                      isOn: notificationBinding(\.morningNarrative))
                    settingsDivider
                    SettingsToggleRow(title: SettingsStrings.notifWeekly, subtitle: nil,
                                      isOn: notificationBinding(\.weeklyDigest))
                    settingsDivider
                    SettingsToggleRow(title: SettingsStrings.notifMeds, subtitle: nil,
                                      isOn: notificationBinding(\.medicationReminders))
                    settingsDivider
                    SettingsToggleRow(title: SettingsStrings.notifPaused, subtitle: nil,
                                      isOn: notificationBinding(\.dataPausedAlerts))
                }
            }
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
                                if newValue { env.update { $0.sensitiveModulesEnabled = true } }
                                else { showPurgeConfirm = true }
                            }
                        )
                    )
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
        BadanCard {
            Button { showResetConfirm = true } label: {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "arrow.counterclockwise")
                        .imageScale(.medium)
                        .foregroundStyle(BadanColor.info)
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

    // MARK: - Local helpers

    private var settingsDivider: some View {
        Rectangle()
            .fill(BadanColor.separator)
            .frame(height: 1)
            .padding(.vertical, BadanSpace.space1)
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
        default: return LocalizedString(en: id.capitalized, ar: id)
        }
    }
}

// MARK: - Reusable single-select group (radio rows)

/// A calm list of mutually-exclusive choices. Uses a checkmark, never colour alone, and reads
/// correctly in both LTR and RTL because it relies on leading/trailing layout.
private struct SettingsRadioGroup<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    let subtitle: ((Option) -> String)?
    let isOn: (Option) -> Bool
    let onSelect: (Option) -> Void

    var body: some View {
        BadanCard {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let selected = isOn(option)
                    Button { onSelect(option) } label: {
                        HStack(spacing: BadanSpace.space3) {
                            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                                Text(title(option))
                                    .font(BadanFont.body)
                                    .foregroundStyle(BadanColor.textPrimary)
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

                    if index < options.count - 1 {
                        Rectangle()
                            .fill(BadanColor.separator)
                            .frame(height: 1)
                            .padding(.vertical, BadanSpace.space1)
                    }
                }
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

// MARK: - Strings (screen-local, always bilingual)

private enum SettingsStrings {
    static let arabicDigitsHint = LocalizedString(
        en: "Show numbers using Arabic-Indic digits.",
        ar: "عرض الأرقام بالصيغة العربية الهندية.")

    static let sensitiveHeader = LocalizedString(en: "Sensitive records", ar: "السجلات الحساسة")
    static let sensitiveSubtitle = LocalizedString(
        en: "Kept in a separate store on this device.",
        ar: "تُحفظ في مخزن منفصل على هذا الجهاز.")
    static let sensitivePurgeNote = LocalizedString(
        en: "Turning this off removes all medication and symptom records from this device.",
        ar: "إيقاف هذا يزيل جميع سجلات الأدوية والأعراض من هذا الجهاز.")

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

    static let notifMorning = LocalizedString(en: "Morning summary", ar: "ملخّص الصباح")
    static let notifWeekly = LocalizedString(en: "Weekly digest", ar: "الملخّص الأسبوعي")
    static let notifMeds = LocalizedString(en: "Medication reminders", ar: "تذكيرات الأدوية")
    static let notifPaused = LocalizedString(en: "Data-paused reminders", ar: "تذكيرات توقّف البيانات")

    static func depthSubtitle(_ depth: DepthPolicy) -> LocalizedString {
        switch depth {
        case .casual: return LocalizedString(en: "Calm and minimal.", ar: "هادئ ومبسّط.")
        case .balanced: return LocalizedString(en: "A little more context.", ar: "سياق أكثر قليلاً.")
        case .power: return LocalizedString(en: "Raw values, lineage and tables.",
                                            ar: "القيم الخام والمصدر والجداول.")
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
        case .display: return LocalizedString(en: "Convert to the units you prefer.",
                                              ar: "تحويل إلى الوحدات التي تفضّلها.")
        case .canonical: return LocalizedString(en: "Show source units, unchanged.",
                                                ar: "عرض وحدات المصدر كما هي دون تغيير.")
        }
    }
}
