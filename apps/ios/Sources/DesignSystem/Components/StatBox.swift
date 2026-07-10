import SwiftUI

/// A hero value block: a big tabular numeral with a caption label, an optional unit and an
/// optional status chip. The workhorse for stat cards and metric heroes.
struct StatBox: View {
    var value: String
    var label: String
    var unit: String?
    var chip: StatusChip?

    init(value: String, label: String, unit: String? = nil, chip: StatusChip? = nil) {
        self.value = value
        self.label = label
        self.unit = unit
        self.chip = chip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space1) {
                Text(value)
                    .font(BadanFont.heroNumeral)
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
    }
}
