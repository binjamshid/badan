import SwiftUI

// MARK: - Copy

private enum MetricPickerCopy {
    static let title = LocalizedString(en: "Choose metrics", ar: "اختيار المؤشرات")
    static let allSelected = LocalizedString(
        en: "Every metric is included. Tap any below to narrow it down.",
        ar: "كل المؤشرات مُدرجة. اضغط أياً منها أدناه للتضييق.")
    static let clear = LocalizedString(en: "Reset to all", ar: "إعادة الكل")
    static let noMatches = LocalizedString(en: "No matching metrics", ar: "لا مؤشرات مطابقة")
    static let clearSearch = LocalizedString(en: "Clear search", ar: "مسح البحث")

    static func selectedCount(_ n: String) -> LocalizedString {
        LocalizedString(en: "\(n) metrics selected", ar: "\(n) مؤشرات محددة")
    }
    /// VoiceOver row value — a metric is "selected" or "not selected" spoken plainly, independent
    /// of the checkmark's colour (§16: status not color-only).
    static let rowSelected = LocalizedString(en: "Selected", ar: "محدد")
}

/// EPIC-11 — the searchable metric multi-select for the advanced builder.
///
/// It reuses the registry's own search (`MetricRegistry.search`) — the exact index behind
/// `BodyAllMetricsBrowser` — rather than standing up a second one, so a query behaves identically
/// in both places (case/diacritic folding, Arabic tashkeel handling, id + en + ar + precise-label
/// matching). The only thing this screen adds over that browser is selection.
///
/// **Empty selection means "every metric".** The builder converts an empty set to
/// `ExportScope.metricIds = nil` (the registry's "all" sentinel), matching how the sources picker
/// treats `sourceIds`. An export with zero metrics would be an empty file that looks like data
/// loss; "none chosen = all" is the reading that can never produce that surprise.
struct ExportMetricPickerScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: Set<String>
    @State private var query = ""

    var body: some View {
        List {
            Section {
                Text(headerText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .listRowBackground(BadanColor.surface)
            }
            if groups.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: env.s(MetricPickerCopy.noMatches),
                    message: "",
                    actionTitle: query.isEmpty ? nil : env.s(MetricPickerCopy.clearSearch),
                    action: query.isEmpty ? nil : { query = "" })
                .listRowBackground(BadanColor.surface)
                .listRowSeparator(.hidden)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.metrics) { def in
                            row(def)
                                .listRowBackground(BadanColor.surface)
                        }
                    } header: {
                        Text(env.s(group.family.displayName))
                            .font(BadanFont.sectionTitle)
                            .foregroundStyle(BadanColor.textPrimary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BadanColor.background.ignoresSafeArea())
        .searchable(text: $query, prompt: Text(Loc.search, language: env.language))
        .navigationTitle(env.s(MetricPickerCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(env.s(MetricPickerCopy.clear)) { selection.removeAll() }
                        .font(BadanFont.link)
                        .foregroundStyle(BadanColor.primary)
                }
            }
        }
    }

    private var headerText: String {
        selection.isEmpty
            ? env.s(MetricPickerCopy.allSelected)
            : env.s(MetricPickerCopy.selectedCount(env.format.integer(selection.count)))
    }

    private func row(_ def: MetricDefinition) -> some View {
        let isSelected = selection.contains(def.metricId)
        return Button {
            if isSelected { selection.remove(def.metricId) } else { selection.insert(def.metricId) }
        } label: {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.separator)
                    .accessibilityHidden(true)
                Image(systemName: def.familyGroup.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(BadanColor.primary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(def.label(depth: env.depth, language: env.language))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    if env.depth.showsPowerDetail {
                        Text(def.metricId)
                            .font(BadanFont.caption.monospaced())
                            .foregroundStyle(BadanColor.textSecondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                Spacer(minLength: BadanSpace.space2)
            }
            .padding(.vertical, BadanSpace.space1)
            .frame(minHeight: BadanSpace.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Selection is otherwise conveyed only by the checkmark's colour; the trait + value make it
        // audible to VoiceOver (A1).
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? env.s(MetricPickerCopy.rowSelected) : "")
    }

    // Same grouping/order as `BodyAllMetricsBrowser` so the two read alike.
    private var results: [MetricDefinition] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? env.registry.all : env.registry.search(query)
    }

    private var groups: [ExportMetricGroup] {
        Dictionary(grouping: results, by: { $0.familyGroup })
            .map { ExportMetricGroup(family: $0.key, metrics: $0.value.sorted { $0.metricId < $1.metricId }) }
            .sorted { orderIndex($0.family) < orderIndex($1.family) }
    }

    private func orderIndex(_ family: MetricFamily) -> Int {
        MetricFamily.allCases.firstIndex(of: family) ?? MetricFamily.allCases.count
    }
}

private struct ExportMetricGroup: Identifiable {
    let family: MetricFamily
    let metrics: [MetricDefinition]
    var id: String { family.rawValue }
}
