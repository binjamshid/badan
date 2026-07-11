import SwiftUI

// MARK: - Screen-local bilingual strings

/// Strings only the nutrition-capture surface needs. Shared vocabulary comes from `Loc`; these
/// fill the gaps with real Arabic. Wording is descriptive, never prescriptive — food is logged,
/// not scored.
private enum NutritionLogStrings {
    static let protein = LocalizedString(en: "Protein", ar: "البروتين")
    static let carbs = LocalizedString(en: "Carbs", ar: "الكربوهيدرات")
    static let fat = LocalizedString(en: "Fat", ar: "الدهون")
    static let fiber = LocalizedString(en: "Fiber", ar: "الألياف")
    static let caffeine = LocalizedString(en: "Caffeine", ar: "الكافيين")
    static let optionalDetails = LocalizedString(en: "Optional details", ar: "تفاصيل اختيارية")
    static let todaysTotals = LocalizedString(en: "Today's totals", ar: "إجمالي اليوم")
    static let todaysMeals = LocalizedString(en: "Today's meals", ar: "وجبات اليوم")
    static let noneYet = LocalizedString(en: "Nothing logged today yet.", ar: "لم تُسجَّل وجبات اليوم بعد.")
    static let quickTag = LocalizedString(en: "Quick", ar: "سريع")
    static let savedManually = LocalizedString(en: "Saved as your own entry", ar: "يُحفَظ كإدخال منك")
    static let kcal = LocalizedString(en: "kcal", ar: "سعرة")
    static let grams = LocalizedString(en: "g", ar: "جم")
    static let mg = LocalizedString(en: "mg", ar: "ملغ")
    static let ml = LocalizedString(en: "ml", ar: "مل")
    static let when = LocalizedString(en: "When", ar: "متى")
    static let quickCaloriesCaption = LocalizedString(
        en: "Hides the protein field and marks this entry as a quick, low-detail estimate.",
        ar: "يُخفي حقل البروتين ويضع علامة على هذا الإدخال كتقدير سريع منخفض التفاصيل.")
    static let recentMeals = LocalizedString(en: "Recent meals", ar: "الوجبات الأخيرة")
    static let history = LocalizedString(en: "Meal history", ar: "سجل الوجبات")
    static let searchMeals = LocalizedString(en: "Search meals", ar: "البحث في الوجبات")
    static let noHistoryResults = LocalizedString(en: "No meals found.", ar: "لم يتم العثور على وجبات.")
    static let trend = LocalizedString(en: "Calories trend", ar: "اتجاه السعرات")
    static let suggested = LocalizedString(en: "Suggested", ar: "مقترح")
    static let saveErrorTitle = LocalizedString(en: "Couldn’t save — try again.", ar: "تعذّر الحفظ — حاول مرة أخرى.")
}

// MARK: - View model

@Observable
@MainActor
final class NutritionLogViewModel {
    var meals: [NutritionEntry] = []
    var kcalTotal: Double = 0
    var proteinTotal: Double = 0
    var waterTotal: Double = 0
    var caffeineTotal: Double = 0

    /// Last ~30 days of entries (for the recent-meals row and the history search below), and a
    /// distinct-by-description subset of that for one-tap re-logging.
    var historyMeals: [NutritionEntry] = []
    var recentUnique: [NutritionEntry] = []

    private var tz: String { TimeZone.current.identifier }

    /// Load everything logged since the start of the local day and sum the day's totals.
    func load(_ env: AppEnvironment) {
        let now = env.now()
        let start = DayAttribution.startOfDay(now, tz: tz)
        let all = (try? env.logging.nutrition(from: start, to: now)) ?? []
        // The repository already orders by `occurred_at DESC`; sorting explicitly here keeps
        // that guarantee visible at the call site and correct once `save(...)` starts mutating
        // `meals` in place instead of always re-querying (UIUX-158 / PERF-079).
        meals = all.sorted { $0.occurredAt > $1.occurredAt }
        recomputeTotals()
    }

    /// Loads a wider window for the recent-meals quick-repeat row and the meal-history search
    /// (FEAT-284 / FEAT-143 / FEAT-200). Kept separate from `load(_:)` so today's totals stay
    /// cheap and unaffected by this wider query.
    func loadHistory(_ env: AppEnvironment) {
        let now = env.now()
        let start = now.addingTimeInterval(-30 * 86_400)
        historyMeals = (try? env.logging.nutrition(from: start, to: now)) ?? []
        var seen = Set<String>()
        var recents: [NutritionEntry] = []
        for entry in historyMeals {
            let key = entry.description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            recents.append(entry)
            if recents.count >= 8 { break }
        }
        recentUnique = recents
    }

    /// A day-bucketed calorie series over the history window, for the trend chart (FEAT-170).
    func dailyKcalSeries() -> [(date: Date, value: Double)] {
        let cal = Calendar.current
        var sums: [Date: Double] = [:]
        for meal in historyMeals {
            guard let kcal = meal.energyKcal else { continue }
            let day = cal.startOfDay(for: meal.occurredAt)
            sums[day, default: 0] += kcal
        }
        return sums.keys.sorted().map { (date: $0, value: sums[$0] ?? 0) }
    }

    private func recomputeTotals() {
        kcalTotal = meals.compactMap { $0.energyKcal }.reduce(0, +)
        proteinTotal = meals.compactMap { $0.proteinG }.reduce(0, +)
        waterTotal = meals.compactMap { $0.waterMl }.reduce(0, +)
        caffeineTotal = meals.compactMap { $0.caffeineMg }.reduce(0, +)
    }

    /// Insert a meal at `occurredAt`. When that falls within today's already-loaded window the
    /// new entry is appended and totals recomputed in place, instead of re-querying the day's
    /// meals from storage on every save (PERF-079). Throws instead of swallowing a failed write
    /// so the caller can keep the form intact and tell the user, rather than clearing it as if
    /// the save had succeeded (OPT-129).
    func save(description: String, mealType: MealType, energyKcal: Double?,
              proteinG: Double?, carbsG: Double?, fatG: Double?, fiberG: Double?,
              caffeineMg: Double?, lowDetail: Bool, occurredAt: Date, env: AppEnvironment) throws {
        let now = env.now()
        let entry = NutritionEntry(
            id: ULID.newID(),
            description: description,
            mealType: mealType,
            energyKcal: energyKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            caffeineMg: caffeineMg,
            lowDetail: lowDetail,
            occurredAt: occurredAt,
            tzId: tz,
            updatedAt: now,
            originDeviceId: env.deviceId)
        try env.logging.upsertNutrition(entry)

        let start = DayAttribution.startOfDay(now, tz: tz)
        if occurredAt >= start && occurredAt <= now {
            meals.append(entry)
            meals.sort { $0.occurredAt > $1.occurredAt }
            recomputeTotals()
        } else {
            // A backdated entry landed outside today's window — fall back to a full reload so
            // "today" stays accurate.
            load(env)
        }
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
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var fiberText: String = ""
    @State private var caffeineText: String = ""
    @State private var quickCalories: Bool = false
    @State private var occurredAt: Date = Date()
    @State private var didSetInitialMeal = false
    @State private var userPickedMealType = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var historyQuery: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case kcal, protein, carbs, fat, fiber, caffeine
    }

    private var power: Bool { env.depth.showsPowerDetail }

    private var canSave: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var maxDate: Date { env.now() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                recentsSection
                descriptionCard
                mealTypeCard
                whenCard
                quickToggleCard
                Group {
                    if !quickCalories {
                        optionalCard
                    } else {
                        quickEnergyCard
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: quickCalories)
                if let saveError {
                    errorRow(saveError)
                }
                saveButton
                TodaySummarySection(
                    kcalTotal: vm.kcalTotal, proteinTotal: vm.proteinTotal,
                    waterTotal: vm.waterTotal, caffeineTotal: vm.caffeineTotal,
                    meals: vm.meals)
                trendSection
                historySection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logFood))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Decimal-pad has no built-in Return/Done key on iOS, so it's the one keyboard type
            // that structurally needs an explicit dismiss affordance (EASE-096).
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(env.s(Loc.done)) { focusedField = nil }
            }
        }
        .task {
            if !didSetInitialMeal {
                occurredAt = env.now()
                mealType = Self.mealForHour(Calendar.current.component(.hour, from: occurredAt))
                didSetInitialMeal = true
            }
            vm.load(env)
            vm.loadHistory(env)
        }
    }

    // MARK: - Recent meals (FEAT-284 / FEAT-143)

    @ViewBuilder
    private var recentsSection: some View {
        if !vm.recentUnique.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(NutritionLogStrings.recentMeals))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(vm.recentUnique) { meal in
                            recentChip(meal)
                        }
                    }
                    .padding(.vertical, BadanSpace.space1)
                }
            }
        }
    }

    private func recentChip(_ meal: NutritionEntry) -> some View {
        Button {
            repeatMeal(meal)
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: "arrow.counterclockwise")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(meal.description)
                    .font(BadanFont.chip)
                    .lineLimit(1)
            }
            .foregroundStyle(BadanColor.textPrimary)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(BadanColor.separator, lineWidth: 1))
        }
        .disabled(isSaving)
    }

    /// Re-logs a past meal's description + macros at "now" in one tap. Guarded by the same
    /// `isSaving` flag as the main save button so a rapid double-tap can't double-log it
    /// (EASE-069's guard applied here too).
    private func repeatMeal(_ meal: NutritionEntry) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        do {
            try vm.save(description: meal.description, mealType: meal.mealType, energyKcal: meal.energyKcal,
                        proteinG: meal.proteinG, carbsG: meal.carbsG, fatG: meal.fatG, fiberG: meal.fiberG,
                        caffeineMg: meal.caffeineMg, lowDetail: meal.lowDetail, occurredAt: env.now(), env: env)
        } catch {
            saveError = env.s(NutritionLogStrings.saveErrorTitle)
        }
        isSaving = false
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
        // Shown only on the still-auto-selected pill, until the user actively taps one
        // (UIUX-157) — makes clear the choice was a guess, not a confirmed selection.
        let isSuggestion = selected && !userPickedMealType
        return Button {
            mealType = option
            userPickedMealType = true
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: option.symbolName)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(env.s(option.displayName))
                    .font(BadanFont.chip)
                    .lineLimit(1)
                if isSuggestion {
                    Text("· \(env.s(NutritionLogStrings.suggested))")
                        .font(BadanFont.caption)
                        .lineLimit(1)
                }
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

    /// Backdate the entry (FEAT-141) — meals are frequently logged well after eating. Adjusting
    /// the time re-syncs the auto-suggested meal type (unless the user already picked one
    /// explicitly), so a backdated breakfast doesn't stay tagged "Dinner" just because it's
    /// being logged in the evening.
    private var whenCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "clock")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(NutritionLogStrings.when))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                DatePicker("", selection: $occurredAt, in: ...maxDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .onChange(of: occurredAt) { _, newValue in
                        if !userPickedMealType {
                            mealType = Self.mealForHour(Calendar.current.component(.hour, from: newValue))
                        }
                    }
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    private var quickToggleCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Toggle(isOn: $quickCalories) {
                    Text(env.s(Loc.quickCalories))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                }
                .tint(BadanColor.primary)
                .frame(minHeight: BadanSpace.touchMin)
                Text(env.s(NutritionLogStrings.quickCaloriesCaption))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    private var optionalCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(NutritionLogStrings.optionalDetails))
                numberField(icon: "flame", placeholder: env.s(Loc.calories),
                            text: $kcalText, unit: env.s(NutritionLogStrings.kcal), field: .kcal)
                Divider()
                numberField(icon: "fork.knife", placeholder: env.s(NutritionLogStrings.protein),
                            text: $proteinText, unit: env.s(NutritionLogStrings.grams), field: .protein)
                if power {
                    Divider()
                    numberField(icon: "leaf", placeholder: env.s(NutritionLogStrings.carbs),
                                text: $carbsText, unit: env.s(NutritionLogStrings.grams), field: .carbs)
                    Divider()
                    numberField(icon: "drop", placeholder: env.s(NutritionLogStrings.fat),
                                text: $fatText, unit: env.s(NutritionLogStrings.grams), field: .fat)
                    Divider()
                    numberField(icon: "circle.grid.3x3", placeholder: env.s(NutritionLogStrings.fiber),
                                text: $fiberText, unit: env.s(NutritionLogStrings.grams), field: .fiber)
                    Divider()
                    numberField(icon: "cup.and.saucer", placeholder: env.s(NutritionLogStrings.caffeine),
                                text: $caffeineText, unit: env.s(NutritionLogStrings.mg), field: .caffeine)
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
                            text: $kcalText, unit: env.s(NutritionLogStrings.kcal), field: .kcal)
                Text(env.s(Loc.quickCalories))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    private func numberField(icon: String, placeholder: String,
                             text: Binding<String>, unit: String, field: Field) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
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
            // Guard against a fast double-tap inserting two near-identical meal entries
            // (EASE-069).
            guard !isSaving else { return }
            isSaving = true
            saveError = nil
            do {
                try vm.save(description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                            mealType: mealType,
                            energyKcal: parseDecimal(kcalText),
                            // Protein (and the other optional macros) are saved whenever they were
                            // typed, even if Quick calories is on — previously flipping the toggle
                            // silently discarded an already-entered protein value (UIUX-153).
                            proteinG: parseDecimal(proteinText),
                            carbsG: parseDecimal(carbsText),
                            fatG: parseDecimal(fatText),
                            fiberG: parseDecimal(fiberText),
                            caffeineMg: parseDecimal(caffeineText),
                            lowDetail: quickCalories,
                            occurredAt: occurredAt,
                            env: env)
                // Only clear the form on a confirmed write — a failed save now leaves everything
                // intact instead of silently discarding it exactly like a successful save would
                // (OPT-129).
                descriptionText = ""
                kcalText = ""
                proteinText = ""
                carbsText = ""
                fatText = ""
                fiberText = ""
                caffeineText = ""
                occurredAt = env.now()
            } catch {
                saveError = env.s(NutritionLogStrings.saveErrorTitle)
            }
            isSaving = false
        } label: {
            Text(env.s(Loc.save))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: BadanSpace.touchMin)
                // UIUX-161: 0.6 (not 0.4) keeps the white label legible against the diluted
                // background in the disabled state.
                .background(BadanColor.primary.opacity(canSave && !isSaving ? 1 : 0.6),
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .disabled(!canSave || isSaving)
    }

    /// Stays calm and non-destructive on failure — the form is left intact so nothing entered
    /// is lost, and the error is surfaced instead of silently discarding the save (OPT-129).
    private func errorRow(_ message: String) -> some View {
        BadanCard {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(BadanColor.outOfBand)
                    .accessibilityHidden(true)
                Text(message)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
            }
        }
    }

    // MARK: - Calories trend (FEAT-170)

    @ViewBuilder
    private var trendSection: some View {
        let series = vm.dailyKcalSeries()
        if !series.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(NutritionLogStrings.trend))
                BadanCard {
                    MetricChart(series: series, style: .bar, unit: env.s(NutritionLogStrings.kcal),
                                language: env.language, arabicDigits: env.profile.arabicDigits)
                        .frame(height: 160)
                }
            }
        }
    }

    // MARK: - Meal history search (FEAT-200)

    private var historyResults: [NutritionEntry] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return vm.historyMeals.filter { $0.description.lowercased().contains(query) }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(NutritionLogStrings.history))
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    TextField(env.s(NutritionLogStrings.searchMeals), text: $historyQuery)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                        .autocorrectionDisabled()
                }
                .frame(minHeight: BadanSpace.touchMin)
            }
            if !historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if historyResults.isEmpty {
                    Text(env.s(NutritionLogStrings.noHistoryResults))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                } else {
                    ForEach(historyResults.prefix(20)) { meal in
                        NutritionMealRow(meal: meal)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Explicit zero (e.g. black coffee, water — genuinely 0 kcal/protein) is meaningfully
    /// different from "nothing entered"; only reject negative/unparseable input, not zero
    /// (OPT-133). None of this screen's numeric fields are duration/distance-style fields
    /// where zero would be meaningless, so a single lenient rule covers all of them.
    private func parseDecimal(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value >= 0 else { return nil }
        return value
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

// MARK: - Today's totals + meals (extracted for PERF-081)

/// Read-only summary of today's totals and meal list. Kept as its own view (taking plain value
/// inputs, not the whole observable view model) so keystrokes in the capture form above don't
/// force this list to re-diff on every render — the same fix as its Workout sibling (PERF-081).
private struct TodaySummarySection: View {
    @Environment(AppEnvironment.self) private var env

    var kcalTotal: Double
    var proteinTotal: Double
    var waterTotal: Double
    var caffeineTotal: Double
    var meals: [NutritionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            totalsSection
            mealsSection
        }
    }

    // MARK: Totals

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(NutritionLogStrings.todaysTotals))
            BadanCard {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    ForEach(Array(totalsStats.enumerated()), id: \.offset) { index, stat in
                        if index > 0 {
                            Rectangle()
                                .fill(BadanColor.separator)
                                .frame(width: 1, height: 44)
                        }
                        StatBox(value: stat.value, label: stat.label, unit: stat.unit)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// kcal/protein always show; a dash — not "0" — distinguishes "nothing logged today yet"
    /// from a genuine logged zero (UIUX-156). Water/caffeine (OPT-105 / FEAT-114) only appear
    /// once something has actually been logged, so the common case stays a calm two-stat row.
    private var totalsStats: [(value: String, label: String, unit: String)] {
        var stats: [(value: String, label: String, unit: String)] = []
        let hasMeals = !meals.isEmpty
        stats.append((
            hasMeals ? env.format.integer(Int(kcalTotal.rounded())) : "—",
            env.s(Loc.calories), env.s(NutritionLogStrings.kcal)))
        stats.append((
            hasMeals ? env.format.integer(Int(proteinTotal.rounded())) : "—",
            env.s(NutritionLogStrings.protein), env.s(NutritionLogStrings.grams)))
        if waterTotal > 0 {
            stats.append((env.format.integer(Int(waterTotal.rounded())), env.s(Loc.logWater), env.s(NutritionLogStrings.ml)))
        }
        if caffeineTotal > 0 {
            stats.append((env.format.integer(Int(caffeineTotal.rounded())), env.s(NutritionLogStrings.caffeine), env.s(NutritionLogStrings.mg)))
        }
        return stats
    }

    // MARK: Today's meals

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(NutritionLogStrings.todaysMeals))
            if meals.isEmpty {
                // Matches Medication's illustrated empty state instead of a bare caption line
                // (UIUX-162).
                EmptyStateView(icon: "fork.knife", title: env.s(NutritionLogStrings.noneYet), message: "")
            } else {
                ForEach(meals) { meal in
                    NutritionMealRow(meal: meal)
                }
            }
        }
    }
}

// MARK: - Meal row (shared by today's list and history search)

private struct NutritionMealRow: View {
    @Environment(AppEnvironment.self) private var env
    var meal: NutritionEntry

    private var power: Bool { env.depth.showsPowerDetail }

    var body: some View {
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

                let chips = detailChips()
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

    /// kcal and protein now follow the same rule — shown whenever the value was actually
    /// entered, even if it's an explicit zero (e.g. black coffee) — instead of protein
    /// silently hiding a logged-zero (UIUX-155).
    private func detailChips() -> [PillLabel] {
        var chips: [PillLabel] = []
        if let kcal = meal.energyKcal {
            chips.append(PillLabel("\(env.format.integer(Int(kcal.rounded()))) \(env.s(NutritionLogStrings.kcal))",
                                   systemImage: "flame"))
        }
        if let protein = meal.proteinG {
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

    // Cached formatter instance, reused and mutated per call rather than allocated fresh per
    // row on every render (PERF-080).
    private static let timeFormatter = DateFormatter()

    private func timeText(_ date: Date) -> String {
        let formatter = Self.timeFormatter
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
