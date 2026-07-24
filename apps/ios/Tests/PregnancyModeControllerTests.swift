import Foundation
import XCTest
@testable import BADAN

/// A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice): `PregnancyModeController`'s legal-
/// transition table — the "zero non-user-initiated transitions" guarantee, verified structurally:
/// every mode change requires an explicit `PregnancyModeTransitionRequest`, and only the requests
/// named in `legalTransitions` ever succeed from a given mode.
final class PregnancyModeControllerTests: XCTestCase {
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"

    private func provenance() -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: clock.now(),
                  measuredTimezone: "UTC", recordedAt: clock.now(), ingestedAt: clock.now())
    }

    // MARK: - beginJourney

    func testBeginJourneyStartsTTCWhenNoLiveRecordExists() throws {
        let record = try PregnancyModeController.beginJourney(
            request: .beginTTC, currentLiveRecord: nil, id: "J-1", provenance: provenance(),
            asOf: clock.now(), originDeviceId: device)
        XCTAssertEqual(record.mode, .ttc)
        XCTAssertTrue(record.isOriginal)
        XCTAssertEqual(record.revision, 1)
    }

    func testBeginJourneyStartsPregnancyConfirmedWhenNoLiveRecordExists() throws {
        let record = try PregnancyModeController.beginJourney(
            request: .beginPregnancyConfirmed, currentLiveRecord: nil, id: "J-2", provenance: provenance(),
            asOf: clock.now(), originDeviceId: device)
        XCTAssertEqual(record.mode, .pregnancyConfirmed)
    }

    func testBeginJourneyThrowsWhenALiveJourneyAlreadyExists() throws {
        let existing = try PregnancyModeController.beginJourney(
            request: .beginTTC, currentLiveRecord: nil, id: "J-3", provenance: provenance(),
            asOf: clock.now(), originDeviceId: device)
        XCTAssertThrowsError(try PregnancyModeController.beginJourney(
            request: .beginTTC, currentLiveRecord: existing, id: "J-4", provenance: provenance(),
            asOf: clock.now(), originDeviceId: device)) { error in
            XCTAssertEqual(error as? PregnancyModeController.TransitionError, .liveJourneyAlreadyExists)
        }
    }

    /// General audit finding 3: this path must never fabricate a `from:` mode via `.illegalTransition`
    /// — it now throws its own dedicated case instead, which carries no invented "current mode" at all.
    func testBeginJourneyRejectsANonBeginRequest() {
        XCTAssertThrowsError(try PregnancyModeController.beginJourney(
            request: .confirmPregnancy, currentLiveRecord: nil, id: "J-5", provenance: provenance(),
            asOf: clock.now(), originDeviceId: device)) { error in
            XCTAssertEqual(error as? PregnancyModeController.TransitionError,
                           .invalidBeginRequest(request: .confirmPregnancy),
                           "must not fabricate a from: mode via .illegalTransition (general audit finding 3)")
        }
    }

    /// Loss-handling audit finding 1 (CRITICAL): a live `.lossDeclared` record must NOT block
    /// starting a brand-new, separate journey — this was the actual bug (the guard treated ANY live
    /// record as blocking). Every other mode keeps blocking, unchanged.
    func testBeginJourneySucceedsWhenTheCurrentLiveRecordIsLossDeclared() throws {
        let lossRecord = record(mode: .lossDeclared)
        let new = try PregnancyModeController.beginJourney(
            request: .beginTTC, currentLiveRecord: lossRecord, id: "NEW-J", provenance: provenance(),
            asOf: clock.now(), originDeviceId: device)
        XCTAssertEqual(new.mode, .ttc)
        XCTAssertEqual(new.originalId, "NEW-J", "a brand-new, separately user-initiated record — never a " +
                       "reactivation of the lost journey's own originalId")
        XCTAssertNotEqual(new.originalId, lossRecord.originalId)
    }

    /// Every mode OTHER than `.lossDeclared` must keep blocking a new journey — only the loss case
    /// was a confirmed bug; this audit did not flag `.postpartumHandoff` or any active mode.
    func testBeginJourneyStillBlocksForEveryModeOtherThanLossDeclared() {
        for mode: PregnancyJourneyMode in [.ttc, .pregnancyConfirmed, .latePregnancy, .birthDelivery, .postpartumHandoff] {
            let existing = record(mode: mode)
            XCTAssertThrowsError(try PregnancyModeController.beginJourney(
                request: .beginTTC, currentLiveRecord: existing, id: "NEW-J", provenance: provenance(),
                asOf: clock.now(), originDeviceId: device), "\(mode) must still block a new journey") { error in
                XCTAssertEqual(error as? PregnancyModeController.TransitionError, .liveJourneyAlreadyExists)
            }
        }
    }

    /// `PregnancyJourneyMode.blocksNewJourney` itself — the exact, exhaustive vocabulary the guard
    /// above reads from.
    func testBlocksNewJourneyIsFalseOnlyForLossDeclared() {
        for mode in PregnancyJourneyMode.allCases {
            XCTAssertEqual(mode.blocksNewJourney, mode != .lossDeclared, "\(mode) blocksNewJourney mismatch")
        }
    }

    // MARK: - applyTransition: the exhaustive legal-transition table

    private func record(mode: PregnancyJourneyMode) -> PregnancyRecord {
        PregnancyRecord(id: "CUR", mode: mode, originalId: "CUR", provenance: provenance(),
                        updatedAt: clock.now(), originDeviceId: device)
    }

    func testEveryLegalTransitionSucceedsAndAppendsARevisionRatherThanMutating() throws {
        let cases: [(PregnancyJourneyMode, PregnancyModeTransitionRequest, PregnancyJourneyMode)] = [
            (.ttc, .confirmPregnancy, .pregnancyConfirmed),
            (.ttc, .declareLoss, .lossDeclared),
            (.pregnancyConfirmed, .declareLatePregnancy, .latePregnancy),
            (.pregnancyConfirmed, .declareBirth, .birthDelivery),
            (.pregnancyConfirmed, .declareLoss, .lossDeclared),
            (.latePregnancy, .declareBirth, .birthDelivery),
            (.latePregnancy, .declareLoss, .lossDeclared),
            (.birthDelivery, .declarePostpartumHandoff, .postpartumHandoff),
        ]
        for (from, request, expectedTo) in cases {
            let current = record(mode: from)
            let next = try PregnancyModeController.applyTransition(
                current: current, request: request, newId: "NEXT", provenance: provenance(),
                asOf: clock.now(), originDeviceId: device)
            XCTAssertEqual(next.mode, expectedTo, "\(from) -> \(request) should reach \(expectedTo)")
            XCTAssertEqual(next.supersedes, current.id, "the next revision supersedes the current head")
            XCTAssertEqual(next.originalId, current.originalId, "the journey identity is preserved")
            XCTAssertEqual(next.revision, current.revision + 1)
            XCTAssertEqual(current.mode, from, "the CURRENT record is never mutated by applying a transition")
        }
    }

    func testEveryIllegalTransitionThrowsAndNothingIsReturned() {
        let illegalCases: [(PregnancyJourneyMode, PregnancyModeTransitionRequest)] = [
            (.ttc, .declareLatePregnancy),
            (.ttc, .declareBirth),
            (.ttc, .declarePostpartumHandoff),
            (.pregnancyConfirmed, .confirmPregnancy),
            (.pregnancyConfirmed, .declarePostpartumHandoff),
            (.latePregnancy, .confirmPregnancy),
            (.latePregnancy, .declareLatePregnancy),
            (.latePregnancy, .declarePostpartumHandoff),
            (.birthDelivery, .confirmPregnancy),
            (.birthDelivery, .declareLoss),
            (.birthDelivery, .declareLatePregnancy),
            (.postpartumHandoff, .confirmPregnancy),
            (.postpartumHandoff, .declareLoss),
            (.postpartumHandoff, .declarePostpartumHandoff),
            (.lossDeclared, .confirmPregnancy),
            (.lossDeclared, .declareLoss),
            (.lossDeclared, .declareBirth),
        ]
        for (from, request) in illegalCases {
            let current = record(mode: from)
            XCTAssertThrowsError(try PregnancyModeController.applyTransition(
                current: current, request: request, newId: "NEXT", provenance: provenance(),
                asOf: clock.now(), originDeviceId: device),
                "\(from) -> \(request) must be illegal") { error in
                guard let transitionError = error as? PregnancyModeController.TransitionError,
                      case .illegalTransition(let erroredFrom, let erroredRequest) = transitionError else {
                    XCTFail("expected .illegalTransition, got \(error)")
                    return
                }
                XCTAssertEqual(erroredFrom, from)
                XCTAssertEqual(erroredRequest, request)
            }
        }
    }

    func testApplyTransitionRejectsBeginRequests() {
        let current = record(mode: .ttc)
        for request in [PregnancyModeTransitionRequest.beginTTC, .beginPregnancyConfirmed] {
            XCTAssertThrowsError(try PregnancyModeController.applyTransition(
                current: current, request: request, newId: "NEXT", provenance: provenance(),
                asOf: clock.now(), originDeviceId: device))
        }
    }

    /// The terminal-modes guarantee named in `PregnancyJourneyMode`'s own doc: nothing transitions
    /// FORWARD out of `.lossDeclared` or `.postpartumHandoff` within the same chain.
    func testLossDeclaredAndPostpartumHandoffAreTerminalWithinTheSameChain() {
        for mode in [PregnancyJourneyMode.lossDeclared, .postpartumHandoff] {
            let transitions: Set<PregnancyModeTransitionRequest> = PregnancyModeController.legalTransitions[mode] ?? []
            XCTAssertTrue(transitions.isEmpty, "\(mode) must have no outgoing transitions")
        }
    }

    /// research doc §9 line 40: loss is reachable from TTC through late pregnancy, and ONLY those
    /// three modes.
    func testCanDeclareLossFromThisModeMatchesExactlyTTCThroughLatePregnancy() {
        for mode in PregnancyJourneyMode.allCases {
            let expected: Bool
            switch mode {
            case .ttc, .pregnancyConfirmed, .latePregnancy: expected = true
            case .birthDelivery, .postpartumHandoff, .lossDeclared: expected = false
            }
            XCTAssertEqual(mode.canDeclareLossFromThisMode, expected, "\(mode) loss-reachability mismatch")
            XCTAssertEqual(PregnancyModeController.legalTransitions[mode]?.contains(.declareLoss) ?? false, expected,
                           "\(mode)'s legal-transition table must agree with canDeclareLossFromThisMode")
        }
    }

    // MARK: - GestationalWeekDisplay (the computed "automatic sub-mode" — never stored)

    func testGestationalWeekDisplayReturnsNilWithNoEstimate() {
        XCTAssertNil(GestationalWeekDisplay.currentWeek(dueDateEstimate: nil, asOf: clock.now()))
    }

    func testGestationalWeekDisplayComputesAReasonableWeekFromACenterDate() {
        let calendar = Calendar(identifier: .gregorian)
        let asOf = clock.now()
        // 140 days until the estimated due date -> 140 days pregnant -> week 20.
        let center = calendar.date(byAdding: .day, value: 140, to: asOf)!
        let estimate = DueDateEstimate(id: "E", pregnancyRecordOriginalId: "J", generatedAt: asOf,
                                       rangeLow: center, rangeCenter: center, rangeHigh: center,
                                       confidence: 0.3, algorithmVersion: "1.0.0", updatedAt: asOf,
                                       originDeviceId: device)
        XCTAssertEqual(GestationalWeekDisplay.currentWeek(dueDateEstimate: estimate, asOf: asOf, calendar: calendar), 20)
    }

    // MARK: - PregnancyContentGate: the structural loss-suppression guarantee

    func testContentGateReturnsEmptySetOnceModeIsLossDeclaredRegardlessOfPriorState() {
        let lossRecord = record(mode: .lossDeclared)
        XCTAssertTrue(PregnancyContentGate.visibleForwardLookingSections(for: lossRecord).isEmpty,
                     "no forward-looking/celebratory section may ever render once loss is declared")
    }

    func testContentGateReturnsEverySectionForAnActivePregnancy() {
        for mode: PregnancyJourneyMode in [.pregnancyConfirmed, .latePregnancy] {
            XCTAssertEqual(PregnancyContentGate.visibleForwardLookingSections(for: record(mode: mode)),
                          Set(PregnancyContentSection.allCases))
        }
    }

    func testContentGateReturnsEmptyForNilOrDeletedRecord() {
        XCTAssertTrue(PregnancyContentGate.visibleForwardLookingSections(for: nil).isEmpty)
        var deleted = record(mode: .pregnancyConfirmed)
        deleted.deletedAt = clock.now()
        XCTAssertTrue(PregnancyContentGate.visibleForwardLookingSections(for: deleted).isEmpty)
    }
}
