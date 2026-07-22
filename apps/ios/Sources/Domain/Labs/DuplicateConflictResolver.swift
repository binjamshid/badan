import Foundation

/// LAB-16: a weighted-score duplicate/conflict detector over `LabResult` rows (same analyte,
/// close-in-time, differing values). Produces a merge/link/flag decision — it NEVER decides to
/// delete anything, and it never mutates storage itself; it only DETECTS and DECIDES.
///
/// The three non-trivial decisions map onto mechanisms this codebase already has, reused rather than
/// re-invented:
///   * `.merge` — the two rows most likely describe the SAME physical reading (e.g. the same PDF
///     imported twice). The caller marks the later one dedup-suppressed via
///     `Provenance.suppressedBy` — the SAME field/mechanism `MeasurementRepository.suppress` already
///     uses for wearable readings (I3: dedup suppresses, never deletes). This file never sets that
///     field itself; it only recommends the decision.
///   * `.link` — plausibly related (e.g. a legitimate repeat/confirmatory draw) but not the same
///     reading. Surfaced to the user; no automatic action.
///   * `.flag` — values disagree and the pairing itself looks like a data problem (same report, or
///     near-identical timestamps). The caller sets `LabResult.reviewState = .conflictFlagged` for
///     explicit review.
/// An amended report is handled entirely by `makeAmendment` below APPENDING a new `LabResult`
/// revision that supersedes the old one — mirroring the revision-chain convention
/// `HydrationLedger.makeRevision`/`StrengthSetLedger` already established elsewhere in this codebase
/// — never an UPDATE/DELETE of the original row.
public enum DuplicateConflictResolver {

    public enum Decision: Equatable, Sendable {
        /// Not the same underlying reading — no relationship recorded.
        case distinct
        /// Plausibly related; surfaced, never auto-resolved.
        case link
        /// Values disagree and the pairing looks like a data problem — flagged for user review.
        case flag
        /// Near-identical value, near-identical time — most likely one physical reading ingested
        /// twice. The later row should be dedup-suppressed, never deleted.
        case merge
    }

    public struct Evaluation: Equatable, Sendable {
        public let score: Double
        public let decision: Decision
    }

    // Tunable weights/thresholds, named rather than scattered as magic numbers through the logic
    // below. Labs are drawn far less often than a wearable metric, so "close in time" is measured in
    // days, not minutes.
    private static let closeInTimeWindowHours: Double = 72
    private static let mergeScoreThreshold: Double = 0.85
    private static let flagScoreThreshold: Double = 0.55
    private static let linkScoreThreshold: Double = 0.30
    /// Two numeric readings count as "the same value" for merge purposes within this relative
    /// tolerance (handles e.g. a re-OCR'd "5.20" reading against an original "5.2").
    private static let valueMatchTolerance: Double = 0.005

    /// Scores and decides for one candidate pair; order-independent. Two results naming different
    /// analytes (`analyteKey`), or either already tombstoned, return `.distinct` immediately at score
    /// 0 — this resolver never compares across markers or considers a deleted row a candidate.
    public static func evaluate(_ a: LabResult, _ b: LabResult) -> Evaluation {
        guard a.analyteKey == b.analyteKey, a.deletedAt == nil, b.deletedAt == nil else {
            return Evaluation(score: 0, decision: .distinct)
        }

        let hoursApart = abs(a.provenance.measuredAt.timeIntervalSince(b.provenance.measuredAt)) / 3600
        let timeScore = max(0, 1 - hoursApart / closeInTimeWindowHours)
        guard timeScore > 0 else { return Evaluation(score: 0, decision: .distinct) }

        let sameReport = a.reportId == b.reportId
        let valueScore = valueSimilarity(a, b)

        // Weighted blend: time proximity and value agreement carry the most weight; sharing the
        // exact same report is a strong extra signal that a re-parse produced two rows for one fact.
        var score = 0.55 * timeScore + 0.35 * valueScore
        if sameReport { score = min(1, score + 0.15) }

        let decision: Decision
        if score >= mergeScoreThreshold && valueScore >= 0.9 {
            decision = .merge
        } else if score >= flagScoreThreshold {
            decision = (sameReport || hoursApart < 1) ? .flag : .link
        } else if score >= linkScoreThreshold {
            decision = .link
        } else {
            decision = .distinct
        }
        return Evaluation(score: score, decision: decision)
    }

    /// Every pairwise evaluation among `candidates` that resolves above `.distinct`. O(n²) over the
    /// input, which is fine at the scale one analyte's history reaches — labs are drawn far less
    /// often than wearable samples, so this never runs over more than a handful of rows at a time.
    public static func evaluate(candidates: [LabResult]) -> [(a: LabResult, b: LabResult, evaluation: Evaluation)] {
        var out: [(a: LabResult, b: LabResult, evaluation: Evaluation)] = []
        guard candidates.count > 1 else { return out }
        for i in 0..<(candidates.count - 1) {
            for j in (i + 1)..<candidates.count {
                let evaluation = evaluate(candidates[i], candidates[j])
                if evaluation.decision != .distinct {
                    out.append((a: candidates[i], b: candidates[j], evaluation: evaluation))
                }
            }
        }
        return out
    }

    /// 1.0 when both parse to the same number (in the same unit) within tolerance, degrading
    /// smoothly as they diverge. Falls back to exact raw-text equality when either side has no
    /// `numericValue` or the units differ — a qualitative/textual result (two "Positive" rows) has
    /// no magnitude to compare, and two different units are never treated as directly comparable
    /// numbers here (that conversion judgment belongs to `UnitNormalization`, not this detector).
    private static func valueSimilarity(_ a: LabResult, _ b: LabResult) -> Double {
        if let av = a.numericValue, let bv = b.numericValue, a.rawUnit == b.rawUnit {
            let denom = max(abs(av), abs(bv), 1e-9)
            let relDiff = abs(av - bv) / denom
            if relDiff <= valueMatchTolerance { return 1.0 }
            return max(0, 1 - relDiff)
        }
        let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalize(a.rawValueText) == normalize(b.rawValueText) ? 1.0 : 0.0
    }

    // MARK: - Amendment (supersede-with-history; the ONLY path this file offers for changing a value)

    /// Builds an amended result that SUPERSEDES `original` — an APPEND, never an UPDATE/DELETE of
    /// `original` (I2-flavored, exactly like `HydrationLedger.makeRevision`/`StrengthSetLedger`'s
    /// revision chain). This is how "an amended report supersedes-with-history" (LAB-16) is actually
    /// applied: the caller builds the new row here, then the repository INSERTs it — `original` is
    /// never touched. Fields not passed are carried over from `original`, so "just fix the value"
    /// keeps everything else (panel, analyte identity, sensitivity tier…) unchanged.
    public static func makeAmendment(
        of original: LabResult, id: String, rawValueText: String? = nil,
        comparator: LabComparator?? = nil, numericValue: Double?? = nil, rawUnit: String?? = nil,
        canonicalValue: Double?? = nil, canonicalUnit: String?? = nil,
        reviewState: LabReviewState = .corrected, provenance: Provenance, updatedAt: Date,
        originDeviceId: String
    ) -> LabResult {
        LabResult(
            id: id, reportId: original.reportId, panelId: original.panelId,
            analyteId: original.analyteId, customLabel: original.customLabel,
            rawValueText: rawValueText ?? original.rawValueText,
            comparator: comparator ?? original.comparator,
            numericValue: numericValue ?? original.numericValue,
            rawUnit: rawUnit ?? original.rawUnit,
            canonicalValue: canonicalValue ?? original.canonicalValue,
            canonicalUnit: canonicalUnit ?? original.canonicalUnit,
            resultType: original.resultType, reviewState: reviewState,
            sensitivityTier: original.sensitivityTier, originalId: original.originalId,
            supersedes: original.id, revision: original.revision + 1,
            provenance: provenance, updatedAt: updatedAt, originDeviceId: originDeviceId)
    }
}
