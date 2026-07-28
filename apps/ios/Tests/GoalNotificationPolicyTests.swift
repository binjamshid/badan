import XCTest
@testable import BADAN

/// The `goalReached` producer's rule. Half of this suite is about what the policy must NOT do:
/// `CLAUDE.md`'s wellness-safe guardrail and `GoalEvaluation`'s own doc both say BADAN describes
/// rather than grades, and a goals notification is the easiest place in the app to break that.
final class GoalNotificationPolicyTests: XCTestCase {

    private func candidate(_ id: String, active: Bool = true,
                           _ evaluation: GoalEvaluation) -> GoalNotificationPolicy.Candidate {
        .init(goalId: id, active: active, evaluation: evaluation)
    }

    func testAnnouncesAReachedGoal() {
        let picked = GoalNotificationPolicy.goalToAnnounce([candidate("a", .onTrack)])
        XCTAssertEqual(picked?.goalId, "a")
    }

    func testAnnouncesNothingWhenNoGoalIsReached() {
        XCTAssertNil(GoalNotificationPolicy.goalToAnnounce([
            candidate("a", .offTrack), candidate("b", .noData),
        ]))
    }

    /// A goal with no reading is not a reached goal. `GoalEvaluation.noData` exists precisely so
    /// "we don't know" is distinguishable from "no", and announcing on it would be inventing news.
    func testNoDataIsNeverAnnounced() {
        XCTAssertNil(GoalNotificationPolicy.goalToAnnounce([candidate("a", .noData)]))
    }

    /// The user switched this goal off. Telling them about it is noise about a decision they have
    /// already made.
    func testAPausedGoalIsSkippedEvenWhenItsMetricIsPastTarget() {
        XCTAssertNil(GoalNotificationPolicy.goalToAnnounce([
            candidate("a", active: false, .onTrack),
        ]))
    }

    /// A foreground evaluation and a background one must agree on which goal was announced, or the
    /// ledger's once-a-day guard would be protecting a different notification than the one already
    /// sent.
    func testTheChoiceIsDeterministicAcrossOrderings() {
        let forward = GoalNotificationPolicy.goalToAnnounce([
            candidate("a", .onTrack), candidate("b", .onTrack), candidate("c", .onTrack),
        ])
        let reversed = GoalNotificationPolicy.goalToAnnounce([
            candidate("c", .onTrack), candidate("b", .onTrack), candidate("a", .onTrack),
        ])
        XCTAssertEqual(forward?.goalId, reversed?.goalId)
        XCTAssertEqual(forward?.goalId, "a")
    }

    /// Four goals reached in an afternoon must not be four notifications. Only one candidate is ever
    /// returned; the ledger's class+day idempotency enforces the rest.
    func testOnlyOneGoalIsEverAnnouncedAtATime() {
        let picked = GoalNotificationPolicy.goalToAnnounce([
            candidate("a", .onTrack), candidate("b", .onTrack),
            candidate("c", .onTrack), candidate("d", .onTrack),
        ])
        XCTAssertNotNil(picked)
    }

    func testEmptyInputAnnouncesNothing() {
        XCTAssertNil(GoalNotificationPolicy.goalToAnnounce([]))
    }

    // MARK: - The guardrail

    /// There is no `goalAtRisk`. This is not an omission to be filled in later: it is the product
    /// rule, and a test is the only thing that makes "we decided not to" survive contact with a
    /// future change that looks obviously useful.
    func testThereIsNoAtRiskNotificationClass() {
        let names = NotificationClass.allCases.map(\.rawValue)
        XCTAssertFalse(names.contains { $0.lowercased().contains("risk") },
                       "telling someone they are behind is a verdict on their day, not a description")
        XCTAssertFalse(names.contains { $0.lowercased().contains("streak") })
    }

    /// The copy states the fact and stops — praise is grading with a friendlier face, and it implies
    /// the inverse on every day the goal is missed.
    func testGoalCopyDoesNotCongratulateOrScore() {
        for text in [NotificationClassCopy.valueFreeContent(.goalReached).body.en,
                     NotificationClassCopy.settingsRow(.goalReached).label.en,
                     NotificationClassCopy.settingsRow(.goalReached).hint.en] {
            let lowered = text.lowercased()
            for banned in ["congrat", "well done", "great job", "streak", "badge", "score", "!"] {
                XCTAssertFalse(lowered.contains(banned),
                               "goal copy must describe, not grade — found \"\(banned)\" in \"\(text)\"")
            }
        }
        for text in [NotificationClassCopy.valueFreeContent(.goalReached).body.en,
                     NotificationClassCopy.valueFreeContent(.goalReached).body.ar] {
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C },
                           "no emoji in a wellness notification")
        }
    }
}
