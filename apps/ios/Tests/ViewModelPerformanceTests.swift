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

    func testHomeViewModelLoadPerformance() {
        measure {
            let vm = HomeViewModel()
            vm.load(env)
        }
    }

    func testBodyViewModelLoadPerformance() {
        measure {
            let vm = BodyViewModel()
            vm.load(env)
        }
    }

    func testTimelineAssemblerPerformance() {
        measure {
            _ = try? TimelineAssembler(env: env).assemble()
        }
    }
}
