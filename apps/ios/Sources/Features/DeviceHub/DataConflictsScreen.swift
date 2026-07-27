import SwiftUI

// See `DeviceHubScreen.swift`'s file-top comment for this feature folder's overall scope
// boundary (no CoreBluetooth, no BP/Thermometer/Pulse-Ox surfaces). This screen additionally
// carries its own, narrower scope note below about `DataConflict`/`SourcePriorityRule`.

// MARK: - `DataConflict` / `ConflictDecisionEngine` — read this before touching either section
//
// `DataConflict` (a detected-but-not-yet-resolved disagreement between two sources for the same
// metric/window, before a rule picks a winner) is the parallel Reconciliation-v2 lane's domain
// type (`Domain/Reconciliation/DataConflict.swift` + `DataConflictRepository`, migration 10's
// `data_conflicts` table) — genuinely distinct from `ReconciliationDecision` below, which only
// ever describes an ALREADY-decided dedup, never an open disagreement. It landed in the working
// tree partway through this slice and is read directly (`unresolved()`), not stubbed.
//
// SUPERSEDED (2026-07-27, EPIC-43 debt closeout): this screen is no longer read-only over the
// unresolved section. It now offers a real pick-a-winner action — see `ConflictResolutionService`
// (resolves the conflict's stored record ids back into readable values, applies the choice) and
// `ConflictResolution` (the domain half, and why a user's choice carries its own rule id rather
// than borrowing an engine rule's). The original reasoning below still explains why it shipped
// read-only first, and the constraint it names was real: the engine needs each candidate's actual
// reading, which the conflict row deliberately does not store (I5).
//
// What has NOT changed: leaving a conflict unresolved is still a legitimate end state (I3/I5),
// nothing is ever averaged or blended, and the losing readings are SUPPRESSED rather than deleted,
// so any choice made here stays reversible through the same `dedup_decisions` ledger every
// automatic decision uses.
//
// (Original note) This screen is READ-ONLY over both sections. It does not itself run
// `ConflictDecisionEngine.decide` (that engine additionally needs each candidate's real
// `CandidateReading` — richness, classification, manual-entry flag — resolved from
// `raw_samples`/`sessions`, which is a bigger "build a resolve action" surface than "list what
// exists" and is out of this UI lane's scope). An unresolved conflict here is shown for exactly
// what it is: detected, not yet decided, with no action attached.
//
// Disclosure UPDATE (commit 4266c68, "Phase 3 debt closeout, wave 1"): reconciliation-v2 IS now
// wired into the real ingestion pipeline — `IngestionPipeline.reconcileMetricConflicts` calls
// `ConflictDecisionEngine.decide`/`.makeDecisions` for `MetricID.restingHeartRate`/`.hrv`/`.weight`
// on every ingest run, so the "Unresolved" section above can genuinely be non-empty in the running
// app now, not only under test. The "Resolved" section below is unaffected by that wiring either
// way: it reads the PRE-EXISTING `dedup_decisions` ledger via `ReconciliationRepository.recent()`,
// which `DedupLite`'s sleep/workout-overlap rules already populated in production before this too.
//
// `SourcePriorityRule` (the per-metric priority order `ConflictDecisionEngine` falls back to) is
// the same parallel lane's type; nothing on THIS screen edits one — see `SourcePriorityEditorScreen`
// (`Features/DeviceHub/SourcePriorityEditorScreen.swift`, reachable from `DeviceHubScreen`'s own
// sibling card), which is that Source Priority Editor now that reconciliation-v2 being wired makes
// it a genuinely actionable surface. That screen only ever sets a FORWARD-looking priority rule for
// a metric — it does not resolve any conflict already open below, which stays a separate, still-open
// gap (picking a winner for an already-detected unresolved conflict) out of both screens' scope.

// MARK: - Local strings

private enum DataConflictsStrings {
    static let title = LocalizedString(en: "Data conflicts", ar: "تعارضات البيانات")
    static let unresolvedHeader = LocalizedString(en: "Unresolved", ar: "غير محلولة")
    static let unresolvedEmptyMessage = LocalizedString(
        en: "Nothing waiting for a decision right now.",
        ar: "لا شيء بانتظار قرار الآن.")
    static let resolvedHeader = LocalizedString(en: "Resolved", ar: "محلولة")
    static let resolvedEmptyMessage = LocalizedString(
        en: "No duplicate readings have been settled yet.",
        ar: "لم تُسوَّ أي قراءات مكررة بعد.")
    static let kept = LocalizedString(en: "Kept", ar: "المحتفظ به")
    static let whyTitle = LocalizedString(en: "Why am I seeing this value?", ar: "لماذا أرى هذه القيمة؟")
    static let ruleLabel = LocalizedString(en: "Rule", ar: "القاعدة")
    static let decidedLabel = LocalizedString(en: "Decided", ar: "تاريخ القرار")
    static let detectedLabel = LocalizedString(en: "Detected", ar: "تاريخ الاكتشاف")
    static let candidateCount = LocalizedString(en: "{n} records disagree", ar: "{n} سجلات متعارضة")
    static let duringWorkout = LocalizedString(en: "during a workout", ar: "أثناء تمرين")
    static let workoutDuplicateLabel = LocalizedString(en: "Possible duplicate workout", ar: "احتمال تمرين مكرر")
    static let unknownScopeLabel = LocalizedString(en: "Unrecognized conflict", ar: "تعارض غير معروف")
    static let unresolvedNote = LocalizedString(
        en: "Not yet decided — nothing is hidden or guessed at in the meantime.",
        ar: "لم يُحسم بعد — لا شيء يُخفى أو يُخمَّن في هذه الأثناء.")
    static let chooseAction = LocalizedString(en: "Choose which to keep", ar: "اختر ما تريد الاحتفاظ به")
    static let keepThisOne = LocalizedString(en: "Keep this one", ar: "احتفظ بهذه")
    static let manualBadge = LocalizedString(en: "Entered by you", ar: "أدخلتها بنفسك")
    static let setAsideBadge = LocalizedString(en: "Set aside", ar: "مُنحّاة")
    static let chooseExplainer = LocalizedString(
        en: "No rule settles this one, so it's yours to decide. The others are set aside, not deleted — you can change this later.",
        ar: "لا قاعدة تحسم هذا، فالقرار لك. تُنحّى البقية ولا تُحذف — يمكنك تغيير ذلك لاحقًا.")
    static let resolveFailed = LocalizedString(
        en: "That didn't go through. Nothing was changed.",
        ar: "لم يتم ذلك. لم يتغير شيء.")
    static let unreadableCandidates = LocalizedString(
        en: "These readings are no longer available to compare.",
        ar: "لم تعد هذه القراءات متاحة للمقارنة.")
    static let alreadyReversed = LocalizedString(en: "Already reversed", ar: "تمت الاستعادة بالفعل")
    static let reversibleNote = LocalizedString(en: "Nothing is deleted — this can be reversed.",
                                                ar: "لا يُحذف شيء — يمكن التراجع عن هذا.")
    static let notReversible = LocalizedString(en: "This decision is final.", ar: "هذا القرار نهائي.")

    /// Plain-language description of a reconciliation rule id, matching
    /// `MetricAnatomySheet.AnatomyStrings.ruleGlossary`'s convention (kept as its own copy here
    /// since that one is `private` to its file). Unknown ids simply show no extra line — the raw
    /// `rule · ruleVersion` line below always renders regardless.
    static let ruleGlossary: [String: LocalizedString] = [
        "sleep.session_overlap.v1": LocalizedString(
            en: "Two sleep sessions overlapped heavily, so the higher-priority source's reading was kept.",
            ar: "تداخلت جلستا نوم بشكل كبير، فتم الاحتفاظ بقراءة المصدر الأعلى أولوية."),
    ]
}

/// The raw rule-identity line inside the "why am I seeing this value?" disclosure. Always the
/// actual decision's own `rule`/`ruleVersion` — never a canned label — so a rule with no glossary
/// entry above still tells the truth about what decided it. A free function (not inline in the
/// view) so `DeviceHubUITests` can assert it renders the real value directly.
enum ReconciliationDisclosureFormat {
    static func ruleLine(_ decision: ReconciliationDecision) -> String {
        "\(decision.rule) · \(decision.ruleVersion)"
    }
}

// MARK: - Loaded data

struct DataConflictsData {
    let unresolved: [DataConflict]
    let resolved: [ReconciliationDecision]
    let sourceNames: [String: String]
    /// Candidate readings per unresolved conflict id, resolved from the record ids the conflict
    /// stores. Loaded here on the background fetch rather than lazily per row so tapping a conflict
    /// never blocks the main actor on SQLite.
    var candidates: [String: [ConflictResolutionService.Candidate]] = [:]
    /// The table each unresolved conflict's candidates live in, so the resolve action suppresses
    /// rows in the right place. Absent for a scope with no suppressible rows.
    var tables: [String: String] = [:]
}

// MARK: - View model

/// `dataConflicts` is built ad hoc over `env.database.main`, matching this codebase's established
/// convention for a repository `AppEnvironment` doesn't pre-wire (see `DeviceHubFetchInputs`'s own
/// doc for the precedent this follows).
struct DataConflictsFetchInputs {
    var catalog: CatalogRepository
    var reconciliation: ReconciliationRepository
    var dataConflicts: DataConflictRepository
    var measurements: MeasurementRepository
    var registry: MetricRegistry
}

enum DataConflictsFetchOutcome {
    case loaded(DataConflictsData)
    case failure(Error)
}

@Observable
@MainActor
final class DataConflictsViewModel {
    var state: LoadState<DataConflictsData> = .loading

    /// Set when a resolve attempt failed, so the row can say so instead of appearing to have worked.
    var resolveError: String?

    func load(_ env: AppEnvironment) async {
        let inputs = Self.inputs(env)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .loaded(let data):
            state = .loaded(data)
        case .failure(let error):
            LoadErrorLog.log(error, screen: "DataConflicts")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    /// Applies the user's pick, then reloads so every section reflects it. Failure is surfaced
    /// (`resolveError`) rather than swallowed — a resolve that silently did nothing would leave the
    /// person believing they had settled something they hadn't.
    func resolve(conflict: DataConflict, winnerId: String, in data: DataConflictsData,
                 env: AppEnvironment) async {
        guard let table = data.tables[conflict.id],
              let candidates = data.candidates[conflict.id] else {
            resolveError = env.s(DataConflictsStrings.resolveFailed)
            return
        }
        let inputs = Self.inputs(env)
        let clock = env.clock

        let succeeded = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                return try ConflictResolutionService.apply(
                    conflict: conflict, table: table, winnerId: winnerId, candidates: candidates,
                    measurements: inputs.measurements, reconciliation: inputs.reconciliation,
                    dataConflicts: inputs.dataConflicts, clock: clock)
            } catch {
                LoadErrorLog.log(error, screen: "DataConflicts.resolve")
                return false
            }
        }.value

        guard !Task.isCancelled else { return }
        resolveError = succeeded ? nil : env.s(DataConflictsStrings.resolveFailed)
        if succeeded {
            // Suppressing a row changes what every other surface reads, so this is a real data
            // change, not a local one — bumping the generation is what makes Home/Body/Metric
            // Detail agree with what just happened here.
            env.bumpDataGeneration()
        }
        await load(env)
    }

    /// `dataConflicts` is built ad hoc over `env.database.main`, matching this codebase's
    /// established convention for a repository `AppEnvironment` doesn't pre-wire.
    private static func inputs(_ env: AppEnvironment) -> DataConflictsFetchInputs {
        DataConflictsFetchInputs(
            catalog: env.catalog, reconciliation: env.reconciliation,
            dataConflicts: DataConflictRepository(main: env.database.main),
            measurements: env.measurements, registry: env.registry)
    }

    nonisolated static func fetch(_ inputs: DataConflictsFetchInputs) -> DataConflictsFetchOutcome {
        do {
            let sources = try inputs.catalog.sources()
            let sourceNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })
            let resolved = try inputs.reconciliation.recent(limit: 50)
            let unresolved = try inputs.dataConflicts.unresolved()

            var candidates: [String: [ConflictResolutionService.Candidate]] = [:]
            var tables: [String: String] = [:]
            for conflict in unresolved {
                guard let scope = conflict.scope,
                      let table = ConflictResolutionService.table(for: scope, registry: inputs.registry)
                else { continue }
                tables[conflict.id] = table
                candidates[conflict.id] = try ConflictResolutionService.candidates(
                    for: conflict, table: table, measurements: inputs.measurements, sourceNames: sourceNames)
            }

            return .loaded(DataConflictsData(unresolved: unresolved, resolved: resolved,
                                             sourceNames: sourceNames, candidates: candidates, tables: tables))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Screen

/// Lists any unresolved `DataConflict` rows and every resolved reconciliation decision, each with
/// a one-tap "why am I seeing this value?" disclosure naming the rule that decided it (plan §7A.6).
struct DataConflictsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = DataConflictsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                StatefulContainer(
                    vm.state,
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env) } }
                ) { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        SectionHeader(env.s(DataConflictsStrings.unresolvedHeader))
                        if data.unresolved.isEmpty {
                            emptyCard(DataConflictsStrings.unresolvedEmptyMessage)
                        } else {
                            ForEach(data.unresolved) { conflict in
                                DataConflictsUnresolvedRow(
                                    conflict: conflict,
                                    candidates: data.candidates[conflict.id] ?? [],
                                    resolveError: vm.resolveError,
                                    onKeep: { winnerId in
                                        Task { await vm.resolve(conflict: conflict, winnerId: winnerId,
                                                                in: data, env: env) }
                                    })
                            }
                        }

                        SectionHeader(env.s(DataConflictsStrings.resolvedHeader))
                        if data.resolved.isEmpty {
                            emptyCard(DataConflictsStrings.resolvedEmptyMessage)
                        } else {
                            ForEach(data.resolved) { decision in
                                DataConflictsResolvedRow(decision: decision, sourceNames: data.sourceNames)
                            }
                        }
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(DataConflictsStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: DataConflictsLoadKey(generation: env.dataGeneration)) { await vm.load(env) }
    }

    private func emptyCard(_ message: LocalizedString) -> some View {
        BadanCard {
            LText(message)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }
}

// MARK: - Scope label (pure — testable without a view; see `DeviceHubUITests`)

/// Renders a `DataConflict`'s scope as one display string. A free function (not inline in the
/// view) for the same reason `ReconciliationDisclosureFormat` is: directly testable, and the one
/// place this formatting can live without drifting between a test's expectation and the view.
enum DataConflictScopeFormat {
    static func label(_ conflict: DataConflict, registry: MetricRegistry, language: AppLanguage) -> String {
        switch conflict.scope {
        case .metric(let id, let inWorkout):
            let name = registry.definitionOrFallback(id).displayName.resolved(language)
            return inWorkout
                ? "\(name) — \(DataConflictsStrings.duringWorkout.resolved(language))"
                : name
        case .workoutDuplicate:
            return DataConflictsStrings.workoutDuplicateLabel.resolved(language)
        case nil:
            return DataConflictsStrings.unknownScopeLabel.resolved(language)
        }
    }
}

// MARK: - Unresolved row (read-only: names the disagreement, decides nothing)

private struct DataConflictsUnresolvedRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conflict: DataConflict
    let candidates: [ConflictResolutionService.Candidate]
    let resolveError: String?
    let onKeep: (String) -> Void
    @State private var choosing = false

    /// A choice is only offered when there are genuinely 2+ readable readings to choose BETWEEN.
    /// A conflict whose candidate rows no longer resolve keeps its honest read-only presentation
    /// rather than showing a picker with one option, which would be a decision in name only.
    private var canChoose: Bool { candidates.count >= 2 }

    /// Rendered through the same `ValueFormatter.full` every other metric surface uses, so the
    /// number the person compares here is in the display unit and numeral system they see
    /// everywhere else — not the canonical storage unit. Falls back to the raw stored value plus
    /// its unit for a scope with no metric id (`.workoutDuplicate`), where there is no registry
    /// definition to convert against.
    private func valueText(_ candidate: ConflictResolutionService.Candidate) -> String {
        if case .metric(let metricId, _) = conflict.scope {
            return env.format.full(metricId: metricId, canonicalValue: candidate.value)
        }
        return "\(env.format.number(candidate.value, fraction: 1)) \(candidate.unit)"
    }

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.outOfBand)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(DataConflictScopeFormat.label(conflict, registry: env.registry, language: env.language))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(DataConflictsStrings.candidateCount.filling(
                            ["n": env.format.integer(conflict.candidateRecordIds.count)])))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                }
                DeviceHubDetailRow(label: DataConflictsStrings.detectedLabel,
                                   value: DeviceHubDateFormat.string(conflict.detectedAt, env.language))
                LText(DataConflictsStrings.unresolvedNote)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if canChoose {
                    chooseToggle
                    if choosing { chooser }
                } else {
                    LText(DataConflictsStrings.unreadableCandidates)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let resolveError {
                    Text(resolveError)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.outOfBand)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var chooseToggle: some View {
        Button {
            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                choosing.toggle()
            }
        } label: {
            HStack(spacing: BadanSpace.space2) {
                Text(env.s(DataConflictsStrings.chooseAction))
                    .font(BadanFont.caption.weight(.medium))
                    .foregroundStyle(BadanColor.primary)
                Spacer(minLength: BadanSpace.space2)
                Image(systemName: "chevron.forward")
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.primary)
                    .rotationEffect(.degrees(choosing ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            LText(DataConflictsStrings.chooseExplainer)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                        Text(valueText(candidate))
                            .font(BadanFont.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                        if candidate.isManualEntry {
                            PillLabel(env.s(DataConflictsStrings.manualBadge), systemImage: "hand.point.up.left",
                                      tint: BadanColor.textSecondary, filled: false)
                        }
                        if candidate.isSuppressed {
                            PillLabel(env.s(DataConflictsStrings.setAsideBadge), systemImage: "eye.slash",
                                      tint: BadanColor.textSecondary, filled: false)
                        }
                    }
                    Text("\(candidate.sourceName) · \(DeviceHubDateFormat.string(candidate.measuredAt, env.language))")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)

                    Button {
                        onKeep(candidate.id)
                    } label: {
                        Text(env.s(DataConflictsStrings.keepThisOne))
                            .font(BadanFont.caption.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("\(env.s(DataConflictsStrings.keepThisOne)) — \(candidate.sourceName)"))
                }
                .padding(.vertical, BadanSpace.space1)
            }
        }
        .padding(.top, BadanSpace.space1)
    }
}

private struct DataConflictsLoadKey: Equatable {
    let generation: Int
}

// MARK: - Resolved row (one-tap "why am I seeing this value?" disclosure)

private struct DataConflictsResolvedRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let decision: ReconciliationDecision
    let sourceNames: [String: String]
    @State private var expanded = false

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        PillLabel(pillText(decision.detail["winner_source"], suffix: env.s(DataConflictsStrings.kept)),
                                  systemImage: "checkmark", tint: BadanColor.inBand)
                        PillLabel(pillText(decision.detail["loser_source"], suffix: env.s(Loc.suppressedDuplicate)),
                                  systemImage: "arrow.uturn.backward", tint: BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    if decision.isReversed {
                        PillLabel(env.s(DataConflictsStrings.alreadyReversed), systemImage: "arrow.uturn.backward.circle",
                                  tint: BadanColor.textSecondary, filled: false)
                    }
                }

                Button {
                    withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: BadanSpace.space2) {
                        Text(env.s(DataConflictsStrings.whyTitle))
                            .font(BadanFont.caption.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.primary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)

                if expanded {
                    VStack(alignment: .leading, spacing: BadanSpace.space2) {
                        if let explanation = DataConflictsStrings.ruleGlossary[decision.rule] {
                            Text(env.s(explanation))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        detailRow(DataConflictsStrings.ruleLabel, value: ReconciliationDisclosureFormat.ruleLine(decision))
                        detailRow(DataConflictsStrings.decidedLabel,
                                  value: DeviceHubDateFormat.string(decision.decidedAt, env.language))
                        // `reversible == false` never occurs in practice today — see the doc
                        // comment on `ReconciliationDecision.reversible` for why this branch is a
                        // real, currently-unreached value the type's own contract allows, not a
                        // stub.
                        if !decision.reversible {
                            Text(env.s(DataConflictsStrings.notReversible))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        } else if !decision.isReversed {
                            Text(env.s(DataConflictsStrings.reversibleNote))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                    .padding(.top, BadanSpace.space1)
                }
            }
        }
    }

    private func pillText(_ sourceId: String?, suffix: String) -> String {
        guard let sourceId, !sourceId.isEmpty else { return suffix }
        let name = sourceNames[sourceId] ?? sourceId
        return "\(name) — \(suffix)"
    }

    private func detailRow(_ label: LocalizedString, value: String) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Text(env.s(label))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.caption.monospaced())
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
                // Rule identifiers and timestamps read left-to-right in both languages, matching
                // `ProvenanceRow`/`InsightsWhyDisclosure`.
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
