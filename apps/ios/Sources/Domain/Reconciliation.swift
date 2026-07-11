import Foundation

/// The dedup journal. When two sources report the same episode, one wins and the other is
/// suppressed (never deleted, I3) — and the decision is recorded here so power mode can
/// show it and, crucially, reverse it. Reversal clears `suppressed_by` and journals a
/// compensating row.
public struct ReconciliationDecision: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var batchId: String?
    public var rule: String            // e.g. "sleep.session_overlap.v1"
    public var ruleVersion: String
    public var keptRecordId: String
    public var suppressedRecordId: String
    public var score: Double?
    public var reversible: Bool
    public var reversedAt: Date?
    public var decidedAt: Date
    public var detail: [String: String]  // thresholds, overlap %, source names

    public init(id: String, batchId: String? = nil, rule: String, ruleVersion: String,
                keptRecordId: String, suppressedRecordId: String, score: Double? = nil,
                reversible: Bool = true, reversedAt: Date? = nil, decidedAt: Date,
                detail: [String: String] = [:]) {
        self.id = id; self.batchId = batchId; self.rule = rule; self.ruleVersion = ruleVersion
        self.keptRecordId = keptRecordId; self.suppressedRecordId = suppressedRecordId
        self.score = score; self.reversible = reversible; self.reversedAt = reversedAt
        self.decidedAt = decidedAt; self.detail = detail
    }

    public var isReversed: Bool { reversedAt != nil }
}
