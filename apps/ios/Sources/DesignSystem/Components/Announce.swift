import SwiftUI

/// Speaks a transient, non-visual-focus event to VoiceOver.
///
/// (A3) Everything BADAN did to confirm an action was purely visual: a toast that fades, a
/// haptic, an inline pill, a form that quietly clears. None of it moves VoiceOver focus, so none
/// of it was announced — a blind user tapped Save and got silence, indistinguishable from a
/// no-op. The worst case wasn't a save at all: a *failed* sensitive-data purge (the "medications
/// are gone from this device" guarantee) reported itself only as a small notice on screen, so
/// the one failure in the app that most needs to be heard was the quietest.
///
/// One helper rather than per-screen `AccessibilityNotification` calls, because the family of
/// bugs is "each screen invented its own feedback and none of them spoke" — a single seam is
/// what makes "did we announce it?" answerable in one place.
///
/// Callers pass an already-resolved string (`env.s(...)`), matching how the presentational
/// components here take `language` explicitly instead of reaching for `AppEnvironment`.
enum Announce {
    /// Announce a completed action ("Symptom saved", "Copied").
    ///
    /// Posted on the main actor after a turn of the runloop: an announcement posted in the same
    /// update in which the view's contents change is liable to be dropped or talked over by
    /// VoiceOver re-reading the changed screen.
    @MainActor
    static func status(_ message: String) {
        guard !message.isEmpty else { return }
        Task { @MainActor in
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// Announce a failure. Identical delivery to `status` today, but kept a separate call so the
    /// intent is legible at the call site and so a future high-priority/interrupting announcement
    /// only has to change here.
    @MainActor
    static func failure(_ message: String) {
        status(message)
    }
}
