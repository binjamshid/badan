import Foundation
import OSLog

/// A single shared `OSSignposter` for the whole app, so every startup/load measurement lands
/// on one Instruments-filterable track instead of a dozen ad-hoc ones. Local-only (no
/// network) — this is a diagnostics aid, not analytics.
enum PerformanceLog {
    static let signposter = OSSignposter(subsystem: "com.badan.app", category: "Startup")
}
