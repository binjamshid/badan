import SwiftUI

// MARK: - Screen

/// EPIC-29 — the daily behaviour journal. **One screen, chips only, ten seconds.**
///
/// Plan §11 names chore fatigue as this epic's main risk, and the design answers it structurally
/// rather than with a reminder: everything is on one scroll, a tag is one tap, and "Yesterday" is a
/// first-class option beside "Today" instead of a date picker buried in a sheet. Nothing here has a
/// Save button — a tap IS the save — because a two-step flow over twenty-eight chips is the version
/// of this screen nobody opens twice.
///
/// **Two altitudes over one model.** Casual is the chip grid: tap what happened. Power adds an
/// amount stepper on the two counted behaviours and the two timed ones, plus free-text tags. Both
/// write the same `JournalEntry` rows through the same view model; there is no second logging path.
///
/// **I7.** The journal is sensitive-plus. When sensitive records are off this screen shows why
/// instead of chips — the rows live in `badan_sensitive.db` with medications and symptoms so that
/// "turn this off" stays a file deletion.
struct JournalScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = JournalViewModel()

    var body: some View {
        ScrollView {
            Group {
                if env.profile.sensitiveModulesEnabled {
                    loggingSurface
                } else {
                    sensitiveOffCard
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(JournalStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: JournalLoadKey(profile: env.profile, generation: env.dataGeneration, day: vm.day)) {
            guard env.profile.sensitiveModulesEnabled else { return }
            vm.load(env)
        }
    }

    private var loggingSurface: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            dayPicker
            trustNote
            if vm.day == .yesterday {
                note(JournalStrings.recallNote, symbol: "clock.arrow.circlepath")
            }
            if vm.loadFailed { inlineWarning(JournalStrings.loadFailed) }
            if vm.saveFailed { inlineWarning(JournalStrings.saveFailed) }
            note(JournalStrings.untappedNote, symbol: "hand.tap")

            ForEach(vm.groups) { group in
                JournalChipGroupView(group: group, vm: vm)
            }

            if env.depth.showsPowerDetail {
                JournalCustomTagsCard(vm: vm)
            }
            contextStatusLink
        }
    }

    // MARK: Day picker

    /// Today / Yesterday. A native segmented control rather than a bespoke pair of buttons: it is
    /// already the app's vocabulary for a two-way scope switch (`MedicationLogView`'s range picker),
    /// it mirrors correctly under RTL for free, and it is the one control on this screen a
    /// screen-reader user must be able to find without hunting.
    private var dayPicker: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Picker(env.s(JournalStrings.dayPickerLabel), selection: Binding(
                get: { vm.day },
                set: { vm.day = $0 }
            )) {
                ForEach(JournalDayChoice.allCases) { choice in
                    Text(choice.displayName, language: env.language).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text(JournalStrings.dayPickerLabel, language: env.language))

            Text(taggedCountText)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    private var taggedCountText: String {
        guard vm.taggedCount > 0 else { return env.s(JournalStrings.nothingTaggedYet) }
        return env.s(JournalStrings.taggedCount.filling(["n": env.format.integer(vm.taggedCount)]))
    }

    // MARK: Notes

    /// Plan §16's trust line for this row. Elevated above `caption`/`textSecondary` for the same
    /// reason `InsightsFooterNote` is: a privacy promise that renders like incidental metadata is a
    /// privacy promise nobody reads.
    private var trustNote: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "lock.shield")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(JournalStrings.trust, language: env.language)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: LocalizedString, symbol: String) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: symbol)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(text, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineWarning(_ text: LocalizedString) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.outOfBandOnTint)
                .accessibilityHidden(true)
            Text(text, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Context statuses

    private var contextStatusLink: some View {
        NavigationLink { ContextStatusManagerView() } label: {
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BadanColor.primary)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(JournalStrings.contextTitle, language: env.language)
                            .font(BadanFont.bodyCompact.weight(.medium))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(JournalStrings.contextLinkSubtitle, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: "chevron.forward")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BadanSpace.touchMin)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Sensitive off

    private var sensitiveOffCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(JournalStrings.sensitiveOffTitle, language: env.language)
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(JournalStrings.sensitiveOffMessage, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The standardized `.task(id:)` identity — see `HomeLoadKey` (`HomeScreen.swift`), plus the day on
/// screen so switching to Yesterday reloads without a second observer.
private struct JournalLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
    let day: JournalDayChoice
}

// MARK: - One chip group

private struct JournalChipGroupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let group: JournalChipGroup
    let vm: JournalViewModel

    /// An adaptive grid rather than a wrapping flow layout: SwiftUI's grids mirror under RTL on
    /// their own, where a custom `Layout` places its subviews left-to-right regardless of direction.
    /// The minimum width keeps a long label ("Noisy or interrupted night") readable instead of
    /// scaled down to nothing; at accessibility text sizes it is raised past a phone's width so the
    /// grid becomes a single column, which is the right answer there rather than a fallback.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 320 : 150),
                  spacing: BadanSpace.space2)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(group.heading, language: env.language)
            LazyVGrid(columns: columns, alignment: .leading, spacing: BadanSpace.space2) {
                ForEach(group.chips) { chip in
                    JournalChipButton(chip: chip, vm: vm)
                }
            }
        }
    }
}

// MARK: - One chip

/// A behaviour chip. Casual: a toggle. Power: a toggle that grows an amount stepper once it's on,
/// for the four dictionary behaviours that carry a shape (two counts, two durations).
private struct JournalChipButton: View {
    @Environment(AppEnvironment.self) private var env
    let chip: JournalChip
    let vm: JournalViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            toggleButton
            if showsAmountRow { amountRow }
        }
        .padding(.horizontal, BadanSpace.space3)
        .padding(.vertical, BadanSpace.space2)
        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin, alignment: .leading)
        .background(
            chip.isOn ? BadanColor.primary.opacity(0.14) : BadanColor.surface,
            in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                .strokeBorder(chip.isOn ? BadanColor.primary.opacity(0.55) : BadanColor.separator, lineWidth: 1))
    }

    private var toggleButton: some View {
        Button { vm.toggle(chip, env: env) } label: {
            HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                // Colour is never the only signal: a filled circle marks a tagged chip for anyone
                // who can't rely on the tint.
                Image(systemName: chip.isOn ? "checkmark.circle.fill" : "circle")
                    .imageScale(.small)
                    .foregroundStyle(chip.isOn ? BadanColor.primary : BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(chip.behavior.displayName, language: env.language)
                    .font(BadanFont.chip)
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let amountText { amountBadge(amountText) }
            }
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin - BadanSpace.space2, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // §16 asks for chip toggles to read as switches. `.isToggle` gives VoiceOver the switch
        // semantics; the value says logged/not logged rather than a bare on/off, which is what the
        // tap actually asserts.
        .accessibilityAddTraits(.isToggle)
        .accessibilityAddTraits(chip.isOn ? .isSelected : [])
        .accessibilityLabel(Text(chip.behavior.displayName, language: env.language))
        .accessibilityValue(Text(chip.isOn ? JournalStrings.logged : JournalStrings.notLogged,
                                 language: env.language))
    }

    /// The amount stepper appears only at power depth, only once the chip is on, and only for a
    /// behaviour the dictionary gives a shape. Casual never sees it — a casual tap deliberately
    /// stores no number (see `JournalViewModel.toggle`).
    private var showsAmountRow: Bool {
        env.depth.showsPowerDetail && chip.isOn && chip.offersAmount
    }

    /// `−` is disabled until an amount exists. A tagged chip with no number is the normal state
    /// (a casual tap stores none), and stepping down from "no amount" would untag the behaviour —
    /// a destructive answer to a button that looks like it edits a number.
    private var amountRow: some View {
        HStack(spacing: BadanSpace.space2) {
            stepperButton(symbol: "minus", label: JournalStrings.decreaseAmount, delta: -chip.amountStep)
                .disabled(chip.amount == nil)
                .opacity(chip.amount == nil ? 0.35 : 1)
            Text(amountText ?? env.s(JournalStrings.amountNotSet))
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(amountText == nil ? BadanColor.textSecondary : BadanColor.textPrimary)
                .frame(minWidth: 44)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
            stepperButton(symbol: "plus", label: JournalStrings.increaseAmount, delta: chip.amountStep)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(JournalStrings.amount, language: env.language))
        .accessibilityValue(amountText ?? env.s(JournalStrings.amountNotSet))
    }

    private func stepperButton(symbol: String, label: LocalizedString, delta: Double) -> some View {
        Button {
            vm.setAmount(chip, to: (chip.amount ?? 0) + delta, env: env)
        } label: {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(BadanColor.primary)
                .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin - BadanSpace.space2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label, language: env.language))
    }

    /// The amount as text: "3" for a count, "20 min" for a duration. Nil when nothing was recorded —
    /// a tapped chip with no number shows no number rather than a zero.
    private var amountText: String? {
        guard let amount = chip.amount, amount > 0 else { return nil }
        let value = env.format.integer(Int(amount.rounded()))
        guard let unit = chip.amountUnit else { return value }
        return "\(value) \(env.s(unit))"
    }

    private func amountBadge(_ text: String) -> some View {
        Text(text)
            .font(BadanFont.caption.monospacedDigit())
            .foregroundStyle(BadanColor.primary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

// MARK: - Free-text tags (power depth)

/// The power-depth "your own tags" card. Free text is stored and exported like everything else and
/// is deliberately NOT correlated — the card says so, because a power user who logs their own tags
/// for a month and sees no findings deserves the reason rather than the appearance of a bug.
private struct JournalCustomTagsCard: View {
    @Environment(AppEnvironment.self) private var env
    let vm: JournalViewModel
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(JournalStrings.ownTagsTitle, language: env.language)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    ForEach(vm.customEntries) { entry in
                        customTagRow(entry)
                    }
                    HStack(spacing: BadanSpace.space2) {
                        TextField(env.s(JournalStrings.ownTagPlaceholder), text: $draft)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button(env.s(JournalStrings.addTag), action: add)
                            .font(BadanFont.link)
                            .foregroundStyle(BadanColor.primary)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    Text(JournalStrings.ownTagsNote, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func customTagRow(_ entry: JournalEntry) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "tag")
                .imageScale(.small)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(entry.customLabel ?? "")
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: BadanSpace.space2)
            Button { vm.removeCustomTag(entry, env: env) } label: {
                Image(systemName: "xmark.circle")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
                    .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(JournalStrings.contextDelete, language: env.language))
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private func add() {
        guard vm.addCustomTag(draft, env: env) else { return }
        draft = ""
        fieldFocused = false
    }
}
