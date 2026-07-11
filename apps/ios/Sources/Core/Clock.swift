import Foundation

/// Injectable time source. BADAN domain code (ingestion, day-attribution, baselines)
/// never reads the wall clock directly — it takes a `Clock` — so DST and boundary
/// behaviour is deterministically testable (blueprint test matrix: "injected clock
/// everywhere, no wall-clock in domain code").
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock pinned to a fixed instant, for tests and reproducible fixtures/seeding.
public final class FixedClock: Clock, @unchecked Sendable {
    public private(set) var instant: Date
    public init(_ instant: Date) { self.instant = instant }
    public func now() -> Date { instant }
    public func advance(by interval: TimeInterval) { instant = instant.addingTimeInterval(interval) }
    public func set(_ instant: Date) { self.instant = instant }
}

public extension Date {
    /// Epoch milliseconds (UTC). BADAN stores instants as INTEGER epoch-millis.
    var epochMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(epochMillis: Int64) { self = Date(timeIntervalSince1970: Double(epochMillis) / 1000.0) }
}
