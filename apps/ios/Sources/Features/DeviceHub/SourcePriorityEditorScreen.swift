import SwiftUI

// MARK: - EPIC-43 — Source Priority Editor (the UI reconciliation-v2's own doc named as future work)
//
// `DataConflictsScreen.swift`'s own header used to say, almost verbatim: "a Source Priority Editor
// is explicitly future UI the engine's own doc says this slice does not build." Commit 4266c68
// ("Phase 3 debt closeout, wave 1") wired `ConflictDecisionEngine`/`DataConflict` into the real
// ingestion pipeline (`IngestionPipeline.reconcileMetricConflicts`), which is what makes a priority
// EDITOR — not just a conflicts LIST — a genuinely actionable surface: the "Unresolved" list on
// `DataConflictsScreen` can now show real rows, and this screen is what lets a person configure how
// a FUTURE disagreement for the same metric gets settled automatically next time.
//
// Domain/storage are untouched by this file — see their own docs before reading further:
//   - `SourcePriorityRule` (Domain/Reconciliation/SourcePriorityRule.swift): the schema. `priorityOrder`
//     is a list of `ClassificationKey` raw values (WHAT KIND of source — chest strap / wrist optical /
//     manual), never a raw source/device id.
//   - `SourcePriorityRuleRepository` (Storage/Repositories/…): append-only. `insert` never overwrites
//     a prior row for the same metric — saving here always mints and inserts a NEW row (I2). `rule
//     (forMetric:)` is what `ConflictDecisionEngine.decide` (via `IngestionPipeline`) actually reads.
//   - `ConflictDecisionEngine.decide` (Domain/Reconciliation/DataConflict.swift): the precedence a
//     saved rule is read through. Load-bearing for what this screen can honestly claim per metric:
//       1. `MetricID.weight` is ALWAYS decided by manual-wins-if-present, else most-recent-wins,
//          *before* any `SourcePriorityRule` is ever consulted — a priority order for weight would be
//          silently inert, so this screen shows weight read-only rather than offering a dead control.
//       2. `MetricID.heartRate` in a workout, with a chest-strap candidate present, is decided by the
//          hardcoded chest-strap-beats-wrist-optical rule (`decideChestStrapPriority`) — independent of
//          any saved `SourcePriorityRule`. Outside that one case (no strap present, or not in a
//          workout), a saved rule for heart rate IS what decides it.
//       3. `restingHeartRate`/`hrv` have no engine-hardcoded default at all — a saved rule is the ONLY
//          thing that can ever resolve a conflict for either, which this screen says plainly rather
//          than showing a misleadingly confident "default."
//
// Reachable from `DeviceHubScreen`, as a sibling `NavigationLink` card to the existing
// `DeviceHubConflictsSummaryRow` (see that file) — Device Hub is where every other source/priority-
// adjacent surface in this feature folder already lives.

// MARK: - Classification vocabulary <-> SensorQualityMap bridge
//
// `SourcePriorityRule.ClassificationKey` is deliberately a small, closed vocabulary (see that type's
// own doc: "one entry per default rule this epic actually ships"). This enum is the ONE bridge
// between that abstract vocabulary and a real, named source/device — reusing `SensorQualityMap`'s
// already-shipped classifier (`classId(for:devices:)`) and its bilingual sensor-class names rather
// than inventing a second classification scheme or a second set of English/Arabic names for "chest
// strap" / "watch or wristband" / "entered by you".
enum SourcePriorityClassification {
    /// Every classification key this editor shows/reorders, in one stable canonical order. Not a
    /// speculative expansion of the vocabulary — exactly the three cases
    /// `SourcePriorityRule.ClassificationKey` declares today.
    static let editableKeys: [String] = [
        SourcePriorityRule.ClassificationKey.bleChestStrapHR,
        SourcePriorityRule.ClassificationKey.wristOpticalHR,
        SourcePriorityRule.ClassificationKey.manual,
    ]

    /// The one real hook back to `SensorQualityMap`'s own sensor-class contract
    /// (`packages/contracts/sensor_quality.json`), so this screen's labels are the SAME bilingual
    /// names already shipped for Device Hub rather than a second, drifting translation.
    private static let sourceClassId: [String: String] = [
        SourcePriorityRule.ClassificationKey.bleChestStrapHR: "chest_strap",
        SourcePriorityRule.ClassificationKey.wristOpticalHR: "wrist_wearable",
        SourcePriorityRule.ClassificationKey.manual: "manual_entry",
    ]

    /// Bilingual display name for one classification key. Falls back to the raw key only if the
    /// bundled contract failed to decode (matches `SensorQualityMap`'s own defensive posture — see
    /// its `Self.logger.fault` call — rather than crashing or showing a blank label).
    static func displayName(_ classificationKey: String) -> LocalizedString {
        guard let classId = sourceClassId[classificationKey],
              let sourceClass = SensorQualityMap.shared.sourceClass(id: classId)
        else { return LocalizedString(en: classificationKey, ar: classificationKey) }
        return sourceClass.displayName
    }

    /// The reverse direction: which classification key (if any) a REAL connected source falls under,
    /// via `SensorQualityMap.shared.classId(for:devices:)` — never a second classifier. `nil` for a
    /// source class this editor's vocabulary doesn't cover (a ring, a scale, a phone, an unrecognized
    /// source, …); such a source simply isn't named as an example anywhere on this screen.
    ///
    /// AUDIT FIX (debt-closeout wave 2): delegates to `SourcePriorityRule.ClassificationKey
    /// .fromSensorClassId(_:)` (moved to the Domain layer) rather than its own copy of this switch —
    /// `IngestionPipeline`'s real candidate-building code needs the IDENTICAL mapping this screen's
    /// display-only grounding uses, and having two copies is exactly how they silently drifted apart
    /// before this fix (this screen's copy existed; production's candidate-building code never
    /// called it at all).
    static func classificationKey(forSourceClassId sourceClassId: String) -> String? {
        SourcePriorityRule.ClassificationKey.fromSensorClassId(sourceClassId)
    }
}

// MARK: - Local strings

enum SourcePriorityEditorStrings {
    static let title = LocalizedString(en: "Source priority", ar: "أولوية المصدر")
    static let subtitle = LocalizedString(
        en: "When two sources report different values for the same reading, this decides which one "
            + "is kept from now on. Saving here never changes anything already recorded — it only "
            + "sets how a future disagreement for this metric gets settled.",
        ar: "عندما يُبلغ مصدران بقيمتين مختلفتين لنفس القراءة، يحدّد هذا أيهما يُعتمد من الآن فصاعداً. "
            + "الحفظ هنا لا يغيّر أي شيء مسجَّل من قبل — بل يحدّد فقط كيف يُحسم تعارض مستقبلي لهذا المؤشر.")

    static let userSetBadge = LocalizedString(en: "Your setting", ar: "إعدادك")
    static let builtInDefaultBadge = LocalizedString(en: "Built-in default", ar: "افتراضي مدمج")
    static let noDefaultYetBadge = LocalizedString(en: "Not set yet", ar: "لم تُعيَّن بعد")

    // AUDIT FIX: the previous copy said "Today's one built-in rule..." in the present/active tense,
    // as though BADAN already resolves a live chest-strap-vs-watch heart-rate disagreement during a
    // workout. It doesn't yet — reconciliation-v2's ingestion wiring only detects conflicts for
    // restingHeartRate/hrv/weight today (IngestionPipeline.intervalConflictMetrics/
    // sampleConflictMetrics); in-workout heart-rate conflict DETECTION isn't wired into real
    // ingestion at all, so this rule (and any order a person saves here for heart rate) has no
    // effect on real app data yet. Reworded to state that plainly rather than describing a shipped
    // rule that isn't reachable in production.
    static let heartRateDefaultExplanation = LocalizedString(
        en: "The engine's one named rule for this: a chest strap would outrank a wrist-worn watch or "
            + "band during a workout, whenever both are present. This rule isn't connected to real "
            + "workout data yet, so saving an order here has no effect today — it's shown so the "
            + "setting exists ahead of that wiring landing.",
        ar: "قاعدة المحرك المسمّاة الوحيدة لهذا: يُرجَّح الحزام الصدري على ساعة أو سوار المعصم أثناء "
            + "التمرين، كلما وُجد الاثنان معاً. لم تُربط هذه القاعدة ببيانات التمرين الفعلية بعد، لذا "
            + "لا تأثير لحفظ ترتيب هنا اليوم — يُعرض هذا لوجود الإعداد مسبقاً قبل اكتمال ذلك الربط.")
    static let noDefaultYetExplanation = LocalizedString(
        en: "No priority is set for this yet. Until you set one, a genuine disagreement here is left "
            + "open for you to review in Data conflicts, never guessed at. Set and save an order below "
            + "to settle future disagreements automatically.",
        ar: "لا توجد أولوية معيَّنة لهذا بعد. وإلى أن تعيّن واحدة، يُترك أي تعارض حقيقي هنا مفتوحاً "
            + "لتراجعه في تعارضات البيانات، ولا يُخمَّن أبداً. عيّن واحفظ ترتيباً أدناه لحسم التعارضات "
            + "المستقبلية تلقائياً.")
    static let userSetExplanation = LocalizedString(
        en: "This is the order you set yourself.", ar: "هذا هو الترتيب الذي عيّنته بنفسك.")

    static let weightExplanation = LocalizedString(
        en: "Weight disagreements are always settled by your manually entered reading, or — when "
            + "there's no manual entry — by the most recent reading. A priority order doesn't apply "
            + "here, so there's nothing to set.",
        ar: "تُحسم تعارضات الوزن دائماً بقراءتك المُدخلة يدوياً، أو — عند عدم وجود إدخال يدوي — بأحدث "
            + "قراءة. لا ينطبق ترتيب الأولوية هنا، فلا شيء لتعيينه.")

    static let moveUp = LocalizedString(en: "Move up", ar: "تحريك لأعلى")
    static let moveDown = LocalizedString(en: "Move down", ar: "تحريك لأسفل")
    static let saveOrder = LocalizedString(en: "Save this order", ar: "احفظ هذا الترتيب")
    static let resetEdit = LocalizedString(en: "Reset", ar: "إعادة تعيين")
    static let examplesPrefix = LocalizedString(en: "Connected: {names}", ar: "متصل: {names}")
    static let savedAnnouncement = LocalizedString(en: "Priority order saved", ar: "تم حفظ ترتيب الأولوية")
    static let saveFailed = LocalizedString(
        en: "Couldn't save this right now. Try again.", ar: "تعذّر الحفظ الآن. حاول مرة أخرى.")
}

// MARK: - Row state (pure — testable without a view or a database)

/// Where a displayed/editable priority order for one metric came from, driving the badge/
/// explanation copy above its reorder list. Never affects what actually gets PERSISTED on save —
/// saving always mints a fresh, `isUserOverride: true` row (I2) regardless of the origin shown here.
enum SourcePriorityOrderOrigin: Equatable {
    /// A live `SourcePriorityRule` this person saved themselves (`isUserOverride == true`).
    case userSet
    /// Either a live `SourcePriorityRule` BADAN shipped (`isUserOverride == false`) or — when no row
    /// exists yet — `MetricID.heartRate`'s one hardcoded engine default, shown so this metric never
    /// reads as an empty/confusing state.
    case builtInDefault
    /// No row exists AND (unlike heart rate) `ConflictDecisionEngine` has no hardcoded default either
    /// (`restingHeartRate`/`hrv` today) — the order shown is a neutral starting point to edit and
    /// save, not a claim that BADAN is already resolving conflicts this way.
    case noDefaultYet
}

enum SourcePriorityRowState: Equatable {
    /// A real, ordered classification list this screen can reorder and save.
    case editable(order: [String], origin: SourcePriorityOrderOrigin)
    /// Read-only: `ConflictDecisionEngine.decide` never reaches a `SourcePriorityRule` for this
    /// metric (see `MetricID.weight`'s branch, checked before any priority rule), so offering a
    /// reorder control here would be a dead affordance.
    case fixedByEngine(explanation: LocalizedString)
}

struct SourcePriorityMetricRow: Identifiable, Equatable {
    let metricId: String
    let displayName: LocalizedString
    let state: SourcePriorityRowState
    var id: String { metricId }
}

/// Pure metric list + row-state derivation — no I/O, directly unit-testable
/// (`SourcePriorityEditorScreenTests`) without a view or a database.
enum SourcePriorityEditorLogic {
    /// The metrics reconciliation-v2 actually detects conflicts for today (`IngestionPipeline`'s
    /// `intervalConflictMetrics`/`sampleConflictMetrics`), plus `heartRate` — the one metric with a
    /// shipped named default (`ConflictDecisionEngine.chestStrapRuleId`). Deliberately this exact
    /// four, not "every metric": a priority question is only meaningful where a genuine cross-source
    /// disagreement is ever detected in the first place.
    static let metricIds: [String] = [MetricID.heartRate, MetricID.restingHeartRate, MetricID.hrv, MetricID.weight]

    /// `liveRule` is whatever `SourcePriorityRuleRepository.rule(forMetric:)` currently returns for
    /// this metric (`nil` if none has ever been saved, or the only one saved was tombstoned).
    static func rowState(metricId: String, liveRule: SourcePriorityRule?) -> SourcePriorityRowState {
        if metricId == MetricID.weight {
            return .fixedByEngine(explanation: SourcePriorityEditorStrings.weightExplanation)
        }
        if let liveRule {
            return .editable(order: liveRule.priorityOrder,
                              origin: liveRule.isUserOverride ? .userSet : .builtInDefault)
        }
        if metricId == MetricID.heartRate {
            // No row saved yet — show the ONE hardcoded engine default
            // (`ConflictDecisionEngine.decideChestStrapPriority`) in `SourcePriorityRule` shape, via
            // the exact factory `SourcePriorityRuleTests` already pins, rather than re-deriving it.
            let shipped = SourcePriorityRule.defaultHeartRateDuringWorkout(
                id: "shipped-default-preview", now: .distantPast, originDeviceId: "")
            return .editable(order: shipped.priorityOrder, origin: .builtInDefault)
        }
        // restingHeartRate / hrv: genuinely no engine default exists — see `ConflictDecisionEngine.
        // decide`'s own precedence doc. Shown as a neutral, editable starting point rather than a
        // fabricated "default."
        return .editable(order: SourcePriorityClassification.editableKeys, origin: .noDefaultYet)
    }
}

/// Pure array reordering, directly unit-testable. Both are no-ops at their respective boundary
/// (moving the first item up, or the last item down) rather than wrapping — a priority list has no
/// natural "wrap-around" meaning.
enum SourcePriorityReorder {
    static func moveUp(_ order: [String], at index: Int) -> [String] {
        guard order.indices.contains(index), index > 0 else { return order }
        var copy = order
        copy.swapAt(index, index - 1)
        return copy
    }

    static func moveDown(_ order: [String], at index: Int) -> [String] {
        guard order.indices.contains(index), index < order.count - 1 else { return order }
        var copy = order
        copy.swapAt(index, index + 1)
        return copy
    }
}

// MARK: - Loaded data

struct SourcePriorityEditorData {
    let rows: [SourcePriorityMetricRow]
    /// Classification key -> real, currently-connected source display names of that class (via
    /// `SensorQualityMap.shared.classId(for:devices:)` + `SourcePriorityClassification.
    /// classificationKey(forSourceClassId:)`). Display-only grounding ("Connected: Polar H10") so
    /// the abstract vocabulary reads as real hardware, never persisted — the saved `priorityOrder`
    /// is always classification keys, never a source/device id (see `SourcePriorityRule`'s own doc).
    let examplesByClassificationKey: [String: [String]]
}

// MARK: - View model

/// `sourcePriorityRules` is built ad hoc over `env.database.main`, matching this codebase's
/// established convention for a repository `AppEnvironment` doesn't pre-wire (see
/// `DataConflictsFetchInputs`'s own doc for the precedent this follows).
struct SourcePriorityEditorFetchInputs {
    var catalog: CatalogRepository
    var sourcePriorityRules: SourcePriorityRuleRepository
    var registry: MetricRegistry
}

enum SourcePriorityEditorFetchOutcome {
    case loaded(SourcePriorityEditorData)
    case failure(Error)
}

@Observable
@MainActor
final class SourcePriorityEditorViewModel {
    var state: LoadState<SourcePriorityEditorData> = .loading
    /// Metric id -> the locally-edited (not yet saved) order, only while a person has reordered a
    /// metric's list without saving it yet. Kept here (not in `state`) so a background reload
    /// (`dataGeneration` bump from something unrelated) never clobbers an in-progress edit.
    var pendingOrder: [String: [String]] = [:]
    var saveFailed = false

    func load(_ env: AppEnvironment) async {
        let inputs = SourcePriorityEditorFetchInputs(
            catalog: env.catalog, sourcePriorityRules: SourcePriorityRuleRepository(main: env.database.main),
            registry: env.registry)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .loaded(let data):
            state = .loaded(data)
        case .failure(let error):
            LoadErrorLog.log(error, screen: "SourcePriorityEditor")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    nonisolated static func fetch(_ inputs: SourcePriorityEditorFetchInputs) -> SourcePriorityEditorFetchOutcome {
        do {
            let sources = try inputs.catalog.sources(includeHidden: false)
            let allDevices = try inputs.catalog.devices()
            let devicesBySource = Dictionary(grouping: allDevices, by: \.sourceId)

            var examples: [String: [String]] = [:]
            for source in sources {
                let devices = devicesBySource[source.id] ?? []
                let classId = SensorQualityMap.shared.classId(for: source, devices: devices)
                guard let key = SourcePriorityClassification.classificationKey(forSourceClassId: classId) else { continue }
                examples[key, default: []].append(source.displayName)
            }

            let rows: [SourcePriorityMetricRow] = try SourcePriorityEditorLogic.metricIds.map { metricId in
                let liveRule = try inputs.sourcePriorityRules.rule(forMetric: metricId)
                return SourcePriorityMetricRow(
                    metricId: metricId,
                    displayName: inputs.registry.definitionOrFallback(metricId).displayName,
                    state: SourcePriorityEditorLogic.rowState(metricId: metricId, liveRule: liveRule))
            }
            return .loaded(SourcePriorityEditorData(rows: rows, examplesByClassificationKey: examples))
        } catch {
            return .failure(error)
        }
    }

    /// Reorders metric `metricId`'s currently-displayed list (the pending edit if one already
    /// exists, otherwise its loaded initial order — `SourcePriorityMetricCard` always passes
    /// whichever one it is currently showing) and stashes the result as the new pending edit.
    func moveUp(metricId: String, currentOrder: [String], index: Int) {
        pendingOrder[metricId] = SourcePriorityReorder.moveUp(currentOrder, at: index)
    }

    func moveDown(metricId: String, currentOrder: [String], index: Int) {
        pendingOrder[metricId] = SourcePriorityReorder.moveDown(currentOrder, at: index)
    }

    func resetEdit(metricId: String) {
        pendingOrder[metricId] = nil
    }

    /// Persists `order` as a brand-new `SourcePriorityRule` row (append-only, I2 — never a mutation
    /// of any prior row) and reloads. Always `isUserOverride: true`: the only path that writes a row
    /// through this screen is a person explicitly choosing and saving an order.
    func save(metricId: String, order: [String], env: AppEnvironment) async {
        let now = env.now()
        let rule = SourcePriorityRule(id: ULID.newID(), metricId: metricId, priorityOrder: order,
                                      isUserOverride: true, createdAt: now, updatedAt: now,
                                      originDeviceId: env.deviceId)
        do {
            try SourcePriorityRuleRepository(main: env.database.main).insert(rule)
            saveFailed = false
            pendingOrder[metricId] = nil
            env.bumpDataGeneration()
            Announce.status(env.s(SourcePriorityEditorStrings.savedAnnouncement))
            await load(env)
        } catch {
            saveFailed = true
            Announce.failure(env.s(SourcePriorityEditorStrings.saveFailed))
        }
    }
}

// MARK: - Screen

/// Lets a person see today's priority order for a handful of metrics reconciliation-v2 actually
/// detects conflicts for, and reorder/save one — persisted as a new, append-only `SourcePriorityRule`
/// row `ConflictDecisionEngine.decide` picks up on its next call (via `IngestionPipeline`). See this
/// file's own header for the full scope note and the engine-precedence caveats per metric.
struct SourcePriorityEditorScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = SourcePriorityEditorViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                Text(env.s(SourcePriorityEditorStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if vm.saveFailed {
                    inlineWarning(SourcePriorityEditorStrings.saveFailed)
                }

                StatefulContainer(
                    vm.state,
                    emptyIcon: "arrow.up.arrow.down.circle",
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env) } }
                ) { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        ForEach(data.rows) { row in
                            SourcePriorityMetricCard(
                                row: row,
                                examples: data.examplesByClassificationKey,
                                pendingOrder: vm.pendingOrder[row.metricId],
                                onMoveUp: { order, index in vm.moveUp(metricId: row.metricId, currentOrder: order, index: index) },
                                onMoveDown: { order, index in vm.moveDown(metricId: row.metricId, currentOrder: order, index: index) },
                                onReset: { vm.resetEdit(metricId: row.metricId) },
                                onSave: { order in Task { await vm.save(metricId: row.metricId, order: order, env: env) } })
                        }
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SourcePriorityEditorStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: SourcePriorityEditorLoadKey(generation: env.dataGeneration)) { await vm.load(env) }
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
}

private struct SourcePriorityEditorLoadKey: Equatable {
    let generation: Int
}

// MARK: - Metric card

private struct SourcePriorityMetricCard: View {
    @Environment(AppEnvironment.self) private var env
    let row: SourcePriorityMetricRow
    let examples: [String: [String]]
    /// The in-progress (unsaved) order, or `nil` to display this row's loaded initial order.
    let pendingOrder: [String]?
    let onMoveUp: (_ currentOrder: [String], _ index: Int) -> Void
    let onMoveDown: (_ currentOrder: [String], _ index: Int) -> Void
    let onReset: () -> Void
    let onSave: (_ order: [String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(row.displayName))
            BadanCard {
                switch row.state {
                case .editable(let initialOrder, let origin):
                    editableContent(initialOrder: initialOrder, origin: origin)
                case .fixedByEngine(let explanation):
                    Text(env.s(explanation))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func editableContent(initialOrder: [String], origin: SourcePriorityOrderOrigin) -> some View {
        let order = pendingOrder ?? initialOrder
        let isDirty = pendingOrder != nil && pendingOrder != initialOrder

        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            HStack {
                originBadge(origin)
                Spacer(minLength: BadanSpace.space2)
            }
            Text(env.s(explanation(for: origin)))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(order.enumerated()), id: \.element) { index, key in
                    if index > 0 {
                        Rectangle().fill(BadanColor.separator).frame(height: 1)
                    }
                    classificationRow(key: key, index: index, order: order)
                }
            }
            .background(BadanColor.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))

            if isDirty {
                HStack(spacing: BadanSpace.space3) {
                    Button(action: { onSave(order) }) {
                        Text(env.s(SourcePriorityEditorStrings.saveOrder))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.onPrimary)
                            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                            .background(BadanColor.primary,
                                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    }
                    Button(action: onReset) {
                        Text(env.s(SourcePriorityEditorStrings.resetEdit))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                            .frame(minHeight: BadanSpace.touchMin)
                            .padding(.horizontal, BadanSpace.space3)
                    }
                }
            }
        }
    }

    private func originBadge(_ origin: SourcePriorityOrderOrigin) -> some View {
        switch origin {
        case .userSet:
            return PillLabel(env.s(SourcePriorityEditorStrings.userSetBadge), systemImage: "person.fill",
                              tint: BadanColor.primary, filled: false)
        case .builtInDefault:
            return PillLabel(env.s(SourcePriorityEditorStrings.builtInDefaultBadge), systemImage: "checkmark.seal",
                              tint: BadanColor.textSecondary, filled: false)
        case .noDefaultYet:
            return PillLabel(env.s(SourcePriorityEditorStrings.noDefaultYetBadge), systemImage: "questionmark.circle",
                              tint: BadanColor.outOfBand, filled: false)
        }
    }

    private func explanation(for origin: SourcePriorityOrderOrigin) -> LocalizedString {
        switch origin {
        case .userSet: return SourcePriorityEditorStrings.userSetExplanation
        case .builtInDefault:
            return row.metricId == MetricID.heartRate
                ? SourcePriorityEditorStrings.heartRateDefaultExplanation
                : SourcePriorityEditorStrings.userSetExplanation
        case .noDefaultYet: return SourcePriorityEditorStrings.noDefaultYetExplanation
        }
    }

    private func classificationRow(key: String, index: Int, order: [String]) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Text("\(index + 1)")
                .font(BadanFont.bodyCompact.weight(.semibold).monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
                .frame(minWidth: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(env.s(SourcePriorityClassification.displayName(key)))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textPrimary)
                if let names = examples[key], !names.isEmpty {
                    Text(env.s(SourcePriorityEditorStrings.examplesPrefix.filling(["names": names.joined(separator: ", ")])))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            Spacer(minLength: BadanSpace.space2)
            Button(action: { onMoveUp(order, index) }) {
                Image(systemName: "chevron.up")
                    .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
            }
            .disabled(index == 0)
            .accessibilityLabel(env.s(SourcePriorityEditorStrings.moveUp))
            Button(action: { onMoveDown(order, index) }) {
                Image(systemName: "chevron.down")
                    .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
            }
            .disabled(index == order.count - 1)
            .accessibilityLabel(env.s(SourcePriorityEditorStrings.moveDown))
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
    }
}
