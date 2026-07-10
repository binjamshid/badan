import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }

            MetricsView()
                .tabItem { Label("Metrics", systemImage: "waveform.path.ecg") }

            LoggingView()
                .tabItem { Label("Log", systemImage: "plus.circle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
