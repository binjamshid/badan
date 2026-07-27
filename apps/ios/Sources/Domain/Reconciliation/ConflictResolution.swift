import Foundation

/// Resolving an open `DataConflict` by the PERSON's own choice (EPIC-43 debt closeout).
///
/// `ConflictDecisionEngine` decides the conflicts a named rule can decide, and deliberately returns
/// `nil` for the rest — an unresolved conflict is a legitimate surfaced state (I3/I5), never a
/// forced guess. But since reconciliation-v2 was wired into real ingestion (commit `4266c68`), a
/// genuinely unresolved conflict can appear in `DataConflictsScreen` with no way for the user to
/// act on it. Surfaced-but-unactionable beats silently-averaged, which is why shipping it that way
/// was defensible; it is still a dead end. This is the missing half.
///
/// **The user's choice is its own rule id, never an existing one.** Reusing
/// `priorityOrderRuleId`/`manualWinsRuleId` would make the ledger claim an algorithm decided
/// something a person decided, and "why am I seeing this value?" would then explain the reading
/// with a rule that was never consulted. `userChoiceRuleId` keeps the journal honest about
/// provenance of the DECISION, which is the same discipline the rest of the app applies to
/// provenance of the data.
///
/// Everything else deliberately reuses `ConflictDecisionEngine.Outcome`: the same `loserIds`
/// derivation ("everyone who isn't the winner", never a separate list), the same
/// `winner_source`/`loser_source` detail keys `DataConflictsScreen`'s pills already read, and the
/// same `makeDecisions` write boundary. A user-resolved conflict is therefore indistinguishable
/// from an auto-resolved one everywhere EXCEPT the rule id — which is exactly the one place it
/// should differ.
public enum ConflictResolution {
    public static let userChoiceRuleId = "conflict.user_choice.v1"

    /// Builds the outcome for a user picking `winnerId` out of `candidates`.
    ///
    /// Returns `nil` when the pick isn't a real one — an unknown winner id, or fewer than two
    /// candidates. Both are caller bugs rather than user errors, and failing closed keeps a
    /// malformed call from journaling a decision that suppresses rows on the strength of an id
    /// nobody verified.
    public static func resolve(scope: ConflictScope, candidates: [CandidateReading],
                               winnerId: String) -> ConflictDecisionEngine.Outcome? {
        guard candidates.count >= 2, let winner = candidates.first(where: { $0.id == winnerId }) else { return nil }

        let loserCandidates = candidates.filter { $0.id != winner.id }
        var detail: [String: String] = [
            // Recorded so a later reader can tell WHY this rule fired without inferring it from the
            // rule id alone, matching how every engine rule stamps its own reason.
            "reason": "resolved_by_user_choice",
            "winner_source": winner.sourceId,
            "loser_source": Set(loserCandidates.map(\.sourceId)).sorted().joined(separator: ","),
        ]
        if case .metric(let metricId, _) = scope { detail["metric_id"] = metricId }

        return ConflictDecisionEngine.Outcome(
            ruleId: userChoiceRuleId, ruleVersion: ConflictDecisionEngine.ruleVersion,
            winnerId: winner.id, loserIds: loserCandidates.map(\.id).sorted(), detail: detail)
    }
}
