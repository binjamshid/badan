import SwiftUI
import UserNotifications

/// Settings -> Personalization. Everything about how BADAN looks and speaks, in one place:
/// appearance, app icon, language + Arabic numerals, detail level, units (power only), and which
/// modules Home shows.
///
/// Moved verbatim out of `SettingsScreen`'s flat scroll — see `SettingsCategory`. The behaviour is
/// unchanged; only where it lives is.
struct PersonalizationSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showUnitsInfo = false
    @State private var sortedHomeModules: [HomeModule] = []
    @State private var iconController = AppIconController()
    @State private var transientNotice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                appearanceSection
                appIconSection
                languageSection
                detailSection
                // Units are a power-only affordance — canonical vs. display is meaningless in casual.
                if env.depth.showsPowerDetail {
                    unitsSection
                }
                modulesSection
                    .padding(.top, BadanSpace.space3)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.personalization.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice = transientNotice { SettingsTransientNotice(notice: notice) }
        }
        .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: transientNotice)
        .sheet(isPresented: $showUnitsInfo) { UnitsExplainerSheet() }
    }

    private func showTransientNotice(_ notice: LocalizedString) {
        transientNotice = notice
        Announce.status(env.s(notice))
        Task {
            try? await Task.sleep(for: .seconds(3))
            if transientNotice == notice { transientNotice = nil }
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
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                    env.update { $0.theme = theme }
                }
            }
        }
    }

    // MARK: App icon

    private var appIconSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.appIcon))
            // EDGE-16: on a device/runtime that can't switch icons at all, say so once here
            // rather than leaving every alternate row a silent, tappable no-op below.
            if !iconController.supportsAlternateIcons {
                Text(env.s(SettingsStrings.iconUnsupportedNotice))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            BadanCard {
                VStack(spacing: 0) {
                    let options = AppIconOption.allCases
                    ForEach(Array(options.enumerated()), id: \.element) { index, option in
                        let selected = option == iconController.current
                        // EDGE-16: the primary icon (`alternateIconName == nil`) is always
                        // selectable — it's the app's own icon, not a switch. Only the
                        // alternates need `supportsAlternateIcons`.
                        let isAlternate = option.alternateIconName != nil
                        // The alternate icons are a Pro feature (D-33's cosmetic tier). The PRIMARY
                        // icon is never gated — it is the app's own icon, not a switch, so a lapsed
                        // subscriber is never stranded on an icon they cannot leave.
                        let needsPro = isAlternate && !env.subscription.allows(.alternateIcons)
                        let disabled = (isAlternate && !iconController.supportsAlternateIcons) || needsPro
                        Button {
                            guard !needsPro else {
                                showTransientNotice(SettingsStrings.iconNeedsProNotice)
                                return
                            }
                            Task {
                                let succeeded = await iconController.select(option)
                                if !succeeded { showTransientNotice(SettingsStrings.iconSwitchFailedNotice) }
                            }
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
                        .disabled(disabled)
                        .opacity(disabled ? 0.45 : 1)
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
                            withAnimation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion)) {
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
                isOn: { $0 == env.depth }
            ) { depth in
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
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

    /// A persisted binding onto a scalar field of the profile.
    private func binding(_ keyPath: WritableKeyPath<CustomizationProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { env.profile[keyPath: keyPath] },
            set: { newValue in env.update { $0[keyPath: keyPath] = newValue } }
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
