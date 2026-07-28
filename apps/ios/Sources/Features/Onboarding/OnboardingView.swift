import SwiftUI

/// The pre-shell welcome flow. The app shell gates the tab UI on `env.onboardingComplete`;
/// this view manages its own full-screen layout (no external NavigationStack) and, on the
/// final step, calls `env.completeOnboarding()` to hand off to the shell.
///
/// Four calm steps over `BadanColor.background`:
///   1. Welcome — with a live EN/AR language toggle so RTL flips immediately.
///   2. A short "why BADAN" value set (your data is yours · works offline) — welcome already
///      covers "private" so the value set doesn't restate it (EASE-110).
///   3. A depth preset choice — "Keep it simple" (.casual) vs "Show me detail" (.power).
///   4. A connect step — a primary connect action, a secondary "Explore with sample data" (the
///      bundled demo dataset, honestly labeled — see `SampleDataBanner`), and a quiet "Start
///      empty" action that purges the demo seed instead. All three complete onboarding.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var step = 0
    @State private var selectedDepth: DepthPolicy?
    /// FEAT-01: local UI state for the real HealthKit connect attempt on `connectPage`. Not
    /// persisted — only `env.isHealthKitConnected`/`env.onboardingComplete` survive past this
    /// screen.
    @State private var connectState: ConnectState = .idle
    /// STUB-01/COMP-06 (ONB "Start empty"): true while the purge kicked off by "Start empty" is
    /// in flight, so a second tap can't race it.
    @State private var startingEmpty = false
    /// (EPIC-01 task 5, plan §13.1) The staged permission bundles onboarding's connect step
    /// covers — core vitals, sleep, activity — each behind its own explainer before its own
    /// system prompt. Body measurements and workouts are deliberately NOT asked for here; the
    /// surfaces that need them ask when they open.
    @State private var permissions = HealthPermissionGate()

    private enum ConnectState: Equatable {
        case idle
        /// The explainer sequence is on screen. Distinct from `.connecting`: nothing has been
        /// written and no backfill exists yet, so the "Continue" escape hatch must not appear —
        /// the user is mid-decision, and offering a way past their own consent flow would be a
        /// dark pattern in the other direction.
        case staging
        case connecting
        /// Authorization was denied or HealthKit is unavailable on this device/simulator — shown
        /// as a calm inline notice rather than navigating away immediately, so the user actually
        /// sees the reassurance before onboarding completes.
        case unavailable
        /// NEW-01: authorization granted; the backfill→derivation the connect path kicked off
        /// (`AppEnvironment.connectHealthKit`) is still running. A "Continue" escape hatch stays
        /// available the whole time — this state never blocks the user.
        case awaitingFirstFact
        /// NEW-01: a real, wellness-safe fact was found (freshest insight, else a baseline
        /// statement) — the trust ladder's first rung.
        case factReady(LocalizedString)
        /// NEW-01: nothing usable within the timeout (fresh account, sparse data, or the
        /// derivation genuinely came up empty). Honest, not fabricated.
        case factUnavailable
    }

    // FEAT-239/FEAT-248: onboarding was the first (and originally only) screen honouring Reduce
    // Motion — every animation on this screen now routes through `BadanMotion`, the shared
    // helper FEAT-239 asked for, which every other animated screen in the app also uses (ledger
    // #36). A vestibular-sensitive user no longer gets a calm first screen and a fully-animated
    // app after it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lastStep = 4
    private var pageCount: Int { lastStep + 1 }

    var body: some View {
        ZStack {
            BadanColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                TabView(selection: $step) {
                    welcomePage.tag(0)
                    valuePage.tag(1)
                    depthPage.tag(2)
                    // Inserted BEFORE connect, not after: the footer shows `Next` only for
                    // `step < lastStep`, so a page placed after connect would have to own its own
                    // Done button and duplicate all six of connect's completion arms. Here it
                    // inherits the shared Next for free, and connect stays the last step.
                    notificationsPage.tag(3)
                    connectPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: step)

                footer
            }
        }
        .onAppear {
            // Reflect any already-chosen depth so returning to the picker shows it selected.
            // No special-casing needed now that DepthPolicy only has casual/power (UX-03) —
            // the profile default (.casual) simply preselects Casual, same as an explicit choice.
            selectedDepth = env.depth
            // ONB-01: a mid-flow relaunch (app killed/backgrounded while onboarding is still in
            // progress) used to always restart at page 0, discarding whatever step the user had
            // already reached. Restore it here; `0` (never persisted, or persisted as 0) is
            // indistinguishable from — and behaves identically to — the existing default.
            let savedStep = UserDefaults.standard.integer(forKey: Self.stepKey)
            if (0...lastStep).contains(savedStep) { step = savedStep }
        }
        .onChange(of: step) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: Self.stepKey)
        }
        .permissionExplainer(permissions)
        // The staged sequence has no completion callback of its own — the gate is a state
        // machine, not a coordinator — so onboarding watches it drain. Guarded on
        // `connectState == .staging` inside `finishStagedConnect`, since `isIdle` is also true
        // before the sequence ever starts.
        .onChange(of: permissions.isIdle) { _, idle in
            if idle { finishStagedConnect() }
        }
    }

    // MARK: - Header (progress + back / skip)

    private var header: some View {
        ZStack {
            progressDots

            HStack {
                if step > 0 {
                    Button {
                        withAnimation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion)) { step -= 1 }
                    } label: {
                        Label(env.s(Loc.back), systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin,
                                   alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                }

                Spacer()

                if step < lastStep {
                    // UIUX-198: Skip exits the whole flow (a more consequential action than
                    // stepping back one page), so it reads a notch quieter than Back rather
                    // than sharing identical visual weight.
                    Button { finishOnboarding() } label: {
                        Text(env.s(Loc.skip))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary.opacity(0.75))
                            .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin,
                                   alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                }
            }
        }
        .padding(.horizontal, BadanSpace.space5)
        .padding(.top, BadanSpace.space2)
    }

    private var progressDots: some View {
        HStack(spacing: BadanSpace.space1) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == step ? BadanColor.primary : BadanColor.separator)
                    .frame(width: index == step ? 22 : 7, height: 7)
            }
        }
        .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: step)
        // EASE-109/OPT-164/UIUX-192: the dots are a purely visual progress cue — rather than
        // hiding progress from VoiceOver entirely, expose an accessible "Step N of total"
        // equivalent so screen-reader users keep the same orientation sighted users get.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(env.s(Self.stepProgressTemplate.filling([
            "current": "\(step + 1)", "total": "\(pageCount)"
        ])))
    }

    // MARK: - Page 1: Welcome + language

    private var welcomePage: some View {
        // UIUX-194: match valuePage/depthPage in offering a scroll escape hatch, so larger
        // Dynamic Type sizes or shorter devices never clip content with no way to reach it.
        // `minHeight` keeps the Spacer-driven centered layout for the common case and only
        // starts scrolling once content actually exceeds the available height.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: BadanSpace.space6) {
                    Spacer(minLength: 0)

                    iconMark("heart.text.square", tint: BadanColor.primary, diameter: Self.heroIconDiameter)

                    VStack(spacing: BadanSpace.space3) {
                        Text(env.s(Loc.welcomeTitle))
                            .font(Self.titleFont)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(Loc.welcomeSubtitle))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    .multilineTextAlignment(.center)

                    VStack(spacing: BadanSpace.space2) {
                        Text(env.s(Loc.language))
                            .font(BadanFont.chip)
                            .foregroundStyle(BadanColor.textSecondary)
                        languageToggle
                        Text(env.s(Self.languageHint))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, BadanSpace.space2)

                    Spacer(minLength: 0)
                }
                .frame(minHeight: proxy.size.height)
                .padding(.horizontal, BadanSpace.space5)
            }
        }
    }

    private var languageToggle: some View {
        HStack(spacing: BadanSpace.space2) {
            ForEach(AppLanguage.allCases) { lang in
                let isSelected = env.language == lang
                Button {
                    withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                        env.update { $0.language = lang }
                    }
                } label: {
                    Text(lang.displayName)
                        .font(BadanFont.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.textSecondary)
                        .background(
                            (isSelected ? BadanColor.primary.opacity(0.14) : BadanColor.surface),
                            in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                                .strokeBorder(isSelected ? BadanColor.primary : BadanColor.separator,
                                              lineWidth: isSelected ? 1.5 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                // UIUX-200: selecting flips the whole app's layout direction (RTL/LTR) — warn
                // VoiceOver users before they trigger that, not just announce the trait.
                .accessibilityHint(env.s(Self.languageToggleHint))
            }
        }
    }

    // MARK: - Page 2: Value set

    private var valuePage: some View {
        ScrollView {
            VStack(spacing: BadanSpace.space4) {
                Text(env.s(Self.whyTitle))
                    .font(Self.titleFont)
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, BadanSpace.space4)

                // EASE-110: welcome already promises "private" (welcomeSubtitle); this page
                // now carries only the two facts welcome doesn't cover, instead of restating
                // privacy a second time.
                VStack(spacing: BadanSpace.space3) {
                    valueCard(icon: "square.and.arrow.up", tint: BadanColor.info,
                              title: Self.valueOwnTitle, body: Self.valueOwnBody)
                    valueCard(icon: "wifi.slash", tint: BadanColor.inBand,
                              title: Self.valueOfflineTitle, body: Self.valueOfflineBody)
                }
            }
            .padding(.horizontal, BadanSpace.space5)
            .padding(.bottom, BadanSpace.space4)
        }
    }

    private func valueCard(icon: String, tint: Color,
                           title: LocalizedString, body: LocalizedString) -> some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                iconMark(icon, tint: tint, diameter: Self.cardIconDiameter)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(title))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(body))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Page 3: Depth preset

    private var depthPage: some View {
        ScrollView {
            VStack(spacing: BadanSpace.space4) {
                VStack(spacing: BadanSpace.space2) {
                    Text(env.s(Self.depthTitle))
                        .font(Self.titleFont)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(Self.depthSubtitle))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, BadanSpace.space4)

                VStack(spacing: BadanSpace.space3) {
                    depthOption(.casual, icon: "leaf",
                                title: Self.depthSimpleTitle, body: Self.depthSimpleBody)
                    depthOption(.power, icon: "slider.horizontal.3",
                                title: Self.depthDetailTitle, body: Self.depthDetailBody)
                }
            }
            .padding(.horizontal, BadanSpace.space5)
            .padding(.bottom, BadanSpace.space4)
        }
    }

    private func depthOption(_ policy: DepthPolicy, icon: String,
                             title: LocalizedString, body: LocalizedString) -> some View {
        let isSelected = selectedDepth == policy
        return Button {
            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                selectedDepth = policy
                env.update { $0.depthPolicy = policy }
            }
        } label: {
            BadanCard {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    iconMark(icon, tint: BadanColor.primary, diameter: Self.cardIconDiameter)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(env.s(title))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(body))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.separator)
                        .accessibilityHidden(true)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? BadanColor.primary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Page 4: Notifications (opt-in + lock-screen values)

    /// Two independent choices, both defaulting to NO. Skipping this page — via the header's Skip,
    /// or by swiping past it — leaves both off, so silence is never read as consent. Nothing here
    /// requests notification authorization: that prompt belongs at the moment the user turns a class
    /// on in Settings (the contextual-permission convention `NotificationsSettingsScreen` already
    /// follows), not in a flow the user is trying to get through.
    private var notificationsPage: some View {
        ScrollView {
            VStack(spacing: BadanSpace.space4) {
                VStack(spacing: BadanSpace.space2) {
                    Text(env.s(Self.notifTitle))
                        .font(Self.titleFont)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(Self.notifSubtitle))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, BadanSpace.space4)

                BadanCard {
                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        SettingsToggleRow(title: Self.notifSummariesLabel,
                                          subtitle: Self.notifSummariesHint,
                                          isOn: onboardingSummariesBinding)
                        Rectangle()
                            .fill(BadanColor.separator)
                            .frame(height: 1)
                        SettingsToggleRow(title: Self.notifValuesLabel,
                                          subtitle: Self.notifValuesHint,
                                          isOn: onboardingValuesBinding)
                    }
                }

                Text(env.s(Self.notifReassurance))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, BadanSpace.space5)
            .padding(.bottom, BadanSpace.space4)
        }
    }

    /// Turns on the two daily summary classes together — this page offers "the daily summaries", not
    /// a per-class matrix, because five toggles mid-onboarding is a decision the user cannot yet make
    /// meaningfully. Settings → Notifications is where each class is chosen individually.
    private var onboardingSummariesBinding: Binding<Bool> {
        Binding(
            get: {
                let optIn = env.profile.notifications.classOptIn
                return (optIn[NotificationClass.morningReadinessSummary.rawValue] ?? false)
                    || (optIn[NotificationClass.eveningWindDown.rawValue] ?? false)
            },
            set: { newValue in
                env.update {
                    $0.notifications.classOptIn[NotificationClass.morningReadinessSummary.rawValue] = newValue
                    $0.notifications.classOptIn[NotificationClass.eveningWindDown.rawValue] = newValue
                }
            }
        )
    }

    private var onboardingValuesBinding: Binding<Bool> {
        Binding(
            get: { env.profile.notifications.showValuesInNotifications },
            set: { newValue in env.update { $0.notifications.showValuesInNotifications = newValue } }
        )
    }

    // MARK: - Page 5: Connect

    private var connectPage: some View {
        // UIUX-194: same scroll escape hatch as welcomePage, for the same reason.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: BadanSpace.space6) {
                    Spacer(minLength: 0)

                    // EASE-115: an ECG waveform reads as "cardiac monitoring," not "connect
                    // any health source" — use the source-agnostic glyph already established
                    // for Data Sources elsewhere (BodyScreen's tool row, Settings).
                    iconMark("antenna.radiowaves.left.and.right", tint: BadanColor.primary,
                              diameter: Self.heroIconDiameter)

                    VStack(spacing: BadanSpace.space3) {
                        Text(env.s(Self.connectTitle))
                            .font(Self.titleFont)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(Self.connectSubtitle))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    .multilineTextAlignment(.center)

                    Spacer(minLength: 0)

                    VStack(spacing: BadanSpace.space3) {
                        switch connectState {
                        case .unavailable:
                            Text(env.s(Self.connectUnavailableNotice))
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, BadanSpace.space2)
                            primaryButton(Loc.done) { finishOnboarding() }

                        // NEW-01: the backfill is still deriving — a calm progress state, never
                        // a blocking one. "Continue" always works and skips straight into the
                        // app without waiting for the fact (styled as secondary, not primary,
                        // since nothing is confirmed yet).
                        case .awaitingFirstFact:
                            firstFactProgress
                            Button { finishOnboarding() } label: {
                                Text(env.s(Self.continueLabel))
                                    .font(BadanFont.body)
                                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                            .buttonStyle(.plain)

                        case .factReady(let fact):
                            firstFactCard(fact)
                            primaryButton(Loc.done) { finishOnboarding() }

                        case .factUnavailable:
                            Text(env.s(Self.firstFactFallback))
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, BadanSpace.space2)
                            primaryButton(Loc.done) { finishOnboarding() }

                        case .idle, .staging, .connecting:
                            primaryButton(connectLabel) {
                                startConnect()
                            }
                            .disabled(connectState != .idle)
                            .opacity(connectState == .idle ? 1 : 0.7)

                            // STUB-01/COMP-06: honest framing for the "don't connect now" path —
                            // this used to read "Continue without connecting" with no mention
                            // that doing so leaves the bundled sample dataset in place
                            // (indefinitely, since bootstrap seeds it before onboarding even
                            // starts). The caption underneath says so; the label itself no
                            // longer implies "continue with nothing."
                            VStack(spacing: BadanSpace.space1) {
                                Button { finishOnboarding() } label: {
                                    Text(env.s(Self.exploreWithSampleData))
                                        .font(BadanFont.body)
                                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                                        .foregroundStyle(BadanColor.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(connectState != .idle)

                                Text(env.s(Self.sampleDataCaption))
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                                    .multilineTextAlignment(.center)
                            }

                            // STUB-01/COMP-06: the honest third option — no sample data at all,
                            // ever. Purges whatever bootstrap already demo-seeded before
                            // onboarding reached this screen and boots straight to real empty
                            // states. Deliberately the quietest of the three actions (plain
                            // caption-weight text, no button chrome) since it's the least common
                            // path, not a discouraged one.
                            Button { startEmpty() } label: {
                                if startingEmpty {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(env.s(Self.startEmpty))
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary.opacity(0.75))
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: BadanSpace.touchMin)
                            .disabled(connectState != .idle || startingEmpty)
                        }
                    }
                }
                .frame(minHeight: proxy.size.height)
                .padding(.horizontal, BadanSpace.space5)
                .padding(.bottom, BadanSpace.space5)
            }
        }
    }

    // MARK: - Footer (Next for steps 0–2)

    @ViewBuilder private var footer: some View {
        if step < lastStep {
            VStack(spacing: BadanSpace.space2) {
                // EASE-106: repeat the "this choice is reversible" reassurance right next to
                // the decision itself, not only in the page subtitle above the cards.
                if step == 2 {
                    Text(env.s(Self.depthReassurance))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                // ONB-02: this used to be `.disabled(step == 2 && selectedDepth == nil)` —
                // dead code, since `selectedDepth` is preselected from `env.depth` in `onAppear`
                // (never nil; `DepthPolicy` has no nil case and defaults to `.casual`), so the
                // guard could never actually trigger. Removed rather than left as
                // never-true-but-still-evaluated logic.
                primaryButton(Loc.next) {
                    withAnimation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion)) { step += 1 }
                }
            }
            .padding(.horizontal, BadanSpace.space5)
            .padding(.top, BadanSpace.space3)
            .padding(.bottom, BadanSpace.space5)
        }
    }

    // MARK: - Shared building blocks

    /// FEAT-01/NEW-01: request real HealthKit authorization. On denial/unavailable, stay on this
    /// page and show a calm notice instead of silently completing, so the user isn't left
    /// wondering what happened to their tap. On grant, stay on this page a little longer and
    /// await the backfill→derivation the connect path kicks off
    /// (`AppEnvironment.connectHealthKit`/`awaitBackfillCompletion`) so onboarding can pay off
    /// its "you'll see something real about yourself" promise with one real fact — but never for
    /// longer than `firstFactTimeout`, and the "Continue" escape hatch works the whole time.
    /// (EPIC-01 task 5) Kicks off the STAGED sequence rather than one blanket prompt: the gate
    /// presents core vitals, then sleep, then activity, each explainer followed by that bundle's
    /// own system sheet. Nothing is written and no backfill starts until the last one is answered
    /// — `finishStagedConnect()` below picks up from there, driven by `onChange(of:
    /// permissions.isIdle)`.
    ///
    /// If HealthKit is unavailable (simulator without a Health store, an iPad, a restricted
    /// device) the gate queues nothing and stays idle, so the sequence would never start. Detect
    /// that here rather than leaving the button spinning forever.
    /// The button label under the explainer sheets. `.staging` gets its own wording because
    /// "Connecting…" would be false while the user is still deciding — nothing has connected, and
    /// the sheet they are reading is the reason.
    private var connectLabel: LocalizedString {
        switch connectState {
        case .idle: return Self.connectPrimary
        case .staging: return Self.reviewingPermissions
        default: return Self.connecting
        }
    }

    private func startConnect() {
        connectState = .staging
        permissions.request(HealthPermissionBundle.onboardingConnect)
        if permissions.isIdle {
            // Nothing to explain: either the platform is unavailable, or these bundles were all
            // answered in a previous run of onboarding. Proceed straight to the connect, which
            // itself no-ops honestly when HealthKit isn't there.
            finishStagedConnect()
        }
    }

    /// Runs after the last explainer is answered.
    ///
    /// `requestAuthorization: false` because the gate has already shown every sheet this flow
    /// intends to show — see `AppEnvironment.connectHealthKit(requestAuthorization:)`.
    ///
    /// A user who dismissed every explainer with "Not now" has connected nothing, and saying
    /// otherwise would put a "Connected" state in front of a person who declined. They land on
    /// the same calm notice a denied prompt produces, which already points them at Sources for
    /// later — so declining costs them the flow, not the app.
    private func finishStagedConnect() {
        guard connectState == .staging else { return }
        guard !permissions.confirmed.isEmpty else {
            setConnectState(.unavailable)
            return
        }
        connectState = .connecting
        Task {
            let connected = await env.connectHealthKit(requestAuthorization: false)
            guard connected else {
                setConnectState(.unavailable)
                return
            }
            setConnectState(.awaitingFirstFact)
            let completedInTime = await env.awaitBackfillCompletion(timeoutSeconds: Self.firstFactTimeout)
            guard completedInTime, let fact = try? env.firstFact() else {
                setConnectState(.factUnavailable)
                return
            }
            setConnectState(.factReady(fact))
        }
    }

    private func setConnectState(_ newValue: ConnectState) {
        withAnimation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion)) { connectState = newValue }
    }

    /// ONB-01: every path off this screen goes through here so the persisted step (see the
    /// `onAppear`/`onChange(of: step)` pair above) never survives past a completed onboarding —
    /// otherwise a relaunch after finishing onboarding once could, in principle, seed a stale
    /// step number for a *future* re-onboarding (e.g. after "Delete all data").
    private func finishOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        env.completeOnboarding()
    }

    /// STUB-01/COMP-06: "Start empty" — purge whatever bootstrap already demo-seeded and mark
    /// onboarding's data state as deliberately, honestly empty (see `SeedController.
    /// markStartEmpty`), then finish onboarding the same way every other path does. Runs the
    /// purge off the main actor (it drops/deletes and `VACUUM`s two on-disk databases) and
    /// guards against a double-tap with `startingEmpty`; failures are non-fatal — onboarding
    /// still completes, since staying stuck on this screen over a purge failure would be a worse
    /// outcome than the user starting with whatever data is left.
    private func startEmpty() {
        guard !startingEmpty else { return }
        startingEmpty = true
        let database = env.database
        Task.detached(priority: .userInitiated) {
            try? SeedController.markStartEmpty(database: database)
            await MainActor.run { finishOnboarding() }
        }
    }

    /// NEW-01: "Looking at your last few weeks…" — shown while the connect path's
    /// backfill→derivation is still running. `.accessibilityElement(children: .combine)` reads
    /// the spinner + text as one phrase, matching `StatBox`'s combined-label pattern.
    private var firstFactProgress: some View {
        VStack(spacing: BadanSpace.space3) {
            ProgressView()
            Text(env.s(Self.firstFactProgressText))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(env.s(Self.firstFactProgressText))
    }

    /// NEW-01: the trust-ladder payoff — one real, wellness-safe fact. Combined into a single
    /// VoiceOver phrase ("Your first insight, {fact}"), matching `StatBox`'s
    /// `accessibilityLabelText` pattern rather than letting VoiceOver hit the caption and body
    /// text as separate, disconnected stops.
    private func firstFactCard(_ fact: LocalizedString) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(env.s(Self.firstFactLabel))
                    .font(BadanFont.chip)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(env.s(fact))
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(env.s(Self.firstFactLabel)), \(env.s(fact))")
    }

    private func primaryButton(_ label: LocalizedString, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(env.s(label))
                .font(BadanFont.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                .foregroundStyle(BadanColor.onPrimary)
                .background(BadanColor.primary,
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconMark(_ systemImage: String, tint: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.12))
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.42, weight: .regular))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    // MARK: - Local tokens

    /// A rounded display title — the token ramp tops out at `sectionTitle` (20pt), so onboarding
    /// heroes use one slightly larger rounded weight for a warmer welcome.
    private static let titleFont = Font.system(size: 28, weight: .bold, design: .rounded)

    /// Foreground for filled primary buttons: white on the light-theme teal, near-black on the
    /// light dark-theme teal — legible in both, since there is no dedicated on-primary token.

    // UIUX-195: named, onboarding-scoped diameters instead of bare `84`/`44` literals at each
    // call site — onboarding is the app's most visually bespoke screen and the least
    // token-governed, so these document intent without promoting a global design-system token.
    private static let heroIconDiameter: CGFloat = 84
    private static let cardIconDiameter: CGFloat = 44

    /// NEW-01: how long the connect page waits for the backfill→derivation to produce a first
    /// fact before falling back to the honest "still settling in" notice. Chosen to comfortably
    /// cover a 90-day HealthKit read + baseline recompute + insight generation on a real device
    /// without ever reading as a stall.
    private static let firstFactTimeout: Double = 12

    /// ONB-01: persists the in-progress step across a relaunch; cleared by `finishOnboarding()`
    /// so a *future* re-onboarding (e.g. after "Delete all data") never inherits a stale step.
    private static let stepKey = "badan.onboarding.step"

    // MARK: - Strings (bilingual; wellness-safe)

    private static let languageHint = LocalizedString(
        en: "Choose your language. You can change it anytime.",
        ar: "اختر لغتك. يمكنك تغييرها في أي وقت.")

    /// UIUX-200: spoken before a language toggle button activates, since selecting it flips
    /// the whole app's layout direction (RTL/LTR), not just a preference value.
    private static let languageToggleHint = LocalizedString(
        en: "Switches the app language and layout direction.",
        ar: "يبدّل لغة التطبيق واتجاه التخطيط.")

    /// EASE-109/OPT-164/UIUX-192: accessible substitute for the purely visual progress dots.
    private static let stepProgressTemplate = LocalizedString(
        en: "Step {current} of {total}",
        ar: "الخطوة {current} من {total}")

    /// EASE-106: reassurance repeated next to the Next button on the depth step, not just in
    /// the page subtitle above the cards.
    private static let depthReassurance = LocalizedString(
        en: "You can change this anytime in Settings.",
        ar: "يمكنك تغيير هذا في أي وقت من الإعدادات.")

    private static let notifTitle = LocalizedString(en: "Want a daily nudge?", ar: "تريد تذكيراً يومياً؟")
    private static let notifSubtitle = LocalizedString(
        en: "Both are off unless you turn them on, and you can change either later.",
        ar: "كلاهما متوقّف ما لم تفعّله، ويمكنك تغيير أيّ منهما لاحقاً.")

    private static let notifSummariesLabel = LocalizedString(
        en: "Daily summaries", ar: "الملخّصات اليومية")
    private static let notifSummariesHint = LocalizedString(
        en: "A short check-in each morning and a calm nudge in the evening.",
        ar: "ملخّص قصير كل صباح وتذكير هادئ في المساء.")

    /// The privacy choice, stated as what it actually does. "Show my readings" would undersell it:
    /// the point is WHERE they appear — a locked screen anyone holding the phone can read.
    private static let notifValuesLabel = LocalizedString(
        en: "Show readings on the lock screen", ar: "إظهار القراءات على شاشة القفل")
    private static let notifValuesHint = LocalizedString(
        en: "Off by default. When off, a notification says only that something is ready — never a number.",
        ar: "متوقّف افتراضياً. عند إيقافه، يذكر الإشعار أن شيئاً جاهز فقط — دون أي رقم.")

    private static let notifReassurance = LocalizedString(
        en: "BADAN will ask permission the first time it actually needs to send one.",
        ar: "سيطلب «بدن» الإذن أول مرة يحتاج فيها فعلاً إلى إرسال إشعار.")

    private static let whyTitle = LocalizedString(en: "Why BADAN", ar: "لماذا بدن")

    private static let valueOwnTitle = LocalizedString(en: "Your data is yours", ar: "بياناتك ملكك")
    private static let valueOwnBody = LocalizedString(
        en: "Export everything, anytime. Raw data is never locked away.",
        ar: "صدّر كل شيء في أي وقت. البيانات الخام لا تُحجب أبداً.")

    private static let valueOfflineTitle = LocalizedString(en: "Works offline", ar: "يعمل دون اتصال")
    private static let valueOfflineBody = LocalizedString(
        en: "Everything stays on your device. No account needed.",
        ar: "كل شيء يبقى على جهازك. لا حاجة إلى حساب.")

    private static let depthTitle = LocalizedString(en: "How much detail?", ar: "كم من التفاصيل؟")
    private static let depthSubtitle = LocalizedString(
        en: "Two views over the same data. Switch anytime in Settings.",
        ar: "عرضان لنفس البيانات. بدّل في أي وقت من الإعدادات.")

    private static let depthSimpleTitle = LocalizedString(en: "Keep it simple", ar: "أبقِه بسيطاً")
    private static let depthSimpleBody = LocalizedString(
        en: "Calm summaries and the numbers that matter most.",
        ar: "ملخّصات هادئة والأرقام الأهم.")

    private static let depthDetailTitle = LocalizedString(en: "Show me detail", ar: "أرِني التفاصيل")
    private static let depthDetailBody = LocalizedString(
        en: "Raw values, your ranges, and where each number came from.",
        ar: "القيم الخام ونطاقاتك ومصدر كل رقم.")

    // EASE-126: standardize on "Connect"/"Data sources" vocabulary — matches `Loc.dataSources`
    // and `connectPrimary` below rather than introducing a third verb ("bring in").
    private static let connectTitle = LocalizedString(en: "Connect your health data", ar: "اربط بياناتك الصحية")
    private static let connectSubtitle = LocalizedString(
        en: "Connect a source now, or add it later — BADAN works either way.",
        ar: "اربط مصدراً الآن أو أضِفه لاحقاً — يعمل بدن في الحالتين.")

    private static let connectPrimary = LocalizedString(en: "Connect health data", ar: "ربط البيانات الصحية")

    // FEAT-01: real HealthKit connect states.
    private static let connecting = LocalizedString(en: "Connecting…", ar: "جارٍ الاتصال…")
    /// (EPIC-01 task 5) Shown while the staged explainers are on screen — the user is reading,
    /// not waiting on us.
    private static let reviewingPermissions = LocalizedString(
        en: "Choosing what to share…", ar: "اختيار ما تريد مشاركته…")
    private static let connectUnavailableNotice = LocalizedString(
        en: "We couldn't connect right now. You can connect later from Sources.",
        ar: "تعذّر الاتصال الآن. يمكنك الاتصال لاحقاً من صفحة المصادر.")

    // MARK: - Strings — STUB-01/COMP-06 sample-data honesty
    //
    // Replaces `Loc.continueWithoutConnecting` ("Continue without connecting") here: that label
    // never said what "continuing" actually means — the bundled 90-day sample dataset stays in
    // place, indefinitely, looking exactly like the user's own data on Home/Body/Sources/
    // Insights. These three strings + `startEmpty` below make that explicit and offer a real
    // alternative that has no sample data in it at all.
    private static let exploreWithSampleData = LocalizedString(
        en: "Explore with sample data", ar: "استكشاف باستخدام بيانات تجريبية")
    private static let sampleDataCaption = LocalizedString(
        en: "BADAN is pre-filled with sample data until you connect your own.",
        ar: "بدن معبأ ببيانات تجريبية إلى أن تربط بياناتك الخاصة.")
    private static let startEmpty = LocalizedString(en: "Start empty", ar: "البدء بلا بيانات")

    // MARK: - Strings — NEW-01 first-fact payoff

    private static let firstFactProgressText = LocalizedString(
        en: "Looking at your last few weeks…",
        ar: "نلقي نظرة على أسابيعك الأخيرة…")

    private static let firstFactLabel = LocalizedString(en: "Your first insight", ar: "ملاحظتك الأولى")

    /// Honest fallback for a fresh HealthKit account, sparse data, or a denied-after-grant edge
    /// — never a fabricated fact, and the primary action still proceeds into the app.
    private static let firstFactFallback = LocalizedString(
        en: "Your data is still settling in — your first insight will be waiting on Home.",
        ar: "لا تزال بياناتك تستقر — ستجد أول ملاحظاتك بانتظارك في الصفحة الرئيسية.")

    private static let continueLabel = LocalizedString(en: "Continue", ar: "متابعة")
}
