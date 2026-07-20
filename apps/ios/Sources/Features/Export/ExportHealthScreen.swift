import SwiftUI

// MARK: - Copy

private enum ExportHealthCopy {
    static let title = LocalizedString(en: "Export health", ar: "حالة التصدير")
    static let trust = LocalizedString(
        en: "If something didn't run, you'll see it here — nothing fails silently.",
        ar: "إن لم يجرِ تشغيل شيء، فسترى ذلك هنا — لا شيء يفشل بصمت.")

    static let templatesSection = LocalizedString(en: "Your templates", ar: "قوالبك")
    static let lastSuccess = LocalizedString(en: "Last successful export", ar: "آخر تصدير ناجح")
    static let noSuccess = LocalizedString(en: "No successful export yet", ar: "لا تصدير ناجح بعد")
    static let nextLabel = LocalizedString(en: "Next export covers", ar: "يشمل التصدير التالي")
    static let run = LocalizedString(en: "Run now", ar: "التشغيل الآن")
    static let noTemplates = LocalizedString(
        en: "No templates yet — save one from the builder to track it here.",
        ar: "لا قوالب بعد — احفظ واحداً من المُنشئ لتتبّعه هنا.")

    static let recentSection = LocalizedString(en: "Recent runs", ar: "عمليات التشغيل الأخيرة")
    static let noRuns = LocalizedString(
        en: "No runs recorded yet. Every time a template or Quick Export runs, its outcome lands here.",
        ar: "لا عمليات مسجّلة بعد. في كل مرة يُشغَّل فيها قالب أو تصدير سريع، تظهر نتيجته هنا.")
    static let customExport = LocalizedString(en: "Custom export", ar: "تصدير مخصص")
    static let deletedTemplate = LocalizedString(en: "Deleted template", ar: "قالب محذوف")

    static let errorDetail = LocalizedString(en: "What happened", ar: "ما الذي حدث")
    static func filesWritten(_ written: String, _ expected: String) -> LocalizedString {
        LocalizedString(en: "\(written) of \(expected) files written", ar: "كُتب \(written) من \(expected) ملفات")
    }
    static func bytes(_ n: String) -> LocalizedString {
        LocalizedString(en: "\(n) on disk", ar: "\(n) على القرص")
    }

    // Power-mode background substrate
    static let backgroundSection = LocalizedString(en: "Background activity", ar: "نشاط الخلفية")
    static let backgroundHint = LocalizedString(
        en: "How often BADAN's own background work has run recently, and how it ended.",
        ar: "كم مرة جرى عمل بدن في الخلفية مؤخراً، وكيف انتهى.")
    static let lastActivity = LocalizedString(en: "Last activity", ar: "آخر نشاط")
    static let runsInWindow = LocalizedString(en: "Runs", ar: "عمليات التشغيل")
    static let noBackground = LocalizedString(
        en: "No background activity recorded yet.", ar: "لا نشاط خلفية مسجّل بعد.")
    static let gapNotice = LocalizedString(
        en: "exports started but left no record — likely the app was closed mid-export. They're counted here so the gap isn't invisible.",
        ar: "تصديرات بدأت ولم تترك سجلاً — غالباً أُغلق التطبيق أثناء التصدير. تُحصى هنا حتى لا تكون الفجوة خفية.")

    static func runAccessibility(_ name: String, outcome: String) -> LocalizedString {
        LocalizedString(en: "\(name), \(outcome)", ar: "\(name)، \(outcome)")
    }
}

// MARK: - Screen

/// EPIC-16 — the trust ledger made visible. Answers "did my export actually run?" at a glance:
/// per-template last success, an estimate of what the next run would cover (never a promised
/// wall-clock time), and the full run log with a plain-language outcome on every row. Power mode
/// adds the sanitized error detail and the background-substrate stats.
///
/// Everything shown here is read from the `export_runs`/`background_runs` ledgers, both of which
/// are value-free by construction (`ExportRun`, `BackgroundWorkCounts`), so this screen is safe to
/// screenshot into a support conversation.
struct ExportHealthScreen: View {
    @Environment(AppEnvironment.self) private var env

    @State private var templates: [ExportTemplate] = []
    @State private var runs: [ExportRun] = []
    @State private var lastSuccesses: [String: ExportRun] = [:]
    @State private var backgroundSummary: BackgroundHealthSummary?
    @State private var gapCount = 0
    @State private var runModel = TemplateRunModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                trustCard
                if let message = runModel.message { runMessageBanner(message) }
                templatesSection
                recentRunsSection
                if env.depth.showsPowerDetail {
                    backgroundSection
                    gapSection
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(ExportHealthCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .templateRun(runModel, env: env)
        .onAppear {
            runModel.onFinished = { reload() }
            reload()
        }
    }

    // MARK: Trust

    private var trustCard: some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "checkmark.shield.fill")
                    .imageScale(.large)
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(ExportHealthCopy.trust, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runMessageBanner(_ message: LocalizedString) -> some View {
        let tint = runModel.messageIsError ? BadanColor.outOfBand : BadanColor.info
        return HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: runModel.messageIsError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BadanSpace.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }

    // MARK: Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportHealthCopy.templatesSection))
            if templates.isEmpty {
                BadanCard {
                    Text(ExportHealthCopy.noTemplates, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(templates) { template in
                    templateCard(template)
                }
            }
        }
    }

    private func templateCard(_ template: ExportTemplate) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: template.format == .csv ? "tablecells" : "curlybraces")
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(displayName(template))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    runButton(template)
                }
                lastSuccessLine(template)
                nextLine(template)
            }
        }
    }

    private func lastSuccessLine(_ template: ExportTemplate) -> some View {
        HStack(spacing: BadanSpace.space2) {
            if let run = lastSuccesses[template.id] {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text("\(env.s(ExportHealthCopy.lastSuccess)): \(dateText(run.finishedAt ?? run.startedAt))")
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                Image(systemName: "circle.dashed")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(ExportHealthCopy.noSuccess, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func nextLine(_ template: ExportTemplate) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "calendar")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text("\(env.s(ExportHealthCopy.nextLabel)): \(env.s(ExportRunPresentation.rangeRuleLabel(template.rangeRule, format: env.format)))")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func runButton(_ template: ExportTemplate) -> some View {
        Button { runModel.run(template, env: env) } label: {
            Group {
                if runModel.runningTemplateId == template.id {
                    ProgressView().tint(BadanColor.primary)
                } else {
                    Text(ExportHealthCopy.run, language: env.language)
                        .font(BadanFont.chip.weight(.semibold))
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
        .accessibilityLabel("\(env.s(ExportHealthCopy.run)): \(displayName(template))")
    }

    // MARK: Recent runs (ledger)

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportHealthCopy.recentSection))
            if runs.isEmpty {
                BadanCard {
                    Text(ExportHealthCopy.noRuns, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                BadanCard {
                    VStack(spacing: BadanSpace.space3) {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                            runRow(run)
                            if index < runs.count - 1 { rowDivider }
                        }
                    }
                }
            }
        }
    }

    private func runRow(_ run: ExportRun) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            HStack(spacing: BadanSpace.space2) {
                outcomeChip(run.outcome)
                PillLabel(env.s(ExportRunPresentation.triggerLabel(run.trigger)), filled: false)
                Spacer(minLength: BadanSpace.space2)
            }
            Text("\(runTitle(run)) · \(dateText(run.startedAt))")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if env.depth.showsPowerDetail { errorDetail(run) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(env.s(ExportHealthCopy.runAccessibility(
            runTitle(run), outcome: env.s(ExportRunPresentation.label(run.outcome)))))
    }

    /// Icon + text + tint — three independent carriers of the same meaning (§16: status not
    /// color-only).
    private func outcomeChip(_ outcome: ExportOutcome) -> some View {
        PillLabel(env.s(ExportRunPresentation.label(outcome)),
                  systemImage: ExportRunPresentation.icon(outcome),
                  tint: ExportRunPresentation.tone(outcome).tint)
    }

    @ViewBuilder
    private func errorDetail(_ run: ExportRun) -> some View {
        if run.outcome.isFailure {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                if let code = run.errorCode {
                    Text("\(env.s(ExportHealthCopy.errorDetail)): \(env.s(ExportRunPresentation.errorLabel(code)))")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = run.errorDetail {
                    Text("\(env.s(ExportRunPresentation.stageLabel(detail.stage))) · \(env.s(ExportHealthCopy.filesWritten(env.format.integer(detail.filesWritten), env.format.integer(detail.filesExpected))))")
                        .font(BadanFont.caption.monospaced())
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            .padding(BadanSpace.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.outOfBand.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        } else if let bytes = run.bytesWritten, bytes > 0 {
            Text(ExportHealthCopy.bytes(byteText(bytes)), language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    // MARK: Background substrate (power)

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportHealthCopy.backgroundSection))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    Text(ExportHealthCopy.backgroundHint, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary = backgroundSummary, summary.totalRuns > 0 {
                        HStack(alignment: .top, spacing: BadanSpace.space6) {
                            StatBox(value: env.format.integer(summary.totalRuns),
                                    label: env.s(ExportHealthCopy.runsInWindow), size: .compact)
                            if let last = summary.lastRunAt {
                                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                                    Text(dateText(last))
                                        .font(BadanFont.bodyCompact.weight(.medium))
                                        .foregroundStyle(BadanColor.textPrimary)
                                    Text(ExportHealthCopy.lastActivity, language: env.language)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                }
                            }
                        }
                        if let outcome = summary.lastRunOutcome {
                            HStack(spacing: BadanSpace.space2) {
                                PillLabel(env.s(ExportRunPresentation.backgroundOutcomeLabel(outcome)),
                                          systemImage: outcome == .error ? "exclamationmark.triangle" : "checkmark.circle",
                                          tint: outcome == .error ? BadanColor.outOfBand : BadanColor.primary)
                                if let kind = summary.lastRunKind {
                                    PillLabel(env.s(ExportRunPresentation.backgroundKindLabel(kind)), filled: false)
                                }
                            }
                        }
                        outcomeMix(summary)
                    } else {
                        Text(ExportHealthCopy.noBackground, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    private func outcomeMix(_ summary: BackgroundHealthSummary) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            ForEach(summary.outcomeCounts, id: \.outcome) { entry in
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: entry.outcome == .error ? "exclamationmark.triangle" : "circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(entry.outcome == .error ? BadanColor.outOfBand : BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(env.s(ExportRunPresentation.backgroundOutcomeLabel(entry.outcome)))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Spacer(minLength: BadanSpace.space2)
                    Text(env.format.integer(entry.count))
                        .font(BadanFont.caption.monospaced())
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var gapSection: some View {
        if gapCount > 0 {
            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(BadanColor.outOfBand)
                    .accessibilityHidden(true)
                Text("\(env.format.integer(gapCount)) \(env.s(ExportHealthCopy.gapNotice))")
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.outOfBand.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }

    // MARK: Data

    private func reload() {
        let service = ExportManageService(env: env)
        service.ensureSeeded()
        templates = service.presets() + service.userTemplates()
        runs = service.recentRuns(limit: 50)
        var successes: [String: ExportRun] = [:]
        for template in templates {
            let dest = template.destinationId ?? ExportDestination.shareSheetId
            if let run = service.lastSuccess(templateId: template.id, destinationId: dest) {
                successes[template.id] = run
            }
        }
        lastSuccesses = successes
        gapCount = service.jobsWithoutRunCount()
        backgroundSummary = try? env.backgroundRuns.summary(now: env.now())
    }

    // MARK: Display helpers

    private func runTitle(_ run: ExportRun) -> String {
        guard let templateId = run.templateId else { return env.s(ExportHealthCopy.customExport) }
        if let template = templates.first(where: { $0.id == templateId }) {
            return displayName(template)
        }
        return env.s(ExportHealthCopy.deletedTemplate)
    }

    private func displayName(_ template: ExportTemplate) -> String {
        guard template.isPreset else { return template.name }
        let range = env.s(ExportRunPresentation.rangeRuleLabel(template.rangeRule, format: env.format))
        let quick = env.language == .ar ? "تصدير سريع" : "Quick Export"
        return "\(quick) · \(range) · \(template.format.rawValue.uppercased())"
    }

    private func byteText(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return "\(env.format.number(value, fraction: unit == 0 ? 0 : 1)) \(units[unit])"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func dateText(_ date: Date) -> String {
        Self.dateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateFormatter.string(from: date)
    }
}
