import SwiftUI

@main
struct BADANApp: App {
    @State private var env = AppEnvironment.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task { await env.bootstrap() }
        }
    }
}
