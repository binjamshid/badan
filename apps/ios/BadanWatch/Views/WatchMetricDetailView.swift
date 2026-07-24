import SwiftUI

/// The "reachable navigation to see a bit more detail than a widget can show" screen (A22/EPIC-42
/// scope). A widget has room for one number; this screen adds: a short, static, generic explainer
/// sentence for what the metric IS (never a personalized/fabricated guidance sentence — those are
/// phone-computed and not part of the bounded snapshot), an honest freshness line, and — for sleep
/// specifically — both duration AND score together, where `TodayView`'s summary row only has room
/// for the duration.
struct WatchMetricDetailView: View {
    let kind: TodayViewState.Row.Kind
    let snapshot: AmbientSnapshotDto?
    let freshnessLabel: String
    let isStale: Bool
    let isArabic: Bool

    private var title: String {
        switch kind {
        case .readiness: return WatchStrings.readiness.resolved(isArabic: isArabic)
        case .effort: return WatchStrings.effort.resolved(isArabic: isArabic)
        case .sleep: return WatchStrings.sleep.resolved(isArabic: isArabic)
        }
    }

    private var explainer: String {
        switch kind {
        case .readiness: return WatchStrings.readinessExplainer.resolved(isArabic: isArabic)
        case .effort: return WatchStrings.effortExplainer.resolved(isArabic: isArabic)
        case .sleep: return WatchStrings.sleepExplainer.resolved(isArabic: isArabic)
        }
    }

    private var provisional: Bool {
        switch kind {
        case .readiness: return snapshot?.readiness?.provisional ?? false
        case .effort: return snapshot?.effort?.provisional ?? false
        case .sleep: return snapshot?.sleep?.provisional ?? false
        }
    }

    /// The big headline value — never a fabricated stand-in when the underlying data is missing.
    private var valueText: String? {
        switch kind {
        case .readiness: return snapshot?.readiness.map { "\(Int($0.score.rounded()))" }
        case .effort: return snapshot?.effort.map { "\(Int($0.score.rounded()))" }
        case .sleep: return snapshot?.sleep.map { TodayViewState.durationText($0.durationMinutes, isArabic: isArabic) }
        }
    }

    private var noDataText: String {
        kind == .sleep
            ? WatchStrings.noSleepData.resolved(isArabic: isArabic)
            : WatchStrings.noData.resolved(isArabic: isArabic)
    }

    /// Sleep's own extra second line (score, when available) — the one place this screen shows
    /// something `TodayView`'s summary row has no room for.
    private var sleepScoreText: String? {
        guard kind == .sleep, let score = snapshot?.sleep?.score else { return nil }
        return "\(Int(score.rounded()))/100"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let valueText {
                    HStack(spacing: 6) {
                        Text(valueText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                        if provisional {
                            Text(WatchStrings.provisional.resolved(isArabic: isArabic))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let sleepScoreText {
                        Text(sleepScoreText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(noDataText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(explainer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Divider()
                Text(freshnessLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(isArabic ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle(title)
    }
}
