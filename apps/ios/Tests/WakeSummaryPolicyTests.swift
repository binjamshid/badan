import XCTest
@testable import BADAN

/// The wake-triggered morning summary. The case that matters most here is `.retarget`: without it
/// the whole feature is inert, because reconcile books today's fixed-hour row the evening before and
/// `evaluateAndScheduleDecision` refuses a second row for the same class and day — so a wake at
/// 06:40 would be deduped away and the user would keep getting 08:00.
final class WakeSummaryPolicyTests: XCTestCase {

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 20; c.hour = hour; c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    // MARK: - The reason the policy exists

    func testAReservationForLaterTodayIsRetargetedNotSkipped() {
        // Reconcile booked 08:00 last night; the user woke at 06:40.
        let outcome = WakeSummaryPolicy.evaluate(
            now: date(6, 45),
            wakeInstant: date(6, 40),
            reservation: .init(scheduledFor: date(8), delivered: false),
            enabled: true)
        XCTAssertEqual(outcome, .retarget,
                       "a booking that has not fired must move to the wake, not block it")
    }

    func testNoReservationFires() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: date(6, 45), wakeInstant: date(6, 40),
                                                  reservation: nil, enabled: true),
                       .fire)
    }

    // MARK: - Never twice in a day

    func testADeliveredReservationIsFinal() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(
            now: date(6, 45), wakeInstant: date(6, 40),
            reservation: .init(scheduledFor: date(6), delivered: true), enabled: true),
            .alreadySentToday)
    }

    /// `markNotificationDelivered` only runs when the app observes a presentation or a tap, so a
    /// notification that fired while the app was never opened stays `scheduled` forever. Re-issuing
    /// it would send a second copy of a summary already sitting on the user's lock screen.
    func testAPassedButUnmarkedReservationIsTreatedAsSpentNotRetargetable() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(
            now: date(9), wakeInstant: date(8, 30),
            reservation: .init(scheduledFor: date(8), delivered: false), enabled: true),
            .alreadySentToday,
            "an unobserved-but-past reservation must fail towards silence, not towards a duplicate")
    }

    // MARK: - Recency

    func testAWakeOutsideTheWindowDoesNotFire() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: date(14), wakeInstant: date(6, 40),
                                                  reservation: nil, enabled: true),
                       .wakeTooOld)
    }

    func testTheWindowBoundaryIsInclusive() {
        let wake = date(6)
        let now = wake.addingTimeInterval(WakeSummaryPolicy.defaultRecencyWindow)
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: now, wakeInstant: wake,
                                                  reservation: nil, enabled: true),
                       .fire)
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: now.addingTimeInterval(1), wakeInstant: wake,
                                                  reservation: nil, enabled: true),
                       .wakeTooOld)
    }

    /// A clock change, a bad sample or a session still open. Never a reason to fire early.
    func testAFutureWakeIsNotYet() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: date(6), wakeInstant: date(7),
                                                  reservation: nil, enabled: true),
                       .wakeInFuture)
    }

    func testNoRecordedWakeIsNamedAsSuch() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: date(9), wakeInstant: nil,
                                                  reservation: nil, enabled: true),
                       .noWakeRecorded)
    }

    // MARK: - Opt-in

    func testAnOptedOutClassDecidesNothing() {
        XCTAssertEqual(WakeSummaryPolicy.evaluate(now: date(6, 45), wakeInstant: date(6, 40),
                                                  reservation: nil, enabled: false),
                       .notEnabled,
                       "opt-out must win over every other reason, as it does in the decision engine")
    }
}
