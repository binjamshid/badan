import SwiftUI

/// The unified chronological spine: sleep, workouts, meds, symptoms, meals, notes and body
/// measurements gathered into one calm, day-grouped feed. Casual shows simple rows; power adds
/// multi-select type filters and a subtle per-row provenance hint. Same data, two altitudes.
@Observable
@MainActor
final class TimelineViewModel {
    var state: LoadState<[TimelineEvent]> = .loading

    /// Assembles the unified spine on a detached task (PERF-01) — Timeline's 7-store fan-out
    /// used to run synchronously on the main thread every time a relevant profile field
    /// changed. A cancelled load never clobbers state.
    func load(_ env: AppEnvironment) async {
        let assembler = TimelineAssembler(
            measurements: env.measurements, logging: env.logging, registry: env.registry,
            symptoms: env.symptoms, format: env.format, language: env.language,
            sensitiveModulesEnabled: env.profile.sensitiveModulesEnabled,
            nutritionEnabled: env.profile.nutritionEnabled, now: env.now())

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[TimelineEvent], Error> in
            do { return .success(try assembler.assemble()) } catch { return .failure(error) }
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let events):
            state = events.isEmpty ? .empty(env.s(Loc.noEventsInRange)) : .loaded(events)
        case .failure(let error):
            // The raw error goes to the debug log, not the UI (BUG-14) — users see one calm,
            // bilingual "couldn't load" message with a retry action instead of a Swift error
            // description as the screen's title.
            LoadErrorLog.log(error, screen: "Timeline")
            state = .error(env.s(LoadErrorCopy.message))
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
    @State private var searchText: String = ""

    // Cached derivation of the loaded events — recomputed only when the events, the type
    // filter, or the search text actually change, not on every unrelated re-render.
    @State private var days: [TimelineDay] = []
    @State private var typeCounts: [TimelineEventType: Int] = [:]
    @State private var presentTypesCache: [TimelineEventType] = []

    /// Only the profile fields that actually affect Timeline's rendered output — narrower than
    /// `env.profile` as a whole, so unrelated settings changes (notification prefs, home-module
    /// visibility, …) don't trigger a full 7-store reassemble.
    private struct RelevantProfileState: Equatable {
        let language: AppLanguage
        let arabicDigits: Bool
        let unitProfile: UnitProfileMode
        let depthPolicy: DepthPolicy
        let sensitiveModulesEnabled: Bool
        let nutritionEnabled: Bool
        /// BUG-12/13: folded into this screen's `.task(id:)` key alongside the profile fields
        /// above — a bumped `dataGeneration` forces the 7-store reassemble to re-run even when
        /// none of those settings changed (a HealthKit sync, a quick log elsewhere, etc). See
        /// `AppEnvironment.dataGeneration`.
        let dataGeneration: Int
    }

    private var relevantProfileState: RelevantProfileState {
        RelevantProfileState(
            language: env.profile.language,
            arabicDigits: env.profile.arabicDigits,
            unitProfile: env.profile.unitProfile,
            depthPolicy: env.profile.depthPolicy,
            sensitiveModulesEnabled: env.profile.sensitiveModulesEnabled,
            nutritionEnabled: env.profile.nutritionEnabled,
            dataGeneration: env.dataGeneration)
    }

    private var searchPrompt: LocalizedString {
        LocalizedString(en: "Search timeline", ar: "ابحث في السجل الزمني")
    }

    var body: some View {
        StatefulContainer(
            vm.state,
            retryTitle: env.s(LoadErrorCopy.retry),
            onRetry: { Task { await vm.load(env) } }
        ) { events in
            loaded(events)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.timeline))
        .searchable(text: $searchText, prompt: Text(searchPrompt.resolved(env.language)))
        // Reload the assembled read-model only when a field that actually affects Timeline's
        // rendered output changes (language, digits, units, depth, module toggles).
        .task(id: relevantProfileState) { await vm.load(env) }
        // Filters are a power affordance; switching away from power should clear a stale
        // selection instead of silently ignoring it while leaving it armed for next time.
        .onChange(of: env.depth) { _, newDepth in
            if !newDepth.showsPowerDetail { selectedTypes.removeAll() }
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func loaded(_ events: [TimelineEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if env.depth.showsPowerDetail {
                    filterBar()
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
        .onChange(of: events, initial: true) { _, newEvents in recompute(newEvents) }
        .onChange(of: selectedTypes) { _, _ in recompute(events) }
        .onChange(of: searchText) { _, _ in recompute(events) }
    }

    // MARK: - Derivation (single pass: filter + search + day-bucket + type counts)

    private func recompute(_ events: [TimelineEvent]) {
        let activeTypes = env.depth.showsPowerDetail ? selectedTypes : []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        var buckets: [String: [TimelineEvent]] = [:]
        var counts: [TimelineEventType: Int] = [:]
        var present: Set<TimelineEventType> = []

        for event in events {   // already sorted newest-first
            counts[event.type, default: 0] += 1
            present.insert(event.type)

            if !activeTypes.isEmpty, !activeTypes.contains(event.type) { continue }
            if !query.isEmpty, !matchesQuery(event, query) { continue }

            let key = DayAttribution.localDayKey(event.occurredAt, tz: event.tzId)
            buckets[key, default: []].append(event)
        }

        // "YYYY-MM-DD" sorts chronologically as a string; descending = newest day first.
        days = buckets.keys.sorted(by: >).map { TimelineDay(key: $0, events: buckets[$0] ?? []) }
        typeCounts = counts
        // Most-frequent type first, so the filters a user is most likely to want sit closest
        // to the leading edge of the (unindicated, scrollable) chip row.
        presentTypesCache = TimelineEventType.allCases
            .filter { present.contains($0) }
            .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    private func matchesQuery(_ event: TimelineEvent, _ query: String) -> Bool {
        let title = event.title.resolved(env.language)
        if title.localizedCaseInsensitiveContains(query) { return true }
        guard let subtitle = event.subtitle?.resolved(env.language) else { return false }
        return subtitle.localizedCaseInsensitiveContains(query)
    }

    // MARK: - Day sections & rows

    private func daySection(_ day: TimelineDay) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            dayHeader(day)
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

    /// A repeating in-list date divider, deliberately lighter than `SectionHeader`'s
    /// page-level title weight, with a trailing event-count summary so a busy day can be
    /// scanned without reading every row.
    private func dayHeader(_ day: TimelineDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            Text(env.s(dayLabel(day.key, tz: representativeTz(day))))
                .font(BadanFont.bodyCompact.weight(.semibold))
                .foregroundStyle(BadanColor.textPrimary)
            Spacer(minLength: BadanSpace.space2)
            Text(env.s(eventCountLabel(day.events.count)))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    /// A row is tappable when it has an obvious destination (UX-03): `.sleep`/`.measurement`
    /// events drill into the universal metric detail, `.medication` events drill into the
    /// medication log. Other kinds (workout, meal, symptom, note, insight) have no single clean
    /// destination today and stay non-tappable rather than linking somewhere misleading.
    @ViewBuilder
    private func eventRow(_ event: TimelineEvent) -> some View {
        if let metricId = navigationMetricId(for: event) {
            NavigationLink { MetricDetailScreen(metricId: metricId) } label: {
                eventRowContent(event, tappable: true)
            }
            .buttonStyle(.plain)
        } else if event.type == .medication {
            NavigationLink { MedicationLogView() } label: {
                eventRowContent(event, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            eventRowContent(event, tappable: false)
        }
    }

    /// `TimelineEvent` itself carries no `metricId` field — only `sourceRecordId` (a record id,
    /// not a metric id). `.measurement` events do encode their metric id as part of their own
    /// `id` (`"measurement:<metricId>:<sampleId>"`, see `TimelineAssembler.measurementEvent`),
    /// so it's recovered from there rather than requiring a `TimelineEvent`/`TimelineAssembler`
    /// model change outside this file's scope. `.sleep` events don't carry a per-row metric id
    /// at all, but every sleep event on this spine represents the same headline metric
    /// (`MetricID.timeAsleep`), so that's a safe fixed mapping.
    private func navigationMetricId(for event: TimelineEvent) -> String? {
        switch event.type {
        case .sleep:
            return MetricID.timeAsleep
        case .measurement:
            let parts = event.id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "measurement" else { return nil }
            return String(parts[1])
        default:
            return nil
        }
    }

    private func eventRowContent(_ event: TimelineEvent, tappable: Bool) -> some View {
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
                // Power-only: a quiet line naming where this row came from. Deliberately
                // smaller and softer than the subtitle above so provenance reads as its own
                // kind of annotation, not a second subtitle line.
                if env.depth.showsPowerDetail, let path = event.ingestionPath {
                    Label {
                        Text(path.displayLabel, language: env.language)
                    } icon: {
                        Image(systemName: "smallcircle.filled.circle")
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(BadanColor.textSecondary.opacity(0.8))
                }
            }

            Spacer(minLength: BadanSpace.space2)

            VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                if let valueText = event.valueText {
                    Text(valueText)
                        .font(BadanFont.bodyCompact.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(timeText(event.occurredAt, tz: event.tzId))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            .multilineTextAlignment(.trailing)

            // Matches the chevron affordance every other tappable row in the app already uses
            // (BodyPillarCard, BodyToolRow, InsightsWeeklyRow, …), so a tappable Timeline row
            // doesn't look identical to a dead-end one.
            if tappable {
                Image(systemName: "chevron.forward")
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: BadanSpace.touchMin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Filters (power only)

    private func filterBar() -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    ForEach(presentTypesCache, id: \.self) { type in
                        filterChip(type, count: typeCounts[type] ?? 0)
                    }
                }
                .padding(.horizontal, 2)
            }
            // A soft trailing fade hints that more chips exist off-screen when the row
            // overflows — the only affordance for that today, since indicators are hidden.
            .mask(filterScrollFadeMask)
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
        .animation(.default, value: selectedTypes)
    }

    private var filterScrollFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func filterChip(_ type: TimelineEventType, count: Int) -> some View {
        let isOn = selectedTypes.contains(type)
        return Button {
            if isOn { selectedTypes.remove(type) } else { selectedTypes.insert(type) }
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: type.symbolName)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text("\(type.displayName.resolved(env.language)) (\(env.format.integer(count)))")
                    .font(BadanFont.chip)
            }
            .foregroundStyle(isOn ? BadanColor.onPrimary : BadanColor.textSecondary)
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

    /// True when the only reason the list is empty is the search text — no type filters are
    /// active. Distinguished so the copy doesn't blame "filters" when the user never touched
    /// any (FIX-10).
    private var isSearchOnlyEmpty: Bool {
        selectedTypes.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let noMatchFilters = LocalizedString(
        en: "No events match your selected filters.",
        ar: "لا توجد أحداث مطابقة للتصفية المحددة.")
    private static let noMatchSearch = LocalizedString(
        en: "No events match your search.",
        ar: "لا توجد أحداث مطابقة لبحثك.")

    private var filteredEmptyState: some View {
        EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: env.s(Loc.noEventsInRange),
            message: env.s(isSearchOnlyEmpty ? Self.noMatchSearch : Self.noMatchFilters),
            // The clear action already resets both filters and search regardless of which
            // caused the empty result, so it stays a single shared action (FIX-10).
            actionTitle: env.s(Loc.clearFilters),
            action: {
                selectedTypes.removeAll()
                searchText = ""
            }
        )
    }

    private var historyStartFooter: some View {
        HStack(spacing: BadanSpace.space2) {
            Rectangle()
                .fill(BadanColor.separator)
                .frame(height: 1)
            Text(Loc.historyStart, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(BadanColor.separator)
                .frame(height: 1)
        }
        .padding(.top, BadanSpace.space2)
    }

    // MARK: - Formatting

    /// The day-bucket's own representative timezone (its events' recorded tz), used for both
    /// the day-key comparison and the "Today"/"Yesterday" special-casing below — so a
    /// traveling user's own recent history stays labeled relative to when it happened, not
    /// relative to the device's current location.
    private func representativeTz(_ day: TimelineDay) -> String {
        day.events.first?.tzId ?? TimeZone.current.identifier
    }

    private func dayLabel(_ key: String, tz: String) -> LocalizedString {
        let todayKey = DayAttribution.localDayKey(env.now(), tz: tz)
        let yesterdayKey = DayAttribution.localDayKey(DayAttribution.addingDays(-1, to: env.now(), tz: tz), tz: tz)
        if key == todayKey { return Loc.today }
        if key == yesterdayKey { return LocalizedString(en: "Yesterday", ar: "أمس") }
        guard let date = DayAttribution.date(fromDayKey: key, tz: tz) else {
            return LocalizedString(en: key, ar: key)
        }
        return LocalizedString(en: formattedDate(date, .en), ar: formattedDate(date, .ar))
    }

    private func eventCountLabel(_ count: Int) -> LocalizedString {
        switch count {
        case 1: return LocalizedString(en: "1 event", ar: "حدث واحد")
        case 2: return LocalizedString(en: "2 events", ar: "حدثان")
        default:
            let n = env.format.integer(count)
            return LocalizedString(en: "\(n) events", ar: "\(n) أحداث")
        }
    }

    // Cached formatter instances — reused and mutated per call rather than allocated fresh
    // per row/section on every render (a 21-day Timeline can render dozens of rows).
    private static let dayDateFormatter = DateFormatter()
    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func formattedDate(_ date: Date, _ language: AppLanguage) -> String {
        let f = Self.dayDateFormatter
        f.locale = Locale(identifier: language.localeIdentifier)
        f.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return f.string(from: date)
    }

    private func timeText(_ date: Date, tz: String) -> String {
        let f = Self.eventTimeFormatter
        f.locale = Locale(identifier: env.language.localeIdentifier)
        f.timeZone = TimeZone(identifier: tz) ?? .current
        return f.string(from: date)
    }
}
