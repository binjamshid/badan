import SwiftUI

// MARK: - Pure formatting (tested directly — see WorkoutUITests)

/// Stopwatch-style elapsed-time rendering, shared by `LiveWorkoutScreen`'s hero timer,
/// `WorkoutHomeScreen`'s recoverable-draft/in-progress cards, and `StrengthLoggingScreen`'s rest
/// timer — one place decides what "1:04:12" looks like so the three screens can never drift.
enum WorkoutTimeFormat {
    private static let arabicIndicDigits = Array("٠١٢٣٤٥٦٧٨٩")

    /// "H:MM:SS" once past an hour, "M:SS" under it. Hand-built rather than routed through
    /// `Numerals.format` because a stopwatch needs zero-padded components (`NumberFormatter` has
    /// no simple "05" mode) — the trailing Arabic-Indic swap below mirrors
    /// `GoalsSettingsScreen`'s own precedent for exactly that gap.
    static func string(seconds: Double, language: AppLanguage, arabicDigits: Bool) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let latin = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        guard language == .ar, arabicDigits else { return latin }
        return String(latin.map { ch in
            ch.wholeNumberValue.flatMap { $0 >= 0 && $0 <= 9 ? arabicIndicDigits[$0] : nil } ?? ch
        })
    }
}

/// The heart-rate tile's text, or `nil` when it must not render at all.
///
/// `nil` in, `nil` out, ALWAYS — this is the one rule the plan states in the most words: "HR tile
/// omitted, never zeros, on phone-only Apple sessions". A fabricated "0" or a placeholder "--"
/// would read as a real (if low/missing) reading; omitting the tile is the only honest rendering
/// of "nothing was read this window."
enum HeartRateTileFormat {
    static func valueText(bpm: Double?, language: AppLanguage, arabicDigits: Bool) -> String? {
        guard let bpm, bpm.isFinite, bpm > 0 else { return nil }
        return Numerals.format(bpm.rounded(), language: language, arabicDigits: arabicDigits)
    }
}

/// The degraded-condition banner's lines, in a fixed, deterministic order (`WorkoutDegradedCondition.
/// allCases`, not a `Set`'s unordered iteration) so the banner never reshuffles line order between
/// renders of the same underlying set.
enum DegradedBannerFormat {
    static func lines(for conditions: Set<WorkoutDegradedCondition>) -> [LocalizedString] {
        WorkoutDegradedCondition.allCases.filter { conditions.contains($0) }.map(\.displayLabel)
    }
}

/// FIX 1 — the VoiceOver announcement to speak once `requestPause()` lands. Reads the coordinator's
/// ACTUAL resulting `lifecycleState` rather than assuming which pause variant it landed in.
/// `WorkoutSessionCoordinator.requestPause()` always fires `.userPaused`, which
/// `WorkoutStateMachine.nextState` always resolves to `.manuallyPaused` — never `.autoPaused`
/// (unreachable in this slice: nothing ever fires `.autoPauseDetected`) — so hardcoding
/// `.autoPaused`'s label here would announce a state the user never actually entered.
enum PauseResumeAnnouncement {
    static func text(resultingState: WorkoutLifecycleState, language: AppLanguage) -> String {
        resultingState.displayLabel.resolved(language)
    }
}

/// FIX 4 — the `.preparing` countdown length (plan §7A.5: "countdown default 3s"), the real
/// elapsed interval `WorkoutSessionCoordinator.start(activityType:)` now leaves the machine sitting
/// in `.preparing` for, before `confirmCountdownFinished()` moves it to `.active`.
enum WorkoutCountdown {
    static let defaultSeconds: TimeInterval = 3
}

/// FIX 4 — drives the `.preparing` countdown for a live/strength session: waits
/// `WorkoutCountdown.defaultSeconds`, then calls `confirmCountdownFinished()` — the event that
/// moves `.preparing` -> `.active` and starts the adapter (see that method's own doc). Both
/// `LiveWorkoutScreen` and `StrengthLoggingScreen` drive this from a
/// `.task(id: coordinator.lifecycleState)` modifier, which SwiftUI cancels automatically the moment
/// `lifecycleState` changes away from `.preparing` (e.g. the user tapped Cancel, which calls
/// `coordinator.discard()`) — a cancelled countdown must never fire a stale confirm against a
/// session that has already moved on or been discarded.
@MainActor
func runPreparingCountdown(coordinator: WorkoutSessionCoordinator) async {
    guard coordinator.lifecycleState == .preparing else { return }
    do {
        try await Task.sleep(nanoseconds: UInt64(WorkoutCountdown.defaultSeconds * 1_000_000_000))
    } catch {
        return   // cancelled — the state already moved on before the countdown elapsed
    }
    guard coordinator.lifecycleState == .preparing else { return }
    try? coordinator.confirmCountdownFinished()
}

// MARK: - Screen-local strings

private enum LiveWorkoutStrings {
    static let elapsedLabel = LocalizedString(en: "Time", ar: "الوقت")
    static let heartRateLabel = LocalizedString(en: "Heart rate", ar: "معدل ضربات القلب")
    static let bpm = LocalizedString(en: "bpm", ar: "ن/د")

    static let pause = LocalizedString(en: "Pause", ar: "إيقاف مؤقت")
    static let resumeAction = LocalizedString(en: "Resume", ar: "استئناف")
    static let endWorkout = LocalizedString(en: "End workout", ar: "إنهاء التمرين")
    static let cancel = LocalizedString(en: "Cancel", ar: "إلغاء")

    static let stopConfirmTitle = LocalizedString(en: "End this workout?", ar: "إنهاء هذا التمرين؟")
    static let stopConfirmMessage = LocalizedString(
        en: "This saves what you've recorded so far and can't be resumed afterward.",
        ar: "سيُحفظ ما سُجِّل حتى الآن، ولا يمكن استئناف التمرين بعد ذلك.")
    static let stopConfirmAction = LocalizedString(en: "End & save", ar: "إنهاء وحفظ")

    static let actionFailed = LocalizedString(en: "Couldn't do that. Try again.", ar: "تعذّر تنفيذ ذلك. حاول مرة أخرى.")
    static let finalizeFailed = LocalizedString(
        en: "Couldn't save your workout. Try ending it again.", ar: "تعذّر حفظ تمرينك. حاول إنهاءه مرة أخرى.")
    static let retry = LocalizedString(en: "Retry", ar: "إعادة المحاولة")

    static let genericActivity = LocalizedString(en: "Workout", ar: "تمرين")

    static func statusLine(_ state: WorkoutLifecycleState) -> LocalizedString? {
        switch state {
        case .preparing, .interrupted, .stopping, .finalizing:
            return state.displayLabel
        default:
            return nil
        }
    }
}

// MARK: - Screen

/// EPIC-42 slice 2 — the default live-tracking screen: elapsed time, an optional heart-rate tile,
/// a degraded-condition banner, and pause/resume/stop, wired to the frozen
/// `WorkoutSessionCoordinator` contract's action methods.
///
/// **Foreground-only, on purpose (task scope).** BADAN drives this entirely with its own
/// timer/state loop — never `HKWorkoutSession`/`HKLiveWorkoutBuilder` (standalone-iPhone support
/// for those arrived only in iOS 26; this app targets iOS 17 and has no watch companion target
/// yet). `Info.plist`'s `UIBackgroundModes` is `[fetch, processing]` only, so a session pauses or
/// ends if the app is backgrounded long enough to be suspended — an honest limitation of this
/// slice, not a bug, and nothing here claims otherwise.
///
/// **No location, ever, in this screen.** Only duration and (best-effort, read-only) heart rate
/// are tracked — see `WorkoutHomeScreen`'s coordinator-factory doc for why a route is structurally
/// unreachable through the health store this screen's coordinator was built with.
struct LiveWorkoutScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let coordinator: WorkoutSessionCoordinator
    /// Pops the ENTIRE workout flow back to the Log tab — captured once at `WorkoutHomeScreen`
    /// and threaded through every screen this flow can push, so "Done" on the post-workout summary
    /// lands in the same place regardless of how many screens sit between it and Home.
    let returnToLog: () -> Void

    @State private var showStopConfirm = false
    @State private var isFinalizing = false
    @State private var actionErrorText: LocalizedString?
    @State private var summary: WorkoutSessionSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if let statusLine = LiveWorkoutStrings.statusLine(coordinator.lifecycleState) {
                    statusBanner(statusLine)
                }
                statsRow
                // EPIC-42: only present for a structured session. `intervalPosition` goes nil once
                // the plan runs past its end, which is not the end of the workout — hence the
                // explicit "plan finished, still recording" line rather than the card vanishing
                // with no explanation.
                if let plan = coordinator.intervalPlan {
                    if let position = coordinator.intervalPosition {
                        IntervalLiveCard(position: position, plan: plan)
                    } else {
                        LText(IntervalStrings.planFinished)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                degradedBanner
                controls
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
        .confirmationDialog(env.s(LiveWorkoutStrings.stopConfirmTitle), isPresented: $showStopConfirm,
                            titleVisibility: .visible) {
            Button(env.s(LiveWorkoutStrings.stopConfirmAction), role: .destructive) {
                Task { await finalizeWorkout() }
            }
            Button(env.s(Loc.cancel), role: .cancel) {}
        } message: {
            Text(env.s(LiveWorkoutStrings.stopConfirmMessage))
        }
        .navigationDestination(item: $summary) { finished in
            PostWorkoutSummaryScreen(summary: finished, returnToLog: returnToLog)
        }
    }

    private var activityDisplayName: String {
        guard let activityType = coordinator.activityType else { return env.s(LiveWorkoutStrings.genericActivity) }
        return ActivityCatalog.shared.definition(activityType)?.displayName.resolved(env.language) ?? activityType
    }

    private func statusBanner(_ label: LocalizedString) -> some View {
        HStack(spacing: BadanSpace.space2) {
            if coordinator.lifecycleState == .stopping || coordinator.lifecycleState == .finalizing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(env.s(label))
                .font(BadanFont.body.weight(.medium))
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    private var statsRow: some View {
        let hrText = HeartRateTileFormat.valueText(bpm: coordinator.liveHeartRateBpm,
                                                   language: env.language, arabicDigits: env.profile.arabicDigits)
        return HStack(alignment: .top, spacing: BadanSpace.space5) {
            StatBox(value: WorkoutTimeFormat.string(seconds: coordinator.elapsedActiveSeconds,
                                                    language: env.language, arabicDigits: env.profile.arabicDigits),
                   label: env.s(LiveWorkoutStrings.elapsedLabel))
            // Omitted entirely when nil — never a "0"/"--" placeholder (see `HeartRateTileFormat`).
            if let hrText {
                StatBox(value: hrText, label: env.s(LiveWorkoutStrings.heartRateLabel), unit: env.s(LiveWorkoutStrings.bpm))
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

    @ViewBuilder
    private var controls: some View {
        switch coordinator.lifecycleState {
        case .preparing:
            actionButton(LiveWorkoutStrings.cancel, style: .secondary) { cancelPreparing() }
        case .stopping:
            EmptyView()
        case .finalizing:
            // FIX 2/5: a `.finalizing` session with a stored error is a PREVIOUS `finalize()`
            // attempt that threw (now legal to retry, per the relaxed entry guard) — never a dead
            // end with no control, which is what an audit found here before this fix.
            if actionErrorText != nil {
                actionButton(LiveWorkoutStrings.retry, style: .primary) { Task { await finalizeWorkout() } }
                    .disabled(isFinalizing)
            } else {
                EmptyView()
            }
        default:
            VStack(spacing: BadanSpace.space3) {
                if coordinator.lifecycleState.isRecording {
                    actionButton(LiveWorkoutStrings.pause, style: .secondary) { pause() }
                } else if coordinator.lifecycleState.isPaused {
                    actionButton(LiveWorkoutStrings.resumeAction, style: .primary) { resume() }
                }
                // `.stopRequested` is legal from exactly these three states (see
                // `WorkoutStateMachine.nextState`) — never `.idle`/terminal/`.recoveryDraft`, none
                // of which this screen should normally show anyway.
                if coordinator.lifecycleState.isRecording || coordinator.lifecycleState.isPaused
                    || coordinator.lifecycleState == .interrupted {
                    actionButton(LiveWorkoutStrings.endWorkout, style: .destructive) { showStopConfirm = true }
                        .disabled(isFinalizing)
                }
            }
        }
    }

    private enum ButtonStyleKind { case primary, secondary, destructive }

    private func actionButton(_ label: LocalizedString, style: ButtonStyleKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(env.s(label))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(foreground(for: style))
                .frame(maxWidth: .infinity)
                .frame(minHeight: BadanSpace.touchMin)
                .background(background(for: style), in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                .overlay {
                    if style == .secondary {
                        RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                            .strokeBorder(BadanColor.separator, lineWidth: 1)
                    }
                }
        }
    }

    private func foreground(for style: ButtonStyleKind) -> Color {
        switch style {
        case .primary: return BadanColor.onPrimary
        case .secondary: return BadanColor.textPrimary
        case .destructive: return BadanColor.onPrimary
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
        do {
            try coordinator.requestPause()
            Announce.status(PauseResumeAnnouncement.text(resultingState: coordinator.lifecycleState,
                                                          language: env.language))
        } catch {
            actionErrorText = LiveWorkoutStrings.actionFailed
        }
    }

    private func resume() {
        actionErrorText = nil
        do {
            try coordinator.requestResume()
            Announce.status(env.s(WorkoutLifecycleState.active.displayLabel))
        } catch {
            actionErrorText = LiveWorkoutStrings.actionFailed
        }
    }

    private func cancelPreparing() {
        try? coordinator.discard()
        dismiss()
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
            actionErrorText = LiveWorkoutStrings.finalizeFailed
            Announce.failure(env.s(LiveWorkoutStrings.finalizeFailed))
        }
    }
}
