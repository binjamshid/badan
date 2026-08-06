import XCTest
@testable import BADAN

/// Exhaustive coverage of the ONE part of EPIC-43's ungated-core slice that makes a real
/// correctness claim: `GattParsers`' pure byte-decoders. Every fixture below is HAND-CONSTRUCTED
/// to match the official Bluetooth SIG GATT Specification Supplement (GSS) byte layout for its
/// characteristic — never a round-trip of this codebase's own encoder, because `GattServiceAdapters.swift`
/// has no encoder. Each parser also gets at least one malformed/truncated-input case, asserting
/// `nil` rather than a crash.
///
/// `GattCentralManaging` itself is NOT exercised against real Bluetooth here (see that protocol's
/// own file-header doc for why: the Simulator has no BLE hardware, and there is no physical
/// accessory in this environment) — `FakeGattCentralManagerTests` below uses a minimal, clearly
/// fake double purely to show how domain code consumes an already-parsed reading.
final class GattServiceAdaptersTests: XCTestCase {

    // MARK: - Heart Rate Measurement (0x2A37)

    func testHeartRate_8Bit_NoOptionalFields() {
        // flags=0x00 (8-bit HR, no contact support, no energy, no RR), HR=65 bpm.
        let data = Data([0x00, 0x41])
        let hr = GattParsers.parseHeartRateMeasurement(data)
        XCTAssertEqual(hr?.heartRateBPM, 65)
        XCTAssertEqual(hr?.sensorContactSupported, false)
        XCTAssertNil(hr?.sensorContactDetected)
        XCTAssertNil(hr?.energyExpendedKJ)
        XCTAssertEqual(hr?.rrIntervals, [])
    }

    func testHeartRate_16Bit_ContactDetected_Energy_RRIntervals() {
        // flags = bit0(16-bit) | bit1(contact detected) | bit2(contact supported) | bit3(energy) | bit4(RR) = 0x1F.
        // HR=300 bpm (0x012C LE), Energy=500 kJ (0x01F4 LE), RR=[1024, 512] * 1/1024s = [1.0, 0.5]s.
        let data = Data([0x1F, 0x2C, 0x01, 0xF4, 0x01, 0x00, 0x04, 0x00, 0x02])
        let hr = try? XCTUnwrap(GattParsers.parseHeartRateMeasurement(data))
        XCTAssertEqual(hr?.heartRateBPM, 300)
        XCTAssertEqual(hr?.sensorContactSupported, true)
        XCTAssertEqual(hr?.sensorContactDetected, true)
        XCTAssertEqual(hr?.energyExpendedKJ, 500)
        XCTAssertEqual(hr?.rrIntervals, [1.0, 0.5], "1024/1024=1.0 and 512/1024=0.5 are exact in binary floating point")
    }

    func testHeartRate_ContactSupportedButNotDetected() {
        // flags = bit2 only (0x04): supported, but bit1=0 means not detected.
        let data = Data([0x04, 0x46]) // 70 bpm
        let hr = GattParsers.parseHeartRateMeasurement(data)
        XCTAssertEqual(hr?.heartRateBPM, 70)
        XCTAssertEqual(hr?.sensorContactSupported, true)
        XCTAssertEqual(hr?.sensorContactDetected, false)
    }

    func testHeartRate_MalformedTruncated16BitValue_ReturnsNilNotCrash() {
        // flags says 16-bit HR (bit0=1) but only one byte of value follows.
        let data = Data([0x01, 0x50])
        XCTAssertNil(GattParsers.parseHeartRateMeasurement(data))
    }

    func testHeartRate_MalformedOddTrailingRRByte_ReturnsNil() {
        // flags = RR present (0x10), 8-bit HR=60, then a single stray trailing byte (not a whole uint16).
        let data = Data([0x10, 0x3C, 0x05])
        XCTAssertNil(GattParsers.parseHeartRateMeasurement(data))
    }

    func testHeartRate_EmptyData_ReturnsNil() {
        XCTAssertNil(GattParsers.parseHeartRateMeasurement(Data()))
        XCTAssertNil(GattParsers.parseHeartRateMeasurement(Data([0x00])))
    }

    // MARK: - Cycling Power Measurement (0x2A63)

    func testCyclingPower_MandatoryOnly_NegativePower() {
        // flags=0x0000, power = -50 W (sint16 0xFFCE LE).
        let data = Data([0x00, 0x00, 0xCE, 0xFF])
        let cp = GattParsers.parseCyclingPowerMeasurement(data)
        XCTAssertEqual(cp?.instantaneousPowerWatts, -50)
        XCTAssertNil(cp?.pedalPowerBalancePercent)
        XCTAssertNil(cp?.cumulativeWheelRevolutions)
        XCTAssertNil(cp?.cumulativeCrankRevolutions)
    }

    func testCyclingPower_PedalBalance_Wheel_Crank() {
        // flags = bit0(pedal balance) | bit4(wheel) | bit5(crank) = 0x0031 (LE: 0x31,0x00).
        // power=250W, pedal balance raw 150 -> 75.0%, wheel revs=12345 + event time 2048(=1.0s @1/2048),
        // crank revs=500 + event time 1024(=1.0s @1/1024).
        let data = Data([
            0x31, 0x00,             // flags
            0xFA, 0x00,             // power = 250
            150,                    // pedal balance raw
            0x39, 0x30, 0x00, 0x00, // wheel revs = 12345
            0x00, 0x08,             // wheel event time raw = 2048
            0xF4, 0x01,             // crank revs = 500
            0x00, 0x04,             // crank event time raw = 1024
        ])
        let cp = try? XCTUnwrap(GattParsers.parseCyclingPowerMeasurement(data))
        XCTAssertEqual(cp?.instantaneousPowerWatts, 250)
        XCTAssertEqual(cp?.pedalPowerBalancePercent, 75.0)
        XCTAssertEqual(cp?.cumulativeWheelRevolutions, 12345)
        XCTAssertEqual(cp?.lastWheelEventTimeSeconds ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(cp?.cumulativeCrankRevolutions, 500)
        XCTAssertEqual(cp?.lastCrankEventTimeSeconds ?? -1, 1.0, accuracy: 0.0001)
    }

    func testCyclingPower_AccumulatedTorqueSkippedButOffsetStaysCorrectForWheelData() {
        // flags = bit2(accumulated torque) | bit4(wheel) = 0x0014. Verifies that a field this
        // parser does NOT expose is still correctly skipped so wheel data lands at the right offset.
        let data = Data([
            0x14, 0x00, // flags
            0x64, 0x00, // power = 100
            0xE7, 0x03, // accumulated torque (unexposed, must still be skipped)
            0x2A, 0x00, 0x00, 0x00, // wheel revs = 42
            0x64, 0x00, // wheel event time raw = 100 -> 100/2048s
        ])
        let cp = try? XCTUnwrap(GattParsers.parseCyclingPowerMeasurement(data))
        XCTAssertEqual(cp?.instantaneousPowerWatts, 100)
        XCTAssertNil(cp?.pedalPowerBalancePercent)
        XCTAssertEqual(cp?.cumulativeWheelRevolutions, 42)
        XCTAssertEqual(cp?.lastWheelEventTimeSeconds ?? -1, 100.0 / 2048.0, accuracy: 0.0001)
        XCTAssertNil(cp?.cumulativeCrankRevolutions)
    }

    func testCyclingPower_MalformedTruncatedWheelEventTime_ReturnsNil() {
        // flags say wheel data present, but the notification ends right after the 4-byte revs
        // count, missing the 2-byte event time.
        let data = Data([0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        XCTAssertNil(GattParsers.parseCyclingPowerMeasurement(data))
    }

    func testCyclingPower_TooShortForMandatoryFields_ReturnsNil() {
        XCTAssertNil(GattParsers.parseCyclingPowerMeasurement(Data([0x00, 0x00, 0x00])))
    }

    // MARK: - CSC Measurement (0x2A5B)

    func testCSC_WheelAndCrankPresent() {
        // flags = 0x03 (both). wheel revs=1000 + event time 1024(=1.0s@1/1024), crank revs=50 + event time 512(=0.5s).
        let data = Data([
            0x03,
            0xE8, 0x03, 0x00, 0x00, // wheel revs = 1000
            0x00, 0x04,             // wheel event time raw = 1024
            0x32, 0x00,             // crank revs = 50
            0x00, 0x02,             // crank event time raw = 512
        ])
        let csc = try? XCTUnwrap(GattParsers.parseCSCMeasurement(data))
        XCTAssertEqual(csc?.cumulativeWheelRevolutions, 1000)
        XCTAssertEqual(csc?.lastWheelEventTimeSeconds ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(csc?.cumulativeCrankRevolutions, 50)
        XCTAssertEqual(csc?.lastCrankEventTimeSeconds ?? -1, 0.5, accuracy: 0.0001)
    }

    func testCSC_NeitherFieldPresent_ValidEmptyReading() {
        let csc = GattParsers.parseCSCMeasurement(Data([0x00]))
        XCTAssertNotNil(csc, "flags=0 with no data is a valid (if useless) reading, not malformed input")
        XCTAssertNil(csc?.cumulativeWheelRevolutions)
        XCTAssertNil(csc?.cumulativeCrankRevolutions)
    }

    func testCSC_MalformedTruncatedWheelData_ReturnsNil() {
        let data = Data([0x01, 0x01, 0x02]) // flags say wheel present, only 2 bytes follow (need 6)
        XCTAssertNil(GattParsers.parseCSCMeasurement(data))
    }

    func testCSC_EmptyData_ReturnsNil() {
        XCTAssertNil(GattParsers.parseCSCMeasurement(Data()))
    }

    // MARK: - RSC Measurement (0x2A53)

    func testRSC_MinimalWalking() {
        // flags=0x00 (walking, no stride/distance). speed raw 300 -> 300/256 m/s. cadence=170.
        let data = Data([0x00, 0x2C, 0x01, 170])
        let rsc = try? XCTUnwrap(GattParsers.parseRSCMeasurement(data))
        XCTAssertEqual(rsc?.instantaneousSpeedMetersPerSecond ?? -1, 300.0 / 256.0, accuracy: 0.0001)
        XCTAssertEqual(rsc?.instantaneousCadenceStepsPerMinute, 170)
        XCTAssertEqual(rsc?.isRunning, false)
        XCTAssertNil(rsc?.strideLengthMeters)
        XCTAssertNil(rsc?.totalDistanceMeters)
    }

    func testRSC_RunningWithStrideAndDistance() {
        // flags = bit0(stride) | bit1(distance) | bit2(running) = 0x07.
        // speed raw 600 -> 600/256 m/s, cadence=180, stride raw 150 -> 1.5m, distance raw 50000 -> 5000.0m.
        let data = Data([
            0x07,
            0x58, 0x02, // speed raw = 600
            180,        // cadence
            0x96, 0x00, // stride raw = 150
            0x50, 0xC3, 0x00, 0x00, // distance raw = 50000
        ])
        let rsc = try? XCTUnwrap(GattParsers.parseRSCMeasurement(data))
        XCTAssertEqual(rsc?.instantaneousSpeedMetersPerSecond ?? -1, 600.0 / 256.0, accuracy: 0.0001)
        XCTAssertEqual(rsc?.instantaneousCadenceStepsPerMinute, 180)
        XCTAssertEqual(rsc?.isRunning, true)
        XCTAssertEqual(rsc?.strideLengthMeters ?? -1, 1.5, accuracy: 0.0001)
        XCTAssertEqual(rsc?.totalDistanceMeters ?? -1, 5000.0, accuracy: 0.0001)
    }

    func testRSC_MalformedTruncatedStride_ReturnsNil() {
        let data = Data([0x01, 0x00, 0x00, 0x00]) // flags say stride present, 0 bytes follow (need 2)
        XCTAssertNil(GattParsers.parseRSCMeasurement(data))
    }

    func testRSC_TooShortForMandatoryFields_ReturnsNil() {
        XCTAssertNil(GattParsers.parseRSCMeasurement(Data([0x00, 0x00, 0x00])))
    }

    // MARK: - Weight Measurement (0x2A9D)

    func testWeight_SI_NoOptionalFields() {
        // raw 14000 * 0.005 kg/unit = 70.0 kg.
        let data = Data([0x00, 0xB0, 0x36])
        let w = try? XCTUnwrap(GattParsers.parseWeightMeasurement(data))
        XCTAssertEqual(w?.weightKg ?? -1, 70.0, accuracy: 0.0001)
        XCTAssertEqual(w?.isImperialUnits, false)
        XCTAssertNil(w?.timestamp)
        XCTAssertNil(w?.userId)
        XCTAssertNil(w?.bmi)
        XCTAssertNil(w?.heightMeters)
    }

    func testWeight_Imperial_Timestamp_UserId_BMIHeight() {
        // flags = bit0(imperial)|bit1(timestamp)|bit2(userId)|bit3(bmi+height) = 0x0F.
        // weight raw 15000 * 0.01 lb/unit = 150.0 lb -> kg. timestamp 2026-07-22 14:30:00.
        // userId=5. bmi raw 245 -> 24.5. height raw 680 * 0.1in/unit -> 68.0in -> meters.
        let data = Data([
            0x0F,
            0x98, 0x3A,             // weight raw = 15000
            0xEA, 0x07,             // year = 2026
            0x07,                   // month
            0x16,                   // day = 22
            0x0E,                   // hours = 14
            0x1E,                   // minutes = 30
            0x00,                   // seconds
            0x05,                   // userId
            0xF5, 0x00,             // bmi raw = 245
            0xA8, 0x02,             // height raw = 680
        ])
        let w = try? XCTUnwrap(GattParsers.parseWeightMeasurement(data))
        XCTAssertEqual(w?.isImperialUnits, true)
        XCTAssertEqual(w?.weightKg ?? -1, 150.0 * 0.45359237, accuracy: 0.0001)
        XCTAssertEqual(w?.timestamp?.year, 2026)
        XCTAssertEqual(w?.timestamp?.month, 7)
        XCTAssertEqual(w?.timestamp?.day, 22)
        XCTAssertEqual(w?.timestamp?.hours, 14)
        XCTAssertEqual(w?.timestamp?.minutes, 30)
        XCTAssertEqual(w?.timestamp?.seconds, 0)
        XCTAssertEqual(w?.userId, 5)
        XCTAssertEqual(w?.bmi ?? -1, 24.5, accuracy: 0.0001)
        XCTAssertEqual(w?.heightMeters ?? -1, 680.0 * 0.1 * 0.0254, accuracy: 0.0001) // raw 680 -> 68.0in -> ~1.727m
    }

    func testWeight_MalformedTruncatedHeight_ReturnsNil() {
        // flags say BMI+height present, but only BMI's 2 bytes follow (height's 2 missing).
        let data = Data([0x08, 0xB0, 0x36, 0xC8, 0x00])
        XCTAssertNil(GattParsers.parseWeightMeasurement(data))
    }

    func testWeight_TooShortForMandatoryFields_ReturnsNil() {
        XCTAssertNil(GattParsers.parseWeightMeasurement(Data([0x00, 0x00])))
    }

    func testWeight_MeasurementUnsuccessfulSentinel_ReturnsNilNotA327KgReading() {
        // GSS reserves 0xFFFF in the Weight field for "Measurement Unsuccessful". Decoded
        // arithmetically it is 65535 * 0.005 = 327.675 kg, which is indistinguishable from a real
        // reading once it reaches storage — so the sentinel must be rejected at the parser.
        XCTAssertNil(GattParsers.parseWeightMeasurement(Data([0x00, 0xFF, 0xFF])))
        // Same sentinel with the Imperial bit set, and with optional fields trailing it: the
        // rejection is on the raw uint16, not on the converted magnitude or the packet's shape.
        XCTAssertNil(GattParsers.parseWeightMeasurement(Data([0x05, 0xFF, 0xFF, 0x03])))
    }

    func testWeight_HighestValidRawWeight_StillDecodes() {
        // 0xFFFE is the largest non-sentinel raw value; rejecting 0xFFFF must not turn into
        // rejecting the top of the legal range.
        let w = try? XCTUnwrap(GattParsers.parseWeightMeasurement(Data([0x00, 0xFE, 0xFF])))
        XCTAssertEqual(w?.weightKg ?? -1, 65534.0 * 0.005, accuracy: 0.0001)
    }

    // MARK: - Body Composition Measurement (0x2A9C)

    func testBodyComposition_MandatoryOnly() {
        // flags=0x0000, body fat raw 250 -> 25.0%.
        let data = Data([0x00, 0x00, 0xFA, 0x00])
        let bc = try? XCTUnwrap(GattParsers.parseBodyCompositionMeasurement(data))
        XCTAssertEqual(bc?.bodyFatPercent ?? -1, 25.0, accuracy: 0.0001)
        XCTAssertEqual(bc?.isImperialUnits, false)
        XCTAssertNil(bc?.timestamp)
        XCTAssertNil(bc?.basalMetabolismKJ)
        XCTAssertNil(bc?.musclePercent)
        XCTAssertNil(bc?.muscleMassKg)
        XCTAssertNil(bc?.fatFreeMassKg)
        XCTAssertNil(bc?.impedanceOhms)
        XCTAssertNil(bc?.weightKg)
        XCTAssertNil(bc?.heightMeters)
        XCTAssertEqual(bc?.isMultiPacketMeasurement, false)
    }

    func testBodyComposition_ManyFlagsSet_SkipsUnsetFieldsCorrectly() {
        // flags = bit1(timestamp) | bit3(basal) | bit4(muscle%) | bit5(muscleMass) | bit9(impedance)
        //       | bit10(weight) | bit11(height) | bit12(multi-packet) = 0x1E3A.
        // Deliberately leaves bit2(userId), bit6(fatFree), bit7(softLean), bit8(bodyWater) UNSET —
        // this is what actually exercises "skip an absent field without breaking subsequent offsets."
        let data = Data([
            0x3A, 0x1E,             // flags
            0x2C, 0x01,             // body fat raw = 300 -> 30.0%
            0xE9, 0x07,             // year = 2025
            0x0C,                   // month = 12
            0x01,                   // day = 1
            0x08,                   // hours = 8
            0x0F,                   // minutes = 15
            0x2D,                   // seconds = 45
            0x70, 0x17,             // basal metabolism raw = 6000
            0xC2, 0x01,             // muscle % raw = 450 -> 45.0%
            0xE0, 0x2E,             // muscle mass raw = 12000 -> 60.0kg
            0x7C, 0x15,             // impedance raw = 5500 -> 550.0 ohm
            0xB0, 0x36,             // weight raw = 14000 -> 70.0kg
            0xD6, 0x06,             // height raw = 1750 -> 1.750m
        ])
        let bc = try? XCTUnwrap(GattParsers.parseBodyCompositionMeasurement(data))
        XCTAssertEqual(bc?.bodyFatPercent ?? -1, 30.0, accuracy: 0.0001)
        XCTAssertEqual(bc?.isImperialUnits, false)
        XCTAssertEqual(bc?.timestamp?.year, 2025)
        XCTAssertEqual(bc?.timestamp?.month, 12)
        XCTAssertEqual(bc?.timestamp?.day, 1)
        XCTAssertEqual(bc?.timestamp?.hours, 8)
        XCTAssertEqual(bc?.timestamp?.minutes, 15)
        XCTAssertEqual(bc?.timestamp?.seconds, 45)
        XCTAssertEqual(bc?.basalMetabolismKJ, 6000)
        XCTAssertEqual(bc?.musclePercent ?? -1, 45.0, accuracy: 0.0001)
        XCTAssertEqual(bc?.muscleMassKg ?? -1, 60.0, accuracy: 0.0001)
        XCTAssertNil(bc?.fatFreeMassKg, "bit6 unset — must stay nil, not accidentally read")
        XCTAssertEqual(bc?.impedanceOhms ?? -1, 550.0, accuracy: 0.0001)
        XCTAssertEqual(bc?.weightKg ?? -1, 70.0, accuracy: 0.0001)
        XCTAssertEqual(bc?.heightMeters ?? -1, 1.750, accuracy: 0.0001)
        XCTAssertEqual(bc?.isMultiPacketMeasurement, true)
    }

    func testBodyComposition_MalformedTruncatedWeight_ReturnsNil() {
        // flags say weight present (bit10), but only 1 of its 2 bytes follows.
        let data = Data([0x00, 0x04, 0x00, 0x00, 0x99])
        XCTAssertNil(GattParsers.parseBodyCompositionMeasurement(data))
    }

    func testBodyComposition_TooShortForMandatoryFields_ReturnsNil() {
        XCTAssertNil(GattParsers.parseBodyCompositionMeasurement(Data([0x00, 0x00, 0x00])))
    }

    // MARK: - Indoor Bike Data (0x2AD2)

    func testIndoorBikeData_FullFlags_EveryOptionalFieldPresent() {
        // flags = bit0(MoreData=0, i.e. speed IS present) clear, bit1(avg speed) | bit2(cadence) |
        // bit3(avg cadence) | bit4(total distance) | bit5(resistance) | bit6(power) |
        // bit7(avg power) | bit8(expended energy) | bit9(heart rate) | bit10(metabolic equiv) |
        // bit11(elapsed time) | bit12(remaining time) all SET = 0x1FFE (LE: 0xFE, 0x1F).
        // speed raw 2500 -> 25.00 km/h, avg speed raw 2000 -> 20.00 km/h (skipped), cadence raw
        // 180 -> 90.0 rpm, avg cadence raw 160 -> 80.0 rpm (skipped), total distance raw 12345 m
        // (skipped, uint24), resistance raw 50 (skipped, sint16), power=250W, avg power=200W
        // (skipped), expended energy total=500kcal/perHour=600/perMin=10 (skipped, 5 bytes),
        // heart rate=145bpm, metabolic equiv raw 85 -> 8.5 (skipped), elapsed=3600s (skipped),
        // remaining=1200s (skipped).
        let data = Data([
            0xFE, 0x1F,             // flags = 0x1FFE
            0xC4, 0x09,             // instantaneous speed raw = 2500
            0xD0, 0x07,             // average speed raw = 2000 (skipped)
            0xB4, 0x00,             // instantaneous cadence raw = 180
            0xA0, 0x00,             // average cadence raw = 160 (skipped)
            0x39, 0x30, 0x00,       // total distance raw = 12345 (uint24, skipped)
            0x32, 0x00,             // resistance level raw = 50 (skipped)
            0xFA, 0x00,             // instantaneous power = 250
            0xC8, 0x00,             // average power = 200 (skipped)
            0xF4, 0x01,             // expended energy: total kcal = 500 (skipped)
            0x58, 0x02,             // expended energy: per hour kcal = 600 (skipped)
            0x0A,                   // expended energy: per minute kcal = 10 (skipped)
            145,                    // heart rate
            0x55,                   // metabolic equivalent raw = 85 (skipped)
            0x10, 0x0E,             // elapsed time raw = 3600 (skipped)
            0xB0, 0x04,             // remaining time raw = 1200 (skipped)
        ])
        let bike = try? XCTUnwrap(GattParsers.parseIndoorBikeDataMeasurement(data))
        XCTAssertEqual(bike?.instantaneousSpeedKmh ?? -1, 25.0, accuracy: 0.0001)
        XCTAssertEqual(bike?.instantaneousCadenceRpm ?? -1, 90.0, accuracy: 0.0001)
        XCTAssertEqual(bike?.instantaneousPowerWatts, 250)
        XCTAssertEqual(bike?.heartRateBPM, 145)
    }

    func testIndoorBikeData_MinimalPacket_MandatoryFieldsOnly() {
        // flags=0x0000 (More Data clear -> speed present; nothing else set).
        // speed raw 1500 -> 15.00 km/h.
        let data = Data([0x00, 0x00, 0xDC, 0x05])
        let bike = try? XCTUnwrap(GattParsers.parseIndoorBikeDataMeasurement(data))
        XCTAssertEqual(bike?.instantaneousSpeedKmh ?? -1, 15.0, accuracy: 0.0001)
        XCTAssertNil(bike?.instantaneousCadenceRpm)
        XCTAssertNil(bike?.instantaneousPowerWatts)
        XCTAssertNil(bike?.heartRateBPM)
    }

    func testIndoorBikeData_MoreDataFlagSet_SpeedAbsentButValidReading() {
        // flags = bit0 (More Data) set -> Instantaneous Speed is NOT present in this packet, and no
        // other bits set. This is a valid (if minimal) reading, not malformed input.
        let bike = GattParsers.parseIndoorBikeDataMeasurement(Data([0x01, 0x00]))
        XCTAssertNotNil(bike, "More Data set with no other flags is a valid reading with no fields")
        XCTAssertNil(bike?.instantaneousSpeedKmh)
        XCTAssertNil(bike?.instantaneousCadenceRpm)
        XCTAssertNil(bike?.instantaneousPowerWatts)
        XCTAssertNil(bike?.heartRateBPM)
    }

    func testIndoorBikeData_MalformedTruncatedCadence_ReturnsNil() {
        // flags = bit0(More Data, speed absent) | bit2(cadence present) = 0x0005. Cadence field
        // needs 2 bytes but 0 follow after the flags.
        let data = Data([0x05, 0x00])
        XCTAssertNil(GattParsers.parseIndoorBikeDataMeasurement(data))
    }

    func testIndoorBikeData_EmptyData_ReturnsNil() {
        XCTAssertNil(GattParsers.parseIndoorBikeDataMeasurement(Data()))
        XCTAssertNil(GattParsers.parseIndoorBikeDataMeasurement(Data([0x00])))
    }

    // MARK: - Treadmill Data (0x2ACD)

    func testTreadmillData_MoreDataClear_InstantaneousSpeedPresent() {
        // flags=0x0000 — More Data clear, so Instantaneous Speed IS present, and no other bit set.
        // speed raw 800 -> 8.00 km/h.
        let data = Data([0x00, 0x00, 0x20, 0x03])
        let treadmill = try? XCTUnwrap(GattParsers.parseTreadmillDataMeasurement(data))
        XCTAssertEqual(treadmill?.instantaneousSpeedKmh ?? -1, 8.0, accuracy: 0.0001)
        XCTAssertNil(treadmill?.instantaneousPowerWatts)
        XCTAssertNil(treadmill?.heartRateBPM)
    }

    func testTreadmillData_MoreDataFlagSet_SpeedAbsentButValidReading() {
        // flags = bit0 (More Data) set -> Instantaneous Speed is NOT present in this packet (FTMS
        // v1.0 §4.7), and no other bits set. Exactly the Indoor Bike Data case above, and exactly
        // as valid: a minimal reading, not malformed input.
        let treadmill = GattParsers.parseTreadmillDataMeasurement(Data([0x01, 0x00]))
        XCTAssertNotNil(treadmill, "More Data set with no other flags is a valid reading with no fields")
        XCTAssertNil(treadmill?.instantaneousSpeedKmh)
        XCTAssertNil(treadmill?.instantaneousPowerWatts)
        XCTAssertNil(treadmill?.heartRateBPM)
    }

    func testTreadmillData_MoreDataFlagSet_SubsequentFieldsAreNotShiftedByAPhantomSpeed() {
        // The regression this test exists for: with More Data set, Instantaneous Speed is absent,
        // so Heart Rate starts immediately after the Flags. A parser that reads speed
        // unconditionally consumes Heart Rate's byte plus one Force-on-Belt byte as a speed, and
        // every field after that lands two bytes early. On this tightly-packed fixture that overrun
        // trips the Force-and-Power length guard and the whole reading is dropped as nil; a
        // notification with any trailing bytes the flags do not account for instead trips no guard
        // and yields a fabricated speed beside a wrong heart rate. Assert the fields land where the
        // spec puts them, which rules out both.
        // flags = bit0(More Data) | bit8(heart rate) | bit12(force on belt & power) = 0x1101.
        let data = Data([
            0x01, 0x11,             // flags = 0x1101
            150,                    // heart rate
            0x50, 0x00,             // force on belt raw = 80 N (skipped)
            0xE2, 0xFF,             // power output = -30 W (sint16 0xFFE2 LE)
        ])
        let treadmill = try? XCTUnwrap(GattParsers.parseTreadmillDataMeasurement(data))
        XCTAssertNil(treadmill?.instantaneousSpeedKmh, "bit0 set — no speed in this packet")
        XCTAssertEqual(treadmill?.heartRateBPM, 150)
        XCTAssertEqual(treadmill?.instantaneousPowerWatts, -30)
    }

    func testTreadmillData_MoreDataFlagSet_TruncatedHeartRate_ReturnsNil() {
        // flags = bit0(More Data) | bit8(heart rate) = 0x0101, but the Heart Rate byte is missing.
        // Dropping the mandatory-speed read must not also drop the length guards behind it.
        XCTAssertNil(GattParsers.parseTreadmillDataMeasurement(Data([0x01, 0x01])))
    }

    func testTreadmillData_HeartRateAndForceAndPowerPresent() {
        // flags = bit8(heart rate) | bit12(force on belt & power) = 0x1100 (LE: 0x00, 0x11).
        // speed raw 1000 -> 10.00 km/h, heart rate=150bpm, force on belt raw=80N (skipped),
        // power output = -30W (sint16).
        let data = Data([
            0x00, 0x11,             // flags = 0x1100
            0xE8, 0x03,             // instantaneous speed raw = 1000
            150,                    // heart rate
            0x50, 0x00,             // force on belt raw = 80 (skipped)
            0xE2, 0xFF,             // power output = -30 (sint16 0xFFE2 LE)
        ])
        let treadmill = try? XCTUnwrap(GattParsers.parseTreadmillDataMeasurement(data))
        XCTAssertEqual(treadmill?.instantaneousSpeedKmh ?? -1, 10.0, accuracy: 0.0001)
        XCTAssertEqual(treadmill?.heartRateBPM, 150)
        XCTAssertEqual(treadmill?.instantaneousPowerWatts, -30)
    }

    func testTreadmillData_MalformedTruncatedForceAndPower_ReturnsNil() {
        // flags say Force on Belt and Power Output present (bit12), but only 2 of the required 4
        // bytes follow.
        let data = Data([0x00, 0x10, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(GattParsers.parseTreadmillDataMeasurement(data))
    }

    func testTreadmillData_TooShortForAnExpectedSpeed_ReturnsNil() {
        // More Data clear says Instantaneous Speed IS present, but only one of its two bytes is.
        XCTAssertNil(GattParsers.parseTreadmillDataMeasurement(Data([0x00, 0x00, 0x00])))
    }

    func testTreadmillData_EmptyData_ReturnsNil() {
        XCTAssertNil(GattParsers.parseTreadmillDataMeasurement(Data()))
        XCTAssertNil(GattParsers.parseTreadmillDataMeasurement(Data([0x00])))
    }
}

// MARK: - `GattCentralManaging` fake double: domain-consumption exercise only

/// A minimal, CLEARLY-FAKE `GattCentralManaging` double — NOT a real BLE stack, and it asserts
/// nothing about real hardware behavior. It exists solely so `testFakeCentralManagerDeliversParsedReadingsToAConsumer`
/// can exercise how domain code consumes an already-parsed reading once a notification arrives,
/// mirroring the shape a real CoreBluetooth-backed adapter (a future slice) would call the same
/// closure with — never a stand-in FOR that future adapter.
private final class FakeGattCentralManager: GattCentralManaging {
    private(set) var connectedPeripherals: Set<GattPeripheralHandle> = []
    private var notifyHandlers: [String: (Data) -> Void] = [:]

    func scan(forService service: String) -> AsyncStream<GattPeripheralHandle> {
        AsyncStream { continuation in
            continuation.yield(GattPeripheralHandle(id: "fake-peripheral-1", advertisedName: "Fake HR Strap"))
            continuation.finish()
        }
    }

    func connect(to peripheral: GattPeripheralHandle) async throws {
        connectedPeripherals.insert(peripheral)
    }

    func subscribeToNotifications(characteristic: String, on peripheral: GattPeripheralHandle,
                                   onNotify: @escaping (Data) -> Void) async throws {
        notifyHandlers[key(peripheral, characteristic)] = onNotify
    }

    func readOnce(characteristic: String, on peripheral: GattPeripheralHandle) async throws -> Data {
        Data()
    }

    func disconnect(from peripheral: GattPeripheralHandle) async throws {
        connectedPeripherals.remove(peripheral)
    }

    /// Test-only helper simulating a real peripheral pushing a characteristic notification.
    func simulateNotification(characteristic: String, on peripheral: GattPeripheralHandle, bytes: Data) {
        notifyHandlers[key(peripheral, characteristic)]?(bytes)
    }

    private func key(_ p: GattPeripheralHandle, _ c: String) -> String { "\(p.id):\(c)" }
}

final class FakeGattCentralManagerTests: XCTestCase {
    func testFakeCentralManagerDeliversParsedReadingsToAConsumer() async throws {
        let manager = FakeGattCentralManager()
        var receivedBPMs: [Int] = []

        var discovered: GattPeripheralHandle?
        for await p in manager.scan(forService: GattServiceUUID.heartRate) {
            discovered = p
            break
        }
        let peripheral = try XCTUnwrap(discovered)

        try await manager.connect(to: peripheral)
        XCTAssertTrue(manager.connectedPeripherals.contains(peripheral))

        try await manager.subscribeToNotifications(
            characteristic: GattCharacteristicUUID.heartRateMeasurement, on: peripheral
        ) { data in
            if let reading = GattParsers.parseHeartRateMeasurement(data) {
                receivedBPMs.append(reading.heartRateBPM)
            }
        }

        manager.simulateNotification(characteristic: GattCharacteristicUUID.heartRateMeasurement,
                                      on: peripheral, bytes: Data([0x00, 0x48])) // 72 bpm
        manager.simulateNotification(characteristic: GattCharacteristicUUID.heartRateMeasurement,
                                      on: peripheral, bytes: Data([0x00, 0x50])) // 80 bpm
        // A malformed notification must be dropped by the consumer, never crash the fake or the parser.
        manager.simulateNotification(characteristic: GattCharacteristicUUID.heartRateMeasurement,
                                      on: peripheral, bytes: Data([0x01, 0x00]))

        try await manager.disconnect(from: peripheral)

        XCTAssertEqual(receivedBPMs, [72, 80])
        XCTAssertFalse(manager.connectedPeripherals.contains(peripheral),
                        "disconnect must remove the peripheral from the fake's connected set")
    }
}
