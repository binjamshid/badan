import SwiftUI
import UIKit

// MARK: - Copy

/// Builder-specific copy. Shares the `ExportCopy` catalog in `ExportCenterScreen.swift` for the
/// scope/format/range/passphrase strings (kept in one place so the two surfaces read identically)
/// and adds only what is new to the builder: metric selection, the route switch, and templating.
private enum BuilderCopy {
    static let title = LocalizedString(en: "Advanced builder", ar: "المُنشئ المتقدّم")
    static let intro = LocalizedString(
        en: "Build exactly the export you want, then run it or save it as a template to reuse.",
        ar: "أنشئ التصدير الذي تريده بالضبط، ثم شغّله أو احفظه كقالب لإعادة استخدامه.")

    static let metricsSection = LocalizedString(en: "Metrics", ar: "المؤشرات")
    static let allMetrics = LocalizedString(en: "All metrics", ar: "كل المؤشرات")
    static let chooseMetrics = LocalizedString(en: "Choose metrics", ar: "اختيار المؤشرات")
    static func metricsSelected(_ n: String) -> LocalizedString {
        LocalizedString(en: "\(n) selected", ar: "\(n) محددة")
    }

    static let advancedSection = LocalizedString(en: "Advanced options", ar: "خيارات متقدّمة")
    static let advancedHint = LocalizedString(
        en: "Fine-grained control over what goes in. Sane defaults are already set.",
        ar: "تحكّم دقيق بما يُدرَج. الإعدادات الافتراضية المعقولة مضبوطة مسبقاً.")

    // Routes: their own switch with its own copy (§12 EPIC-11), and honest — no writer produces a
    // route export yet (EPIC-12 owns the GPX writer), so the switch states the truth rather than
    // pretending to include something that cannot be produced.
    static let includeRoutes = LocalizedString(en: "Workout routes (GPS)", ar: "مسارات التمارين (GPS)")
    static let routesUnavailable = LocalizedString(
        en: "Route export isn't available yet — it arrives with GPX support. Routes are never part of any export until then.",
        ar: "تصدير المسارات غير متاح بعد — سيأتي مع دعم GPX. لا تكون المسارات جزءاً من أي تصدير حتى ذلك الحين.")

    static let saveSection = LocalizedString(en: "Save as template", ar: "الحفظ كقالب")
    static let saveHint = LocalizedString(
        en: "Name this configuration to run it again later in one tap.",
        ar: "سمِّ هذا الإعداد لتشغيله لاحقاً بنقرة واحدة.")
    static let namePlaceholder = LocalizedString(en: "Template name", ar: "اسم القالب")
    static let nameTaken = LocalizedString(en: "That name is already used.", ar: "هذا الاسم مستخدَم بالفعل.")
    static let save = LocalizedString(en: "Save template", ar: "حفظ القالب")
    static let update = LocalizedString(en: "Update template", ar: "تحديث القالب")
    static let saved = LocalizedString(en: "Template saved", ar: "تم حفظ القالب")
    static let updated = LocalizedString(en: "Template updated", ar: "تم تحديث القالب")
    static let saveFailed = LocalizedString(en: "Couldn't save the template.", ar: "تعذّر حفظ القالب.")

    static let editTitle = LocalizedString(en: "Edit template", ar: "تعديل القالب")
    /// Shown when editing a template whose range rule the builder can't represent as one of its
    /// segments (e.g. `sinceLastRun`). The original rule is kept unless the user changes the range.
    static let rulePreserved = LocalizedString(
        en: "This template's date rule is kept as-is unless you change the range above.",
        ar: "يُحتفَظ بقاعدة تاريخ هذا القالب كما هي ما لم تُغيّر النطاق أعلاه.")
}

// MARK: - Builder

/// EPIC-11 — the power surface: arbitrary scope (metrics, sources, date range, raw/derived/
/// suppressed, sensitive and route opt-ins), run it now, or save it as a reusable template
/// (EPIC-09's create/edit path).
///
/// Over-choice is fought the way §16 asks: the everyday knobs (format, period, what-to-include)
/// are up top, and the finer controls (specific metrics, sources, units, layout) live in a
/// collapsed "Advanced options" section with defaults already sensible. Sensitive records and
/// routes are each their own switch with their own copy — never a blanket "include everything".
///
/// The immediate **Run** produces exactly what `ExportRunner` supports today (the tidy scope you
/// see). Aggregation/wide layout are template-model fields with no run path yet (EPIC-13/15), so
/// this builder deliberately does not offer controls that would imply they change today's output.
struct AdvancedExportBuilderScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// Non-nil when editing an existing user template (EPIC-09). Nil = fresh ad-hoc builder.
    let editing: ExportTemplate?

    init(editing: ExportTemplate? = nil) { self.editing = editing }

    @State private var vm = ExportCenterViewModel()

    @State private var scope = ExportScope()
    @State private var selectedFormats: Set<ExportFormat> = [.csv]
    @State private var range: ExportRange = .last30
    @State private var rangeTouched = false
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var selectedMetricIds: Set<String> = []
    @State private var availableSources: [Source] = []
    @State private var advancedExpanded = false
    @State private var unitNoteExpanded = false

    // Passphrase entry for `includeSensitive` (review ledger #19 / ADR-0008). Never persisted.
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""

    // Save-as-template
    @State private var templateName = ""
    @State private var saveError: Bool = false
    @State private var savedConfirmation: LocalizedString?

    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                introCard
                formatSection
                whatToIncludeSection
                dateRangeSection
                advancedDisclosure
                if !isEditing {
                    trustReminder
                    runButton
                    ForEach(vm.lastResults) { item in
                        ExportSuccessCard(result: item.result, sortedMetricIds: item.sortedMetricIds) {
                            shareURLs = item.result.fileURLs
                            showShare = !item.result.fileURLs.isEmpty
                        } onRunAgain: {
                            handleRunAgain(item.result.job)
                        }
                    }
                    if let error = vm.errorText { errorCard(error) }
                }
                saveTemplateSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(isEditing ? BuilderCopy.editTitle : BuilderCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { seedInitialState() }
        .sheet(isPresented: $showShare) {
            ShareSheet(activityItems: shareURLs) { completed in
                guard completed else { return }
                deleteSharedFolders(shareURLs)
            }
        }
        .onChange(of: range) { _, _ in rangeTouched = true }
        .onChange(of: scope.includeSensitive) { _, includeSensitive in
            guard !includeSensitive else { return }
            passphrase = ""
            passphraseConfirm = ""
        }
    }

    // MARK: Seed

    private func seedInitialState() {
        scope.unitProfile = env.profile.unitProfile
        if let template = editing {
            scope = template.scope
            selectedFormats = [template.format]
            selectedMetricIds = Set(template.scope.metricIds ?? [])
            templateName = template.name
            (range, customStart, customEnd) = Self.range(from: template.rangeRule, scope: template.scope,
                                                         now: env.now())
            advancedExpanded = true
        }
        if availableSources.isEmpty {
            availableSources = ((try? env.catalog.sources()) ?? []).filter { $0.deletedAt == nil }
        }
    }

    // MARK: Intro

    private var introCard: some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(BuilderCopy.intro, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.exportFormat))
            HStack(spacing: BadanSpace.space3) {
                ExportFormatCard(title: "CSV", subtitle: ExportCopy.formatCSVSubtitle, icon: "tablecells",
                                 selected: selectedFormats.contains(.csv)) { toggleFormat(.csv) }
                ExportFormatCard(title: "JSON", subtitle: ExportCopy.formatJSONSubtitle, icon: "curlybraces",
                                 selected: selectedFormats.contains(.json)) { toggleFormat(.json) }
            }
        }
    }

    private func toggleFormat(_ format: ExportFormat) {
        // When editing a template (single format), tapping selects that one format rather than
        // multi-selecting — a template stores exactly one `ExportFormat`.
        if isEditing {
            selectedFormats = [format]
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        if selectedFormats.contains(format) {
            guard selectedFormats.count > 1 else { return }
            selectedFormats.remove(format)
        } else {
            selectedFormats.insert(format)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: What to include

    private var whatToIncludeSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.exportScope))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    scopeToggle(Loc.includeRaw, ExportCopy.includeRawSubtitle,
                                isOn: $scope.includeRaw, icon: "waveform.path.ecg")
                    rowDivider
                    scopeToggle(Loc.includeDerived, ExportCopy.includeDerivedSubtitle,
                                isOn: $scope.includeDerived, icon: "function")
                    rowDivider
                    scopeToggle(Loc.includeSuppressed, ExportCopy.includeSuppressedSubtitle,
                                isOn: $scope.includeSuppressed, icon: "square.on.square.dashed")
                    rowDivider
                    // Sensitive: its own switch, its own copy, its own passphrase (I7 / ADR-0008).
                    scopeToggle(Loc.includeSensitive, ExportCopy.includeSensitiveSubtitle,
                                isOn: $scope.includeSensitive, icon: "cross.case")
                        .disabled(!env.profile.sensitiveModulesEnabled)
                    if !env.profile.sensitiveModulesEnabled {
                        caption(ExportCopy.sensitiveModuleDisabledNote)
                    } else if scope.includeSensitive {
                        sensitiveNote
                        if !isEditing { passphraseFields }
                    }
                    rowDivider
                    // Routes: separate switch, honestly unavailable (EPIC-12).
                    routeToggle
                }
                .animation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion),
                           value: scope.includeSensitive)
            }
        }
    }

    private var routeToggle: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Toggle(isOn: .constant(false)) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "map")
                        .imageScale(.medium)
                        .foregroundStyle(BadanColor.textSecondary)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    Text(BuilderCopy.includeRoutes, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            .tint(BadanColor.primary)
            .disabled(true)
            .frame(minHeight: BadanSpace.touchMin)
            caption(BuilderCopy.routesUnavailable)
        }
    }

    // MARK: Date range

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportCopy.dateRange))
            ExportSegmented(options: ExportRange.allCases.map { (value: $0, label: env.s($0.label(env.format))) },
                            selection: $range)
            if range == .custom {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    DatePicker(env.s(ExportCopy.customRangeStart), selection: $customStart, displayedComponents: .date)
                    DatePicker(env.s(ExportCopy.customRangeEnd), selection: $customEnd, displayedComponents: .date)
                }
                .font(BadanFont.body)
                .tint(BadanColor.primary)
                if customRangeInvalid { caption(ExportCopy.customRangeInvalidNotice, tint: BadanColor.outOfBand) }
            }
            if isEditing, editingRuleUnrepresentable, !rangeTouched {
                caption(BuilderCopy.rulePreserved)
            }
        }
    }

    // MARK: Advanced disclosure

    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion)) {
                    advancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: BadanSpace.space2) {
                    Text(BuilderCopy.advancedSection, language: env.language)
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BadanSpace.touchMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(advancedExpanded ? [.isSelected] : [])

            if advancedExpanded {
                caption(BuilderCopy.advancedHint)
                metricsSection
                if !availableSources.isEmpty { sourceSection }
                unitSection
            }
        }
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(BuilderCopy.metricsSection))
            NavigationLink {
                ExportMetricPickerScreen(selection: $selectedMetricIds)
            } label: {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(BadanColor.primary)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BuilderCopy.chooseMetrics, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(metricsSummary)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
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
        }
    }

    private var metricsSummary: String {
        selectedMetricIds.isEmpty
            ? env.s(BuilderCopy.allMetrics)
            : env.s(BuilderCopy.metricsSelected(env.format.integer(selectedMetricIds.count)))
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(ExportCopy.sources))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    ForEach(availableSources) { source in
                        Button { toggleSource(source) } label: {
                            HStack(spacing: BadanSpace.space3) {
                                Image(systemName: sourceIncluded(source) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(sourceIncluded(source) ? BadanColor.primary : BadanColor.separator)
                                    .accessibilityHidden(true)
                                Text(source.displayName)
                                    .font(BadanFont.body)
                                    .foregroundStyle(BadanColor.textPrimary)
                                Spacer(minLength: BadanSpace.space2)
                            }
                            .frame(minHeight: BadanSpace.touchMin)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(sourceIncluded(source) ? .isSelected : [])
                        if source.id != availableSources.last?.id { rowDivider }
                    }
                }
            }
        }
    }

    private func sourceIncluded(_ source: Source) -> Bool {
        guard let ids = scope.sourceIds else { return true }
        return ids.contains(source.id)
    }

    private func toggleSource(_ source: Source) {
        var current = Set(scope.sourceIds ?? availableSources.map(\.id))
        if current.contains(source.id) { current.remove(source.id) } else { current.insert(source.id) }
        scope.sourceIds = current.count == availableSources.count ? nil : Array(current)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var unitSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(Loc.units))
            ExportSegmented(options: [
                (value: UnitProfileMode.canonical, label: env.s(ExportCopy.unitSource)),
                (value: UnitProfileMode.display, label: env.s(ExportCopy.unitDisplay)),
            ], selection: $scope.unitProfile)
            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                    unitNoteExpanded.toggle()
                }
            } label: {
                HStack(spacing: BadanSpace.space1) {
                    Text(ExportCopy.unitNoteCollapsedLabel, language: env.language)
                        .font(BadanFont.caption.weight(.medium))
                        .foregroundStyle(BadanColor.primary)
                    Image(systemName: unitNoteExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(BadanColor.primary)
                }
            }
            .buttonStyle(.plain)
            if unitNoteExpanded { caption(ExportCopy.unitNote) }
        }
    }

    // MARK: Scope toggle + shared bits

    private func scopeToggle(_ title: LocalizedString, _ subtitle: LocalizedString,
                             isOn: Binding<Bool>, icon: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(BadanColor.primary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
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

    private var sensitiveNote: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(BadanColor.info)
                .accessibilityHidden(true)
            Text(ExportCopy.sensitiveNote, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BadanSpace.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BadanColor.info.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }

    private var passphraseFields: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(ExportCopy.passphraseIntro(env.format), language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            passphraseField(env.s(ExportCopy.passphrasePlaceholder), text: $passphrase)
            passphraseField(env.s(ExportCopy.passphraseConfirmPlaceholder), text: $passphraseConfirm)
            if !passphrase.isEmpty && !ExportPassphrasePolicy.isValid(passphrase) {
                Text(ExportCopy.passphraseTooShort, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.outOfBand)
            } else if !passphraseConfirm.isEmpty
                        && !ExportPassphrasePolicy.matches(passphrase, confirmation: passphraseConfirm) {
                Text(ExportCopy.passphraseMismatch, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.outOfBand)
            }
        }
        .padding(.top, BadanSpace.space1)
    }

    private func passphraseField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .font(BadanFont.body)
            .textContentType(.newPassword)
            .autocorrectionDisabled()
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(BadanColor.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }

    private var passphraseValid: Bool {
        ExportPassphrasePolicy.isValid(passphrase)
            && ExportPassphrasePolicy.matches(passphrase, confirmation: passphraseConfirm)
    }

    // MARK: Run (ad-hoc only)

    private var trustReminder: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(ExportCopy.onDeviceOnly, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    private var runButton: some View {
        Button(action: runExport) {
            HStack(spacing: BadanSpace.space2) {
                if vm.isRunning {
                    ProgressView().tint(BadanColor.onPrimary)
                    Text(ExportCopy.preparing, language: env.language)
                } else {
                    Image(systemName: "square.and.arrow.up").accessibilityHidden(true)
                    Text(Loc.runExport, language: env.language)
                }
            }
            .font(BadanFont.body.weight(.semibold))
            .foregroundStyle(BadanColor.onPrimary)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 6)
            .background(BadanColor.primary,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(vm.isRunning || selectedFormats.isEmpty || customRangeInvalid || sensitiveExportBlocked)
        .opacity(vm.isRunning ? 0.75 : 1)
    }

    private var customRangeInvalid: Bool {
        range == .custom && ExportCenterScreen.isRangeInvalid(start: customStart, end: customEnd)
    }

    private var sensitiveExportBlocked: Bool {
        scope.includeSensitive && !passphraseValid
    }

    private func runExport() {
        guard !customRangeInvalid, !sensitiveExportBlocked else { return }
        var s = resolvedScope()
        s.language = env.language
        vm.run(scope: s, formats: Array(selectedFormats), env: env,
               passphrase: s.includeSensitive ? passphrase : nil)
        passphrase = ""
        passphraseConfirm = ""
    }

    private func handleRunAgain(_ job: ExportJob) {
        guard job.scope.includeSensitive else {
            vm.run(scope: job.scope, formats: [job.format], env: env)
            return
        }
        scope = job.scope
        selectedFormats = [job.format]
        passphrase = ""
        passphraseConfirm = ""
    }

    /// Fold the metric selection + date range into the scope actually run/saved.
    private func resolvedScope() -> ExportScope {
        var s = scope
        s.metricIds = selectedMetricIds.isEmpty ? nil : Array(selectedMetricIds).sorted()
        if range == .custom {
            s.startDate = Calendar.current.startOfDay(for: customStart)
            s.endDate = ExportCenterScreen.endOfDayBound(for: customEnd)
        } else {
            s.startDate = range.startDate(now: env.now())
            s.endDate = nil
        }
        return s
    }

    private func errorCard(_ message: String) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(BadanColor.outOfBand)
                        .accessibilityHidden(true)
                    Text(ExportCopy.couldntPrepare, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(ExportCopy.errorHint, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if env.depth.showsPowerDetail {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Save as template

    private var saveTemplateSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(isEditing ? BuilderCopy.editTitle : BuilderCopy.saveSection))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    if !isEditing { caption(BuilderCopy.saveHint) }
                    TextField(env.s(BuilderCopy.namePlaceholder), text: $templateName)
                        .font(BadanFont.body)
                        .autocorrectionDisabled()
                        .padding(.horizontal, BadanSpace.space3)
                        .frame(minHeight: BadanSpace.touchMin)
                        .background(BadanColor.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    if nameCollision { caption(BuilderCopy.nameTaken, tint: BadanColor.outOfBand) }
                    if saveError { caption(BuilderCopy.saveFailed, tint: BadanColor.outOfBand) }
                    if let savedConfirmation {
                        HStack(spacing: BadanSpace.space2) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(BadanColor.inBand)
                                .accessibilityHidden(true)
                            Text(savedConfirmation, language: env.language)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textPrimary)
                        }
                    }
                    saveButton
                }
            }
        }
    }

    private var saveButton: some View {
        Button(action: saveTemplate) {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "square.and.arrow.down").accessibilityHidden(true)
                Text(isEditing ? BuilderCopy.update : BuilderCopy.save, language: env.language)
            }
            .font(BadanFont.body.weight(.medium))
            .foregroundStyle(BadanColor.primary)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                .strokeBorder(BadanColor.primary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!saveEnabled)
        .opacity(saveEnabled ? 1 : 0.5)
    }

    private var trimmedName: String { templateName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameCollision: Bool {
        guard !trimmedName.isEmpty else { return false }
        return !ExportManageService(env: env).isNameAvailable(trimmedName, excludingId: editing?.id)
    }

    private var saveEnabled: Bool {
        !trimmedName.isEmpty && !nameCollision && !customRangeInvalid
    }

    private func saveTemplate() {
        guard saveEnabled else { return }
        let service = ExportManageService(env: env)
        // Save the scope minus its immediate passphrase; a template stores no secret (§9.3). The
        // sensitive *flag* is preserved — running it later re-confirms and re-collects a passphrase.
        var savedScope = resolvedScope()
        savedScope.language = .en  // templates are language-neutral; the run stamps the live language
        let rule = resolvedRangeRule()
        // For `.fixed`, the window lives on the scope's dates (already set by `resolvedScope`).
        let format = selectedFormats.first ?? .csv

        do {
            if let editing {
                var updated = editing
                updated.name = trimmedName
                updated.scope = savedScope
                updated.rangeRule = rule
                updated.format = format
                try service.updateTemplate(updated)
                savedConfirmation = BuilderCopy.updated
            } else {
                _ = try service.createTemplate(name: trimmedName, scope: savedScope, rangeRule: rule,
                                               format: format)
                savedConfirmation = BuilderCopy.saved
            }
            saveError = false
            Announce.status(env.s(savedConfirmation ?? BuilderCopy.saved))
            // On edit, pop back to the manager so the updated row is visible immediately.
            if isEditing { dismiss() }
        } catch {
            saveError = true
            savedConfirmation = nil
            Announce.failure(env.s(BuilderCopy.saveFailed))
        }
    }

    /// The rule to store. If editing a rule the builder can't represent (e.g. `sinceLastRun`) and
    /// the user didn't touch the range picker, keep the original rule rather than silently
    /// rewriting it.
    private func resolvedRangeRule() -> ExportRangeRule {
        if isEditing, editingRuleUnrepresentable, !rangeTouched, let editing {
            return editing.rangeRule
        }
        switch range {
        case .last30: return .lastNDays(30)
        case .last90: return .lastNDays(90)
        case .all: return .allTime
        case .custom: return .fixed
        }
    }

    private var editingRuleUnrepresentable: Bool {
        guard let rule = editing?.rangeRule else { return false }
        switch rule {
        case .allTime, .fixed: return false
        case .lastNDays(let n): return n != 30 && n != 90
        case .sinceLastRun: return true
        }
    }

    // MARK: Helpers

    private func caption(_ text: LocalizedString, tint: Color = BadanColor.textSecondary) -> some View {
        Text(text, language: env.language)
            .font(BadanFont.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deleteSharedFolders(_ urls: [URL]) {
        let folders = Set(urls.map { $0.deletingLastPathComponent().path })
        for folder in folders { env.exporter.deleteExportedFiles(at: folder) }
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }

    /// Map a stored `ExportRangeRule` + scope back onto the builder's range control when editing.
    static func range(from rule: ExportRangeRule, scope: ExportScope, now: Date)
        -> (ExportRange, start: Date, end: Date) {
        let defaultStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        switch rule {
        case .lastNDays(30): return (.last30, defaultStart, now)
        case .lastNDays(90):
            return (.last90, Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now, now)
        case .lastNDays(let n):
            return (.custom, Calendar.current.date(byAdding: .day, value: -max(1, n), to: now) ?? now, now)
        case .allTime, .sinceLastRun:
            return (.all, defaultStart, now)
        case .fixed:
            return (.custom, scope.startDate ?? defaultStart, scope.endDate ?? now)
        }
    }
}
