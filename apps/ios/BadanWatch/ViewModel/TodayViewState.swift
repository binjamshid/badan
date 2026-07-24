import Foundation

/// Pure view-state builder for `TodayView` — no SwiftUI, no `WatchConnectivity`, so it is directly
/// unit-testable on this host without a watchOS simulator (see this slice's own test-coverage
/// note in `BadanWatchTests`). Takes exactly what `SnapshotReceiver` holds
/// (`AmbientSnapshotDto?`/`receivedAt`) plus `now`/`isArabic` and returns a plain value type the
/// view renders — the same "pure function of state" shape this codebase's `HomeData`/
/// `HomeEffortSummary` already are on the phone side, rebuilt fresh here since this target cannot
/// import `Features/Home/`.
struct TodayViewState: Equatable {
    struct Row: Equatable, Identifiable {
        enum Kind: Equatable { case readiness, effort, sleep }
        var id: Kind { kind }
        let kind: Kind
        let title: String
        /// Formatted value text ("72", "6h 45m") — `nil` when this row has no data at all, in
        /// which case the view shows `noDataText` instead. Never a fabricated placeholder number.
        let valueText: String?
        let provisional: Bool
        let noDataText: String
    }

    let rows: [Row]
    /// The one-true-sentence, already resolved to the right language — `nil` when the snapshot has
    /// none (never synced, or the phone genuinely had nothing to say yet).
    let sentence: String?
    let freshnessLabel: String
    /// True when a snapshot exists but is older than `SnapshotFreshness.staleAfter` — the view uses
    /// this to show a plain, non-alarming banner rather than presenting old numbers as current.
    let isStale: Bool
    /// True when this watch has never received a snapshot at all — distinct from `isStale` (a real
    /// snapshot that has merely aged) so the view can offer the right honest copy for each.
    let neverSynced: Bool

    static func build(
        snapshot: AmbientSnapshotDto?, now: Date, isArabic: Bool
    ) -> TodayViewState {
        let freshness = SnapshotFreshness.state(generatedAt: snapshot?.generatedAt, now: now)

        let rows = [
            Row(kind: .readiness,
                title: WatchStrings.readiness.resolved(isArabic: isArabic),
                valueText: snapshot?.readiness.map { "\(Int($0.score.rounded()))" },
                provisional: snapshot?.readiness?.provisional ?? false,
                noDataText: WatchStrings.noData.resolved(isArabic: isArabic)),
            Row(kind: .effort,
                title: WatchStrings.effort.resolved(isArabic: isArabic),
                valueText: snapshot?.effort.map { "\(Int($0.score.rounded()))" },
                provisional: snapshot?.effort?.provisional ?? false,
                noDataText: WatchStrings.noData.resolved(isArabic: isArabic)),
            Row(kind: .sleep,
                title: WatchStrings.sleep.resolved(isArabic: isArabic),
                valueText: snapshot?.sleep.map { durationText($0.durationMinutes, isArabic: isArabic) },
                provisional: snapshot?.sleep?.provisional ?? false,
                noDataText: WatchStrings.noSleepData.resolved(isArabic: isArabic)),
        ]

        let sentence = snapshot?.sentence.map { isArabic ? $0.ar : $0.en }

        let neverSynced: Bool
        let isStale: Bool
        let freshnessLabel: String
        switch freshness {
        case .neverSynced:
            neverSynced = true
            isStale = false
            freshnessLabel = WatchStrings.neverSynced.resolved(isArabic: isArabic)
        case .fresh:
            neverSynced = false
            isStale = false
            freshnessLabel = WatchStrings.updatedTemplate.resolved(isArabic: isArabic)
                .replacingOccurrences(of: "{time}", with: relativeGeneratedAt(snapshot, now: now, isArabic: isArabic))
        case .stale:
            neverSynced = false
            isStale = true
            freshnessLabel = WatchStrings.staleTemplate.resolved(isArabic: isArabic)
                .replacingOccurrences(of: "{time}", with: relativeGeneratedAt(snapshot, now: now, isArabic: isArabic))
        }

        return TodayViewState(rows: rows, sentence: sentence, freshnessLabel: freshnessLabel,
                              isStale: isStale, neverSynced: neverSynced)
    }

    private static func relativeGeneratedAt(_ snapshot: AmbientSnapshotDto?, now: Date, isArabic: Bool) -> String {
        // `.fresh`/`.stale` only ever get built when `snapshot` (and so `generatedAt`) is non-nil
        // (see `SnapshotFreshness.state`) — `now` is an honest, harmless fallback that this branch
        // should never actually reach.
        SnapshotFreshness.relativeLabel(snapshot?.generatedAt ?? now, isArabic: isArabic, now: now)
    }

    /// `DateComponentsFormatter` rather than a hand-rolled "Xh Ym" string, so the Arabic rendering
    /// is grammatically real localized output — mirrors `SleepCardWidgetView.durationText`
    /// (`BadanWidgets/SleepCardWidget.swift`) exactly; this target cannot import that file (separate
    /// watchOS module) so the few lines are duplicated rather than shared.
    static func durationText(_ minutes: Int, isArabic: Bool) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: isArabic ? "ar" : "en_US")
        formatter.calendar = calendar
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        return formatter.string(from: components) ?? "\(minutes)m"
    }
}
