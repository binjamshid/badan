import SwiftUI

/// A22/EPIC-42 (Phase 4 extension). `BadanWatch` — "a renderer of phone-computed truth plus a
/// logger" (blueprint §24.4's own framing). This slice ships the renderer half only: a glanceable
/// "today" view over `SnapshotReceiver`'s WatchConnectivity-sourced snapshot, plus a read-only
/// detail screen per metric. No on-watch logging, no HealthKit, no live workout session — all
/// explicitly out of this slice's scope (see `project.yml`'s own `BadanWatch` target comment).
@main
struct BadanWatchApp: App {
    var body: some Scene {
        WindowGroup {
            TodayView()
        }
    }
}
