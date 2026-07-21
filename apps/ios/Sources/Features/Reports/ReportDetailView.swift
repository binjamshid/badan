import SwiftUI

// MARK: - Detail read model

private struct ReportDetailModel {
    var model: ReportModel
    var record: ReportRecord
    /// The persisted row's content hash still matches a fresh re-derivation — nothing new has
    /// landed since it was generated.
    var isUpToDate: Bool
}

private struct ShareableURL: Identifiable { let url: URL; var id: String { url.path } }

private enum ReportDetailStrings {
    static let share = LocalizedString(en: "Share PDF", ar: "مشاركة PDF")
    static let staleNote = LocalizedString(
        en: "New data has landed since this report. Regenerate to refresh it.",
        ar: "وصلت بيانات جديدة منذ هذا التقرير. أعد الإنشاء للتحديث.")
    static let generatedAt = LocalizedString(en: "Generated {when}", ar: "أُنشئ في {when}")
}

// MARK: - Detail view model

@Observable
@MainActor
private final class ReportDetailViewModel {
    var state: LoadState<ReportDetailModel> = .loading
    var isWorking = false
    var share: ShareableURL?

    func load(_ record: ReportRecord, _ env: AppEnvironment) async {
        let derivation = env.derivation
        let logging = env.logging
        let periodKey = record.periodKey
        let tz = TimeZone.current.identifier
        let now = env.now()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ReportModel, Error> in
            do {
                let builder = ReportBuilder(derivation: derivation, logging: logging)
                return .success(try builder.generate(periodKey: periodKey, tz: tz, now: now))
            } catch { return .failure(error) }
        }.value
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let model):
            state = .loaded(ReportDetailModel(model: model, record: record,
                                              isUpToDate: !record.isStale(against: model.sha256)))
        case .failure(let error):
            LoadErrorLog.log(error, screen: "ReportDetail")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    /// Rebuild and re-persist this period, replacing the row in place. A failure is reported rather
    /// than swallowed — a regenerate that quietly left the stale banner up would leave the user
    /// tapping a button that appears to do nothing.
    func regenerate(_ record: ReportRecord, _ env: AppEnvironment) async {
        isWorking = true
        defer { isWorking = false }
        let service = env.reportGeneration
        let periodKey = record.periodKey
        let now = env.now()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(ReportRecord, ReportModel), Error> in
            do { return .success(try service.generateAndSave(periodKey: periodKey, now: now)) }
            catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let (newRecord, model)):
            state = .loaded(ReportDetailModel(model: model, record: newRecord, isUpToDate: true))
        case .failure(let error):
            LoadErrorLog.log(error, screen: "ReportDetail.regenerate")
            Announce.failure(env.s(ReportPresentation.generateError))
            await load(record, env)
        }
    }

    /// Render the report's PDF (on the main actor — UIKit's print stack) and hand it to the share
    /// sheet. The artifact is regenerable, so it is written to a temp file each time rather than
    /// kept as a source of truth.
    func makeShare(_ model: ReportModel, _ env: AppEnvironment) {
        let data = ReportRenderer.renderPDF(model, language: env.language, arabicDigits: env.profile.arabicDigits)
        let safeName = model.periodKey.replacingOccurrences(of: ":", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BADAN-\(safeName).pdf")
        do {
            try data.write(to: url, options: .atomic)
            share = ShareableURL(url: url)
        } catch {
            LoadErrorLog.log(error, screen: "ReportDetailShare")
        }
    }
}

// MARK: - Detail view

/// One report, in full. Casual reads the narrative; power adds the per-metric stat tables and the
/// evidence refs behind each claim (the transparency contract). A "regenerate" affordance is always
/// present, and a stale report (its stored hash no longer matches a fresh re-derivation) says so
/// plainly rather than being silently shown as current.
struct ReportDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let record: ReportRecord
    @State private var vm = ReportDetailViewModel()

    var body: some View {
        ScrollView {
            StatefulContainer(
                vm.state,
                retryTitle: env.s(LoadErrorCopy.retry),
                onRetry: { Task { await vm.load(record, env) } }
            ) { detail in
                content(detail)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(ReportPresentation.title(record.periodKey.hasPrefix("month:") ? .month : .week)))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $vm.share) { shareable in
            ShareSheet(activityItems: [shareable.url])
        }
        .task(id: record.id) { await vm.load(record, env) }
    }

    @ViewBuilder
    private func content(_ detail: ReportDetailModel) -> some View {
        let model = detail.model
        let isPower = env.profile.depthPolicy == .power
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            header(detail)

            if !detail.isUpToDate {
                staleBanner
            }

            if !model.hasSufficientData {
                BadanCard {
                    Text(ReportPresentation.emptyMessage(model.periodKind), language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(model.sections, id: \.kind) { section in
                sectionView(section, model: model, isPower: isPower)
            }
        }
    }

    @ViewBuilder
    private func header(_ detail: ReportDetailModel) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(ReportPresentation.periodLabel(detail.model, language: env.language, arabicDigits: env.profile.arabicDigits))
                .font(BadanFont.sectionTitle)
                .foregroundStyle(BadanColor.textPrimary)
            Text(generatedLabel(detail.model.generatedAt))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            HStack(spacing: BadanSpace.space4) {
                Button {
                    Task { await vm.regenerate(record, env) }
                } label: {
                    Label(env.s(ReportPresentation.regenerateLabel), systemImage: "arrow.clockwise")
                        .font(BadanFont.link)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BadanColor.primary)
                .disabled(vm.isWorking)

                Button {
                    vm.makeShare(detail.model, env)
                } label: {
                    Label(env.s(ReportDetailStrings.share), systemImage: "square.and.arrow.up")
                        .font(BadanFont.link)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BadanColor.primary)
                .disabled(vm.isWorking || !detail.model.hasSufficientData)
            }
            .padding(.top, BadanSpace.space1)
        }
    }

    private var staleBanner: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            Text(ReportDetailStrings.staleNote, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BadanSpace.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BadanColor.outOfBand.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
    }

    @ViewBuilder
    private func sectionView(_ section: ReportSection, model: ReportModel, isPower: Bool) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(ReportPresentation.sectionTitle(section.kind), language: env.language)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    switch section.kind {
                    case .sleep, .effort, .readiness:
                        ForEach(section.metrics, id: \.metricId) { metric in
                            metricView(metric, model: model, isPower: isPower)
                        }
                    case .changes:
                        ForEach(section.changes, id: \.metricId) { change in
                            claimView(text: ReportPresentation.changeNarrative(change, kind: model.periodKind, language: env.language, arabicDigits: env.profile.arabicDigits),
                                      evidence: change.evidence, evidenceCount: change.evidence.count, isPower: isPower)
                        }
                    case .adherence:
                        if let a = section.adherence {
                            claimView(text: ReportPresentation.adherenceNarrative(a, kind: model.periodKind, language: env.language, arabicDigits: env.profile.arabicDigits),
                                      evidence: a.evidence, evidenceCount: a.logged, isPower: isPower)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metricView(_ m: MetricSummary, model: ReportModel, isPower: Bool) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(ReportPresentation.metricNarrative(m, kind: model.periodKind, language: env.language, arabicDigits: env.profile.arabicDigits))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if isPower {
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    statRow(ReportPresentation.averageLabel, num(m.mean ?? 0))
                    statRow(ReportPresentation.rangeLabel, "\(num(m.min ?? 0))–\(num(m.max ?? 0))")
                    statRow(ReportPresentation.latestLabel, num(m.latest ?? 0))
                }
                evidenceView(m.evidence, count: m.count)
            }
        }
    }

    @ViewBuilder
    private func claimView(text: String, evidence: [EvidenceRef], evidenceCount: Int, isPower: Bool) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(text)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if isPower { evidenceView(evidence, count: evidenceCount) }
        }
    }

    @ViewBuilder
    private func statRow(_ label: LocalizedString, _ value: String) -> some View {
        HStack {
            Text(label, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
        }
    }

    @ViewBuilder
    private func evidenceView(_ refs: [EvidenceRef], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ReportPresentation.evidenceCountPhrase(count, language: env.language, arabicDigits: env.profile.arabicDigits))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            if !refs.isEmpty {
                Text(refs.map { $0.periodKey ?? $0.id }.joined(separator: ", "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(BadanColor.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.top, BadanSpace.space1)
    }

    private func num(_ v: Double) -> String {
        ReportPresentation.number(v, env.language, env.profile.arabicDigits, fractionDigits: 0)
    }

    private func generatedLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = env.language.locale
        df.dateStyle = .medium
        df.timeStyle = .short
        return env.s(ReportDetailStrings.generatedAt.filling(["when": df.string(from: date)]))
    }
}
