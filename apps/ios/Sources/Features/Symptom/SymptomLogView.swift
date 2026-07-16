import SwiftUI

// MARK: - Screen-local bilingual strings

/// Strings only the symptom-capture surface needs. Shared vocabulary comes from `Loc`; these
/// fill the gaps with real Arabic. Wording is calm and non-judgmental — logging a symptom is
/// never framed as a failure.
private enum SymptomLogStrings {
    static let privateNote = LocalizedString(
        en: "Private to you — just for your own record.",
        ar: "خاص بك — مجرّد سجلّك الشخصي.")
    static let noMatches = LocalizedString(en: "No matches", ar: "لا نتائج مطابقة")
    static let change = LocalizedString(en: "Change", ar: "تغيير")
    static let whenLabel = LocalizedString(en: "When", ar: "الوقت")
    static let addTrigger = LocalizedString(en: "Add a trigger", ar: "أضف محفزاً")
    static let details = LocalizedString(en: "Record details", ar: "تفاصيل السجل")
    static let selfReport = LocalizedString(en: "Saved as a manual self-report.", ar: "محفوظ كإدخال ذاتي يدوي.")
    static let deviceOnly = LocalizedString(en: "Stays on this device only.", ar: "يبقى على هذا الجهاز فقط.")
    static let timeZone = LocalizedString(en: "Time zone", ar: "المنطقة الزمنية")
    static let yesterday = LocalizedString(en: "Yesterday", ar: "أمس")
    static let saveErrorTitle = LocalizedString(en: "Couldn’t save — try again.", ar: "تعذّر الحفظ — حاول مرة أخرى.")
    static let loadErrorTitle = LocalizedString(en: "Couldn’t load your symptoms right now.", ar: "تعذّر تحميل أعراضك الآن.")
    static let savedConfirmation = LocalizedString(en: "Saved", ar: "تم الحفظ")
    static let oldDateNotice = LocalizedString(
        en: "That’s a while back — double check the date.",
        ar: "هذا تاريخ بعيد نسبياً — تحقق منه.")
    static let ofScale = LocalizedString(en: "of 10", ar: "من 10")
    static let trendTitle = LocalizedString(en: "Your symptom trend", ar: "اتجاه أعراضك")
    static let trendCountLabel = LocalizedString(en: "Logged", ar: "المسجّل")
    static let trendSeverityLabel = LocalizedString(en: "Average severity", ar: "متوسط الشدة")

    static func logCustom(_ query: String) -> LocalizedString {
        LocalizedString(en: "Log “\(query)”", ar: "تسجيل «\(query)»")
    }

    /// Bilingual label for a symptom-dictionary category key.
    static func categoryName(_ key: String) -> LocalizedString {
        switch key {
        case "general": return LocalizedString(en: "General", ar: "عام")
        case "head": return LocalizedString(en: "Head", ar: "الرأس")
        case "digestive": return LocalizedString(en: "Digestive", ar: "الجهاز الهضمي")
        case "respiratory": return LocalizedString(en: "Respiratory", ar: "الجهاز التنفسي")
        case "musculoskeletal": return LocalizedString(en: "Muscles & joints", ar: "العضلات والمفاصل")
        case "mental": return LocalizedString(en: "Mood & mind", ar: "المزاج والذهن")
        case "sleep": return LocalizedString(en: "Sleep", ar: "النوم")
        case "skin": return LocalizedString(en: "Skin", ar: "الجلد")
        default: return LocalizedString(en: key.capitalized, ar: key)
        }
    }

    /// A few gentle, optional trigger suggestions — free chips still allow anything.
    static let triggerSuggestions: [LocalizedString] = [
        LocalizedString(en: "Stress", ar: "توتر"),
        LocalizedString(en: "Poor sleep", ar: "سوء النوم"),
        LocalizedString(en: "Food", ar: "طعام"),
        LocalizedString(en: "Caffeine", ar: "كافيين"),
        LocalizedString(en: "Dehydration", ar: "جفاف"),
        LocalizedString(en: "Screen time", ar: "وقت الشاشة"),
        LocalizedString(en: "Weather", ar: "الطقس"),
    ]
}

// MARK: - Choice model

/// What the user is about to log: a canonical dictionary symptom, or a free-text custom label
/// for anything not listed.
private enum SymptomChoice: Equatable {
    case known(SymptomDefinition)
    case custom(String)

    var displayName: LocalizedString {
        switch self {
        case .known(let def): return def.displayName
        case .custom(let label): return LocalizedString(en: label, ar: label)
        }
    }

    var symptomId: String? { if case .known(let def) = self { return def.id }; return nil }
    var customLabel: String? { if case .custom(let label) = self { return label }; return nil }
}

// MARK: - Loaded data

/// Everything the picker needs, gathered once: the distinct symptoms logged in the last 30
/// days (for 2-tap re-log) plus the full dictionary grouped into category sections.
struct SymptomLogData {
    var recents: [SymptomDefinition]
    var categories: [(key: String, items: [SymptomDefinition])]
    /// Distinct free-text triggers used in the last 30 days, for lightweight autocomplete
    /// alongside the fixed suggestion chips (FEAT-199).
    var recentTriggers: [String] = []
    /// Small "your symptom trend" summary — 14-day count + average severity, computed directly
    /// from the sensitive symptom store (see `SymptomLogViewModel.trendAggregates`), not a
    /// derived-metrics-registry read (FEAT-161 / STUB-05).
    var trendCount: Int?
    var trendSeverityAvg: Double?
}

// MARK: - View model

@Observable
@MainActor
final class SymptomLogViewModel {
    var state: LoadState<SymptomLogData> = .loading

    /// Distinct recently-logged symptoms (most recent first) + the categorized dictionary.
    func load(_ env: AppEnvironment) {
        do {
            let now = env.now()
            let from = now.addingTimeInterval(-30 * 86_400)
            let recentEntries = try env.logging.symptoms(from: from, to: now)

            var seen = Set<String>()
            var recents: [SymptomDefinition] = []
            for entry in recentEntries {
                guard let id = entry.symptomId, !seen.contains(id),
                      let def = env.symptoms.definition(id) else { continue }
                seen.insert(id)
                recents.append(def)
            }

            let categories = env.symptoms.categories.map { key in
                (key: key, items: env.symptoms.inCategory(key))
            }

            // Distinct past free-text triggers, for lightweight autocomplete (FEAT-199).
            let recentTriggers = Array(Set(recentEntries.flatMap(\.triggers))).sorted()

            // A small "your symptom trend" summary over the last 14 days (FEAT-161), computed
            // directly from the already-loaded 30-day `recentEntries` window rather than reading
            // a "symptoms.count"/"symptoms.severity_avg" derived series — nothing ever produces
            // those series, and nothing ever could: symptoms live in the sensitive DB, which the
            // main-DB derivation engine has no handle to, so that read was permanently dead
            // (STUB-05). Computed here instead — still entirely within the sensitive store,
            // nothing derived is written back to the main DB.
            let (trendCount, trendSeverityAvg) = Self.trendAggregates(
                from: recentEntries, windowStart: now.addingTimeInterval(-14 * 86_400))

            let data = SymptomLogData(
                recents: recents,
                categories: categories,
                recentTriggers: recentTriggers,
                trendCount: trendCount,
                trendSeverityAvg: trendSeverityAvg)
            state = (recents.isEmpty && categories.isEmpty)
                ? .empty(env.s(Loc.chooseSymptom))
                : .loaded(data)
        } catch {
            state = .error(env.s(SymptomLogStrings.loadErrorTitle))
        }
    }

    /// Pure count + average-severity aggregation over `entries` occurring at or after
    /// `windowStart` — factored out of `load(_:)` so it's directly testable without a database
    /// or `AppEnvironment` (STUB-05). `nil` for both when the window has no entries, matching
    /// the trend card's existing "hide when there's nothing to show" behavior.
    nonisolated static func trendAggregates(from entries: [SymptomEntry], windowStart: Date) -> (count: Int?, severityAvg: Double?) {
        let windowed = entries.filter { $0.occurredAt >= windowStart }
        guard !windowed.isEmpty else { return (nil, nil) }
        let avg = Double(windowed.reduce(0) { $0 + $1.severity }) / Double(windowed.count)
        return (windowed.count, avg)
    }

    /// After a successful save, fold the just-logged symptom into `recents` in place instead
    /// of re-fetching and re-deduping the full 30-day window — keeps the "Save & add another"
    /// loop fast (PERF-066). No-op for custom (non-dictionary) labels, which never populate
    /// `recents`.
    fileprivate func prependRecent(_ choice: SymptomChoice) {
        guard case .loaded(var data) = state, case .known(let def) = choice else { return }
        data.recents.removeAll { $0.id == def.id }
        data.recents.insert(def, at: 0)
        state = .loaded(data)
    }
}

// MARK: - Screen

/// Under-10-second symptom capture, pushed as its own screen. Pick from recents (2 taps) or
/// search / browse categories, set a calm severity, add optional triggers + a note, optionally
/// backdate, then save. Sensitive by nature — private, judgment-free, never alarming.
struct SymptomLogView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = SymptomLogViewModel()

    // Capture state
    @State private var selection: SymptomChoice?
    @State private var searchText: String = ""
    @State private var severity: Double = 3
    @State private var triggers: [String] = []
    @State private var newTrigger: String = ""
    @State private var note: String = ""
    @State private var occurredAt: Date = Date()
    @State private var maxDate: Date = Date()
    /// Snapshotted once at screen entry, not read live at save time (OPT-110).
    @State private var tz: String = TimeZone.current.identifier

    // Save-flow state
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    @State private var savedTick: Int = 0
    @State private var showSavedToast: Bool = false

    var body: some View {
        ScrollView {
            StatefulContainer(vm.state) { data in
                Group {
                    if let selection {
                        captureForm(selection, recentTriggers: data.recentTriggers)
                    } else {
                        picker(data)
                    }
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logSymptom))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if let selection {
                saveButtons(selection)
                    .padding(.horizontal, BadanSpace.space4)
                    .padding(.top, BadanSpace.space3)
                    .padding(.bottom, BadanSpace.space2)
                    .background(.bar)
            }
        }
        .overlay(alignment: .top) {
            if showSavedToast {
                savedToast
                    .padding(.top, BadanSpace.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSavedToast)
        .sensoryFeedback(.success, trigger: savedTick)
        .task {
            tz = TimeZone.current.identifier
            maxDate = env.now()
            if selection == nil { occurredAt = env.now() }
            vm.load(env)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Keep the "cannot log the future" upper bound live across backgrounding, not
            // frozen at first appearance (OPT-109 / UIUX-122).
            if newPhase == .active { maxDate = env.now() }
        }
    }

    private var savedToast: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(env.s(SymptomLogStrings.savedConfirmation))
                .font(BadanFont.bodyCompact.weight(.medium))
                .foregroundStyle(BadanColor.textPrimary)
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(BadanColor.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Picker (choose a symptom)

    @ViewBuilder
    private func picker(_ data: SymptomLogData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            Text(env.s(SymptomLogStrings.privateNote))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)

            if data.trendCount != nil || data.trendSeverityAvg != nil {
                trendCard(data)
            }

            searchField

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                searchResults(query: query)
            } else {
                if !data.recents.isEmpty {
                    recentsSection(data.recents)
                }
                categorySections(data.categories)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            TextField(env.s(Loc.chooseSymptom), text: $searchText)
                .font(BadanFont.body)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                .accessibilityLabel(env.s(Loc.close))
            }
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
    }

    @ViewBuilder
    private func searchResults(query: String) -> some View {
        let results = env.symptoms.search(query)
        // Suppress the free-text "Log '<query>'" option when it's a near-exact match of a
        // dictionary symptom already listed above, so typing "migraine" doesn't create a
        // second, fragmented identity next to the canonical "Migraine" row (OPT-112).
        let hasExactDictionaryMatch = results.contains {
            env.s($0.displayName).localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            ForEach(results) { def in
                resultRow(def)
            }
            if results.isEmpty {
                Text(env.s(SymptomLogStrings.noMatches))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .padding(.vertical, BadanSpace.space1)
            }
            // Free-text custom label — anything not in the dictionary is still loggable.
            if !hasExactDictionaryMatch {
                customResultRow(query)
            }
        }
    }

    private func resultRow(_ def: SymptomDefinition) -> some View {
        Button {
            select(.known(def))
        } label: {
            HStack(spacing: BadanSpace.space3) {
                Text(env.s(def.displayName))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                Text(env.s(SymptomLogStrings.categoryName(def.category)))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .padding(.horizontal, BadanSpace.cardPadding)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                    .strokeBorder(BadanColor.separator, lineWidth: 1))
        }
    }

    private func customResultRow(_ query: String) -> some View {
        Button {
            select(.custom(query))
        } label: {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(env.s(SymptomLogStrings.logCustom(query)))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.primary)
                Spacer(minLength: BadanSpace.space2)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .padding(.horizontal, BadanSpace.cardPadding)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                    .strokeBorder(BadanColor.separator, lineWidth: 1))
        }
    }

    private func recentsSection(_ recents: [SymptomDefinition]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.recents))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    ForEach(recents) { def in
                        chip(title: env.s(def.displayName), systemImage: "arrow.counterclockwise") {
                            select(.known(def))
                        }
                    }
                }
                .padding(.vertical, BadanSpace.space1)
            }
        }
    }

    private func categorySections(_ categories: [(key: String, items: [SymptomDefinition])]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            ForEach(categories, id: \.key) { category in
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    SectionHeader(env.s(SymptomLogStrings.categoryName(category.key)))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BadanSpace.space2) {
                            ForEach(category.items) { def in
                                chip(title: env.s(def.displayName)) {
                                    select(.known(def))
                                }
                            }
                        }
                        .padding(.vertical, BadanSpace.space1)
                    }
                }
            }
        }
    }

    /// A calm, at-a-glance readout of the last-14-days symptom count and average severity
    /// (FEAT-161), computed straight from the sensitive symptom store rather than a derived
    /// series (STUB-05) — the card was previously unreachable dead code, since nothing ever
    /// wrote to (or could write to) a `symptoms.count`/`symptoms.severity_avg` derived series.
    private func trendCard(_ data: SymptomLogData) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(SymptomLogStrings.trendTitle))
                HStack(spacing: BadanSpace.space5) {
                    if let count = data.trendCount {
                        VStack(alignment: .leading, spacing: BadanSpace.space1) {
                            Text(env.format.integer(count))
                                .font(BadanFont.sectionTitle.monospacedDigit())
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(env.s(SymptomLogStrings.trendCountLabel))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                    if let avg = data.trendSeverityAvg {
                        VStack(alignment: .leading, spacing: BadanSpace.space1) {
                            Text("\(env.format.number(avg, fraction: 1))/\(env.format.integer(10))")
                                .font(BadanFont.sectionTitle.monospacedDigit())
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(env.s(SymptomLogStrings.trendSeverityLabel))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Capture form

    @ViewBuilder
    private func captureForm(_ choice: SymptomChoice, recentTriggers: [String]) -> some View {
        let power = env.depth.showsPowerDetail
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            selectedHeader(choice)
            severityCard(sev: roundedSeverity, power: power)
            triggersCard(recentTriggers: recentTriggers)
            noteCard()
            whenCard()
            if power { metadataCard() }
            if let saveError {
                errorRow(saveError)
            }
        }
    }

    private func selectedHeader(_ choice: SymptomChoice) -> some View {
        BadanCard {
            HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space3) {
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(SymptomLogStrings.privateNote))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Text(env.s(choice.displayName))
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                }
                Spacer(minLength: BadanSpace.space2)
                Button {
                    selection = nil
                } label: {
                    Text(env.s(SymptomLogStrings.change))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.primary)
                        // Widen the tappable area beyond the text's own width — a short label
                        // with only vertical padding is an easy miss on a row used every time
                        // (UIUX-125).
                        .padding(.horizontal, BadanSpace.space2)
                        .frame(minHeight: BadanSpace.touchMin)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func severityCard(sev: Int, power: Bool) -> some View {
        let tint = severityTint(sev)
        // Computed once and reused for both the visible label and the accessibility value,
        // instead of calling severityDescriptor(sev) twice per render (PERF-068).
        let descriptor = env.s(severityDescriptor(sev))
        // Power-mode sighted users see the raw 0–10 number next to the header; VoiceOver users
        // should hear the same information, not just the qualitative word (UIUX-117).
        let accessibilityValue = power
            ? "\(descriptor), \(env.format.integer(sev)) \(env.s(SymptomLogStrings.ofScale))"
            : descriptor
        return BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.severity)) {
                    if power {
                        // Raw 0–10 value is a power-only affordance.
                        Text("\(env.format.integer(sev))/\(env.format.integer(10))")
                            .font(BadanFont.chip.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                Text(descriptor)
                    .font(BadanFont.sectionTitle)
                    .foregroundStyle(tint)
                    // A hard color snap at the 7/10 threshold can read as a sudden alarm;
                    // ease into it instead, consistent with "calm amber, never alarming" (UIUX-118).
                    .animation(.easeInOut(duration: 0.2), value: tint)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    // Subtle mild/moderate/severe landmarks under the track so the descriptor
                    // change isn't a surprise while dragging (UIUX-114).
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(BadanColor.primary.opacity(0.25))
                                .frame(width: geo.size.width * 0.35)
                            Capsule().fill(BadanColor.primary.opacity(0.45))
                                .frame(width: geo.size.width * 0.30)
                            Capsule().fill(BadanColor.outOfBand.opacity(0.45))
                                .frame(width: geo.size.width * 0.35 - 4)
                        }
                    }
                    .frame(height: 4)
                    Slider(value: $severity, in: 0...10, step: 1)
                        .tint(tint)
                        .animation(.easeInOut(duration: 0.2), value: tint)
                        .accessibilityValue(accessibilityValue)
                }
                HStack {
                    Text(env.s(Loc.mild))
                    Spacer()
                    Text(env.s(Loc.moderate))
                    Spacer()
                    Text(env.s(Loc.severe))
                }
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    private func triggersCard(recentTriggers: [String]) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.triggers))

                if !triggers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BadanSpace.space2) {
                            ForEach(triggers, id: \.self) { trigger in
                                removableChip(trigger)
                            }
                        }
                        .padding(.vertical, BadanSpace.space1)
                    }
                }

                // Fixed suggestions plus the user's own recently-used free-text triggers
                // (FEAT-199), deduplicated case-insensitively (OPT-108) against each other and
                // against triggers already added to this entry.
                let suggestions = dedupedSuggestions(
                    SymptomLogStrings.triggerSuggestions.map { env.s($0) } + recentTriggers)
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BadanSpace.space2) {
                            ForEach(suggestions, id: \.self) { label in
                                chip(title: label, systemImage: "plus") {
                                    addTrigger(label)
                                }
                            }
                        }
                        .padding(.vertical, BadanSpace.space1)
                    }
                }

                HStack(spacing: BadanSpace.space2) {
                    TextField(env.s(SymptomLogStrings.addTrigger), text: $newTrigger)
                        .font(BadanFont.body)
                        .autocorrectionDisabled()
                        .onSubmit { commitTrigger() }
                    Button {
                        commitTrigger()
                    } label: {
                        Text(env.s(Loc.add))
                            .font(BadanFont.body.weight(.medium))
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, BadanSpace.space3)
                .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
        }
    }

    private func noteCard() -> some View {
        BadanCard {
            // A taller minimum line count than the single-line fields above hints this is the
            // one open-ended free-text field on the screen (UIUX-124).
            TextField(env.s(Loc.notePlaceholder), text: $note, axis: .vertical)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .lineLimit(2...5)
        }
    }

    private func whenCard() -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "clock")
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(env.s(SymptomLogStrings.whenLabel))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    DatePicker("", selection: $occurredAt, in: ...maxDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                .frame(minHeight: BadanSpace.touchMin)
                // One-tap backdate shortcuts for the most common correction (FEAT-285).
                HStack(spacing: BadanSpace.space2) {
                    chip(title: env.s(Loc.today), selected: isSameDay(occurredAt, as: 0)) {
                        setOccurred(daysAgo: 0)
                    }
                    chip(title: env.s(SymptomLogStrings.yesterday), selected: isSameDay(occurredAt, as: 1)) {
                        setOccurred(daysAgo: 1)
                    }
                }
                if isImplausiblyOld(occurredAt) {
                    Text(env.s(SymptomLogStrings.oldDateNotice))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.outOfBand)
                }
            }
        }
    }

    private func metadataCard() -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(SymptomLogStrings.details))
                metaRow(env.s(SymptomLogStrings.timeZone), value: localizedTimeZoneLabel)
                Text(env.s(SymptomLogStrings.selfReport))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(env.s(SymptomLogStrings.deviceOnly))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    /// Wellness-safe, non-blocking notice — matches `ExportCenterScreen.errorCard`'s calm
    /// tone. Entered data is left untouched so the user can just tap Save again (OPT-106 /
    /// UIUX-113).
    private func errorRow(_ message: String) -> some View {
        BadanCard {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(BadanColor.outOfBand)
                    .accessibilityHidden(true)
                Text(message)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
            }
        }
    }

    private func saveButtons(_ choice: SymptomChoice) -> some View {
        VStack(spacing: BadanSpace.space3) {
            Button {
                save(choice, addAnother: false)
            } label: {
                Text(env.s(Loc.save))
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.onPrimary) // (DS1)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: BadanSpace.touchMin)
                    .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .opacity(isSaving ? 0.6 : 1)
            }
            .disabled(isSaving)
            Button {
                save(choice, addAnother: true)
            } label: {
                Text(env.s(Loc.saveAndAddAnother))
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.primary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: BadanSpace.touchMin)
                    .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                            .strokeBorder(BadanColor.separator, lineWidth: 1))
                    .opacity(isSaving ? 0.6 : 1)
            }
            .disabled(isSaving)
        }
    }

    // MARK: - Reusable chip

    private func chip(title: String, systemImage: String? = nil, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BadanSpace.space1) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(BadanFont.chip)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary) // (DS1)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(
                (selected ? BadanColor.primary : BadanColor.surface),
                in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
    }

    private func removableChip(_ text: String) -> some View {
        Button {
            removeTrigger(text)
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Text(text)
                    .font(BadanFont.chip)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(BadanColor.primary)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(BadanColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        }
        .accessibilityLabel("\(env.s(Loc.delete)) \(text)")
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Text(label)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: BadanSpace.space7)
    }

    // MARK: - Actions

    private func select(_ choice: SymptomChoice) {
        searchText = ""
        selection = choice
    }

    private func addTrigger(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitive containment check, so "Stress" and "stress" don't both get added as
        // separate triggers (OPT-108).
        guard !trimmed.isEmpty,
              !triggers.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        triggers.append(trimmed)
    }

    private func removeTrigger(_ value: String) {
        triggers.removeAll { $0 == value }
    }

    private func commitTrigger() {
        addTrigger(newTrigger)
        newTrigger = ""
    }

    /// Fixed suggestions plus recent free-text triggers, deduplicated case-insensitively
    /// against each other and against triggers already on this entry (OPT-108 / FEAT-199).
    private func dedupedSuggestions(_ candidates: [String]) -> [String] {
        var seenFolded = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let folded = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard !seenFolded.contains(folded),
                  !triggers.contains(where: { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame })
            else { continue }
            seenFolded.insert(folded)
            result.append(candidate)
        }
        return result
    }

    private func isSameDay(_ date: Date, as daysAgo: Int) -> Bool {
        guard let target = Calendar.current.date(byAdding: .day, value: -daysAgo, to: env.now()) else { return false }
        return Calendar.current.isDate(date, inSameDayAs: target)
    }

    /// One-tap "Today"/"Yesterday" backdate shortcut, keeping the current time-of-day
    /// (FEAT-285). Never past the live upper bound.
    private func setOccurred(daysAgo: Int) {
        let now = env.now()
        let candidate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        occurredAt = min(candidate, maxDate)
    }

    /// A soft, non-blocking plausibility notice for far-backdated entries — an accidental
    /// multi-year-old timestamp from a stray wheel-picker scroll is otherwise easy to miss
    /// (OPT-113).
    private func isImplausiblyOld(_ date: Date) -> Bool {
        date < env.now().addingTimeInterval(-90 * 86_400)
    }

    private var localizedTimeZoneLabel: String {
        let locale = Locale(identifier: env.language == .ar ? "ar" : "en_US")
        return TimeZone(identifier: tz)?.localizedName(for: .generic, locale: locale) ?? tz
    }

    private func save(_ choice: SymptomChoice, addAnother: Bool) {
        // Guard against a fast double-tap inserting two near-identical entries (EASE-016 /
        // EASE-097).
        guard !isSaving else { return }
        isSaving = true
        saveError = nil

        // Refresh the "cannot log the future" bound and clamp to it, so a screen left open
        // across a real-time boundary can't silently save a now-past-max timestamp (OPT-109).
        let now = env.now()
        if maxDate < now { maxDate = now }
        let clampedOccurredAt = min(occurredAt, maxDate)

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SymptomEntry(
            id: ULID.newID(),
            symptomId: choice.symptomId,
            customLabel: choice.customLabel,
            severity: roundedSeverity,
            occurredAt: clampedOccurredAt,
            tzId: tz,
            triggers: triggers,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            updatedAt: now,
            originDeviceId: env.deviceId)

        do {
            try env.logging.insertSymptom(entry)
            // (F5) Bumped only on the success path — the catch below leaves disk unchanged, so
            // there is nothing for other screens to reload.
            env.bumpDataGeneration()
        } catch {
            // Stay calm and non-destructive; keep the form intact so nothing entered is lost,
            // and tell the user so they know to retry (OPT-106 / UIUX-113).
            isSaving = false
            saveError = env.s(SymptomLogStrings.saveErrorTitle)
            // (A3) The error renders inline, which VoiceOver doesn't announce on its own.
            Announce.failure(env.s(SymptomLogStrings.saveErrorTitle))
            return
        }

        isSaving = false
        savedTick += 1 // light haptic confirmation (UIUX-119)
        // (A3) The haptic and the toast below are both non-verbal, and on the `addAnother` path
        // the only other feedback is the form clearing — silence, to VoiceOver.
        Announce.status(env.s(SymptomLogStrings.savedConfirmation))

        if addAnother {
            vm.prependRecent(choice) // PERF-066: no full 30-day re-fetch between entries
            resetForm()
            showSavedToast = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                showSavedToast = false
            }
        } else {
            dismiss()
        }
    }

    private func resetForm() {
        selection = nil
        searchText = ""
        severity = 3
        triggers = []
        newTrigger = ""
        note = ""
        occurredAt = env.now()
        maxDate = env.now()
        saveError = nil
    }

    // MARK: - Severity helpers

    /// Computed once from `severity` and reused everywhere a rounded value is needed, so the
    /// displayed value and the saved value can never drift apart (OPT-111).
    private var roundedSeverity: Int { Int(severity.rounded()) }

    private func severityDescriptor(_ value: Int) -> LocalizedString {
        switch value {
        case 0...3: return Loc.mild
        case 4...6: return Loc.moderate
        default: return Loc.severe
        }
    }

    /// Never red. Calm primary for most of the range; a subtle amber only at the top so the
    /// scale reads without moralizing.
    private func severityTint(_ value: Int) -> Color {
        value >= 7 ? BadanColor.outOfBand : BadanColor.primary
    }
}
