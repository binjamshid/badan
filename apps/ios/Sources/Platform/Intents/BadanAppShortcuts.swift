import AppIntents

/// EPIC-19 — registers BADAN's three App Intents with Siri and the Shortcuts app.
///
/// An `AppShortcutsProvider` is the sanctioned "donate for Siri suggestions" mechanism for App
/// Intents: every `AppShortcut` listed here is automatically offered as a Siri suggestion and
/// appears in the Shortcuts app's action list without the user building anything first. That is
/// what the epic means by intents donating — the older SiriKit `INInteraction.donate()` call has
/// no App Intents equivalent because the framework does this surfacing itself.
///
/// Phrases live in `AppShortcuts.strings` (en + ar) keyed by the English phrase with the
/// `${applicationName}` token; every phrase must contain the app name, which is an App Intents
/// requirement, not a style choice. `LogWaterIntent` is not given a phrase with a spoken amount
/// here because a spoken number would have to be baked into the phrase — the amount is entered
/// when the shortcut runs instead; the phrases below open the intent, Siri then asks for the value.
struct BadanAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunExportTemplateIntent(),
            phrases: [
                "Run a \(.applicationName) export",
                "Export my data with \(.applicationName)",
                "\(.applicationName) export",
            ],
            shortTitle: LocalizedStringResource("shortcut.run_export.short_title", table: "AppShortcuts"),
            systemImageName: "square.and.arrow.up")

        AppShortcut(
            intent: GetLatestScoreIntent(),
            phrases: [
                "What's my \(.applicationName) readiness",
                "Get my latest \(.applicationName) score",
            ],
            shortTitle: LocalizedStringResource("shortcut.get_score.short_title", table: "AppShortcuts"),
            systemImageName: "gauge.medium")

        AppShortcut(
            intent: LogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Log a drink in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("shortcut.log_water.short_title", table: "AppShortcuts"),
            systemImageName: "drop.fill")
    }
}
