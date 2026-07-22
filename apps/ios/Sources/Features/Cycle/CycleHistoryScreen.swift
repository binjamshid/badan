import SwiftUI

// ============================================================================
// MARK: - EPIC-39 (Phase 3F slice 2) — cycle history + prediction detail + anomaly history.
// ============================================================================
//
// This lane owns exactly two files: this screen and `Tests/CycleHistoryUITests.swift`. It is UI
// only, built over the already-committed, audited domain core (commit c8fa895 —
// `Domain/Cycle/{CycleModels,CyclePredictionEngine,CycleAnomalyEngine}.swift`, `Domain/Derivation/
// CyclePhaseCovariateCoordinator.swift`, and the six sensitive-only `Storage/Repositories/Cycle*
// Repository.swift` files) and the shared composition layer another lane already landed
// (`Features/Cycle/CycleModuleServices.swift`, `Domain/Customization.swift`'s `cycleModuleEnabled`/
// `cyclePredictionsPaused` fields). Nothing here redesigns any of those — every read below goes
// through `CycleModuleServices`'s existing public surface, exactly as that file declares it
// (`cycleRecords`/`flowLogs`/`predictions`/`phaseEstimates`/`anomalies`, all sensitive-DB-only).
//
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` (esp. §5 prediction/expectation model, §6
// anomaly model, §9 privacy architecture, §12 casual UX, §14 wellness-safe language) and
// `docs/legal/reproductive-threat-model.md` (binding, not advisory). Reachable by being pushed
// onto a `NavigationStack` from `CycleHomeScreen`'s prediction summary — another lane's own
// routing, not built here; this screen only needs to compile and render given a
// `CycleModuleServices` instance.
//
// STANDING CONSTRAINTS THIS FILE HOLDS ITSELF TO (repeated from the brief, load-bearing):
//   * No single-date predictions ever rendered. `predictedNextStartLow/Center/High` are only ever
//     shown TOGETHER, in the same card, alongside a confidence descriptor and a method label —
//     never a lone predicted date presented as if it were a due date. `CyclePrediction.
//     suppressionReason` is NEVER rendered directly (it is an internal, non-user-facing placeholder
//     per that field's own doc comment); the paused sentence below is BADAN's own calm copy.
//   * No diagnostic/clinical language. The anomaly section renders ONLY
//     `CycleAnomalyMessages.text(for:)` — never a freshly-invented description of what an anomaly
//     "means".
//   * Anti-panic palette: `BadanColor.outOfBand` (muted amber) for an active anomaly, never a raw
//     red, never the reserved-and-unused critical color token, never a traffic-light/verdict word.
//   * Neutral "cycle" language throughout — never "period" in user-facing copy.
//   * Out of scope, not built here: fertile-window/ovulation as a user-facing FEATURE (A17),
//     BBT/cervical-mucus/ovulation-test logging, sexual-activity logging, sharing, symptom overlay.
//     Rendering `CyclePhase.ovulatory`'s bare phase NAME below (an already-built CYCLE-06 output,
//     used as a baseline covariate) is not a fertile-window feature — it makes no conception/
//     contraception claim, exactly like the domain engine's own header states.
//
// This screen is read-only history: it never logs a period, never edits a contraceptive context,
// and never acknowledges/dismisses an anomaly — those are other lanes' write-surfaces. It also
// never calls `refreshAll`/`purgeCycleData` (those are triggered by write actions/settings
// elsewhere) and never constructs a repository of its own — every read goes through the
// `CycleModuleServices` instance it is handed.

// MARK: - CyclePhase display name (mirrors `LabSensitivityTier.displayName`, `Domain/Labs/
// LabModels.swift`, exactly) — a Features-layer extension on a Domain enum, the same established
// pattern `extension MetricFamily: Identifiable` uses in `Features/Body/SourcesScreen.swift` (this
// app builds as a single Xcode target, so there is no cross-module boundary being crossed).

extension CyclePhase {
    var displayName: LocalizedString {
        switch self {
        case .menstrual: return LocalizedString(en: "Menstrual", ar: "الطمث")
        case .follicular: return LocalizedString(en: "Follicular", ar: "الجريبي")
        case .ovulatory: return LocalizedString(en: "Ovulatory", ar: "الإباضي")
        case .luteal: return LocalizedString(en: "Luteal", ar: "الأصفري")
        case .unknown: return LocalizedString(en: "Not enough pattern yet", ar: "لا يوجد نمط كافٍ بعد")
        }
    }
}

// MARK: - Screen-local strings

enum CycleHistoryStrings {
    static let title = LocalizedString(en: "Cycle history", ar: "سجلّ الدورة")

    // Prediction detail
    static let predictionSectionTitle = LocalizedString(en: "Next cycle estimate", ar: "تقدير الدورة القادمة")
    static let expectedRange = LocalizedString(en: "Expected between {low} and {high}", ar: "متوقعة بين {low} و{high}")
    static let centeredAround = LocalizedString(en: "Centered around {center}", ar: "تتمحور حول {center}")
    static let methodLabel = LocalizedString(en: "Based on {n} recent cycles", ar: "استناداً إلى {n} من الدورات الأخيرة")
    static let noEstimateYet = LocalizedString(
        en: "Log at least one more cycle to begin an estimate.",
        ar: "سجّل دورة واحدة إضافية على الأقل لبدء التقدير.")
    static let broadEstimate = LocalizedString(
        en: "Your pattern is variable right now, so this estimate is broad.",
        ar: "نمطك متغيّر حالياً، لذا هذا التقدير واسع.")
    static let moderateEstimate = LocalizedString(
        en: "This estimate is based on your recent cycles and may still settle.",
        ar: "يستند هذا التقدير إلى دوراتك الأخيرة وقد يستقر أكثر لاحقاً.")
    static let confidentEstimate = LocalizedString(
        en: "This estimate reflects your longer recent pattern.",
        ar: "يعكس هذا التقدير نمطك الأطول في الفترة الأخيرة.")
    static let predictionPaused = LocalizedString(
        en: "Estimates are paused while an active contraceptive context is logged.",
        ar: "التقديرات متوقفة مؤقتاً أثناء تسجيل سياق فعّال لوسيلة منع حمل.")

    static let whyThisEstimate = LocalizedString(en: "Why this estimate?", ar: "لماذا هذا التقدير؟")
    static let anatomyIntro = LocalizedString(
        en: "This estimate was built from these logged cycles.",
        ar: "بُني هذا التقدير من هذه الدورات المسجَّلة.")
    static let anatomyEmpty = LocalizedString(
        en: "Not enough logged cycles on file to name what fed this estimate.",
        ar: "لا توجد دورات مسجَّلة كافية لتحديد ما غذّى هذا التقدير.")

    // Phase section
    static let phaseSectionTitle = LocalizedString(en: "Today's phase", ar: "مرحلة اليوم")
    static let notEnoughPatternYet = LocalizedString(
        en: "Not enough recent pattern yet to estimate today's phase.",
        ar: "لا يوجد نمط كافٍ في الفترة الأخيرة لتقدير مرحلة اليوم.")
    static let pausedForContraceptiveContext = LocalizedString(
        en: "Paused because of your current contraceptive context.",
        ar: "متوقف مؤقتاً بسبب سياق وسيلة منع الحمل الحالي لديك.")

    // History section
    static let historySectionTitle = LocalizedString(en: "Logged cycles", ar: "الدورات المسجَّلة")
    static let noCyclesLogged = LocalizedString(en: "No cycles logged yet.", ar: "لا توجد دورات مسجَّلة بعد.")
    static let ongoing = LocalizedString(en: "Ongoing", ar: "مستمرة")
    static let durationDays = LocalizedString(en: "Lasted {n} days", ar: "استمرت {n} أيام")
    static let flowEntriesLogged = LocalizedString(en: "{n} flow entries logged", ar: "{n} من قيود التدفق المسجَّلة")
    static let latestFlow = LocalizedString(en: "Latest: {label}", ar: "الأحدث: {label}")

    // Anomaly history
    static let anomalySectionTitle = LocalizedString(en: "Pattern notes", ar: "ملاحظات النمط")
    static let anomalyEmpty = LocalizedString(en: "No pattern notes on file.", ar: "لا توجد ملاحظات نمط مسجَّلة.")
    static let unresolvedAnomalyNote = LocalizedString(
        en: "This note can't be shown right now.", ar: "لا يمكن عرض هذه الملاحظة الآن.")
    static let stateActive = LocalizedString(en: "Active", ar: "حالية")
    static let stateAcknowledged = LocalizedString(en: "Seen", ar: "تمت رؤيتها")
    static let stateDismissed = LocalizedString(en: "Dismissed", ar: "تم تجاهلها")
    static let stateSuppressed = LocalizedString(en: "No longer applies", ar: "لم تعد سارية")

    static let loadFailed = LocalizedString(en: "Couldn't load your cycle history right now.", ar: "تعذّر تحميل سجل الدورة الآن.")
}

// MARK: - Pure logic (tested directly — see CycleHistoryUITests)

/// Most-recently-started-first ordering, and the per-period flow-log summary. Kept independent of
/// any particular repository call (`CycleRecordRepository.liveRecords()` already orders this way,
/// but re-deriving it here makes the ordering directly testable without a database).
enum CycleHistorySummary {
    static func sortedMostRecentFirst(_ records: [CycleRecord]) -> [CycleRecord] {
        records.sorted { $0.startAt > $1.startAt }
    }

    /// `logs` is expected in occurred-ascending order (`FlowLogRepository.liveLogs`'s own
    /// contract) — the last element is the most recently logged flow moment for this period.
    /// `originalLabel` is surfaced verbatim, never rewritten against `CycleFlowIntensity`'s
    /// dictionary, per `FlowLog`'s own doc.
    static func flowSummary(_ logs: [FlowLog]) -> CycleFlowSummary? {
        guard !logs.isEmpty else { return nil }
        return CycleFlowSummary(count: logs.count, mostRecentLabel: logs.last?.originalLabel)
    }
}

struct CycleFlowSummary: Equatable {
    let count: Int
    let mostRecentLabel: String?
}

/// Everything the prediction-detail card needs to decide WHAT to show, kept independent of SwiftUI
/// so it is testable without a view. Never derives a re-guess at the engine's own private tier
/// thresholds (`CyclePredictionEngine`'s confidence constants are `private` by design) — these are
/// separate, UI-only descriptive buckets keyed off the ALREADY-COMPUTED, already-public `method`/
/// `status` fields.
enum CyclePredictionPresentation {
    /// A predicted range is only ever considered present when every one of the three range fields
    /// is populated AND the forecast is not paused — matches `CyclePredictionEngine`'s own
    /// guarantee that a paused/coldStart forecast carries nil range fields, checked again here
    /// defensively rather than assumed.
    static func hasRange(_ prediction: CyclePrediction) -> Bool {
        prediction.status == .active
            && prediction.predictedNextStartLow != nil
            && prediction.predictedNextStartCenter != nil
            && prediction.predictedNextStartHigh != nil
    }

    /// `n` for "based on {n} recent cycles" — the exact count of `CycleRecord`s named in
    /// `inputCycleIds`, the real audit manifest, never a guessed or re-derived count. `nil`
    /// suppresses the method label entirely (coldStart, paused, or an empty manifest).
    static func recentCycleCount(_ prediction: CyclePrediction) -> Int? {
        guard prediction.status == .active, prediction.method != .coldStart,
              !prediction.inputCycleIds.isEmpty else { return nil }
        return prediction.inputCycleIds.count
    }

    /// One sentence, always shown, drawn from the exact phrasing bank in
    /// `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §5/§14 ("pattern is variable right now, so the
    /// estimate is broad", etc.). Paused takes priority over method — a suppressed forecast's
    /// `method` field still names a history tier, but the paused reason is the one fact worth
    /// saying. NEVER reads the prediction engine's own internal suppression-reason field — that
    /// field is documented as an internal, non-rendered placeholder (`CyclePredictionEngine`'s own
    /// file header).
    static func confidenceDescriptor(_ prediction: CyclePrediction) -> LocalizedString {
        if prediction.status == .paused { return CycleHistoryStrings.predictionPaused }
        switch prediction.method {
        case .coldStart: return CycleHistoryStrings.noEstimateYet
        case .lowHistory: return CycleHistoryStrings.broadEstimate
        case .moderateHistory: return CycleHistoryStrings.moderateEstimate
        case .matureHistory: return CycleHistoryStrings.confidentEstimate
        }
    }
}

/// The "why this estimate?" anatomy sheet's own resolution logic — `CyclePrediction.inputCycleIds`
/// resolved back to the real `CycleRecord`s that fed the forecast (the research doc §5's own named
/// "anatomy sheet"). Preserves `inputCycleIds`' own order rather than re-sorting. An id with no
/// matching record among the ones passed in (e.g. it named a since-superseded revision no longer
/// live) is silently skipped — graceful degradation over a crash or a fabricated placeholder row,
/// matching this codebase's standing posture for malformed/partial persisted data.
enum CyclePredictionAnatomy {
    static func resolvedInputs(_ prediction: CyclePrediction, records: [CycleRecord]) -> [CycleRecord] {
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return prediction.inputCycleIds.compactMap { byId[$0] }
    }
}

/// The phase section's gate + caveat selection. Reuses `CyclePhaseCovariateCoordinator`'s own
/// write-side confidence floor (0.5, "a coin-flip-or-better floor") as the READ-side bar for
/// showing a phase NAME at all — the same "reasonably high" confidence a materially identical
/// decision in this codebase already draws a line at, rather than an arbitrary new number.
enum CyclePhasePresentation {
    static var minConfidenceToShowPhase: Double { CyclePhaseCovariateCoordinator.minPhaseConfidenceForConditionedRecompute }

    static func shouldShowPhaseName(_ estimate: CyclePhaseEstimate) -> Bool {
        estimate.evidenceBasis == .calendarOnly && estimate.confidence >= minConfidenceToShowPhase
    }

    /// The plain, factual caveat — never fabricated vocabulary beyond what
    /// `CyclePhaseEvidenceBasis` itself represents. `nil` exactly when `shouldShowPhaseName` is
    /// `true` (the two are never both shown at once).
    static func caveat(_ estimate: CyclePhaseEstimate) -> LocalizedString? {
        if shouldShowPhaseName(estimate) { return nil }
        switch estimate.evidenceBasis {
        case .suppressedDueToContext: return CycleHistoryStrings.pausedForContraceptiveContext
        case .insufficientHistory, .calendarOnly: return CycleHistoryStrings.notEnoughPatternYet
        }
    }
}

/// The anomaly-history section's row model — every `CycleAnomalyEvent` on file (not just active
/// ones), most-recently-detected first, each resolved through `CycleAnomalyMessages.text(for:)`
/// ONLY — this function has no other way to produce anomaly copy, structurally enforcing the
/// "never a freshly-invented description" rule.
enum CycleAnomalyPresentation {
    struct Row: Identifiable, Equatable {
        let id: String
        let text: LocalizedString?
        let state: CycleAnomalyState
        let detectedAt: Date
    }

    static func rows(_ events: [CycleAnomalyEvent]) -> [Row] {
        events
            .sorted { $0.detectedAt > $1.detectedAt }
            .map { Row(id: $0.id, text: CycleAnomalyMessages.text(for: $0.messageKey), state: $0.state, detectedAt: $0.detectedAt) }
    }
}

// MARK: - Loaded data

private struct CycleHistoryData {
    var records: [CycleRecord]
    var flowLogsByCycle: [String: [FlowLog]]
    var prediction: CyclePrediction?
    var phaseEstimate: CyclePhaseEstimate?
    var anomalies: [CycleAnomalyEvent]
}

// MARK: - Screen

/// Cycle history + prediction detail + anomaly history. Pushed onto a `NavigationStack` from
/// `CycleHomeScreen`'s prediction summary (another lane's own routing). Read-only: no logging, no
/// contraceptive-context editing, no anomaly acknowledge/dismiss here.
struct CycleHistoryScreen: View {
    @Environment(AppEnvironment.self) private var env
    let services: CycleModuleServices

    @State private var state: LoadState<CycleHistoryData> = .loading
    @State private var showAnatomySheet = false

    private struct LoadKey: Equatable {
        let profile: CustomizationProfile
        let generation: Int
    }

    var body: some View {
        ScrollView {
            StatefulContainer(state, emptyIcon: "calendar") { data in
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    predictionSection(data)
                    phaseSection(data)
                    historySection(data)
                    anomalySection(data)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(CycleHistoryStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: LoadKey(profile: env.profile, generation: env.dataGeneration)) { load() }
        .sheet(isPresented: $showAnatomySheet) {
            if case .loaded(let data) = state, let prediction = data.prediction {
                CyclePredictionAnatomySheet(prediction: prediction, records: data.records)
            }
        }
    }

    // MARK: Load

    private func load() {
        do {
            let records = try services.cycleRecords.liveRecords()
            var flowByCycle: [String: [FlowLog]] = [:]
            for record in records {
                flowByCycle[record.id] = try services.flowLogs.liveLogs(cycleId: record.id)
            }
            let prediction = try services.predictions.latestPrediction()
            let phaseEstimate = try services.phaseEstimates.latestEstimate(asOf: env.now())
            let anomalies = try services.anomalies.liveEvents()
            state = .loaded(CycleHistoryData(records: records, flowLogsByCycle: flowByCycle,
                                              prediction: prediction, phaseEstimate: phaseEstimate,
                                              anomalies: anomalies))
        } catch {
            LoadErrorLog.log(error, screen: "CycleHistoryScreen")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Prediction detail

    private func predictionSection(_ data: CycleHistoryData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(CycleHistoryStrings.predictionSectionTitle)) {
                    if let prediction = data.prediction, !prediction.inputCycleIds.isEmpty {
                        Button(env.s(CycleHistoryStrings.whyThisEstimate)) { showAnatomySheet = true }
                            .font(BadanFont.link)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                }
                if let prediction = data.prediction {
                    predictionBody(prediction)
                } else {
                    Text(env.s(CycleHistoryStrings.noEstimateYet))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Every date here is shown TOGETHER with its range partners, the confidence descriptor, and
    /// the method label, in this one card — never a lone predicted date presented in isolation.
    @ViewBuilder
    private func predictionBody(_ prediction: CyclePrediction) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            if CyclePredictionPresentation.hasRange(prediction),
               let low = prediction.predictedNextStartLow,
               let center = prediction.predictedNextStartCenter,
               let high = prediction.predictedNextStartHigh {
                Text(env.s(CycleHistoryStrings.expectedRange.filling(["low": dateText(low), "high": dateText(high)])))
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: false, vertical: true)
                Text(env.s(CycleHistoryStrings.centeredAround.filling(["center": dateText(center)])))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Text(env.s(CyclePredictionPresentation.confidenceDescriptor(prediction)))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let n = CyclePredictionPresentation.recentCycleCount(prediction) {
                Text(env.s(CycleHistoryStrings.methodLabel.filling(["n": env.format.integer(n)])))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    // MARK: Phase (optional, calm)

    @ViewBuilder
    private func phaseSection(_ data: CycleHistoryData) -> some View {
        if let estimate = data.phaseEstimate {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    SectionHeader(env.s(CycleHistoryStrings.phaseSectionTitle))
                    if CyclePhasePresentation.shouldShowPhaseName(estimate) {
                        Text(env.s(estimate.phase.displayName))
                            .font(BadanFont.body.weight(.medium))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text("\(dateText(estimate.dateRangeStart)) – \(dateText(estimate.dateRangeEnd))")
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .environment(\.layoutDirection, .leftToRight)
                    } else if let caveat = CyclePhasePresentation.caveat(estimate) {
                        Text(env.s(caveat))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: History

    private func historySection(_ data: CycleHistoryData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(CycleHistoryStrings.historySectionTitle))
            if data.records.isEmpty {
                Text(env.s(CycleHistoryStrings.noCyclesLogged))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                ForEach(CycleHistorySummary.sortedMostRecentFirst(data.records)) { record in
                    CycleRecordRow(record: record,
                                   flowSummary: CycleHistorySummary.flowSummary(data.flowLogsByCycle[record.id] ?? []))
                }
            }
        }
    }

    // MARK: Anomaly history

    private func anomalySection(_ data: CycleHistoryData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(CycleHistoryStrings.anomalySectionTitle))
            if data.anomalies.isEmpty {
                Text(env.s(CycleHistoryStrings.anomalyEmpty))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                ForEach(CycleAnomalyPresentation.rows(data.anomalies)) { row in
                    CycleAnomalyRow(row: row)
                }
            }
        }
    }

    // MARK: Dates

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    private func dateText(_ date: Date) -> String {
        Self.dateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateFormatter.string(from: date)
    }
}

// MARK: - "Why this estimate?" anatomy sheet (research doc §5's own named UI element)

private struct CyclePredictionAnatomySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let prediction: CyclePrediction
    let records: [CycleRecord]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    private var resolved: [CycleRecord] {
        CyclePredictionAnatomy.resolvedInputs(prediction, records: records)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    if resolved.isEmpty {
                        Text(env.s(CycleHistoryStrings.anatomyEmpty))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(env.s(CycleHistoryStrings.anatomyIntro))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(resolved) { record in
                            BadanCard {
                                HStack(spacing: BadanSpace.space2) {
                                    Text(dateText(record.startAt))
                                        .font(BadanFont.bodyCompact.monospacedDigit())
                                        .foregroundStyle(BadanColor.textPrimary)
                                        .environment(\.layoutDirection, .leftToRight)
                                    if let end = record.endAt {
                                        Text("– \(dateText(end))")
                                            .font(BadanFont.bodyCompact.monospacedDigit())
                                            .foregroundStyle(BadanColor.textSecondary)
                                            .environment(\.layoutDirection, .leftToRight)
                                    }
                                    Spacer(minLength: BadanSpace.space2)
                                    if record.ongoing {
                                        PillLabel(env.s(CycleHistoryStrings.ongoing), tint: BadanColor.textSecondary, filled: false)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(CycleHistoryStrings.whyThisEstimate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func dateText(_ date: Date) -> String {
        Self.dateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateFormatter.string(from: date)
    }
}

// MARK: - History row

private struct CycleRecordRow: View {
    @Environment(AppEnvironment.self) private var env
    let record: CycleRecord
    let flowSummary: CycleFlowSummary?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: "calendar")
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(dateRangeText)
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                        .environment(\.layoutDirection, .leftToRight)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: BadanSpace.space2)
                    if record.ongoing {
                        PillLabel(env.s(CycleHistoryStrings.ongoing), tint: BadanColor.primary, filled: false)
                    }
                }
                if let days = durationDays {
                    Text(env.s(CycleHistoryStrings.durationDays.filling(["n": env.format.integer(days)])))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                if let flowSummary {
                    Text(env.s(CycleHistoryStrings.flowEntriesLogged.filling(["n": env.format.integer(flowSummary.count)])))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    if let label = flowSummary.mostRecentLabel {
                        Text(env.s(CycleHistoryStrings.latestFlow.filling(["label": label])))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    private var dateRangeText: String {
        Self.dateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        let start = Self.dateFormatter.string(from: record.startAt)
        guard let end = record.endAt else { return start }
        return "\(start) – \(Self.dateFormatter.string(from: end))"
    }

    private var durationDays: Int? {
        guard let end = record.endAt else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: record.startAt, to: end).day
    }
}

// MARK: - Anomaly row

private struct CycleAnomalyRow: View {
    @Environment(AppEnvironment.self) private var env
    let row: CycleAnomalyPresentation.Row

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space2) {
                    Text(dateText)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                    Spacer(minLength: BadanSpace.space2)
                    statePill
                }
                Text(env.s(row.text ?? CycleHistoryStrings.unresolvedAnomalyNote))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dateText: String {
        Self.dateFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateFormatter.string(from: row.detectedAt)
    }

    /// `BadanColor.outOfBand` (muted amber) for `.active` only — every other state reads as calm,
    /// settled history via `BadanColor.textSecondary`. Never red, never the reserved critical token.
    @ViewBuilder
    private var statePill: some View {
        switch row.state {
        case .active:
            PillLabel(env.s(CycleHistoryStrings.stateActive), tint: BadanColor.outOfBand, filled: false)
        case .acknowledged:
            PillLabel(env.s(CycleHistoryStrings.stateAcknowledged), tint: BadanColor.textSecondary, filled: false)
        case .dismissed:
            PillLabel(env.s(CycleHistoryStrings.stateDismissed), tint: BadanColor.textSecondary, filled: false)
        case .suppressed:
            PillLabel(env.s(CycleHistoryStrings.stateSuppressed), tint: BadanColor.textSecondary, filled: false)
        }
    }
}
