import XCTest
@testable import BADAN

/// EPIC-38 hydration SURFACES (the iOS UI layer over the Stage-1 ledger/engine/repo). Two halves:
/// pure presentation helpers (favorites, progress, weekly count, day-type memory, beverage catalog,
/// copy), and the `HydrationViewModel` exercised end-to-end against a real database — proving a
/// logged drink updates the total, offers a working undo, and edits/deletes/goals/day-types behave
/// exactly as the wellness-safe rules require (no percentage of a no-goal day, no inferred day type).
final class HydrationSurfacesTests: XCTestCase {
    private let device = "test-device"

    private func container(id: String, name: String, ml: Double, sort: Int, deleted: Bool = false) -> ContainerPreset {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        return ContainerPreset(id: id, nameEn: name, nameAr: name, volumeMl: ml, beverageId: nil,
                               sortOrder: sort, updatedAt: now, originDeviceId: device,
                               deletedAt: deleted ? now : nil)
    }

    private func summary(day: String, manual: Double, count: Int, deleted: Bool = false) -> HydrationDailySummary {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        return HydrationDailySummary(dayKey: day, tzId: "Asia/Riyadh", manualMl: manual, entryCount: count,
                                     goalKind: .none, updatedAt: now, originDeviceId: device,
                                     deletedAt: deleted ? now : nil)
    }

    // MARK: - Favorites

    func testFavoritesFallBackToBuiltinDefaultsWhenNoContainersSaved() {
        let favorites = HydrationFavorite.list(containers: [])
        XCTAssertEqual(favorites.map(\.volumeMl), [250, 500])
        XCTAssertTrue(favorites.allSatisfy { $0.isDefault }, "built-in defaults carry no container id")
        XCTAssertTrue(favorites.allSatisfy { $0.name == nil }, "an anonymous amount has no name to say 'from'")
    }

    func testSavedContainersReplaceDefaultsAndSortStably() {
        let favorites = HydrationFavorite.list(containers: [
            container(id: "b", name: "Bottle", ml: 500, sort: 1),
            container(id: "g", name: "Glass", ml: 250, sort: 0),
            container(id: "x", name: "Gone", ml: 999, sort: 2, deleted: true),
        ])
        XCTAssertEqual(favorites.map(\.id), ["g", "b"], "sorted by sortOrder; tombstoned container excluded")
        XCTAssertTrue(favorites.allSatisfy { !$0.isDefault && $0.name != nil }, "a saved favorite is named and deletable")
    }

    // MARK: - Progress (no percentage of nothing)

    func testProgressHasNoFractionWithoutARealGoal() {
        XCTAssertNil(HydrationProgress(totalMl: 1200, goalTargetMl: nil).fraction, "a no-goal day never renders a fraction")
        XCTAssertNil(HydrationProgress(totalMl: 1200, goalTargetMl: 0).fraction, "a zero target is not a real goal")
        XCTAssertFalse(HydrationProgress(totalMl: 1200, goalTargetMl: nil).hasGoal)
    }

    func testProgressFractionIsCappedAtOne() {
        XCTAssertEqual(HydrationProgress(totalMl: 500, goalTargetMl: 2000).fraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(HydrationProgress(totalMl: 2500, goalTargetMl: 2000).fraction ?? -1, 1.0, accuracy: 0.0001,
                       "over your amount reads as gently complete, never an alarming overflow")
    }

    // MARK: - Weekly (observational count only)

    func testLoggedDayCountCountsOnlyDaysWithDrinks() {
        let count = HydrationWeek.loggedDayCount([
            summary(day: "2026-07-15", manual: 1000, count: 3),
            summary(day: "2026-07-16", manual: 0, count: 0),      // a day that recomputed to empty
            summary(day: "2026-07-17", manual: 500, count: 1),
            summary(day: "2026-07-18", manual: 800, count: 2, deleted: true),  // tombstoned
        ])
        XCTAssertEqual(count, 2, "only days with logged drinks count — a missing/empty day is not a 'miss'")
        XCTAssertEqual(HydrationWeek.loggedDayCount([]), 0)
    }

    // MARK: - Day type memory (user-selected, never inferred)

    func testDayTypeStoreRemembersOnlyForItsOwnDay() {
        let defaults = UserDefaults(suiteName: "hydration-daytype-\(UUID().uuidString)")!
        HydrationDayTypeStore.set("Training", forDayKey: "2026-07-21", defaults: defaults)
        XCTAssertEqual(HydrationDayTypeStore.selected(forDayKey: "2026-07-21", defaults: defaults), "Training")
        XCTAssertNil(HydrationDayTypeStore.selected(forDayKey: "2026-07-22", defaults: defaults),
                     "a selection for a past day never carries into a new day (each day starts at the default)")
        HydrationDayTypeStore.set(nil, forDayKey: "2026-07-21", defaults: defaults)
        XCTAssertNil(HydrationDayTypeStore.selected(forDayKey: "2026-07-21", defaults: defaults), "nil clears the pick")
    }

    // MARK: - Beverage catalog

    private func makeCatalog() -> HydrationBeverageCatalog {
        HydrationBeverageCatalog(builtins: [
            HydrationBeverage(id: "water", name: LocalizedString(en: "Water", ar: "ماء"),
                              fluidType: "water", defaultVolumeMl: 250, isBuiltin: true),
            HydrationBeverage(id: "coffee", name: LocalizedString(en: "Coffee", ar: "قهوة"),
                              fluidType: "coffee", defaultVolumeMl: 200, isBuiltin: true),
        ])
    }

    private func customBeverage(id: String, name: String, fluid: String, deleted: Bool = false) -> BeverageDefinition {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        return BeverageDefinition(id: id, nameEn: name, nameAr: name, fluidType: fluid, isBuiltin: false,
                                  updatedAt: now, originDeviceId: device, deletedAt: deleted ? now : nil)
    }

    func testCatalogMergesBuiltinsAndCustomWithOverride() {
        let catalog = makeCatalog()
        let merged = catalog.all(custom: [customBeverage(id: "kombucha", name: "Kombucha", fluid: "other")])
        XCTAssertEqual(merged.count, 3, "built-ins plus the one custom beverage")
        XCTAssertTrue(merged.contains { $0.id == "kombucha" })

        let overridden = catalog.all(custom: [customBeverage(id: "coffee", name: "My Coffee", fluid: "coffee")])
        XCTAssertEqual(overridden.first { $0.id == "coffee" }?.name.en, "My Coffee", "a same-id custom overrides the built-in")
    }

    func testCatalogResolveFallsBackToWater() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.resolve(id: "coffee", custom: []).name.en, "Coffee")
        XCTAssertEqual(catalog.resolve(id: nil, custom: []).id, "water", "a nil beverage id resolves to water")
        XCTAssertEqual(catalog.resolve(id: "deleted-drink", custom: []).id, "water", "an unknown id resolves to water")
        // A custom override wins for display, consistent with all(custom:).
        XCTAssertEqual(catalog.resolve(id: "coffee", custom: [customBeverage(id: "coffee", name: "My Coffee", fluid: "coffee")]).name.en, "My Coffee")
    }

    // MARK: - Copy (wellness-safe, bilingual)

    private func formatter(_ language: AppLanguage) -> ValueFormatter {
        ValueFormatter(profile: CustomizationProfile(language: language), registry: .shared)
    }

    func testConfirmationNamesTheFavoriteWhenItHasOne() {
        let en = formatter(.en)
        XCTAssertEqual(HydrationStrings.confirmation(
            volume: HydrationStrings.volume(500, formatter: en, language: .en),
            favoriteName: "My Bottle", language: .en), "Added 500 mL from My Bottle")
        XCTAssertEqual(HydrationStrings.confirmation(
            volume: HydrationStrings.volume(500, formatter: en, language: .en),
            favoriteName: nil, language: .en), "Added 500 mL")
        let ar = formatter(.ar)
        XCTAssertEqual(HydrationStrings.confirmation(
            volume: HydrationStrings.volume(500, formatter: ar, language: .ar),
            favoriteName: "قنينتي", language: .ar), "أُضيف 500 مل من قنينتي")
    }

    func testWeeklySentenceIsObservationalInBothLanguages() {
        XCTAssertEqual(HydrationStrings.loggedDaysSentence(days: 5, of: 7, formatter: formatter(.en), language: .en),
                       "Logged drinks on 5 of 7 days")
        XCTAssertEqual(HydrationStrings.loggedDaysSentence(days: 5, of: 7, formatter: formatter(.ar), language: .ar),
                       "سجّلت مشروبات في 5 من 7 أيام")
    }

    func testProgressReadoutNeverPercentagesANoGoalDay() {
        XCTAssertEqual(HydrationStrings.progressReadout(current: "1,200 mL", target: nil, language: .en),
                       "1,200 mL logged today")
        XCTAssertEqual(HydrationStrings.progressReadout(current: "1,200 mL", target: "2,000 mL", language: .en),
                       "1,200 mL of 2,000 mL")
    }
}

// MARK: - View model, exercised against a real database

@MainActor
final class HydrationViewModelTests: XCTestCase {
    var tempDir: URL!
    var env: AppEnvironment!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        // The day-type memory lives in UserDefaults.standard; clear it so one test's pick never
        // leaks into another (they share the same fixed-clock day key).
        UserDefaults.standard.removeObject(forKey: HydrationDayTypeStore.defaultsKey)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-hydration-vm-\(UUID().uuidString)", isDirectory: true)
        let db = try Database(directory: tempDir)
        env = AppEnvironment(database: db, clock: clock)   // migrations run on open; no demo seed needed
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: HydrationDayTypeStore.defaultsKey)
        env = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func makeVM() -> HydrationViewModel {
        HydrationViewModel(catalog: HydrationBeverageCatalog(builtins: [
            HydrationBeverage(id: "water", name: LocalizedString(en: "Water", ar: "ماء"),
                              fluidType: "water", defaultVolumeMl: 250, isBuiltin: true),
        ]))
    }

    func testLoggingAFavoriteUpdatesTotalAndOffersUndo() {
        let vm = makeVM()
        vm.load(env)
        XCTAssertEqual(vm.todayTotalMl, 0)
        let fav = try? XCTUnwrap(vm.favorites.first { $0.volumeMl == 500 })
        XCTAssertTrue(vm.log(favorite: fav!, env: env))
        XCTAssertEqual(vm.todayTotalMl, 500)
        XCTAssertEqual(vm.todayEntries.count, 1)
        XCTAssertEqual(vm.pendingUndo?.message, "Added 500 mL")

        vm.undoLastLog(env: env)
        XCTAssertEqual(vm.todayTotalMl, 0, "undo tombstones the drink — the total returns to zero")
        XCTAssertTrue(vm.todayEntries.isEmpty)
        XCTAssertNil(vm.pendingUndo)
    }

    func testCustomLogEditAndDeleteRoundTrip() {
        let vm = makeVM()
        vm.load(env)
        XCTAssertTrue(vm.log(volumeMl: 300, fluidType: "water", beverageId: "water", containerId: nil,
                             occurredAt: env.now(), note: nil, favoriteName: nil, env: env))
        let entry = try? XCTUnwrap(vm.todayEntries.first)
        XCTAssertEqual(vm.todayTotalMl, 300)

        // Revise up to 450 — an append that supersedes, not a mutation.
        XCTAssertTrue(vm.revise(originalId: entry!.originalId, volumeMl: 450, fluidType: "water",
                                beverageId: "water", occurredAt: entry!.occurredAt, note: "more", env: env))
        XCTAssertEqual(vm.todayTotalMl, 450)
        XCTAssertEqual(vm.todayEntries.count, 1, "a revision does not add a second live row")
        XCTAssertTrue(vm.todayEntries.first?.isRevised == true)

        XCTAssertTrue(vm.delete(entry: vm.todayEntries.first!, env: env))
        XCTAssertTrue(vm.todayEntries.isEmpty)
        XCTAssertEqual(vm.todayTotalMl, 0)
    }

    func testManualGoalDrivesProgressAndNoGoalClearsIt() {
        let vm = makeVM()
        vm.load(env)
        XCTAssertTrue(vm.setDefaultGoal(manualTargetMl: 2000, env: env))
        vm.log(volumeMl: 500, fluidType: "water", beverageId: "water", containerId: nil,
               occurredAt: env.now(), note: nil, favoriteName: nil, env: env)
        XCTAssertEqual(vm.progress.goalTargetMl, 2000)
        XCTAssertEqual(vm.progress.fraction ?? -1, 0.25, accuracy: 0.0001)

        XCTAssertTrue(vm.setDefaultGoal(manualTargetMl: nil, env: env), "no-goal is an equal-status choice")
        XCTAssertNil(vm.progress.goalTargetMl)
        XCTAssertNil(vm.progress.fraction)
    }

    func testSavingAFavoriteReplacesDefaultsAndNamesItsConfirmation() {
        let vm = makeVM()
        vm.load(env)
        XCTAssertTrue(vm.favorites.allSatisfy { $0.isDefault })
        XCTAssertTrue(vm.saveFavorite(name: "My Bottle", volumeMl: 750, beverageId: nil, env: env))
        XCTAssertFalse(vm.favorites.contains { $0.isDefault }, "the user's own favorites replace the built-in defaults")
        let mine = try? XCTUnwrap(vm.favorites.first)
        XCTAssertEqual(mine?.volumeMl, 750)
        vm.log(favorite: mine!, env: env)
        XCTAssertEqual(vm.pendingUndo?.message, "Added 750 mL from My Bottle")
    }

    func testDayTypeGoalAppliesOnlyWhenTheUserPicksItForToday() {
        let vm = makeVM()
        vm.load(env)
        XCTAssertTrue(vm.setDefaultGoal(manualTargetMl: 2000, env: env))
        XCTAssertTrue(vm.setDayTypeGoal(name: "Training", targetMl: 3000, env: env))
        XCTAssertEqual(vm.progress.goalTargetMl, 2000, "authoring a day type never infers today onto it")

        vm.selectTodayDayType("Training", env: env)
        XCTAssertEqual(vm.progress.goalTargetMl, 3000, "today follows the user's explicit pick")

        vm.selectTodayDayType(nil, env: env)
        XCTAssertEqual(vm.progress.goalTargetMl, 2000, "back to the default")
    }

    func testBackdatedDrinkLandsOnItsOwnDayNotToday() {
        let vm = makeVM()
        vm.load(env)
        let yesterday = env.now().addingTimeInterval(-86_400)
        XCTAssertTrue(vm.log(volumeMl: 400, fluidType: "water", beverageId: "water", containerId: nil,
                             occurredAt: yesterday, note: nil, favoriteName: nil, env: env))
        XCTAssertEqual(vm.todayTotalMl, 0, "a backdated drink does not inflate today's total")
        XCTAssertTrue(vm.todayEntries.isEmpty)
        // …but it does count toward the week's logged-day count.
        XCTAssertGreaterThanOrEqual(vm.loggedDayCountThisWeek, 1)
    }
}
