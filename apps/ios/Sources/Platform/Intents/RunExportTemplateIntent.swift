import AppIntents
import Foundation

/// EPIC-19 — "run my morning export" as an App Intent.
///
/// This is the action a Shortcuts time-of-day automation runs, and the whole reason the epic
/// lists Shortcuts as "the only honest fixed-time path on iOS": iOS gives an app no way to wake
/// itself at a wall-clock time, but a Shortcuts automation can, and it can call this. What it
/// **cannot** promise is that the phone is unlocked when the time comes — the in-app setup guide
/// (`ShortcutsSetupGuideScreen`) states that before the user enables anything, and nothing in this
/// intent's copy implies otherwise.
///
/// The export itself is produced by `IntentExportService` → `ExportRunner`, unchanged and fully
/// offline. This type only resolves the parameter, hands off, and turns the result into files a
/// Shortcut can pass to "Save File" and a spoken confirmation.
struct RunExportTemplateIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.run_export.title", table: Self.table)

    static var description = IntentDescription(
        LocalizedStringResource("intent.run_export.description", table: Self.table))

    /// No app launch for a background export: the point of a scheduled automation is that it
    /// completes without the user watching. The export path touches no UI.
    static var openAppWhenRun = false

    /// The one intent in this bundle that hands FILES to whatever runs it — up to the user's whole
    /// recorded history, in one bundle, with provenance. The default policy (`.alwaysAllowed`) let
    /// that happen from a locked device via Siri, which contradicts BADAN's own threat model
    /// everywhere else: `AmbientPrivacyConfig.neverOnLockScreen` bars a medication *name* from the
    /// Lock Screen with no setting to turn it off, so a full export needing no unlock was the larger
    /// hole by far. It also contradicts what the app already promises about this exact surface — the
    /// setup guide's `guideUnlockRule` tells the user "iPhone must be unlocked" before they build the
    /// automation, so requiring it here codifies the documented behavior rather than changing it.
    ///
    /// `.requiresAuthentication` (device passcode/biometric having been satisfied), not
    /// `.requiresLocalDeviceAuthentication` (a fresh Face ID prompt per run): the latter would make
    /// an unattended time-of-day automation impossible even on an unlocked phone, which is the whole
    /// use case EPIC-19 exists for. Deliberately NOT applied to `LogWaterIntent` — a write-only
    /// quick-log that discloses nothing and would be pointless if it demanded an unlock.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    private static let table = "AppIntents"

    @Parameter(title: LocalizedStringResource("intent.run_export.param.template", table: Self.table))
    var template: ExportTemplateEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run export template \(\.$template)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let env = IntentEnvironment.resolve()
        let service = IntentExportService(env: env)

        // Re-resolve from storage rather than trusting the entity snapshot: a Shortcut built last
        // week carries a name and id captured then, and the template may have been edited or
        // deleted since. The id is the durable handle; a miss is reported, never guessed around.
        guard let stored = service.template(id: template.id) else {
            throw IntentPresentableError(env.s(IntentStrings.exportTemplateNotFound))
        }

        do {
            let outcome = try service.run(template: stored)
            let files = outcome.files.map { IntentFile(fileURL: $0.url, filename: $0.filename) }

            if outcome.rowCount == 0 {
                // Honest empty: the run happened, is in the ledger, and produced files that
                // describe an empty range. Say so rather than returning silence that reads as a
                // failure — and carry the notice, because "nothing in that window" means something
                // different when the window was clipped to seven days than when it was the whole
                // history the template asked for.
                let empty = env.s(IntentStrings.exportNothingInRange)
                let message = outcome.notice.map { "\(empty) \(env.s($0))" } ?? empty
                return .result(value: files, dialog: IntentDialog(appLanguage: message))
            }

            let confirmation = env.s(IntentStrings.exportFinished.filling([
                "files": env.format.integer(files.count),
                "count": env.format.integer(outcome.rowCount),
            ]))
            // A `sinceLastRun` run with NO checkpoint to resume from appends its notice, so the user
            // learns the window wasn't what the template literally asked for. A `sinceLastRun` run
            // that DID have a checkpoint takes the real delta and says nothing extra — there is
            // nothing to disclose (see `IntentExportService.cursor(for:)`).
            let dialog = outcome.notice.map { "\(confirmation) \(env.s($0))" } ?? confirmation
            return .result(value: files, dialog: IntentDialog(appLanguage: dialog))
        } catch IntentExportRefusal.sensitiveTemplateNeedsTheApp {
            throw IntentPresentableError(env.s(IntentStrings.exportSensitiveNeedsTheApp))
        } catch {
            throw IntentPresentableError(env.s(IntentStrings.exportFailed))
        }
    }
}
