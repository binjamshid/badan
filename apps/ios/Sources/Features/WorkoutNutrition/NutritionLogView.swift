import SwiftUI

// MARK: - Screen-local bilingual strings

/// Strings only the nutrition-capture surface needs. Shared vocabulary comes from `Loc`; these
/// fill the gaps with real Arabic. Wording is descriptive, never prescriptive — food is logged,
/// not scored.
private enum NutritionLogStrings {
    static let protein = LocalizedString(en: "Protein", ar: "البروتين")
    static let optionalDetails = LocalizedString(en: "Optional details", ar: "تفاصيل اختيارية")
    static let todaysTotals = LocalizedString(en: "Today's totals", ar: "إجمالي اليوم")
    static let todaysMeals = LocalizedString(en: "Today's meals", ar: "وجبات اليوم")
    static let noneYet = LocalizedString(en: "Nothing logged today yet.", ar: "لم تُسجَّل وجبات اليوم بعد.")
    static let quickTag = LocalizedString(en: "Quick", ar: "سريع")
    static let savedManually = LocalizedString(en: "Saved as your own entry", ar: "يُحفَظ كإدخال منك")
    static let kcal = LocalizedString(en: "kcal", ar: "سعرة")
    static let grams = LocalizedString(en: "g", ar: "جم")
}

// MARK: - View model

@Observable
@MainActor
final class NutritionLogViewModel {
    var meals: [NutritionEntry] = []
    var kcalTotal: Double = 0
    var proteinTotal: Double = 0

    private var tz: String { TimeZone.current.identifier }

    /// Load everything logged since the start of the local day and sum the day's energy/protein.
    func load(_ env: AppEnvironment) {
        let now = env.now()
        let start = DayAttribution.startOfDay(now, tz: tz)
        let all = (try? env.logging.nutrition(from: start, to: now)) ?? []
        meals = all
        kcalTotal = all.compactMap { $0.energyKcal }.reduce(0, +)
        proteinTotal = all.compactMap { $0.proteinG }.reduce(0, +)
    }

    /// Insert a manual meal at now, then reload today's list + totals in place.
    func save(description: String, mealType: MealType, energyKcal: Double?,
              proteinG: Double?, lowDetail: Bool, env: AppEnvironment) {
        let now = env.now()
        let entry = NutritionEntry(
            id: ULID.newID(),
            description: description,
            mealType: mealType,
            energyKcal: energyKcal,
            proteinG: proteinG,
            lowDetail: lowDetail,
            occurredAt: now,
            tzId: tz,
            updatedAt: now,
            originDeviceId: env.deviceId)
        try? env.logging.upsertNutrition(entry)
        load(env)
    }
}

// MARK: - Screen

/// Under-10-second food capture, pushed as its own screen. Describe what you ate, pick a meal,
/// optionally add energy + protein (or flip "quick calories" to log honestly-low-detail), then
/// save. Today's meals and a plain totals bar sit below. Descriptive, calm, never judgmental.
struct NutritionLogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = NutritionLogViewModel()

    // Capture state
    @State private var descriptionText: String = ""
    @State private var mealType: MealType = .snack
    @State private var kcalText: String = ""
    @State private var proteinText: String = ""
    @State private var quickCalories: Bool = false
    @State private var didSetInitialMeal = false

    private var tz: String { TimeZone.current.identifier }
    private var power: Bool { env.depth.showsPowerDetail }

    private var canSave: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                descriptionCard
                mealTypeCard
                quickToggleCard
                if !quickCalories {
                    optionalCard
                } else {
                    quickEnergyCard
                }
                saveButton
                totalsSection
                mealsSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logFood))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !didSetInitialMeal {
                mealType = Self.mealForHour(Calendar.current.component(.hour, from: env.now()))
                didSetInitialMeal = true
            }
            vm.load(env)
        }
    }

    // MARK: - Form cards

    private var descriptionCard: some View {
        BadanCard {
            TextField(env.s(Loc.describeFood), text: $descriptionText, axis: .vertical)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .lineLimit(1...3)
        }
    }

    private var mealTypeCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.mealType))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(MealType.allCases, id: \.self) { option in
                            mealPill(option)
                        }
                    }
                    .padding(.vertical, BadanSpace.space1)
                }
            }
        }
    }

    private func mealPill(_ option: MealType) -> some View {
        let selected = option == mealType
        return Button {
            mealType = option
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: option.symbolName)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(env.s(option.displayName))
                    .font(BadanFont.chip)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : BadanColor.textPrimary)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(
                (selected ? BadanColor.primary : BadanColor.surface),
                in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
    }

    private var quickToggleCard: some View {
        BadanCard {
            Toggle(isOn: $quickCalories) {
                Text(env.s(Loc.quickCalories))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
            }
            .tint(BadanColor.primary)
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    private var optionalCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(NutritionLogStrings.optionalDetails))
                numberField(icon: "flame", placeholder: env.s(Loc.calories),
                            text: $kcalText, unit: env.s(NutritionLogStrings.kcal))
                Divider()
                numberField(icon: "fork.knife", placeholder: env.s(NutritionLogStrings.protein),
                            text: $proteinText, unit: env.s(NutritionLogStrings.grams))
                if power {
                    Text(env.s(NutritionLogStrings.savedManually))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private var quickEnergyCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                numberField(icon: "flame", placeholder: env.s(Loc.calories),
                            text: $kcalText, unit: env.s(NutritionLogStrings.kcal))
                Text(env.s(Loc.quickCalories))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    private func numberField(icon: String, placeholder: String,
                             text: Binding<String>, unit: String) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Text(unit)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private var saveButton: some View {
        Button {
            vm.save(description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                    mealType: mealType,
                    energyKcal: parseDecimal(kcalText),
                    proteinG: quickCalories ? nil : parseDecimal(proteinText),
                    lowDetail: quickCalories,
                    env: env)
            descriptionText = ""
            kcalText = ""
            proteinText = ""
        } label: {
            Text(env.s(Loc.save))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: BadanSpace.touchMin)
                .background(BadanColor.primary.opacity(canSave ? 1 : 0.4),
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .disabled(!canSave)
    }

    // MARK: - Today's totals

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(NutritionLogStrings.todaysTotals))
            BadanCard {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    StatBox(value: env.format.integer(Int(vm.kcalTotal.rounded())),
                            label: env.s(Loc.calories),
                            unit: env.s(NutritionLogStrings.kcal))
                    Spacer(minLength: BadanSpace.space2)
                    Rectangle()
                        .fill(BadanColor.separator)
                        .frame(width: 1, height: 44)
                    Spacer(minLength: BadanSpace.space2)
                    StatBox(value: env.format.integer(Int(vm.proteinTotal.rounded())),
                            label: env.s(NutritionLogStrings.protein),
                            unit: env.s(NutritionLogStrings.grams))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Today's meals

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(NutritionLogStrings.todaysMeals))
            if vm.meals.isEmpty {
                Text(env.s(NutritionLogStrings.noneYet))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                ForEach(vm.meals) { meal in
                    mealRow(meal)
                }
            }
        }
    }

    private func mealRow(_ meal: NutritionEntry) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: meal.mealType.symbolName)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(meal.description)
                            .font(BadanFont.body.weight(.medium))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(meal.mealType.displayName))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Text(timeText(meal.occurredAt))
                        .font(BadanFont.caption.monospacedDigit())
                        .foregroundStyle(BadanColor.textSecondary)
                }

                let chips = detailChips(meal)
                if !chips.isEmpty {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(chips.indices, id: \.self) { index in
                            chips[index]
                        }
                    }
                }

                if power {
                    Text(env.s(IngestionPath.manual.displayLabel))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private func detailChips(_ meal: NutritionEntry) -> [PillLabel] {
        var chips: [PillLabel] = []
        if let kcal = meal.energyKcal {
            chips.append(PillLabel("\(env.format.integer(Int(kcal.rounded()))) \(env.s(NutritionLogStrings.kcal))",
                                   systemImage: "flame"))
        }
        if let protein = meal.proteinG, protein > 0 {
            chips.append(PillLabel("\(env.format.integer(Int(protein.rounded()))) \(env.s(NutritionLogStrings.grams))",
                                   systemImage: "fork.knife"))
        }
        // "Quick calories" is flagged honestly, not hidden.
        if meal.lowDetail {
            chips.append(PillLabel(env.s(NutritionLogStrings.quickTag),
                                   systemImage: "bolt", tint: BadanColor.info))
        }
        return chips
    }

    // MARK: - Helpers

    private func parseDecimal(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func mealForHour(_ hour: Int) -> MealType {
        switch hour {
        case 4..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<21: return .dinner
        default: return .snack
        }
    }
}
