import SwiftUI

// MARK: - Coordinator composition (scoped to this slice's owned-file boundary)

/// Builds a `WorkoutSessionCoordinator` from pieces `AppEnvironment` already exposes
/// (`database.main`, `measurements`, `derivation`, `clock`, `deviceId`, `isHealthKitConnected`).
///
/// This is NOT added to `AppEnvironment` itself. This slice's owned files are exactly the five
/// Workout screens plus one `LogHubScreen` edit and tests (see the task brief); `AppEnvironment.
/// swift` is not one of them, and it is not the parallel engine lane's file either (that lane owns
/// `WorkoutSessionCoordinator.swift`/`LiveWorkoutAdapter.swift`/`Measurements.swift`/`WorkoutSession.
/// swift`). Rather than reach into a file neither lane was told it owns, this factory stays local
/// to the one screen that needs it, constructing the same lightweight repository wrappers every
/// other composition-root property already wraps (`WorkoutCheckpointRepository`,
/// `StrengthSetRepository` — both cheap, stateless wrappers over a `SQLiteConnection`, safe to
/// construct fresh here). A natural follow-up once both lanes land is promoting this into
/// `AppEnvironment` as a real stored property/factory, matching `measurements`/`derivation`/
/// `routes`/`hydration`'s own wiring convention there — flagged here rather than done silently.
///
/// The health store is constructed ONLY when HealthKit is already connected (read-only access the
/// user already granted elsewhere — see `HealthKitAdapter`'s doc), and its route consent is
/// pinned to `DeniedRouteConsent()` explicitly: this slice never reads a route, and an adapter
/// used only for a live-ish heart-rate read should be structurally incapable of returning one,
/// regardless of the user's separate route-consent toggle (task scope §1 — no location/GPS
/// anywhere in this slice).
@MainActor
func makeWorkoutSessionCoordinator(env: AppEnvironment) -> WorkoutSessionCoordinator {
    WorkoutSessionCoordinator(
        checkpointRepository: WorkoutCheckpointRepository(env.database.main),
        strengthSetRepository: StrengthSetRepository(main: env.database.main),
        measurementRepository: env.measurements,
        derivationRepository: env.derivation,
        healthStore: env.isHealthKitConnected
            ? HealthKitAdapter(anchors: ReadAnchorRepository(env.database.main),
                               routeConsent: DeniedRouteConsent())
            : nil,
        deviceId: env.deviceId,
        clock: env.clock,
        // EPIC-42: without this the interval engine still runs the live screen, but its completed
        // segments are never persisted (see the coordinator's own init doc).
        intervalRepository: WorkoutIntervalRepository(main: env.database.main))
}

// MARK: - Quick-start activities

/// The plan's stated MVP quick-start set (research doc §"Start Walk / Run / Strength / Workout").
/// A small, fixed, curated set — distinct from the full `ActivityCatalog` the "more activities"
/// picker offers — so the home screen's first tap is never more than one glance away.
enum QuickStartActivity: String, CaseIterable, Identifiable, Sendable {
    case walk, run, cycle, strength, open

    var id: String { rawValue }

    /// The stable BADAN slug passed to `coordinator.start(activityType:)` — matches
    /// `packages/contracts/dictionaries/activities.json`'s ids verbatim, so a quick-start session
    /// resolves to the same taxonomy entry the full picker would have offered for the same tap.
    var activityId: String {
        switch self {
        case .walk: return "walking"
        case .run: return "running"
        case .cycle: return "cycling"
        case .strength: return "strength_training"
        // "Workout"/"Open" in the research doc — a generic, unclassified session for whatever
        // doesn't fit the four named quick-starts. Maps to the dictionary's own honest fallback
        // (`activities.json`'s `other`) rather than guessing a nearer-but-wrong category.
        case .open: return "other"
        }
    }

    var isStrength: Bool { self == .strength }

    /// FIX 8 — resolved from `ActivityCatalog` (`packages/contracts/dictionaries/activities.json`),
    /// the SAME canonical source `LiveWorkoutScreen.activityDisplayName`/
    /// `PostWorkoutSummaryScreen.activityDisplayName` already read from — never a hardcoded
    /// duplicate. Hardcoding a second EN/AR copy here is exactly what let `.cycle`'s Arabic drift to
    /// "دراجة" ("a bicycle", the object) instead of "ركوب الدراجة" ("cycling", the activity) while
    /// the canonical dictionary said something else; every one of the five entries had drifted from
    /// the dictionary to some degree, not just that one word. Resolving from the one shared source
    /// means the SAME session's activity name can never again visibly differ between this tile and
    /// the live/summary screens. The fallback (raw id) only matters if a quick-start `activityId`
    /// were ever missing from the dictionary — none of the five real ones are.
    var label: LocalizedString {
        ActivityCatalog.shared.definition(activityId)?.displayName ?? LocalizedString(en: activityId, ar: activityId)
    }

    var symbolName: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .strength: return "dumbbell.fill"
        case .open: return "figure.mixed.cardio"
        }
    }
}

// MARK: - Screen-local strings

private enum WorkoutHomeStrings {
    static let title = LocalizedString(en: "Workout", ar: "التمرين")
    static let subtitle = LocalizedString(
        en: "Tracked live, right on your phone. Time and heart rate only — no location, ever, in this version.",
        ar: "يُتتبَّع مباشرة من هاتفك. الوقت ومعدل ضربات القلب فقط — دون أي موقع جغرافي، في هذا الإصدار.")
    static let moreActivities = LocalizedString(en: "More activities", ar: "المزيد من الأنشطة")
    static let startFailed = LocalizedString(
        en: "Couldn't start that workout. Try again.", ar: "تعذّر بدء هذا التمرين. حاول مرة أخرى.")

    static let draftTitle = LocalizedString(en: "Pick up where you left off?", ar: "أتريد المتابعة من حيث توقفت؟")
    // FIX 7: the Arabic sentence is built around a FIXED-GENDER head noun ("جلسة", session, always
    // feminine) rather than the activity name itself, which is of MIXED grammatical gender across
    // `activities.json`'s 29 real entries (السباحة/الملاكمة/كرة السلة/كرة القدم/الفنون القتالية/
    // تمارين المرونة and others are feminine; الجري and others are masculine). The prior copy had no
    // "التي" (relative pronoun) and a hardcoded masculine verb ("لم يُحفظ") — grammatically wrong
    // for every feminine activity. "جلسة {ACTIVITY} التي لم تُحفظ ... حفظها" makes "التي"/"تُحفظ"/
    // "حفظها" agree with "جلسة" (fixed feminine) regardless of the activity's own gender — correct
    // for every entry in the dictionary, not just some — without adding a new gender field to
    // `activities.json`. See `CrashRecoveryBodyText` for the composition and `WorkoutUITests` for
    // the exact-string coverage across activities of different gender.
    static let draftBodyPrefix = LocalizedString(en: "A", ar: "توجد جلسة")
    static let draftBodySuffix = LocalizedString(
        en: "session from earlier wasn't saved — the app closed before it could save.",
        ar: "التي لم تُحفظ من وقت سابق — أُغلق التطبيق قبل حفظها.")
    static let resume = LocalizedString(en: "Resume", ar: "متابعة")
    static let discard = LocalizedString(en: "Discard", ar: "تجاهل")
    static let discardConfirmTitle = LocalizedString(
        en: "Discard this session?", ar: "تجاهل هذه الجلسة؟")
    static let discardConfirmMessage = LocalizedString(
        en: "Nothing from it will be saved. This can't be undone.",
        ar: "لن يُحفظ شيء منها. لا يمكن التراجع عن هذا.")

    static let inProgressTitle = LocalizedString(en: "Workout in progress", ar: "تمرين قيد التنفيذ")
    static let continueAction = LocalizedString(en: "Continue", ar: "متابعة")
}

// MARK: - Screen

/// EPIC-42 slice 2 — the workout OS's entry point. Quick-start tiles for the plan's named MVP set
/// (Walk/Run/Cycle/Strength/Open), a link to the full activity picker, and — ahead of anything
/// else — the crash-recovery prompt `WorkoutStateMachine`'s own doc requires ("ask the user,
/// never silently resume").
///
/// Foreground-only, by design (task scope): this screen's coordinator drives a BADAN-owned
/// timer/state loop, not a platform `HKWorkoutSession` (unsupported standalone on iPhone before
/// iOS 26) and not a backgrounded capture (`Info.plist`'s `UIBackgroundModes` carries no workout
/// mode). A session pauses/ends if the app is suspended long enough — see `LiveWorkoutScreen`'s
/// doc for where that is stated to the user rather than silently hidden.
struct WorkoutHomeScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: WorkoutSessionCoordinator?
    @State private var route: WorkoutFlowRoute?
    @State private var startErrorText: LocalizedString?
    @State private var showDiscardConfirm = false

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: BadanSpace.space3), GridItem(.flexible(), spacing: BadanSpace.space3)]
    }

    var body: some View {
        Group {
            if let coordinator {
                if RecoverableDraftPromptRule.shouldShow(coordinator.recoverableDraft),
                   let draft = coordinator.recoverableDraft {
                    recoverableDraftPrompt(coordinator, draft: draft)
                } else if isSessionInFlight(coordinator.lifecycleState) {
                    inProgressCard(coordinator)
                } else {
                    quickStartContent(coordinator)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(WorkoutHomeStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Built once per screen instance. The coordinator's own init already resolves
            // `recoverableDraft` from `WorkoutCheckpointRepository` (per its doc), so by the time
            // this state is set the crash-recovery check above already has its answer.
            if coordinator == nil { coordinator = makeWorkoutSessionCoordinator(env: env) }
        }
        .navigationDestination(item: $route) { destinationRoute in
            if let coordinator {
                destinationRoute.makeView(coordinator: coordinator, returnToLog: { dismiss() })
            }
        }
    }

    /// A session is "in flight" under THIS coordinator instance (the user backed out of the live
    /// screen without finishing) whenever `start(activityType:)` would throw rather than begin a
    /// fresh one — i.e. whenever a machine exists and isn't terminal (`WorkoutSessionCoordinator.
    /// start`'s own guard). Covers the pause/interruption states as well as the brief
    /// `.stopping`/`.finalizing` window if the user backs out mid-finalize.
    func isSessionInFlight(_ state: WorkoutLifecycleState) -> Bool {
        state == .preparing || state.isRecording || state.isPaused || state == .interrupted
            || state == .stopping || state == .finalizing
    }

    // MARK: - Recoverable draft (WorkoutStateMachine: "ask the user, never silently resume")

    private func recoverableDraftPrompt(_ coordinator: WorkoutSessionCoordinator, draft: WorkoutCheckpoint) -> some View {
        VStack(spacing: BadanSpace.space5) {
            Spacer()
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 40))
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            VStack(spacing: BadanSpace.space2) {
                Text(env.s(WorkoutHomeStrings.draftTitle))
                    .font(BadanFont.sectionTitle)
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(draftBodyText(draft))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, BadanSpace.space5)
            Text(WorkoutTimeFormat.string(seconds: draft.hotState.activeSeconds,
                                          language: env.language, arabicDigits: env.profile.arabicDigits))
                .font(BadanFont.numeralM)
                .foregroundStyle(BadanColor.textPrimary)
            VStack(spacing: BadanSpace.space3) {
                Button {
                    resumeDraft(coordinator)
                } label: {
                    Text(env.s(WorkoutHomeStrings.resume))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.onPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: BadanSpace.touchMin)
                        .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                }
                Button(role: .destructive) {
                    showDiscardConfirm = true
                } label: {
                    Text(env.s(WorkoutHomeStrings.discard))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: BadanSpace.touchMin)
                }
            }
            .padding(.horizontal, BadanSpace.space5)
            Spacer()
        }
        .padding(BadanSpace.space4)
        .confirmationDialog(env.s(WorkoutHomeStrings.discardConfirmTitle), isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button(env.s(WorkoutHomeStrings.discard), role: .destructive) { discardDraft(coordinator) }
            Button(env.s(Loc.cancel), role: .cancel) {}
        } message: {
            Text(env.s(WorkoutHomeStrings.discardConfirmMessage))
        }
    }

    private func draftBodyText(_ draft: WorkoutCheckpoint) -> String {
        CrashRecoveryBodyText.compose(activityId: draft.activityType, language: env.language)
    }

    private func resumeDraft(_ coordinator: WorkoutSessionCoordinator) {
        do {
            try coordinator.resumeFromRecoverableDraft()
            route = WorkoutFlowRoute.destination(forActivityType: coordinator.activityType)
        } catch {
            startErrorText = WorkoutHomeStrings.startFailed
            Announce.failure(env.s(WorkoutHomeStrings.startFailed))
        }
    }

    private func discardDraft(_ coordinator: WorkoutSessionCoordinator) {
        try? coordinator.discardRecoverableDraft()
    }

    // MARK: - In-progress (returned to Home mid-session)

    private func inProgressCard(_ coordinator: WorkoutSessionCoordinator) -> some View {
        VStack(spacing: BadanSpace.space4) {
            Spacer()
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(WorkoutHomeStrings.inProgressTitle))
                    Text(WorkoutTimeFormat.string(seconds: coordinator.elapsedActiveSeconds,
                                                  language: env.language, arabicDigits: env.profile.arabicDigits))
                        .font(BadanFont.heroNumeral)
                        .foregroundStyle(BadanColor.textPrimary)
                    Button {
                        route = WorkoutFlowRoute.destination(forActivityType: coordinator.activityType)
                    } label: {
                        Text(env.s(WorkoutHomeStrings.continueAction))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.onPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BadanSpace.touchMin)
                            .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, BadanSpace.space4)
            Spacer()
        }
    }

    // MARK: - Quick start

    private func quickStartContent(_ coordinator: WorkoutSessionCoordinator) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                Text(env.s(WorkoutHomeStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, spacing: BadanSpace.space3) {
                    ForEach(QuickStartActivity.allCases) { activity in
                        Button {
                            start(activity, coordinator: coordinator)
                        } label: {
                            QuickStartTile(activity: activity)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    route = .picker
                } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(env.s(WorkoutHomeStrings.moreActivities))
                            .font(BadanFont.body.weight(.medium))
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(BadanSpace.space3)
                    .frame(minHeight: BadanSpace.touchMin)
                    .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .strokeBorder(BadanColor.separator, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // EPIC-42. Sits beside "more activities" rather than among the quick-start tiles:
                // those tiles start a session on tap, and this one opens a setup screen first.
                Button {
                    route = .intervalBuilder
                } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "timer")
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(env.s(IntervalStrings.openBuilder))
                            .font(BadanFont.body.weight(.medium))
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(BadanSpace.space3)
                    .frame(minHeight: BadanSpace.touchMin)
                    .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .strokeBorder(BadanColor.separator, lineWidth: 1))
                }
                .buttonStyle(.plain)

                if let startErrorText {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(BadanColor.outOfBand)
                            .accessibilityHidden(true)
                        Text(env.s(startErrorText))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
    }

    private func start(_ activity: QuickStartActivity, coordinator: WorkoutSessionCoordinator) {
        startErrorText = nil
        do {
            try coordinator.start(activityType: activity.activityId)
            route = activity.isStrength ? .strength : .live
        } catch {
            startErrorText = WorkoutHomeStrings.startFailed
            Announce.failure(env.s(WorkoutHomeStrings.startFailed))
        }
    }
}

/// One quick-start tile — icon + bilingual label, matching `LogHubScreen`'s `LogTile` sizing so
/// the workout home screen reads as the same visual family as the rest of the Log tab.
private struct QuickStartTile: View {
    @Environment(AppEnvironment.self) private var env
    let activity: QuickStartActivity

    var body: some View {
        VStack(spacing: BadanSpace.space2) {
            Image(systemName: activity.symbolName)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(env.s(activity.label))
                .font(BadanFont.body.weight(.medium))
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(BadanSpace.space3)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
            .strokeBorder(BadanColor.separator, lineWidth: 1))
    }
}

// MARK: - Pure rule (tested directly — see WorkoutUITests)

/// Whether the crash-recovery prompt should be showing, as a pure predicate over the exact value
/// the frozen `WorkoutSessionCoordinator` contract exposes (`recoverableDraft: WorkoutCheckpoint?`).
/// Kept as its own testable rule rather than inlined so `WorkoutUITests` can assert the
/// appearing/not-appearing behavior without needing a live coordinator instance.
enum RecoverableDraftPromptRule {
    static func shouldShow(_ draft: WorkoutCheckpoint?) -> Bool { draft != nil }
}

// MARK: - Crash-recovery body text (FIX 7, tested directly — see WorkoutUITests)

/// Composes the crash-recovery prompt's full body sentence for a given activity — pulled out as a
/// pure function (rather than left inlined in `draftBodyText`) so `WorkoutUITests` can assert the
/// EXACT bilingual copy without a live coordinator or environment. See `WorkoutHomeStrings.
/// draftBodyPrefix`/`draftBodySuffix`'s own doc for why the Arabic sentence is built around a
/// fixed-gender head noun ("جلسة") rather than per-activity gender agreement.
enum CrashRecoveryBodyText {
    static func compose(activityId: String, language: AppLanguage) -> String {
        let activityName = ActivityCatalog.shared.definition(activityId)?.displayName.resolved(language) ?? activityId
        let prefix = WorkoutHomeStrings.draftBodyPrefix.resolved(language)
        let suffix = WorkoutHomeStrings.draftBodySuffix.resolved(language)
        return "\(prefix) \(activityName) \(suffix)"
    }
}

// MARK: - Flow routing

/// Where a quick-start tap, a picker selection, or a resumed draft goes next. One shared enum so
/// every entry point into the live/strength flow (`WorkoutHomeScreen`, `ActivityPickerScreen`)
/// resolves the "which screen does this activity need" question identically.
enum WorkoutFlowRoute: Hashable, Identifiable {
    case live
    case strength
    case picker
    /// EPIC-42. Reached from the home screen's own entry below, not from an activity tile: a
    /// structured session is a setup step BEFORE an activity starts, so it cannot ride the
    /// activity-to-screen mapping the other cases use.
    case intervalBuilder

    var id: Self { self }

    /// Strength-modality activities (per `ActivityCatalog`'s `category == "strength"`, the same
    /// grouping `activities.json` documents itself as existing for) go to the set-logging screen;
    /// everything else gets the plain live screen.
    static func destination(forActivityType activityType: String?) -> WorkoutFlowRoute {
        ActivityCatalog.shared.isStrength(activityType) ? .strength : .live
    }

    @ViewBuilder
    func makeView(coordinator: WorkoutSessionCoordinator, returnToLog: @escaping () -> Void) -> some View {
        switch self {
        case .live:
            LiveWorkoutScreen(coordinator: coordinator, returnToLog: returnToLog)
        case .strength:
            StrengthLoggingScreen(coordinator: coordinator, returnToLog: returnToLog)
        case .picker:
            ActivityPickerScreen(coordinator: coordinator, returnToLog: returnToLog)
        case .intervalBuilder:
            // `makeView` is nonisolated, so the start hop is marked explicitly rather than
            // relying on inference. `hiit` is the activity slug for a structured session; the plan
            // itself is what makes it structured, and it is fixed for the session's life (see
            // `WorkoutSessionCoordinator.intervalPlan`).
            IntervalPlanBuilderScreen { plan in
                Task { @MainActor in try? coordinator.start(activityType: "hiit", plan: plan) }
            }
        }
    }
}
