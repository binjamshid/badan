import WidgetKit
import SwiftUI

/// A22/EPIC-42 extension: the watch-face complications.
///
/// Reads the SAME cached snapshot the watch app renders (`WatchSnapshotStore`, in the shared app
/// group) rather than opening its own `WCSession`. A complication and the watch app are separate
/// processes, and two independent readers of one session would race over which saw a given push —
/// the file the app already writes on every receipt is the single source both read.
///
/// Consequence worth stating plainly: a complication is only ever as fresh as the last snapshot the
/// phone pushed. It cannot pull. That is why staleness is rendered rather than hidden — showing an
/// old number as though it were current is the failure mode here, not showing an old number.
@main
struct BadanWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WatchReadinessComplication()
        WatchSleepComplication()
        WatchEffortComplication()
    }
}

// MARK: - Timeline

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: AmbientSnapshotDto?
    let receivedAt: Date?
    var isPlaceholder = false
}

struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, snapshot: nil, receivedAt: nil, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        // One entry, revisited in ~15 minutes. There is nothing to interpolate between: the value
        // changes only when the phone pushes a new snapshot, and generating intermediate entries
        // would draw numbers that were never measured.
        completion(Timeline(entries: [current()], policy: .after(Date.now.addingTimeInterval(15 * 60))))
    }

    private func current() -> WatchComplicationEntry {
        let cached = WatchSnapshotStore.shared().read()
        return WatchComplicationEntry(date: .now, snapshot: cached?.snapshot,
                                      receivedAt: cached?.receivedAt)
    }
}

// MARK: - Shared rendering

/// A 0–100 score in a circular gauge, or an honest empty state. Every complication here is this
/// same shape, so it is written once.
private struct ScoreGauge: View {
    let title: String
    let score: Double?
    let emptyGlyph: String
    let isStale: Bool

    var body: some View {
        if let score {
            Gauge(value: score, in: 0...100) {
                Text(title)
            } currentValueLabel: {
                Text("\(Int(score.rounded()))")
                    // Stale is dimmed, not hidden. The number was true when it was taken, and
                    // removing it would tell the wearer less than showing it is old.
                    .opacity(isStale ? 0.5 : 1)
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            // Never a filled ring at zero — that reads as "your score is 0", which is a claim. A
            // dashed outline reads as "nothing to show", which is the truth.
            ZStack {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Image(systemName: emptyGlyph).font(.system(size: 14))
            }
        }
    }
}

/// Staleness is judged on `generatedAt` — when the PHONE computed the value — not on when this
/// watch received it. That is `SnapshotFreshness`'s own rule and the one that answers "how current
/// is what I'm looking at": a snapshot received five minutes ago can still describe yesterday.
private func isStale(_ entry: WatchComplicationEntry) -> Bool {
    switch SnapshotFreshness.state(generatedAt: entry.snapshot?.generatedAt, now: entry.date) {
    case .fresh: return false
    case .stale, .neverSynced: return true
    }
}

private func isArabic(_ entry: WatchComplicationEntry) -> Bool {
    WatchLanguage.isArabic(for: entry.snapshot)
}

// MARK: - Readiness

struct WatchReadinessComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchReadinessComplication", provider: WatchComplicationProvider()) { entry in
            ScoreGauge(title: WatchStrings.readiness.resolved(isArabic: isArabic(entry)),
                       score: entry.snapshot?.readiness?.score,
                       emptyGlyph: "moon.zzz", isStale: isStale(entry))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Readiness")
        .description("Today's readiness on your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Sleep

struct WatchSleepComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchSleepComplication", provider: WatchComplicationProvider()) { entry in
            // `sleep.score` — the real composite now, not the performance value this field used to
            // carry under a name that promised otherwise.
            ScoreGauge(title: WatchStrings.sleep.resolved(isArabic: isArabic(entry)),
                       score: entry.snapshot?.sleep?.score,
                       emptyGlyph: "bed.double", isStale: isStale(entry))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Sleep")
        .description("Last night's sleep score on your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Effort

struct WatchEffortComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchEffortComplication", provider: WatchComplicationProvider()) { entry in
            ScoreGauge(title: WatchStrings.effort.resolved(isArabic: isArabic(entry)),
                       score: entry.snapshot?.effort?.score,
                       emptyGlyph: "figure.walk", isStale: isStale(entry))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Effort")
        .description("Today's effort on your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}
