import WidgetKit

/// The single entry type all four widgets in this wave render from. `isPlaceholder` is carried
/// explicitly (rather than relying solely on WidgetKit's own implicit placeholder rendering) so
/// every widget view can apply `.redacted(reason: .placeholder)` itself, deterministically, off a
/// value it actually has in hand.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: AmbientSnapshotDto?
    let isPlaceholder: Bool
}

/// The one shared `TimelineProvider` for `RingSingleWidget`, `SentenceWidget`, `MedsDueWidget` and
/// `SleepCardWidget`. A plain `TimelineProvider` (not `AppIntentTimelineProvider`) is the right
/// choice here — none of these four widgets take a user configuration in this wave (no size/metric
/// picker, nothing an `AppIntentConfiguration` would model); `AppIntentTimelineProvider` exists for
/// the configurable-widget case, which is future work, not this one.
struct SnapshotTimelineProvider: TimelineProvider {
    /// Believable-but-clearly-placeholder sample content for the widget gallery / first-add
    /// preview. Every field is fabricated by construction, never a real reading — the view marks
    /// it `.redacted(reason: .placeholder)`, so it is always shown shimmering/greyed, never as if
    /// it were live data (the one thing every widget in this wave promises never to fake for its
    /// REAL nil state — this is the one place fake numbers are correct, precisely because they are
    /// visibly redacted).
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(
            date: .now,
            snapshot: AmbientSnapshotDto(
                schemaVersion: AmbientSnapshotDto.currentSchemaVersion,
                generatedAt: .now,
                language: "en",
                readiness: RingSnapshot(score: 72, provisional: false),
                sentence: SentenceSnapshot(
                    en: "Your readiness looks steady today.",
                    ar: "استعدادك يبدو مستقرًا اليوم."
                ),
                sleep: SleepSnapshot(durationMinutes: 435, score: 78, provisional: false),
                medsDue: MedsDueSnapshot(items: [
                    MedsDueItem(regimenId: "placeholder", displayName: "Medication", timeLabel: "8:00 AM")
                ])
            ),
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let current = currentEntry(at: now)
        // One fallback entry a few hours out so a widget the app hasn't relaunched to refresh
        // (via `WidgetCenter.reloadTimelines` — the main app's job, not this target's) still ticks
        // forward reasonably rather than freezing on a visibly stale timeline. It repeats the SAME
        // last-known snapshot rather than inventing anything new; `.after` re-asks this provider
        // once that time passes, and WidgetKit may also reload sooner on its own system budget or
        // immediately whenever the main app calls `reloadTimelines`.
        let fallbackDate = Calendar.current.date(byAdding: .hour, value: 4, to: now)
            ?? now.addingTimeInterval(4 * 3600)
        let fallback = SnapshotEntry(date: fallbackDate, snapshot: current.snapshot, isPlaceholder: false)
        completion(Timeline(entries: [current, fallback], policy: .after(fallbackDate)))
    }

    private func currentEntry(at date: Date = .now) -> SnapshotEntry {
        SnapshotEntry(date: date, snapshot: AmbientSnapshotReader.read(), isPlaceholder: false)
    }
}
