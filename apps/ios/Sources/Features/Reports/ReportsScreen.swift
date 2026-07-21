import SwiftUI

// MARK: - Local strings

/// Copy only the Reports surface needs; shared report wording (titles, section labels, narratives,
/// the disclaimer) comes from `ReportPresentation`, so the PDF and this screen never diverge.
private enum ReportsStrings {
    static let title = LocalizedString(en: "Reports", ar: "التقارير")
    static let subtitle = LocalizedString(
        en: "Weekly and monthly summaries — every number links to its evidence.",
        ar: "ملخّصات أسبوعية وشهرية — كل رقم مرتبط بدليله.")
    static let generateHeader = LocalizedString(en: "Generate", ar: "إنشاء")
    static let yourReportsHeader = LocalizedString(en: "Your reports", ar: "تقاريرك")
    static let noReports = LocalizedString(
        en: "No reports yet. Generate one above, or one appears automatically after a week of data.",
        ar: "لا توجد تقارير بعد. أنشئ واحداً بالأعلى، أو سيظهر تلقائياً بعد أسبوع من البيانات.")
    static let generateAction = LocalizedString(en: "Generate", ar: "إنشاء")
}

// MARK: - List read model

private struct ReportSuggestion: Identifiable {
    let periodKey: String
    let kind: ReportPeriodKind
    let exists: Bool
    var id: String { periodKey }
}

private struct ReportsListModel {
    var records: [ReportRecord]
    var suggestions: [ReportSuggestion]
}

private struct ReportsFetchInputs {
    var reports: ReportRepository
    var now: Date
    var tz: String
}

// MARK: - List view model

@Observable
@MainActor
private final class ReportsViewModel {
    var state: LoadState<ReportsListModel> = .loading
    var isWorking = false

    func load(_ env: AppEnvironment) async {
        let inputs = ReportsFetchInputs(reports: env.reports, now: env.now(), tz: TimeZone.current.identifier)
        let outcome = await Task.detached(priority: .userInitiated) { Self.fetch(inputs) }.value
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let model): state = .loaded(model)
        case .failure(let error):
            LoadErrorLog.log(error, screen: "Reports")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    /// Generate (or regenerate) a report for a period, then reload the list. Runs the build+persist
    /// off the main actor; the service is Sendable and serializes its DB writes internally.
    ///
    /// A failure is reported rather than swallowed: silently reloading an unchanged list after a
    /// tap on "Generate" is indistinguishable from a period that legitimately produced nothing, and
    /// an empty period does produce a report here (an honest one). Same log + announce shape every
    /// other write in the app uses.
    func generate(periodKey: String, _ env: AppEnvironment) async {
        isWorking = true
        defer { isWorking = false }
        let service = env.reportGeneration
        let now = env.now()
        let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { _ = try service.generateAndSave(periodKey: periodKey, now: now); return nil }
            catch { return error }
        }.value
        if let failure {
            LoadErrorLog.log(failure, screen: "Reports.generate")
            Announce.failure(env.s(ReportPresentation.generateError))
        }
        await load(env)
    }

    nonisolated static func fetch(_ inputs: ReportsFetchInputs) -> Result<ReportsListModel, Error> {
        do {
            let records = try inputs.reports.all()
            let existing = Set(records.map { $0.periodKey })
            let tz = inputs.tz
            let lastWeek = ReportTrigger.lastCompletedWeek(asOf: inputs.now, tz: tz).periodKey
            let thisWeek = ReportPeriod.week(containing: inputs.now, tz: tz).periodKey
            let thisMonth = ReportPeriod.month(containing: inputs.now, tz: tz)
            let lastMonth = ReportPeriod.prior(thisMonth, tz: tz).periodKey

            var seen = Set<String>()
            var suggestions: [ReportSuggestion] = []
            func add(_ key: String, _ kind: ReportPeriodKind) {
                guard seen.insert(key).inserted else { return }
                suggestions.append(ReportSuggestion(periodKey: key, kind: kind, exists: existing.contains(key)))
            }
            add(lastWeek, .week)
            add(thisWeek, .week)
            add(lastMonth, .month)
            return .success(ReportsListModel(records: records, suggestions: suggestions))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - List screen

/// EPIC-31 — the Reports surface, under Body. Lists generated weekly/monthly reports and offers to
/// generate the most useful periods. Casual reads the narrative; power adds the stat tables and the
/// evidence refs (see `ReportDetailView`). A persistent "wellness summary, not a medical
/// assessment" footer sits below the fold at all times.
struct ReportsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = ReportsViewModel()

    var body: some View {
        ScrollView {
            StatefulContainer(
                vm.state,
                retryTitle: env.s(LoadErrorCopy.retry),
                onRetry: { Task { await vm.load(env) } }
            ) { model in
                content(model)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(ReportsStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            ReportsMedicalFooter(text: ReportPresentation.disclaimer, language: env.language)
        }
        .task(id: ReportsLoadKey(profile: env.profile, generation: env.dataGeneration)) {
            await vm.load(env)
        }
    }

    @ViewBuilder
    private func content(_ model: ReportsListModel) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            Text(ReportsStrings.subtitle, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Generate suggestions.
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(ReportsStrings.generateHeader, language: env.language)
                BadanCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            if index > 0 {
                                Rectangle().fill(BadanColor.separator).frame(height: 1)
                                    .padding(.leading, BadanSpace.cardPadding)
                            }
                            suggestionRow(suggestion)
                        }
                    }
                }
            }

            // Existing reports.
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(ReportsStrings.yourReportsHeader, language: env.language)
                if model.records.isEmpty {
                    BadanCard {
                        Text(ReportsStrings.noReports, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    BadanCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                                if index > 0 {
                                    Rectangle().fill(BadanColor.separator).frame(height: 1)
                                        .padding(.leading, BadanSpace.cardPadding)
                                }
                                NavigationLink { ReportDetailView(record: record) } label: {
                                    reportRow(record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: ReportSuggestion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ReportPresentation.title(suggestion.kind), language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(suggestionLabel(suggestion))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            Button {
                Task { await vm.generate(periodKey: suggestion.periodKey, env) }
            } label: {
                // The action is always a build — for a period that already has a report it
                // rebuilds it in place. Labelling that "View" would promise navigation this
                // button does not perform; the report itself is reachable from the list below.
                Text(suggestion.exists ? ReportPresentation.regenerateLabel : ReportsStrings.generateAction,
                     language: env.language)
                    .font(BadanFont.link)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BadanColor.primary)
            .disabled(vm.isWorking)
        }
        .padding(BadanSpace.cardPadding)
        .frame(minHeight: BadanSpace.touchMin)
    }

    @ViewBuilder
    private func reportRow(_ record: ReportRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(periodDisplay(record))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(ReportPresentation.sectionCount(record.sectionsIncluded.count,
                                                     language: env.language,
                                                     arabicDigits: env.profile.arabicDigits))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            Image(systemName: "chevron.forward")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .padding(BadanSpace.cardPadding)
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
    }

    private func suggestionLabel(_ suggestion: ReportSuggestion) -> String {
        // Reuse the model period-label logic by resolving the period; fall back to the raw key.
        guard let resolved = ReportPeriod.resolve(periodKey: suggestion.periodKey, tz: TimeZone.current.identifier) else {
            return suggestion.periodKey
        }
        let stub = ReportModel(periodKey: resolved.periodKey, periodKind: resolved.kind,
                               periodStart: resolved.start, periodEnd: resolved.end, timezone: resolved.timezone,
                               generatedAt: env.now(), algorithmVersionId: ReportBuilder.algorithm.id,
                               hasSufficientData: false, sections: [], sha256: "")
        return ReportPresentation.periodLabel(stub, language: env.language, arabicDigits: env.profile.arabicDigits)
    }

    private func periodDisplay(_ record: ReportRecord) -> String {
        let tz = TimeZone.current.identifier
        guard let resolved = ReportPeriod.resolve(periodKey: record.periodKey, tz: tz) else {
            return record.periodKey
        }
        let stub = ReportModel(periodKey: resolved.periodKey, periodKind: resolved.kind,
                               periodStart: resolved.start, periodEnd: resolved.end, timezone: resolved.timezone,
                               generatedAt: record.generatedAt, algorithmVersionId: record.algorithmVersionId,
                               hasSufficientData: true, sections: [], sha256: record.sha256)
        return ReportPresentation.periodLabel(stub, language: env.language, arabicDigits: env.profile.arabicDigits)
    }
}

private struct ReportsLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

/// The persistent "wellness summary, not a medical assessment" strip. Local to this file rather
/// than shared because the Health Monitor's equivalent is file-private; both render the same token
/// surface + hairline so they read identically.
private struct ReportsMedicalFooter: View {
    let text: LocalizedString
    var language: AppLanguage

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(text, language: language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BadanSpace.space4)
        .padding(.vertical, BadanSpace.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BadanColor.surfaceElevated)
        .overlay(alignment: .top) {
            Rectangle().fill(BadanColor.separator).frame(height: 1)
        }
    }
}
