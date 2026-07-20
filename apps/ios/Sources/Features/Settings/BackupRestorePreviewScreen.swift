import SwiftUI

/// EPIC-18 — the restore *preview* (plan §12 EPIC-18: "preview before commit").
///
/// This screen reads a backup file the user picked, verifies it (per-file SHA-256, schema version,
/// encryption), and shows exactly what it contains before anything is written — the honest,
/// inspectable half of restore. It deliberately exposes **no apply button**: writing the staged
/// records back into the store is a destructive step that goes through the `import_batches` machinery
/// (batch preview + undo), and that machinery is not wired on-device yet. Rather than show a control
/// that would silently do nothing — the exact defect this codebase keeps deleting — the screen states
/// the true thing: preview and verification work today; writing back does not.
///
/// The sensitive-namespace toggle appears only when the backup actually carries meds/symptoms (I7),
/// and even then it is presented as what the eventual restore *will* ask — the consent gate is real
/// in `BackupBundle.plan`, re-asked at restore time (§12 EPIC-18 requirement 5), and this screen
/// surfaces the choice without pretending to act on it.
struct BackupRestorePreviewScreen: View {
    @Environment(AppEnvironment.self) private var env
    let fileURL: URL

    @State private var phase: Phase = .loading
    @State private var passphrase: String = ""
    @State private var includeSensitive = false

    private enum Phase {
        case loading
        /// The bytes are an encrypted container; we need a passphrase before we can read anything.
        case locked(wrongAttempt: Bool)
        case loaded(BackupBundle.RestorePreview)
        case failed(LocalizedString)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, BadanSpace.space7)
                case .locked(let wrongAttempt):
                    lockedView(wrongAttempt: wrongAttempt)
                case .loaded(let preview):
                    loadedView(preview)
                case .failed(let message):
                    failedView(message)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Strings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { load(passphrase: nil) }
    }

    // MARK: - States

    private func lockedView(wrongAttempt: Bool) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Strings.encryptedHeader))
            LText(Strings.encryptedBlurb)
                .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SecureField(env.s(Strings.passphraseField), text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    if wrongAttempt {
                        LText(Strings.wrongPassphrase)
                            .font(BadanFont.caption).foregroundStyle(BadanColor.critical)
                    }
                    Button {
                        phase = .loading
                        load(passphrase: passphrase)
                    } label: {
                        Text(env.s(Strings.unlock))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
                }
            }
        }
    }

    private func loadedView(_ preview: BackupBundle.RestorePreview) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            originCard(preview)
            contentsCard(preview)
            if preview.sensitivePresent { sensitiveCard }
            applyNotice
        }
    }

    private func originCard(_ preview: BackupBundle.RestorePreview) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Strings.aboutHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    infoRow(env.s(Strings.createdAt), preview.createdAt)
                    infoRow(env.s(Strings.origin), "\(preview.originPlatform) · \(preview.originAppVersion)")
                    infoRow(env.s(Strings.encryption),
                            env.s(preview.encrypted ? Strings.encrypted : Strings.plaintext))
                    infoRow(env.s(Strings.schemaVersion), preview.schemaVersion)
                }
            }
        }
    }

    private func contentsCard(_ preview: BackupBundle.RestorePreview) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Strings.contentsHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    let rows = Self.namespaceLabels.compactMap { key, label -> (String, Int)? in
                        let count = preview.namespaceCounts[key] ?? 0
                        return count > 0 ? (env.s(label), count) : nil
                    }
                    if rows.isEmpty {
                        LText(Strings.noRecords)
                            .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                    } else {
                        ForEach(rows, id: \.0) { label, count in
                            infoRow(label, env.format.integer(count))
                        }
                    }
                    let templates = preview.configCounts["export_templates"] ?? 0
                    if templates > 0 {
                        infoRow(env.s(Strings.templates), env.format.integer(templates))
                    }
                }
            }
        }
    }

    private var sensitiveCard: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Strings.sensitiveHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    Toggle(isOn: $includeSensitive) {
                        LText(Strings.sensitiveToggle).font(BadanFont.body)
                    }
                    .tint(BadanColor.primary)
                    LText(Strings.sensitiveBlurb)
                        .font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The honest statement that inspection is built and writing-back is not — see the type doc.
    private var applyNotice: some View {
        UnbuiltFeatureNotice(feature: Strings.applyFeature)
    }

    private func failedView(_ message: LocalizedString) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(BadanColor.critical).accessibilityHidden(true)
            LText(message)
                .font(BadanFont.body).foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BadanSpace.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space3)
            Text(value).font(BadanFont.body).foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Load

    /// Reads and parses the picked file. A `nil` passphrase is the first attempt; an encrypted
    /// container with no passphrase surfaces the `locked` state rather than an error, so the user is
    /// asked rather than told "wrong passphrase" before they typed one.
    private func load(passphrase: String?) {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: fileURL) else {
            phase = .failed(Strings.unreadable)
            return
        }
        if BackupBundle.isEncryptedContainer(data), (passphrase ?? "").isEmpty {
            phase = .locked(wrongAttempt: false)
            return
        }
        do {
            let bundle = try BackupBundle.parse(data, passphrase: passphrase)
            phase = .loaded(BackupBundle.preview(bundle))
        } catch let error as BackupBundle.RestoreError {
            switch error {
            case .encrypted:
                // A wrong passphrase or an altered container — both land here (GCM cannot tell them
                // apart). Re-prompt rather than dead-end.
                phase = .locked(wrongAttempt: true)
            case .schemaTooNew:
                phase = .failed(Strings.schemaTooNew)
            case .checksumMismatch:
                phase = .failed(Strings.checksumMismatch)
            case .kdfCostTooHigh:
                phase = .failed(Strings.kdfCostTooHigh)
            case .notABackup:
                phase = .failed(Strings.notABackup)
            case .malformed:
                phase = .failed(Strings.malformed)
            }
        } catch {
            phase = .failed(Strings.malformed)
        }
    }

    // MARK: - Strings

    private static let namespaceLabels: [(String, LocalizedString)] = [
        ("raw_samples", LocalizedString(en: "Measurements", ar: "القياسات")),
        ("interval_records", LocalizedString(en: "Daily aggregates", ar: "التجميعات اليومية")),
        ("sessions", LocalizedString(en: "Sleep sessions", ar: "جلسات النوم")),
        ("workouts", LocalizedString(en: "Workouts", ar: "التمارين")),
        ("derived_values", LocalizedString(en: "Computed values", ar: "القيم المحسوبة")),
        ("baselines", LocalizedString(en: "Baselines", ar: "خطوط الأساس")),
        ("logs.symptoms", LocalizedString(en: "Symptom logs", ar: "سجلات الأعراض")),
        ("logs.adherence", LocalizedString(en: "Medication logs", ar: "سجلات الأدوية")),
        ("logs.nutrition", LocalizedString(en: "Nutrition logs", ar: "سجلات التغذية"))
    ]

    private enum Strings {
        static let title = LocalizedString(en: "Backup preview", ar: "معاينة النسخة الاحتياطية")
        static let aboutHeader = LocalizedString(en: "About this backup", ar: "عن هذه النسخة")
        static let contentsHeader = LocalizedString(en: "Contents", ar: "المحتويات")
        static let createdAt = LocalizedString(en: "Created", ar: "أُنشئت")
        static let origin = LocalizedString(en: "From", ar: "من")
        static let encryption = LocalizedString(en: "Protection", ar: "الحماية")
        static let encrypted = LocalizedString(en: "Encrypted", ar: "مشفّرة")
        static let plaintext = LocalizedString(en: "Plain (unencrypted)", ar: "غير مشفّرة")
        static let schemaVersion = LocalizedString(en: "Format version", ar: "إصدار التنسيق")
        static let templates = LocalizedString(en: "Saved export templates", ar: "قوالب التصدير المحفوظة")
        static let noRecords = LocalizedString(en: "This backup carries configuration only — no health records.",
                                               ar: "تحمل هذه النسخة الإعدادات فقط — دون سجلات صحية.")
        static let encryptedHeader = LocalizedString(en: "Encrypted backup", ar: "نسخة مشفّرة")
        static let encryptedBlurb = LocalizedString(
            en: "This backup is locked. Enter the passphrase it was created with to read what's inside.",
            ar: "هذه النسخة مقفلة. أدخل عبارة المرور التي أُنشئت بها لقراءة محتواها.")
        static let passphraseField = LocalizedString(en: "Passphrase", ar: "عبارة المرور")
        static let unlock = LocalizedString(en: "Unlock", ar: "فتح")
        static let wrongPassphrase = LocalizedString(
            en: "That passphrase didn't open it — or the file was altered.",
            ar: "لم تفتحها عبارة المرور هذه — أو أن الملف قد عُدِّل.")
        static let sensitiveHeader = LocalizedString(en: "Sensitive records", ar: "السجلات الحساسة")
        static let sensitiveToggle = LocalizedString(en: "Include medications & symptoms",
                                                     ar: "تضمين الأدوية والأعراض")
        static let sensitiveBlurb = LocalizedString(
            en: "This backup contains medication and symptom records. Restoring them is a separate "
                + "choice you make here, each time — a backup is never permission to write them back.",
            ar: "تحتوي هذه النسخة على سجلات أدوية وأعراض. استعادتها قرار منفصل تتخذه هنا في كل مرة — "
                + "والنسخة الاحتياطية ليست إذناً بإعادة كتابتها.")
        static let applyFeature = LocalizedString(en: "Write this backup back into BADAN",
                                                  ar: "إعادة كتابة هذه النسخة إلى بدن")
        static let unreadable = LocalizedString(
            en: "This file couldn't be read. It may have moved, or access was not granted.",
            ar: "تعذّرت قراءة هذا الملف. ربما نُقل، أو لم يُمنح الوصول إليه.")
        static let schemaTooNew = LocalizedString(
            en: "This backup was made by a newer version of BADAN than the one on this device. To "
                + "keep your data safe, it is not imported at all rather than partly. Update BADAN, "
                + "then try again.",
            ar: "أُنشئت هذه النسخة بإصدار من بدن أحدث من الموجود على هذا الجهاز. حفاظاً على بياناتك، "
                + "لا تُستورد إطلاقاً بدل أن تُستورد جزئياً. حدِّث بدن ثم أعد المحاولة.")
        static let checksumMismatch = LocalizedString(
            en: "This backup appears altered or incomplete — its contents don't match its own "
                + "checksums. It was not imported.",
            ar: "يبدو أن هذه النسخة عُدِّلت أو أنها ناقصة — محتواها لا يطابق بصماتها. لم تُستورد.")
        static let kdfCostTooHigh = LocalizedString(
            en: "This backup asks for an unusually expensive unlock and was refused as a precaution.",
            ar: "تطلب هذه النسخة فتحاً مكلفاً بشكل غير معتاد وقد رُفضت احترازاً.")
        static let notABackup = LocalizedString(
            en: "This isn't a BADAN backup file.", ar: "هذا ليس ملف نسخة احتياطية من بدن.")
        static let malformed = LocalizedString(
            en: "This backup file is damaged and couldn't be read.",
            ar: "ملف النسخة الاحتياطية هذا تالف وتعذّرت قراءته.")
    }
}
