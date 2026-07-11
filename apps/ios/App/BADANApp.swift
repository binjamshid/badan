import SwiftUI
import MetricKit
import OSLog

@main
struct BADANApp: App {
    @State private var env = AppEnvironment.makeDefault()
    @State private var metricSubscriber = MetricKitSubscriber()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task { await env.bootstrap() }
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
