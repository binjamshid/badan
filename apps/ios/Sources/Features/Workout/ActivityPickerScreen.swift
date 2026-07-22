import SwiftUI

// MARK: - Activity dictionary (packages/contracts/dictionaries/activities.json)

/// One entry from the curated bilingual activity taxonomy. Mirrors `BehaviorDefinition`/
/// `SymptomDefinition`'s shape exactly (see those types' docs for the established convention).
struct ActivityDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var nameEn: String
    var nameAr: String
    var category: String

    var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }
}

/// The canonical activity vocabulary (`activities.json`) the full picker draws from, loaded via
/// this codebase's established `BundleJSON` convention — see `BehaviorDictionary`/
/// `SymptomDictionary` for the identical pattern this mirrors.
final class ActivityCatalog {
    static let shared = ActivityCatalog()

    let all: [ActivityDefinition]
    private let byId: [String: ActivityDefinition]

    private struct File: Decodable { let activities: [ActivityDefinition] }

    init(activities: [ActivityDefinition]? = nil) {
        let loaded = activities ?? BundleJSON.load(File.self, "activities")?.activities ?? []
        self.all = loaded
        self.byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func definition(_ id: String?) -> ActivityDefinition? { id.flatMap { byId[$0] } }

    /// Whether `id` names a strength-modality activity (`category == "strength"` —
    /// `activities.json`'s own documented grouping, covering `strength_training` plus its
    /// cross/functional/core-training siblings) — the rule `WorkoutFlowRoute` uses to decide
    /// between the plain live screen and the set-logging screen. `false` (never a guess) for an
    /// unrecognized id.
    func isStrength(_ id: String?) -> Bool { definition(id)?.category == "strength" }

    /// Categories in file-authored order — the section order the picker renders, matching
    /// `BehaviorDictionary.categories`'s identical "don't re-sort a deliberately authored list" rule.
    var categories: [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for a in all where !seen.contains(a.category) { seen.insert(a.category); ordered.append(a.category) }
        return ordered
    }

    func inCategory(_ category: String) -> [ActivityDefinition] { all.filter { $0.category == category } }
}

/// Bilingual, wellness-safe display names for the category groupings `activities.json` uses —
/// descriptive of the modality, never of a fitness level (matches this file's own "no diagnostic
/// or moralizing entry" selection rule).
private enum ActivityCategoryLabel {
    static func label(for category: String) -> LocalizedString {
        switch category {
        case "cardio": return LocalizedString(en: "Cardio", ar: "قلب ورئتين")
        case "strength": return LocalizedString(en: "Strength", ar: "قوة")
        case "water": return LocalizedString(en: "Water", ar: "مائي")
        case "mind_body": return LocalizedString(en: "Mind & body", ar: "العقل والجسد")
        case "sport": return LocalizedString(en: "Sport", ar: "رياضة")
        case "winter": return LocalizedString(en: "Winter", ar: "شتوي")
        case "other": return LocalizedString(en: "Other", ar: "أخرى")
        default: return LocalizedString(en: category.capitalized, ar: category.capitalized)
        }
    }
}

// MARK: - Screen-local strings

private enum ActivityPickerStrings {
    static let title = LocalizedString(en: "Choose an activity", ar: "اختر نشاطاً")
    static let startFailed = LocalizedString(
        en: "Couldn't start that workout. Try again.", ar: "تعذّر بدء هذا التمرين. حاول مرة أخرى.")
}

// MARK: - Screen

/// EPIC-42 slice 2 — the full activity list (`activities.json`), grouped by category, reached from
/// `WorkoutHomeScreen`'s "More activities" link. Tapping an entry starts the SAME coordinator the
/// home screen quick-start tiles drive, then routes to the live or strength-logging screen exactly
/// as `WorkoutFlowRoute.destination(forActivityType:)` decides for any other entry point.
struct ActivityPickerScreen: View {
    @Environment(AppEnvironment.self) private var env
    let coordinator: WorkoutSessionCoordinator
    let returnToLog: () -> Void

    @State private var route: WorkoutFlowRoute?
    @State private var startErrorText: LocalizedString?

    private let catalog = ActivityCatalog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                ForEach(catalog.categories, id: \.self) { category in
                    categorySection(category)
                }
                if let startErrorText {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(BadanColor.outOfBand)
                            .accessibilityHidden(true)
                        Text(env.s(startErrorText))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(ActivityPickerStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { destinationRoute in
            destinationRoute.makeView(coordinator: coordinator, returnToLog: returnToLog)
        }
    }

    private func categorySection(_ category: String) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(ActivityCategoryLabel.label(for: category)))
            VStack(spacing: BadanSpace.space2) {
                ForEach(catalog.inCategory(category)) { activity in
                    activityRow(activity)
                }
            }
        }
    }

    private func activityRow(_ activity: ActivityDefinition) -> some View {
        Button {
            start(activity)
        } label: {
            HStack(spacing: BadanSpace.space3) {
                Text(env.s(activity.displayName))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func start(_ activity: ActivityDefinition) {
        startErrorText = nil
        do {
            try coordinator.start(activityType: activity.id)
            route = WorkoutFlowRoute.destination(forActivityType: activity.id)
        } catch {
            startErrorText = ActivityPickerStrings.startFailed
            Announce.failure(env.s(ActivityPickerStrings.startFailed))
        }
    }
}
