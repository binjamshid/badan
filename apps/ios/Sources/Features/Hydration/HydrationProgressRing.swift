import SwiftUI

/// The calm hydration progress ring. Deliberately un-alarming: one colour (`primary`) for the fill,
/// a neutral track, no red/amber, no "you're behind". A no-goal day passes `fraction == nil` and
/// renders as a plain neutral ring with the running total in the middle — never a percentage of
/// nothing (§7A.1). A goal day fills the arc to `fraction` (capped at 1.0 upstream), so being over
/// your amount reads as a gently complete ring, never an overflow to alarm about.
///
/// One accessibility element: VoiceOver hears the whole thing as a single phrase (the caller supplies
/// it, always naming the logged volume), not four disconnected stops. Scales with Dynamic Type via
/// `minimumScaleFactor` on the centre numeral so the value stays inside the ring at XXL sizes.
struct HydrationProgressRing: View {
    var fraction: Double?
    var centerValue: String
    var centerUnit: String
    var caption: String
    var accessibilityText: String
    var diameter: CGFloat = 136
    var lineWidth: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(BadanColor.primary.opacity(0.14), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.001, fraction))
                    .stroke(BadanColor.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // Start the fill at the top and run clockwise. The arc is geometry, not
                    // directional text, so it is pinned LTR and never mirrors under RTL.
                    .rotationEffect(.degrees(-90))
                    .environment(\.layoutDirection, .leftToRight)
                    .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: fraction)
            }
            VStack(spacing: BadanSpace.space1) {
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                    Text(centerValue)
                        .font(BadanFont.heroNumeral)
                        .foregroundStyle(BadanColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(centerUnit)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                Text(caption)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(lineWidth + BadanSpace.space2)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

#Preview("HydrationProgressRing") {
    HStack(spacing: BadanSpace.space6) {
        HydrationProgressRing(fraction: 0.6, centerValue: "1,200", centerUnit: "mL",
                              caption: "of 2,000 mL", accessibilityText: "1,200 of 2,000 mL logged today")
        HydrationProgressRing(fraction: nil, centerValue: "1,200", centerUnit: "mL",
                              caption: "logged today", accessibilityText: "1,200 mL logged today")
    }
    .padding()
    .background(BadanColor.background)
}
