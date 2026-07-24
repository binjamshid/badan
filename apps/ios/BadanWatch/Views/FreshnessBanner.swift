import SwiftUI

/// The honest-degradation banner A22/EPIC-42 requires: "if the snapshot is stale/missing, the
/// watch app must say so plainly, never show stale data as if fresh." Calm, non-alarming tone
/// (wellness-safe register, matching the rest of this app) — a plain statement of fact, not a
/// warning icon/red color. `isNeverSynced` picks a slightly different glyph (no prior connection
/// at all vs. a connection that has simply gone quiet for a while) but both read as the SAME
/// register.
struct FreshnessBanner: View {
    let text: String
    let isNeverSynced: Bool
    let isArabic: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isNeverSynced ? "antenna.radiowaves.left.and.right.slash" : "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isNeverSynced {
                    Text(WatchStrings.openPhoneHint.resolved(isArabic: isArabic))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(isArabic ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}
