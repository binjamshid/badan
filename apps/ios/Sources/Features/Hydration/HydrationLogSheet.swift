import SwiftUI
import UIKit

/// The custom / edit sheet (plan §16.1): amount, beverage (from `beverages.json` + custom), time and
/// an optional note. Arabic volume entry works through `DecimalParsing` (the same path the ledger's
/// `parseVolumeMl` uses). Used both to log a new drink and to revise an existing one — a revision is
/// an append that supersedes the live row, never an in-place edit.
struct HydrationLogSheet: View {
    enum Mode: Equatable {
        case create
        case edit(HydrationEntry)
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool

    var vm: HydrationViewModel
    var mode: Mode

    @State private var amountText: String = ""
    @State private var beverageId: String = HydrationFluidType.water.rawValue
    @State private var occurredAt: Date = Date()
    @State private var note: String = ""
    @State private var userEditedAmount = false
    @State private var didPrime = false
    @State private var saveFailed = false

    private var isEditing: Bool { if case .edit = mode { return true } else { return false } }

    private var parsedAmount: Double? { HydrationLedger.parseVolumeMl(amountText) }

    private var canSave: Bool { parsedAmount != nil }

    private var isImplausible: Bool {
        guard let amount = parsedAmount else { return false }
        return HydrationPlausibility.isImplausible(amount)
    }

    private var maxDate: Date { env.now() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    amountCard
                    beverageCard
                    whenCard
                    noteCard
                    if isImplausible {
                        notice(env.s(HydrationStrings.implausibleNotice))
                    }
                    if saveFailed {
                        notice(env.s(HydrationStrings.saveFailed))
                    }
                }
                .padding(BadanSpace.space4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(isEditing ? HydrationStrings.editDrinkTitle : HydrationStrings.addDrink))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) { save() }
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(env.s(Loc.done)) { amountFocused = false }
                }
            }
            .task { primeIfNeeded() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Cards

    private var amountCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(env.s(HydrationStrings.amount))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                HStack(spacing: BadanSpace.space2) {
                    TextField(env.s(HydrationStrings.customAmount), text: $amountText)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                        .font(BadanFont.numeralM)
                        .foregroundStyle(BadanColor.textPrimary)
                        .onChange(of: amountText) { _, _ in userEditedAmount = true }
                    Text(env.s(HydrationStrings.ml))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private var beverageCard: some View {
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
    }

    private func beveragePill(_ beverage: HydrationBeverage) -> some View {
        let selected = beverage.id == beverageId
        return Button {
            beverageId = beverage.id
            // Pre-fill the amount from the drink's default only while the user hasn't typed one — a
            // starting suggestion, never an override of what they entered (defaultVolumeMl is not a target).
            if !userEditedAmount, let suggested = beverage.defaultVolumeMl {
                amountText = env.format.integer(Int(suggested.rounded()))
                userEditedAmount = false
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

    private var whenCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "clock")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(HydrationStrings.time))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                DatePicker("", selection: $occurredAt, in: ...maxDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    private var noteCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                TextField(env.s(HydrationStrings.noteOptional), text: $note, axis: .vertical)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .lineLimit(1...3)
                Text(env.s(HydrationStrings.noteRedactionHint))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notice(_ message: String) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            Text(message)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
        }
    }

    // MARK: Actions

    private func primeIfNeeded() {
        guard !didPrime else { return }
        didPrime = true
        switch mode {
        case .create:
            occurredAt = env.now()
        case .edit(let entry):
            amountText = env.format.integer(Int(entry.volumeMl.rounded()))
            beverageId = entry.beverageId ?? HydrationFluidType.water.rawValue
            occurredAt = min(entry.occurredAt, env.now())
            note = entry.note ?? ""
            userEditedAmount = true   // don't let a beverage tap overwrite the loaded amount
        }
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        let fluidType = vm.beverages.first(where: { $0.id == beverageId })?.fluidType
            ?? HydrationFluidType.water.rawValue
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteOrNil = trimmedNote.isEmpty ? nil : trimmedNote
        let succeeded: Bool
        switch mode {
        case .create:
            succeeded = vm.log(volumeMl: amount, fluidType: fluidType, beverageId: beverageId,
                               containerId: nil, occurredAt: occurredAt, note: noteOrNil,
                               favoriteName: nil, env: env)
        case .edit(let entry):
            succeeded = vm.revise(originalId: entry.originalId, volumeMl: amount, fluidType: fluidType,
                                  beverageId: beverageId, occurredAt: occurredAt, note: noteOrNil, env: env)
        }
        if succeeded {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            saveFailed = true
        }
    }
}
