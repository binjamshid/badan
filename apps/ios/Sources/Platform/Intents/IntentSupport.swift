import AppIntents
import Foundation

/// An intent failure whose message is already resolved to the **app's** language.
///
/// App Intents surfaces a thrown error to the user when it conforms to
/// `CustomLocalizedStringResourceConvertible`. The obvious route — a
/// `LocalizedStringResource("key")` — would resolve against the *system* language at display
/// time, which is right for the static metadata the Shortcuts editor renders but wrong for a
/// sentence BADAN produces at run time: everything the user reads inside the product follows
/// their `CustomizationProfile.language`, and a Siri error is not the place to break that. So the
/// string is resolved here, and wrapped in a `LocalizedStringResource` whose literal default IS
/// that resolved text.
struct IntentPresentableError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

extension IntentDialog {
    /// Build a spoken/shown dialog from a string BADAN has **already resolved** to the app's
    /// language. `IntentDialog` is `ExpressibleByStringLiteral`, so its only `String` initializer
    /// is `init(stringLiteral:)` — there is no `init(_ full: String)` for a runtime value. Passing
    /// our resolved sentence through the literal initializer is correct here (the string is real
    /// copy, not a lookup key) and keeps every intent's `perform` reading `IntentDialog(appLanguage:)`
    /// rather than the misleading `stringLiteral:` label at each call site.
    init(appLanguage message: String) { self.init(stringLiteral: message) }
}
