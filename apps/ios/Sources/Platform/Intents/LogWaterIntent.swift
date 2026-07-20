import AppIntents
import Foundation

/// EPIC-19 — "log 500 ml of water" by voice, from a Shortcut, or (later) an interactive widget.
///
/// The lightest of the three intents and the one most likely to be run by voice, so it returns a
/// short spoken confirmation and does not open the app. It writes through `IntentWaterService`,
/// the same `NutritionEntry` the Log tab's water sheet writes, so a drink logged here is
/// indistinguishable from a tapped one and shows up on an already-open Log tab immediately.
struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.log_water.title", table: Self.table)

    static var description = IntentDescription(
        LocalizedStringResource("intent.log_water.description", table: Self.table))

    static var openAppWhenRun = false

    private static let table = "AppIntents"

    /// Millilitres, matching the Log tab's water quick-add (which is ml-based regardless of the
    /// user's unit profile). Validated in `IntentWaterService` against the same 5000 ml ceiling
    /// the in-app sheet uses; the `inclusiveRange` below is the Shortcuts-editor hint for the same
    /// bounds and must be literals (App Intents rejects a non-literal here), so it mirrors
    /// `IntentWaterService.minMl`/`maxMl` rather than referencing them.
    @Parameter(
        title: LocalizedStringResource("intent.log_water.param.amount", table: Self.table),
        controlStyle: .field,
        inclusiveRange: (1, 5000))
    var milliliters: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$milliliters) ml of water")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = IntentEnvironment.resolve()
        let service = IntentWaterService(env: env)
        do {
            let logged = try service.log(milliliters: milliliters)
            let amount = "\(env.format.integer(Int(logged))) \(env.s(IntentStrings.milliliters))"
            let message = env.s(IntentStrings.waterLogged.filling(["amount": amount]))
            return .result(dialog: IntentDialog(appLanguage: message))
        } catch IntentWaterRefusal.amountOutOfRange {
            throw IntentPresentableError(env.s(IntentStrings.waterAmountOutOfRange))
        } catch {
            throw IntentPresentableError(env.s(IntentStrings.waterSaveFailed))
        }
    }
}
