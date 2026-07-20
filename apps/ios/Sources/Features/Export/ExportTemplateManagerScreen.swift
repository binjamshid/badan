import SwiftUI

// MARK: - Copy

private enum TemplateManagerCopy {
    static let title = LocalizedString(en: "Templates", ar: "القوالب")
    static let intro = LocalizedString(
        en: "Save an export setup once, run it whenever you like.",
        ar: "احفظ إعداد تصدير مرة، وشغّله متى شئت.")
    /// Trust copy (§16) — and true in behavior, not just words: a template stores a fixed
    /// `ExportScope`. Nothing re-derives it, and a metric that later becomes sensitive still can't
    /// ride along, because the runner gates the whole sensitive namespace on `includeSensitive`,
    /// which is off unless this template explicitly opted in (and even then re-confirms per run).
    static let neverAutoSensitive = LocalizedString(
        en: "Templates never auto-include newly-sensitive data types. A saved setup only exports what it already names.",
        ar: "لا تُدرِج القوالب تلقائياً أنواع البيانات التي تصبح حسّاسة لاحقاً. الإعداد المحفوظ يصدّر فقط ما يسمّيه بالفعل.")
    static let newTemplate = LocalizedString(en: "New template", ar: "قالب جديد")
    static let presetsSection = LocalizedString(en: "Quick Export presets", ar: "قوالب التصدير السريع")
    static let yourTemplates = LocalizedString(en: "Your templates", ar: "قوالبك")
    static let readOnly = LocalizedString(en: "Read-only", ar: "للقراءة فقط")
    static let run = LocalizedString(en: "Run", ar: "تشغيل")
    static let noUserTemplates = LocalizedString(
        en: "No saved templates yet. Build an export and save it as a template to see it here.",
        ar: "لا قوالب محفوظة بعد. أنشئ تصديراً واحفظه كقالب لتراه هنا.")
    static let templateDeleted = LocalizedString(en: "Template deleted", ar: "تم حذف القالب")
    static let lastRun = LocalizedString(en: "Last run", ar: "آخر تشغيل")
    static let neverRun = LocalizedString(en: "Not run yet", ar: "لم يُشغّل بعد")

    static func runAccessibility(_ name: String) -> LocalizedString {
        LocalizedString(en: "Run template \(name)", ar: "تشغيل القالب \(name)")
    }
}

// MARK: - Screen

/// EPIC-09 — the saved-configuration library. Presets are read-only (you can run them, not edit or
/// delete them — that rule is enforced in the repository, not just by a disabled button). The
/// user's own templates get full CRUD: run, tap to edit in the builder, swipe (or VoiceOver
/// action) to delete with an undo window.
struct ExportTemplateManagerScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var presets: [ExportTemplate] = []
    @State private var userTemplates: [ExportTemplate] = []
    @State private var runModel = TemplateRunModel()
    @State private var lastRuns: [String: ExportRun] = [:]

    // Pending-delete/undo window (the `BadanUndoToast` caller owns the timing — ledger #34).
    @State private var pendingDelete: ExportTemplate?
    @State private var deleteTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    introCard
                    newTemplateButton
                    presetsSection
                    userTemplatesSection
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background.ignoresSafeArea())
            if let pendingDelete {
                BadanUndoToast(message: env.s(TemplateManagerCopy.templateDeleted),
                               undoLabel: env.s(Loc.undo)) {
                    undoDelete(pendingDelete)
                }
            }
        }
        .navigationTitle(env.s(TemplateManagerCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .templateRun(runModel, env: env)
        .onAppear {
            runModel.onFinished = { reload() }
            reload()
        }
    }

    // MARK: Sections

    private var introCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(TemplateManagerCopy.intro, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: BadanSpace.space2) {
                    Image(systemName: "checkmark.shield")
                        .imageScale(.small)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(TemplateManagerCopy.neverAutoSensitive, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var newTemplateButton: some View {
        NavigationLink { AdvancedExportBuilderScreen() } label: {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "plus.circle.fill").accessibilityHidden(true)
                Text(TemplateManagerCopy.newTemplate, language: env.language)
            }
            .font(BadanFont.body.weight(.semibold))
            .foregroundStyle(BadanColor.onPrimary)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 4)
            .background(BadanColor.primary,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var presetsSection: some View {
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(TemplateManagerCopy.presetsSection))
                BadanCard {
                    VStack(spacing: BadanSpace.space3) {
                        ForEach(Array(presets.enumerated()), id: \.element.id) { index, template in
                            presetRow(template)
                            if index < presets.count - 1 { rowDivider }
                        }
                    }
                }
            }
        }
    }

    private var userTemplatesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(TemplateManagerCopy.yourTemplates))
            if userTemplates.isEmpty {
                BadanCard {
                    Text(TemplateManagerCopy.noUserTemplates, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                BadanCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(userTemplates.enumerated()), id: \.element.id) { index, template in
                            BadanSwipeToDelete(deleteLabel: env.s(Loc.delete)) {
                                beginDelete(template)
                            } content: {
                                userRow(template)
                                    .padding(.horizontal, BadanSpace.cardPadding)
                            }
                            if index < userTemplates.count - 1 { rowDivider }
                        }
                    }
                    .padding(.vertical, BadanSpace.space1)
                }
            }
        }
    }

    // MARK: Rows

    private func presetRow(_ template: ExportTemplate) -> some View {
        HStack(spacing: BadanSpace.space3) {
            templateIcon(template)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BadanSpace.space2) {
                    Text(displayName(template))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    PillLabel(env.s(TemplateManagerCopy.readOnly), systemImage: "lock", filled: false)
                }
                Text(summary(template))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                lastRunLine(template)
            }
            Spacer(minLength: BadanSpace.space2)
            runButton(template)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private func userRow(_ template: ExportTemplate) -> some View {
        HStack(spacing: BadanSpace.space3) {
            NavigationLink { AdvancedExportBuilderScreen(editing: template) } label: {
                HStack(spacing: BadanSpace.space3) {
                    templateIcon(template)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(template))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(summary(template))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        lastRunLine(template)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: "chevron.forward")
                        .imageScale(.small)
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(env.s(Loc.edit))
            runButton(template)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private func templateIcon(_ template: ExportTemplate) -> some View {
        Image(systemName: template.format == .csv ? "tablecells" : "curlybraces")
            .foregroundStyle(BadanColor.primary)
            .frame(width: 26)
            .accessibilityHidden(true)
    }

    private func runButton(_ template: ExportTemplate) -> some View {
        Button { runModel.run(template, env: env) } label: {
            Group {
                if runModel.runningTemplateId == template.id {
                    ProgressView().tint(BadanColor.primary)
                } else {
                    HStack(spacing: BadanSpace.space1) {
                        Image(systemName: "square.and.arrow.up").imageScale(.small).accessibilityHidden(true)
                        Text(TemplateManagerCopy.run, language: env.language)
                            .font(BadanFont.chip.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(BadanColor.primary)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                .strokeBorder(BadanColor.primary.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(runModel.isRunning)
        .accessibilityLabel(env.s(TemplateManagerCopy.runAccessibility(displayName(template))))
    }

    @ViewBuilder
    private func lastRunLine(_ template: ExportTemplate) -> some View {
        HStack(spacing: BadanSpace.space1) {
            if let run = lastRuns[template.id] {
                Image(systemName: ExportRunPresentation.icon(run.outcome))
                    .imageScale(.small)
                    .foregroundStyle(ExportRunPresentation.tone(run.outcome).tint)
                    .accessibilityHidden(true)
                Text("\(env.s(TemplateManagerCopy.lastRun)): \(env.s(ExportRunPresentation.label(run.outcome)))")
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                Text(TemplateManagerCopy.neverRun, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }

    // MARK: Data

    private func reload() {
        let service = ExportManageService(env: env)
        service.ensureSeeded()
        presets = service.presets()
        // Exclude a template pending deletion from the visible list so the undo window feels real.
        userTemplates = service.userTemplates().filter { $0.id != pendingDelete?.id }
        var runs: [String: ExportRun] = [:]
        for template in presets + userTemplates {
            if let run = service.lastRun(templateId: template.id) { runs[template.id] = run }
        }
        lastRuns = runs
    }

    private func beginDelete(_ template: ExportTemplate) {
        deleteTask?.cancel()
        withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
            pendingDelete = template
            userTemplates.removeAll { $0.id == template.id }
        }
        // Commit the soft-delete only after the undo window closes — so "Undo" is a no-op restore
        // of a row we never actually removed from the database yet.
        deleteTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            try? ExportManageService(env: env).deleteTemplate(id: template.id)
            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                pendingDelete = nil
            }
        }
    }

    private func undoDelete(_ template: ExportTemplate) {
        deleteTask?.cancel()
        withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
            pendingDelete = nil
        }
        reload()
    }

    // MARK: Display helpers

    /// Presets store a stable English `name` for storage identity; render a localized label from
    /// their rule + format instead (matching how Quick Export labels itself). User templates show
    /// the name the user typed.
    private func displayName(_ template: ExportTemplate) -> String {
        guard template.isPreset else { return template.name }
        let range = env.s(ExportRunPresentation.rangeRuleLabel(template.rangeRule, format: env.format))
        let quick = env.language == .ar ? "تصدير سريع" : "Quick Export"
        return "\(quick) · \(range) · \(template.format.rawValue.uppercased())"
    }

    private func summary(_ template: ExportTemplate) -> String {
        var parts: [String] = [template.format.rawValue.uppercased(),
                               env.s(ExportRunPresentation.rangeRuleLabel(template.rangeRule, format: env.format))]
        var scopeParts: [String] = []
        if template.scope.includeRaw { scopeParts.append(env.s(ExportCopy.scopeRaw)) }
        if template.scope.includeDerived { scopeParts.append(env.s(ExportCopy.scopeDerived)) }
        if template.scope.includeSuppressed { scopeParts.append(env.s(ExportCopy.scopeSuppressed)) }
        if template.scope.includeSensitive { scopeParts.append(env.s(ExportCopy.scopeSensitive)) }
        if !scopeParts.isEmpty { parts.append(scopeParts.joined(separator: "+")) }
        if let ids = template.scope.metricIds, !ids.isEmpty {
            let n = env.format.integer(ids.count)
            parts.append(env.language == .ar ? "\(n) مؤشرات" : "\(n) metrics")
        }
        return parts.joined(separator: " · ")
    }
}
