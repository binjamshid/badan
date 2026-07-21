import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AHImportStrings {
    static let title = LocalizedString(en: "Apple Health import", ar: "استيراد صحة Apple")
    static let intro = LocalizedString(
        en: "Bring your Apple Health history into BADAN from an export. In the Health app, tap your "
            + "photo, then \"Export All Health Data\" — you'll get an export.zip you can share to BADAN here.",
        ar: "استورد سجل صحة Apple إلى بدن من ملف تصدير. في تطبيق الصحة، اضغط صورتك ثم \"تصدير جميع "
            + "البيانات الصحية\" — ستحصل على ملف export.zip يمكنك مشاركته مع بدن هنا.")
    /// Deliberately states the limit as well as the guarantee, because they are different facts and
    /// `AppleHealthArchiveImporter` only delivers one of them universally: re-importing the same
    /// archive is always a no-op, and sleep reconciles against live data per night, but Apple's
    /// export carries no per-sample identity, so an ordinary reading from a window live sync already
    /// covers can land as a second row. Promising blanket de-duplication here would be the kind of
    /// claim the code cannot keep.
    static let honesty = LocalizedString(
        en: "Importing the same export again never duplicates it, and sleep is reconciled with your "
            + "live data night by night. Other readings from a period your live sync already covers "
            + "can land as a second copy, so this works best for history older than your synced "
            + "data. An import is one tap to undo.",
        ar: "إعادة استيراد الملف نفسه لا تُكرّره أبداً، ويُوفَّق النوم مع بياناتك المباشرة ليلةً بليلة. "
            + "أما القراءات الأخرى من فترة تغطيها مزامنتك المباشرة فقد تُسجَّل نسخة ثانية منها، لذا "
            + "هذا أنسب للسجل الأقدم من بياناتك المتزامنة. ويمكن التراجع عن الاستيراد بضغطة واحدة.")
    static let chooseFile = LocalizedString(en: "Choose an export file", ar: "اختر ملف تصدير")
    static let importing = LocalizedString(en: "Importing…", ar: "جارٍ الاستيراد…")
    static let recordsRead = LocalizedString(en: "{n} records read", ar: "تمت قراءة {n} سجل")
    /// Shown only while an import is running, because that is when it is actionable — and because
    /// it is the honest description of what the app can promise: iOS grants a backgrounded app a
    /// limited grace period, not an open-ended job (`AppleHealthImportModel.run`).
    /// "Choose the file again and it finishes" — not "it resumes from where it stopped". The resume
    /// model re-reads the archive from the beginning and relies on every write being idempotent
    /// (`ImportBatchRepository`'s type doc), so a claim that it picks up mid-file would describe
    /// something the importer does not do. What the user is promised is the outcome: it completes,
    /// and nothing already imported is written twice.
    static let keepOpen = LocalizedString(
        en: "A big export takes a while. Keep BADAN open if you can — if the import stops early, "
            + "choose the same file again and it will finish, without importing anything twice.",
        ar: "يستغرق ملف التصدير الكبير بعض الوقت. أبقِ بدن مفتوحاً إن أمكن — وإذا توقّف الاستيراد "
            + "مبكراً، فاختر الملف نفسه مرة أخرى ليكتمل، دون أن يُستورد شيء مرتين.")
    static let doneTitle = LocalizedString(en: "Import complete", ar: "اكتمل الاستيراد")
    /// The honest result of importing an archive BADAN already holds in full: not an error, not a
    /// blank line — a statement that the matching worked.
    static let nothingNew = LocalizedString(
        en: "Everything in this export was already in BADAN — nothing was duplicated.",
        ar: "كل ما في هذا التصدير كان موجوداً في بدن — ولم يتكرّر شيء.")
    static let undo = LocalizedString(en: "Undo this import", ar: "التراجع عن هذا الاستيراد")
    static let recentHeader = LocalizedString(en: "Recent imports", ar: "الاستيرادات الأخيرة")
    static let noneYet = LocalizedString(en: "No imports yet.", ar: "لا توجد استيرادات بعد.")
    /// An undone import keeps its row in this list — the file was imported, and the history of that
    /// is worth keeping — so the row has to say plainly that its data is no longer in BADAN.
    /// Without this line the counts beside it ("1,240 readings") would read as data still present.
    /// It also states the one thing a user is most likely to wonder next: importing the file again
    /// brings it all back.
    static let undoneBadge = LocalizedString(en: "Undone", ar: "تم التراجع")
    static let undoneNote = LocalizedString(
        en: "This import was undone — its data is no longer in BADAN. Import the same file again to bring it back.",
        ar: "تم التراجع عن هذا الاستيراد — لم تعد بياناته في بدن. استورد الملف نفسه مرة أخرى لاستعادتها.")

    static let errNoXML = LocalizedString(
        en: "That file doesn't contain an Apple Health export. Choose the export.zip from the Health app.",
        ar: "لا يحتوي هذا الملف على تصدير صحة Apple. اختر ملف export.zip من تطبيق الصحة.")
    static let errMalformed = LocalizedString(
        en: "That export couldn't be read — it may be incomplete. Try exporting again from the Health app.",
        ar: "تعذّرت قراءة هذا التصدير — قد يكون غير مكتمل. حاول التصدير مجدداً من تطبيق الصحة.")
    static let errGeneric = LocalizedString(en: "The import couldn't finish. Please try again.",
                                            ar: "تعذّر إكمال الاستيراد. يرجى المحاولة مجدداً.")

    static let samples = LocalizedString(en: "readings", ar: "قراءات")
    static let intervals = LocalizedString(en: "daily values", ar: "قيم يومية")
    static let sessions = LocalizedString(en: "sleep & workouts", ar: "نوم وتمارين")
}

/// Settings → Apple Health import (plan §19). A real import surface, not a stub: it routes the
/// picked archive through the same ingestion pipeline as live sync (deduped, provenanced), shows
/// live progress, and lists past imports each with a one-tap undo backed by `import_batches`.
struct AppleHealthImportScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = AppleHealthImportModel()
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                intro
                statusSection
                recentSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(AHImportStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        // `.zip` is the export archive; `.xml` admits an already-extracted `export.xml`; `.data`
        // is the fallback for a `.zip` a provider hands over without a registered content type.
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .xml, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.run(url: url, importer: env.makeAppleHealthImporter(),
                          batches: env.importBatches) { env.bumpDataGeneration() }
            }
        }
        .task { model.load(env.importBatches) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            LText(AHImportStrings.intro)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LText(AHImportStrings.honesty)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch model.phase {
        case .idle:
            BadanCard {
                Button { picking = true } label: {
                    SettingsNavRowLabel(icon: "square.and.arrow.down", title: AHImportStrings.chooseFile)
                }
                .buttonStyle(.plain)
            }
        case .running(let processed, _):
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                BadanCard {
                    HStack(spacing: BadanSpace.space3) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            LText(AHImportStrings.importing).font(BadanFont.body)
                            Text(env.s(AHImportStrings.recordsRead.filling(["n": "\(processed)"])))
                                .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LText(AHImportStrings.keepOpen)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done(let batchId, let counts):
            doneCard(batchId: batchId, counts: counts)
        case .failed(let message):
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                BadanCard {
                    Button { picking = true } label: {
                        SettingsNavRowLabel(icon: "square.and.arrow.down", title: AHImportStrings.chooseFile)
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
                        LText(AHImportStrings.doneTitle).font(BadanFont.body)
                    }
                    Text(Self.summaryLine(counts: counts, language: env.language))
                        .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            BadanCard {
                Button(role: .destructive) {
                    model.undo(batchId: batchId, importer: env.makeAppleHealthImporter(),
                               batches: env.importBatches) { env.bumpDataGeneration() }
                } label: {
                    SettingsNavRowLabel(icon: "arrow.uturn.backward", title: AHImportStrings.undo)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(AHImportStrings.recentHeader, language: env.language)
            if model.recent.isEmpty {
                LText(AHImportStrings.noneYet).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
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
                                        LText(AHImportStrings.undoneBadge)
                                            .font(BadanFont.caption)
                                            .foregroundStyle(BadanColor.textSecondary)
                                    }
                                }
                                Text(Self.summaryLine(counts: batch.decodedCounts, language: env.language))
                                    .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                                if batch.isUndone {
                                    LText(AHImportStrings.undoneNote)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if batch.isTerminal {
                                Button(role: .destructive) {
                                    model.undo(batchId: batch.id, importer: env.makeAppleHealthImporter(),
                                               batches: env.importBatches) { env.bumpDataGeneration() }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .foregroundStyle(BadanColor.critical)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(env.s(AHImportStrings.undo))
                            }
                        }
                    }
                }
            }
        }
    }

    /// "1,240 readings · 30 daily values · 12 sleep & workouts", built from the row counts. Sleep
    /// and workout rows share the `sessions` table, so they are summed under one honest label.
    ///
    /// A run that wrote nothing is two different facts, and they get two different lines: an
    /// archive whose every row BADAN already held (counts present, all zero — the ordinary result
    /// of re-importing) says so in words, while a run that recorded no counts at all falls back to
    /// a dash rather than claiming a match that was never attempted.
    static func summaryLine(counts: [String: Int], language: AppLanguage) -> String {
        let sessions = (counts["sessions"] ?? 0) + (counts["workouts"] ?? 0)
        var parts: [String] = []
        if let s = counts["samples"], s > 0 { parts.append("\(s) " + AHImportStrings.samples.resolved(language)) }
        if let i = counts["intervals"], i > 0 { parts.append("\(i) " + AHImportStrings.intervals.resolved(language)) }
        if sessions > 0 { parts.append("\(sessions) " + AHImportStrings.sessions.resolved(language)) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return counts.isEmpty ? "—" : AHImportStrings.nothingNew.resolved(language)
    }
}

/// Drives one import off the main actor and mirrors its progress/result back onto the main actor
/// for the view. Kept as an `@Observable` model (not `@State` scalars) so the escaping progress
/// closure has a stable object to publish into.
@MainActor
@Observable
final class AppleHealthImportModel {
    enum Phase {
        case idle
        case running(processed: Int, counts: [String: Int])
        case done(batchId: String, counts: [String: Int])
        case failed(LocalizedString)
    }

    var phase: Phase = .idle
    var recent: [ImportBatch] = []
    private var task: Task<Void, Never>?

    func load(_ batches: ImportBatchRepository) {
        recent = (try? batches.all()) ?? []
    }

    func run(url: URL, importer: AppleHealthArchiveImporter, batches: ImportBatchRepository,
             onFinished: @escaping () -> Void) {
        phase = .running(processed: 0, counts: [:])
        // Hold a UIKit background-task assertion for the run, the same way `AssertedWorkDispatcher`
        // does for background ingestion, so leaving BADAN mid-import does not suspend it the
        // instant the app backgrounds. This is the OS's finite grace period, not an open-ended
        // background job — the copy on screen says so. If it expires the process may be killed
        // mid-import; nothing is corrupted and nothing is double-written, because each flush
        // commits in its own SQLite transaction and every upsert is keyed by upstream identity:
        // the batch simply stays `running` and re-picking the file resumes it.
        let assertion = ImportBackgroundAssertion()
        assertion.begin()
        task = Task.detached(priority: .userInitiated) {
            // The picked file lives outside the app sandbox; hold its security scope for the whole
            // import (the zip is read/streamed during extraction).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try importer.importArchive(
                    zipURL: url, fileName: url.lastPathComponent,
                    progress: { p in
                        Task { @MainActor in self.publishProgress(p) }
                    })
                await MainActor.run {
                    self.phase = .done(batchId: result.batchId, counts: result.counts)
                    self.load(batches)
                    assertion.end()
                    onFinished()
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(Self.message(for: error))
                    self.load(batches)
                    assertion.end()
                }
            }
        }
    }

    /// Apply one progress tick, but only while the run is still in flight.
    ///
    /// The guard is load-bearing, not defensive noise: each tick is delivered by hopping to the
    /// main actor from the import's own queue, and the importer emits its last ticks immediately
    /// before returning. Without the check, a tick enqueued just before the result could be applied
    /// just after it and overwrite `.done`/`.failed` with `.running` — the import would be finished
    /// and undoable while the screen showed a spinner that never stopped.
    func publishProgress(_ p: AppleHealthImportProgress) {
        guard case .running = phase else { return }
        phase = .running(processed: p.recordsProcessed, counts: p.counts)
    }

    func undo(batchId: String, importer: AppleHealthArchiveImporter, batches: ImportBatchRepository,
              onFinished: @escaping () -> Void) {
        task = Task.detached(priority: .userInitiated) {
            _ = try? importer.undo(batchId: batchId)
            await MainActor.run {
                if case .done(let done, _) = self.phase, done == batchId { self.phase = .idle }
                self.load(batches)
                onFinished()
            }
        }
    }

    /// Main-actor box for the import's `UIBackgroundTaskIdentifier`, so the expiration handler and
    /// the finished path each release it exactly once. A local twin of the one
    /// `AssertedWorkDispatcher` keeps private to the background substrate — duplicated rather than
    /// shared because the two have different owners and the substrate's is not part of its API.
    @MainActor
    final class ImportBackgroundAssertion {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        func begin() {
            guard identifier == .invalid else { return }
            identifier = UIApplication.shared.beginBackgroundTask(withName: "apple-health-import") { [weak self] in
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
        case AppleHealthImportError.noExportXML: return AHImportStrings.errNoXML
        case AppleHealthImportError.malformedXML, AppleHealthImportError.cannotReadXML: return AHImportStrings.errMalformed
        default: return AHImportStrings.errGeneric
        }
    }
}
