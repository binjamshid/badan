import Foundation

/// A frozen algorithm identity. Derived values carry their algorithm+version so a number
/// can always be traced to the exact method that produced it, and recompute is auditable.
public struct AlgorithmVersion: Codable, Hashable, Sendable, Identifiable {
    public var algorithmId: String     // e.g. "baseline.rolling_median_mad"
    public var semver: String          // e.g. "1.0.0"
    public var params: [String: Double]
    public var introducedIn: String    // app version

    public var id: String { "\(algorithmId)@\(semver)" }

    public init(algorithmId: String, semver: String, params: [String: Double] = [:], introducedIn: String) {
        self.algorithmId = algorithmId; self.semver = semver
        self.params = params; self.introducedIn = introducedIn
    }
}

/// The records that fed a derived value — renders the "anatomy" sheet that answers
/// "why is it saying that?" (VS-4). Append-only alongside the DerivedValue.
public struct InputManifest: Codable, Hashable, Sendable, Identifiable {
    public struct Input: Codable, Hashable, Sendable {
        public var recordId: String
        public var metricId: String
        public var value: Double
        public var weight: Double?
        public init(recordId: String, metricId: String, value: Double, weight: Double? = nil) {
            self.recordId = recordId; self.metricId = metricId; self.value = value; self.weight = weight
        }
    }
    public var id: String
    public var inputs: [Input]

    public init(id: String, inputs: [Input]) { self.id = id; self.inputs = inputs }
}

/// An append-only interpretation of raw facts (D-2). Recompute appends a new row and the
/// latest `computedAt` wins on read; older rows are never overwritten (INVARIANT I2).
public struct DerivedValue: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var value: Double
    public var unit: String
    public var periodKey: String          // "day:2026-07-10" | "session:<ulid>" | "week:2026-W28"
    public var confidence: Double?
    public var provisional: Bool
    public var algorithmId: String
    public var algorithmVersion: String
    public var inputManifestId: String?
    public var computedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, metricId: String, value: Double, unit: String, periodKey: String,
                confidence: Double? = nil, provisional: Bool = false, algorithmId: String,
                algorithmVersion: String, inputManifestId: String? = nil, computedAt: Date,
                updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.metricId = metricId; self.value = value; self.unit = unit
        self.periodKey = periodKey; self.confidence = confidence; self.provisional = provisional
        self.algorithmId = algorithmId; self.algorithmVersion = algorithmVersion
        self.inputManifestId = inputManifestId; self.computedAt = computedAt
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

public enum BaselineMethod: String, Codable, Hashable, Sendable {
    case medianMAD
}

/// A materialized "personal normal" band. Center ± spread define the band; `provisional`
/// stays true until there are enough points to be honest about (I: wellness-safe honesty).
public struct Baseline: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var covariateContext: String   // MVP always "default"
    public var windowDays: Int
    public var method: BaselineMethod
    public var center: Double
    public var spread: Double              // MAD
    public var bandLow: Double
    public var bandHigh: Double
    public var nPoints: Int
    public var provisional: Bool
    public var algorithmVersion: String
    public var validFrom: Date
    public var computedAt: Date
    public var unit: String

    public init(id: String, metricId: String, covariateContext: String = "default",
                windowDays: Int, method: BaselineMethod = .medianMAD, center: Double,
                spread: Double, bandLow: Double, bandHigh: Double, nPoints: Int,
                provisional: Bool, algorithmVersion: String, validFrom: Date, computedAt: Date,
                unit: String) {
        self.id = id; self.metricId = metricId; self.covariateContext = covariateContext
        self.windowDays = windowDays; self.method = method; self.center = center
        self.spread = spread; self.bandLow = bandLow; self.bandHigh = bandHigh
        self.nPoints = nPoints; self.provisional = provisional
        self.algorithmVersion = algorithmVersion; self.validFrom = validFrom
        self.computedAt = computedAt; self.unit = unit
    }

    /// Where a value sits relative to the personal band — never "good/bad", only position.
    public enum Position: String, Sendable { case below, within, above }

    /// A value exactly on a band edge is deliberately `.within` (both comparisons are strict);
    /// this boundary is inclusive by design and template selection depends on it staying that
    /// way, so treat a `<=`/`>=` edit here as a behavior change, not a cleanup.
    public func position(of value: Double) -> Position {
        if value < bandLow { return .below }
        if value > bandHigh { return .above }
        return .within
    }

    /// Standardized deviation from center (robust z). Used by the insight engine and to
    /// scale confidence to data quality.
    public func z(of value: Double) -> Double {
        guard spread > 0 else { return 0 }
        // 1.4826 makes MAD a consistent estimator of sigma for normal data.
        return (value - center) / (1.4826 * spread)
    }
}
