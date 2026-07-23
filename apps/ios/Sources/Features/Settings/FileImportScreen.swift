import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum FileImportStrings {
    static let title = LocalizedString(en: "Import a file", ar: "استيراد ملف")
    static let intro = LocalizedString(
        en: "Bring workouts and readings into BADAN from a GPX, TCX, or CSV file — a route exported "
            + "from another app, a Garmin activity, or your own spreadsheet of measurements.",
        ar: "استورد التمارين والقراءات إلى بدن من ملف GPX أو TCX أو CSV — مسار مُصدَّر من تطبيق آخر، "
            + "أو نشاط من Garmin، أو جدول بياناتك الخاص بالقياسات.")
    /// States the limit as well as the guarantee, matching `AHImportStrings.honesty`'s own reasoning:
    /// re-importing the identical file never duplicates it, but this codebase's cross-source dedup is
    /// per-night sleep and workout-vs-manual only — an imported file overlapping a live-synced window
    /// for the SAME reading can land as a second copy. Promising blanket de-duplication would be a
    /// claim the code cannot keep.
    static let honesty = LocalizedString(
        en: "Importing the same file again never duplicates it, and an import is one tap to undo. FIT "
            + "files (Garmin's binary format) aren't supported yet.",
        ar: "إعادة استيراد الملف نفسه لا تُكرّره أبداً، ويمكن التراجع عن الاستيراد بضغطة واحدة. ملفات "
            + "FIT (صيغة Garmin الثنائية) غير مدعومة بعد.")
    static let formatLabel = LocalizedString(en: "Format", ar: "الصيغة")
    static let chooseFile = LocalizedString(en: "Choose a file", ar: "اختر ملفاً")
    static let importing = LocalizedString(en: "Importing…", ar: "جارٍ الاستيراد…")
    static let doneTitle = LocalizedString(en: "Import complete", ar: "اكتمل الاستيراد")
    static let nothingNew = LocalizedString(
        en: "Everything in this file was already in BADAN — nothing was duplicated.",
        ar: "كل ما في هذا الملف كان موجوداً في بدن — ولم يتكرّر شيء.")
    static let undo = LocalizedString(en: "Undo this import", ar: "التراجع عن هذا الاستيراد")
    static let recentHeader = LocalizedString(en: "Recent imports", ar: "الاستيرادات الأخيرة")
    static let noneYet = LocalizedString(en: "No imports yet for this format.", ar: "لا توجد استيرادات بعد لهذه الصيغة.")
    static let undoneBadge = LocalizedString(en: "Undone", ar: "تم التراجع")
    static let undoneNote = LocalizedString(
        en: "This import was undone — its data is no longer in BADAN. Import the same file again to bring it back.",
        ar: "تم التراجع عن هذا الاستيراد — لم تعد بياناته في بدن. استورد الملف نفسه مرة أخرى لاستعادتها.")

    static let errCannotRead = LocalizedString(
        en: "That file couldn't be opened. Try choosing it again.",
        ar: "تعذّر فتح هذا الملف. حاول اختياره مجدداً.")
    static let errMalformed = LocalizedString(
        en: "That file couldn't be read — it may be damaged or not actually in this format.",
        ar: "تعذّرت قراءة هذا الملف — قد يكون تالفاً أو ليس بهذه الصيغة فعلاً.")
    static let errColumns = LocalizedString(
        en: "That CSV is missing required columns: metric_id, value, unit, measured_at, tz.",
        ar: "يفتقد ملف CSV هذا إلى أعمدة مطلوبة: metric_id و value و unit و measured_at و tz.")
    static let errEmpty = LocalizedString(en: "That file has no rows to import.", ar: "لا يحتوي هذا الملف على صفوف لاستيرادها.")
    static let errGeneric = LocalizedString(en: "The import couldn't finish. Please try again.",
                                            ar: "تعذّر إكمال الاستيراد. يرجى المحاولة مجدداً.")

    static let samples = LocalizedString(en: "readings", ar: "قراءات")
    static let workouts = LocalizedString(en: "workouts", ar: "تمارين")
    static let routes = LocalizedString(en: "routes", ar: "مسارات")
}

private extension FileImportFormat {
    var displayName: LocalizedString {
        switch self {
        case .gpx: return LocalizedString(en: "GPX", ar: "GPX")
        case .tcx: return LocalizedString(en: "TCX", ar: "TCX")
        case .csv: return LocalizedString(en: "CSV", ar: "CSV")
        }
    }

    /// GPX/TCX have no system-registered `UTType` (they are plain XML with a vendor-specific
    /// extension), so — matching `AppleHealthImportScreen`'s own `[.zip, .xml, .data]` fallback —
    /// `.xml`/`.data` admit whatever content type a file provider actually hands over for them.
    var contentTypes: [UTType] {
        switch self {
        case .gpx, .tcx: return [.xml, .data]
        case .csv: return [.commaSeparatedText, .plainText, .data]
        }
    }
}

/// Settings → Import a file (EPIC-43 ACC-005). One shared screen for GPX/TCX/CSV, parametrized
/// over which format's `.fileImporter` picker and parser+sourceKind is active — the same
/// `@Observable` model/`Phase`/undo shape `AppleHealthImportScreen` establishes, not a third copy
/// of that UI built per format.
struct FileImportScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var format: FileImportFormat = .gpx
    @State private var model = FileImportModel()
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                intro
                formatPicker
                statusSection
                recentSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(FileImportStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: format.contentTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.run(url: url, format: format, importer: env.makeFileImporter(),
                          batches: env.importBatches) { env.bumpDataGeneration() }
            }
        }
        .task(id: format) { model.load(env.importBatches, format: format) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            LText(FileImportStrings.intro)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LText(FileImportStrings.honesty)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formatPicker: some View {
        Picker(env.s(FileImportStrings.formatLabel), selection: $format) {
            ForEach(FileImportFormat.allCases, id: \.self) { f in
                Text(env.s(f.displayName)).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isRunning)
    }

    @ViewBuilder private var statusSection: some View {
        switch model.phase {
        case .idle:
            BadanCard {
                Button { picking = true } label: {
                    SettingsNavRowLabel(icon: "square.and.arrow.down", title: FileImportStrings.chooseFile)
                }
                .buttonStyle(.plain)
            }
        case .running:
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    ProgressView()
                    LText(FileImportStrings.importing).font(BadanFont.body)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .done(let batchId, let counts):
            doneCard(batchId: batchId, counts: counts)
        case .failed(let message):
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                BadanCard {
                    Button { picking = true } label: {
                        SettingsNavRowLabel(icon: "square.and.arrow.down", title: FileImportStrings.chooseFile)
                    }
                    .buttonStyle(.plain)
                }
                LText(message).font(BadanFont.caption).foregroundStyle(BadanColor.critical)
            }
        }
    }

    private func doneCard(batchId: String, counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(BadanColor.primary)
                        LText(FileImportStrings.doneTitle).font(BadanFont.body)
                    }
                    Text(Self.summaryLine(counts: counts, language: env.language))
                        .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            BadanCard {
                Button(role: .destructive) {
                    model.undo(batchId: batchId, format: format, importer: env.makeFileImporter(),
                              batches: env.importBatches) { env.bumpDataGeneration() }
                } label: {
                    SettingsNavRowLabel(icon: "arrow.uturn.backward", title: FileImportStrings.undo)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(FileImportStrings.recentHeader, language: env.language)
            if model.recent.isEmpty {
                LText(FileImportStrings.noneYet).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
            } else {
                ForEach(model.recent, id: \.id) { batch in
                    BadanCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: BadanSpace.space2) {
                                    Text(batch.fileName ?? batch.sourceKind)
                                        .font(BadanFont.body).foregroundStyle(BadanColor.textPrimary)
                                        .lineLimit(1)
                                    if batch.isUndone {
                                        LText(FileImportStrings.undoneBadge)
                                            .font(BadanFont.caption)
                                            .foregroundStyle(BadanColor.textSecondary)
                                    }
                                }
                                Text(Self.summaryLine(counts: batch.decodedCounts, language: env.language))
                                    .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                                if batch.isUndone {
                                    LText(FileImportStrings.undoneNote)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if batch.isTerminal {
                                Button(role: .destructive) {
                                    model.undo(batchId: batch.id, format: format, importer: env.makeFileImporter(),
                                              batches: env.importBatches) { env.bumpDataGeneration() }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .foregroundStyle(BadanColor.critical)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(env.s(FileImportStrings.undo))
                            }
                        }
                    }
                }
            }
        }
    }

    /// "12 readings · 2 workouts · 1 route", built from the row counts `FileImporter` checkpoints.
    /// A run that wrote nothing is two different facts, exactly as `AppleHealthImportScreen
    /// .summaryLine` distinguishes them: an already-imported file (counts present, all zero) says so
    /// in words, while a run recording no counts at all falls back to a dash.
    static func summaryLine(counts: [String: Int], language: AppLanguage) -> String {
        var parts: [String] = []
        if let s = counts["samples"], s > 0 { parts.append("\(s) " + FileImportStrings.samples.resolved(language)) }
        if let w = counts["workouts"], w > 0 { parts.append("\(w) " + FileImportStrings.workouts.resolved(language)) }
        if let r = counts["routes"], r > 0 { parts.append("\(r) " + FileImportStrings.routes.resolved(language)) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return counts.isEmpty ? "—" : FileImportStrings.nothingNew.resolved(language)
    }
}

/// Drives one file import off the main actor and mirrors its progress/result back onto the main
/// actor for the view — the same shape `AppleHealthImportModel` establishes, generalized over
/// `FileImportFormat` since one model now serves all three.
@MainActor
@Observable
final class FileImportModel {
    enum Phase {
        case idle
        case running
        case done(batchId: String, counts: [String: Int])
        case failed(LocalizedString)
    }

    var phase: Phase = .idle
    var recent: [ImportBatch] = []
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { return true }; return false }

    func load(_ batches: ImportBatchRepository, format: FileImportFormat) {
        recent = ((try? batches.all()) ?? []).filter { $0.sourceKind == format.sourceKind }
    }

    func run(url: URL, format: FileImportFormat, importer: FileImporter, batches: ImportBatchRepository,
             onFinished: @escaping () -> Void) {
        phase = .running
        // Mirrors `AppleHealthImportModel.run`'s background-task assertion: these files are far
        // smaller than an Apple Health archive, but the same reasoning applies — hold a background
        // assertion for the run so backgrounding mid-import doesn't suspend it the instant the app
        // backgrounds. A local twin rather than a shared type, matching that model's own comment on
        // why its assertion isn't shared with the background substrate's.
        let assertion = ImportBackgroundAssertion()
        assertion.begin()
        task = Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try importer.importFile(format: format, fileURL: url, fileName: url.lastPathComponent)
                await MainActor.run {
                    self.phase = .done(batchId: result.batchId, counts: result.counts)
                    self.load(batches, format: format)
                    assertion.end()
                    onFinished()
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(Self.message(for: error))
                    self.load(batches, format: format)
                    assertion.end()
                }
            }
        }
    }

    func undo(batchId: String, format: FileImportFormat, importer: FileImporter,
             batches: ImportBatchRepository, onFinished: @escaping () -> Void) {
        task = Task.detached(priority: .userInitiated) {
            _ = try? importer.undo(batchId: batchId)
            await MainActor.run {
                if case .done(let done, _) = self.phase, done == batchId { self.phase = .idle }
                self.load(batches, format: format)
                onFinished()
            }
        }
    }

    @MainActor
    final class ImportBackgroundAssertion {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        func begin() {
            guard identifier == .invalid else { return }
            identifier = UIApplication.shared.beginBackgroundTask(withName: "file-import") { [weak self] in
                self?.end()
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    static func message(for error: Error) -> LocalizedString {
        switch error {
        case FileImportError.cannotReadFile: return FileImportStrings.errCannotRead
        case FileImportError.malformed: return FileImportStrings.errMalformed
        case FileImportError.missingColumns: return FileImportStrings.errColumns
        case FileImportError.emptyFile: return FileImportStrings.errEmpty
        default: return FileImportStrings.errGeneric
        }
    }
}
