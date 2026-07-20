import SwiftUI

/// A transient "Deleted — Undo" pill, shown after `BadanSwipeToDelete` removes a row from view.
/// ONE component so every screen with deletable rows shares the same placement, motion and
/// accessibility behaviour (ledger #34 / dossier "No manual log can be edited or deleted anywhere
/// in the app").
///
/// Purely presentational and stateless: the caller owns the pending-delete/undo-window timing
/// (see `TimelineViewModel.PendingDelete`) and passes `onUndo` — this view only renders the pill
/// and the tap target, and announces itself to VoiceOver the moment it appears (a toast that only
/// fades in visually is invisible to a screen-reader user, the same class of gap `Announce`
/// exists to close elsewhere in the app).
///
/// Colour choice: the pill's fill is `textPrimary` and its text is `background` — always the
/// near-inverse of each other by construction in both themes (see the token-pair contrast test),
/// so this reads as a conventional "inverted surface" toast with guaranteed AA contrast in either
/// theme without inventing a new, unverified colour pairing.
struct BadanUndoToast: View {
    var message: String
    var undoLabel: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Text(message)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.background)
                .lineLimit(2)
            Spacer(minLength: BadanSpace.space2)
            Button(action: onUndo) {
                Text(undoLabel)
                    .font(BadanFont.body.weight(.bold))
                    .foregroundStyle(BadanColor.background)
            }
            .buttonStyle(.plain)
            .frame(minHeight: BadanSpace.touchMin)
        }
        .padding(.horizontal, BadanSpace.space4)
        .padding(.vertical, BadanSpace.space3)
        .background(BadanColor.textPrimary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .padding(.horizontal, BadanSpace.space4)
        .padding(.bottom, BadanSpace.space3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task { Announce.status(message) }
    }
}

#Preview("BadanUndoToast") {
    ZStack(alignment: .bottom) {
        BadanColor.background.ignoresSafeArea()
        BadanUndoToast(message: "Note deleted", undoLabel: "Undo") {}
    }
}
