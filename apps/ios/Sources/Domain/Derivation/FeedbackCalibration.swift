import Foundation

/// What a user said about a derived value: did the number match how they felt?
///
/// The question is about the NUMBER's fit, never about health, and the vocabulary is deliberately
/// small. "Felt better than this" and "felt worse than this" are directions, not magnitudes — the
/// user is not asked to estimate how wrong it was, because they could not, and a magnitude would
/// invite a precision the whole mechanism does not have.
public enum FeedbackDirection: String, Codable, Hashable, Sendable, CaseIterable {
    case matches
    /// The number read higher than the day felt — BADAN over-scored it.
    case over
    /// The number read lower than the day felt — BADAN under-scored it.
    case under

    /// The sign this contributes to an offset. `matches` contributes zero rather than being
    /// excluded, so agreement actively pulls a drifting calibration back toward nothing.
    var signedWeight: Double {
        switch self {
        case .matches: return 0
        case .over: return -1
        case .under: return 1
        }
    }
}

/// One recorded reaction to one derived value.
///
/// `algorithmId`/`algorithmVersion` are load-bearing, not bookkeeping: feedback about the sleep-led
/// readiness method says nothing about the autonomic one, and a version bump means the number the
/// user judged is not the number the code now produces.
public struct DerivedFeedback: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var periodKey: String
    public var derivedValueId: String
    public var algorithmId: String
    public var algorithmVersion: String
    public var direction: FeedbackDirection
    public var createdAt: Date

    public init(id: String, metricId: String, periodKey: String, derivedValueId: String,
                algorithmId: String, algorithmVersion: String, direction: FeedbackDirection,
                createdAt: Date) {
        self.id = id; self.metricId = metricId; self.periodKey = periodKey
        self.derivedValueId = derivedValueId; self.algorithmId = algorithmId
        self.algorithmVersion = algorithmVersion; self.direction = direction
        self.createdAt = createdAt
    }
}

/// A learned personal offset for one (metric, method) pair.
///
/// Append-only and latest-wins, exactly like `derived_values` (I2): an older calibration row is what
/// explains a value computed while it was in force, so it is never rewritten.
public struct MetricCalibration: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var algorithmId: String
    public var algorithmVersion: String
    /// Points to add to the computed value. Signed, and clamped by the contract's `maxOffsetPoints`.
    public var offset: Double
    public var sampleCount: Int
    public var computedAt: Date

    public init(id: String, metricId: String, algorithmId: String, algorithmVersion: String,
                offset: Double, sampleCount: Int, computedAt: Date) {
        self.id = id; self.metricId = metricId; self.algorithmId = algorithmId
        self.algorithmVersion = algorithmVersion; self.offset = offset
        self.sampleCount = sampleCount; self.computedAt = computedAt
    }

    /// The reserved manifest `recordId` that discloses this calibration on a derived row.
    ///
    /// Follows the documented synthetic-recordId convention `CorrelationEngine` already establishes
    /// with `stat:<name>` — a manifest input whose `recordId` names a thing that is not a stored
    /// measurement. Chosen over a new `derived_values` column because that table is duplicated in
    /// the sensitive DB (so a column is two schema changes), and because the manifest is already the
    /// surface `MetricAnatomySheet` reads to explain a number.
    public var manifestRecordId: String { "calibration:\(id)" }

    public static let manifestRecordIdPrefix = "calibration:"
}

/// The calibration's own constants, from the contract.
///
/// `isLoaded == false` when the entry is absent, and every caller treats that as "apply no
/// calibration" — the same fail-closed posture every other engine has. That is the whole reason
/// these constants are contract data rather than Swift literals: a silent default is
/// indistinguishable, on the stored row, from an authored constant.
public struct CalibrationSpec: Sendable, Hashable {
    public let algorithm: AlgorithmVersion
    public let minFeedbackEvents: Int
    public let maxOffsetPoints: Double
    public let learningRate: Double
    public let decayHalfLifeDays: Double
    public let isLoaded: Bool

    static let contractId = "calibration.user_feedback_offset"

    static func load(from registry: AlgorithmRegistry) -> CalibrationSpec {
        guard let def = registry.definition(contractId),
              let minEvents = def.params["minFeedbackEvents"],
              let maxOffset = def.params["maxOffsetPoints"],
              let rate = def.params["learningRate"],
              let halfLife = def.params["decayHalfLifeDays"] else { return .unavailable }
        return CalibrationSpec(algorithm: def.algorithmVersion, minFeedbackEvents: Int(minEvents),
                               maxOffsetPoints: maxOffset, learningRate: rate,
                               decayHalfLifeDays: halfLife, isLoaded: true)
    }

    static let defaultShared = load(from: .shared)

    /// The degenerate spec. `minFeedbackEvents: .max` means no amount of feedback ever reaches the
    /// threshold, so this can never produce an offset even if `isLoaded` were ignored.
    static let unavailable = CalibrationSpec(
        algorithm: AlgorithmVersion(algorithmId: contractId, semver: "0.0.0", introducedIn: "0.0.0"),
        minFeedbackEvents: .max, maxOffsetPoints: 0, learningRate: 0, decayHalfLifeDays: 1,
        isLoaded: false)
}

/// Turns feedback into an offset. Pure — no repository, no clock reading, no I/O — so every rule
/// below is testable on its own.
public enum FeedbackCalibrator {
    /// The offset implied by `feedback`, or `nil` when none should be applied.
    ///
    /// Returns `nil` (not `0`) below the event floor, because "no calibration" and "a calibration
    /// that happens to be zero" are different things to a reader of the row: only the second should
    /// produce a `calibration:` manifest input.
    public static func offset(from feedback: [DerivedFeedback], asOf: Date,
                              spec: CalibrationSpec) -> Double? {
        guard spec.isLoaded, feedback.count >= spec.minFeedbackEvents else { return nil }

        var weightedSum = 0.0
        var weightTotal = 0.0
        for event in feedback {
            let ageDays = max(0, asOf.timeIntervalSince(event.createdAt) / 86_400)
            // Older feedback counts for less, so a calibration follows how someone feels now
            // rather than staying anchored to a month they were ill.
            let decay = pow(0.5, ageDays / max(0.0001, spec.decayHalfLifeDays))
            weightedSum += event.direction.signedWeight * decay
            weightTotal += decay
        }
        guard weightTotal > 0 else { return nil }

        // Net direction in [-1, 1], scaled to points by the learning rate and clamped. The clamp is
        // what keeps a calibrated readiness recognisably a readiness — see `maxOffsetPoints`' note.
        let net = weightedSum / weightTotal
        let raw = net * spec.learningRate * spec.maxOffsetPoints
        return min(spec.maxOffsetPoints, max(-spec.maxOffsetPoints, raw))
    }
}
