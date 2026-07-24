import SwiftUI

// MARK: - A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice) — the module's single screen.
//
// Grounded in `docs/BADAN_PREGNANCY_CALENDAR_RESEARCH.md` §9 and
// `docs/legal/reproductive-threat-model.md` — read both before touching this file's copy. Mirrors
// `CycleConsentScreen`'s dual-role pattern: ONE screen, switched purely on
// `env.profile.pregnancyModuleMode`:
//   - `.off`: the onboarding/consent explainer, ending in a single "Turn on pregnancy tracking"
//     action.
//   - `.on`: the same screen re-purposed as the module's home — journey status, due-date entry,
//     mode transitions, the ALWAYS-REACHABLE "declare a loss" action, and purge.
//
// P0 SCOPE NOTE: this is deliberately the module's ONLY screen (no separate "PregnancyHomeScreen").
// Recon's own P0 recommendation ships PREG-03 as a versioned CONTENT SHELL, not real week-by-week
// content — building a separate, deeper home screen now would be UI depth ahead of the content it
// would need to show. Everything this slice's non-negotiable requirements need (module gating, a
// dedicated consent screen, loss declaration reachable in 1-2 taps from anywhere in the module,
// due-date provenance always shown, purge) is satisfied by this one screen.
//
// Per the threat model's "new, specific to this phase" mitigations (mirroring `CycleConsentScreen`'s
// own copy discipline exactly): no sync-consent toggle, no cloud-AI-consent toggle, and no
// partner-sharing toggle are built here, because none of those capabilities exist yet (PREG-12 stays
// explicitly deferred). The copy below states these facts plainly instead of offering a toggle for
// something that doesn't exist.
struct PregnancyConsentScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var services: PregnancyModuleServices?
    @State private var showPurgeConfirm = false
    @State private var showLossSheet = false
    @State private var transientNotice: LocalizedString?

    // Journey state, refreshed after every write.
    @State private var journey: PregnancyRecord?
    @State private var dueDateEstimate: DueDateEstimate?
    // Every live loss declaration across every journey — the revisit UI (loss-handling audit
    // finding 2) reads this, not just the sheet that created one.
    @State private var lossDeclarations: [LossDeclarationRecord] = []
    @State private var pendingDeleteDeclarationId: String?
    @State private var showDeleteDeclarationConfirm = false

    // Due-date entry form state.
    @State private var dueDateSourceType: DueDateSourceType = .lmpBased
    @State private var dueDateEnteredDate = Date()

    // Loss-declaration sheet state.
    @State private var lossApproximateDate = Date()
    @State private var lossStage: LossGestationalStage?
    @State private var lossNote: String = ""
    @State private var lossDisposition: LossDataDisposition = .keep

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if env.profile.pregnancyModuleMode == .on {
                    settingsContent
                } else {
                    onboardingContent
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(PregnancyConsentStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice = transientNotice {
                SettingsTransientNotice(notice: notice)
            }
        }
        .confirmationDialog(
            env.s(PregnancyConsentStrings.purgeConfirmTitle),
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(PregnancyConsentStrings.purgeConfirmAction), role: .destructive) {
                performPurge()
            }
            Button(env.s(Loc.cancel), role: .cancel) {}
        } message: {
            Text(env.s(PregnancyConsentStrings.purgeConfirmMessage))
        }
        .confirmationDialog(
            env.s(PregnancyConsentStrings.deleteDeclarationConfirmTitle),
            isPresented: $showDeleteDeclarationConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(PregnancyConsentStrings.deleteDeclarationConfirmAction), role: .destructive) {
                performDeleteDeclarationData()
            }
            Button(env.s(Loc.cancel), role: .cancel) { pendingDeleteDeclarationId = nil }
        } message: {
            Text(env.s(PregnancyConsentStrings.deleteDeclarationConfirmMessage))
        }
        .sheet(isPresented: $showLossSheet) {
            lossDeclarationSheet
        }
        .task {
            if services == nil {
                services = PregnancyModuleServices(env: env)
            }
            refreshJourneyState()
        }
    }

    private func refreshJourneyState() {
        guard let services else { return }
        journey = try? services.liveJourney()
        dueDateEstimate = try? services.currentDueDateEstimate()
        lossDeclarations = (try? services.allLossDeclarations()) ?? []
    }

    // MARK: - Onboarding (pregnancyModuleMode == .off)

    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            Text(env.s(PregnancyConsentStrings.introBody))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    consentPoint(icon: "iphone", text: PregnancyConsentStrings.pointLocalFirst)
                    consentPoint(icon: "hand.raised", text: PregnancyConsentStrings.pointNeverInferred)
                    consentPoint(icon: "heart.text.square", text: PregnancyConsentStrings.pointLossHandling)
                    consentPoint(icon: "cloud.slash", text: PregnancyConsentStrings.pointNoCloudAI)
                    consentPoint(icon: "person.2.slash", text: PregnancyConsentStrings.pointNoSharing)
                    consentPoint(icon: "trash", text: PregnancyConsentStrings.pointHideOrDelete)
                }
            }

            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "info.circle")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(PregnancyConsentStrings.noSingleDateNote))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                env.update { $0.pregnancyModuleMode = .on }
            } label: {
                Text(env.s(PregnancyConsentStrings.enableAction))
                    .font(BadanFont.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.borderedProminent)
            .tint(BadanColor.primary)
        }
    }

    private func consentPoint(icon: String, text: LocalizedString) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(BadanColor.primary)
                .frame(width: BadanSpace.space5)
                .accessibilityHidden(true)
            Text(env.s(text))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings/home (pregnancyModuleMode == .on)

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(PregnancyConsentStrings.moduleSectionHeader))
                BadanCard {
                    SettingsToggleRow(
                        title: PregnancyConsentStrings.moduleToggleTitle,
                        subtitle: PregnancyConsentStrings.moduleToggleSubtitle,
                        isOn: Binding(
                            get: { env.profile.pregnancyModuleMode == .on },
                            set: { newValue in env.update { $0.pregnancyModuleMode = newValue ? .on : .off } }
                        )
                    )
                }
            }

            journeySection

            if let journey, journey.mode.canDeclareLossFromThisMode {
                lossEntryPointSection
            }

            lossDeclarationsSection

            if journey != nil {
                dataSection
            }

            // PREG-03 (P0 shell): the mandatory, identically-rendered disclaimer — this screen is
            // the closest thing to a "content surface" this P0 slice ships (it shows the due-date
            // estimate, the nearest thing to pregnancy content that exists yet), so it renders here.
            // Any FUTURE real content screen (once D-21 clears) must render this SAME component.
            if journey != nil {
                PregnancyContentDisclaimerFooter()
            }
        }
    }

    // MARK: - Journey section

    @ViewBuilder
    private var journeySection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(PregnancyConsentStrings.journeySectionHeader))
            if let journey {
                BadanCard {
                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        Text(journey.mode.displayName, language: env.language)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        if journey.mode == .pregnancyConfirmed || journey.mode == .latePregnancy {
                            dueDateSummary
                        }
                        transitionButtons(for: journey)
                    }
                }
                // Loss-handling audit finding 1 (CRITICAL): `.lossDeclared` is terminal for THIS
                // journey's own chain, but it must never be the only thing standing between a
                // grieving user and a genuinely new, separate journey — this card is reachable in
                // the SAME screen state that also still shows "Loss recorded" above, with no need to
                // delete or purge anything first (`PregnancyJourneyMode.blocksNewJourney`).
                if journey.mode == .lossDeclared {
                    beginJourneyCard(intro: PregnancyConsentStrings.newJourneyAfterLossIntro)
                }
            } else {
                beginJourneyCard(intro: PregnancyConsentStrings.noJourneyBody)
            }
        }
    }

    private func beginJourneyCard(intro: LocalizedString) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                Text(env.s(intro))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    performBegin(.beginTTC)
                } label: {
                    Text(env.s(PregnancyConsentStrings.beginTTCAction))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                }
                .buttonStyle(.bordered)
                Button {
                    performBegin(.beginPregnancyConfirmed)
                } label: {
                    Text(env.s(PregnancyConsentStrings.beginPregnancyConfirmedAction))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                }
                .buttonStyle(.borderedProminent)
                .tint(BadanColor.primary)
            }
        }
    }

    /// Due-date provenance display — ALWAYS shows the source alongside the range, never a bare date
    /// (this module's own non-negotiable requirement #3), plus a minimal entry form.
    private var dueDateSummary: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            if let estimate = dueDateEstimate, estimate.hasRange, let low = estimate.rangeLow,
               let high = estimate.rangeHigh, let sourceType = estimate.resolvedSourceType {
                Text(PregnancyConsentStrings.dueDateRangeText(low: low, high: high, language: env.language))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textPrimary)
                HStack(spacing: BadanSpace.space1) {
                    Image(systemName: "info.circle")
                        .imageScale(.small)
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(sourceType.displayName, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            } else {
                Text(env.s(PregnancyConsentStrings.noDueDateYet))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }

            DisclosureGroup(env.s(PregnancyConsentStrings.addDueDateSourceAction)) {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    Picker(env.s(PregnancyConsentStrings.dueDateSourceTypeLabel), selection: $dueDateSourceType) {
                        ForEach(DueDateSourceType.allCases, id: \.self) { type in
                            Text(type.displayName, language: env.language).tag(type)
                        }
                    }
                    DatePicker(env.s(PregnancyConsentStrings.dueDateEnteredDateLabel),
                              selection: $dueDateEnteredDate, displayedComponents: .date)
                    Button {
                        saveDueDateSource()
                    } label: {
                        Text(env.s(Loc.save))
                            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, BadanSpace.space2)
            }
            .font(BadanFont.caption)
        }
    }

    @ViewBuilder
    private func transitionButtons(for journey: PregnancyRecord) -> some View {
        let legal = PregnancyModeController.legalTransitions[journey.mode] ?? []
        if legal.contains(.confirmPregnancy) {
            transitionButton(.confirmPregnancy, title: PregnancyConsentStrings.confirmPregnancyAction)
        }
        if legal.contains(.declareLatePregnancy) {
            transitionButton(.declareLatePregnancy, title: PregnancyConsentStrings.declareLatePregnancyAction)
        }
        if legal.contains(.declareBirth) {
            transitionButton(.declareBirth, title: PregnancyConsentStrings.declareBirthAction)
        }
        if legal.contains(.declarePostpartumHandoff) {
            transitionButton(.declarePostpartumHandoff, title: PregnancyConsentStrings.declarePostpartumAction)
        }
    }

    private func transitionButton(_ request: PregnancyModeTransitionRequest, title: LocalizedString) -> some View {
        Button {
            performTransition(request)
        } label: {
            Text(env.s(title)).frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Loss entry point — ALWAYS reachable (1-2 taps) whenever the current mode allows it,
    // never buried behind another navigation layer, per this module's own non-negotiable requirement.

    private var lossEntryPointSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            BadanCard {
                Button {
                    showLossSheet = true
                } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "heart.slash")
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(env.s(PregnancyConsentStrings.declareLossEntryTitle))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Loss declarations: the revisit UI (loss-handling audit finding 2). The data-
    // disposition choice made in the moment of loss is NOT one-time-forced — every live declaration
    // (across every journey this profile ever recorded, not only the current one) is listed here,
    // and its disposition can be changed anytime, the same "revisitable later" guarantee
    // `PregnancyModuleServices.updateLossDataDisposition`'s own doc names.
    @ViewBuilder
    private var lossDeclarationsSection: some View {
        if !lossDeclarations.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(PregnancyConsentStrings.lossDeclarationsSectionHeader))
                ForEach(lossDeclarations, id: \.id) { declaration in
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space3) {
                            Text(PregnancyConsentStrings.lossDeclarationDateText(
                                declaration.approximateDate, language: env.language))
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.textPrimary)
                            Picker(env.s(PregnancyConsentStrings.lossDispositionLabel),
                                  selection: dispositionBinding(for: declaration)) {
                                ForEach(LossDataDisposition.allCases, id: \.self) { disposition in
                                    Text(dispositionDisplayName(disposition), language: env.language).tag(disposition)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(env.s(PregnancyConsentStrings.lossDispositionFootnote))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    /// A binding that intercepts a change TO `.delete` and routes it through the same confirmation
    /// dialog `showPurgeConfirm` uses for the whole-module purge — changing to `.delete` here is a
    /// real, irreversible erasure (`PregnancyModuleServices.purgeJourneyData(originalId:)`), never a
    /// silent picker tap. `.keep`/`.archive` apply immediately, matching this choice's own
    /// "unpressured, revisitable" framing.
    private func dispositionBinding(for declaration: LossDeclarationRecord) -> Binding<LossDataDisposition> {
        Binding(
            get: { declaration.dataDisposition },
            set: { newValue in
                if newValue == .delete {
                    pendingDeleteDeclarationId = declaration.id
                    showDeleteDeclarationConfirm = true
                } else {
                    changeDisposition(id: declaration.id, to: newValue)
                }
            })
    }

    private var lossDeclarationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(env.s(PregnancyConsentStrings.lossSheetIntro))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(env.s(PregnancyConsentStrings.lossApproximateDateLabel)) {
                    DatePicker(env.s(PregnancyConsentStrings.lossApproximateDateLabel),
                              selection: $lossApproximateDate, displayedComponents: .date)
                        .labelsHidden()
                }
                Section(env.s(PregnancyConsentStrings.lossStageLabel)) {
                    Picker(env.s(PregnancyConsentStrings.lossStageLabel), selection: $lossStage) {
                        Text(env.s(PregnancyConsentStrings.lossStagePreferNotToSay)).tag(LossGestationalStage?.none)
                        ForEach(LossGestationalStage.allCases, id: \.self) { stage in
                            Text(stageDisplayName(stage), language: env.language).tag(LossGestationalStage?.some(stage))
                        }
                    }
                    .labelsHidden()
                }
                Section(env.s(PregnancyConsentStrings.lossNoteLabel)) {
                    TextField(env.s(PregnancyConsentStrings.lossNoteLabel), text: $lossNote, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section(env.s(PregnancyConsentStrings.lossDispositionLabel)) {
                    Picker(env.s(PregnancyConsentStrings.lossDispositionLabel), selection: $lossDisposition) {
                        ForEach(LossDataDisposition.allCases, id: \.self) { disposition in
                            Text(dispositionDisplayName(disposition), language: env.language).tag(disposition)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(env.s(PregnancyConsentStrings.lossDispositionFootnote))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                Section {
                    // Loss-handling audit finding 3: declaring a loss is not itself a destructive
                    // action in this module's data model (I2 — nothing is erased for `.keep`/
                    // `.archive`), so the red "danger" button treatment only belongs here when the
                    // chosen disposition genuinely IS destructive — i.e. the user picked `.delete`,
                    // which now really does erase this journey's data (general audit finding 1).
                    // For the far more common `.keep`/`.archive` choice, this stays a normal,
                    // unalarming confirm action — matching the warm, non-clinical tone of the copy
                    // directly above it.
                    if lossDisposition == .delete {
                        Button(role: .destructive) {
                            confirmLoss()
                        } label: {
                            Text(env.s(PregnancyConsentStrings.lossConfirmAction))
                                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        }
                    } else {
                        Button {
                            confirmLoss()
                        } label: {
                            Text(env.s(PregnancyConsentStrings.lossConfirmAction))
                                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BadanColor.primary)
                    }
                }
            }
            .navigationTitle(env.s(PregnancyConsentStrings.lossSheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { showLossSheet = false }
                }
            }
        }
    }

    private func stageDisplayName(_ stage: LossGestationalStage) -> LocalizedString {
        switch stage {
        case .earlyPregnancy: return LocalizedString(en: "Early pregnancy", ar: "حمل مبكر")
        case .midPregnancy: return LocalizedString(en: "Mid pregnancy", ar: "حمل متوسط")
        case .latePregnancy: return LocalizedString(en: "Late pregnancy", ar: "حمل متأخر")
        case .unspecified: return LocalizedString(en: "Not specified", ar: "غير محدد")
        }
    }

    private func dispositionDisplayName(_ disposition: LossDataDisposition) -> LocalizedString {
        switch disposition {
        case .keep: return LocalizedString(en: "Keep", ar: "الاحتفاظ")
        case .archive: return LocalizedString(en: "Archive", ar: "أرشفة")
        case .delete: return LocalizedString(en: "Delete", ar: "حذف")
        }
    }

    // MARK: - Data section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(PregnancyConsentStrings.dataSectionHeader))
            BadanCard {
                Button {
                    showPurgeConfirm = true
                } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "trash")
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.outOfBand)
                            .accessibilityHidden(true)
                        Text(env.s(PregnancyConsentStrings.purgeActionTitle))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(env.s(PregnancyConsentStrings.purgeFootnote))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func performBegin(_ request: PregnancyModeTransitionRequest) {
        guard let services else { return }
        do {
            try services.beginJourney(request, asOf: env.now())
            refreshJourneyState()
            Announce.status(env.s(PregnancyConsentStrings.journeyStartedNotice))
        } catch {
            showTransientNotice(PregnancyConsentStrings.genericErrorNotice)
        }
    }

    private func performTransition(_ request: PregnancyModeTransitionRequest) {
        guard let services else { return }
        do {
            try services.applyTransition(request, asOf: env.now())
            refreshJourneyState()
            Announce.status(env.s(PregnancyConsentStrings.journeyUpdatedNotice))
        } catch {
            showTransientNotice(PregnancyConsentStrings.genericErrorNotice)
        }
    }

    private func saveDueDateSource() {
        guard let services else { return }
        do {
            try services.recordDueDateSource(sourceType: dueDateSourceType, enteredDate: dueDateEnteredDate,
                                             asOf: env.now())
            refreshJourneyState()
            Announce.status(env.s(PregnancyConsentStrings.dueDateSavedNotice))
        } catch {
            showTransientNotice(PregnancyConsentStrings.genericErrorNotice)
        }
    }

    private func confirmLoss() {
        guard let services else { return }
        let note = lossNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let disposition = lossDisposition
        Task {
            do {
                try await services.declareLoss(
                    approximateDate: lossApproximateDate, gestationalStage: lossStage,
                    freeTextNote: note.isEmpty ? nil : note, dataDisposition: disposition,
                    asOf: env.now())
                await MainActor.run {
                    refreshJourneyState()
                    showLossSheet = false
                    // `.delete` really did erase this journey's data now (general audit finding 1)
                    // — the notice must say so honestly rather than reusing the "we stopped
                    // forward-looking notes" copy, which implies the journey still exists.
                    let notice = disposition == .delete
                        ? PregnancyConsentStrings.lossAcknowledgedAndDeletedNotice
                        : PregnancyConsentStrings.lossAcknowledgedNotice
                    Announce.status(env.s(notice))
                }
            } catch {
                await MainActor.run { showTransientNotice(PregnancyConsentStrings.genericErrorNotice) }
            }
        }
    }

    /// Applies an immediate, non-destructive disposition change (`.keep`/`.archive`) — routed
    /// through `dispositionBinding(for:)`, which never calls this for `.delete`.
    private func changeDisposition(id: String, to disposition: LossDataDisposition) {
        guard let services else { return }
        do {
            try services.updateLossDataDisposition(id: id, disposition: disposition, asOf: env.now())
            refreshJourneyState()
            Announce.status(env.s(PregnancyConsentStrings.dispositionUpdatedNotice))
        } catch {
            showTransientNotice(PregnancyConsentStrings.genericErrorNotice)
        }
    }

    /// The confirmed, irreversible erasure a revisited `.delete` choice performs — reached only
    /// after `showDeleteDeclarationConfirm`'s dialog is explicitly accepted.
    private func performDeleteDeclarationData() {
        guard let services, let id = pendingDeleteDeclarationId else { return }
        do {
            try services.updateLossDataDisposition(id: id, disposition: .delete, asOf: env.now())
            pendingDeleteDeclarationId = nil
            refreshJourneyState()
            Announce.status(env.s(PregnancyConsentStrings.dispositionDeletedNotice))
        } catch {
            pendingDeleteDeclarationId = nil
            showTransientNotice(PregnancyConsentStrings.genericErrorNotice)
        }
    }

    private func performPurge() {
        guard let services else { return }
        do {
            try services.purgePregnancyData()
            refreshJourneyState()
            Announce.status(env.s(PregnancyConsentStrings.purgeSucceededNotice))
        } catch {
            showTransientNotice(PregnancyConsentStrings.purgeFailedNotice)
        }
    }

    private func showTransientNotice(_ notice: LocalizedString) {
        transientNotice = notice
        Announce.failure(env.s(notice))
        Task {
            try? await Task.sleep(for: .seconds(3))
            if transientNotice == notice { transientNotice = nil }
        }
    }
}

// MARK: - Screen-local strings

private enum PregnancyConsentStrings {
    static let title = LocalizedString(en: "Pregnancy tracking", ar: "متابعة الحمل")

    static let introBody = LocalizedString(
        en: "Track a pregnancy journey privately, entirely at your own pace and by your own choice. "
            + "BADAN never guesses — you tell it when to start, when to change stage, and if it ever "
            + "ends in loss.",
        ar: "تابع رحلة حملك بخصوصية وبالوتيرة التي تختارها بنفسك تمامًا. لا يخمّن BADAN أبدًا — أنت "
            + "من يخبره متى يبدأ، ومتى تتغيّر المرحلة، وإن انتهت الرحلة بفقدان.")

    static let pointLocalFirst = LocalizedString(
        en: "Stored on this device by default, in BADAN's own protected storage.",
        ar: "محفوظة على جهازك افتراضيًا، في التخزين المحمي الخاص بـ BADAN.")
    static let pointNeverInferred = LocalizedString(
        en: "Never inferred. Nothing about a pregnancy is ever guessed from your cycle data, missed "
            + "periods, or symptoms — only what you explicitly tell BADAN.",
        ar: "لا يُستنتج أبدًا. لا شيء عن الحمل يُخمَّن من بيانات دورتك أو الدورات الفائتة أو "
            + "الأعراض — فقط ما تخبر به BADAN صراحة.")
    static let pointLossHandling = LocalizedString(
        en: "If this journey ever ends in loss, you can say so in a couple of taps, from anywhere in "
            + "this module. Every forward-looking note stops immediately, and nothing you already "
            + "logged is ever erased.",
        ar: "إذا انتهت هذه الرحلة بفقدان، يمكنك تسجيل ذلك خلال لمستين من أي مكان في هذه الوحدة. "
            + "تتوقف فورًا كل الملاحظات التطلعية، ولا يُحذف أي شيء سبق أن سجّلته.")
    static let pointNoCloudAI = LocalizedString(
        en: "Excluded from cloud AI. There's no cloud-AI feature for this data, and none of it is "
            + "sent anywhere by default.",
        ar: "مستبعدة من الذكاء الاصطناعي السحابي. لا توجد ميزة ذكاء اصطناعي سحابي لهذه البيانات، "
            + "ولا يُرسَل أي منها إلى أي مكان افتراضيًا.")
    static let pointNoSharing = LocalizedString(
        en: "No sharing feature exists for this data yet.",
        ar: "لا توجد ميزة مشاركة لهذه البيانات حاليًا.")
    static let pointHideOrDelete = LocalizedString(
        en: "You can hide the module or permanently delete everything, anytime, from this same screen.",
        ar: "يمكنك إخفاء الوحدة أو حذف كل شيء نهائيًا، في أي وقت، من هذه الشاشة نفسها.")

    static let noSingleDateNote = LocalizedString(
        en: "BADAN never shows a due date without also showing where it came from — only a range, "
            + "with its source. Any pattern notes stay calm and non-diagnostic.",
        ar: "لا يعرض BADAN أبدًا موعد ولادة متوقعًا دون توضيح مصدره — بل نطاقًا زمنيًا مع مصدره. "
            + "وأي ملاحظات تبقى هادئة وغير تشخيصية.")

    static let enableAction = LocalizedString(en: "Turn on pregnancy tracking", ar: "تفعيل متابعة الحمل")

    static let moduleSectionHeader = LocalizedString(en: "Pregnancy tracking", ar: "متابعة الحمل")
    static let moduleToggleTitle = LocalizedString(en: "Pregnancy tracking", ar: "متابعة الحمل")
    static let moduleToggleSubtitle = LocalizedString(
        en: "Turn this off to hide the module. Your journey stays saved — turning it back on picks "
            + "up right where you left off.",
        ar: "أوقف هذا لإخفاء الوحدة. تبقى رحلتك محفوظة — وعند إعادة التفعيل تستأنف من حيث توقفت.")

    static let journeySectionHeader = LocalizedString(en: "Your journey", ar: "رحلتك")
    static let noJourneyBody = LocalizedString(
        en: "You haven't started a journey yet. Choose what applies to you — you can change this "
            + "later.",
        ar: "لم تبدأ رحلة بعد. اختر ما ينطبق عليك — يمكنك تغيير ذلك لاحقًا.")
    static let beginTTCAction = LocalizedString(en: "I'm trying to conceive", ar: "أحاول الإنجاب")
    static let beginPregnancyConfirmedAction = LocalizedString(en: "I'm pregnant", ar: "أنا حامل")

    // Loss-handling audit finding 1: shown alongside "Loss recorded" once a loss has been declared
    // — never "start over" framing, never a timeline, and an explicit reassurance that the loss
    // stays in the record rather than being an obstacle to clear first.
    static let newJourneyAfterLossIntro = LocalizedString(
        en: "When you're ready — there's no timeline for this — you can start a new journey. This "
            + "one stays in your history exactly as it is.",
        ar: "عندما تكون مستعدًا — لا يوجد إطار زمني لذلك — يمكنك بدء رحلة جديدة. تبقى هذه الرحلة في "
            + "سجلك كما هي تمامًا.")

    static let confirmPregnancyAction = LocalizedString(en: "Confirm pregnancy", ar: "تأكيد الحمل")
    static let declareLatePregnancyAction = LocalizedString(en: "This is now late pregnancy", ar: "أصبح الحمل الآن متأخرًا")
    static let declareBirthAction = LocalizedString(en: "Log birth", ar: "تسجيل الولادة")
    static let declarePostpartumAction = LocalizedString(en: "Move to postpartum", ar: "الانتقال إلى ما بعد الولادة")

    static let noDueDateYet = LocalizedString(
        en: "No due-date information yet.", ar: "لا توجد معلومات عن موعد الولادة بعد.")
    static let addDueDateSourceAction = LocalizedString(en: "Add or update a due-date source", ar: "إضافة أو تحديث مصدر موعد الولادة")
    static let dueDateSourceTypeLabel = LocalizedString(en: "Source", ar: "المصدر")
    static let dueDateEnteredDateLabel = LocalizedString(en: "Date", ar: "التاريخ")

    static func dueDateRangeText(low: Date, high: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: language == .ar ? "ar" : "en")
        let lowText = formatter.string(from: low)
        let highText = formatter.string(from: high)
        switch language {
        case .en: return "Estimated due date: \(lowText) – \(highText)"
        case .ar: return "موعد الولادة المتوقع: \(lowText) – \(highText)"
        }
    }

    static let declareLossEntryTitle = LocalizedString(en: "Declare a loss", ar: "تسجيل فقدان")

    static let lossSheetTitle = LocalizedString(en: "Declare a loss", ar: "تسجيل فقدان")
    static let lossSheetIntro = LocalizedString(
        en: "We're sorry. Whatever you share here is entirely optional beyond the date — take your "
            + "time. Your history stays exactly as it is; only what BADAN shows you going forward "
            + "changes.",
        ar: "نأسف لما تمرّ به. كل ما تشاركه هنا اختياري تمامًا باستثناء التاريخ — خذ وقتك. يبقى "
            + "سجلك كما هو تمامًا؛ فقط ما يعرضه BADAN لك مستقبلًا هو ما يتغيّر.")
    static let lossApproximateDateLabel = LocalizedString(en: "Approximate date", ar: "التاريخ التقريبي")
    static let lossStageLabel = LocalizedString(en: "Stage (optional)", ar: "المرحلة (اختياري)")
    static let lossStagePreferNotToSay = LocalizedString(en: "Prefer not to say", ar: "أفضّل عدم القول")
    static let lossNoteLabel = LocalizedString(en: "Note (optional)", ar: "ملاحظة (اختياري)")
    static let lossDispositionLabel = LocalizedString(en: "What should happen to this data?", ar: "ماذا يحدث لهذه البيانات؟")
    static let lossDispositionFootnote = LocalizedString(
        en: "You can change this choice anytime. Nothing is erased unless you choose Delete.",
        ar: "يمكنك تغيير هذا الاختيار في أي وقت. لا يُحذف شيء ما لم تختر الحذف.")
    static let lossConfirmAction = LocalizedString(en: "Record this", ar: "تسجيل هذا")
    static let lossAcknowledgedNotice = LocalizedString(
        en: "We've recorded this, and stopped forward-looking notes for this journey.",
        ar: "لقد سجّلنا هذا، وأوقفنا الملاحظات التطلعية لهذه الرحلة.")
    // Shown instead of `lossAcknowledgedNotice` only when the user chose "Delete" — that choice now
    // really does erase this journey's data (general audit finding 1), so the notice says so plainly
    // rather than implying the journey is still there, just quieter.
    static let lossAcknowledgedAndDeletedNotice = LocalizedString(
        en: "We've deleted this, as you asked.", ar: "لقد حذفنا هذا بناءً على طلبك.")

    // MARK: Loss declarations — revisit UI (loss-handling audit finding 2)

    static let lossDeclarationsSectionHeader = LocalizedString(en: "Loss records", ar: "سجلات الفقدان")

    static func lossDeclarationDateText(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: language == .ar ? "ar" : "en")
        let text = formatter.string(from: date)
        switch language {
        case .en: return "Loss recorded — \(text)"
        case .ar: return "فقدان مُسجَّل — \(text)"
        }
    }

    static let dispositionUpdatedNotice = LocalizedString(en: "Choice updated.", ar: "تم تحديث الاختيار.")
    static let dispositionDeletedNotice = LocalizedString(
        en: "This data has been deleted.", ar: "تم حذف هذه البيانات.")

    static let deleteDeclarationConfirmTitle = LocalizedString(en: "Delete this data?", ar: "حذف هذه البيانات؟")
    static let deleteDeclarationConfirmMessage = LocalizedString(
        en: "This permanently deletes this journey's full history — every entry, every due-date "
            + "source, and this loss record. This can't be undone.",
        ar: "سيؤدي هذا إلى حذف نهائي للسجل الكامل لهذه الرحلة — كل إدخال، ومصدر موعد ولادة، وسجل "
            + "الفقدان هذا. لا يمكن التراجع عن هذا الإجراء.")
    static let deleteDeclarationConfirmAction = LocalizedString(en: "Delete this data", ar: "حذف هذه البيانات")

    static let dataSectionHeader = LocalizedString(en: "Your pregnancy data", ar: "بيانات الحمل")
    static let purgeActionTitle = LocalizedString(en: "Delete all pregnancy data", ar: "حذف جميع بيانات الحمل")
    static let purgeFootnote = LocalizedString(
        en: "This removes every journey, due-date entry, and loss declaration in the pregnancy "
            + "module. Turning the module off above keeps your data — this is the separate, "
            + "permanent action.",
        ar: "يؤدي هذا إلى إزالة كل رحلة وإدخال موعد ولادة وتصريح فقدان في وحدة الحمل. أما إيقاف "
            + "الوحدة أعلاه فيحتفظ ببياناتك — وهذا إجراء منفصل ودائم.")
    static let purgeConfirmTitle = LocalizedString(en: "Delete all pregnancy data?", ar: "حذف جميع بيانات الحمل؟")
    static let purgeConfirmMessage = LocalizedString(
        en: "This permanently deletes every journey, due-date entry, and loss declaration in the "
            + "pregnancy module. This can't be undone.",
        ar: "سيؤدي هذا إلى حذف نهائي لكل رحلة وإدخال موعد ولادة وتصريح فقدان في وحدة الحمل. لا "
            + "يمكن التراجع عن هذا الإجراء.")
    static let purgeConfirmAction = LocalizedString(en: "Delete all pregnancy data", ar: "حذف جميع بيانات الحمل")
    static let purgeSucceededNotice = LocalizedString(en: "Pregnancy data deleted.", ar: "تم حذف بيانات الحمل.")
    static let purgeFailedNotice = LocalizedString(
        en: "Couldn't delete pregnancy data. Try again.", ar: "تعذّر حذف بيانات الحمل. حاول مرة أخرى.")

    static let journeyStartedNotice = LocalizedString(en: "Journey started.", ar: "بدأت الرحلة.")
    static let journeyUpdatedNotice = LocalizedString(en: "Journey updated.", ar: "تم تحديث الرحلة.")
    static let dueDateSavedNotice = LocalizedString(en: "Due-date source saved.", ar: "تم حفظ مصدر موعد الولادة.")
    static let genericErrorNotice = LocalizedString(
        en: "Something went wrong. Try again.", ar: "حدث خطأ ما. حاول مرة أخرى.")
}
