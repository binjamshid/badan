import SwiftUI

/// Two tiles per row on iPad's regular width, one full-width column on iPhone's compact width —
/// the split used across every card-stack tab (Home, Body, Log, ...) so an iPad doesn't strand a
/// column of cards down the middle of the screen with empty space on both sides.
enum AdaptiveTiles {
    static func columns(for sizeClass: UserInterfaceSizeClass?, spacing: CGFloat) -> [GridItem] {
        sizeClass == .regular
            ? [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
            : [GridItem(.flexible())]
    }
}
