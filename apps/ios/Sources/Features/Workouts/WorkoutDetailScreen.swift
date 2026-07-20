import SwiftUI

// MARK: - Model

/// Everything one ingested workout's detail screen renders. Assembled once, off the main actor.
struct WorkoutDetailData {
    let session: Session
    let workout: WorkoutDetail?
    /// The canonical heart-rate series covering this workout's window, read from `raw_samples`.
    /// NOT a copy stored on the workout — plan §9.1 is explicit that HR linkage resolves from
    /// the canonical store, and `WorkoutDetail.hrSeriesRef` names the metric rather than
    /// duplicating a few thousand samples per session.
    let heartRate: [MetricChart.Point]
    /// Time-in-band, when the trace supports it — see `WorkoutEffortBands`.
    let effort: WorkoutEffortBands.Result?
    let route: WorkoutRoute?
    let routePoints: [RoutePoint]
    /// Display name of the source that recorded this, for the provenance row.
    let sourceName: String?
    /// Manual entries this workout currently suppresses (I3 lineage).
    let suppressedChildren: [UnifiedWorkoutList.Child]
}

/// The thread-safe slice of `AppEnvironment` the fetch needs, mirroring `BodyFetchInputs` /
/// `SourcesFetchInputs` — value types and repository references only, no main-actor state.
struct WorkoutDetailFetchInputs {
    var sessionId: String
    var measurements: MeasurementRepository
    var derivation: DerivationRepository
    var logging: LoggingRepository
    var reconciliation: ReconciliationRepository
    var catalog: CatalogRepository
    var routes: RouteRepository
    /// Live route consent. Read here rather than assumed from the presence of a `routeRef`:
    /// a trace ingested while consent was on must stop being displayed the moment it is turned
    /// off, without waiting for a purge. The rows stay (I3/§9.2 — they keep their own
    /// `consent_snapshot`); what changes is that BADAN stops showing them.
    var routeConsentGranted: Bool
}

@Observable
@MainActor
final class WorkoutDetailViewModel {
    var state: LoadState<WorkoutDetailData> = .loading

    private static let notFound = LocalizedString(
        en: "This workout is no longer in your record.",
        ar: "لم يعد هذا التمرين موجوداً في سجلّك.")

    func load(_ env: AppEnvironment, sessionId: String) async {
        let inputs = WorkoutDetailFetchInputs(
            sessionId: sessionId, measurements: env.measurements, derivation: env.derivation,
            logging: env.logging, reconciliation: env.reconciliation, catalog: env.catalog,
            routes: env.routes, routeConsentGranted: RouteConsentStore.current.granted)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let data?):
            state = .loaded(data)
        case .success(nil):
            state = .empty(env.s(Self.notFound))
        case .failure(let error):
            LoadErrorLog.log(error, screen: "WorkoutDetail")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Fetch core (nonisolated — runs on a detached task)

    nonisolated static func fetch(_ inputs: WorkoutDetailFetchInputs) -> Result<WorkoutDetailData?, Error> {
        do {
            guard let session = try inputs.measurements.session(id: inputs.sessionId),
                  session.kind == .workout else {
                return .success(nil)
            }
            let workout = session.detail.workout

            // Heart rate across the workout window. `rawSamples` filters suppressed rows by
            // default, which is what this chart wants: a duplicate reading from a second source
            // would draw a second line's worth of noise over the same minutes.
            let samples = try inputs.measurements.rawSamples(
                metricId: MetricID.heartRate, from: session.startAt, to: session.endAt)
            let points = samples
                .map { MetricChart.Point(date: $0.startAt, value: $0.value) }
                .sorted { $0.date < $1.date }

            // The person's own resting baseline anchors the effort bands. A provisional baseline
            // is used as-is: it is still their own recorded floor, and the bands are explicitly
            // presented as the shape of this session rather than as a settled measure.
            let restingBaseline = try inputs.derivation.latestBaseline(metricId: MetricID.restingHeartRate)
            let effort = WorkoutEffortBands.compute(
                samples: points.map { (date: $0.date, value: $0.value) },
                restingBpm: restingBaseline?.center, end: session.endAt)

            var route: WorkoutRoute?
            var routePoints: [RoutePoint] = []
            if inputs.routeConsentGranted, let routeRef = workout?.routeRef,
               let stored = try inputs.routes.route(id: routeRef), stored.deletedAt == nil {
                route = stored
                routePoints = try inputs.routes.points(routeId: stored.id)
            }

            let sourceName = try inputs.catalog.source(id: session.provenance.sourceId)?.displayName

            // Manual entries this session suppressed. Scoped to the workout's own window (padded
            // like `IngestionPipeline.dedupWorkouts` pads its lookup) rather than scanning the
            // whole table, then filtered to decisions that actually name THIS session.
            let padding: TimeInterval = 86_400
            let manual = try inputs.logging.workouts(from: session.startAt.addingTimeInterval(-padding),
                                                     to: session.endAt.addingTimeInterval(padding))
            var children: [UnifiedWorkoutList.Child] = []
            for entry in manual where entry.deletedAt == nil {
                guard let decision = try inputs.reconciliation.forSuppressed(entry.id),
                      decision.keptRecordId == session.id, decision.reversedAt == nil else { continue }
                children.append(UnifiedWorkoutList.Child(
                    entry: entry, lineage: UnifiedWorkoutList.Lineage(decision: decision)))
            }

            return .success(WorkoutDetailData(
                session: session, workout: workout, heartRate: points, effort: effort,
                route: route, routePoints: routePoints, sourceName: sourceName,
                suppressedChildren: children.sorted { $0.entry.startAt > $1.entry.startAt }))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Screen

/// One ingested workout in full (EPIC-03 task 5): what the source recorded, the heart-rate trace
/// across it, how the effort was distributed, its route if you've allowed routes, and — because
/// I3 says a suppressed row is set aside rather than deleted — any hand-typed entry this workout
/// currently stands in for.
///
/// Reached from the unified list in `WorkoutLogView`. Manual entries do not open this screen:
/// they carry none of what it renders (no HR trace, no route, no source), and a detail screen
/// that is mostly empty states is worse than the list row the user already read.
struct WorkoutDetailScreen: View {
    @Environment(AppEnvironment.self) private var env
    let sessionId: String

    @State private var vm = WorkoutDetailViewModel()
    @State private var showsRouteConsent = false

    private static let heartRateHeader = LocalizedString(en: "Heart rate", ar: "معدل ضربات القلب")
    private static let effortHeader = LocalizedString(en: "How the effort was spread", ar: "كيف توزّع الجهد")
    private static let effortExplainer = LocalizedString(
        en: "Bands are worked out from your own resting heart rate and the highest rate in this workout. They show the shape of this session — they aren't training zones, and they don't compare to anyone else.",
        ar: "تُحسب النطاقات من معدل قلبك أثناء الراحة ومن أعلى معدل في هذا التمرين. وهي تُظهر شكل هذه الجلسة — ليست نطاقات تدريب، ولا تقارنك بأحد.")
    private static let noHeartRate = LocalizedString(
        en: "No heart rate was recorded during this workout.",
        ar: "لم يُسجَّل معدل ضربات القلب خلال هذا التمرين.")
    private static let routeOffTitle = LocalizedString(en: "Routes are off", ar: "المسارات متوقّفة")
    private static let routeOffBody = LocalizedString(
        en: "Routes are location data, so they have their own switch. Turn it on and BADAN can show the path your device already saved with outdoor workouts.",
        ar: "المسارات بيانات موقع، لذا لها مفتاحها الخاص. فعّله ليتمكّن بدن من عرض المسار الذي حفظه جهازك مع التمارين الخارجية.")
    private static let routeSettings = LocalizedString(en: "Route settings", ar: "إعدادات المسار")
    private static let energyLabel = LocalizedString(en: "Energy", ar: "الطاقة")
    private static let distanceLabel = LocalizedString(en: "Distance", ar: "المسافة")
    private static let avgHrLabel = LocalizedString(en: "Average heart rate", ar: "متوسط معدل القلب")
    private static let maxHrLabel = LocalizedString(en: "Highest heart rate", ar: "أعلى معدل للقلب")
    private static let elevationLabel = LocalizedString(en: "Elevation gain", ar: "الارتفاع المكتسب")
    private static let kcal = LocalizedString(en: "kcal", ar: "سعرة")
    private static let km = LocalizedString(en: "km", ar: "كم")
    private static let bpm = LocalizedString(en: "bpm", ar: "ن/د")
    private static let meters = LocalizedString(en: "m", ar: "م")
    private static let recordedIds = LocalizedString(en: "Recorded as", ar: "مسجَّل باسم")

    var body: some View {
        StatefulContainer(
            vm.state,
            emptyIcon: "figure.run",
            retryTitle: env.s(LoadErrorCopy.retry),
            onRetry: { Task { await vm.load(env, sessionId: sessionId) } }
        ) { data in
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    summaryCard(data)
                    heartRateSection(data)
                    if let effort = data.effort {
                        effortSection(effort)
                    }
                    routeSection(data)
                    if !data.suppressedChildren.isEmpty {
                        WorkoutSuppressedEntriesCard(children: data.suppressedChildren)
                    }
                    if env.depth.showsPowerDetail {
                        provenanceCard(data)
                    }
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.logWorkout))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsRouteConsent) {
            // `RouteConsentScreen` is normally pushed (from Sources), where the navigation bar
            // supplies Back. Presented as a sheet it has no dismiss affordance of its own, so the
            // Close item is added here rather than inside the screen — the screen shouldn't have
            // to know how it was presented, and a pushed copy with a redundant Close button would
            // be the cost of putting it there.
            NavigationStack {
                RouteConsentScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(env.s(Loc.close)) { showsRouteConsent = false }
                        }
                    }
            }
        }
        // Consent lives in `UserDefaults`, which SwiftUI cannot observe, and the fetch captured
        // it at load time. Without this, a user who turns routes on from the sheet returns to a
        // screen still insisting routes are off — and stays there until the next sync happens to
        // bump `dataGeneration`. Reloading on dismiss re-reads consent and, if a trace was
        // already ingested under an earlier grant, shows it immediately.
        .onChange(of: showsRouteConsent) { _, isPresented in
            if !isPresented { Task { await vm.load(env, sessionId: sessionId) } }
        }
        // Keyed on `dataGeneration` like every other data-backed screen, so a sync that lands
        // while this is open (adding a route, or suppressing a manual twin) redraws instead of
        // showing a stale reading of the same workout.
        .task(id: WorkoutDetailLoadKey(sessionId: sessionId, profile: env.profile,
                                       generation: env.dataGeneration)) {
            await vm.load(env, sessionId: sessionId)
        }
    }

    // MARK: - Summary

    private func summaryCard(_ data: WorkoutDetailData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: WorkoutActivity.symbol(forStored: data.activityType))
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(BadanColor.primary)
                        .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                        .background(BadanColor.primary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.s(WorkoutActivity.label(forStored: data.activityType)))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(WorkoutDateText.string(data.session.startAt, env.language))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    StatBox(value: env.format.duration(seconds: data.session.durationSeconds),
                            label: env.s(Loc.duration), size: .compact)
                }

                let stats = summaryStats(data)
                if !stats.isEmpty {
                    Rectangle().fill(BadanColor.separator).frame(height: 1)
                    // A wrapping grid rather than a fixed HStack: a swim carries two of these and
                    // a ride carries five, and at accessibility text sizes even two won't sit
                    // side by side.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: BadanSpace.space3)],
                              alignment: .leading, spacing: BadanSpace.space3) {
                        ForEach(stats, id: \.label) { stat in
                            StatBox(value: stat.value, label: stat.label, unit: stat.unit, size: .compact)
                        }
                    }
                }
            }
        }
    }

    /// Only totals the source actually reported. `WorkoutTotals` is all-optional on purpose —
    /// "0 kcal" and "not recorded" are different claims and only one of them is true — so an
    /// absent value renders no tile rather than a zero.
    private func summaryStats(_ data: WorkoutDetailData) -> [(label: String, value: String, unit: String?)] {
        guard let totals = data.workout?.totals else { return [] }
        var out: [(label: String, value: String, unit: String?)] = []
        if let energy = totals.energyKcal {
            out.append((env.s(Self.energyLabel), env.format.integer(Int(energy.rounded())), env.s(Self.kcal)))
        }
        if let distance = totals.distanceMeters {
            out.append((env.s(Self.distanceLabel), env.format.number(distance / 1000, fraction: 2), env.s(Self.km)))
        }
        if let avg = totals.avgHeartRateBpm {
            out.append((env.s(Self.avgHrLabel), env.format.integer(Int(avg.rounded())), env.s(Self.bpm)))
        }
        if let max = totals.maxHeartRateBpm {
            out.append((env.s(Self.maxHrLabel), env.format.integer(Int(max.rounded())), env.s(Self.bpm)))
        }
        if let elevation = totals.elevationGainMeters {
            out.append((env.s(Self.elevationLabel), env.format.integer(Int(elevation.rounded())), env.s(Self.meters)))
        }
        return out
    }

    // MARK: - Heart rate

    @ViewBuilder
    private func heartRateSection(_ data: WorkoutDetailData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(Self.heartRateHeader, language: env.language)
                if data.heartRate.isEmpty {
                    Text(env.s(Self.noHeartRate))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                } else {
                    // `MetricChart` already carries the spoken summary and the
                    // `AXChartDescriptor` audio graph (FEAT-237/240) — reusing it rather than
                    // hand-rolling a workout-specific plot is what keeps this screen's chart
                    // accessible on the same terms as every other chart in the app.
                    MetricChart(points: data.heartRate, style: .line, unit: env.s(Self.bpm),
                                language: env.language, arabicDigits: env.profile.arabicDigits)
                        .frame(height: 180)
                }
            }
        }
    }

    // MARK: - Effort bands

    private func effortSection(_ effort: WorkoutEffortBands.Result) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(Self.effortHeader, language: env.language)
                ForEach(effort.bands) { band in
                    effortRow(band, fraction: effort.fraction(of: band.band))
                }
                Text(env.s(Self.effortExplainer))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func effortRow(_ band: WorkoutEffortBands.BandTime, fraction: Double) -> some View {
        // One calm tint at four opacities rather than a red-to-green ramp: the design system
        // reserves hue for band position (`StatusChip`), and colouring "Peak" red would moralize
        // an effort level the app has no business grading.
        let tintOpacity = 0.35 + 0.65 * (Double(WorkoutEffortBands.Band.allCases.firstIndex(of: band.band) ?? 0) / 3.0)
        return HStack(spacing: BadanSpace.space3) {
            Text(env.s(band.band.label))
                .font(BadanFont.chip)
                .foregroundStyle(BadanColor.textSecondary)
                .frame(minWidth: 56, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(BadanColor.surfaceElevated)
                    Capsule()
                        .fill(BadanColor.primary.opacity(tintOpacity))
                        .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 3 : 0))
                }
            }
            .frame(height: 10)
            Text(env.format.duration(seconds: band.seconds, unit: "min"))
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .frame(minHeight: BadanSpace.touchMin)
        // The bar is decorative; the label and duration carry the information. Combine them into
        // one spoken phrase rather than leaving VoiceOver to read a nameless geometry element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(env.s(band.band.label)), \(env.format.duration(seconds: band.seconds, unit: "min"))")
    }

    // MARK: - Route

    @ViewBuilder
    private func routeSection(_ data: WorkoutDetailData) -> some View {
        if let route = data.route, !data.routePoints.isEmpty {
            WorkoutRoutePreview(points: data.routePoints, storedPointCount: route.pointCount)
        } else if data.workout?.routeRef == nil && !RouteConsentStore.current.granted {
            // Deliberately shown only when routes are OFF and none is stored. With routes on and
            // still nothing here, the honest reading is "this workout has no saved route" — and
            // inviting the user to enable a switch that is already enabled would be nonsense.
            routeOffCard
        }
    }

    private var routeOffCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "map")
                        .imageScale(.medium)
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(env.s(Self.routeOffTitle))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(Self.routeOffBody))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    showsRouteConsent = true
                } label: {
                    Text(env.s(Self.routeSettings))
                        .font(BadanFont.link)
                        .foregroundStyle(BadanColor.primary)
                        .frame(minHeight: BadanSpace.touchMin)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Provenance (power)

    private func provenanceCard(_ data: WorkoutDetailData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(Loc.provenance, language: env.language)
                ProvenanceRow(sourceName: data.sourceName ?? data.session.provenance.sourceId,
                              ingestionPath: data.session.provenance.ingestionPath,
                              timestamp: data.session.provenance.measuredAt,
                              language: env.language)
                if let uuid = data.workout?.sourceWorkoutUUID {
                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                        Text(env.s(Self.recordedIds))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        // The platform's own workout id — a technical identifier, so monospaced
                        // and pinned LTR in Arabic, matching how algorithm/rule ids are styled.
                        Text(uuid)
                            .font(BadanFont.caption.monospaced())
                            .foregroundStyle(BadanColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                // `provenance.qualityFlags` is deliberately NOT rendered here. `QualityFlag` has
                // no bilingual label anywhere in the app yet, and inventing eight en+ar strings
                // inside a workout screen would plant the app's quality vocabulary in the one
                // place least likely to be found when the Health Monitor needs it. It belongs on
                // the enum, alongside `IngestionPath.displayLabel`, in a change that can update
                // every provenance surface at once.
            }
        }
    }
}

private extension WorkoutDetailData {
    var activityType: String { workout?.activityType ?? session.subtype ?? "other" }
}

/// Standardized `.task(id:)` identity — see `HomeLoadKey`/`BodyLoadKey`. Carries `sessionId` as
/// well, so navigating from one workout straight to another (via a future "previous workout"
/// link) reloads rather than showing the first one's data under the second one's title.
private struct WorkoutDetailLoadKey: Equatable {
    let sessionId: String
    let profile: CustomizationProfile
    let generation: Int
}

// MARK: - Suppressed-entry lineage (I3)

/// The manual entries an ingested workout currently stands in for.
///
/// This card is the user-visible half of I3. The pipeline never touches the manual row — it
/// journals a reversible `dedup_decisions` entry and moves on — but that guarantee is worth
/// nothing if the only surface a person can see renders the entry as gone. So the entry is shown
/// in full, with the rule that set it aside, how much the two overlapped, and both activity
/// labels (which the rule deliberately does not require to match, so a wrong pairing is visible).
///
/// **No "restore" button, deliberately.** `ReconciliationRepository.markReversed` exists and the
/// decision is `reversible`, but `IngestionPipeline.dedupWorkouts` re-journals any suppression
/// whose previous decision no longer resolves through `forSuppressed` — and `forSuppressed`
/// filters reversed rows out. A restore offered here would therefore be silently undone by the
/// next sync, which is a worse failure than not offering it: the user would believe they had
/// fixed something. Making reversal stick needs the pipeline to consult reversed decisions
/// before re-journaling, which is ingestion-layer work this screen does not own.
private struct WorkoutSuppressedEntriesCard: View {
    @Environment(AppEnvironment.self) private var env
    let children: [UnifiedWorkoutList.Child]

    private static let header = LocalizedString(en: "Your own entry for this", ar: "إدخالك الخاص لهذا")
    private static let explanation = LocalizedString(
        en: "You logged this workout by hand as well. BADAN is showing the recorded version because it carries more detail, and has set yours aside — nothing was deleted, and your entry is still in your record and in every export.",
        ar: "سجّلت هذا التمرين يدوياً أيضاً. ويعرض بدن النسخة المسجَّلة تلقائياً لأنها تحمل تفاصيل أكثر، وقد وضع إدخالك جانباً — لم يُحذف شيء، وإدخالك ما زال في سجلّك وفي كل تصدير.")
    private static let overlap = LocalizedString(en: "{pct}% overlap", ar: "تداخل بنسبة {pct}٪")
    private static let ruleLabel = LocalizedString(en: "Rule", ar: "القاعدة")
    private static let setAside = LocalizedString(en: "Set aside", ar: "موضوع جانباً")
    private static let bothCalled = LocalizedString(
        en: "Recorded as “{kept}”, you called it “{mine}”.",
        ar: "سُجّل باسم «{kept}»، وأنت سمّيته «{mine}».")

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(Self.header, language: env.language)
                Text(env.s(Self.explanation))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(children) { child in
                    childRow(child)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.info.opacity(0.35), lineWidth: 1.5)
        )
    }

    private func childRow(_ child: UnifiedWorkoutList.Child) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Rectangle().fill(BadanColor.separator).frame(height: 1)
            HStack(spacing: BadanSpace.space2) {
                Text(env.s(WorkoutActivity.label(forStored: child.entry.activityType)))
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                PillLabel(env.s(Self.setAside), systemImage: "arrow.down.right.circle",
                          tint: BadanColor.textSecondary, filled: false)
            }
            Text("\(WorkoutDateText.string(child.entry.startAt, env.language)) · \(env.format.duration(seconds: child.entry.durationSeconds, unit: "min"))")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)

            if let percent = child.lineage.overlapPercent {
                Text(env.s(Self.overlap.filling(["pct": env.format.number(percent, fraction: 0)])))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            if let kept = child.lineage.keptActivity, let mine = child.lineage.suppressedActivity,
               kept != mine {
                // Surfaced because `workout.session_overlap.v1` pairs on time overlap alone and
                // never compares activity labels — so when the two disagree, the user is the only
                // one who can tell whether the pairing was right.
                Text(env.s(Self.bothCalled.filling(["kept": kept, "mine": mine])))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if env.depth.showsPowerDetail {
                HStack(spacing: BadanSpace.space2) {
                    Text(env.s(Self.ruleLabel))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Spacer(minLength: BadanSpace.space2)
                    Text("\(child.lineage.rule)@\(child.lineage.ruleVersion)")
                        .font(BadanFont.caption.monospaced())
                        .foregroundStyle(BadanColor.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                LText(Loc.reversible)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }
}

/// Date formatting shared by the workout surfaces. One cached formatter per language rather than
/// a fresh `DateFormatter` per row (PERF-033's finding, applied here from the start).
enum WorkoutDateText {
    private static let enFormatter: DateFormatter = make(.en)
    private static let arFormatter: DateFormatter = make(.ar)

    private static func make(_ language: AppLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    static func string(_ date: Date, _ language: AppLanguage) -> String {
        (language == .en ? enFormatter : arFormatter).string(from: date)
    }
}
