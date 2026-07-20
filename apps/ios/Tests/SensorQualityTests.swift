import XCTest
@testable import BADAN

/// The sensor-quality contract loader (`packages/contracts/sensor_quality.json`, plan §15 / §4
/// principle 9).
///
/// The bundled file is a SHARED contract mirrored by `scripts/sync_ios_resources.sh`, so these
/// tests double as a check that the mirror step ran — a missing resource makes every source
/// render the fallback label, which looks plausible and is wrong.
final class SensorQualityTests: XCTestCase {

    private var map: SensorQualityMap { SensorQualityMap.shared }

    private func source(type: SourceType, name: String = "Apple Health") -> Source {
        Source(id: "src", type: type, displayName: name, updatedAt: Date(), originDeviceId: "dev")
    }

    private func device(name: String, model: String? = nil) -> Device {
        Device(id: "d-\(name)", sourceId: "src", name: name, model: model,
               firstSeen: Date(), lastSeen: Date(), updatedAt: Date(), originDeviceId: "dev")
    }

    // MARK: - Loading

    /// Catches a broken/missing `sync_ios_resources.sh` mirror, which is otherwise silent: an
    /// empty map still "works", it just labels everything with the fallback.
    func testContractLoads() {
        XCTAssertFalse(map.orderedClasses.isEmpty, "sensor_quality.json failed to load or is empty")
        XCTAssertNotNil(map.sourceClass(id: "wrist_wearable"))
        XCTAssertNotNil(map.sourceClass(id: "unknown"))
    }

    /// Every quality key the contract authors must be reachable from some `MetricFamily`.
    ///
    /// This is the test that was missing when it mattered. The contract declared entries for
    /// `workout`, `cycle`, `hydration` and `lab` while the enum had no case for any of them, so
    /// all four resolved through `.other` -> `"unmapped"` and returned `defaultQuality` instead of
    /// the authored level. A source the contract calls `unsupported` for a family was labelled
    /// "medium" — plausible, and wrong, on a screen whose entire job is honesty about sensors.
    /// The reverse direction is deliberately NOT asserted: a family with no contract entry is
    /// legitimate (see `sensorQualityKey`) and degrades to `defaultQuality` by design.
    func testEveryContractQualityKeyIsReachableFromAFamily() {
        let declared = Set(map.orderedClasses.flatMap(\.quality.keys))
        let reachable = Set(MetricFamily.allCases.map(\.sensorQualityKey))
        let orphaned = declared.subtracting(reachable).sorted()

        XCTAssertTrue(orphaned.isEmpty,
                      """
                      sensor_quality.json authors quality levels for \(orphaned) that no MetricFamily \
                      maps to, so those levels can never be shown and every lookup silently returns \
                      defaultQuality. Add the MetricFamily case (or its sensorQualityKey mapping).
                      """)
    }

    /// The contract's own resolution rule: a family with no entry for a class falls back to
    /// `defaultQuality`, never to `high`. An unlabelled new family must degrade toward caution.
    func testUnknownFamilyFallsBackToDefaultNotHigh() {
        // `.medications` maps to the deliberately-unmapped key (see `MetricFamily
        // .sensorQualityKey`), so no class has an entry for it.
        let level = map.level(sourceClassId: "wrist_wearable", family: .medications)
        XCTAssertEqual(level, map.defaultQuality)
        XCTAssertNotEqual(level, .high)
    }

    func testUnknownSourceClassFallsBackToDefault() {
        XCTAssertEqual(map.level(sourceClassId: "not_a_real_class", family: .heart), map.defaultQuality)
    }

    /// Spot-checks of the contract's actual content, so a bad merge into the shared JSON that
    /// inverts a claim is caught on this side too.
    func testKnownClassLevelsMatchTheContract() {
        XCTAssertEqual(map.level(sourceClassId: "wrist_wearable", family: .heart), .high)
        XCTAssertEqual(map.level(sourceClassId: "wrist_wearable", family: .body), .low)
        XCTAssertEqual(map.level(sourceClassId: "phone_handset", family: .heart), .unsupported)
        XCTAssertEqual(map.level(sourceClassId: "smart_scale", family: .body), .medium)
    }

    // MARK: - Classification

    func testWatchAndBandClassifyAsWristWearables() {
        let hk = source(type: .healthkit)
        XCTAssertEqual(map.classId(for: hk, devices: [device(name: "Apple Watch", model: "Watch7,1")]),
                       "wrist_wearable")
        XCTAssertEqual(map.classId(for: hk, devices: [device(name: "Mi Band 8")]), "wrist_wearable")
    }

    /// An Arabic-named device must classify identically to its English equivalent — otherwise the
    /// same watch is labelled `high` for activity in English and `medium` in Arabic, purely
    /// because of the user's language. Same class of bug as `SourcesScreen.deviceIcon`'s
    /// Arabic-keyword fix (UIUX-027).
    func testArabicDeviceNamesClassifyTheSameAsEnglish() {
        let hk = source(type: .healthkit)
        XCTAssertEqual(map.classId(for: hk, devices: [device(name: "ساعة أبل")]), "wrist_wearable")
        XCTAssertEqual(map.classId(for: hk, devices: [device(name: "هاتف")]), "phone_handset")
        XCTAssertEqual(map.classId(for: hk, devices: [device(name: "ميزان ذكي")]), "smart_scale")
    }

    /// An unrecognized device falls through to the source type's default rather than to a guess.
    func testUnrecognisedDeviceFallsBackToSourceTypeDefault() {
        XCTAssertEqual(map.classId(for: source(type: .healthkit), devices: [device(name: "Zephyr 9000")]),
                       "unknown")
        XCTAssertEqual(map.classId(for: source(type: .manual), devices: []), "manual_entry")
        XCTAssertEqual(map.classId(for: source(type: .fileImport), devices: []), "file_import")
    }

    /// A source with no devices yet (freshly connected, nothing synced) is `unknown`, not an
    /// optimistic assumption about hardware nobody has seen.
    func testSourceWithNoDevicesIsUnknown() {
        XCTAssertEqual(map.classId(for: source(type: .healthkit), devices: []), "unknown")
    }

    // MARK: - Presentation

    /// Class names come straight from the contract, which carries both languages precisely so
    /// this surface doesn't have to invent Arabic for hardware categories.
    func testClassNamesAndDescriptionsAreBilingual() {
        for sourceClass in map.orderedClasses {
            XCTAssertFalse(sourceClass.nameEn.isEmpty, "\(sourceClass.sourceClassId) has no English name")
            XCTAssertFalse(sourceClass.nameAr.isEmpty, "\(sourceClass.sourceClassId) has no Arabic name")
            XCTAssertNotEqual(sourceClass.nameEn, sourceClass.nameAr,
                              "\(sourceClass.sourceClassId)'s name is untranslated")
            XCTAssertFalse(sourceClass.descriptionEn.isEmpty)
            XCTAssertFalse(sourceClass.descriptionAr.isEmpty)
        }
    }

    /// Level copy is authored in Swift (the contract's own level descriptions are English-only),
    /// so it gets the same bilingual check every other authored string does.
    func testLevelLabelsAreBilingualAndNonJudgemental() {
        for level in SensorQualityLevel.allCases {
            XCTAssertFalse(level.label.en.isEmpty)
            XCTAssertNotEqual(level.label.en, level.label.ar)
            XCTAssertTrue(level.label.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(level.rawValue)'s Arabic label contains no Arabic script")
            XCTAssertFalse(level.explainer.en.isEmpty)
            XCTAssertNotEqual(level.explainer.en, level.explainer.ar)
        }

        // The label vocabulary describes METHOD, never merit. A grade ("poor", "bad", "weak")
        // would read as a verdict on the user's equipment and, by implication, on them — the
        // register the contract's own note explicitly rules out.
        let banned = ["poor", "bad", "weak", "unreliable", "inaccurate", "worse", "inferior"]
        for level in SensorQualityLevel.allCases {
            let lowered = (level.label.en + " " + level.explainer.en).lowercased()
            for word in banned {
                XCTAssertFalse(lowered.contains(word),
                               "\(level.rawValue) copy uses the judgemental word '\(word)'")
            }
        }
    }

    /// Lenient decode: an unrecognized level string from a newer Android release must not fail
    /// the whole file's decode and blank the map.
    func testUnknownLevelStringDecodesToMediumRatherThanThrowing() throws {
        let json = Data("""
        {
          "version": "test",
          "defaultQuality": "medium",
          "sourceTypeDefaults": {"healthkit": "unknown"},
          "sourceClasses": [
            {"sourceClassId": "future_device", "nameEn": "Future", "nameAr": "مستقبلي",
             "descriptionEn": "d", "descriptionAr": "و",
             "quality": {"heart": "extremely_high"}}
          ]
        }
        """.utf8)

        let parsed = SensorQualityMap(file: json)
        XCTAssertNotNil(parsed.sourceClass(id: "future_device"),
                        "One unknown level string must not take the whole contract down with it")
        XCTAssertEqual(parsed.level(sourceClassId: "future_device", family: .heart), .medium)
    }
}
