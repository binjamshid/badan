import Foundation

// W-11 (EPIC-44 wave 1): "privacy modes & sensitive data configuration", whose stated outcome is a
// privacy-mode architecture where **lock screens never leak**, and whose Phase-3 exit criterion in
// the execution plan is a "lock-screen redaction non-overridability test".
//
// The structural point of this file: the widget extension cannot leak what the main app never
// wrote. BADAN's ambient surfaces already work that way for medications (`consentWidgetMedsDue`
// gates whether `medsDue` is assembled at all), and this generalises that one-off into a mode the
// user controls — while keeping the part that must NOT be user-controllable actually
// un-controllable.
//
// Why enforcement lives here rather than in the widgets: a widget-side check is a rendering
// decision, and rendering decisions can be forgotten by the next widget someone adds. The snapshot
// file is a single choke point that every present and future ambient surface reads — the widget
// bundle, the Lock Screen and StandBy families, and `BadanWatch` — so a value withheld here is
// withheld from all of them, including ones that do not exist yet.

/// How much an ambient surface may show.
public enum AmbientPrivacyMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Scores and sentences appear on ambient surfaces. Every value-bearing view in the four
    /// Lock-Screen-capable widgets is marked `.privacySensitive()`, so iOS redacts those values
    /// while the device is locked and this stays "normal", not "everything, always".
    ///
    /// That sentence used to be written here as a description of behaviour that did not exist:
    /// `.privacySensitive()` appeared nowhere in the repository, iOS does NOT auto-redact
    /// accessory-family content, and so readiness, effort, sleep and the day's sentence rendered in
    /// full on a locked Lock Screen. The modifier is real now (see `RingSingleWidget`,
    /// `EffortRingWidget`, `SleepCardWidget`, `SentenceWidget`, and the ratchet test in
    /// `AmbientPrivacyTests` that fails if a widget registers an accessory family without it).
    case standard
    /// Labels and shapes only — no numbers, no sentences. A ring still shows it exists and is
    /// filled; it does not say 74. For someone whose phone sits face-up on a shared desk.
    case discreet
    /// Nothing but the app's own name reaches any ambient surface. Widgets still render (removing
    /// them is the user's choice, not ours) but carry no personal content whatsoever.
    case off

    public var showsValues: Bool { self == .standard }
    public var showsAnyContent: Bool { self != .off }
}

/// The user's ambient-privacy settings.
public struct AmbientPrivacyConfig: Codable, Hashable, Sendable {
    /// Applies to Home Screen widgets, StandBy, and the watch glance.
    ///
    /// The three surfaces reach that outcome by two different mechanisms, which is worth knowing
    /// before changing either: widgets and StandBy read the `AmbientSnapshotDto.privacy` flags this
    /// config stamps and obey them at render time (`BadanWidgets/WidgetPrivacy.swift`), while the
    /// watch — whose copy of the DTO has no privacy field, and whose complications are a third
    /// process again — is served by `WatchSnapshotSync.watchPayload(for:)` removing the values from
    /// the payload before it is ever encoded. See that method for why enforcement there rather than
    /// a flag the watch would have to remember to honour.
    public var mode: AmbientPrivacyMode

    public init(mode: AmbientPrivacyMode = .standard) {
        self.mode = mode
    }

    public static let `default` = AmbientPrivacyConfig()

    /// Content families an ambient surface can carry, for the redaction decision below.
    public enum Family: String, Codable, Hashable, Sendable, CaseIterable {
        case readiness
        case sentence
        case sleep
        case effort
        /// Medication names and times. Sensitive-plus.
        case medsDue
    }

    /// Families whose VALUES may never reach a Lock Screen, no matter what mode the user picks or
    /// what consent they have granted.
    ///
    /// This is the non-overridable floor the execution plan's Phase-3 exit criteria asks for, and it
    /// is deliberately not a preference. A Lock Screen renders to whoever is holding the phone —
    /// including someone who picked it up off a table — and a medication name is diagnostic: it can
    /// disclose a condition the person has told no one about. `consentWidgetMedsDue` remains a real
    /// and separate gate for whether meds reach the snapshot at all; this says that even a granted
    /// consent does not extend to the lock screen. There is intentionally no setting, anywhere in
    /// the app, that turns this off.
    public static let neverOnLockScreen: Set<Family> = [.medsDue]

    /// Whether `family`'s values may be written into the shared snapshot for a surface.
    ///
    /// `isLockScreen` is supplied by the caller because the main app writes ONE snapshot read by
    /// several surfaces; the Lock Screen decision is applied at render time by the widget from the
    /// flags this config stamps into the DTO. See `AmbientSnapshotDto.privacy` — and
    /// `WatchSnapshotSync.watchPayload(for:)` for the watch, which is served by withholding the
    /// values rather than by a flag it would have to honour.
    public func allowsValues(for family: Family, isLockScreen: Bool) -> Bool {
        if isLockScreen && Self.neverOnLockScreen.contains(family) { return false }
        return mode.showsValues
    }

    /// Whether `family` may appear at all (even as a label with no value).
    public func allowsPresence(for family: Family, isLockScreen: Bool) -> Bool {
        if isLockScreen && Self.neverOnLockScreen.contains(family) { return false }
        return mode.showsAnyContent
    }
}
