import SwiftUI

/// A swipe-to-reveal delete affordance for row content living inside a `ScrollView` + `VStack`
/// card list — not a SwiftUI `List` — which is how every card-based list in BADAN (Timeline, and
/// any future deletable row) is built. SwiftUI's native `.swipeActions` modifier only functions
/// inside `List` row content, so adopting it here would silently do nothing; this is BADAN's own
/// gesture-based equivalent. ONE implementation so every deletable row gets the same threshold,
/// motion and RTL behaviour rather than each screen reinventing it (ledger #34 / dossier "No
/// manual log can be edited or deleted anywhere in the app").
///
/// Mirrors automatically under RTL via `\.layoutDirection`: the delete affordance always reveals
/// from the row's *trailing* edge in whichever direction is active, matching the platform
/// convention in both LTR and RTL rather than a hardcoded left/right offset.
///
/// Also exposes the delete as a VoiceOver custom action (`.accessibilityAction(named:)`) — a drag
/// gesture alone is not reachable by VoiceOver, so without this a screen-reader user would have
/// no way to trigger the one action this component exists to offer.
struct BadanSwipeToDelete<Content: View>: View {
    var deleteLabel: String
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var isRevealed = false

    private let actionWidth: CGFloat = 92
    private let revealThreshold: CGFloat = 48

    /// The reveal direction's sign in the current layout direction: content is dragged toward
    /// negative x in LTR (revealing a trailing-edge button on the right) and toward positive x
    /// in RTL (revealing on the left — RTL's trailing edge).
    private var revealSign: CGFloat { layoutDirection == .rightToLeft ? 1 : -1 }

    var body: some View {
        ZStack {
            deleteAction
            content()
                .background(BadanColor.surface)
                .offset(x: dragOffset)
                .gesture(dragGesture)
                // Revealed but not confirmed: a tap anywhere on the row closes it instead of
                // forwarding to whatever the content underneath would otherwise do (navigation,
                // a button) — the standard swipe-row expectation, and it keeps a half-revealed
                // delete button from being one stray tap away from misfiring.
                .overlay {
                    if isRevealed {
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                            .accessibilityHidden(true)
                    }
                }
        }
        .clipped()
        .accessibilityAction(named: Text(deleteLabel)) { performDelete() }
    }

    private var deleteAction: some View {
        HStack(spacing: 0) {
            if revealSign < 0 { Spacer(minLength: 0) }
            Button(role: .destructive, action: performDelete) {
                VStack(spacing: BadanSpace.space1) {
                    Image(systemName: "trash")
                        .imageScale(.medium)
                    Text(deleteLabel)
                        .font(BadanFont.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .background(BadanColor.critical)
            // The delete action itself is exposed as an accessibility action on the whole row
            // (below), not as a second focusable element here — a drag-revealed button is not
            // reliably reachable by VoiceOver swipe navigation.
            .accessibilityHidden(true)
            if revealSign > 0 { Spacer(minLength: 0) }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let base: CGFloat = isRevealed ? revealSign * actionWidth : 0
                let proposed = base + value.translation.width
                dragOffset = revealSign < 0
                    ? min(0, max(proposed, -actionWidth))
                    : max(0, min(proposed, actionWidth))
            }
            .onEnded { _ in
                let pastThreshold = abs(dragOffset) > revealThreshold
                isRevealed = pastThreshold
                animateOffset(pastThreshold ? revealSign * actionWidth : 0)
            }
    }

    private func close() {
        isRevealed = false
        animateOffset(0)
    }

    private func performDelete() {
        isRevealed = false
        animateOffset(0)
        onDelete()
    }

    private func animateOffset(_ target: CGFloat) {
        withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
            dragOffset = target
        }
    }
}

#Preview("BadanSwipeToDelete") {
    VStack(spacing: 0) {
        BadanSwipeToDelete(deleteLabel: "Delete") {
            print("deleted")
        } content: {
            HStack {
                Text("Swipe me")
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer()
            }
            .padding(BadanSpace.space4)
            .frame(minHeight: BadanSpace.touchMin)
        }
        Rectangle().fill(BadanColor.separator).frame(height: 1)
        BadanSwipeToDelete(deleteLabel: "حذف") {
            print("deleted")
        } content: {
            HStack {
                Text("اسحب هنا")
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer()
            }
            .padding(BadanSpace.space4)
            .frame(minHeight: BadanSpace.touchMin)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
    .background(BadanColor.background)
}
