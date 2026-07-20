import AppIntents
import Foundation

/// The Shortcuts-facing choice of which score to read. A thin `AppEnum` mirror of
/// `IntentScoreKind` so the domain enum stays free of `AppIntents` (same separation as
/// `ExportTemplateEntity` vs `ExportTemplate`).
enum ScoreKindAppEnum: String, AppEnum {
    case readiness
    case sleepEfficiency

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource("intent.score.type", table: "AppIntents"))
    }

    static var caseDisplayRepresentations: [ScoreKindAppEnum: DisplayRepresentation] {
        [
            .readiness: DisplayRepresentation(title: LocalizedStringResource("intent.score.readiness", table: "AppIntents")),
            .sleepEfficiency: DisplayRepresentation(title: LocalizedStringResource("intent.score.sleep_efficiency", table: "AppIntents")),
        ]
    }

    var kind: IntentScoreKind {
        switch self {
        case .readiness: return .readiness
        case .sleepEfficiency: return .sleepEfficiency
        }
    }
}

/// EPIC-19 — expose the latest readiness / sleep-efficiency score to a user's own automation.
///
/// The value is returned so a Shortcut can branch on it ("if readiness is below 40, …"). The
/// honesty rule for this epic is load-bearing here: BADAN derives these from the user's own
/// history, and a user without enough history has no score — so this returns `nil` and says so,
/// rather than a fabricated placeholder an automation would treat as real (see `IntentScoreService`,
/// which reads only what `BaselineEngine` actually appended). Phase 2's richer Readiness (EPIC-25)
/// deepens the number this reads; it does not change the "no value yet is a real answer" contract.
struct GetLatestScoreIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.get_score.title", table: Self.table)

    static var description = IntentDescription(
        LocalizedStringResource("intent.get_score.description", table: Self.table))

    static var openAppWhenRun = false

    private static let table = "AppIntents"

    @Parameter(title: LocalizedStringResource("intent.get_score.param.score", table: Self.table))
    var score: ScoreKindAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Get latest \(\.$score)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double?> & ProvidesDialog {
        let env = IntentEnvironment.resolve()
        let service = IntentScoreService(env: env)
        let kind = score.kind
        let label = env.s(kind.label)

        guard let reading = service.latest(kind) else {
            // Honestly empty — not zero, not a guess. `nil` so an automation can distinguish
            // "no score" from a real low score; the dialog explains why.
            let message = env.s(IntentStrings.scoreUnavailable.filling(["label": label]))
            return .result(value: nil, dialog: IntentDialog(appLanguage: message))
        }

        let dateText = Self.dateFormatter(env.language).string(from: reading.day)
        let valueText = env.format.integer(Int(reading.value.rounded()))
        let template = reading.provisional ? IntentStrings.scoreAnswerProvisional : IntentStrings.scoreAnswer
        let message = env.s(template.filling([
            "label": label, "date": dateText, "value": valueText,
        ]))
        return .result(value: reading.value, dialog: IntentDialog(appLanguage: message))
    }

    /// A per-language medium date formatter, matching `HomeDateFormatting`'s locale choice so a
    /// score spoken by Siri reads the day the same way the Home hero prints it.
    private static func dateFormatter(_ language: AppLanguage) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language.localeIdentifier)
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }
}
