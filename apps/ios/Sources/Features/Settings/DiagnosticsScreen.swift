import SwiftUI

// MARK: - Strings

private enum DiagnosticsStrings {
    static let title = LocalizedString(en: "Diagnostics", ar: "التشخيص")
    static let intro = LocalizedString(
        en: "Technical details about this install. Useful if something looks wrong and you want "
            + "to describe it accurately. Nothing here leaves your device unless you share it.",
        ar: "تفاصيل تقنية عن هذا التثبيت. مفيدة إن بدا شيء غير صحيح وأردت وصفه بدقة. "
            + "ولا يغادر أي شيء هنا جهازك ما لم تشاركه بنفسك.")
    static let app = LocalizedString(en: "App", ar: "التطبيق")
    static let storage = LocalizedString(en: "Storage", ar: "التخزين")
    static let sync = LocalizedString(en: "Sync", ar: "المزامنة")

    static let version = LocalizedString(en: "Version", ar: "الإصدار")
    static let language = LocalizedString(en: "Language", ar: "اللغة")
    static let depth = LocalizedString(en: "Detail level", ar: "مستوى التفصيل")
    static let schemaVersion = LocalizedString(en: "Database version", ar: "إصدار قاعدة البيانات")
    static let mainSize = LocalizedString(en: "Main database", ar: "قاعدة البيانات الرئيسية")
    static let sensitiveSize = LocalizedString(en: "Sensitive database", ar: "قاعدة البيانات الحساسة")
    static let storageMode = LocalizedString(en: "Storage mode", ar: "وضع التخزين")
    static let storageNormal = LocalizedString(en: "Normal (saved on this device)", ar: "عادي (محفوظ على هذا الجهاز)")
    static let storageTemporary = LocalizedString(
        en: "Temporary — nothing is being saved",
        ar: "مؤقت — لا يُحفَظ أي شيء")
    /// Read-back confirmation of the claim `docs/PRIVACY_POLICY.md` §3 makes unconditionally —
    /// see `Database.HardeningStatus` (ledger #20).
    static let backupProtection = LocalizedString(en: "Backup exclusion & protection", ar: "الاستثناء من النسخ الاحتياطي والحماية")
    static let backupProtectionConfirmed = LocalizedString(en: "Confirmed", ar: "مؤكَّد")
    static let backupProtectionNotConfirmed = LocalizedString(
        en: "Not confirmed on this device — data may be included in iCloud backup",
        ar: "غير مؤكَّد على هذا الجهاز — قد تُضمَّن البيانات في النسخة الاحتياطية على آي كلاود")
    static let connected = LocalizedString(en: "Apple Health", ar: "صحة آبل")
    static let connectedYes = LocalizedString(en: "Connected", ar: "متصل")
    static let connectedNo = LocalizedString(en: "Not connected", ar: "غير متصل")
    static let lastSync = LocalizedString(en: "Last sync attempt", ar: "آخر محاولة مزامنة")
    static let never = LocalizedString(en: "Not since this app opened", ar: "لم تحدث منذ فتح التطبيق")
    static let sampleData = LocalizedString(en: "Sample data", ar: "بيانات تجريبية")
    static let yes = LocalizedString(en: "Yes", ar: "نعم")
    static let no = LocalizedString(en: "No", ar: "لا")
    static let remindersCapped = LocalizedString(en: "Reminders not scheduled", ar: "تذكيرات غير مجدولة")

    static let copy = LocalizedString(en: "Copy diagnostics", ar: "نسخ التشخيص")
    static let copied = LocalizedString(en: "Copied", ar: "تم النسخ")
    static let shareHint = LocalizedString(
        en: "Copies the values above as text you can paste into a support message. It contains no "
            + "health readings — only the technical details shown here.",
        ar: "ينسخ القيم أعلاه كنص يمكنك لصقه في رسالة دعم. ولا يتضمّن أي قراءات صحية — "
            + "بل التفاصيل التقنية المعروضة هنا فقط.")
}

// MARK: - Report (pure)

/// The diagnostics report, as plain data.
///
/// (G2) BADAN is local-first and ships no crash or analytics SDK — a deliberate privacy decision
/// that also means a beta user's "it's not showing my sleep" is otherwise unanswerable: there is
/// no console to look at, no session to replay, and asking the user to describe their database is
/// absurd. This is the observability story that posture requires: the handful of facts that
/// actually explain the common failures (a store that fell back to temporary mode, a sync that
/// never ran, a schema behind the app, sample data mistaken for real data), gathered where the
/// user can read and share them.
///
/// Deliberately carries no health data — only the technical shape of the install — so sharing it
/// is a safe act rather than one the user has to weigh.
struct DiagnosticsReport: Equatable {
    var appVersion: String
    var deviceId: String
    var language: String
    var depth: String
    var schemaVersion: Int64
    var mainBytes: Int64
    var sensitiveBytes: Int64
    var isStorageFallback: Bool
    /// `nil` when hardening was never applicable (in-memory fallback); otherwise the read-back
    /// result of `Database.applyHardening` — whether the backup-exclusion and file-protection
    /// writes `docs/PRIVACY_POLICY.md` §3 promises actually took effect on this device.
    var isBackupHardened: Bool?
    var isHealthKitConnected: Bool
    var lastSyncAt: Date?
    var isSampleDataActive: Bool
    var remindersTruncatedCount: Int

    /// The shareable text. Fixed labels in English regardless of app language: this is pasted
    /// into a support conversation, and it has to be legible to whoever reads it there.
    func plainText(dateFormatter: DateFormatter) -> String {
        var lines: [String] = ["BADAN diagnostics"]
        lines.append("app_version: \(appVersion)")
        lines.append("device_id: \(deviceId)")
        lines.append("language: \(language)")
        lines.append("depth: \(depth)")
        lines.append("schema_version: \(schemaVersion)")
        lines.append("main_db_bytes: \(mainBytes)")
        lines.append("sensitive_db_bytes: \(sensitiveBytes)")
        lines.append("storage_mode: \(isStorageFallback ? "TEMPORARY (not persisting)" : "normal")")
        lines.append("backup_excluded_and_protected: \(isBackupHardened.map(String.init) ?? "n/a")")
        lines.append("healthkit_connected: \(isHealthKitConnected)")
        lines.append("last_sync_attempt: \(lastSyncAt.map { dateFormatter.string(from: $0) } ?? "none this session")")
        lines.append("sample_data_active: \(isSampleDataActive)")
        lines.append("reminders_dropped_by_os_cap: \(remindersTruncatedCount)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen

/// Settings → Diagnostics. Read-only; nothing here changes app state.
struct DiagnosticsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var report: DiagnosticsReport?
    @State private var copied = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                LText(DiagnosticsStrings.intro)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let report {
                    appSection(report)
                    storageSection(report)
                    syncSection(report)
                    copyButton(report)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(DiagnosticsStrings.title))
        .task { report = await Self.gather(env) }
    }

    // MARK: Sections

    private func appSection(_ report: DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(DiagnosticsStrings.app))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    row(DiagnosticsStrings.version, report.appVersion)
                    rowDivider
                    row(DiagnosticsStrings.language, report.language)
                    rowDivider
                    row(DiagnosticsStrings.depth, report.depth)
                }
            }
        }
    }

    private func storageSection(_ report: DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(DiagnosticsStrings.storage))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    // The one row here that can indicate something is actually wrong: a store that
                    // fell back to scratch/in-memory is losing everything on quit (EDGE-05), and
                    // "my data disappears" is exactly the report this explains.
                    row(DiagnosticsStrings.storageMode,
                        env.s(report.isStorageFallback ? DiagnosticsStrings.storageTemporary
                                                       : DiagnosticsStrings.storageNormal),
                        emphasised: report.isStorageFallback)
                    rowDivider
                    row(DiagnosticsStrings.schemaVersion, "\(report.schemaVersion)")
                    rowDivider
                    row(DiagnosticsStrings.mainSize, Self.formatBytes(report.mainBytes))
                    rowDivider
                    row(DiagnosticsStrings.sensitiveSize, Self.formatBytes(report.sensitiveBytes))
                    if let isBackupHardened = report.isBackupHardened {
                        rowDivider
                        // The one row here that can falsify docs/PRIVACY_POLICY.md §3's
                        // unconditional claim — emphasised only when the read-back actually
                        // disagrees with it (ledger #20).
                        row(DiagnosticsStrings.backupProtection,
                            env.s(isBackupHardened ? DiagnosticsStrings.backupProtectionConfirmed
                                                   : DiagnosticsStrings.backupProtectionNotConfirmed),
                            emphasised: !isBackupHardened)
                    }
                }
            }
        }
    }

    private func syncSection(_ report: DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(DiagnosticsStrings.sync))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    row(DiagnosticsStrings.connected,
                        env.s(report.isHealthKitConnected ? DiagnosticsStrings.connectedYes
                                                          : DiagnosticsStrings.connectedNo))
                    rowDivider
                    row(DiagnosticsStrings.lastSync,
                        report.lastSyncAt.map { Self.timestampFormatter.string(from: $0) }
                            ?? env.s(DiagnosticsStrings.never))
                    rowDivider
                    row(DiagnosticsStrings.sampleData,
                        env.s(report.isSampleDataActive ? DiagnosticsStrings.yes : DiagnosticsStrings.no))
                    if report.remindersTruncatedCount > 0 {
                        rowDivider
                        row(DiagnosticsStrings.remindersCapped, "\(report.remindersTruncatedCount)",
                            emphasised: true)
                    }
                }
            }
        }
    }

    private func copyButton(_ report: DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Button {
                UIPasteboard.general.string = report.plainText(dateFormatter: Self.timestampFormatter)
                copied = true
                // (A3) The pasteboard write is invisible and the label change is easy to miss.
                Announce.status(env.s(DiagnosticsStrings.copied))
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .accessibilityHidden(true)
                    LText(copied ? DiagnosticsStrings.copied : DiagnosticsStrings.copy)
                        .font(BadanFont.body.weight(.semibold))
                }
                .foregroundStyle(BadanColor.onPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: BadanSpace.touchMin)
                .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            LText(DiagnosticsStrings.shareHint)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Row primitives

    private func row(_ label: LocalizedString, _ value: String, emphasised: Bool = false) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            LText(label)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(emphasised ? BadanColor.outOfBand : BadanColor.textSecondary)
                .multilineTextAlignment(.trailing)
                // Sizes, versions and ids are LTR tokens even in Arabic — pinning matches the
                // deliberate LTR pins the export screen uses for hashes and filenames.
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Rectangle().fill(BadanColor.separator).frame(height: 1)
    }

    // MARK: Gathering

    /// Reads the report off the main actor — `diskUsage()` and the schema query both touch the
    /// filesystem/DB, which is exactly the kind of work `AppEnvironment`'s main-actor readers get
    /// criticised for doing inline.
    @MainActor
    static func gather(_ env: AppEnvironment) async -> DiagnosticsReport {
        let database = env.database
        let storage: (main: Int64, sensitive: Int64, schema: Int64) = await Task.detached {
            let sizes = (try? database.diskUsage()) ?? (main: 0, sensitive: 0)
            let schema = (try? database.main.query("PRAGMA user_version;").first?.int("user_version")) ?? 0
            return (sizes.main, sizes.sensitive, schema ?? 0)
        }.value

        return DiagnosticsReport(
            appVersion: env.appVersion,
            deviceId: env.deviceId,
            language: env.language.rawValue,
            depth: env.profile.depthPolicy.rawValue,
            schemaVersion: storage.schema,
            mainBytes: storage.main,
            sensitiveBytes: storage.sensitive,
            isStorageFallback: env.isStorageFallback,
            isBackupHardened: database.hardeningStatus?.isFullyHardened,
            isHealthKitConnected: env.isHealthKitConnected,
            lastSyncAt: env.lastSyncAt,
            isSampleDataActive: SeedController.isDemoDataActive,
            remindersTruncatedCount: env.remindersTruncatedCount)
    }

    /// Bytes as a short human string. Locale-independent on purpose — this value is copied into
    /// support text where a grouping separator would only confuse.
    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}
