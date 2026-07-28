import SwiftUI

/// The watch app's one glanceable "today" screen (A22/EPIC-42 scope: "a glanceable today view...
/// reachable navigation to see a bit more detail than a widget can show"). Renders Readiness,
/// Effort, and Sleep — the SAME three cards `HomeScreen`'s flagship first screen leads with on the
/// phone (`ReadinessHeroCard`/`EffortCard`/`SleepModuleCard`) — off whatever `SnapshotReceiver`
/// currently holds. This view computes nothing itself; `TodayViewState.build` (a pure function,
/// unit-tested in `BadanWatchTests`) owns every bit of that logic.
struct TodayView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let receiver = SnapshotReceiver.shared
    @State private var now = Date()
    /// Whether a refresh request was handed to the system this session. Reset on foreground so the
    /// confirmation does not linger from a previous glance.
    @State private var syncRequested = false

    private var isArabic: Bool { WatchLanguage.isArabic(for: receiver.snapshot) }
    private var state: TodayViewState {
        TodayViewState.build(snapshot: receiver.snapshot, now: now, isArabic: isArabic)
    }

    var body: some View {
        NavigationStack {
            List {
                if state.neverSynced || state.isStale {
                    FreshnessBanner(text: state.freshnessLabel, isNeverSynced: state.neverSynced,
                                    isArabic: isArabic)
                        .listRowBackground(Color.clear)
                }
                ForEach(state.rows) { row in
                    NavigationLink {
                        WatchMetricDetailView(kind: row.kind, snapshot: receiver.snapshot,
                                              freshnessLabel: state.freshnessLabel,
                                              isStale: state.isStale, isArabic: isArabic)
                    } label: {
                        TodayRow(row: row, isArabic: isArabic)
                    }
                }
                if let sentence = state.sentence {
                    Section {
                        Text(sentence)
                            .font(.footnote)
                            .multilineTextAlignment(isArabic ? .trailing : .leading)
                    }
                }
                Section {
                    Button {
                        syncRequested = receiver.requestRefresh()
                    } label: {
                        Label(WatchStrings.syncNow.resolved(isArabic: isArabic),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    if syncRequested {
                        // The watch cannot report on the phone's progress — the refreshed snapshot
                        // arrives later through the ordinary one-way push, and may be queued until
                        // the phone next wakes. So this confirms the ASK was sent, and says nothing
                        // about when data will land, because it does not know.
                        Text(WatchStrings.syncRequested.resolved(isArabic: isArabic))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(WatchStrings.todayTitle.resolved(isArabic: isArabic))
        }
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
        .onAppear { now = .now }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { now = .now }
        }
    }
}

/// One row of the today list — a title, a big value (or an honest "no data yet"), and a
/// provisional marker when the underlying value hasn't settled yet. Mirrors the SAME
/// nil-vs-value discipline every `BadanWidgets` widget view already follows: never a fabricated
/// number standing in for a real gap.
private struct TodayRow: View {
    let row: TodayViewState.Row
    let isArabic: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let valueText = row.valueText {
                    HStack(spacing: 4) {
                        Text(valueText)
                            .font(.title3.weight(.semibold))
                        if row.provisional {
                            Text(WatchStrings.provisional.resolved(isArabic: isArabic))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(row.noDataText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
