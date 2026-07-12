import XCTest
@testable import BADAN

/// Regression guard for the N+1 / over-fetch patterns flagged against the highest-traffic
/// view-model `load()` paths (Home, Body, Timeline). Exercises each against a realistic,
/// deterministic 90-day dataset — the same `FakeHealthStore`/`SeedController` fixture
/// `PipelineTests` uses — so a future change that reintroduces or worsens an N+1 pattern shows
/// up as a measurable regression here instead of shipping silently.
@MainActor
final class ViewModelPerformanceTests: XCTestCase {
    var tempDir: URL!
    var env: AppEnvironment!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-perf-test-\(UUID().uuidString)", isDirectory: true)
        let db = try Database(directory: tempDir)
        env = AppEnvironment(database: db, clock: FixedClock(Date(timeIntervalSince1970: 1_783_000_000)))
        await env.bootstrap()
    }

    override func tearDown() {
        env = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    /// `measure {}` doesn't support `async` — these now exercise the extracted, nonisolated
    /// fetch cores directly (PERF-01 split `load()` into a main-actor dispatcher + a pure
    /// fetch function), which is exactly the query cost this regression guard was written to
    /// track in the first place.
    func testHomeViewModelLoadPerformance() {
        let inputs = HomeFetchInputs(
            measurements: env.measurements, derivation: env.derivation, catalog: env.catalog,
            logging: env.logging, insightsRepo: env.insightsRepo, registry: env.registry,
            format: env.format, language: env.language, depth: env.depth,
            nutritionEnabled: env.profile.nutritionEnabled,
            sensitiveModulesEnabled: env.profile.sensitiveModulesEnabled,
            now: env.now())
        measure {
            _ = HomeViewModel.fetch(inputs)
        }
    }

    func testBodyViewModelLoadPerformance() {
        let inputs = BodyFetchInputs(
            registry: env.registry, derivation: env.derivation, measurements: env.measurements,
            now: env.now())
        measure {
            _ = BodyViewModel.fetch(inputs)
        }
    }

    func testTimelineAssemblerPerformance() {
        let assembler = TimelineAssembler(
            measurements: env.measurements, logging: env.logging, registry: env.registry,
            symptoms: env.symptoms, format: env.format, language: env.language,
            sensitiveModulesEnabled: env.profile.sensitiveModulesEnabled,
            nutritionEnabled: env.profile.nutritionEnabled, now: env.now())
        measure {
            _ = try? assembler.assemble()
        }
    }
}
