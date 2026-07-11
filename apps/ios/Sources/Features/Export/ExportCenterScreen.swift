import SwiftUI

// MARK: - Copy

/// Screen-local bilingual strings that don't belong in the shared catalog. Every string in the
/// app carries both languages; these are the ones specific to the export cockpit.
private enum ExportCopy {
    static let onDeviceOnly = LocalizedString(en: "On this device — no network", ar: "على هذا الجهاز — دون شبكة")
    static let formatCSVSubtitle = LocalizedString(
        en: "Spreadsheet-friendly. Raw and computed rows in separate files.",
        ar: "مناسب لجداول البيانات. صفوف خام ومحسوبة في ملفات منفصلة.")
    static let formatJSONSubtitle = LocalizedString(
        en: "One structured file with everything and its manifest.",
        ar: "ملف واحد منظّم يضم كل شيء مع بيانه.")

    static let includeRawSubtitle = LocalizedString(
        en: "Measured records straight from your sources.",
        ar: "سجلات مُقاسة مباشرة من مصادرك.")
    static let includeDerivedSubtitle = LocalizedString(
        en: "Baselines and scores BADAN computed for you.",
        ar: "المستويات المعتادة والدرجات التي حسبها بدن.")
    static let includeSuppressedSubtitle = LocalizedString(
        en: "Duplicate readings that were quietly set aside.",
        ar: "قراءات مكرّرة تم وضعها جانباً بهدوء.")
    static let includeSensitiveSubtitle = LocalizedString(
        en: "Your private medication and symptom logs.",
        ar: "سجلات أدويتك وأعراضك الخاصة.")
    static let sensitiveNote = LocalizedString(
        en: "This export will contain your medications and symptoms. Keep the file somewhere private.",
        ar: "سيتضمّن هذا التصدير أدويتك وأعراضك. احتفظ بالملف في مكان خاص.")

    static let dateRange = LocalizedString(en: "Date range", ar: "النطاق الزمني")
    static let unitSource = LocalizedString(en: "Source units", ar: "وحدات المصدر")
    static let unitDisplay = LocalizedString(en: "My units", ar: "وحداتي")
    static let unitNote = LocalizedString(
        en: "Source units keep the original SI values; my units convert to your chosen display units. Canonical columns are always preserved either way.",
        ar: "وحدات المصدر تُبقي قيم SI الأصلية؛ ووحداتي تُحوّل إلى وحدات العرض التي اخترتها. تُحفظ الأعمدة القياسية في الحالتين.")

    static let preparing = LocalizedString(en: "Preparing your export…", ar: "جارٍ تجهيز تصديرك…")
    static let exportReady = LocalizedString(en: "Export ready", ar: "التصدير جاهز")
    static let records = LocalizedString(en: "Records", ar: "السجلات")
    static let recordsInline = LocalizedString(en: "records", ar: "سجل")
    static let files = LocalizedString(en: "Files", ar: "الملفات")
    static let checksums = LocalizedString(en: "Checksums (SHA-256)", ar: "بصمات التحقق (SHA-256)")

    static let manifest = LocalizedString(en: "Manifest", ar: "البيان")
    static let schema = LocalizedString(en: "Schema", ar: "المخطط")
    static let generated = LocalizedString(en: "Generated", ar: "أُنشئ")
    static let rangeField = LocalizedString(en: "Range", ar: "النطاق")
    static let exportId = LocalizedString(en: "Export ID", ar: "معرّف التصدير")
    static let rowsPerMetric = LocalizedString(en: "Rows per metric", ar: "الصفوف لكل مؤشر")

    static let history = LocalizedString(en: "Previous exports", ar: "التصديرات السابقة")
    static let noHistory = LocalizedString(en: "No exports yet — create your first above.",
                                           ar: "لا توجد تصديرات بعد — أنشئ أول تصدير أعلاه.")

    static let couldntPrepare = LocalizedString(en: "That export couldn't be prepared. Nothing left your device.",
                                                ar: "تعذّر تجهيز هذا التصدير. لم يغادر شيء جهازك.")
}

/// The three offered windows. Maps to `ExportScope.startDate`; "all time" leaves it open.
private enum ExportRange: CaseIterable, Hashable {
    case last30, last90, all

    func startDate(now: Date) -> Date? {
        switch self {
        case .last30: return now.addingTimeInterval(-30 * 86_400)
        case .last90: return now.addingTimeInterval(-90 * 86_400)
        case .all: return nil
        }
    }

    func label(_ format: ValueFormatter) -> LocalizedString {
        switch self {
        case .last30:
            let n = format.integer(30)
            return LocalizedString(en: "Last \(n) days", ar: "آخر \(n) يوماً")
        case .last90:
            let n = format.integer(90)
            return LocalizedString(en: "Last \(n) days", ar: "آخر \(n) يوماً")
        case .all:
            return LocalizedString(en: "All time", ar: "كل الوقت")
        }
    }
}

// MARK: - View model

@Observable
@MainActor
final class ExportCenterViewModel {
    var history: [ExportJob] = []
    var lastResult: ExportRunner.ExportResult?
    var isRunning = false
    var errorText: String?

    func loadHistory(_ env: AppEnvironment) {
        history = (try? env.exportJobs.recent(limit: 20)) ?? []
    }

    func run(scope: ExportScope, format: ExportFormat, env: AppEnvironment) {
        guard !isRunning else { return }
        isRunning = true
        errorText = nil
        lastResult = nil
        // ExportRunner is fully synchronous, offline, and thread-safe (SQLite recursive lock).
        // Run it OFF the main actor (Task.detached) so a large "all time · raw+derived" export
        // never freezes the UI or risks the iOS watchdog; then hop back to update state.
        let exporter = env.exporter
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try exporter.run(scope: scope, format: format)
                }.value
                lastResult = result
                loadHistory(env)
            } catch {
                errorText = String(describing: error)
            }
            isRunning = false
        }
    }
}

// MARK: - Screen

/// The trust cockpit. Pick a format, choose exactly what to include, set a window, and create a
/// fully offline export — then share the file or re-share any earlier one. Casual keeps it calm
/// (format, the sensitive toggle, a window); power exposes the raw/computed/suppressed toggles,
/// the unit profile, per-file checksums and the manifest. Same run, two altitudes.
struct ExportCenterScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = ExportCenterViewModel()

    @State private var scope = ExportScope()
    @State private var format: ExportFormat = .csv
    @State private var range: ExportRange = .last30

    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                introCard
                formatSection
                scopeSection
                dateRangeSection
                if env.depth.showsPowerDetail {
                    unitSection
                }
                runButton
                if let error = vm.errorText {
                    errorCard(error)
                }
                if let result = vm.lastResult {
                    ExportSuccessCard(result: result) {
                        shareURLs = result.fileURLs
                        showShare = !result.fileURLs.isEmpty
                    }
                }
                historySection
                footer
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.exportTitle))
        .task { vm.loadHistory(env) }
        .onChange(of: vm.lastResult?.job.id) { _, newValue in
            guard newValue != nil, let urls = vm.lastResult?.fileURLs, !urls.isEmpty else { return }
            shareURLs = urls
            showShare = true
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(activityItems: shareURLs)
        }
    }

    // MARK: Intro

    private var introCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: "lock.shield")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    PillLabel(env.s(ExportCopy.onDeviceOnly), systemImage: "wifi.slash", tint: BadanColor.primary)
                    Spacer(minLength: BadanSpace.space2)
                }
                Text(Loc.exportEverything, language: env.language)
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
                ExportFormatCard(
                    title: "CSV",
                    subtitle: ExportCopy.formatCSVSubtitle,
                    icon: "tablecells",
                    selected: format == .csv
                ) { format = .csv }
                ExportFormatCard(
                    title: "JSON",
                    subtitle: ExportCopy.formatJSONSubtitle,
                    icon: "curlybraces",
                    selected: format == .json
                ) { format = .json }
            }
        }
    }

    // MARK: Scope

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.exportScope))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    if env.depth.showsPowerDetail {
                        scopeToggle(Loc.includeRaw, ExportCopy.includeRawSubtitle,
                                    isOn: $scope.includeRaw, icon: "waveform.path.ecg")
                        rowDivider
                        scopeToggle(Loc.includeDerived, ExportCopy.includeDerivedSubtitle,
                                    isOn: $scope.includeDerived, icon: "function")
                        rowDivider
                        scopeToggle(Loc.includeSuppressed, ExportCopy.includeSuppressedSubtitle,
                                    isOn: $scope.includeSuppressed, icon: "square.on.square.dashed")
                        rowDivider
                    }
                    scopeToggle(Loc.includeSensitive, ExportCopy.includeSensitiveSubtitle,
                                isOn: $scope.includeSensitive, icon: "cross.case")
                    if scope.includeSensitive {
                        sensitiveNote
                    }
                }
            }
        }
    }

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

    // MARK: Date range

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportCopy.dateRange))
            ExportSegmented(
                options: ExportRange.allCases.map { (value: $0, label: env.s($0.label(env.format))) },
                selection: $range
            )
        }
    }

    // MARK: Unit profile (power)

    private var unitSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.units))
            ExportSegmented(
                options: [
                    (value: UnitProfileMode.canonical, label: env.s(ExportCopy.unitSource)),
                    (value: UnitProfileMode.display, label: env.s(ExportCopy.unitDisplay)),
                ],
                selection: $scope.unitProfile
            )
            Text(ExportCopy.unitNote, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Run

    private var runButton: some View {
        Button(action: runExport) {
            HStack(spacing: BadanSpace.space2) {
                if vm.isRunning {
                    ProgressView()
                        .tint(BadanColor.background)
                    Text(ExportCopy.preparing, language: env.language)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityHidden(true)
                    Text(Loc.runExport, language: env.language)
                }
            }
            .font(BadanFont.body.weight(.semibold))
            .foregroundStyle(BadanColor.background)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 6)
            .background(BadanColor.primary,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(vm.isRunning)
        .opacity(vm.isRunning ? 0.75 : 1)
    }

    private func runExport() {
        var s = scope
        s.language = env.language
        s.startDate = range.startDate(now: env.now())
        s.endDate = nil
        vm.run(scope: s, format: format, env: env)
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
                if env.depth.showsPowerDetail {
                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportCopy.history))
            if vm.history.isEmpty {
                BadanCard {
                    Text(ExportCopy.noHistory, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                BadanCard {
                    VStack(spacing: BadanSpace.space3) {
                        ForEach(Array(vm.history.enumerated()), id: \.element.id) { index, job in
                            ExportHistoryRow(job: job) { urls in
                                shareURLs = urls
                                showShare = !urls.isEmpty
                            }
                            if index < vm.history.count - 1 {
                                rowDivider
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        Text(Loc.exportDisclaimer, language: env.language)
            .font(BadanFont.caption)
            .foregroundStyle(BadanColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, BadanSpace.space2)
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }
}

// MARK: - Format card

private struct ExportFormatCard: View {
    @Environment(AppEnvironment.self) private var env
    let title: String
    let subtitle: LocalizedString
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack {
                    Image(systemName: icon)
                        .imageScale(.large)
                        .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? BadanColor.primary : BadanColor.separator)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.textPrimary)
                Text(subtitle, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .padding(BadanSpace.space3)
            .background(selected ? BadanColor.primary.opacity(0.08) : BadanColor.surface,
                        in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                    .strokeBorder(selected ? BadanColor.primary : BadanColor.separator,
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Segmented control

private struct ExportSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: BadanSpace.space1) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(BadanFont.chip.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(selection == option.value ? BadanColor.primary : BadanColor.textSecondary)
                        .background(selection == option.value ? BadanColor.primary.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: BadanRadius.control - 2, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(BadanSpace.space1)
        .background(BadanColor.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }
}

// MARK: - Success card

private struct ExportSuccessCard: View {
    @Environment(AppEnvironment.self) private var env
    let result: ExportRunner.ExportResult
    let onShare: () -> Void

    private var checksums: [String: String] { result.job.manifest?.checksums ?? [:] }

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: "checkmark.seal.fill")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.inBand)
                        .accessibilityHidden(true)
                    Text(ExportCopy.exportReady, language: env.language)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    PillLabel(result.job.format.rawValue.uppercased(), tint: BadanColor.primary)
                }

                HStack(alignment: .top, spacing: BadanSpace.space6) {
                    StatBox(value: env.format.integer(result.rowCount), label: env.s(ExportCopy.records))
                    StatBox(value: env.format.integer(result.fileURLs.count), label: env.s(ExportCopy.files))
                }

                if !checksums.isEmpty {
                    rowDivider
                    Text(ExportCopy.checksums, language: env.language)
                        .font(BadanFont.caption.weight(.semibold))
                        .foregroundStyle(BadanColor.textSecondary)
                    ForEach(checksums.keys.sorted(), id: \.self) { name in
                        HStack(spacing: BadanSpace.space2) {
                            Text(name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(BadanColor.textPrimary)
                            Spacer(minLength: BadanSpace.space2)
                            Text(shortHash(checksums[name] ?? ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(BadanColor.textSecondary)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                }

                if env.depth.showsPowerDetail, let manifest = result.job.manifest {
                    rowDivider
                    manifestDetail(manifest)
                }

                Button(action: onShare) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityHidden(true)
                        Text(Loc.share, language: env.language)
                    }
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.primary)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .overlay(
                        RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                            .strokeBorder(BadanColor.primary, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func manifestDetail(_ manifest: ExportManifest) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(ExportCopy.manifest, language: env.language)
                .font(BadanFont.caption.weight(.semibold))
                .foregroundStyle(BadanColor.textSecondary)
            detailLine(ExportCopy.schema, value: manifest.schemaVersion)
            detailLine(ExportCopy.generated, value: dateText(manifest.generatedAt))
            detailLine(ExportCopy.rangeField, value: manifest.dateRange)
            detailLine(ExportCopy.exportId, value: String(manifest.exportId.prefix(10)))

            if !manifest.perMetricRowCounts.isEmpty {
                Text(ExportCopy.rowsPerMetric, language: env.language)
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                    .padding(.top, BadanSpace.space1)
                ForEach(manifest.perMetricRowCounts.keys.sorted(), id: \.self) { id in
                    HStack(spacing: BadanSpace.space2) {
                        Text(id)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(BadanColor.textPrimary)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer(minLength: BadanSpace.space2)
                        Text(env.format.integer(manifest.perMetricRowCounts[id] ?? 0))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    private func detailLine(_ label: LocalizedString, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            Text(label, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func shortHash(_ hash: String) -> String {
        hash.isEmpty ? "—" : String(hash.prefix(12)) + "…"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }
}

// MARK: - History row

private struct ExportHistoryRow: View {
    @Environment(AppEnvironment.self) private var env
    let job: ExportJob
    let onShare: ([URL]) -> Void

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: job.format == .csv ? "tablecells" : "curlybraces")
                .foregroundStyle(BadanColor.primary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BadanSpace.space2) {
                    Text(job.format.rawValue.uppercased())
                        .font(BadanFont.bodyCompact.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    PillLabel(rowCountText)
                }
                Text(dateText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            let urls = availableFileURLs()
            if !urls.isEmpty {
                Button {
                    onShare(urls)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .imageScale(.medium)
                        .foregroundStyle(BadanColor.primary)
                        .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(env.s(Loc.share))
            }
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private var rowCountText: String {
        "\(env.format.integer(job.rowCount ?? 0)) \(env.s(ExportCopy.recordsInline))"
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: job.createdAt)
    }

    /// Rebuild the shareable file URLs from the persisted job. The manifest's checksum keys are
    /// the written filenames; CSV runs additionally carry a manifest.json. Only files still on
    /// disk are offered.
    private func availableFileURLs() -> [URL] {
        guard let path = job.outputPath else { return [] }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        var names = Array(job.manifest?.checksums.keys ?? Dictionary<String, String>().keys)
        if names.isEmpty {
            names = job.format == .csv ? ["raw.csv", "derived.csv"] : ["bundle.json"]
        }
        if job.format == .csv {
            names.append("manifest.json")
        }
        return names
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
