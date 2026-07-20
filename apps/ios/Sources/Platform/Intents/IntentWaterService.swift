import Foundation

/// Why a water quick-log from an intent was refused.
enum IntentWaterRefusal: Error, Equatable {
    /// Outside the plausible single-entry range. The ceiling matches `WaterQuickSheet`'s own
    /// 5000 ml plausibility limit so the intent and the in-app sheet agree on what counts as a
    /// mis-entry — a Shortcut passing "5" meaning litres shouldn't silently log 5 ml, and one
    /// passing 50000 shouldn't log a bathtub.
    case amountOutOfRange
    /// The write itself failed.
    case saveFailed
}

/// EPIC-19 — the water quick-log behind `LogWaterIntent`.
///
/// Deliberately the *same* write `LogHubViewModel.logWater` performs: a `NutritionEntry` with the
/// stable `WaterEntryIdentity.canonicalKey` description (so it dedupes and displays exactly like a
/// tap-logged one, EDGE-17), `mealType = .drink`, manual origin, followed by a `dataGeneration`
/// bump so an already-open Log tab reflects it (BUG-12/13). Factoring it here rather than reaching
/// into the view model keeps the intent off the SwiftUI type while still going through the one
/// canonical shape — a second, subtly-different water write is exactly the drift this avoids.
@MainActor
struct IntentWaterService {
    let env: AppEnvironment

    /// Inclusive plausible range for a single entry, in millilitres. Lower bound is 1 (a zero or
    /// negative amount is not a log); upper bound mirrors `WaterQuickSheet.waterPlausibilityCeilingMl`.
    static let minMl = 1.0
    static let maxMl = 5000.0

    @discardableResult
    func log(milliliters: Double) throws -> Double {
        let rounded = milliliters.rounded()
        guard rounded >= Self.minMl, rounded <= Self.maxMl else {
            throw IntentWaterRefusal.amountOutOfRange
        }
        let now = env.now()
        let entry = NutritionEntry(
            id: ULID.newID(),
            description: WaterEntryIdentity.canonicalKey,
            mealType: .drink,
            waterMl: rounded,
            occurredAt: now,
            tzId: TimeZone.current.identifier,
            updatedAt: now,
            originDeviceId: env.deviceId)
        do {
            try env.logging.upsertNutrition(entry)
        } catch {
            throw IntentWaterRefusal.saveFailed
        }
        env.bumpDataGeneration()
        return rounded
    }
}
