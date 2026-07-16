import SwiftUI

// MARK: - Strings

private enum GoalStrings {
    static let intro = LocalizedString(
        en: "A target for a metric you care about. BADAN shows how you're tracking against it — "
            + "it never scores you, and missing one is not a failure.",
        ar: "هدف لمقياس يهمّك. يعرض بدن مسارك نحوه — دون أن يقيّمك، وعدم بلوغه ليس فشلاً.")
    static let yourGoals = LocalizedString(en: "Your goals", ar: "أهدافك")
    static let addGoal = LocalizedString(en: "Add a goal", ar: "أضف هدفاً")
    static let emptyTitle = LocalizedString(en: "No goals yet", ar: "لا أهداف بعد")
    static let emptyBody = LocalizedString(
        en: "Add one for any metric BADAN tracks. Entirely optional — BADAN works the same without.",
        ar: "أضِف هدفاً لأي مقياس يتتبّعه بدن. اختياري تماماً — ويعمل بدن كما هو بدونه.")
    static let metric = LocalizedString(en: "Metric", ar: "المقياس")
    static let target = LocalizedString(en: "Target", ar: "الهدف")
    static let direction = LocalizedString(en: "Aim", ar: "الاتجاه")
    static let atLeast = LocalizedString(en: "At least", ar: "على الأقل")
    static let atMost = LocalizedString(en: "At most", ar: "على الأكثر")
    static let around = LocalizedString(en: "Around", ar: "حوالي")
    static let atLeastHint = LocalizedString(en: "Reaching the target or more", ar: "بلوغ الهدف أو تجاوزه")
    static let atMostHint = LocalizedString(en: "Staying at the target or under", ar: "البقاء عند الهدف أو دونه")
    /// Says the tolerance out loud rather than leaving "around" to mean whatever the user guesses.
    static let aroundHint = LocalizedString(en: "Within about 5% of the target either way",
                                            ar: "ضمن حوالي ٥٪ من الهدف في أي اتجاه")
    static let active = LocalizedString(en: "Active", ar: "مفعّل")
    /// Pausing beats deleting for a goal you're stepping back from — the record and its history
    /// survive, and nothing is judged while it's off.
    static let activeSubtitle = LocalizedString(
        en: "Turn off to pause this goal without deleting it.",
        ar: "أوقفه لتعليق هذا الهدف دون حذفه.")
    static let save = LocalizedString(en: "Save goal", ar: "حفظ الهدف")
    static let delete = LocalizedString(en: "Delete goal", ar: "حذف الهدف")
    static let saved = LocalizedString(en: "Goal saved", ar: "تم حفظ الهدف")
    static let deleted = LocalizedString(en: "Goal deleted", ar: "تم حذف الهدف")
    static let saveFailed = LocalizedString(en: "Couldn't save — try again.", ar: "تعذّر الحفظ — حاول مرة أخرى.")
    static let noData = LocalizedString(en: "No readings yet", ar: "لا قراءات بعد")
    static let paused = LocalizedString(en: "Paused", ar: "متوقف")
    static let searchMetrics = LocalizedString(en: "Search metrics", ar: "البحث في المقاييس")
    static let invalidTarget = LocalizedString(en: "Enter a number greater than zero",
                                               ar: "أدخل رقماً أكبر من صفر")

    static func onTrack(_ direction: GoalDirection) -> LocalizedString {
        switch direction {
        case .atLeast: return LocalizedString(en: "At or above your goal", ar: "عند هدفك أو فوقه")
        case .atMost: return LocalizedString(en: "At or below your goal", ar: "عند هدفك أو دونه")
        case .around: return LocalizedString(en: "Close to your goal", ar: "قريب من هدفك")
        }
    }

    /// Never "you failed" — the app's register is descriptive, not corrective (`Loc` discipline).
    static func offTrack(_ direction: GoalDirection) -> LocalizedString {
        switch direction {
        case .atLeast: return LocalizedString(en: "Below your goal", ar: "دون هدفك")
        case .atMost: return LocalizedString(en: "Above your goal", ar: "فوق هدفك")
        case .around: return LocalizedString(en: "Away from your goal", ar: "بعيد عن هدفك")
        }
    }
}

// MARK: - Evaluation (pure)

/// Where a reading sits relative to a goal.
///
/// A pure function of (value, target, direction) so the rule is unit-testable without a database
/// — the same seam `MedicationReminderPlan` and `DedupLite` use. There is no scoring, no streak
/// and no judgement here by design: BADAN describes, it doesn't grade (`CLAUDE.md`'s
/// wellness-safe guardrail). The only question this answers is "is the reading on the goal's side
/// of the target?".
enum GoalEvaluation: Equatable {
    case onTrack
    case offTrack
    case noData

    /// `around` needs a tolerance — an exact float match would essentially never be "on track".
    /// 5% of the target is a proportional band, so it behaves sensibly for both a 7-hour sleep
    /// goal and an 8000-step one, rather than a fixed epsilon that would be absurd for one of them.
    static let aroundTolerance = 0.05

    static func evaluate(value: Double?, target: Double, direction: GoalDirection) -> GoalEvaluation {
        guard let value else { return .noData }
        switch direction {
        case .atLeast: return value >= target ? .onTrack : .offTrack
        case .atMost: return value <= target ? .onTrack : .offTrack
        case .around:
            let tolerance = abs(target) * aroundTolerance
            return abs(value - target) <= tolerance ? .onTrack : .offTrack
        }
    }
}

// MARK: - View model

@Observable
@MainActor
final class GoalsViewModel {
    struct Row: Identifiable {
        let goal: Goal
        let currentValue: Double?
        let evaluation: GoalEvaluation
        var id: String { goal.id }
    }

    var state: LoadState<[Row]> = .loading

    func load(_ env: AppEnvironment) {
        do {
            let goals = try env.profiles.goals()
            guard !goals.isEmpty else { state = .empty(env.s(GoalStrings.emptyTitle)); return }
            let rows = goals.map { goal -> Row in
                let value = Self.currentValue(for: goal.metricId, env: env)
                return Row(goal: goal, currentValue: value,
                           evaluation: goal.active
                               ? GoalEvaluation.evaluate(value: value, target: goal.target,
                                                         direction: goal.direction)
                               : .noData)
            }
            state = .loaded(rows)
        } catch {
            LoadErrorLog.log(error, screen: "Goals")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    /// The most recent canonical reading for a metric, whichever shape it's stored in.
    ///
    /// Goals can target any metric in the ontology, and the ontology stores values three ways:
    /// interval aggregates (steps, energy), instant samples (weight, HR) and engine-derived
    /// values (readiness, sleep score). Checking all three — rather than assuming one — is what
    /// lets a goal be set on any metric instead of an arbitrary subset.
    private static func currentValue(for metricId: String, env: AppEnvironment) -> Double? {
        if let interval = try? env.measurements.latestInterval(metricId: metricId) { return interval.value }
        if let sample = try? env.measurements.rawSamples(metricId: metricId).last { return sample.value }
        if let derived = try? env.derivation.latestDerivedSeries(metricId: metricId).last { return derived.value }
        return nil
    }

    @discardableResult
    func save(_ goal: Goal, env: AppEnvironment) -> Bool {
        do {
            try env.profiles.upsertGoal(goal)
            // A goal changes what Home can show — same bus discipline as the log editors (F5).
            env.bumpDataGeneration()
            load(env)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(_ goal: Goal, env: AppEnvironment) -> Bool {
        do {
            try env.profiles.deleteGoal(id: goal.id)
            env.bumpDataGeneration()
            load(env)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Screen

/// Settings -> Health goals.
///
/// The `goals` table, its domain model and its repository have all existed since migration v1;
/// nothing ever read or wrote them from the UI, so the feature was dead scaffolding on both
/// platforms (the 2026-07-16 audit lists it under "no UI anywhere"). This is the surface that
/// makes it real.
struct GoalsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = GoalsViewModel()
    @State private var editing: Goal?
    @State private var showAdd = false
    @State private var notice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                LText(GoalStrings.intro)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                StatefulContainer(vm.state, emptyIcon: "target") { rows in
                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        SectionHeader(env.s(GoalStrings.yourGoals))
                        BadanCard {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    Button { editing = row.goal } label: { goalRow(row) }
                                        .buttonStyle(.plain)
                                    if index < rows.count - 1 { settingsDivider }
                                }
                            }
                        }
                    }
                }

                addButton
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.goals.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice { SettingsTransientNotice(notice: notice) }
        }
        .animation(.easeInOut(duration: 0.25), value: notice)
        .task(id: GoalsLoadKey(profile: env.profile, generation: env.dataGeneration)) { vm.load(env) }
        .sheet(isPresented: $showAdd) {
            GoalEditorSheet(goal: nil) { saved in handleSave(saved) }
        }
        .sheet(item: $editing) { goal in
            GoalEditorSheet(goal: goal, onDelete: { handleDelete(goal) }) { saved in handleSave(saved) }
        }
    }

    private func handleSave(_ goal: Goal) {
        if vm.save(goal, env: env) {
            show(GoalStrings.saved)
        } else {
            show(GoalStrings.saveFailed)
        }
    }

    private func handleDelete(_ goal: Goal) {
        if vm.delete(goal, env: env) {
            show(GoalStrings.deleted)
        } else {
            show(GoalStrings.saveFailed)
        }
    }

    private func show(_ message: LocalizedString) {
        notice = message
        Announce.status(env.s(message)) // (A3) the sheet dismissing is the only other feedback
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == message { notice = nil }
        }
    }

    // MARK: Rows

    private func goalRow(_ row: GoalsViewModel.Row) -> some View {
        let definition = env.registry.definitionOrFallback(row.goal.metricId)
        return HStack(alignment: .top, spacing: BadanSpace.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.displayName, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(targetText(row.goal, definition: definition))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            statusChip(row)
            Image(systemName: "chevron.forward")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusChip(_ row: GoalsViewModel.Row) -> some View {
        if !row.goal.active {
            PillLabel(env.s(GoalStrings.paused))
        } else {
            switch row.evaluation {
            case .onTrack:
                StatusChip(.inBand, label: env.s(GoalStrings.onTrack(row.goal.direction)),
                           language: env.language)
            case .offTrack:
                // One calm status, never `critical` — a missed goal is not an alarm, and the
                // direction word already carries whether it's above or below.
                StatusChip(row.goal.direction == .atMost ? .above : .below,
                           label: env.s(GoalStrings.offTrack(row.goal.direction)),
                           language: env.language)
            case .noData:
                PillLabel(env.s(GoalStrings.noData))
            }
        }
    }

    private func targetText(_ goal: Goal, definition: MetricDefinition) -> String {
        let aim: LocalizedString
        switch goal.direction {
        case .atLeast: aim = GoalStrings.atLeast
        case .atMost: aim = GoalStrings.atMost
        case .around: aim = GoalStrings.around
        }
        // `bareValue`/`bareUnitLabel` already do canonical -> display, including the
        // seconds-to-minutes special case every duration metric needs.
        let value = env.format.bareValue(metricId: goal.metricId, canonicalValue: goal.target)
        let unit = env.format.bareUnitLabel(metricId: goal.metricId)
        return "\(env.s(aim)) \(value) \(unit)".trimmingCharacters(in: .whitespaces)
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "plus.circle.fill").accessibilityHidden(true)
                LText(GoalStrings.addGoal).font(BadanFont.body.weight(.semibold))
            }
            .foregroundStyle(BadanColor.onPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: BadanSpace.touchMin)
            .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// See `AppEnvironment.dataGeneration` — same `.task(id:)` shape as every other data-backed screen.
private struct GoalsLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

// MARK: - Editor sheet

/// Add or edit one goal. Presented as a sheet so the list stays put behind it.
private struct GoalEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let goal: Goal?
    var onDelete: (() -> Void)?
    let onSave: (Goal) -> Void

    @State private var metricId: String = MetricID.steps
    @State private var targetText: String = ""
    @State private var direction: GoalDirection = .atLeast
    @State private var active: Bool = true
    @State private var metricQuery: String = ""

    private var isEditing: Bool { goal != nil }

    /// Every metric the ontology knows — a goal is a user intention, so it isn't restricted to the
    /// four types currently ingested. A goal on a metric with no readings simply shows
    /// "No readings yet" rather than being unofferable.
    private var metrics: [MetricDefinition] {
        let all = env.registry.all.sorted { $0.metricId < $1.metricId }
        let query = metricQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.resolved(env.language).localizedCaseInsensitiveContains(query)
                || $0.metricId.localizedCaseInsensitiveContains(query)
        }
    }

    /// Accepts Arabic-Indic digits and a comma decimal separator, because the app renders them
    /// and a user typing back what they read must not be rejected.
    private var parsedTarget: Double? {
        var text = targetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let arabicIndic = Array("٠١٢٣٤٥٦٧٨٩")
        text = String(text.map { ch in arabicIndic.firstIndex(of: ch).map { Character(String($0)) } ?? ch })
        guard let value = Double(text), value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    targetCard
                    directionCard
                    if isEditing { activeCard }
                    metricPicker
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background.ignoresSafeArea())
            .navigationTitle(env.s(isEditing ? GoalStrings.yourGoals : GoalStrings.addGoal))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(GoalStrings.save)) { save() }
                        .disabled(parsedTarget == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isEditing, let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        LText(GoalStrings.delete)
                            .font(BadanFont.body)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                    .padding(BadanSpace.space4)
                }
            }
        }
        .onAppear(perform: seed)
    }

    private func seed() {
        guard let goal else { return }
        metricId = goal.metricId
        direction = goal.direction
        active = goal.active
        targetText = env.format.bareValue(metricId: goal.metricId, canonicalValue: goal.target)
    }

    private var definition: MetricDefinition { env.registry.definitionOrFallback(metricId) }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(GoalStrings.target))
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    TextField("", text: $targetText)
                        .keyboardType(.decimalPad)
                        .font(BadanFont.body)
                        .frame(minHeight: BadanSpace.touchMin)
                    Text(env.format.bareUnitLabel(metricId: metricId))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            if !targetText.isEmpty && parsedTarget == nil {
                LText(GoalStrings.invalidTarget)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.outOfBand)
            }
        }
    }

    private var directionCard: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(GoalStrings.direction))
            SettingsRadioGroup(
                options: [GoalDirection.atLeast, .atMost, .around],
                title: { d in
                    switch d {
                    case .atLeast: return env.s(GoalStrings.atLeast)
                    case .atMost: return env.s(GoalStrings.atMost)
                    case .around: return env.s(GoalStrings.around)
                    }
                },
                subtitle: { d in
                    switch d {
                    case .atLeast: return env.s(GoalStrings.atLeastHint)
                    case .atMost: return env.s(GoalStrings.atMostHint)
                    case .around: return env.s(GoalStrings.aroundHint)
                    }
                },
                isOn: { $0 == direction }
            ) { direction = $0 }
        }
    }

    private var activeCard: some View {
        BadanCard {
            SettingsToggleRow(title: GoalStrings.active,
                              subtitle: GoalStrings.activeSubtitle,
                              isOn: Binding(get: { active }, set: { active = $0 }))
        }
    }

    private var metricPicker: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(GoalStrings.metric))
            BadanCard {
                TextField(env.s(GoalStrings.searchMetrics), text: $metricQuery)
                    .font(BadanFont.body)
                    .frame(minHeight: BadanSpace.touchMin)
            }
            BadanCard {
                VStack(spacing: 0) {
                    ForEach(Array(metrics.prefix(40).enumerated()), id: \.element.metricId) { index, def in
                        Button { metricId = def.metricId } label: {
                            HStack(spacing: BadanSpace.space3) {
                                Text(def.displayName, language: env.language)
                                    .font(BadanFont.body)
                                    .foregroundStyle(BadanColor.textPrimary)
                                Spacer(minLength: BadanSpace.space2)
                                Image(systemName: def.metricId == metricId ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(def.metricId == metricId ? BadanColor.primary : BadanColor.separator)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: BadanSpace.touchMin)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(def.metricId == metricId ? .isSelected : [])
                        if index < min(metrics.count, 40) - 1 { settingsDivider }
                    }
                }
            }
        }
    }

    private func save() {
        guard let target = parsedTarget else { return }
        // Stored canonical, like every other value in the database — the display unit is a
        // presentation concern, and a goal saved in lb must not become a goal in kg.
        let unit = env.format.displayUnit(for: definition)
        let canonical = Units.toCanonical(target, from: unit, canonical: definition.canonicalUnit)
        onSave(Goal(id: goal?.id ?? ULID.newID(), metricId: metricId, target: canonical,
                    unit: definition.canonicalUnit, direction: direction, active: active,
                    createdAt: goal?.createdAt ?? env.now()))
        dismiss()
    }
}
