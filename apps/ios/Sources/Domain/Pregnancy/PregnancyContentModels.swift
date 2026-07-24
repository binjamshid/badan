import Foundation

// MARK: - PREG-03 (P0 slice): the versioned content shell + mandatory disclaimer.
//
// Recon's own scoping for this build stage: "Ship the versioned content-schema container and the
// mandatory, identically-rendered disclaimer footer... with placeholder/no real week-by-week
// clinical text — actual content needs independent authorship/licensing plus the clinical advisor's
// review (D-21) before it can ship, and building the shell without content lets that review happen
// in parallel rather than gating engineering." This file is that shell, and ONLY that shell —
// `PregnancyContentBundle.builtIn` below is deliberately empty; no case in this codebase ever
// populates it with real gestational-week/milestone copy until D-21 clears.
//
// The disclaimer itself (`PregnancyContentDisclaimer.footer`) is NOT gated the same way: it is
// mandatory, generic, non-diagnostic boilerplate (not clinical content), and it is what
// `PregnancyConsentScreen` renders today even though this P0 slice ships no real week-by-week
// content screens yet — see that screen's own use of it.

/// A versioned, keyed container for future bilingual pregnancy content (gestational milestones,
/// stage-specific notes, etc.). `schemaVersion` lets a later slice introduce a new content shape
/// without breaking an older persisted/bundled version — mirrors this codebase's other
/// `algorithmVersion`-style versioning discipline, applied to content instead of computation.
/// `entries` is a flat `contentKey -> LocalizedString` map so a lookup never needs to know the
/// internal shape of whatever authored the content; `PregnancyContentGate` (in
/// `PregnancyModels.swift`) is what decides WHETHER a section may render at all — this type only
/// decides WHAT text an already-permitted section would show.
public struct PregnancyContentBundle: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var entries: [String: LocalizedString]

    public init(schemaVersion: String = PregnancyContentBundle.shellSchemaVersion,
                entries: [String: LocalizedString] = [:]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// The P0 shell's own version identity — deliberately named `-shell` so a future reader can
    /// never mistake this for a reviewed, ship-ready content version.
    public static let shellSchemaVersion = "pregnancy.content@0.0.0-shell"

    /// THE P0 SHIPPED BUNDLE. Deliberately, permanently empty in this slice — real content is a
    /// separate, later change gated on D-21 (clinical review) and ADR-0010 A18/A25, never an
    /// incremental edit to this constant without that review having actually happened.
    public static let builtIn = PregnancyContentBundle()
}

/// The mandatory, identically-worded disclaimer every pregnancy content surface must render —
/// research doc `:71`; plan `:443`: "Build shell; content gated on A18/A25." Wellness-safe,
/// non-diagnostic, and deliberately generic (names no week, no stage, no clinical claim) so it is
/// equally true whether or not any real content ever renders alongside it.
public enum PregnancyContentDisclaimer {
    public static let footer = LocalizedString(
        en: "This information is general and educational, not medical advice. Always follow the "
            + "guidance of your own healthcare provider for anything about your pregnancy.",
        ar: "هذه المعلومات عامة وتثقيفية، وليست استشارة طبية. اتبع دائمًا إرشادات مقدّم الرعاية "
            + "الصحية الخاص بك بشأن أي أمر متعلق بحملك.")
}
