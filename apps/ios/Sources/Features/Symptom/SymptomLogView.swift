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

            let data = SymptomLogData(recents: recents, categories: categories)
            state = (recents.isEmpty && categories.isEmpty)
                ? .empty(env.s(Loc.chooseSymptom))
                : .loaded(data)
        } catch {
            state = .error(String(describing: error))
        }
    }
}

// MARK: - Screen

/// Under-10-second symptom capture, pushed as its own screen. Pick from recents (2 taps) or
/// search / browse categories, set a calm severity, add optional triggers + a note, optionally
/// backdate, then save. Sensitive by nature — private, judgment-free, never alarming.
struct SymptomLogView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
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

    private var tz: String { TimeZone.current.identifier }

    var body: some View {
        ScrollView {
            StatefulContainer(vm.state) { data in
                Group {
                    if let selection {
                        captureForm(selection)
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
        .task {
            maxDate = env.now()
            if selection == nil { occurredAt = env.now() }
            vm.load(env)
        }
    }

    // MARK: - Picker (choose a symptom)

    @ViewBuilder
    private func picker(_ data: SymptomLogData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            Text(env.s(SymptomLogStrings.privateNote))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)

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
            customResultRow(query)
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

    // MARK: - Capture form

    @ViewBuilder
    private func captureForm(_ choice: SymptomChoice) -> some View {
        let power = env.depth.showsPowerDetail
        let sev = Int(severity.rounded())
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            selectedHeader(choice)
            severityCard(sev: sev, power: power)
            triggersCard()
            noteCard()
            whenCard()
            if power { metadataCard() }
            saveButtons(choice)
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
                        .frame(minHeight: BadanSpace.touchMin)
                }
            }
        }
    }

    private func severityCard(sev: Int, power: Bool) -> some View {
        let tint = severityTint(sev)
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
                Text(env.s(severityDescriptor(sev)))
                    .font(BadanFont.sectionTitle)
                    .foregroundStyle(tint)
                Slider(value: $severity, in: 0...10, step: 1)
                    .tint(tint)
                    .accessibilityValue(env.s(severityDescriptor(sev)))
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

    private func triggersCard() -> some View {
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

                let suggestions = SymptomLogStrings.triggerSuggestions
                    .map { env.s($0) }
                    .filter { !triggers.contains($0) }
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
            TextField(env.s(Loc.notePlaceholder), text: $note, axis: .vertical)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .lineLimit(1...4)
        }
    }

    private func whenCard() -> some View {
        BadanCard {
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
        }
    }

    private func metadataCard() -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(SymptomLogStrings.details))
                metaRow(env.s(SymptomLogStrings.timeZone), value: tz)
                Text(env.s(SymptomLogStrings.selfReport))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(env.s(SymptomLogStrings.deviceOnly))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
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
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: BadanSpace.touchMin)
                    .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
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
            }
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
            .foregroundStyle(selected ? Color.white : BadanColor.textPrimary)
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
        guard !trimmed.isEmpty, !triggers.contains(trimmed) else { return }
        triggers.append(trimmed)
    }

    private func removeTrigger(_ value: String) {
        triggers.removeAll { $0 == value }
    }

    private func commitTrigger() {
        addTrigger(newTrigger)
        newTrigger = ""
    }

    private func save(_ choice: SymptomChoice, addAnother: Bool) {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SymptomEntry(
            id: ULID.newID(),
            symptomId: choice.symptomId,
            customLabel: choice.customLabel,
            severity: Int(severity.rounded()),
            occurredAt: occurredAt,
            tzId: tz,
            triggers: triggers,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            updatedAt: env.now(),
            originDeviceId: env.deviceId)

        do {
            try env.logging.insertSymptom(entry)
        } catch {
            // Stay calm and non-destructive; keep the form so nothing is lost.
            return
        }

        if addAnother {
            resetForm()
            vm.load(env) // refresh recents so the just-logged symptom is a 2-tap re-log
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
    }

    // MARK: - Severity helpers

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
