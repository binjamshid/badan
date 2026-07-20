import SwiftUI

private enum SensitiveRunCopy {
    static let title = LocalizedString(en: "Encrypt this export", ar: "تشفير هذا التصدير")
    static let context = LocalizedString(
        en: "This template includes your medications and symptoms. It can only leave your device encrypted — choose a passphrase to continue.",
        ar: "يتضمّن هذا القالب أدويتك وأعراضك. لا يمكنه مغادرة جهازك إلا مشفَّراً — اختر عبارة مرور للمتابعة.")
    static let run = LocalizedString(en: "Encrypt & run", ar: "تشفير وتشغيل")
}

/// A focused sheet for the run-time confirmation a sensitive template needs (§9.3 + ADR-0008):
/// the act of typing a passphrase here IS the `SensitiveRunConsent`, and it can't be reused for a
/// different template or after it expires. Shared by the Template Manager and Export Health so the
/// "run now" of a sensitive template collects the same thing in both places, with the same
/// no-recovery warning as the advanced builder.
struct SensitivePassphraseSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let templateName: String
    /// Called with the validated passphrase when the user confirms. The caller mints the
    /// `SensitiveRunConsent` (so it carries the correct template id + timestamp) and runs.
    let onConfirm: (String) -> Void

    @State private var passphrase = ""
    @State private var passphraseConfirm = ""

    private var isValid: Bool {
        ExportPassphrasePolicy.isValid(passphrase)
            && ExportPassphrasePolicy.matches(passphrase, confirmation: passphraseConfirm)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    HStack(alignment: .top, spacing: BadanSpace.space2) {
                        Image(systemName: "lock.shield")
                            .imageScale(.large)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(SensitiveRunCopy.context, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(ExportCopy.passphraseIntro(env.format), language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    field(env.s(ExportCopy.passphrasePlaceholder), text: $passphrase)
                    field(env.s(ExportCopy.passphraseConfirmPlaceholder), text: $passphraseConfirm)

                    if !passphrase.isEmpty && !ExportPassphrasePolicy.isValid(passphrase) {
                        Text(ExportCopy.passphraseTooShort, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBand)
                    } else if !passphraseConfirm.isEmpty
                                && !ExportPassphrasePolicy.matches(passphrase, confirmation: passphraseConfirm) {
                        Text(ExportCopy.passphraseMismatch, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBand)
                    }

                    Button {
                        guard isValid else { return }
                        let entered = passphrase
                        dismiss()
                        onConfirm(entered)
                    } label: {
                        HStack(spacing: BadanSpace.space2) {
                            Image(systemName: "lock.fill").accessibilityHidden(true)
                            Text(SensitiveRunCopy.run, language: env.language)
                        }
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 4)
                        .background(BadanColor.primary,
                                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.5)
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background.ignoresSafeArea())
            .navigationTitle(env.s(SensitiveRunCopy.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                        .foregroundStyle(BadanColor.primary)
                }
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .font(BadanFont.body)
            .textContentType(.newPassword)
            .autocorrectionDisabled()
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(BadanColor.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }
}
