import SwiftUI

/// Goal settings (plan §16.1, task item 3). A tracking goal is optional and equal-status: "No goal"
/// is a real choice, never a nag and never a 0%-of-nothing. When a goal is set it is only ever "your
/// tracking goal" — no dehydration claim, no urgency, no streak. Day-type amounts are user-authored;
/// BADAN never infers which kind of day today is (that pick lives on the main screen).
struct HydrationGoalSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var vm: HydrationViewModel

    private enum GoalMode { case none, manual }

    @State private var mode: GoalMode = .none
    @State private var manualAmount: String = ""
    @State private var newDayTypeName: String = ""
    @State private var newDayTypeAmount: String = ""
    @State private var didPrime = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                trackingGoalSection
                dayTypesSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(HydrationStrings.yourTrackingGoal))
        .navigationBarTitleDisplayMode(.inline)
        .task { primeIfNeeded() }
    }

    // MARK: Tracking goal (default)

    private var trackingGoalSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationStrings.yourTrackingGoal))
            Text(env.s(HydrationStrings.goalHelp))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            BadanCard {
                VStack(spacing: 0) {
                    choiceRow(
                        title: env.s(HydrationStrings.noGoal),
                        subtitle: env.s(HydrationStrings.noGoalDescription),
                        selected: mode == .none) {
                            mode = .none
                            _ = vm.setDefaultGoal(manualTargetMl: nil, env: env)
                        }
                    Rectangle().fill(BadanColor.separator).frame(height: 1)
                    choiceRow(
                        title: env.s(HydrationStrings.setAGoal),
                        subtitle: nil,
                        selected: mode == .manual) {
                            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                                mode = .manual
                            }
                        }
                    if mode == .manual {
                        manualAmountRow
                    }
                }
            }
        }
    }

    private var manualAmountRow: some View {
        VStack(spacing: BadanSpace.space3) {
            Rectangle().fill(BadanColor.separator).frame(height: 1)
            HStack(spacing: BadanSpace.space3) {
                Text(env.s(HydrationStrings.dailyAmount))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                TextField(env.s(HydrationStrings.dailyAmount), text: $manualAmount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(env.s(HydrationStrings.ml))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                Button(env.s(Loc.save)) {
                    if let amount = HydrationLedger.parseVolumeMl(manualAmount) {
                        _ = vm.setDefaultGoal(manualTargetMl: amount, env: env)
                        Announce.status(env.s(Loc.save))
                    }
                }
                .font(BadanFont.link)
                .disabled(HydrationLedger.parseVolumeMl(manualAmount) == nil)
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    // MARK: Day types (user-authored)

    private var dayTypesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationStrings.dayTypes))
            Text(env.s(HydrationStrings.dayTypesHelp))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(vm.dayTypeGoals) { goal in
                BadanSwipeToDelete(deleteLabel: env.s(Loc.delete)) {
                    _ = vm.removeDayTypeGoal(goal, env: env)
                } content: {
                    dayTypeRow(goal)
                }
            }

            addDayTypeCard
        }
    }

    private func dayTypeRow(_ goal: HydrationGoal) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Text(goal.dayType ?? "")
                .font(BadanFont.body.weight(.medium))
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            Text(amountText(goal.targetMl))
                .font(BadanFont.body.monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
        }
        .padding(.horizontal, BadanSpace.space4)
        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin, alignment: .leading)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
    }

    private var addDayTypeCard: some View {
        BadanCard {
            VStack(spacing: BadanSpace.space3) {
                TextField(env.s(HydrationStrings.dayTypeNamePlaceholder), text: $newDayTypeName)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                HStack(spacing: BadanSpace.space3) {
                    TextField(env.s(HydrationStrings.dailyAmount), text: $newDayTypeAmount)
                        .keyboardType(.decimalPad)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(HydrationStrings.ml))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                    Button(env.s(HydrationStrings.add)) { addDayType() }
                        .font(BadanFont.link)
                        .disabled(!canAddDayType)
                }
                .frame(minHeight: BadanSpace.touchMin)
            }
        }
    }

    private var canAddDayType: Bool {
        !newDayTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && HydrationLedger.parseVolumeMl(newDayTypeAmount) != nil
    }

    private func addDayType() {
        guard let amount = HydrationLedger.parseVolumeMl(newDayTypeAmount) else { return }
        let name = newDayTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if vm.setDayTypeGoal(name: name, targetMl: amount, env: env) {
            newDayTypeName = ""
            newDayTypeAmount = ""
            Announce.status(env.s(HydrationStrings.add))
        }
    }

    // MARK: Helpers

    private func choiceRow(title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BadanSpace.space3) {
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(title)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: BadanSpace.space2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.medium)
                    .foregroundStyle(selected ? BadanColor.primary : BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func amountText(_ ml: Double?) -> String {
        guard let ml else { return "" }
        return HydrationStrings.volume(ml, formatter: env.format, language: env.language)
    }

    private func primeIfNeeded() {
        guard !didPrime else { return }
        didPrime = true
        if let goal = vm.defaultGoal, goal.hasTarget, let target = goal.targetMl {
            mode = .manual
            manualAmount = env.format.integer(Int(target.rounded()))
        } else {
            mode = .none
        }
    }
}
