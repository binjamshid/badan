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
        .badanChrome(env)
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
/// (EASE-135, OPT-073, UIUX-069), and offers a way forward if the seed stalls (OPT-071).
struct SplashView: View {
    @Environment(AppEnvironment.self) private var env

    private static let statusCaption = LocalizedString(
        en: "Setting up your data…", ar: "جارٍ إعداد بياناتك…")
    private static let stalledCaption = LocalizedString(
        en: "This is taking longer than usual.", ar: "هذا يستغرق وقتًا أطول من المعتاد.")
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
                LText(env.bootstrapStalled ? Self.stalledCaption : Self.statusCaption)
                    .font(.footnote)
                    .foregroundStyle(BadanColor.textSecondary)
                if env.bootstrapStalled {
                    Button {
                        env.dismissBootstrapStall()
                    } label: {
                        LText(Self.continueAction)
                    }
                    .tint(BadanColor.primary)
                    .padding(.top, BadanSpace.space2)
                }
            }
        }
    }
}
