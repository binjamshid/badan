import SwiftUI

// ============================================================================
// MARK: - EPIC-39 (Phase 3F slice 2) — cycle module home screen + period/flow logging (Lane B).
// ============================================================================
//
// This lane owns exactly two files: this screen and `PeriodLogScreen.swift` (plus their shared
// test file, `Tests/CycleHomeUITests.swift`). Built entirely over already-landed pieces this lane
// does not redesign:
//   - The audited domain core (commit c8fa895): `Domain/Cycle/{CycleModels,CyclePredictionEngine,
//     CycleAnomalyEngine}.swift`.
//   - The shared composition layer another lane already landed: `Features/Cycle/
//     CycleModuleServices.swift` — every read/write below goes through its existing public surface
//     exactly as that file declares it (`cycleRecords`/`flowLogs`/`contraceptiveContext`/
//     `predictions`/`phaseEstimates`/`anomalies`/`deviceId`, `refreshAll(asOf:)`,
//     `purgeCycleData()`), and `Domain/Customization.swift`'s `cycleModuleEnabled`/
//     `cyclePredictionsPaused` fields (read by `CycleModuleServices`/`CycleConsentScreen`, never
//     touched directly here).
//   - `CycleConsentScreen`/`CycleExportScreen`/`CycleHistoryScreen` (other UI lanes, already
//     landed) — routed to below using their REAL, already-declared init signatures:
//     `CycleConsentScreen()` (zero-arg — it constructs its own services), `CycleExportScreen
//     (services:)`, `CycleHistoryScreen(services:)`.
//   - `CyclePredictionPresentation` and `CycleHistoryStrings.methodLabel` — already defined in
//     `CycleHistoryScreen.swift` (same module, no import needed) and REUSED here rather than
//     re-derived, so the confidence-descriptor/method-label wording this screen's compact summary
//     shows can never silently drift from the full history detail screen's own wording for the
//     exact same forecast.
//
// STANDING CONSTRAINTS THIS FILE HOLDS ITSELF TO (from the task brief / research doc / threat
// model — not restated in full, only the load-bearing shape each enforces):
//   * No single-date predictions ever rendered. `predictedNextStartLow/Center/High` are only ever
//     shown TOGETHER as a range, alongside a confidence descriptor and a method label — never a
//     lone predicted date. `CyclePrediction.suppressionReason` is NEVER read directly here (that
//     field is an internal, non-user-facing placeholder per its own doc comment) — the paused
//     sentence comes from `CyclePredictionPresentation.confidenceDescriptor`'s own calm copy.
//   * No diagnostic/clinical language. Anomaly cards render ONLY `CycleAnomalyMessages.text(for:)`
//     verbatim, never a freshly-invented description.
//   * Anti-panic palette: `BadanColor.outOfBand` (muted amber) for a flagged anomaly — never red,
//     never the reserved-and-unused critical color token, never a traffic-light/verdict word.
//   * Neutral "cycle" language throughout every rendered string here — never "period" (the file
//     name `PeriodLogScreen.swift`/type `CycleRecord` etc. are internal identifiers, not user-facing
//     copy, and are unaffected by this rule).
//   * `CycleFlowIntensity` (rendered in `PeriodLogScreen.swift`, this lane's sibling file) gets a
//     proper bilingual `displayName` there — never its raw `rawValue` — following
//     `LabSensitivityTier`'s own fix (`Domain/Labs/LabModels.swift`) as the template. This screen
//     never renders `CyclePredictionMethod`'s raw value either: it never touches that enum directly
//     at all, reading only through `CyclePredictionPresentation`'s already-public, non-raw-value
//     surface.
//   * Out of scope, not built here: fertile-window/ovulation as a user-facing feature (A17), BBT/
//     cervical-mucus/ovulation-test logging, sexual-activity logging, sharing, symptom overlay.
//     Consuming phase-conditioned baselines from THIS screen's own read paths is explicitly out of
//     scope too (per `CycleModuleServices`'s own header) — this screen never reads a phase-
//     conditioned baseline, only the plain `CyclePhaseEstimate`/`CyclePrediction`/`CycleAnomalyEvent`
//     rows `CycleModuleServices` already exposes.
//
// This screen never calls `purgeCycleData()` (that is `CycleConsentScreen`'s settings action) and
// never constructs a repository of its own — every read/write goes through the `CycleModuleServices`
// instance this screen constructs once and threads to every child screen it routes to.

// MARK: - Screen-local strings
//
// "Cycle", never "period" — the neutral-by-default language the threat model's §5 requires (see
// `MetricFamily.cycle`'s own framing, reused directly below for this screen's title rather than a
// second, possibly-drifting title string).
enum CycleHomeStrings {
    static let coldStartTitle = LocalizedString(en: "No cycle logged yet", ar: "لا توجد دورة مسجّلة بعد")
    static let coldStartMessage = LocalizedString(
        en: "Log your first cycle to see your day count and a next-cycle estimate build up over time.",
        ar: "يمكنك تسجيل أول دورة لرؤية عدد أيام دورتك وتقدير الدورة القادمة يتكوّن مع الوقت.")
    static let startCycleAction = LocalizedString(en: "Start cycle", ar: "بدء الدورة")
    static let endCycleAction = LocalizedString(en: "End cycle", ar: "إنهاء الدورة")
    static let logFlowAction = LocalizedString(en: "Log flow", ar: "تسجيل التدفق")
    static let dayLabel = LocalizedString(en: "Day {n}", ar: "اليوم {n}")
    static let ongoingSubtitle = LocalizedString(en: "Ongoing", ar: "مستمرة")
    static let predictionSectionTitle = LocalizedString(en: "Next cycle", ar: "الدورة القادمة")
    static let anomaliesSectionTitle = LocalizedString(en: "Recent patterns", ar: "الأنماط الأخيرة")
    /// Low-confidence phrasing pattern, research doc §5/§14 ("likely between...").
    static let likelyBetween = LocalizedString(
        en: "Likely between {low} and {high}.", ar: "من المرجّح أن تكون بين {low} و{high}.")
    /// Moderate/mature-confidence phrasing pattern, research doc §5/§14 ("expected around...").
    static let expectedAround = LocalizedString(
        en: "Expected around {center} (between {low} and {high}).",
        ar: "متوقعة في حوالي {center} (بين {low} و{high}).")
    static let dismissAction = LocalizedString(en: "Dismiss", ar: "تجاهل")
    static let dismissFailed = LocalizedString(
        en: "Couldn't dismiss that right now — try again.", ar: "تعذّر التجاهل الآن — حاول مرة أخرى.")
    static let settingsAction = LocalizedString(en: "Cycle settings", ar: "إعدادات الدورة")
}

// MARK: - Pure logic (tested directly — see CycleHomeUITests)

/// What the status card shows: nothing logged yet, or a calendar-only day count against the most
/// recently STARTED live `CycleRecord` — "Day N" counts the whole cycle (start date = Day 1),
/// independent of whether that period's own bleed has finished, matching how a cycle-day count is
/// ordinarily understood (not just "days still bleeding"). Never a diagnostic tone, never more than
/// a calendar count.
enum CycleHomeStatus: Equatable {
    case noRecordsYet
    case tracking(dayNumber: Int, ongoing: Bool)
}

/// Resolves `CycleHomeStatus` from a caller-supplied `[CycleRecord]` — defensively re-derives the
/// most-recently-started row by `startAt` rather than trusting the caller's array order (the same
/// "don't trust caller order" discipline `CycleHistorySummary.sortedMostRecentFirst`/
/// `CyclePredictionEngine.sortedLiveRecords` already apply elsewhere in this codebase), so this stays
/// correct even if a future caller passes an unsorted array.
enum CycleStatusResolver {
    static func resolve(liveRecords: [CycleRecord], asOf: Date, tz: String) -> CycleHomeStatus {
        guard let mostRecent = liveRecords.max(by: { $0.startAt < $1.startAt }) else { return .noRecordsYet }
        return .tracking(dayNumber: dayNumber(startAt: mostRecent.startAt, asOf: asOf, tz: tz),
                          ongoing: mostRecent.ongoing)
    }

    /// Day 1 on the start date itself, Day 2 the next calendar day, and so on — computed via each
    /// date's own start-of-day in `tz` (not raw `timeIntervalSince/86_400`), the same DST-safe
    /// posture `DayAttribution`/`CyclePredictionEngine`'s own day arithmetic takes everywhere else.
    /// Floored at 1 so a clock-skew edge case (`asOf` somehow before `startAt`) never renders "Day 0"
    /// or a negative day count.
    static func dayNumber(startAt: Date, asOf: Date, tz: String) -> Int {
        let cal = DayAttribution.calendar(tz: tz)
        let startDay = cal.startOfDay(for: startAt)
        let asOfDay = cal.startOfDay(for: asOf)
        let diff = cal.dateComponents([.day], from: startDay, to: asOfDay).day ?? 0
        return max(1, diff + 1)
    }
}

/// The anomaly CARDS this screen renders — deliberately narrower than `CycleAnomalyPresentation`
/// (`CycleHistoryScreen.swift`, another lane's read-only full history of every state): this screen
/// shows only LIVE, non-dismissed events, each paired with a dismiss action, so it needs its own
/// filter+resolve step rather than reusing that history-only row model.
///
/// Filters to `state != .dismissed` only, per this lane's exact brief ("render each live,
/// non-dismissed CycleAnomalyEvent") — `.active`/`.acknowledged`/`.suppressed` all still render here;
/// only a user's own dismiss action (or a future lane's own acknowledge/suppress UI) changes that.
/// An event whose `messageKey` this build's `CycleAnomalyMessages` doesn't recognize (a future engine
/// version's key) is silently skipped rather than rendered with a fabricated fallback sentence, per
/// that lookup's own doc.
enum CycleHomeAnomalyPresentation {
    static func renderable(_ events: [CycleAnomalyEvent]) -> [(event: CycleAnomalyEvent, message: LocalizedString)] {
        events
            .filter { $0.state != .dismissed }
            .compactMap { event in CycleAnomalyMessages.text(for: event.messageKey).map { (event, $0) } }
    }
}

// MARK: - Navigation routing

/// The FOUR destinations this screen's toolbar/prediction card route to — all OTHER lanes' screens,
/// already landed with the real signatures used below (`CycleConsentScreen()` is zero-arg by
/// design: it constructs its own `CycleModuleServices` internally, exactly like this screen does,
/// rather than taking one as a parameter).
///
/// AUDIT FIX (Integrate phase, cross-lane reconciliation): `.contraceptiveContext` was added here
/// because `ContraceptiveContextScreen` (Lane D — CYCLE-07) had a real, tested screen with no
/// construction site ANYWHERE in the app — `scripts/check-reachability.py` flags this as a
/// violation ("built but dark"), and no lane's own test suite asserted this cross-lane path (each
/// lane's reachability test only covers the ONE sub-screen it itself constructs, by design — see
/// e.g. `CycleHistoryUITests`'s own header). Research doc §4's data-inventory table names this
/// screen's placement explicitly ("Visible in cycle settings and timeline cards"), so wiring it in
/// as a toolbar entry point here (alongside settings/export) is the fix, not a new design choice.
enum CycleRoute: Hashable, Identifiable {
    case history
    case consent
    case export
    case contraceptiveContext

    var id: String {
        switch self {
        case .history: return "history"
        case .consent: return "consent"
        case .export: return "export"
        case .contraceptiveContext: return "contraceptiveContext"
        }
    }

    @ViewBuilder
    func makeView(services: CycleModuleServices) -> some View {
        switch self {
        case .history: CycleHistoryScreen(services: services)
        case .consent: CycleConsentScreen()
        case .export: CycleExportScreen(services: services)
        case .contraceptiveContext: ContraceptiveContextScreen(services: services)
        }
    }
}

// MARK: - Loaded data

private struct CycleHomeData {
    var status: CycleHomeStatus
    var mostRecentLiveRecord: CycleRecord?
    var prediction: CyclePrediction?
    /// A17/ADR-0010/D-24 (EPIC-39 CYCLE-12) — only ever non-nil when `env.profile.fertileWindowMode
    /// != .suppressed` AND the estimate itself carries a real, active window (see `load()`'s own
    /// gate below); this screen deliberately shows nothing for the "not enough history yet" /
    /// "suppressed by contraceptive context" in-between states — those calmer caveats belong on the
    /// fuller `CycleHistoryScreen`, not this compact summary, per §7's "optional overlay, not forced
    /// narrative" rule.
    var fertileWindowEstimate: CycleFertileWindowEstimate?
    var anomalies: [CycleAnomalyEvent]
}

// MARK: - Screen

/// The cycle module's main screen, reached from `LogHubScreen` once `cycleModuleEnabled` is on
/// (already wired there by that lane). Calm status card, a range-only next-cycle summary, live
/// anomaly cards, and the ≤3-interaction repeat-case quick actions (start/end/log-flow) that route
/// into `PeriodLogScreen`.
struct CycleHomeScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var services: CycleModuleServices?
    @State private var state: LoadState<CycleHomeData> = .loading
    @State private var route: CycleRoute?
    @State private var periodLogMode: PeriodLogScreen.Mode?

    /// Mirrors `CycleHistoryScreen`'s own private `LoadKey` shape exactly (same slice, same
    /// reactivity convention) — nested here, so it is `CycleHomeScreen.LoadKey`, distinct from that
    /// screen's own nested type of the same short name.
    private struct LoadKey: Equatable {
        let profile: CustomizationProfile
        let generation: Int
    }

    var body: some View {
        ScrollView {
            StatefulContainer(state, emptyIcon: "calendar", errorIcon: "exclamationmark.triangle") { data in
                content(data)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(MetricFamily.cycle.displayName))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { route = .consent } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(env.s(CycleHomeStrings.settingsAction))
            }
            ToolbarItem(placement: .primaryAction) {
                Button { route = .export } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(env.s(CycleExportStrings.title))
            }
            // AUDIT FIX (Integrate phase): the real entry point for `.contraceptiveContext` — see
            // `CycleRoute`'s own doc comment above for why this exists. Reuses
            // `ContraceptiveContextStrings.title` (`ContraceptiveContextScreen.swift`, same module)
            // for the accessibility label rather than a second, possibly-drifting string, mirroring
            // how the export button above reuses `CycleExportStrings.title`.
            ToolbarItem(placement: .primaryAction) {
                Button { route = .contraceptiveContext } label: {
                    Image(systemName: "pills")
                }
                .accessibilityLabel(env.s(ContraceptiveContextStrings.title))
            }
        }
        .navigationDestination(item: $route) { destination in
            if let services { destination.makeView(services: services) }
        }
        .sheet(item: $periodLogMode) { mode in
            if let services { PeriodLogScreen(services: services, mode: mode) }
        }
        // Services are constructed once (guarded), then EVERY (re)load — first appearance, a
        // language/depth/profile change, or `env.dataGeneration` bumping from a write this screen's
        // own action performed (the anomaly dismiss below) OR a write `PeriodLogScreen` performed on
        // the SAME shared `env` instance while presented as a sheet on top of this screen — goes
        // through this one `.task(id:)`, matching `CycleHistoryScreen`'s own reactivity convention.
        .task(id: LoadKey(profile: env.profile, generation: env.dataGeneration)) {
            if services == nil { services = CycleModuleServices(env: env) }
            load()
        }
    }

    @ViewBuilder
    private func content(_ data: CycleHomeData) -> some View {
        switch data.status {
        case .noRecordsYet:
            EmptyStateView(
                icon: "calendar.badge.plus",
                title: env.s(CycleHomeStrings.coldStartTitle),
                message: env.s(CycleHomeStrings.coldStartMessage),
                actionTitle: env.s(CycleHomeStrings.startCycleAction),
                action: { periodLogMode = .start })
        case .tracking:
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                statusCard(data)
                quickActionsRow(data)
                predictionSection(data)
                fertileWindowSection(data)
                anomalySection(data)
            }
        }
    }

    // MARK: Load

    private func load() {
        guard let services else { return }
        do {
            let liveRecords = try services.cycleRecords.liveRecords()
            let prediction = try services.predictions.latestPrediction()
            // A17/ADR-0010/D-24 (EPIC-39 CYCLE-12): gated the same way `CycleHistoryScreen.load()`
            // gates its own read — while the user-declared mode default (`.suppressed`) holds, this
            // screen never even queries the estimate table, let alone renders a section for it.
            let fertileWindowEstimate: CycleFertileWindowEstimate? = env.profile.fertileWindowMode == .suppressed
                ? nil
                : try services.fertileWindowEstimates.latestEstimate().flatMap {
                    CycleFertileWindowPresentation.hasWindow($0) ? $0 : nil
                }
            let anomalyEvents = try services.anomalies.liveEvents()
            let status = CycleStatusResolver.resolve(liveRecords: liveRecords, asOf: env.now(),
                                                      tz: TimeZone.current.identifier)
            let mostRecent = liveRecords.max(by: { $0.startAt < $1.startAt })
            state = .loaded(CycleHomeData(status: status, mostRecentLiveRecord: mostRecent,
                                          prediction: prediction, fertileWindowEstimate: fertileWindowEstimate,
                                          anomalies: anomalyEvents))
        } catch {
            LoadErrorLog.log(error, screen: "CycleHomeScreen")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Status card

    private func statusCard(_ data: CycleHomeData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                if case .tracking(let dayNumber, let ongoing) = data.status {
                    Text(env.s(CycleHomeStrings.dayLabel.filling(["n": env.format.integer(dayNumber)])))
                        .font(BadanFont.heroNumeral)
                        .foregroundStyle(BadanColor.textPrimary)
                    if ongoing {
                        Text(env.s(CycleHomeStrings.ongoingSubtitle))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: Quick actions (≤3-interaction repeat case)

    /// "Start cycle" when no cycle is currently ongoing, "End cycle" when one is — mutually
    /// exclusive, never both — plus "Log flow" whenever there is a most-recent live cycle to attach
    /// a flow entry to (whether or not it is still ongoing, since a user may log/correct flow shortly
    /// after a cycle ends too). Each opens `PeriodLogScreen` as a sheet pre-filled to "now"; from
    /// there a bare Save is 2 taps total for the repeat case, well inside the ≤3-interaction budget.
    private func quickActionsRow(_ data: CycleHomeData) -> some View {
        HStack(spacing: BadanSpace.space3) {
            if case .tracking(_, let ongoing) = data.status, let mostRecent = data.mostRecentLiveRecord {
                if ongoing {
                    Button { periodLogMode = .end(mostRecent) } label: {
                        QuickActionTile(title: env.s(CycleHomeStrings.endCycleAction), systemImage: "stop.circle")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { periodLogMode = .start } label: {
                        QuickActionTile(title: env.s(CycleHomeStrings.startCycleAction), systemImage: "play.circle")
                    }
                    .buttonStyle(.plain)
                }
                Button { periodLogMode = .logFlow(cycle: mostRecent) } label: {
                    QuickActionTile(title: env.s(CycleHomeStrings.logFlowAction), systemImage: "drop")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Prediction summary — tapping navigates to CycleHistoryScreen (another lane's screen)

    private func predictionSection(_ data: CycleHomeData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(CycleHomeStrings.predictionSectionTitle))
            Button { route = .history } label: {
                BadanCard {
                    HStack(alignment: .top, spacing: BadanSpace.space3) {
                        VStack(alignment: .leading, spacing: BadanSpace.space2) {
                            predictionBody(data.prediction)
                        }
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .font(BadanFont.caption.weight(.semibold))
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// A RANGE + confidence descriptor + method label — NEVER a bare date. Reuses
    /// `CyclePredictionPresentation` (`CycleHistoryScreen.swift`, this slice's already-landed history
    /// lane) for the gating/confidence-sentence/recent-cycle-count logic, so this screen's compact
    /// summary can never say something different from that screen's own full detail for the exact
    /// same forecast — only the RANGE line's own phrasing is this screen's own (a shorter, confidence-
    /// adaptive sentence per this lane's brief: "likely between..." at low confidence, "expected
    /// around..." otherwise), which `CyclePredictionPresentation` has no equivalent for (its own
    /// history-detail screen always shows the full range unconditionally, a deliberately different,
    /// more spelled-out treatment appropriate to a detail screen rather than a summary card).
    @ViewBuilder
    private func predictionBody(_ prediction: CyclePrediction?) -> some View {
        if let prediction {
            if CyclePredictionPresentation.hasRange(prediction),
               let low = prediction.predictedNextStartLow,
               let center = prediction.predictedNextStartCenter,
               let high = prediction.predictedNextStartHigh {
                let rangeLine: LocalizedString = prediction.method == .lowHistory
                    ? CycleHomeStrings.likelyBetween.filling(["low": dateText(low), "high": dateText(high)])
                    : CycleHomeStrings.expectedAround.filling(
                        ["center": dateText(center), "low": dateText(low), "high": dateText(high)])
                Text(env.s(rangeLine))
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: false, vertical: true)
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
        } else {
            // No prediction has ever been generated yet (e.g. the module was just enabled and
            // `refreshAll` hasn't run once) — the same honest "nothing to estimate from yet" copy
            // `CyclePredictionPresentation.confidenceDescriptor` already gives a fresh `coldStart`
            // forecast, reused here rather than a second, possibly-drifting string.
            Text(env.s(CycleHistoryStrings.noEstimateYet))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Fertile-window summary (A17/ADR-0010/D-24, EPIC-39 CYCLE-12) — tapping navigates to
    // CycleHistoryScreen, same as the prediction card above, where the full range/caveat/"why this
    // estimate?" detail lives. Renders ONLY when `data.fertileWindowEstimate` is non-nil (see that
    // field's own doc) — never a forced, always-present section, per §7's "optional overlay chips...
    // not forced narrative" rule.
    @ViewBuilder
    private func fertileWindowSection(_ data: CycleHomeData) -> some View {
        if let estimate = data.fertileWindowEstimate, let start = estimate.windowStart, let end = estimate.windowEnd {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(CycleHistoryStrings.fertileWindowSectionTitle))
                Button { route = .history } label: {
                    BadanCard {
                        HStack(alignment: .top, spacing: BadanSpace.space3) {
                            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                                Text(env.s(CycleHistoryStrings.fertileWindowRange.filling(
                                    ["low": dateText(start), "high": dateText(end)])))
                                    .font(BadanFont.body.weight(.medium))
                                    .foregroundStyle(BadanColor.textPrimary)
                                    .environment(\.layoutDirection, .leftToRight)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(env.s(CycleHistoryStrings.fertileWindowNotContraception))
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: BadanSpace.space2)
                            Image(systemName: "chevron.forward")
                                .font(BadanFont.caption.weight(.semibold))
                                .foregroundStyle(BadanColor.textSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Anomaly cards

    @ViewBuilder
    private func anomalySection(_ data: CycleHomeData) -> some View {
        let renderable = CycleHomeAnomalyPresentation.renderable(data.anomalies)
        if !renderable.isEmpty {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(CycleHomeStrings.anomaliesSectionTitle))
                ForEach(renderable, id: \.event.id) { item in
                    anomalyCard(item.event, message: item.message)
                }
            }
        }
    }

    /// Verbatim `CycleAnomalyMessages` copy only — never invented text. `BadanColor.outOfBand` (muted
    /// amber) regardless of `severity` — severity is a surfacing priority only, never rendered as a
    /// verdict word or a color escalation.
    private func anomalyCard(_ event: CycleAnomalyEvent, message: LocalizedString) -> some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(BadanColor.outOfBand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    Text(env.s(message))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(env.s(CycleHomeStrings.dismissAction)) { dismissAnomaly(event) }
                        .font(BadanFont.caption.weight(.medium))
                        .foregroundStyle(BadanColor.primary)
                        .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
                }
            }
        }
    }

    /// Only a lifecycle transition (`anomalies.updateState`) — deliberately does NOT call
    /// `CycleModuleServices.refreshAll`, unlike every write in `PeriodLogScreen`: that method's own
    /// doc scopes its trigger to "logging a period/flow/contraceptive-context change", and dismissing
    /// an anomaly is none of those. Calling it here would re-run `CycleAnomalyEngine.detectAnomalies`
    /// against the SAME still-true underlying condition and immediately re-append a fresh `.active`
    /// event of the same type (the dedup rule only blocks a repeat while the prior one isn't
    /// `.dismissed`) — defeating the point of "dismiss" the instant it was tapped. `bumpDataGeneration`
    /// still fires (a real persisted state change other surfaces, e.g. `CycleHistoryScreen`'s own
    /// anomaly-history list, should see reflected), and this screen reloads its own state directly
    /// rather than waiting on that signal to loop back through `.task(id:)`.
    private func dismissAnomaly(_ event: CycleAnomalyEvent) {
        guard let services else { return }
        do {
            try services.anomalies.updateState(id: event.id, state: .dismissed, at: env.now())
            env.bumpDataGeneration()
            load()
        } catch {
            Announce.failure(env.s(CycleHomeStrings.dismissFailed))
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

// MARK: - Small shared subview

private struct QuickActionTile: View {
    let title: String
    let systemImage: String

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        }
    }
}
