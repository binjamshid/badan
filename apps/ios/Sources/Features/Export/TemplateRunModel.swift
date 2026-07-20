import SwiftUI

private enum TemplateRunCopy {
    static let nothingToExport = LocalizedString(
        en: "Nothing to export in this template's range right now.",
        ar: "لا شيء للتصدير في نطاق هذا القالب الآن.")
    static func ready(_ count: String) -> LocalizedString {
        LocalizedString(en: "Export ready — \(count) records", ar: "التصدير جاهز — \(count) سجلاً")
    }
}

/// Shared "run this template now" flow used by the Template Manager and Export Health. It owns the
/// three things a run-now needs and both screens would otherwise duplicate: the sensitive-template
/// passphrase gate (the entry of a passphrase IS the run-time consent), the share-sheet
/// presentation, and the temp-file cleanup afterwards.
///
/// The `ExportRun` ledger row is written by `ExportManageService.run` regardless of outcome, so
/// whichever surface calls this, Export Health sees the result — including a refusal.
@Observable
@MainActor
final class TemplateRunModel {
    /// The template currently generating, so a row can show a spinner without disabling the rest.
    var runningTemplateId: String?
    var shareURLs: [URL] = []
    var showShare = false
    var pendingSensitive: ExportTemplate?
    var showPassphrase = false
    /// A calm inline message after a run that produced no share (nothing-to-export) or failed.
    var message: LocalizedString?
    var messageIsError = false

    /// Called after any run finishes (success, skip, or failure) so the host screen can reload the
    /// run ledger and template rows.
    var onFinished: (() -> Void)?

    var isRunning: Bool { runningTemplateId != nil }

    func run(_ template: ExportTemplate, env: AppEnvironment) {
        guard runningTemplateId == nil else { return }
        message = nil
        if template.requiresSensitiveConfirmation {
            pendingSensitive = template
            showPassphrase = true
            return
        }
        execute(template, passphrase: nil, consent: nil, env: env)
    }

    /// Called by `SensitivePassphraseSheet` on confirm. Mints the consent here so it carries the
    /// correct template id + timestamp (§9.3 — a confirmation for one template can't authorize
    /// another, and it expires).
    func confirmSensitive(passphrase: String, env: AppEnvironment) {
        guard let template = pendingSensitive else { return }
        let consent = SensitiveRunConsent(templateId: template.id, confirmedAt: env.now())
        execute(template, passphrase: passphrase, consent: consent, env: env)
    }

    private func execute(_ template: ExportTemplate, passphrase: String?,
                         consent: SensitiveRunConsent?, env: AppEnvironment) {
        runningTemplateId = template.id
        message = nil
        messageIsError = false
        let service = ExportManageService(env: env)
        Task {
            defer {
                runningTemplateId = nil
                pendingSensitive = nil
                onFinished?()
            }
            do {
                let result = try await service.run(template: template, passphrase: passphrase,
                                                   consent: consent)
                if result.rowCount > 0 && !result.files.isEmpty {
                    shareURLs = result.files
                    showShare = true
                    Announce.status(env.s(TemplateRunCopy.ready(env.format.integer(result.rowCount))))
                } else {
                    message = TemplateRunCopy.nothingToExport
                    Announce.status(env.s(TemplateRunCopy.nothingToExport))
                }
            } catch {
                message = Self.errorMessage(error)
                messageIsError = true
                Announce.failure(env.s(message ?? ExportCopy.couldntPrepare))
            }
        }
    }

    func cleanupShared(env: AppEnvironment) {
        let folders = Set(shareURLs.map { $0.deletingLastPathComponent().path })
        for folder in folders { env.exporter.deleteExportedFiles(at: folder) }
        shareURLs = []
    }

    private static func errorMessage(_ error: Error) -> LocalizedString {
        switch error {
        case is ExportTemplateRunRefusal:
            return ExportRunPresentation.errorLabel(.sensitiveConfirmationMissing)
        case ExportRunError.sensitiveExportRequiresPassphrase:
            return ExportRunPresentation.errorLabel(.passphraseMissing)
        default:
            return ExportCopy.couldntPrepare
        }
    }
}

/// Attaches the run coordinator's share + passphrase sheets to a host screen.
private struct TemplateRunModifier: ViewModifier {
    @Bindable var model: TemplateRunModel
    let env: AppEnvironment

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showShare) {
                ShareSheet(activityItems: model.shareURLs) { completed in
                    guard completed else { return }
                    model.cleanupShared(env: env)
                }
            }
            .sheet(isPresented: $model.showPassphrase) {
                if let template = model.pendingSensitive {
                    SensitivePassphraseSheet(templateName: template.name) { passphrase in
                        model.confirmSensitive(passphrase: passphrase, env: env)
                    }
                }
            }
    }
}

extension View {
    /// Wire a `TemplateRunModel`'s share + passphrase sheets into this view.
    func templateRun(_ model: TemplateRunModel, env: AppEnvironment) -> some View {
        modifier(TemplateRunModifier(model: model, env: env))
    }
}
