import SwiftUI

/// The app's top-level gate: a calm splash while the store seeds, then onboarding on first
/// run, then the five-destination tab shell. Everything is wrapped in `badanChrome` so a
/// language or theme change re-skins (and re-mirrors for RTL) instantly.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// STUB-01/COMP-06: whether sample (bootstrap demo) data is currently active, driving the
    /// global `SampleDataBanner`. `SeedController.isDemoDataActive` is a bare `UserDefaults`
    /// flag living outside `AppEnvironment` on purpose (see `SeedController`), so it isn't
    /// `@Observable` — this re-reads it explicitly rather than relying on SwiftUI to notice a
    /// change on its own. Refreshed: once on first appearance; on every scene-phase change
    /// (foreground/background — cheap, covers anything that changed while suspended); and on
    /// every `onboardingComplete` flip, which is exactly the moment `OnboardingView`'s "Explore
    /// with sample data" / "Start empty" / real connect choices land — the one transition that
    /// happens *within* the same session and so wouldn't otherwise trigger a re-check.
    @State private var isSampleDataActive = SeedController.isDemoDataActive

    var body: some View {
        Group {
            if !env.isReady {
                SplashView()
                    .transition(.opacity)
            } else if !env.onboardingComplete {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainTabView(showSampleDataBanner: isSampleDataActive) {
                    // STUB-01/COMP-06: the moment `DataConnectionChoiceScreen`'s sheet closes —
                    // having connected or deleted sample data, or just been dismissed with
                    // neither — is, like `onboardingComplete` flipping, a within-session change
                    // this bare `UserDefaults` flag wouldn't otherwise trigger a re-check for.
                    // Without this the banner (and its sheet) would keep showing until the next
                    // scene-phase change (backgrounding/foregrounding the app).
                    isSampleDataActive = SeedController.isDemoDataActive
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: env.isReady)
        .animation(.easeInOut, value: env.onboardingComplete)
        .task { isSampleDataActive = SeedController.isDemoDataActive }
        .onChange(of: scenePhase) { _, _ in isSampleDataActive = SeedController.isDemoDataActive }
        .onChange(of: env.onboardingComplete) { _, _ in isSampleDataActive = SeedController.isDemoDataActive }
        // EDGE-05: a calm, always-visible warning whenever `AppEnvironment.makeDefault()` had to
        // fall back to ephemeral (scratch temp dir or true in-memory) storage — previously this
        // was either silent or a hard crash, with no way for the user to know a session's data
        // won't survive closing the app.
        .overlay(alignment: .top) {
            if env.isStorageFallback {
                StorageFallbackBanner()
            }
        }
        .badanChrome(env)
    }
}

/// EDGE-05: see `RootView`'s overlay above. Factual, wellness-safe, no alarm language — this is
/// a storage-mode notice, not an error the user needs to act on.
private struct StorageFallbackBanner: View {
    @Environment(AppEnvironment.self) private var env

    private static let message = LocalizedString(
        en: "Running in temporary mode — data entered now won't be saved after closing the app.",
        ar: "وضع مؤقت قيد التشغيل — لن تُحفظ البيانات المُدخلة الآن بعد إغلاق التطبيق.")

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.small)
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            LText(Self.message)
                .font(.footnote)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BadanSpace.space4)
        .padding(.vertical, BadanSpace.space3)
        .background(BadanColor.surfaceElevated)
    }
}

/// The five destinations (Blueprint IA): Today, Body, Log, Insights, Settings. Each tab is its
/// own NavigationStack so screens push detail views (metric detail, sources, export) freely.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env

    /// STUB-01/COMP-06: whether `RootView` determined sample data is currently active — see
    /// `SampleDataBanner`. Defaults `false` so existing callers/previews that construct
    /// `MainTabView()` bare keep compiling unchanged.
    var showSampleDataBanner: Bool = false

    /// STUB-01/COMP-06: called once `DataConnectionChoiceScreen`'s sheet has closed, so
    /// `RootView` can re-read `SeedController.isDemoDataActive` and flip `showSampleDataBanner`
    /// promptly — see the call site in `RootView.body`. Defaults `nil` for the same reason
    /// `showSampleDataBanner` defaults `false`: existing bare `MainTabView()` callers/previews
    /// keep compiling unchanged.
    var onDataChoiceDismissed: (() -> Void)? = nil

    /// EPIC-32: the selected tab. The `TabView` was previously uncontrolled (defaulted to the
    /// first tab); this binding preserves that (starts on Today) and additionally lets a tapped
    /// notification's deep link select the destination tab. Manual tab taps still work unchanged.
    @State private var selectedTab: MainTab = .today

    /// STUB-01/COMP-06 (post-onboarding data choice): whether `DataConnectionChoiceScreen` is
    /// presented. Tapping the (now-tappable) `SampleDataBanner` is this screen's one entry point
    /// from the tab shell — see `DataConnectionChoiceScreen`'s doc for why it's needed at all
    /// (onboarding's own connect/start-empty choice has no way back to it afterward).
    @State private var showingDataChoice = false

    var body: some View {
        // Stable accessibilityIdentifiers on the five tabs anchor future UI tests to the
        // primary navigation without depending on (localized) visible labels. FEAT-300.
        TabView(selection: $selectedTab) {
            NavigationStack { HomeScreen() }
                .tabItem { Label(env.s(Loc.tabToday), systemImage: "sun.max.fill") }
                .accessibilityIdentifier("tab.today")
                .tag(MainTab.today)

            NavigationStack { BodyScreen() }
                .tabItem { Label(env.s(Loc.tabBody), systemImage: "figure.stand") }
                .accessibilityIdentifier("tab.body")
                .tag(MainTab.body)

            NavigationStack { LogHubScreen() }
                .tabItem { Label(env.s(Loc.tabLog), systemImage: "plus.circle.fill") }
                .accessibilityIdentifier("tab.log")
                .tag(MainTab.log)

            NavigationStack { InsightsScreen() }
                .tabItem { Label(env.s(Loc.tabInsights), systemImage: "sparkles") }
                .accessibilityIdentifier("tab.insights")
                .tag(MainTab.insights)

            NavigationStack { SettingsScreen() }
                .tabItem { Label(env.s(Loc.tabSettings), systemImage: "gearshape.fill") }
                .accessibilityIdentifier("tab.settings")
                .tag(MainTab.settings)
        }
        // EPIC-32: a tapped notification sets `env.pendingDeepLink`; select its tab and clear it.
        // Deep links resolve to the destination tab (the evidence surface's top-level home) — see
        // `NotificationDeepLink.tab`.
        .onChange(of: env.pendingDeepLink) { _, link in
            if let link {
                selectedTab = link.tab
                env.pendingDeepLink = nil
            }
        }
        // STUB-01/COMP-06: `safeAreaInset` on the `TabView` itself places the banner directly
        // above the tab bar (each tab's own content gets the matching bottom inset reserved
        // automatically) rather than floating over it — chosen over a plain `.overlay` so it
        // never has to guess the tab bar's height across devices/Dynamic Type sizes.
        .safeAreaInset(edge: .bottom) {
            if showSampleDataBanner {
                // STUB-01/COMP-06: the banner itself stays purely presentational (see its own
                // doc — no dismiss control) — tappability and what tapping it opens are both
                // this call site's concern, not the component's.
                Button { showingDataChoice = true } label: {
                    SampleDataBanner(language: env.language)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(env.s(Self.sampleDataBannerHint)))
            }
        }
        .sheet(isPresented: $showingDataChoice) {
            NavigationStack {
                DataConnectionChoiceScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(env.s(Loc.close)) { showingDataChoice = false }
                        }
                    }
            }
        }
        // STUB-01/COMP-06: fires on every dismiss path (a successful connect/delete calling
        // `dismiss()` from inside the sheet, the toolbar Close button above, or a swipe-to-
        // dismiss gesture) — SwiftUI flips a `.sheet(isPresented:)` binding back to `false` on
        // all three, so one `onChange` covers all of them.
        .onChange(of: showingDataChoice) { _, isPresented in
            if !isPresented { onDataChoiceDismissed?() }
        }
    }

    private static let sampleDataBannerHint = LocalizedString(
        en: "Opens options to connect Apple Health or delete the sample data.",
        ar: "يفتح خيارات لربط صحة آبل أو حذف البيانات التجريبية.")
}

/// Shown while `AppEnvironment.bootstrap()` seeds/loads. On a slow first run this is the
/// longest wait in the app, so it carries a calm status caption instead of a bare spinner
/// (EASE-135, OPT-073, UIUX-069), offers a way forward if the seed stalls (OPT-071), and —
/// since `bootstrap()` now holds `isReady` at `false` while `bootstrapError` is set (BUG-17) —
/// shows the same "continue anyway" way forward for a genuine setup failure.
struct SplashView: View {
    @Environment(AppEnvironment.self) private var env

    private static let statusCaption = LocalizedString(
        en: "Setting up your data…", ar: "جارٍ إعداد بياناتك…")
    private static let stalledCaption = LocalizedString(
        en: "This is taking longer than usual.", ar: "هذا يستغرق وقتًا أطول من المعتاد.")
    // BUG-17: calm, wellness-safe wording — nothing about the user's health data was lost; the
    // one-time setup step itself hit a problem.
    private static let errorCaption = LocalizedString(
        en: "Setup ran into a problem. Your device is fine — you can continue.",
        ar: "واجه الإعداد مشكلة. جهازك بخير — يمكنك المتابعة.")
    private static let continueAction = LocalizedString(en: "Continue anyway", ar: "المتابعة على أي حال")

    var body: some View {
        ZStack {
            BadanColor.background.ignoresSafeArea()
            VStack(spacing: BadanSpace.space4) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                // FIX-15: the app calls itself بدن everywhere in Arabic, but the splash
                // wordmark used to be Latin-only ("BADAN") even in Arabic mode. "BADAN" stays
                // the primary mark in both languages (it's the brand/App Store name); in Arabic
                // it now carries a secondary بدن caption underneath rather than replacing it, so
                // the reading is: this app, in your language, is بدن.
                VStack(spacing: BadanSpace.space1) {
                    Text("BADAN").font(.system(size: 28, weight: .bold))
                        .foregroundStyle(BadanColor.textPrimary)
                    if env.language == .ar {
                        Text("بدن")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                ProgressView().tint(BadanColor.primary)
                LText(caption)
                    .font(.footnote)
                    .foregroundStyle(BadanColor.textSecondary)
                    .multilineTextAlignment(.center)
                if env.bootstrapStalled || env.bootstrapError != nil {
                    Button {
                        env.dismissBootstrapStall()
                    } label: {
                        LText(Self.continueAction)
                    }
                    .tint(BadanColor.primary)
                    .padding(.top, BadanSpace.space2)
                }
            }
            .padding(.horizontal, BadanSpace.space4)
        }
    }

    private var caption: LocalizedString {
        if env.bootstrapError != nil { return Self.errorCaption }
        if env.bootstrapStalled { return Self.stalledCaption }
        return Self.statusCaption
    }
}
