import SwiftUI

// MARK: - Copy

private enum WizardCopy {
    static let title = LocalizedString(en: "Set up automation", ar: "إعداد الأتمتة")

    static func stepOf(_ current: String, _ total: String) -> LocalizedString {
        LocalizedString(en: "Step \(current) of \(total)", ar: "الخطوة \(current) من \(total)")
    }

    // Step 1 — template
    static let pickTemplateHeader = LocalizedString(en: "What should run?", ar: "ما الذي سيُشغَّل؟")
    static let pickTemplateIntro = LocalizedString(
        en: "Choose one of your saved export templates. Automation reruns that exact setup — it never widens what a template already exports.",
        ar: "اختر أحد قوالب التصدير المحفوظة لديك. تعيد الأتمتة تشغيل الإعداد نفسه بالضبط — ولا توسّع أبداً ما يصدّره القالب.")
    static let noTemplates = LocalizedString(
        en: "You don't have any saved templates yet. Build an export and save it as a template first, then come back to schedule it.",
        ar: "لا توجد لديك قوالب محفوظة بعد. أنشئ تصديراً واحفظه كقالب أولاً، ثم عُد لجدولته.")
    static let buildTemplate = LocalizedString(en: "Build a template", ar: "أنشئ قالباً")
    static let alreadyScheduled = LocalizedString(en: "Already scheduled", ar: "مجدول بالفعل")

    // Step 2 — how it runs
    static let howHeader = LocalizedString(en: "How should it run?", ar: "كيف سيعمل؟")
    static let howIntro = LocalizedString(
        en: "This is the honest part. Each option below tells you exactly how reliable it is — read it before you choose.",
        ar: "هذا هو الجزء الصريح. يخبرك كل خيار أدناه بمدى موثوقيته بالضبط — اقرأه قبل أن تختار.")
    static let cadenceHeader = LocalizedString(en: "How often", ar: "كم مرة")
    static let quietHeader = LocalizedString(en: "Quiet hours", ar: "ساعات الهدوء")
    static let quietToggle = LocalizedString(en: "Don't run during a window", ar: "لا تُشغّل خلال فترة")
    static let quietHint = LocalizedString(
        en: "The schedule stays quiet between these times — useful overnight. It resumes on its own afterwards.",
        ar: "يبقى الجدول هادئاً بين هذين الوقتين — مفيد أثناء الليل. ويستأنف تلقائياً بعدها.")
    static let quietFrom = LocalizedString(en: "From", ar: "من")
    static let quietTo = LocalizedString(en: "To", ar: "إلى")

    // Step 3 — review
    static let reviewHeader = LocalizedString(en: "Review", ar: "المراجعة")
    static let reviewTemplate = LocalizedString(en: "Template", ar: "القالب")
    static let reviewReliability = LocalizedString(en: "Reliability", ar: "الموثوقية")
    static let reviewWhen = LocalizedString(en: "When", ar: "متى")
    static let reviewQuiet = LocalizedString(en: "Quiet hours", ar: "ساعات الهدوء")
    static let ledgerNote = LocalizedString(
        en: "Every run lands in Export & Automation Health — including the ones that find nothing and the ones that fail. If it isn't there, it didn't run.",
        ar: "يظهر كل تشغيل في حالة التصدير والأتمتة — بما فيها ما لم يجد شيئاً وما أخفق. وإن لم يكن هناك فهو لم يعمل.")

    // Shortcuts explainer (shown for the Shortcuts tier before enabling)
    static let shortcutsUnlockDetail = LocalizedString(
        en: "If your iPhone is locked when the time comes, the automation waits — iOS never tells BADAN the moment passed. No app can work around that. You'll create the time-of-day trigger in the Shortcuts app.",
        ar: "إذا كان آيفونك مقفلاً عند حلول الوقت، ينتظر التشغيل — ولا يُبلَّغ بدن أن الوقت مرّ. لا يمكن لأي تطبيق تجاوز ذلك. ستنشئ مُشغِّل «وقت من اليوم» في تطبيق الاختصارات.")
    static let openShortcuts = LocalizedString(en: "Open Shortcuts", ar: "فتح الاختصارات")
    static let fullGuide = LocalizedString(en: "See the full step-by-step guide", ar: "شاهد الدليل الكامل خطوة بخطوة")
    static let shortcutsMissing = LocalizedString(
        en: "Shortcuts isn't available on this device. You can reinstall it from the App Store.",
        ar: "تطبيق الاختصارات غير متاح على هذا الجهاز. يمكنك إعادة تثبيته من App Store.")

    // Actions
    static let back = LocalizedString(en: "Back", ar: "رجوع")
    static let continueLabel = LocalizedString(en: "Continue", ar: "متابعة")
    static let enable = LocalizedString(en: "Enable automation", ar: "تفعيل الأتمتة")
    static let enabledAnnouncement = LocalizedString(en: "Automation enabled", ar: "تم تفعيل الأتمتة")
}

// MARK: - Screen

/// EPIC-15 — the automation setup wizard. A guided three-step flow that turns an existing export
/// template into an `AutomationSchedule`, and — this is the whole point — makes the reliability tier
/// a *mandatory* step the user reads BEFORE anything is enabled (§16: "the wizard IS the
/// expectation-setting", because users arrive expecting cron and iOS cannot give them cron).
///
/// The three steps are always the same three (choose what → choose how → review & enable) regardless
/// of tier, so the focus order is stable for VoiceOver. Step 2 shows the honest §13.7 label under
/// every tier option; step 3 reaffirms it, and for the Shortcuts tier states the unlock rule and
/// links Shortcuts directly before the Enable button — never a bare wall-clock promise, never "cron",
/// never "guaranteed".
///
/// It creates the schedule row and pops; it does not itself run anything. A background schedule fires
/// from the substrate wake, a Shortcuts one from the App Intent, a manual one from a Run-now tap — so
/// nothing in this screen can make the tier label a lie.
struct AutomationSetupWizardScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var step = 0
    @State private var templates: [ExportTemplate] = []
    @State private var scheduledTemplateIds: Set<String> = []
    @State private var selectedTemplateId: String?

    @State private var tier: AutomationTier = .opportunisticBackground
    @State private var cadence: AutomationCadence = .dailyBestEffort
    @State private var quietEnabled = false
    @State private var quietStart = WizardDefaults.tenPM
    @State private var quietEnd = WizardDefaults.sevenAM
    @State private var shortcutsUnavailable = false

    private static let shortcutsURL = URL(string: "shortcuts://")!
    private static let shortcutsAppStoreURL = URL(string: "https://apps.apple.com/app/shortcuts/id915249334")!
    private static let totalSteps = 3

    private var selectedTemplate: ExportTemplate? {
        templates.first { $0.id == selectedTemplateId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    stepIndicator
                    switch step {
                    case 0: templateStep
                    case 1: howStep
                    default: reviewStep
                    }
                }
                .padding(BadanSpace.space4)
            }
            bottomBar
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(WizardCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .alert(env.s(WizardCopy.shortcutsMissing), isPresented: $shortcutsUnavailable) {
            Button(env.s(Loc.close), role: .cancel) { }
            Button(env.s(WizardCopy.openShortcuts)) { openURL(Self.shortcutsAppStoreURL) }
        }
        .onAppear(perform: reload)
    }

    // MARK: Step indicator

    private var stepIndicator: some View {
        HStack(spacing: BadanSpace.space2) {
            Text(WizardCopy.stepOf(env.format.integer(step + 1), env.format.integer(Self.totalSteps)),
                 language: env.language)
                .font(BadanFont.caption.weight(.semibold))
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            HStack(spacing: BadanSpace.space1) {
                ForEach(0..<Self.totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? BadanColor.primary : BadanColor.separator)
                        .frame(width: i == step ? 20 : 8, height: 6)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: Step 1 — template

    private var templateStep: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(WizardCopy.pickTemplateHeader))
            Text(WizardCopy.pickTemplateIntro, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if templates.isEmpty {
                BadanCard {
                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        Text(WizardCopy.noTemplates, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink { AdvancedExportBuilderScreen() } label: {
                            HStack(spacing: BadanSpace.space2) {
                                Image(systemName: "plus.circle.fill").accessibilityHidden(true)
                                Text(WizardCopy.buildTemplate, language: env.language)
                            }
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                BadanCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                            templateRow(template)
                                .padding(.horizontal, BadanSpace.cardPadding)
                                .padding(.vertical, BadanSpace.space2)
                            if index < templates.count - 1 { rowDivider }
                        }
                    }
                    .padding(.vertical, BadanSpace.space1)
                }
            }
        }
    }

    private func templateRow(_ template: ExportTemplate) -> some View {
        let selected = selectedTemplateId == template.id
        let scheduled = scheduledTemplateIds.contains(template.id)
        return Button { selectedTemplateId = template.id } label: {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: template.format == .csv ? "tablecells" : "curlybraces")
                    .foregroundStyle(BadanColor.primary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    HStack(spacing: BadanSpace.space2) {
                        Text(env.s(ExportRunPresentation.rangeRuleLabel(template.rangeRule, format: env.format)))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        if scheduled {
                            PillLabel(env.s(WizardCopy.alreadyScheduled), systemImage: "clock.arrow.circlepath",
                                      tint: BadanColor.info, filled: false)
                        }
                    }
                }
                Spacer(minLength: BadanSpace.space2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? BadanColor.primary : BadanColor.separator)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Step 2 — how it runs

    private var howStep: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(WizardCopy.howHeader))
                Text(WizardCopy.howIntro, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(AutomationTier.allCases, id: \.self) { t in
                    tierOption(t)
                }
            }
            if tier == .opportunisticBackground {
                cadenceSection
                quietSection
            }
        }
    }

    private func tierOption(_ t: AutomationTier) -> some View {
        let selected = tier == t
        return Button { tier = t } label: {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: AutomationPresentation.tierIcon(t))
                        .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(AutomationPresentation.tierTitle(t), language: env.language)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? BadanColor.primary : BadanColor.separator)
                        .accessibilityHidden(true)
                }
                Text(AutomationPresentation.tierLabel(t), language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? BadanColor.primary.opacity(0.08) : BadanColor.surface,
                        in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(selected ? BadanColor.primary : BadanColor.separator, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cadenceSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(WizardCopy.cadenceHeader))
            BadanCard {
                VStack(spacing: BadanSpace.space3) {
                    ForEach(Array(AutomationCadence.allCases.enumerated()), id: \.element) { index, c in
                        cadenceRow(c)
                        if index < AutomationCadence.allCases.count - 1 { rowDivider }
                    }
                }
            }
        }
    }

    private func cadenceRow(_ c: AutomationCadence) -> some View {
        let selected = cadence == c
        return Button { cadence = c } label: {
            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? BadanColor.primary : BadanColor.separator)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AutomationPresentation.cadenceLabel(c), language: env.language)
                        .font(BadanFont.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(AutomationPresentation.cadenceHint(c), language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BadanSpace.space2)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var quietSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(WizardCopy.quietHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    Toggle(isOn: $quietEnabled) {
                        Text(WizardCopy.quietToggle, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    .tint(BadanColor.primary)
                    if quietEnabled {
                        Text(WizardCopy.quietHint, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: BadanSpace.space3) {
                            quietPicker(WizardCopy.quietFrom, selection: $quietStart)
                            quietPicker(WizardCopy.quietTo, selection: $quietEnd)
                        }
                    }
                }
            }
        }
    }

    private func quietPicker(_ label: LocalizedString, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(label, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel(env.s(label))
        }
    }

    // MARK: Step 3 — review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            SectionHeader(env.s(WizardCopy.reviewHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    reviewLine(WizardCopy.reviewTemplate, value: selectedTemplate?.name ?? "—")
                    rowDivider
                    reviewReliabilityLine
                    rowDivider
                    reviewLine(WizardCopy.reviewWhen,
                               value: env.s(tier == .opportunisticBackground
                                            ? AutomationPresentation.cadenceLabel(cadence)
                                            : AutomationPresentation.nextWindowLabel(
                                                tier == .shortcutDriven ? .inShortcuts : .onTap, dateText: nil)))
                    if tier == .opportunisticBackground && quietEnabled {
                        rowDivider
                        reviewLine(WizardCopy.reviewQuiet, value: quietSummary)
                    }
                }
            }
            if tier == .shortcutDriven { shortcutsExplainer }
            ledgerNote
        }
    }

    private func reviewLine(_ label: LocalizedString, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space3) {
            Text(label, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var reviewReliabilityLine: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            HStack(spacing: BadanSpace.space2) {
                Text(WizardCopy.reviewReliability, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Spacer(minLength: BadanSpace.space2)
                PillLabel(env.s(AutomationPresentation.tierChip(tier)),
                          systemImage: AutomationPresentation.tierIcon(tier), tint: BadanColor.primary)
            }
            Text(AutomationPresentation.tierLabel(tier), language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutsExplainer: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(WizardCopy.shortcutsUnlockDetail, language: env.language)
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    openURL(Self.shortcutsURL) { accepted in
                        if !accepted { shortcutsUnavailable = true }
                    }
                } label: {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "arrow.up.forward.app").accessibilityHidden(true)
                        Text(WizardCopy.openShortcuts, language: env.language)
                    }
                    .font(BadanFont.link)
                    .foregroundStyle(BadanColor.primary)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .strokeBorder(BadanColor.primary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                NavigationLink { ShortcutsSetupGuideScreen() } label: {
                    HStack(spacing: BadanSpace.space2) {
                        Text(WizardCopy.fullGuide, language: env.language)
                        Image(systemName: "chevron.forward").imageScale(.small).accessibilityHidden(true)
                    }
                    .font(BadanFont.link)
                    .foregroundStyle(BadanColor.primary)
                    .frame(minHeight: BadanSpace.touchMin)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ledgerNote: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(WizardCopy.ledgerNote, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BadanSpace.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BadanColor.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: BadanSpace.space3) {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Text(WizardCopy.back, language: env.language)
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 4)
                        .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                            .strokeBorder(BadanColor.separator, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            primaryButton
        }
        .padding(BadanSpace.space4)
        .background(BadanColor.surface.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(BadanColor.separator).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let isFinal = step == Self.totalSteps - 1
        let disabled = step == 0 && selectedTemplate == nil
        Button {
            if isFinal { enable() } else { withAnimation { step += 1 } }
        } label: {
            Text(isFinal ? WizardCopy.enable : WizardCopy.continueLabel, language: env.language)
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.onPrimary)
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 4)
                .background(BadanColor.primary.opacity(disabled ? 0.4 : 1),
                            in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Data

    private func reload() {
        let service = AutomationScheduleService(env: env)
        templates = service.schedulableTemplates()
        scheduledTemplateIds = Set(service.allSchedules().map { $0.templateId })
        // If the pre-selected template vanished (deleted while away), drop the selection.
        if let id = selectedTemplateId, !templates.contains(where: { $0.id == id }) {
            selectedTemplateId = nil
        }
    }

    private func enable() {
        guard let template = selectedTemplate else { return }
        let service = AutomationScheduleService(env: env)
        // Cadence and quiet hours only mean anything for the background tier — the engine never
        // consults them for Shortcuts/manual, which fire from elsewhere. Store an inert `onNewData`
        // for those so the row is well-formed without implying a cadence the tier can't honor.
        let effectiveCadence = tier == .opportunisticBackground ? cadence : .onNewData
        let quiet: QuietHours? = (tier == .opportunisticBackground && quietEnabled) ? quietHoursValue() : nil
        try? service.create(templateId: template.id, tier: tier, cadence: effectiveCadence, quietHours: quiet)
        Announce.status(env.s(WizardCopy.enabledAnnouncement))
        dismiss()
    }

    private func quietHoursValue() -> QuietHours {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: quietStart)
        let e = cal.dateComponents([.hour, .minute], from: quietEnd)
        return QuietHours(startHour: s.hour ?? 22, startMinute: s.minute ?? 0,
                          endHour: e.hour ?? 7, endMinute: e.minute ?? 0)
    }

    private var quietSummary: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: env.language.localeIdentifier)
        f.setLocalizedDateFormatFromTemplate("jm")
        return "\(f.string(from: quietStart)) – \(f.string(from: quietEnd))"
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }
}

/// Default quiet-hours anchors (22:00–07:00), built once. Overnight is the window the toggle is for,
/// so the defaults land there rather than at midnight.
private enum WizardDefaults {
    static let tenPM = time(hour: 22)
    static let sevenAM = time(hour: 7)

    private static func time(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
