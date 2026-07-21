import Foundation

/// A pickable drink for the hydration surfaces — the merged view of the curated built-ins
/// (`beverages.json`) and the user's own `BeverageDefinition` rows. Deliberately carries only what
/// the UI needs to name a drink and pre-fill a starting volume; the dictionary's caffeine / alcohol /
/// electrolyte metadata is **not** surfaced this phase and never becomes a hydration weight (§7A.1 —
/// a logged mL is a logged mL regardless of what was in the cup).
struct HydrationBeverage: Identifiable, Hashable {
    let id: String
    let name: LocalizedString
    let fluidType: String
    /// A starting suggestion for the amount field — never a target, never enforced.
    let defaultVolumeMl: Double?
    let isBuiltin: Bool
}

/// Loads and merges the beverage vocabulary. Built-ins ship in `beverages.json` (the read side of
/// the same dictionary-vs-custom split `SymptomDictionary` uses for `symptoms.json`); user-added
/// beverages come from the `beverage_definitions` table via `HydrationRepository`. Injecting
/// `builtins` keeps the type testable without the app bundle.
final class HydrationBeverageCatalog {
    static let shared = HydrationBeverageCatalog()

    let builtins: [HydrationBeverage]
    private let builtinById: [String: HydrationBeverage]

    private struct BuiltinFile: Decodable { let beverages: [BuiltinRow] }
    private struct BuiltinRow: Decodable {
        let id: String
        let nameEn: String
        let nameAr: String
        let fluidType: String
        let defaultVolumeMl: Double?
    }

    init(builtins: [HydrationBeverage]? = nil) {
        let loaded = builtins ?? (BundleJSON.load(BuiltinFile.self, "beverages")?.beverages ?? []).map {
            HydrationBeverage(id: $0.id, name: LocalizedString(en: $0.nameEn, ar: $0.nameAr),
                              fluidType: $0.fluidType, defaultVolumeMl: $0.defaultVolumeMl, isBuiltin: true)
        }
        self.builtins = loaded
        self.builtinById = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Built-ins (each swapped for a same-id custom override, if one exists) followed by the user's
    /// remaining custom beverages. Tombstoned custom rows are excluded.
    func all(custom: [BeverageDefinition]) -> [HydrationBeverage] {
        let liveCustom = custom.filter { $0.deletedAt == nil }
        let customById = Dictionary(liveCustom.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [HydrationBeverage] = builtins.map { builtin in
            guard let override = customById[builtin.id] else { return builtin }
            return Self.beverage(from: override)
        }
        let builtinIds = Set(builtins.map(\.id))
        for c in liveCustom where !builtinIds.contains(c.id) {
            result.append(Self.beverage(from: c))
        }
        return result
    }

    /// Resolves a stored `beverageId` for display. A live custom row wins (so a custom override of a
    /// built-in id displays the user's name, consistent with `all(custom:)`), then the built-ins. A
    /// nil or unknown id falls back to plain water, so a ledger entry always names a drink even if its
    /// beverage was later deleted from the custom catalog.
    func resolve(id: String?, custom: [BeverageDefinition]) -> HydrationBeverage {
        if let id {
            if let c = custom.first(where: { $0.id == id && $0.deletedAt == nil }) { return Self.beverage(from: c) }
            if let builtin = builtinById[id] { return builtin }
        }
        return builtinById["water"] ?? HydrationBeverage(
            id: "water", name: HydrationFluidType.water.displayLabel,
            fluidType: HydrationFluidType.water.rawValue, defaultVolumeMl: 250, isBuiltin: true)
    }

    private static func beverage(from def: BeverageDefinition) -> HydrationBeverage {
        HydrationBeverage(id: def.id, name: def.displayName, fluidType: def.fluidType,
                          defaultVolumeMl: def.defaultVolumeMl, isBuiltin: false)
    }
}
