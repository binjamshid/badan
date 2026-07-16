import SwiftUI

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
    static let chooseFile = LocalizedString(en: "Choose a backup file", ar: "اختر ملف نسخة احتياطية")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                backupSection
                restoreSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.backup.title))
        .navigationBarTitleDisplayMode(.inline)
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

    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(BackupStrings.restoreHeader))
            LText(BackupStrings.restoreBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            UnbuiltFeatureNotice(feature: BackupStrings.chooseFile)
        }
    }
}
