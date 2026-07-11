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
            } else if !env.onboardingComplete {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .badanChrome(env)
    }
}

/// The five destinations (Blueprint IA): Today, Body, Log, Insights, Settings. Each tab is its
/// own NavigationStack so screens push detail views (metric detail, sources, export) freely.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            NavigationStack { HomeScreen() }
                .tabItem { Label(env.s(Loc.tabToday), systemImage: "sun.max.fill") }

            NavigationStack { BodyScreen() }
                .tabItem { Label(env.s(Loc.tabBody), systemImage: "figure.stand") }

            NavigationStack { LogHubScreen() }
                .tabItem { Label(env.s(Loc.tabLog), systemImage: "plus.circle.fill") }

            NavigationStack { InsightsScreen() }
                .tabItem { Label(env.s(Loc.tabInsights), systemImage: "sparkles") }

            NavigationStack { SettingsScreen() }
                .tabItem { Label(env.s(Loc.tabSettings), systemImage: "gearshape.fill") }
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            BadanColor.background.ignoresSafeArea()
            VStack(spacing: BadanSpace.space4) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(BadanColor.primary)
                Text("BADAN").font(.system(size: 28, weight: .bold))
                    .foregroundStyle(BadanColor.textPrimary)
                ProgressView().tint(BadanColor.primary)
            }
        }
    }
}
