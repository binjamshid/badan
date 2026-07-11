import SwiftUI

/// A hero value block: a big tabular numeral with a caption label, an optional unit and an
/// optional status chip. The workhorse for stat cards and metric heroes.
struct StatBox: View {
    /// `.hero` (44pt) is the default full-size stat block; `.compact` (28pt) matches the
    /// numeral size used by grid/pillar cards, so those surfaces can adopt `StatBox` instead
    /// of hand-rolling the same value/unit/chip layout.
    enum Size {
        case hero, compact

        var font: Font {
            switch self {
            case .hero: return BadanFont.heroNumeral
            case .compact: return BadanFont.numeralM
            }
        }
    }

    var value: String
    var label: String
    var unit: String?
    var chip: StatusChip?
    var size: Size

    init(value: String, label: String, unit: String? = nil, chip: StatusChip? = nil, size: Size = .hero) {
        self.value = value
        self.label = label
        self.unit = unit
        self.chip = chip
        self.size = size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                Text(value)
                    .font(size.font)
                    .foregroundStyle(BadanColor.textPrimary)
                if let unit {
                    Text(unit)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            Text(label)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            if let chip {
                chip
                    .padding(.top, BadanSpace.space1)
            }
        }
        // Read as one phrase ("Sleep, 6h 31m, in your usual range") instead of VoiceOver
        // hitting value/unit/label/chip as separate, disconnected stops.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        var parts = [label, [value, unit].compactMap { $0 }.joined(separator: " ")]
        if let chip { parts.append(chip.label) }
        return parts.joined(separator: ", ")
    }
}

#Preview("StatBox") {
    VStack(alignment: .leading, spacing: BadanSpace.space4) {
        StatBox(value: "6h 31m", label: "Sleep",
                chip: StatusChip(.inBand, label: "In your usual range", language: .en))
        StatBox(value: "56", label: "Resting heart rate", unit: "bpm",
                chip: StatusChip(.above, label: "Above your usual range", language: .en))
        StatBox(value: "8,214", label: "Steps")
        StatBox(value: "72", label: "HRV", unit: "ms", size: .compact)
    }
    .padding()
}
