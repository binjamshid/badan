import SwiftUI
import MetricKit
import OSLog
import UserNotifications

@main
struct BADANApp: App {
    @State private var env = AppEnvironment.makeDefault()
    @State private var metricSubscriber = MetricKitSubscriber()
    // Retained here because UNUserNotificationCenter holds its delegate weakly; without a strong
    // reference foreground presentation would silently stop working.
    @State private var notificationDelegate = NotificationForegroundDelegate()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task {
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    await env.bootstrap()
                    // NEW-02/UX-02: self-heal medication-reminder scheduling once per launch
                    // (no-op unless the pref is on AND notifications are already authorized;
                    // never prompts here — authorization is only ever requested contextually
                    // from the Settings toggle).
                    await env.refreshMedicationReminders()
                }
        }
        // BUG-02: without this, data goes permanently stale after the one connect-time
        // backfill — nothing else ever re-ingests. Every return to the foreground (not just
        // cold launch) is a chance to catch up incrementally. `syncIfStale()` already guards
        // `isHealthKitConnected` (and the debounce/in-flight check) itself, so the check below
        // is a cheap redundant short-circuit, not the only thing standing between this and a
        // needless call — safe either way.
        //
        // EDGE-10: `Database.performBackgroundMaintenance()` (WAL checkpoint + PRAGMA optimize)
        // had no caller — do it opportunistically whenever the app is backgrounded, fire-and-
        // forget, off the main actor, and never blocking the transition itself.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if env.isHealthKitConnected {
                    env.syncIfStale()
                }
            case .background:
                let database = env.database
                Task.detached(priority: .utility) {
                    database.performBackgroundMaintenance()
                }
            default:
                break
            }
        }
    }
}

/// Local-only MetricKit subscriber (PERF-005): logs launch/hang/disk-write payloads via OSLog
/// so real-world performance data is at least inspectable during beta testing. No network
/// transmission — everything stays on-device, consistent with the app's local-first design.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let logger = Logger(subsystem: "com.badan.app", category: "MetricKit")

    override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            logger.info("MetricKit metric payload received: \(payload.dictionaryRepresentation().description, privacy: .public)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            logger.info("MetricKit diagnostic payload received: \(payload.dictionaryRepresentation().description, privacy: .public)")
        }
    }
}
