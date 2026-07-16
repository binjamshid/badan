import SwiftUI

/// The hairline between rows inside a settings card.
///
/// Was a private helper on the single Settings screen; every category page draws it now, so it
/// lives on its own rather than being copied seven times.
var settingsDivider: some View {
    Rectangle()
        .fill(BadanColor.separator)
        .frame(height: 1)
        .padding(.vertical, BadanSpace.space1)
}
