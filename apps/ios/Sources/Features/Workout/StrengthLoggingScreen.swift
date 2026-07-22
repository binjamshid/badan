import SwiftUI

// MARK: - Movement dictionary (packages/contracts/dictionaries/movements.json)

/// One curated strength movement. Mirrors `ActivityDefinition`/`BehaviorDefinition`'s shape and
/// loading convention.
struct MovementDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var nameEn: String
    var nameAr: String
    var muscleGroups: [String]
    var equipment: [String]
    var isCompound: Bool
    var isBuiltin: Bool

    var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }
}

/// The canonical movement vocabulary `StrengthSet.movementId` resolves against, loaded via the
/// same `BundleJSON` convention as `SymptomDictionary`/`BehaviorDictionary`/`ActivityCatalog`. A
/// movement not listed here is still loggable via `StrengthSet.customLabel` — the dictionary-vs-
/// custom split every other BADAN vocabulary file already uses.
final class MovementCatalog {
    static let shared = MovementCatalog()

    let all: [MovementDefinition]
    private let byId: [String: MovementDefinition]

    private struct File: Decodable { let movements: [MovementDefinition] }

    init(movements: [MovementDefinition]? = nil) {
        let loaded = movements ?? BundleJSON.load(File.self, "movements")?.movements ?? []
        self.all = loaded
        self.byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func definition(_ id: String?) -> MovementDefinition? { id.flatMap { byId[$0] } }

    /// Display name for a logged (or in-progress) set: the dictionary name when `movementId`
    /// resolves, the free-text label when it doesn't, and a generic fallback when neither is
    /// present — never a blank row.
    func displayName(forId id: String?, customLabel: String?) -> LocalizedString {
        if let def = definition(id) { return def.displayName }
        if let customLabel, !customLabel.isEmpty { return LocalizedString(en: customLabel, ar: customLabel) }
        return LocalizedString(en: "Set", ar: "مجموعة")
    }

    func search(_ query: String) -> [MovementDefinition] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.nameEn.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
                || $0.nameAr.contains(query)
        }
    }
}

// MARK: - Screen-local strings

private enum StrengthStrings {
    static let chooseMovement = LocalizedString(en: "Choose a movement", ar: "اختر تمريناً")
    static let orCustom = LocalizedString(en: "Not listed? Type a name", ar: "غير مدرَج؟ اكتب اسماً")
    static let weight = LocalizedString(en: "Weight", ar: "الوزن")
    static let reps = LocalizedString(en: "Reps", ar: "التكرارات")
    static let setKind = LocalizedString(en: "Set type", ar: "نوع المجموعة")
    static let superset = LocalizedString(en: "Part of a superset", ar: "ضمن مجموعة متتالية")
    static let logSet = LocalizedString(en: "Log set", ar: "تسجيل المجموعة")
    static let logFailed = LocalizedString(en: "Couldn't log that set. Try again.", ar: "تعذّر تسجيل المجموعة. حاول مرة أخرى.")
    static let setLogged = LocalizedString(en: "Set logged", ar: "تم تسجيل المجموعة")
    static let restTimer = LocalizedString(en: "Rest", ar: "الراحة")
    static let skipRest = LocalizedString(en: "Skip rest", ar: "تخطي الراحة")
    static let startRest = LocalizedString(en: "Start rest", ar: "بدء الراحة")
    static let loggedSets = LocalizedString(en: "Logged sets", ar: "المجموعات المسجَّلة")
    static let noSetsYet = LocalizedString(en: "No sets logged yet", ar: "لا مجموعات مسجَّلة بعد")
    static let search = LocalizedString(en: "Search movements", ar: "ابحث عن تمرين")
    static let done = LocalizedString(en: "Done", ar: "تم")
    static let kg = LocalizedString(en: "kg", ar: "كغم")
    static let lb = LocalizedString(en: "lb", ar: "رطل")

    static let pause = LocalizedString(en: "Pause", ar: "إيقاف مؤقت")
    static let resumeAction = LocalizedString(en: "Resume", ar: "استئناف")
    static let endWorkout = LocalizedString(en: "End workout", ar: "إنهاء التمرين")
    static let stopConfirmTitle = LocalizedString(en: "End this workout?", ar: "إنهاء هذا التمرين؟")
    static let stopConfirmMessage = LocalizedString(
        en: "This saves what you've logged so far and can't be resumed afterward.",
        ar: "سيُحفظ ما سجّلته حتى الآن، ولا يمكن استئناف التمرين بعد ذلك.")
    static let stopConfirmAction = LocalizedString(en: "End & save", ar: "إنهاء وحفظ")
    static let actionFailed = LocalizedString(en: "Couldn't do that. Try again.", ar: "تعذّر تنفيذ ذلك. حاول مرة أخرى.")
    static let finalizeFailed = LocalizedString(
        en: "Couldn't save your workout. Try ending it again.", ar: "تعذّر حفظ تمرينك. حاول إنهاءه مرة أخرى.")
    static let retry = LocalizedString(en: "Retry", ar: "إعادة المحاولة")
}

// MARK: - Screen

/// EPIC-42 slice 2 — used instead of `LiveWorkoutScreen` when `coordinator.activityType` is a
/// strength modality (`WorkoutFlowRoute.destination(forActivityType:)`). Set entry (movement
/// picker, weight/reps/unit, set kind, superset grouping), a rest timer, the running
/// `coordinator.strengthSets` ledger, and the same end-workout/finalize flow as the live screen.
struct StrengthLoggingScreen: View {
    @Environment(AppEnvironment.self) private var env
    let coordinator: WorkoutSessionCoordinator
    let returnToLog: () -> Void

    // Set-entry state
    @State private var selectedMovementId: String?
    @State private var customLabelText = ""
    @State private var showMovementPicker = false
    @State private var selectedKind: StrengthSetKind = .working
    @State private var weightText = ""
    @State private var weightUnit: WeightUnit = .kg
    @State private var repsText = ""
    @State private var activeSupersetGroup: String?
    @State private var logErrorText: LocalizedString?

    // Rest timer
    @State private var restTimer = RestTimer(targetSeconds: 90)

    // Stop/finalize
    @State private var showStopConfirm = false
    @State private var isFinalizing = false
    @State private var actionErrorText: LocalizedString?
    @State private var summary: WorkoutSessionSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                sessionBar
                degradedBanner
                setEntryCard
                restTimerCard
                setsList
                if let actionErrorText { errorRow(actionErrorText) }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(activityDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: coordinator.lifecycleState) {
            await runPreparingCountdown(coordinator: coordinator)
        }
        .sheet(isPresented: $showMovementPicker) {
            MovementPickerSheet(selectedMovementId: $selectedMovementId)
        }
        .confirmationDialog(env.s(StrengthStrings.stopConfirmTitle), isPresented: $showStopConfirm,
                            titleVisibility: .visible) {
            Button(env.s(StrengthStrings.stopConfirmAction), role: .destructive) {
                Task { await finalizeWorkout() }
            }
            Button(env.s(Loc.cancel), role: .cancel) {}
        } message: {
            Text(env.s(StrengthStrings.stopConfirmMessage))
        }
        .navigationDestination(item: $summary) { finished in
            PostWorkoutSummaryScreen(summary: finished, returnToLog: returnToLog)
        }
    }

    private var activityDisplayName: String {
        guard let activityType = coordinator.activityType else { return env.s(Loc.logWorkout) }
        return ActivityCatalog.shared.definition(activityType)?.displayName.resolved(env.language) ?? activityType
    }

    // MARK: - Session bar (elapsed + HR + pause/resume/stop)

    private var sessionBar: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space5) {
                    StatBox(value: WorkoutTimeFormat.string(seconds: coordinator.elapsedActiveSeconds,
                                                            language: env.language, arabicDigits: env.profile.arabicDigits),
                           label: env.s(Loc.duration), size: .compact)
                    if let hrText = HeartRateTileFormat.valueText(bpm: coordinator.liveHeartRateBpm,
                                                                  language: env.language, arabicDigits: env.profile.arabicDigits) {
                        StatBox(value: hrText, label: env.s(LocalizedString(en: "Heart rate", ar: "معدل ضربات القلب")),
                               unit: env.s(LocalizedString(en: "bpm", ar: "ن/د")), size: .compact)
                    }
                    Spacer(minLength: BadanSpace.space2)
                }
                HStack(spacing: BadanSpace.space3) {
                    if coordinator.lifecycleState.isRecording {
                        sessionButton(StrengthStrings.pause, style: .secondary) { pause() }
                    } else if coordinator.lifecycleState.isPaused {
                        sessionButton(StrengthStrings.resumeAction, style: .primary) { resume() }
                    }
                    if coordinator.lifecycleState.isRecording || coordinator.lifecycleState.isPaused
                        || coordinator.lifecycleState == .interrupted {
                        sessionButton(StrengthStrings.endWorkout, style: .destructive) { showStopConfirm = true }
                            .disabled(isFinalizing)
                    }
                    // FIX 2/5: a `.finalizing` session with a stored error is a PREVIOUS
                    // `finalize()` attempt that threw (now legal to retry) — never a dead end with
                    // no control, which is what an audit found here before this fix.
                    if coordinator.lifecycleState == .finalizing, actionErrorText != nil {
                        sessionButton(StrengthStrings.retry, style: .primary) { Task { await finalizeWorkout() } }
                            .disabled(isFinalizing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var degradedBanner: some View {
        let lines = DegradedBannerFormat.lines(for: coordinator.degradedConditions)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(BadanColor.outOfBand)
                            .accessibilityHidden(true)
                        Text(env.s(lines[index]))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
            .padding(BadanSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.outOfBand.opacity(0.1), in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
    }

    // MARK: - Set entry

    private var setEntryCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.activityType))
                movementRow
                Text(env.s(StrengthStrings.setKind)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
                kindPicker
                HStack(spacing: BadanSpace.space3) {
                    weightField
                    repsField
                }
                supersetToggle
                Button {
                    logSet()
                } label: {
                    Text(env.s(StrengthStrings.logSet))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.onPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: BadanSpace.touchMin)
                        .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                }
                if let logErrorText {
                    errorRow(logErrorText)
                }
            }
        }
    }

    private var movementRow: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Button {
                showMovementPicker = true
            } label: {
                HStack(spacing: BadanSpace.space3) {
                    Text(movementButtonLabel)
                        .font(BadanFont.body)
                        .foregroundStyle(selectedMovementId == nil && customLabelText.isEmpty
                                        ? BadanColor.textSecondary : BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            TextField(env.s(StrengthStrings.orCustom), text: $customLabelText)
                .font(BadanFont.bodyCompact)
                .onChange(of: customLabelText) { _, newValue in
                    if !newValue.isEmpty { selectedMovementId = nil }
                }
        }
    }

    private var movementButtonLabel: String {
        if let selectedMovementId, let def = MovementCatalog.shared.definition(selectedMovementId) {
            return env.s(def.displayName)
        }
        if !customLabelText.isEmpty { return customLabelText }
        return env.s(StrengthStrings.chooseMovement)
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BadanSpace.space2) {
                ForEach(StrengthSetKind.allCases, id: \.self) { kind in
                    kindPill(kind)
                }
            }
            .padding(.vertical, BadanSpace.space1)
        }
    }

    private func kindPill(_ kind: StrengthSetKind) -> some View {
        let selected = kind == selectedKind
        return Button {
            selectedKind = kind
        } label: {
            Text(env.s(kind.displayLabel))
                .font(BadanFont.chip)
                .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary)
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .background(selected ? BadanColor.primary : BadanColor.surface,
                           in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var weightField: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(env.s(StrengthStrings.weight)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
            HStack(spacing: BadanSpace.space2) {
                TextField("0", text: $weightText)
                    .keyboardType(.decimalPad)
                    .font(BadanFont.numeralM)
                Picker("", selection: $weightUnit) {
                    Text(env.s(StrengthStrings.kg)).tag(WeightUnit.kg)
                    Text(env.s(StrengthStrings.lb)).tag(WeightUnit.lb)
                }
                .pickerStyle(.segmented)
                .frame(width: 108)
                .accessibilityLabel(env.s(StrengthStrings.weight))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var repsField: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Text(env.s(StrengthStrings.reps)).font(BadanFont.caption).foregroundStyle(BadanColor.textSecondary)
            TextField("0", text: $repsText)
                .keyboardType(.numberPad)
                .font(BadanFont.numeralM)
        }
        .frame(maxWidth: .infinity)
    }

    private var supersetToggle: some View {
        Toggle(isOn: Binding(
            get: { activeSupersetGroup != nil },
            set: { on in activeSupersetGroup = on ? (activeSupersetGroup ?? ULID.newID(clock: env.clock)) : nil }
        )) {
            Text(env.s(StrengthStrings.superset)).font(BadanFont.bodyCompact).foregroundStyle(BadanColor.textPrimary)
        }
        .tint(BadanColor.primary)
    }

    private func logSet() {
        logErrorText = nil
        let weightValue = DecimalParsing.parse(weightText)
        let reps = DecimalParsing.parseInt(repsText)
        let trimmedCustom = customLabelText.trimmingCharacters(in: .whitespaces)
        do {
            // FIX 3: pass the RAW as-entered value in the unit the user actually selected — no
            // pre-conversion to kg here. `recordStrengthSet` now stores exactly what was logged,
            // in the caller's own `unit`; canonical kilograms are derived on read via
            // `StrengthSet.weightKg`, never stored pre-converted.
            try coordinator.recordStrengthSet(
                movementId: selectedMovementId,
                customLabel: selectedMovementId == nil && !trimmedCustom.isEmpty ? trimmedCustom : nil,
                kind: selectedKind,
                weightValue: weightValue,
                reps: reps,
                unit: weightUnit,
                supersetGroup: activeSupersetGroup)
            restTimer = restTimer.started(at: env.now())
            weightText = ""
            repsText = ""
            Announce.status(env.s(StrengthStrings.setLogged))
        } catch {
            logErrorText = StrengthStrings.logFailed
            Announce.failure(env.s(StrengthStrings.logFailed))
        }
    }

    // MARK: - Rest timer

    private var restTimerCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(StrengthStrings.restTimer))
                if restTimer.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(WorkoutTimeFormat.string(seconds: restTimer.remaining(at: context.date),
                                                      language: env.language, arabicDigits: env.profile.arabicDigits))
                            .font(BadanFont.heroNumeral)
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    Button {
                        restTimer = restTimer.stopped()
                    } label: {
                        Text(env.s(StrengthStrings.skipRest))
                            .font(BadanFont.link)
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                } else {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach([60.0, 90.0, 120.0], id: \.self) { preset in
                            presetPill(preset)
                        }
                    }
                    Button {
                        restTimer = restTimer.started(at: env.now())
                    } label: {
                        Text(env.s(StrengthStrings.startRest))
                            .font(BadanFont.body.weight(.medium))
                            .foregroundStyle(BadanColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BadanSpace.touchMin)
                            .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    }
                }
            }
        }
    }

    private func presetPill(_ seconds: Double) -> some View {
        let selected = restTimer.targetSeconds == seconds
        return Button {
            restTimer = RestTimer(targetSeconds: seconds)
        } label: {
            Text("\(Int(seconds))s")
                .font(BadanFont.chip)
                .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary)
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .background(selected ? BadanColor.primary : BadanColor.surface,
                           in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logged sets

    @ViewBuilder
    private var setsList: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(StrengthStrings.loggedSets))
            if coordinator.strengthSets.isEmpty {
                Text(env.s(StrengthStrings.noSetsYet))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                ForEach(coordinator.strengthSets.reversed(), id: \.id) { set in
                    setRow(set)
                }
            }
        }
    }

    private func setRow(_ set: StrengthSet) -> some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.s(MovementCatalog.shared.displayName(forId: set.movementId, customLabel: set.customLabel)))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                    HStack(spacing: BadanSpace.space2) {
                        Text(env.s(set.setKind.displayLabel))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        if set.supersetGroup != nil {
                            PillLabel(env.s(StrengthStrings.superset), tint: BadanColor.info, filled: false)
                        }
                    }
                }
                Spacer(minLength: BadanSpace.space2)
                VStack(alignment: .trailing, spacing: 2) {
                    if let weightValue = set.weightValue, let unit = set.weightUnit {
                        Text("\(env.format.number(weightValue, fraction: 1)) \(env.s(unit == .kg ? StrengthStrings.kg : StrengthStrings.lb))")
                            .font(BadanFont.bodyCompact.monospacedDigit())
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    if let reps = set.reps {
                        Text("× \(env.format.integer(reps))")
                            .font(BadanFont.caption.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Shared bits (mirrors LiveWorkoutScreen's own small button/error helpers)

    private enum ButtonStyleKind { case primary, secondary, destructive }

    private func sessionButton(_ label: LocalizedString, style: ButtonStyleKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(env.s(label))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(style == .secondary ? BadanColor.textPrimary : BadanColor.onPrimary)
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .frame(maxWidth: .infinity)
                .background(background(for: style), in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                .overlay {
                    if style == .secondary {
                        RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                            .strokeBorder(BadanColor.separator, lineWidth: 1)
                    }
                }
        }
    }

    private func background(for style: ButtonStyleKind) -> Color {
        switch style {
        case .primary: return BadanColor.primary
        case .secondary: return BadanColor.surface
        case .destructive: return BadanColor.outOfBand
        }
    }

    private func errorRow(_ message: LocalizedString) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            Text(env.s(message))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    // MARK: - Actions

    private func pause() {
        actionErrorText = nil
        do { try coordinator.requestPause() } catch { actionErrorText = StrengthStrings.actionFailed }
    }

    private func resume() {
        actionErrorText = nil
        do { try coordinator.requestResume() } catch { actionErrorText = StrengthStrings.actionFailed }
    }

    /// Also the RETRY action (FIX 2/5): called again from the `.finalizing` Retry button. On a
    /// retry, `coordinator.lifecycleState` is already `.finalizing` (the previous attempt's
    /// `requestStop()` already landed), so `requestStop()` must NOT be called a second time —
    /// `.finalizing -> .stopRequested` is illegal and would throw before `finalize()` ever ran.
    private func finalizeWorkout() async {
        isFinalizing = true
        actionErrorText = nil
        do {
            if coordinator.lifecycleState != .finalizing {
                try coordinator.requestStop()
            }
            let result = try await coordinator.finalize()
            isFinalizing = false
            summary = result
        } catch {
            isFinalizing = false
            actionErrorText = StrengthStrings.finalizeFailed
            Announce.failure(env.s(StrengthStrings.finalizeFailed))
        }
    }
}

// MARK: - Movement picker sheet

private struct MovementPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMovementId: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(MovementCatalog.shared.search(query)) { movement in
                Button {
                    selectedMovementId = movement.id
                    dismiss()
                } label: {
                    HStack {
                        Text(env.s(movement.displayName)).foregroundStyle(BadanColor.textPrimary)
                        Spacer()
                        if movement.id == selectedMovementId {
                            Image(systemName: "checkmark").foregroundStyle(BadanColor.primary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: env.s(StrengthStrings.search))
            .navigationTitle(env.s(StrengthStrings.chooseMovement))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(StrengthStrings.done)) { dismiss() }
                }
            }
        }
    }
}
