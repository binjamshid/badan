import SwiftUI

// MARK: - Copy

private enum MetricVisibilityCopy {
    static let title = LocalizedString(en: "Metrics", ar: "المؤشرات")
    static let blurb = LocalizedString(
        en: "Choose which metrics you browse, and pin up to 8 to the top of Home.",
        ar: "اختر المؤشرات التي تتصفّحها، وثبّت حتى ٨ منها أعلى الصفحة الرئيسية.")
    /// The guardrail, stated to the user rather than only enforced in code. A person tidying a long
    /// list needs to know they are not deleting anything — otherwise "hide" reads as "stop
    /// collecting", and the readings they'd lose are ones Health will not hand over again later.
    static let hidingIsPresentationOnly = LocalizedString(
        en: "Hiding a metric only affects browsing. BADAN keeps recording it, keeps calculating "
          + "with it, and still includes it in exports — and you can always find it here or by "
          + "typing its name in search.",
        ar: "إخفاء المؤشر يؤثّر على التصفّح فقط. يواصل بادن تسجيله والحساب به وإدراجه في "
          + "التصدير — ويمكنك دائماً إيجاده هنا أو بكتابة اسمه في البحث.")
    static let noMatches = LocalizedString(en: "No matching metrics", ar: "لا مؤشرات مطابقة")
    static let clearSearch = LocalizedString(en: "Clear search", ar: "مسح البحث")
    static let pinnedSection = LocalizedString(en: "Pinned to Home", ar: "مثبّت في الرئيسية")
    static let pinFull = LocalizedString(
        en: "Home shows up to 8 pinned metrics. Unpin one to add another.",
        ar: "تعرض الرئيسية حتى ٨ مؤشرات مثبّتة. ألغِ تثبيت أحدها لإضافة غيره.")
    static let shown = LocalizedString(en: "Shown", ar: "ظاهر")
    static let hidden = LocalizedString(en: "Hidden", ar: "مخفي")
    static let pin = LocalizedString(en: "Pin to Home", ar: "تثبيت في الرئيسية")
    static let unpin = LocalizedString(en: "Unpin from Home", ar: "إلغاء التثبيت")
    static let pinned = LocalizedString(en: "Pinned", ar: "مثبّت")
    static let hide = LocalizedString(en: "Hide", ar: "إخفاء")
    static let show = LocalizedString(en: "Show", ar: "إظهار")

    static func hiddenCount(_ n: String) -> LocalizedString {
        LocalizedString(en: "\(n) hidden", ar: "\(n) مخفي")
    }
}

/// Settings → Personalization → Metrics. The customization surface development priority #2 named
/// (D-35), at metric granularity rather than the seven-module granularity `HomeModule` offers.
///
/// Built on `ExportMetricPickerScreen`'s shape — same registry-backed search (`MetricRegistry.search`,
/// so folding and Arabic tashkeel behave identically everywhere), same family grouping and order,
/// same row treatment — with a second per-row control for pinning.
///
/// **This screen never filters by `hiddenMetricIds`.** It is the way back: a metric hidden here has
/// to remain findable here, or hiding becomes a trap with no undo. Search is the other way back, and
/// it is likewise unfiltered.
struct MetricVisibilityScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    LText(MetricVisibilityCopy.blurb)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    LText(MetricVisibilityCopy.hidingIsPresentationOnly)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(BadanColor.surface)
            }

            // The pinned set, in the user's own order, so "what is on my Home" is answerable
            // without scrolling the whole registry looking for filled pins.
            if !env.profile.pinnedMetricIds.isEmpty {
                Section {
                    ForEach(pinnedDefinitions) { def in
                        row(def).listRowBackground(BadanColor.surface)
                    }
                } header: {
                    sectionHeader(env.s(MetricVisibilityCopy.pinnedSection))
                } footer: {
                    if !env.profile.canPinMore {
                        LText(MetricVisibilityCopy.pinFull)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }

            if groups.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: env.s(MetricVisibilityCopy.noMatches),
                    message: "",
                    actionTitle: query.isEmpty ? nil : env.s(MetricVisibilityCopy.clearSearch),
                    action: query.isEmpty ? nil : { query = "" })
                .listRowBackground(BadanColor.surface)
                .listRowSeparator(.hidden)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.metrics) { def in
                            row(def).listRowBackground(BadanColor.surface)
                        }
                    } header: {
                        sectionHeader(env.s(group.family.displayName))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BadanColor.background.ignoresSafeArea())
        .searchable(text: $query, prompt: Text(Loc.search, language: env.language))
        .navigationTitle(env.s(MetricVisibilityCopy.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(BadanFont.sectionTitle)
            .foregroundStyle(BadanColor.textPrimary)
            .textCase(nil)
    }

    private func row(_ def: MetricDefinition) -> some View {
        let isHidden = env.profile.isMetricHidden(def.metricId)
        let isPinned = env.profile.isMetricPinned(def.metricId)
        // Pinning is unavailable at the cap, but never for a metric that is already pinned —
        // otherwise the control that unpins it would be the one disabled.
        let canPin = isPinned || env.profile.canPinMore

        return HStack(spacing: BadanSpace.space3) {
            Image(systemName: def.familyGroup.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(isHidden ? BadanColor.textSecondary : BadanColor.primary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(def.label(depth: env.depth, language: env.language))
                    .font(BadanFont.body)
                    .foregroundStyle(isHidden ? BadanColor.textSecondary : BadanColor.textPrimary)
                if env.depth.showsPowerDetail {
                    Text(def.metricId)
                        .font(BadanFont.caption.monospaced())
                        .foregroundStyle(BadanColor.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            Spacer(minLength: BadanSpace.space2)

            Button { togglePin(def.metricId) } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 15))
                    .foregroundStyle(isPinned ? BadanColor.primary
                                              : (canPin ? BadanColor.separator : BadanColor.separator.opacity(0.4)))
                    .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPin)
            .accessibilityLabel(env.s(isPinned ? MetricVisibilityCopy.unpin : MetricVisibilityCopy.pin))

            Button { toggleHidden(def.metricId) } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 15))
                    .foregroundStyle(isHidden ? BadanColor.textSecondary : BadanColor.primary)
                    .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(env.s(isHidden ? MetricVisibilityCopy.show : MetricVisibilityCopy.hide))
        }
        .padding(.vertical, BadanSpace.space1)
        // State is otherwise conveyed by icon shape and colour alone; spelling it out keeps it
        // audible to VoiceOver and legible without colour (§16: status not colour-only).
        .accessibilityElement(children: .combine)
        .accessibilityValue(rowValue(isHidden: isHidden, isPinned: isPinned))
    }

    private func rowValue(isHidden: Bool, isPinned: Bool) -> String {
        var parts = [env.s(isHidden ? MetricVisibilityCopy.hidden : MetricVisibilityCopy.shown)]
        if isPinned { parts.append(env.s(MetricVisibilityCopy.pinned)) }
        return parts.joined(separator: ", ")
    }

    // MARK: Mutations

    // `pinMetric`/`hideMetric` resolve the pinned-and-hidden contradiction themselves, so these
    // stay thin — see `CustomizationProfile`'s own docs for which side wins and why.
    private func togglePin(_ metricId: String) {
        env.update { profile in
            if profile.isMetricPinned(metricId) { profile.unpinMetric(metricId) }
            else { profile.pinMetric(metricId) }
        }
    }

    private func toggleHidden(_ metricId: String) {
        env.update { profile in
            if profile.isMetricHidden(metricId) { profile.unhideMetric(metricId) }
            else { profile.hideMetric(metricId) }
        }
    }

    // MARK: Data

    /// Pin order is array order, so this maps rather than sorts. Ids with no registry definition
    /// (a metric withdrawn by an app update) are dropped from the display without being unpinned —
    /// silently rewriting stored preferences on a read is how a downgrade loses a user's layout.
    private var pinnedDefinitions: [MetricDefinition] {
        env.profile.pinnedMetricIds.compactMap { env.registry.definition($0) }
    }

    private var results: [MetricDefinition] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? env.registry.all : env.registry.search(query)
    }

    // Same grouping/order as `BodyAllMetricsBrowser` and `ExportMetricPickerScreen`.
    private var groups: [MetricVisibilityGroup] {
        Dictionary(grouping: results, by: { $0.familyGroup })
            .map { MetricVisibilityGroup(family: $0.key, metrics: $0.value.sorted { $0.metricId < $1.metricId }) }
            .sorted { orderIndex($0.family) < orderIndex($1.family) }
    }

    private func orderIndex(_ family: MetricFamily) -> Int {
        MetricFamily.allCases.firstIndex(of: family) ?? MetricFamily.allCases.count
    }
}

private struct MetricVisibilityGroup: Identifiable {
    let family: MetricFamily
    let metrics: [MetricDefinition]
    var id: String { family.rawValue }
}
