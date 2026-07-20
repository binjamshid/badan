import AppIntents
import Foundation

/// The Shortcuts-facing handle for a saved `ExportTemplate` (EPIC-19).
///
/// A separate entity rather than conforming `ExportTemplate` itself to `AppEntity` on purpose:
/// `ExportTemplate` is a domain type under `Domain/` that must not import `AppIntents` (it is
/// compiled and reasoned about far from any platform framework), and it carries fields — the full
/// `ExportScope`, the destination id, timestamps — that have no business being visible to a
/// Shortcut. This entity exposes only what the picker needs: a stable id and a name to show.
///
/// The id is the template's storage ULID, so a Shortcut the user built keeps pointing at the same
/// template across app launches. If that template is later deleted, `ExportTemplateQuery` returns
/// nothing for the id and the intent surfaces `templateNotFound` rather than silently running a
/// different one — see `RunExportTemplateIntent`.
struct ExportTemplateEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Export template")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = ExportTemplateQuery()

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ template: ExportTemplate) {
        self.id = template.id
        self.name = template.name
    }
}

/// Resolves `ExportTemplateEntity` values for the Shortcuts picker and for a typed/spoken
/// parameter (`EntityStringQuery`).
///
/// Everything routes through `IntentExportService`, the one place template lookup lives, so the
/// intent, the picker and the string match cannot drift into three different notions of "which
/// templates exist". The service reads the same `ExportTemplateRepository` the Export Center does.
struct ExportTemplateQuery: EntityStringQuery {
    @MainActor
    private var service: IntentExportService { IntentExportService(env: IntentEnvironment.resolve()) }

    /// Called with the ids the system remembers from a previously-built Shortcut. A missing id
    /// (template since deleted) simply drops out of the result — the intent then has no value to
    /// run and reports it honestly, rather than this step inventing a placeholder.
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExportTemplateEntity] {
        identifiers.compactMap { id in service.template(id: id).map(ExportTemplateEntity.init) }
    }

    /// The Shortcuts "choose a template" list. Presets and user templates alike, ordered by the
    /// repository (presets first) — the same order the Export Center shows.
    @MainActor
    func suggestedEntities() async throws -> [ExportTemplateEntity] {
        service.allTemplates().map(ExportTemplateEntity.init)
    }

    /// Spoken or typed name resolution. Returns candidates rather than one winner so App Intents'
    /// own disambiguation prompt asks the user which they meant — guessing would run the wrong
    /// export against their data (see `IntentExportService.templates(matching:)`).
    @MainActor
    func entities(matching string: String) async throws -> [ExportTemplateEntity] {
        service.templates(matching: string).map(ExportTemplateEntity.init)
    }
}
