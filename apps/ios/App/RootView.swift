import SwiftUI

/// The app's top-level gate: a calm splash while the store seeds, then onboarding on first
/// run, then the five-destination tab shell. Everything is wrapped in `badanChrome` so a
/// language or theme change re-skins (and re-mirrors for RTL) instantly.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if !env.isReady {
                SplashView()
                    .transition(.opacity)
            } else if !env.onboardingComplete {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: env.isReady)
        .animation(.easeInOut, value: env.onboardingComplete)
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

    var body: some View {
        // Stable accessibilityIdentifiers on the five tabs anchor future UI tests to the
        // primary navigation without depending on (localized) visible labels. FEAT-300.
        TabView {
            NavigationStack { HomeScreen() }
                .tabItem { Label(env.s(Loc.tabToday), systemImage: "sun.max.fill") }
                .accessibilityIdentifier("tab.today")

            NavigationStack { BodyScreen() }
                .tabItem { Label(env.s(Loc.tabBody), systemImage: "figure.stand") }
                .accessibilityIdentifier("tab.body")

            NavigationStack { LogHubScreen() }
                .tabItem { Label(env.s(Loc.tabLog), systemImage: "plus.circle.fill") }
                .accessibilityIdentifier("tab.log")

            NavigationStack { InsightsScreen() }
                .tabItem { Label(env.s(Loc.tabInsights), systemImage: "sparkles") }
                .accessibilityIdentifier("tab.insights")

            NavigationStack { SettingsScreen() }
                .tabItem { Label(env.s(Loc.tabSettings), systemImage: "gearshape.fill") }
                .accessibilityIdentifier("tab.settings")
        }
    }
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
                Text("BADAN").font(.system(size: 28, weight: .bold))
                    .foregroundStyle(BadanColor.textPrimary)
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
