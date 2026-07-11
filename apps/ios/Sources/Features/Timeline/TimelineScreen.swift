import SwiftUI

/// The unified chronological spine: sleep, workouts, meds, symptoms, meals, notes and body
/// measurements gathered into one calm, day-grouped feed. Casual shows simple rows; power adds
/// multi-select type filters and a subtle per-row provenance hint. Same data, two altitudes.
@Observable
@MainActor
final class TimelineViewModel {
    var state: LoadState<[TimelineEvent]> = .loading

    func load(_ env: AppEnvironment) {
        do {
            let events = try TimelineAssembler(env: env).assemble()
            state = events.isEmpty ? .empty(env.s(Loc.noEventsInRange)) : .loaded(events)
        } catch {
            state = .error(String(describing: error))
        }
    }
}

/// A day's worth of events, newest day first, newest event first within the day.
private struct TimelineDay: Identifiable {
    let key: String
    let events: [TimelineEvent]
    var id: String { key }
}

struct TimelineScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = TimelineViewModel()
    @State private var selectedTypes: Set<TimelineEventType> = []

    var body: some View {
        StatefulContainer(vm.state) { events in
            loaded(events)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.timeline))
        // Reload the assembled read-model whenever a presentation preference (language,
        // digits, units, depth) changes so every pre-formatted value re-localizes.
        .task(id: env.profile) { vm.load(env) }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func loaded(_ events: [TimelineEvent]) -> some View {
        let days = groupByDay(filtered(events))
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if env.depth.showsPowerDetail {
                    filterBar(events)
                }
                if days.isEmpty {
                    filteredEmptyState
                } else {
                    ForEach(days) { day in
                        daySection(day)
                    }
                    historyStartFooter
                }
            }
            .padding(BadanSpace.space4)
        }
    }

    // MARK: - Day sections & rows

    private func daySection(_ day: TimelineDay) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(dayLabel(day.key)))
            BadanCard {
                VStack(spacing: 0) {
                    ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 {
                            Rectangle()
                                .fill(BadanColor.separator)
                                .frame(height: 1)
                                .padding(.vertical, BadanSpace.space2)
                        }
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            Image(systemName: event.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(BadanColor.primary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(event.title, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                if let subtitle = event.subtitle {
                    Text(subtitle, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                // Power-only: a quiet line naming where this row came from.
                if env.depth.showsPowerDetail, let path = event.ingestionPath {
                    Label {
                        Text(path.displayLabel, language: env.language)
                    } icon: {
                        Image(systemName: "smallcircle.filled.circle")
                    }
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                }
            }

            Spacer(minLength: BadanSpace.space2)

            VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                if let valueText = event.valueText {
                    Text(valueText)
                        .font(BadanFont.bodyCompact.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                        .monospacedDigit()
                }
                Text(timeText(event.occurredAt, tz: event.tzId))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filters (power only)

    private func filterBar(_ events: [TimelineEvent]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    ForEach(presentTypes(events), id: \.self) { type in
                        filterChip(type)
                    }
                }
                .padding(.horizontal, 2)
            }
            if !selectedTypes.isEmpty {
                Button {
                    selectedTypes.removeAll()
                } label: {
                    Text(Loc.clearFilters, language: env.language)
                        .font(BadanFont.chip.weight(.medium))
                        .foregroundStyle(BadanColor.primary)
                        .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func filterChip(_ type: TimelineEventType) -> some View {
        let isOn = selectedTypes.contains(type)
        return Button {
            if isOn { selectedTypes.remove(type) } else { selectedTypes.insert(type) }
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: type.symbolName)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(type.displayName, language: env.language)
                    .font(BadanFont.chip)
            }
            .foregroundStyle(isOn ? Color.white : BadanColor.textSecondary)
            .padding(.horizontal, BadanSpace.space3)
            .padding(.vertical, BadanSpace.space2)
            .background(
                isOn ? BadanColor.primary : BadanColor.surfaceElevated,
                in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
            )
            .frame(minHeight: BadanSpace.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Empty & footer surfaces

    private var filteredEmptyState: some View {
        EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: env.s(Loc.noEventsInRange),
            message: "",
            actionTitle: env.s(Loc.clearFilters),
            action: { selectedTypes.removeAll() }
        )
    }

    private var historyStartFooter: some View {
        HStack {
            Spacer()
            Text(Loc.historyStart, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer()
        }
        .padding(.top, BadanSpace.space2)
    }

    // MARK: - Derivation helpers

    private func filtered(_ events: [TimelineEvent]) -> [TimelineEvent] {
        // Filters are a power affordance; casual always shows the full spine.
        let active = env.depth.showsPowerDetail ? selectedTypes : []
        guard !active.isEmpty else { return events }
        return events.filter { active.contains($0.type) }
    }

    private func presentTypes(_ events: [TimelineEvent]) -> [TimelineEventType] {
        let present = Set(events.map(\.type))
        return TimelineEventType.allCases.filter { present.contains($0) }
    }

    private func groupByDay(_ events: [TimelineEvent]) -> [TimelineDay] {
        var buckets: [String: [TimelineEvent]] = [:]
        for event in events {   // already sorted newest-first
            let key = DayAttribution.localDayKey(event.occurredAt, tz: event.tzId)
            buckets[key, default: []].append(event)
        }
        // "YYYY-MM-DD" sorts chronologically as a string; descending = newest day first.
        return buckets.keys.sorted(by: >).map { TimelineDay(key: $0, events: buckets[$0] ?? []) }
    }

    // MARK: - Formatting

    private func dayLabel(_ key: String) -> LocalizedString {
        let tz = TimeZone.current.identifier
        let todayKey = DayAttribution.localDayKey(env.now(), tz: tz)
        let yesterdayKey = DayAttribution.localDayKey(DayAttribution.addingDays(-1, to: env.now(), tz: tz), tz: tz)
        if key == todayKey { return Loc.today }
        if key == yesterdayKey { return LocalizedString(en: "Yesterday", ar: "أمس") }
        guard let date = DayAttribution.date(fromDayKey: key, tz: tz) else {
            return LocalizedString(en: key, ar: key)
        }
        return LocalizedString(en: formattedDate(date, .en), ar: formattedDate(date, .ar))
    }

    private func formattedDate(_ date: Date, _ language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter.string(from: date)
    }

    private func timeText(_ date: Date, tz: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.timeZone = TimeZone(identifier: tz) ?? .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
