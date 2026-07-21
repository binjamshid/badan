import SwiftUI

/// The full hydration module (plan §11 EPIC-38 UI, §16.1). Reached from the Log tab's Today card.
/// Holds the calm progress, one-tap favorites, the custom sheet, today's editable drink list, the
/// observational weekly card, goal settings, and the "hide without deletion" control. Its own view
/// model reloads whenever the shared `dataGeneration` moves (a log made on the card, a background
/// sync), so it never shows a stale total.
struct HydrationScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm = HydrationViewModel()
    @State private var showCustomSheet = false
    @State private var showSaveFavorite = false
    @State private var editingEntry: HydrationEntry?

    private struct LoadKey: Equatable {
        let profile: CustomizationProfile
        let generation: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                progressSection
                quickLogSection
                todaysDrinksSection
                weeklySection
                settingsSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(HydrationStrings.moduleTitle))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { undoOverlay }
        .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: vm.pendingUndo)
        .sheet(isPresented: $showCustomSheet) { HydrationLogSheet(vm: vm, mode: .create) }
        .sheet(item: $editingEntry) { entry in HydrationLogSheet(vm: vm, mode: .edit(entry)) }
        .sheet(isPresented: $showSaveFavorite) { HydrationSaveFavoriteSheet(vm: vm) }
        .task(id: LoadKey(profile: env.profile, generation: env.dataGeneration)) { vm.load(env) }
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(spacing: BadanSpace.space3) {
            HydrationProgressRing(
                fraction: vm.progress.fraction,
                centerValue: env.format.integer(Int(vm.todayTotalMl.rounded())),
                centerUnit: env.s(HydrationStrings.ml),
                caption: caption,
                accessibilityText: accessibilityProgress,
                diameter: 172, lineWidth: 14)
                .frame(maxWidth: .infinity)
            if !vm.dayTypeGoals.isEmpty {
                dayTypeSelector
            }
        }
    }

    private var dayTypeSelector: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(HydrationStrings.todayIs))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    dayTypePill(name: env.s(HydrationStrings.defaultDay), value: nil)
                    ForEach(vm.dayTypeGoals) { goal in
                        dayTypePill(name: goal.dayType ?? "", value: goal.dayType)
                    }
                }
                .padding(.vertical, BadanSpace.space1)
            }
        }
    }

    private func dayTypePill(name: String, value: String?) -> some View {
        let selected = vm.todayDayType == value
        return Button {
            vm.selectTodayDayType(value, env: env)
        } label: {
            Text(name)
                .font(BadanFont.chip)
                .lineLimit(1)
                .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary)
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .background(
                    (selected ? BadanColor.primary : BadanColor.surface),
                    in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                        .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Quick log

    private var quickLogSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationStrings.favorites))
            HydrationFavoritesRow(
                favorites: vm.favorites,
                onTap: { vm.log(favorite: $0, env: env) },
                onCustom: { showCustomSheet = true },
                onDelete: { _ = vm.deleteFavorite($0, env: env) })
            Button { showSaveFavorite = true } label: {
                HStack(spacing: BadanSpace.space1) {
                    Image(systemName: "star")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(env.s(HydrationStrings.saveFavorite))
                        .font(BadanFont.link)
                }
                .foregroundStyle(BadanColor.primary)
                .frame(minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Today's drinks

    private var todaysDrinksSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationStrings.todaysDrinks))
            if vm.loadFailed {
                Text(env.s(HydrationStrings.couldntLoad))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            } else if vm.todayEntries.isEmpty {
                EmptyStateView(icon: "drop", title: env.s(HydrationStrings.noDrinksYet), message: "")
            } else {
                ForEach(vm.todayEntries) { entry in
                    BadanSwipeToDelete(deleteLabel: env.s(Loc.delete)) {
                        _ = vm.delete(entry: entry, env: env)
                    } content: {
                        Button { editingEntry = entry } label: {
                            HydrationDrinkRow(entry: entry, beverageName: vm.beverage(for: entry).name)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Weekly (observational)

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationStrings.thisWeek))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    let series = weekSeries()
                    if series.contains(where: { $0.value > 0 }) {
                        MetricChart(series: series, style: .bar, unit: env.s(HydrationStrings.ml),
                                    language: env.language, arabicDigits: env.profile.arabicDigits)
                            .frame(height: 120)
                    }
                    Text(HydrationStrings.loggedDaysSentence(
                        days: vm.loggedDayCountThisWeek, of: 7, formatter: env.format, language: env.language))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(HydrationStrings.weekObservationalNote))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Settings / hide

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            NavigationLink { HydrationGoalSettingsView(vm: vm) } label: {
                settingsRow(icon: "target", title: env.s(HydrationStrings.goalAndSettings), showsChevron: true)
            }
            .buttonStyle(.plain)

            Button { hideModule() } label: {
                settingsRow(icon: "eye.slash", title: env.s(HydrationStrings.hideModule), showsChevron: false)
            }
            .buttonStyle(.plain)
            Text(env.s(HydrationStrings.hideModuleNote))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsRow(icon: String, title: String, showsChevron: Bool) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .foregroundStyle(BadanColor.primary)
                .frame(width: BadanSpace.space5)
                .accessibilityHidden(true)
            Text(title)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, BadanSpace.space4)
        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin, alignment: .leading)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func hideModule() {
        env.update { $0.hydrationEnabled = false }
        Announce.status(env.s(HydrationStrings.hiddenChip))
        dismiss()
    }

    // MARK: Undo

    @ViewBuilder
    private var undoOverlay: some View {
        if let pending = vm.pendingUndo {
            BadanUndoToast(message: pending.message, undoLabel: env.s(Loc.undo)) {
                vm.undoLastLog(env: env)
            }
        }
    }

    // MARK: Helpers

    private var caption: String {
        if let target = vm.progress.goalTargetMl {
            return HydrationStrings.ofTarget(
                HydrationStrings.volume(target, formatter: env.format, language: env.language),
                language: env.language)
        }
        return env.s(HydrationStrings.loggedToday)
    }

    private var accessibilityProgress: String {
        let current = HydrationStrings.volume(vm.todayTotalMl, formatter: env.format, language: env.language)
        let target = vm.progress.goalTargetMl.map {
            HydrationStrings.volume($0, formatter: env.format, language: env.language)
        }
        return HydrationStrings.progressReadout(current: current, target: target, language: env.language)
    }

    /// The last 7 local days (oldest-first) with their logged totals, for the observational bar chart.
    /// Days never logged simply read as 0 — a plain absence, not a judged miss.
    private func weekSeries() -> [(date: Date, value: Double)] {
        let tzId = TimeZone.current.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tzId) ?? .current
        let totalsByKey = Dictionary(vm.weekSummaries.map { ($0.dayKey, $0.totalMl) },
                                     uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: env.now())
        var series: [(date: Date, value: Double)] = []
        for offset in stride(from: -6, through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = GoalEngine.dayKey(for: date, tzId: tzId)
            series.append((date: date, value: totalsByKey[key] ?? 0))
        }
        return series
    }
}

/// A compact sheet to save a container preset — the named favorite that logs in ≤2 actions and gives
/// the "Added 500 mL from My Bottle" confirmation its name.
private struct HydrationSaveFavoriteSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var vm: HydrationViewModel

    @State private var name: String = ""
    @State private var amount: String = ""
    @State private var beverageId: String = HydrationFluidType.water.rawValue
    @State private var saveFailed = false

    private var parsedAmount: Double? { HydrationLedger.parseVolumeMl(amount) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedAmount != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    BadanCard {
                        TextField(env.s(HydrationStrings.favoriteName), text: $name)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    BadanCard {
                        HStack(spacing: BadanSpace.space3) {
                            TextField(env.s(HydrationStrings.dailyAmount), text: $amount)
                                .keyboardType(.decimalPad)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(env.s(HydrationStrings.ml))
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        .frame(minHeight: BadanSpace.touchMin)
                    }
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space3) {
                            Text(env.s(HydrationStrings.drink))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: BadanSpace.space2) {
                                    ForEach(vm.beverages) { beverage in
                                        beveragePill(beverage)
                                    }
                                }
                                .padding(.vertical, BadanSpace.space1)
                            }
                        }
                    }
                    if saveFailed {
                        Text(env.s(HydrationStrings.saveFailed))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBand)
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(HydrationStrings.saveFavorite))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) { save() }.disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func beveragePill(_ beverage: HydrationBeverage) -> some View {
        let selected = beverage.id == beverageId
        return Button {
            beverageId = beverage.id
            if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let suggested = beverage.defaultVolumeMl {
                amount = env.format.integer(Int(suggested.rounded()))
            }
        } label: {
            Text(env.s(beverage.name))
                .font(BadanFont.chip)
                .lineLimit(1)
                .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary)
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .background(
                    (selected ? BadanColor.primary : BadanColor.surface),
                    in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                        .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A plain-water favorite stores no beverage id (nil = water), matching ContainerPreset's default.
        let beverage = beverageId == HydrationFluidType.water.rawValue ? nil : beverageId
        if vm.saveFavorite(name: name, volumeMl: amount, beverageId: beverage, env: env) {
            dismiss()
        } else {
            saveFailed = true
        }
    }
}
