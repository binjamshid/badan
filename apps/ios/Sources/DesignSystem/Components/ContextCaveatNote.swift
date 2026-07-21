import SwiftUI

/// The note a score card shows when the day it describes sat inside a period the user marked
/// (EPIC-29, plan §18: "`ContextStatus` … annotate confidence and copy — they modify *interpretation
/// framing*, never the stored value").
///
/// This is the visible half of that promise, and the reason the context manager's explainer can say
/// "adds a note beside them" without overstating: the sentences come from
/// `ContextStatus.caveat` — the same text the manager screen previews on each card before the tap —
/// so what the user was told a period would do is exactly what they later meet on the score.
///
/// **Deliberately not a warning.** No triangle, no amber, no retry: nothing is wrong with the number,
/// and the sentence says only that the personal pattern it is read against was built from days that
/// didn't look like this one. It is rendered at `textSecondary` beside the value, the same weight as
/// the window and provisional notes it sits with.
///
/// **Why the text is resolved at display time.** Caveats name a circumstance ("travelling",
/// "feeling unwell") and are therefore sensitive-plus, so they are never written onto the derived row
/// in the main database — the surface reads them from the sensitive store when it renders (see
/// `ContextCaveats`). Only the confidence CEILING crosses into `badan.db`, as a bare number.
/// Renders nothing at all when `caveats` is empty, which is the ordinary day.
struct ContextCaveatNote: View {
    let caveats: [LocalizedString]
    var language: AppLanguage

    var body: some View {
        if !caveats.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                ForEach(Array(caveats.enumerated()), id: \.offset) { _, caveat in
                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                        Image(systemName: "note.text")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(caveat, language: language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // One phrase per note is already the shape a screen reader wants; the icon is decorative.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(caveats.map { $0.resolved(language) }.joined(separator: ". "))
        }
    }
}
