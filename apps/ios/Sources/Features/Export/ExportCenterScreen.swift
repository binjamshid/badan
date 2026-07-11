import SwiftUI
import UIKit

// MARK: - Copy

/// Screen-local bilingual strings that don't belong in the shared catalog. Every string in the
/// app carries both languages; these are the ones specific to the export cockpit.
private enum ExportCopy {
    static let onDeviceOnly = LocalizedString(en: "On this device — no network", ar: "على هذا الجهاز — دون شبكة")
    static let formatCSVSubtitle = LocalizedString(
        en: "Spreadsheet-friendly. Raw and computed rows in separate files. Best for Excel, Numbers, or Sheets.",
        ar: "مناسب لجداول البيانات. صفوف خام ومحسوبة في ملفات منفصلة. الأنسب لإكسل أو Numbers أو Sheets.")
    static let formatJSONSubtitle = LocalizedString(
        en: "One structured file with everything and its manifest. Best for developers or a full backup.",
        ar: "ملف واحد منظّم يضم كل شيء مع بيانه. الأنسب للمطورين أو نسخة احتياطية كاملة.")

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
    static let sensitiveModuleDisabledNote = LocalizedString(
        en: "Turn on Sensitive records in Settings to include this.",
        ar: "فعّل السجلات الحساسة في الإعدادات لتضمين هذا.")
    static let casualIncludesNote = LocalizedString(
        en: "Includes: raw records + computed values, from your chosen date range.",
        ar: "يتضمّن: السجلات الخام + القيم المحسوبة، من النطاق الزمني الذي اخترته.")

    static let dateRange = LocalizedString(en: "Date range", ar: "النطاق الزمني")
    static let customRangeStart = LocalizedString(en: "Start date", ar: "تاريخ البدء")
    static let customRangeEnd = LocalizedString(en: "End date", ar: "تاريخ الانتهاء")
    static let unitSource = LocalizedString(en: "Source units", ar: "وحدات المصدر")
    static let unitDisplay = LocalizedString(en: "My units", ar: "وحداتي")
    static let unitNote = LocalizedString(
        en: "Source units keep the original SI values; my units convert to your chosen display units. Canonical columns are always preserved either way.",
        ar: "وحدات المصدر تُبقي قيم SI الأصلية؛ ووحداتي تُحوّل إلى وحدات العرض التي اخترتها. تُحفظ الأعمدة القياسية في الحالتين.")
    static let unitNoteCollapsedLabel = LocalizedString(en: "Source vs. my units", ar: "وحدات المصدر مقابل وحداتي")
    static let casualUnitsSource = LocalizedString(
        en: "Values will use source (original) units.", ar: "ستُستخدم وحدات المصدر (الأصلية) للقيم.")
    static let casualUnitsDisplay = LocalizedString(
        en: "Values will use your preferred display units.", ar: "ستُستخدم وحدات العرض التي تفضّلها للقيم.")

    static let sources = LocalizedString(en: "Sources", ar: "المصادر")

    static let preparing = LocalizedString(en: "Preparing your export…", ar: "جارٍ تجهيز تصديرك…")
    static let exportReady = LocalizedString(en: "Export ready", ar: "التصدير جاهز")
    static let records = LocalizedString(en: "Records", ar: "السجلات")
    static let recordsInline = LocalizedString(en: "records", ar: "سجل")
    static let files = LocalizedString(en: "Files", ar: "الملفات")
    static let checksums = LocalizedString(en: "Checksums (SHA-256)", ar: "بصمات التحقق (SHA-256)")
    static let checksumsExplainer = LocalizedString(
        en: "A fingerprint you can use to confirm the file wasn't altered.",
        ar: "بصمة يمكنك استخدامها للتأكد من أن الملف لم يُغيَّر.")
    static let exportAgain = LocalizedString(en: "Export again", ar: "صدّر مرة أخرى")

    static let manifest = LocalizedString(en: "Manifest", ar: "البيان")
    static let schema = LocalizedString(en: "Schema", ar: "المخطط")
    static let generated = LocalizedString(en: "Generated", ar: "أُنشئ")
    static let rangeField = LocalizedString(en: "Range", ar: "النطاق")
    static let exportId = LocalizedString(en: "Export ID", ar: "معرّف التصدير")
    static let rowsPerMetric = LocalizedString(en: "Rows per metric", ar: "الصفوف لكل مؤشر")

    static let history = LocalizedString(en: "Previous exports", ar: "التصديرات السابقة")
    static let noHistory = LocalizedString(en: "No exports yet — create your first above.",
                                           ar: "لا توجد تصديرات بعد — أنشئ أول تصدير أعلاه.")
    static let seeAll = LocalizedString(en: "See all", ar: "عرض الكل")
    static let filesUnavailable = LocalizedString(
        en: "Files no longer available on this device.", ar: "الملفات لم تعد متوفرة على هذا الجهاز.")

    static let scopeRaw = LocalizedString(en: "Raw", ar: "خام")
    static let scopeDerived = LocalizedString(en: "Derived", ar: "محسوب")
    static let scopeSuppressed = LocalizedString(en: "Suppressed", ar: "مستبعد")
    static let scopeSensitive = LocalizedString(en: "Sensitive", ar: "حساس")
    static let scopeNone = LocalizedString(en: "Nothing", ar: "لا شيء")
    static let scopeAllTime = LocalizedString(en: "All time", ar: "كل الوقت")

    static let couldntPrepare = LocalizedString(en: "That export couldn't be prepared. Nothing left your device.",
                                                ar: "تعذّر تجهيز هذا التصدير. لم يغادر شيء جهازك.")
    static let errorHint = LocalizedString(en: "Check available storage and try again.",
                                           ar: "تحقّق من المساحة المتوفرة وحاول مرة أخرى.")
    static let tryAgain = LocalizedString(en: "Try again", ar: "حاول مرة أخرى")
}

/// The offered windows. Maps to `ExportScope.startDate`/`endDate`; "all time" leaves both open,
/// "custom" reads two user-picked dates instead of a fixed offset.
private enum ExportRange: CaseIterable, Hashable {
    case last30, last90, all, custom

    func startDate(now: Date) -> Date? {
        switch self {
        case .last30: return now.addingTimeInterval(-30 * 86_400)
        case .last90: return now.addingTimeInterval(-90 * 86_400)
        case .all, .custom: return nil
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
        case .custom:
            return LocalizedString(en: "Custom", ar: "مخصص")
        }
    }
}

// MARK: - View model

/// A past export paired with the file URLs actually still reachable on disk, resolved once
/// (not per render — PERF-083) from the job's own manifest.
struct ExportHistoryItem: Identifiable {
    let job: ExportJob
    let fileURLs: [URL]
    var id: String { job.id }
}

/// One completed run, paired with its manifest's metric-id keys sorted once (PERF-085) instead
/// of on every render of the detail view.
struct ExportResultDisplay: Identifiable {
    let result: ExportRunner.ExportResult
    let sortedMetricIds: [String]
    var id: String { result.job.id }
}

@Observable
@MainActor
final class ExportCenterViewModel {
    var history: [ExportHistoryItem] = []
    var lastResults: [ExportResultDisplay] = []
    var isRunning = false
    var errorText: String?

    func loadHistory(_ env: AppEnvironment) {
        history = Self.buildItems(from: (try? env.exportJobs.recent(limit: 20)) ?? [])
    }

    static func buildItems(from jobs: [ExportJob]) -> [ExportHistoryItem] {
        jobs.map { ExportHistoryItem(job: $0, fileURLs: availableFileURLs(for: $0)) }
    }

    /// Rebuilds shareable file URLs for a persisted job. Filenames come from the manifest's own
    /// checksum keys — the only source of truth for what was actually written. A job whose
    /// manifest is missing or empty (e.g. failed to decode after a future schema change) is
    /// treated as unverifiable and offers nothing to re-share rather than guessing filenames
    /// (OPT-139): re-sharing a file we can no longer verify against its own manifest would
    /// undermine the manifest's entire tamper-evidence purpose. Only files still on disk are
    /// offered.
    static func availableFileURLs(for job: ExportJob) -> [URL] {
        guard let path = job.outputPath, let manifest = job.manifest, !manifest.checksums.isEmpty else { return [] }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        var names = Array(manifest.checksums.keys)
        if job.format == .csv { names.append("manifest.json") }
        return names
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Runs one export per requested format, sequentially, off the main actor (`ExportRunner` is
    /// fully synchronous, offline, and thread-safe — SQLite recursive lock) so a large "all
    /// time · raw+derived" export never freezes the UI or risks the iOS watchdog; then hops back
    /// to update state once. A failure aborts any remaining formats, matching the previous
    /// single-format error behavior.
    func run(scope: ExportScope, formats: [ExportFormat], env: AppEnvironment) {
        guard !isRunning, !formats.isEmpty else { return }
        isRunning = true
        errorText = nil
        lastResults = []
        let exporter = env.exporter
        Task {
            do {
                var produced: [ExportResultDisplay] = []
                for fmt in formats {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try exporter.run(scope: scope, format: fmt)
                    }.value
                    let sortedIds = result.job.manifest?.perMetricRowCounts.keys.sorted() ?? []
                    produced.append(ExportResultDisplay(result: result, sortedMetricIds: sortedIds))
                }
                lastResults = produced
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
    @State private var selectedFormats: Set<ExportFormat> = [.csv]
    @State private var range: ExportRange = .last30
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var unitNoteExpanded = false
    @State private var availableSources: [Source] = []

    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var showAllHistory = false
    @State private var allHistoryItems: [ExportHistoryItem] = []
    @State private var inspectingItem: ExportHistoryItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                introCard
                formatSection
                scopeSection
                if env.depth.showsPowerDetail && !availableSources.isEmpty {
                    sourceSection
                }
                dateRangeSection
                if env.depth.showsPowerDetail {
                    unitSection
                }
                trustReminder
                runButton
                if let error = vm.errorText {
                    errorCard(error)
                }
                ForEach(vm.lastResults) { item in
                    ExportSuccessCard(result: item.result, sortedMetricIds: item.sortedMetricIds) {
                        shareURLs = item.result.fileURLs
                        showShare = !item.result.fileURLs.isEmpty
                    } onRunAgain: {
                        vm.run(scope: item.result.job.scope, formats: [item.result.job.format], env: env)
                    }
                }
                historySection
                footer
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.exportTitle))
        .task {
            if vm.history.isEmpty { vm.loadHistory(env) }
            if availableSources.isEmpty {
                availableSources = ((try? env.catalog.sources()) ?? []).filter { $0.deletedAt == nil }
            }
            // A user who set "my display units" globally in Settings shouldn't see Export
            // silently revert to canonical/SI every time they open it (EASE-204/OPT-156).
            scope.unitProfile = env.profile.unitProfile
        }
        .onChange(of: vm.lastResults.last?.result.job.id) { _, newValue in
            guard newValue != nil else { return }
            let urls = vm.lastResults.flatMap { $0.result.fileURLs }
            guard !urls.isEmpty else { return }
            shareURLs = urls
            showShare = true
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(activityItems: shareURLs)
        }
        .sheet(isPresented: $showAllHistory) {
            allExportsSheet
        }
        .sheet(item: $inspectingItem) { item in
            historyDetailSheet(item)
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
                    selected: selectedFormats.contains(.csv)
                ) { toggleFormat(.csv) }
                ExportFormatCard(
                    title: "JSON",
                    subtitle: ExportCopy.formatJSONSubtitle,
                    icon: "curlybraces",
                    selected: selectedFormats.contains(.json)
                ) { toggleFormat(.json) }
            }
        }
    }

    /// Toggles a format in/out of the multi-select (both may be selected to produce both in one
    /// run); the last remaining format can't be deselected so there's always something to export.
    private func toggleFormat(_ format: ExportFormat) {
        if selectedFormats.contains(format) {
            guard selectedFormats.count > 1 else { return }
            selectedFormats.remove(format)
        } else {
            selectedFormats.insert(format)
        }
        UISelectionFeedbackGenerator().selectionChanged()
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
                        .disabled(!env.profile.sensitiveModulesEnabled)
                    if !env.profile.sensitiveModulesEnabled {
                        Text(ExportCopy.sensitiveModuleDisabledNote, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if scope.includeSensitive {
                        sensitiveNote
                    }
                    if !env.depth.showsPowerDetail {
                        Text(ExportCopy.casualIncludesNote, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scope.includeSensitive)
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

    // MARK: Sources (power)

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportCopy.sources))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    ForEach(availableSources) { source in
                        Button {
                            toggleSource(source)
                        } label: {
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
                        if source.id != availableSources.last?.id {
                            rowDivider
                        }
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
        if current.contains(source.id) {
            current.remove(source.id)
        } else {
            current.insert(source.id)
        }
        scope.sourceIds = current.count == availableSources.count ? nil : Array(current)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Date range

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportCopy.dateRange))
            ExportSegmented(
                options: ExportRange.allCases.map { (value: $0, label: env.s($0.label(env.format))) },
                selection: $range
            )
            if range == .custom {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    DatePicker(env.s(ExportCopy.customRangeStart), selection: $customStart, displayedComponents: .date)
                    DatePicker(env.s(ExportCopy.customRangeEnd), selection: $customEnd, displayedComponents: .date)
                }
                .font(BadanFont.body)
                .tint(BadanColor.primary)
            }
            if !env.depth.showsPowerDetail {
                Text(scope.unitProfile == .display ? ExportCopy.casualUnitsDisplay : ExportCopy.casualUnitsSource,
                     language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { unitNoteExpanded.toggle() }
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
            if unitNoteExpanded {
                Text(ExportCopy.unitNote, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Run

    /// A short repeat of the trust badge right at the commit point (UIUX-172) — by the time a
    /// cautious user has scrolled past format/scope/range, the top-of-screen badge is long
    /// off-screen.
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
        .disabled(vm.isRunning || selectedFormats.isEmpty)
        .opacity(vm.isRunning ? 0.75 : 1)
    }

    private func runExport() {
        var s = scope
        s.language = env.language
        if range == .custom {
            s.startDate = Calendar.current.startOfDay(for: customStart)
            s.endDate = customEnd
        } else {
            s.startDate = range.startDate(now: env.now())
            s.endDate = nil
        }
        vm.run(scope: s, formats: Array(selectedFormats), env: env)
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
                Button(action: runExport) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityHidden(true)
                        Text(ExportCopy.tryAgain, language: env.language)
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

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ExportCopy.history)) {
                if vm.history.count >= 20 {
                    Button(env.s(ExportCopy.seeAll)) { showAllHistory = true }
                        .font(BadanFont.link)
                        .foregroundStyle(BadanColor.primary)
                }
            }
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
                        ForEach(Array(vm.history.enumerated()), id: \.element.id) { index, item in
                            ExportHistoryRow(item: item) { urls in
                                shareURLs = urls
                                showShare = !urls.isEmpty
                            } onInspect: {
                                inspectingItem = item
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

    /// Full (non-paginated but much deeper) history list, so exports older than the default
    /// 20-item window stay reachable (EASE-208).
    private var allExportsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: BadanSpace.space3) {
                    ForEach(allHistoryItems) { item in
                        ExportHistoryRow(item: item) { urls in
                            shareURLs = urls
                            showShare = !urls.isEmpty
                            showAllHistory = false
                        } onInspect: {
                            showAllHistory = false
                            inspectingItem = item
                        }
                        rowDivider
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background.ignoresSafeArea())
            .navigationTitle(env.s(ExportCopy.history))
            .task {
                if allHistoryItems.isEmpty {
                    let jobs = (try? env.exportJobs.recent(limit: 500)) ?? []
                    allHistoryItems = ExportCenterViewModel.buildItems(from: jobs)
                }
            }
        }
    }

    /// Reconstructs the trust-cockpit detail view (checksums/manifest) for a past export from
    /// its persisted job, not only the most recently run one (UIUX-174).
    private func historyDetailSheet(_ item: ExportHistoryItem) -> some View {
        NavigationStack {
            ScrollView {
                ExportSuccessCard(
                    result: ExportRunner.ExportResult(job: item.job, fileURLs: item.fileURLs,
                                                       rowCount: item.job.rowCount ?? 0),
                    sortedMetricIds: item.job.manifest?.perMetricRowCounts.keys.sorted() ?? []
                ) {
                    shareURLs = item.fileURLs
                    showShare = !item.fileURLs.isEmpty
                } onRunAgain: {
                    let job = item.job
                    inspectingItem = nil
                    vm.run(scope: job.scope, formats: [job.format], env: env)
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background.ignoresSafeArea())
            .navigationTitle(env.s(ExportCopy.exportReady))
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
                        .minimumScaleFactor(0.7)
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
    let sortedMetricIds: [String]
    let onShare: () -> Void
    let onRunAgain: () -> Void

    @State private var copiedValue: String?

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

                // Checksums are only actionable when paired with an external verification tool,
                // same as the manifest detail below — gate both behind power depth (EASE-213)
                // instead of showing a wall of hex to every casual user.
                if env.depth.showsPowerDetail && !checksums.isEmpty {
                    rowDivider
                    Text(ExportCopy.checksums, language: env.language)
                        .font(BadanFont.caption.weight(.semibold))
                        .foregroundStyle(BadanColor.textSecondary)
                    Text(ExportCopy.checksumsExplainer, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(checksums.keys.sorted(), id: \.self) { name in
                        HStack(spacing: BadanSpace.space2) {
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(BadanColor.textPrimary)
                            Spacer(minLength: BadanSpace.space2)
                            copyableValue(shortHash(checksums[name] ?? ""), copying: checksums[name] ?? "")
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

                // Same scope+format the user just ran, one tap away — the screen already holds
                // everything needed to reproduce it (EASE-222).
                Button(action: onRunAgain) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityHidden(true)
                        Text(ExportCopy.exportAgain, language: env.language)
                    }
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A tap-to-copy value (checksum hash / export ID) — truncated display text stays readable
    /// while the full untruncated value goes to the pasteboard (EASE-214).
    private func copyableValue(_ display: String, copying full: String) -> some View {
        Button {
            copy(full)
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Text(display)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(BadanColor.textSecondary)
                Image(systemName: copiedValue == full ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        withAnimation(.easeInOut(duration: 0.15)) { copiedValue = value }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedValue == value {
                withAnimation(.easeInOut(duration: 0.15)) { copiedValue = nil }
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
            detailLine(ExportCopy.exportId, value: String(manifest.exportId.prefix(10)) + "…",
                       copyValue: manifest.exportId)

            if !manifest.perMetricRowCounts.isEmpty {
                Text(ExportCopy.rowsPerMetric, language: env.language)
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                    .padding(.top, BadanSpace.space1)
                ForEach(sortedMetricIds, id: \.self) { id in
                    HStack(spacing: BadanSpace.space2) {
                        Text(id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(BadanColor.textPrimary)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer(minLength: BadanSpace.space2)
                        Text(env.format.integer(manifest.perMetricRowCounts[id] ?? 0))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    private func detailLine(_ label: LocalizedString, value: String, copyValue: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            Text(label, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            if let copyValue {
                copyableValue(value, copying: copyValue)
            } else {
                Text(value)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func shortHash(_ hash: String) -> String {
        hash.isEmpty ? "—" : String(hash.prefix(12)) + "…"
    }

    /// Cached once per type rather than allocated fresh on every render (PERF-082); only the
    /// locale is mutated per call, which is cheap.
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

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }
}

// MARK: - History row

private struct ExportHistoryRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: ExportHistoryItem
    let onShare: ([URL]) -> Void
    let onInspect: () -> Void

    private var job: ExportJob { item.job }

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
                Text(scopeSummaryText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(dateText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                if item.fileURLs.isEmpty {
                    Text(ExportCopy.filesUnavailable, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            Spacer(minLength: BadanSpace.space2)
            if !item.fileURLs.isEmpty {
                Button {
                    onShare(item.fileURLs)
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
        .contentShape(Rectangle())
        .onTapGesture { onInspect() }
    }

    private var rowCountText: String {
        "\(env.format.integer(job.rowCount ?? 0)) \(env.s(ExportCopy.recordsInline))"
    }

    /// A compact "what was in this one" chip (e.g. "Raw+Derived · 30d") sourced from the job's
    /// own persisted scope, so two same-day exports are no longer indistinguishable (EASE-210).
    private var scopeSummaryText: String {
        var parts: [String] = []
        if job.scope.includeRaw { parts.append(env.s(ExportCopy.scopeRaw)) }
        if job.scope.includeDerived { parts.append(env.s(ExportCopy.scopeDerived)) }
        if job.scope.includeSuppressed { parts.append(env.s(ExportCopy.scopeSuppressed)) }
        if job.scope.includeSensitive { parts.append(env.s(ExportCopy.scopeSensitive)) }
        let category = parts.isEmpty ? env.s(ExportCopy.scopeNone) : parts.joined(separator: "+")

        let rangeLabel: String
        if let start = job.scope.startDate {
            let end = job.scope.endDate ?? job.createdAt
            let days = max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0, 0)
            let n = env.format.integer(days)
            rangeLabel = env.language == .ar ? "\(n)ي" : "\(n)d"
        } else {
            rangeLabel = env.s(ExportCopy.scopeAllTime)
        }
        return "\(category) · \(rangeLabel)"
    }

    /// Cached once per type rather than allocated fresh on every render (PERF-082); only the
    /// locale is mutated per call, which is cheap.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var dateText: String {
        Self.dateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateFormatter.string(from: job.createdAt)
    }
}
