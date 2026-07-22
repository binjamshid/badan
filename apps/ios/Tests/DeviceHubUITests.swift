import Foundation
import XCTest
@testable import BADAN

/// EPIC-43 — coverage for the Device Hub UI lane's own view-logic and wiring: reachability
/// (mirrors `scripts/check-reachability.py`'s own check, as a real XCTest — see
/// `WorkoutUITests` for the established pattern this copies), the pure healthy/needs-attention/
/// disconnected card-state rules (`DeviceHealthClassifier`), and the "why am I seeing this
/// value?" disclosure's rule-name rendering (`ReconciliationDisclosureFormat`).
///
/// No CoreBluetooth anywhere in this file, matching the feature it tests: every fixture below is
/// a plain `Source`/`Device`/`ReconciliationDecision` value, never a real or simulated BLE
/// connection.
final class DeviceHubUITests: XCTestCase {
    private let device = "test-device"
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Reachability (mirrors scripts/check-reachability.py's own check, as a real XCTest)

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DeviceHubUITests.swift
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
    }()

    private static func sourceText(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Drops every `#Preview { ... }` block's BODY (brace-matched), matching
    /// `check-reachability.py`'s `strip_preview_blocks` exactly.
    private static func strippingPreviewBlocks(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while let previewRange = text.range(of: "#Preview", range: index..<text.endIndex) {
            result += text[index..<previewRange.lowerBound]
            guard let openBrace = text[previewRange.upperBound...].firstIndex(of: "{") else {
                index = text.endIndex
                break
            }
            var depth = 1
            var cursor = text.index(after: openBrace)
            while cursor < text.endIndex, depth > 0 {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" { depth -= 1 }
                cursor = text.index(after: cursor)
            }
            index = cursor
        }
        result += text[index...]
        return result
    }

    private func assertReachable(_ typeName: String, in relativePath: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = Self.strippingPreviewBlocks(Self.sourceText(relativePath))
        XCTAssertTrue(text.contains("\(typeName)("),
                      "\(typeName) has no construction site in \(relativePath) outside a #Preview — " +
                      "this is exactly the 'built but dark' defect check-reachability.py guards against.",
                      file: file, line: line)
    }

    func testDeviceHubScreenIsReachableFromSettings() {
        assertReachable("DeviceHubScreen", in: "apps/ios/Sources/Features/Settings/PrivacySecuritySettingsScreen.swift")
    }

    func testDeviceDetailScreenIsReachableFromDeviceHub() {
        assertReachable("DeviceDetailScreen", in: "apps/ios/Sources/Features/DeviceHub/DeviceHubScreen.swift")
    }

    func testDataConflictsScreenIsReachableFromDeviceHub() {
        assertReachable("DataConflictsScreen", in: "apps/ios/Sources/Features/DeviceHub/DeviceHubScreen.swift")
    }

    // MARK: - Fixtures

    private func source(
        status: SourceStatus = .active, connectedAt: Date? = nil, lastDeliveryAt: Date? = nil
    ) -> Source {
        Source(id: "source-1", type: .healthkit, displayName: "Apple Health", status: status,
               connectedAt: connectedAt, lastDeliveryAt: lastDeliveryAt, updatedAt: now, originDeviceId: device)
    }

    private func deviceRow(lastSeen: Date) -> Device {
        Device(id: "device-1", sourceId: "source-1", name: "Apple Watch", firstSeen: now.addingTimeInterval(-100_000),
               lastSeen: lastSeen, updatedAt: now, originDeviceId: device)
    }

    // MARK: - DeviceHealthClassifier: source status

    func testActiveSourceWithRecentDeliveryIsHealthy() {
        let src = source(lastDeliveryAt: now.addingTimeInterval(-3600)) // 1h ago
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .healthy)
    }

    func testActiveSourceWithStaleDeliveryNeedsAttention() {
        let src = source(lastDeliveryAt: now.addingTimeInterval(-72 * 3600)) // 72h ago, past the 48h threshold
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .needsAttention)
    }

    func testActiveSourceWithDeliveryExactlyAtThresholdIsStillHealthy() {
        let src = source(lastDeliveryAt: now.addingTimeInterval(-DeviceHealthClassifier.staleAfter))
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .healthy,
                       "the boundary itself must still read healthy (<=, not <)")
    }

    func testActiveSourceNeverDeliveredButJustConnectedIsHealthyNotAlarming() {
        let src = source(connectedAt: now.addingTimeInterval(-60), lastDeliveryAt: nil)
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .healthy,
                       "a source that just connected hasn't had a chance to sync yet — that's normal")
    }

    func testActiveSourceNeverDeliveredAndConnectedLongAgoNeedsAttention() {
        let src = source(connectedAt: now.addingTimeInterval(-1_000_000), lastDeliveryAt: nil)
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .needsAttention)
    }

    func testRevokedSourceIsDisconnectedRegardlessOfDeliveryHistory() {
        let src = source(status: .revoked, lastDeliveryAt: now.addingTimeInterval(-60))
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .disconnected)
    }

    func testHiddenSourceIsDisconnected() {
        let src = source(status: .hidden, lastDeliveryAt: now.addingTimeInterval(-60))
        XCTAssertEqual(DeviceHealthClassifier.status(of: src, now: now), .disconnected)
    }

    // MARK: - DeviceHealthClassifier: device status (floored by its source)

    func testDeviceWithRecentLastSeenUnderHealthySourceIsHealthy() {
        let d = deviceRow(lastSeen: now.addingTimeInterval(-60))
        XCTAssertEqual(DeviceHealthClassifier.status(of: d, sourceStatus: .healthy, now: now), .healthy)
    }

    func testDeviceWithStaleLastSeenNeedsAttentionEvenUnderAHealthySource() {
        let d = deviceRow(lastSeen: now.addingTimeInterval(-72 * 3600))
        XCTAssertEqual(DeviceHealthClassifier.status(of: d, sourceStatus: .healthy, now: now), .needsAttention)
    }

    func testDeviceUnderADisconnectedSourceIsAlwaysDisconnectedRegardlessOfItsOwnLastSeen() {
        let d = deviceRow(lastSeen: now.addingTimeInterval(-60)) // fresh lastSeen
        XCTAssertEqual(DeviceHealthClassifier.status(of: d, sourceStatus: .disconnected, now: now), .disconnected,
                       "a device can never read healthier than the source carrying it")
    }

    // MARK: - DeviceHealthClassifier: worse() ordering

    func testWorseOrdersDisconnectedAboveNeedsAttentionAboveHealthy() {
        XCTAssertEqual(DeviceHealthClassifier.worse(.healthy, .needsAttention), .needsAttention)
        XCTAssertEqual(DeviceHealthClassifier.worse(.needsAttention, .disconnected), .disconnected)
        XCTAssertEqual(DeviceHealthClassifier.worse(.disconnected, .healthy), .disconnected)
        XCTAssertEqual(DeviceHealthClassifier.worse(.healthy, .healthy), .healthy)
    }

    // MARK: - DeviceHealthClassifier: whole-card aggregate

    func testCardOverallStatusIsTheWorstAmongSourceAndEveryDevice() {
        let src = source(lastDeliveryAt: now.addingTimeInterval(-3600)) // healthy source
        let healthyDevice = deviceRow(lastSeen: now.addingTimeInterval(-60))
        let staleDevice = Device(id: "device-2", sourceId: "source-1", name: "Old sensor",
                                 firstSeen: now.addingTimeInterval(-500_000), lastSeen: now.addingTimeInterval(-90 * 3600),
                                 updatedAt: now, originDeviceId: device)

        let (sourceStatus, perDevice, overall) = DeviceHealthClassifier.cardStatus(
            source: src, devices: [healthyDevice, staleDevice], now: now)

        XCTAssertEqual(sourceStatus, .healthy)
        XCTAssertEqual(perDevice["device-1"], .healthy)
        XCTAssertEqual(perDevice["device-2"], .needsAttention)
        XCTAssertEqual(overall, .needsAttention, "one stale device must pull the whole card's badge down")
    }

    func testCardWithNoDevicesReflectsOnlyTheSourcesOwnStatus() {
        let src = source(status: .revoked)
        let (sourceStatus, perDevice, overall) = DeviceHealthClassifier.cardStatus(source: src, devices: [], now: now)
        XCTAssertEqual(sourceStatus, .disconnected)
        XCTAssertTrue(perDevice.isEmpty)
        XCTAssertEqual(overall, .disconnected)
    }

    // MARK: - "Why am I seeing this value?" disclosure (ReconciliationDisclosureFormat)

    private func decision(rule: String, ruleVersion: String) -> ReconciliationDecision {
        ReconciliationDecision(id: "decision-1", rule: rule, ruleVersion: ruleVersion,
                               keptRecordId: "kept-1", suppressedRecordId: "suppressed-1", decidedAt: now)
    }

    func testDisclosureRendersTheActualDecisionsRuleNameAndVersion() {
        let d = decision(rule: "sleep.session_overlap.v1", ruleVersion: "1")
        XCTAssertEqual(ReconciliationDisclosureFormat.ruleLine(d), "sleep.session_overlap.v1 · 1",
                       "must render the decision's OWN rule/version, not a canned label")
    }

    func testDisclosureRendersAnUnknownRuleIdVerbatimRatherThanHidingIt() {
        // No glossary entry exists for this made-up rule id — the disclosure must still surface
        // the real value rather than silently omitting it.
        let d = decision(rule: "custom.future_rule.v9", ruleVersion: "9")
        XCTAssertEqual(ReconciliationDisclosureFormat.ruleLine(d), "custom.future_rule.v9 · 9")
    }

    func testDisclosureDistinguishesTwoDifferentDecisionsByTheirOwnRuleLine() {
        let a = decision(rule: "sleep.session_overlap.v1", ruleVersion: "1")
        let b = decision(rule: "sleep.session_overlap.v1", ruleVersion: "2")
        XCTAssertNotEqual(ReconciliationDisclosureFormat.ruleLine(a), ReconciliationDisclosureFormat.ruleLine(b),
                          "a version bump must change what's rendered, since it changed what actually decided")
    }

    // MARK: - Unresolved `DataConflict` scope label (DataConflictScopeFormat)

    private func conflict(scope: ConflictScope) -> DataConflict {
        DataConflict(id: "conflict-1", scope: scope, windowStart: now.addingTimeInterval(-600), windowEnd: now,
                    candidateRecordIds: ["record-1", "record-2"], detectedAt: now, updatedAt: now, originDeviceId: device)
    }

    func testUnresolvedConflictScopeLabelNamesTheMetricForAPlainMetricConflict() {
        let c = conflict(scope: .metric(id: MetricID.weight, inWorkout: false))
        let label = DataConflictScopeFormat.label(c, registry: MetricRegistry.shared, language: .en)
        XCTAssertEqual(label, MetricRegistry.shared.definitionOrFallback(MetricID.weight).displayName.en)
    }

    func testUnresolvedConflictScopeLabelNamesTheWorkoutContextWhenInWorkoutIsSet() {
        let c = conflict(scope: .metric(id: MetricID.heartRate, inWorkout: true))
        let label = DataConflictScopeFormat.label(c, registry: MetricRegistry.shared, language: .en)
        XCTAssertTrue(label.contains("during a workout"),
                      "an in-workout conflict must say so, since that's exactly what the chest-strap-priority default keys on")
    }

    func testUnresolvedConflictScopeLabelNamesADuplicateWorkoutDistinctlyFromAnyMetric() {
        let c = conflict(scope: .workoutDuplicate)
        let label = DataConflictScopeFormat.label(c, registry: MetricRegistry.shared, language: .en)
        XCTAssertEqual(label, "Possible duplicate workout")
    }

    func testUnresolvedConflictScopeLabelResolvesInBothLanguages() {
        let c = conflict(scope: .workoutDuplicate)
        XCTAssertEqual(DataConflictScopeFormat.label(c, registry: MetricRegistry.shared, language: .ar),
                       "احتمال تمرين مكرر")
    }
}
