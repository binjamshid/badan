import SwiftUI
import UniformTypeIdentifiers

private enum BackupStrings {
    static let backupHeader = LocalizedString(en: "Backup", ar: "النسخ الاحتياطي")
    static let restoreHeader = LocalizedString(en: "Restore", ar: "الاستعادة")
    static let backupBlurb = LocalizedString(
        en: "A backup is just an export: your complete data as files you keep. There's no BADAN "
            + "cloud — where the file goes is entirely your choice.",
        ar: "النسخة الاحتياطية هي التصدير نفسه: بياناتك كاملةً كملفات تحتفظ بها. لا توجد سحابة "
            + "لبدن — ووجهة الملف قرارك وحدك.")
    static let openExport = LocalizedString(en: "Export your data", ar: "تصدير بياناتك")
    static let restoreBlurb = LocalizedString(
        en: "Restoring reads a BADAN JSON backup back in. Records you already have are matched and "
            + "updated rather than duplicated, so restoring the same file twice is safe.",
        ar: "تقرأ الاستعادة نسخة JSON من بدن مجدداً. وتُطابَق السجلات الموجودة لديك وتُحدَّث بدل "
            + "تكرارها، لذا فاستعادة الملف نفسه مرتين آمنة.")
    static let chooseFile = LocalizedString(en: "Preview a backup file", ar: "معاينة ملف نسخة احتياطية")
    static let pickFailed = LocalizedString(en: "That file couldn't be opened. Try choosing it again.",
                                            ar: "تعذّر فتح ذلك الملف. حاول اختياره مجدداً.")
    static let restorePreviewBlurb = LocalizedString(
        en: "Pick a BADAN backup to check it and see exactly what it holds — records, saved "
            + "templates, and whether it's encrypted. BADAN verifies the file before showing "
            + "anything, and refuses one made by a newer version rather than importing it in part.",
        ar: "اختر نسخة احتياطية من بدن لفحصها ورؤية ما تحتويه تماماً — السجلات والقوالب المحفوظة "
            + "وما إذا كانت مشفّرة. يتحقق بدن من الملف قبل عرض أي شيء، ويرفض نسخة أنشأها إصدار أحدث "
            + "بدل استيرادها جزئياً.")
    static let automationHeader = LocalizedString(en: "Automate", ar: "الأتمتة")
    static let automationBlurb = LocalizedString(
        en: "Run an export by voice, or at a time you choose, through the Shortcuts app. iOS "
            + "decides whether a timed run fires — the guide is honest about what it can and "
            + "can't promise.",
        ar: "شغّل تصديراً بصوتك، أو في وقت تختاره، عبر تطبيق اختصارات. يقرّر iOS ما إذا كان "
            + "التشغيل المؤقّت سيعمل — والدليل صريح بشأن ما يمكن وما لا يمكن ضمانه.")
}

/// Settings -> Backup & restore.
///
/// Backup is export, which is real and complete. **Restore is not built yet** — the importer,
/// `import_batches` (a table reserved since migration v1 and never used), and the file picker are
/// the outstanding work, and this page says so plainly rather than showing a button that does
/// nothing. See `docs/MONETIZATION.md` and the audit's stub sweep: an inert control on a data page
/// is exactly the class of dishonesty this codebase keeps removing, and "Restore" that silently
/// no-ops would be the worst instance of it — the user would believe their data was coming back.
struct BackupRestoreSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env

    /// A picked backup file, wrapped so it can drive `.navigationDestination(item:)` (a bare `URL`
    /// isn't `Identifiable`).
    private struct PickedBackup: Identifiable, Hashable { let id = UUID(); let url: URL }
    @State private var importingBackup = false
    @State private var pickedBackup: PickedBackup?
    @State private var importError: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                backupSection
                automationSection
                restoreSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.backup.title))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pickedBackup) { picked in
            BackupRestorePreviewScreen(fileURL: picked.url)
        }
        // `.json` covers a plaintext backup; `.data` admits the `.badanenc` encrypted container,
        // which has no registered UTI of its own. Routes/sensitive files are never involved here —
        // a backup is one self-contained artifact.
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { pickedBackup = PickedBackup(url: url) }
            case .failure:
                importError = BackupStrings.pickFailed
            }
        }
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(BackupStrings.backupHeader))
            BadanCard {
                NavigationLink { ExportCenterScreen() } label: {
                    SettingsNavRowLabel(icon: "square.and.arrow.up", title: BackupStrings.openExport)
                }
                .buttonStyle(.plain)
            }
            LText(BackupStrings.backupBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// EPIC-19. The Shortcuts/Siri setup guide lives here because a timed export is, on iOS, a
    /// Shortcuts automation calling BADAN's export intent — automation of the very thing this
    /// screen already opens the Export Center for.
    private var automationSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(BackupStrings.automationHeader))
            BadanCard {
                NavigationLink { ShortcutsSetupGuideScreen() } label: {
                    SettingsNavRowLabel(icon: "clock.arrow.circlepath",
                                        title: IntentStrings.guideTitle)
                }
                .buttonStyle(.plain)
            }
            LText(BackupStrings.automationBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// EPIC-18 restore. Previewing a backup — reading it, verifying it, and showing its contents —
    /// is built and lives behind this button. Writing the records back into the store is a separate,
    /// destructive step that goes through the `import_batches` staged-import machinery (preview +
    /// batch undo), and that machinery is not wired on-device yet; `BackupRestorePreviewScreen`
    /// states so plainly rather than offering an apply button that would do nothing.
    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(BackupStrings.restoreHeader))
            LText(BackupStrings.restorePreviewBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            BadanCard {
                Button { importingBackup = true } label: {
                    SettingsNavRowLabel(icon: "doc.badge.arrow.up", title: BackupStrings.chooseFile)
                }
                .buttonStyle(.plain)
            }
            if let importError {
                LText(importError)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.critical)
            }
        }
    }
}
