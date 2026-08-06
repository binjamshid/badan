import Foundation

// MARK: - SCOPE BOUNDARY — read this before touching this file
//
// This file contains ZERO CoreBluetooth references — no `import CoreBluetooth`, no
// `CBCentralManager`, no `CBPeripheral`, anywhere in this slice. That is deliberate, not an
// oversight, and the reason is honesty rather than laziness: the iOS Simulator has NO Bluetooth
// hardware access at all (a permanent, documented platform limitation — not something a
// workaround fixes), and this build/test environment has no physical BLE accessory to pair with
// either. Any CoreBluetooth-backed scanning/connection code written here would ship completely
// unverified against real hardware, which is exactly the kind of unverifiable claim this
// codebase's audits exist to catch (see `docs/audit/`).
//
// So this file draws a hard line between two things that must never be conflated by a future
// reader:
//
//   1. `GattCentralManaging` (below) is a PROTOCOL describing exactly the operations a real
//      CoreBluetooth-backed adapter would need: scan for a service, connect to a peripheral,
//      subscribe to a characteristic's notifications, read a characteristic once, disconnect.
//      It is the SEAM a real `CBCentralManager`/`CBPeripheral`-backed implementation drops into
//      later, in a follow-up slice that has an actual accessory to test against. This file
//      contains no conforming real-BLE type — only a minimal, clearly-fake test double conforms
//      (see `Tests/GattServiceAdaptersTests.swift`), and that double exists purely to exercise how
//      domain code CONSUMES an already-parsed reading, never to claim anything about real
//      hardware behavior.
//
//   2. `GattParsers` is the GATT PARSING layer: pure functions that decode the raw bytes a real
//      peripheral's characteristic notification would contain — per the official Bluetooth SIG
//      "GATT Specification Supplement" (GSS) byte layouts — into a typed BADAN value. THIS is the
//      part of this slice that is actually verified: every parser is exercised in
//      `Tests/GattServiceAdaptersTests.swift` against hand-constructed byte arrays matching the
//      published spec layout (never a round-trip of this file's own encoder, because this file
//      has no encoder), including at least one malformed/truncated case per parser. Every parser
//      returns `nil` rather than trapping on malformed or truncated input — a real accessory
//      sending a short or corrupt notification must never crash BADAN.
//
// A future reader must not mistake "the parsing layer is bit-accurate against the spec" for
// "this has been tested against a real heart rate strap, power meter, or scale." It has not —
// nothing in this file has ever talked to a real BLE radio.
//
// OUT OF SCOPE (do not add here, even behind a flag): Blood Pressure (0x2A35), Health
// Thermometer (0x2A1C), Pulse Oximeter (0x2A5E) parsing or UI. Those three are vitals-BLE copy
// surfaces gated behind approval A25 (a retained clinical advisor) per the founder's standing
// do-not-build list, and are not touched by this file in any form.

// MARK: - GATT identifiers

/// 16-bit Bluetooth SIG-assigned Service UUIDs (uppercase hex, no `0x` prefix, matching how the
/// SIG's own assigned-numbers documents render them) for the seven services this slice's parsing
/// layer covers. `CBUUID(string:)` is exactly how a real adapter would turn one of these into a
/// scan filter — but that conversion happens in the follow-up slice that owns `CBCentralManager`,
/// not here.
public enum GattServiceUUID {
    public static let heartRate = "180D"
    public static let cyclingPower = "1818"
    public static let cyclingSpeedAndCadence = "1816"
    public static let runningSpeedAndCadence = "1814"
    public static let weightScale = "181D"
    public static let bodyComposition = "181B"
    public static let fitnessMachine = "1826"
}

/// 16-bit Bluetooth SIG-assigned Characteristic UUIDs for the measurement characteristics
/// `GattParsers` decodes below.
public enum GattCharacteristicUUID {
    /// Heart Rate Measurement, GSS §3.114 (notify-only).
    public static let heartRateMeasurement = "2A37"
    /// Cycling Power Measurement, GSS §3.65 (notify-only).
    public static let cyclingPowerMeasurement = "2A63"
    /// CSC (Cycling Speed and Cadence) Measurement, GSS §3.66 (notify-only).
    public static let cscMeasurement = "2A5B"
    /// RSC (Running Speed and Cadence) Measurement, GSS §3.153 (notify-only).
    public static let rscMeasurement = "2A53"
    /// Weight Measurement, GSS §3.243 (indicate).
    public static let weightMeasurement = "2A9D"
    /// Body Composition Measurement, GSS §3.34 (indicate).
    public static let bodyCompositionMeasurement = "2A9C"
    /// Indoor Bike Data, GSS §3.117 (notify-only). Part of the Fitness Machine Service
    /// (`GattServiceUUID.fitnessMachine`).
    public static let indoorBikeData = "2AD2"
    /// Treadmill Data, GSS §3.203 (notify-only). Part of the Fitness Machine Service
    /// (`GattServiceUUID.fitnessMachine`).
    public static let treadmillData = "2ACD"
}

// MARK: - `GattCentralManaging` — the seam, not an implementation

/// An opaque, platform-agnostic handle to a discovered peripheral. A real adapter's `id` would be
/// `CBPeripheral.identifier.uuidString`; nothing in this file (or anywhere in this slice)
/// constructs one from an actual `CBPeripheral`.
public struct GattPeripheralHandle: Hashable, Sendable {
    public let id: String
    public let advertisedName: String?

    public init(id: String, advertisedName: String? = nil) {
        self.id = id
        self.advertisedName = advertisedName
    }
}

/// Everything a real CoreBluetooth-backed adapter would need to implement — and nothing more.
/// This is the exact seam plan §7A.6 calls for ("AccessorySetupKit (iOS 18) picker pairing;
/// user-initiated scanning only; foreground/session-based only — no background-BLE promises").
/// No type in this slice conforms to this protocol with real BLE behavior; only a minimal fake
/// test double does, in `Tests/GattServiceAdaptersTests.swift`, to exercise how domain code
/// consumes an already-decoded reading.
public protocol GattCentralManaging: AnyObject {
    /// Begin a user-initiated scan for peripherals advertising `service` (a `GattServiceUUID`
    /// constant). Foreground/session-based only — this signature makes no background-delivery
    /// promise, and a real implementation must not make one either.
    func scan(forService service: String) -> AsyncStream<GattPeripheralHandle>

    /// Connect to a previously discovered peripheral.
    func connect(to peripheral: GattPeripheralHandle) async throws

    /// Subscribe to notifications on `characteristic` (a `GattCharacteristicUUID` constant).
    /// `onNotify` receives the RAW characteristic value exactly as a real `CBPeripheral` would
    /// deliver it to `peripheral(_:didUpdateValueFor:error:)` — undecoded. Turning those bytes
    /// into a typed reading is `GattParsers`' job, never this protocol's.
    func subscribeToNotifications(characteristic: String, on peripheral: GattPeripheralHandle,
                                   onNotify: @escaping (Data) -> Void) async throws

    /// Read a characteristic's current value once, without subscribing.
    func readOnce(characteristic: String, on peripheral: GattPeripheralHandle) async throws -> Data

    /// Disconnect from a peripheral (e.g. at the end of a workout session — this slice's
    /// connections are session-scoped, never background-persistent).
    func disconnect(from peripheral: GattPeripheralHandle) async throws
}

// MARK: - Typed parsed values

/// Heart Rate Measurement (0x2A37) decoded per GSS §3.114.
public struct HeartRateMeasurement: Equatable, Sendable {
    public let heartRateBPM: Int
    /// Whether this peripheral supports reporting contact status at all (Flags bit 2). When
    /// `false`, `sensorContactDetected` is meaningless and always `nil` — the spec is explicit
    /// that the detected bit (bit 1) must be ignored when the support bit is unset.
    public let sensorContactSupported: Bool
    public let sensorContactDetected: Bool?
    /// Energy Expended since the last reset, in kilojoules — present only when Flags bit 3 is set.
    public let energyExpendedKJ: Int?
    /// Zero or more RR-intervals in SECONDS (raw units are 1/1024 s per the spec; this parser
    /// converts them so callers never repeat that division) — present only when Flags bit 4 is set.
    public let rrIntervals: [Double]
}

/// Cycling Power Measurement (0x2A63) decoded per GSS §3.65. Only the fields BADAN's Effort/
/// workout engines actually consume are exposed as named properties; `Pedal Power Balance` is
/// exposed too because it costs nothing extra to read once its byte position is known. Fields
/// beyond Crank Revolution Data (Extreme Force/Torque/Angles, Top/Bottom Dead Spot, Accumulated
/// Energy) are NOT decoded — BADAN has no consumer for them this slice, and because every
/// optional field before Crank Revolution Data in the spec's fixed field order IS decoded (so the
/// offset math reaching Crank Revolution Data is correct), skipping the fields AFTER it costs
/// nothing: this parser never needs to read past the last field it exposes.
public struct CyclingPowerMeasurement: Equatable, Sendable {
    public let instantaneousPowerWatts: Int
    /// Percent, 0–100 in 0.5-percent steps — present only when Flags bit 0 is set.
    public let pedalPowerBalancePercent: Double?
    public let cumulativeWheelRevolutions: UInt32?
    /// Seconds, present only when Flags bit 4 is set. Raw units are 1/2048 s — NOTE the
    /// resolution difference from CSC Measurement's own Last Wheel Event Time field, which uses
    /// 1/1024 s; this is a genuine inconsistency between the two GSS characteristics, not a typo.
    public let lastWheelEventTimeSeconds: Double?
    public let cumulativeCrankRevolutions: UInt16?
    /// Seconds, present only when Flags bit 5 is set. Raw units are 1/1024 s.
    public let lastCrankEventTimeSeconds: Double?
}

/// CSC (Cycling Speed and Cadence) Measurement (0x2A5B) decoded per GSS §3.66.
public struct CSCMeasurement: Equatable, Sendable {
    public let cumulativeWheelRevolutions: UInt32?
    /// Seconds; raw units are 1/1024 s — see `CyclingPowerMeasurement.lastWheelEventTimeSeconds`'s
    /// doc for why this differs from Cycling Power's own wheel-event-time resolution.
    public let lastWheelEventTimeSeconds: Double?
    public let cumulativeCrankRevolutions: UInt16?
    /// Seconds; raw units are 1/1024 s.
    public let lastCrankEventTimeSeconds: Double?
}

/// RSC (Running Speed and Cadence) Measurement (0x2A53) decoded per GSS §3.153.
public struct RSCMeasurement: Equatable, Sendable {
    public let instantaneousSpeedMetersPerSecond: Double
    public let instantaneousCadenceStepsPerMinute: Int
    /// Flags bit 2: `false` = walking, `true` = running. Always meaningful (unlike Heart Rate's
    /// contact bit) — RSC has no separate "supported" gate for this bit.
    public let isRunning: Bool
    /// Meters — present only when Flags bit 0 is set.
    public let strideLengthMeters: Double?
    /// Meters — present only when Flags bit 1 is set.
    public let totalDistanceMeters: Double?
}

/// A GATT `org.bluetooth.characteristic.date_time` structure (7 bytes: uint16 year, uint8 month,
/// day, hours, minutes, seconds) as embedded in Weight/Body Composition Measurement's optional
/// Time Stamp field. Not validated against a real calendar (e.g. `month == 13` decodes as-is) —
/// GSS defines this purely as a byte layout, and range validation is a display-layer concern this
/// parsing layer deliberately leaves alone (I5: raw values are never silently "corrected").
public struct GattDateTime: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
}

/// Weight Measurement (0x2A9D) decoded per GSS §3.243. `weightKg`/`heightMeters` are always
/// canonicalized to SI regardless of the transmitted unit (Flags bit 0), so callers never branch
/// on `isImperialUnits` themselves — it is exposed only for provenance/display ("this scale
/// reports in lb").
public struct WeightMeasurement: Equatable, Sendable {
    public let weightKg: Double
    public let isImperialUnits: Bool
    public let timestamp: GattDateTime?
    public let userId: Int?
    /// Resolution 0.1 — present only when Flags bit 3 is set (BMI & Height are gated together).
    public let bmi: Double?
    /// Canonicalized to meters — present only when Flags bit 3 is set.
    public let heightMeters: Double?
}

/// Body Composition Measurement (0x2A9C) decoded per GSS §3.34 — the most heavily flag-gated
/// characteristic in this slice (13 flag bits). Every field in the spec's fixed order IS decoded
/// (so offset math never drifts for a device that sets many flags at once); `userId`,
/// `softLeanMassKg` and `bodyWaterMassKg` are consumed for correct offsets but intentionally not
/// exposed as named properties beyond what BADAN's body-composition surface needs today — see
/// each stored property's doc for exactly what this parser surfaces and why. Mass fields are
/// canonicalized to kilograms and the height field to meters regardless of transmitted units.
public struct BodyCompositionMeasurement: Equatable, Sendable {
    /// Percent, resolution 0.1 — the one MANDATORY field (always present, right after Flags).
    public let bodyFatPercent: Double
    public let isImperialUnits: Bool
    public let timestamp: GattDateTime?
    public let basalMetabolismKJ: Int?
    public let musclePercent: Double?
    public let muscleMassKg: Double?
    public let fatFreeMassKg: Double?
    public let impedanceOhms: Double?
    public let weightKg: Double?
    public let heightMeters: Double?
    /// Flags bit 12 — signals this notification is one packet of a larger multi-packet
    /// measurement. Carries no additional bytes; BADAN does not reassemble multi-packet
    /// measurements this slice (documented gap, not silently ignored — a caller sees this flag and
    /// can choose to discard/flag the reading as incomplete rather than trust a partial one).
    public let isMultiPacketMeasurement: Bool
}

/// Indoor Bike Data (0x2AD2) decoded per GSS §3.117 (`org.bluetooth.characteristic.indoor_bike_data`),
/// part of the Fitness Machine Service. Every field in the spec's fixed order IS decoded (so offset
/// math never drifts for a bike that sets many optional flags at once — see Cycling Power
/// Measurement's own Accumulated Torque precedent) but only the fields BADAN's workout session
/// engine actually consumes are exposed as named properties: Average Speed, Average Cadence, Total
/// Distance, Resistance Level, Average Power, Expended Energy, Metabolic Equivalent, Elapsed Time,
/// and Remaining Time are all consumed for correct downstream offsets but intentionally not decoded
/// into named properties — no BADAN consumer yet.
public struct IndoorBikeDataMeasurement: Equatable, Sendable {
    /// km/h, resolution 0.01 — present only when Flags bit 0 ("More Data") is CLEAR. NOTE the
    /// inverted polarity versus every other optional field in this file: bit 0 SET means this
    /// notification omits Instantaneous Speed (it will arrive in a later packet), not that the
    /// field is present.
    public let instantaneousSpeedKmh: Double?
    /// rpm — present only when Flags bit 2 is set. Raw units are 0.5 rpm (the spec transmits crank
    /// rpm at 2x scale); this parser divides by 2 so callers never repeat that scaling.
    public let instantaneousCadenceRpm: Double?
    /// Watts, signed — present only when Flags bit 6 is set.
    public let instantaneousPowerWatts: Int?
    /// bpm — present only when Flags bit 9 is set.
    public let heartRateBPM: Int?
}

/// Treadmill Data (0x2ACD) decoded per GSS §3.203 (`org.bluetooth.characteristic.treadmill_data`),
/// part of the Fitness Machine Service. An analogous but not identical flag layout to Indoor Bike
/// Data's own: Instantaneous Speed here obeys the SAME inverted "More Data" rule as Indoor Bike
/// Data's (FTMS v1.0 §4.7 — the field shall be included only when Flags bit 0 is 0), but there is
/// no cadence field at all in this characteristic (a treadmill reports pace over FTMS, not
/// crank/step cadence) — BADAN has no consumer for a cadence value here because the spec provides
/// none. Every field in the spec's fixed order IS decoded (so offset math never drifts for a
/// treadmill that sets many optional flags at once); Average Speed, Total Distance, Inclination/
/// Ramp Angle, Elevation Gain, Instantaneous/Average Pace, Expended Energy, Metabolic Equivalent,
/// Elapsed/Remaining Time, and Force on Belt are all consumed for correct downstream offsets but
/// intentionally not decoded into named properties — mirroring Cycling Power Measurement's own
/// Accumulated Torque precedent.
///
/// This type's doc, and the parser's byte-layout comment below, previously asserted that
/// Instantaneous Speed was mandatory and unconditional here "unlike Indoor Bike Data's". That was
/// simply wrong about the spec, and the parser had been written to match the wrong comment: for a
/// treadmill that splits one record across notifications (More Data = 1) it consumed the FIRST
/// optional field's bytes as a speed, shifting every later field two bytes early. On a
/// tightly-packed notification the resulting two-byte overrun tripped the next length guard and the
/// whole valid reading was silently dropped; on one carrying any trailing bytes the flags do not
/// account for, no guard tripped and BADAN ingested a fabricated speed with a wrong heart rate and
/// power output beside it. Neither outcome is acceptable for untrusted peripheral input. Nothing
/// outside this file consumed the property yet, so widening it to optional was free.
public struct TreadmillDataMeasurement: Equatable, Sendable {
    /// km/h, resolution 0.01 — present only when Flags bit 0 ("More Data") is CLEAR, exactly as in
    /// `IndoorBikeDataMeasurement.instantaneousSpeedKmh`. NOTE the inverted polarity versus every
    /// other optional field in this file: bit 0 SET means this notification omits Instantaneous
    /// Speed (it will arrive in a later packet), not that the field is present.
    public let instantaneousSpeedKmh: Double?
    /// Watts, signed — decoded from the "Force on Belt and Power Output" field's second (Power
    /// Output) sub-field; present only when Flags bit 12 is set. Force on Belt itself (newtons) is
    /// consumed for offset only, not exposed — no BADAN consumer yet.
    public let instantaneousPowerWatts: Int?
    /// bpm — present only when Flags bit 8 is set.
    public let heartRateBPM: Int?
}

// MARK: - Parsers

/// Pure GATT-bytes-to-typed-value decoders. See the file-header scope boundary above: this is the
/// half of this slice that is genuinely, exhaustively tested against spec-accurate fixtures.
/// Every function takes raw characteristic-notification bytes and returns an optional — `nil` on
/// any malformed or truncated input, NEVER a forced unwrap/trap. None of these functions perform
/// I/O, read the clock, or depend on anything beyond their input bytes.
public enum GattParsers {

    // MARK: Shared little-endian readers (GATT multi-byte fields are little-endian throughout)

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func s16(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: u16(b, i))
    }

    /// International avoirdupois pound in kilograms — the single conversion constant used
    /// everywhere an Imperial mass field is canonicalized to SI.
    private static let kgPerLb = 0.45359237
    /// International inch in meters — used everywhere an Imperial length field is canonicalized.
    private static let metersPerInch = 0.0254

    // MARK: Heart Rate Measurement (0x2A37)

    /// Decodes a Heart Rate Measurement notification per GSS §3.114.
    ///
    /// Byte layout:
    /// - Byte 0: Flags — bit0 HR value format (0=uint8, 1=uint16), bit1 sensor contact detected,
    ///   bit2 sensor contact supported, bit3 Energy Expended present, bit4 RR-Interval present,
    ///   bits5-7 reserved.
    /// - Byte 1 (or bytes 1–2 if bit0 set): Heart Rate Value, uint8 or uint16 LE, bpm.
    /// - Next 2 bytes, only if bit3 set: Energy Expended, uint16 LE, kJ.
    /// - Remaining bytes, only if bit4 set: one or more RR-Interval values, uint16 LE each,
    ///   1/1024 s resolution, consumed until the end of the notification (RR-Interval is always
    ///   the LAST field per the spec's fixed field order, so "consume to end" is correct here and
    ///   only here).
    public static func parseHeartRateMeasurement(_ data: Data) -> HeartRateMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }

        let flags = b[0]
        let is16Bit = flags & 0x01 != 0
        let contactSupported = flags & 0x04 != 0
        let contactDetected = contactSupported ? (flags & 0x02 != 0) : nil
        let energyPresent = flags & 0x08 != 0
        let rrPresent = flags & 0x10 != 0

        var offset = 1
        let hr: Int
        if is16Bit {
            guard b.count >= offset + 2 else { return nil }
            hr = Int(u16(b, offset))
            offset += 2
        } else {
            hr = Int(b[offset])
            offset += 1
        }

        var energy: Int? = nil
        if energyPresent {
            guard b.count >= offset + 2 else { return nil }
            energy = Int(u16(b, offset))
            offset += 2
        }

        var rr: [Double] = []
        if rrPresent {
            let remaining = b.count - offset
            guard remaining >= 2, remaining % 2 == 0 else { return nil }
            while offset < b.count {
                rr.append(Double(u16(b, offset)) / 1024.0)
                offset += 2
            }
        }

        return HeartRateMeasurement(heartRateBPM: hr, sensorContactSupported: contactSupported,
                                     sensorContactDetected: contactDetected, energyExpendedKJ: energy,
                                     rrIntervals: rr)
    }

    // MARK: Cycling Power Measurement (0x2A63)

    /// Decodes a Cycling Power Measurement notification per GSS §3.65.
    ///
    /// Byte layout (all multi-byte fields little-endian):
    /// - Bytes 0–1: Flags (uint16) — bit0 Pedal Power Balance present, bit2 Accumulated Torque
    ///   present, bit4 Wheel Revolution Data present, bit5 Crank Revolution Data present (higher
    ///   bits gate fields this parser does not decode — see the type's own doc for why that is
    ///   safe).
    /// - Bytes 2–3: Instantaneous Power, sint16, watts. MANDATORY — always present.
    /// - Next 1 byte, only if bit0 set: Pedal Power Balance, uint8, 1/2-percent resolution.
    /// - Next 2 bytes, only if bit2 set: Accumulated Torque, uint16 (consumed for correct
    ///   downstream offsets; not decoded into a named property — BADAN has no consumer yet).
    /// - Next 6 bytes, only if bit4 set: Cumulative Wheel Revolutions (uint32) + Last Wheel Event
    ///   Time (uint16, 1/2048 s resolution).
    /// - Next 4 bytes, only if bit5 set: Cumulative Crank Revolutions (uint16) + Last Crank Event
    ///   Time (uint16, 1/1024 s resolution).
    public static func parseCyclingPowerMeasurement(_ data: Data) -> CyclingPowerMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }

        let flags = UInt16(b[0]) | (UInt16(b[1]) << 8)
        var offset = 2
        let power = Int(s16(b, offset))
        offset += 2

        var pedalBalance: Double? = nil
        if flags & 0x0001 != 0 {
            guard b.count >= offset + 1 else { return nil }
            pedalBalance = Double(b[offset]) * 0.5
            offset += 1
        }
        if flags & 0x0004 != 0 {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Accumulated Torque — offset-only, not decoded (see doc above).
        }

        var wheelRevs: UInt32? = nil
        var wheelTime: Double? = nil
        if flags & 0x0010 != 0 {
            guard b.count >= offset + 6 else { return nil }
            wheelRevs = u32(b, offset)
            offset += 4
            wheelTime = Double(u16(b, offset)) / 2048.0
            offset += 2
        }

        var crankRevs: UInt16? = nil
        var crankTime: Double? = nil
        if flags & 0x0020 != 0 {
            guard b.count >= offset + 4 else { return nil }
            crankRevs = u16(b, offset)
            offset += 2
            crankTime = Double(u16(b, offset)) / 1024.0
            offset += 2
        }

        return CyclingPowerMeasurement(instantaneousPowerWatts: power, pedalPowerBalancePercent: pedalBalance,
                                        cumulativeWheelRevolutions: wheelRevs, lastWheelEventTimeSeconds: wheelTime,
                                        cumulativeCrankRevolutions: crankRevs, lastCrankEventTimeSeconds: crankTime)
    }

    // MARK: CSC Measurement (0x2A5B)

    /// Decodes a CSC Measurement notification per GSS §3.66.
    ///
    /// Byte layout:
    /// - Byte 0: Flags — bit0 Wheel Revolution Data present, bit1 Crank Revolution Data present.
    /// - Next 6 bytes, only if bit0 set: Cumulative Wheel Revolutions (uint32) + Last Wheel Event
    ///   Time (uint16, 1/1024 s resolution — NOTE this differs from Cycling Power Measurement's
    ///   own Last Wheel Event Time resolution of 1/2048 s; both are correct per their respective
    ///   GSS entries).
    /// - Next 4 bytes, only if bit1 set: Cumulative Crank Revolutions (uint16) + Last Crank Event
    ///   Time (uint16, 1/1024 s resolution).
    public static func parseCSCMeasurement(_ data: Data) -> CSCMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 1 else { return nil }

        let flags = b[0]
        var offset = 1

        var wheelRevs: UInt32? = nil
        var wheelTime: Double? = nil
        if flags & 0x01 != 0 {
            guard b.count >= offset + 6 else { return nil }
            wheelRevs = u32(b, offset)
            offset += 4
            wheelTime = Double(u16(b, offset)) / 1024.0
            offset += 2
        }

        var crankRevs: UInt16? = nil
        var crankTime: Double? = nil
        if flags & 0x02 != 0 {
            guard b.count >= offset + 4 else { return nil }
            crankRevs = u16(b, offset)
            offset += 2
            crankTime = Double(u16(b, offset)) / 1024.0
            offset += 2
        }

        return CSCMeasurement(cumulativeWheelRevolutions: wheelRevs, lastWheelEventTimeSeconds: wheelTime,
                               cumulativeCrankRevolutions: crankRevs, lastCrankEventTimeSeconds: crankTime)
    }

    // MARK: RSC Measurement (0x2A53)

    /// Decodes an RSC Measurement notification per GSS §3.153.
    ///
    /// Byte layout:
    /// - Byte 0: Flags — bit0 Instantaneous Stride Length present, bit1 Total Distance present,
    ///   bit2 Walking/Running Status (0=walking, 1=running — always meaningful, no separate
    ///   "supported" gate the way Heart Rate's contact bit has one).
    /// - Bytes 1–2: Instantaneous Speed, uint16 LE, 1/256 m/s resolution. MANDATORY.
    /// - Byte 3: Instantaneous Cadence, uint8, steps/minute (no scaling). MANDATORY.
    /// - Next 2 bytes, only if bit0 set: Instantaneous Stride Length, uint16 LE, 1/100 m
    ///   resolution (centimeters).
    /// - Next 4 bytes, only if bit1 set: Total Distance, uint32 LE, 1/10 m resolution.
    public static func parseRSCMeasurement(_ data: Data) -> RSCMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }

        let flags = b[0]
        let stridePresent = flags & 0x01 != 0
        let distancePresent = flags & 0x02 != 0
        let isRunning = flags & 0x04 != 0

        var offset = 1
        let speed = Double(u16(b, offset)) / 256.0
        offset += 2
        let cadence = Int(b[offset])
        offset += 1

        var stride: Double? = nil
        if stridePresent {
            guard b.count >= offset + 2 else { return nil }
            stride = Double(u16(b, offset)) / 100.0
            offset += 2
        }

        var totalDistance: Double? = nil
        if distancePresent {
            guard b.count >= offset + 4 else { return nil }
            totalDistance = Double(u32(b, offset)) / 10.0
            offset += 4
        }

        return RSCMeasurement(instantaneousSpeedMetersPerSecond: speed, instantaneousCadenceStepsPerMinute: cadence,
                               isRunning: isRunning, strideLengthMeters: stride, totalDistanceMeters: totalDistance)
    }

    // MARK: Weight Measurement (0x2A9D)

    /// Decodes a Weight Measurement notification per GSS §3.243.
    ///
    /// Byte layout:
    /// - Byte 0: Flags — bit0 Measurement Units (0=SI kg/m, 1=Imperial lb/in), bit1 Time Stamp
    ///   present, bit2 User ID present, bit3 BMI & Height present (gated together).
    /// - Bytes 1–2: Weight, uint16 LE — 0.005 kg resolution (SI) or 0.01 lb resolution (Imperial).
    ///   MANDATORY. GSS reserves 0xFFFF for this field as "Measurement Unsuccessful": a scale that
    ///   could not weigh (user stepped off early, unstable load) still indicates a notification and
    ///   fills the field with the sentinel. Decoded arithmetically that is 327.675 kg — a value
    ///   BADAN would happily store as a real reading — so this parser rejects the whole
    ///   measurement, per the file-header contract that a malformed notification yields `nil`
    ///   rather than an invented number.
    /// - Next 7 bytes, only if bit1 set: Time Stamp (`org.bluetooth.characteristic.date_time`):
    ///   uint16 year, uint8 month, day, hours, minutes, seconds.
    /// - Next 1 byte, only if bit2 set: User ID, uint8.
    /// - Next 4 bytes, only if bit3 set: BMI (uint16 LE, 0.1 resolution) + Height (uint16 LE,
    ///   0.001 m resolution SI / 0.1 in resolution Imperial).
    public static func parseWeightMeasurement(_ data: Data) -> WeightMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 3 else { return nil }

        let flags = b[0]
        let imperial = flags & 0x01 != 0
        let timestampPresent = flags & 0x02 != 0
        let userIdPresent = flags & 0x04 != 0
        let bmiHeightPresent = flags & 0x08 != 0

        var offset = 1
        let rawWeight = u16(b, offset)
        offset += 2
        // 0xFFFF is the GSS "Measurement Unsuccessful" sentinel, not a weight — see the byte-layout
        // note above. Rejecting it here is the only place it can be caught: downstream every value
        // is just a Double, and 327.675 kg looks like data rather than a failure signal.
        guard rawWeight != 0xFFFF else { return nil }
        let weightKg = imperial ? Double(rawWeight) * 0.01 * kgPerLb : Double(rawWeight) * 0.005

        var timestamp: GattDateTime? = nil
        if timestampPresent {
            guard b.count >= offset + 7 else { return nil }
            timestamp = GattDateTime(year: Int(u16(b, offset)), month: Int(b[offset + 2]), day: Int(b[offset + 3]),
                                      hours: Int(b[offset + 4]), minutes: Int(b[offset + 5]), seconds: Int(b[offset + 6]))
            offset += 7
        }

        var userId: Int? = nil
        if userIdPresent {
            guard b.count >= offset + 1 else { return nil }
            userId = Int(b[offset])
            offset += 1
        }

        var bmi: Double? = nil
        var heightM: Double? = nil
        if bmiHeightPresent {
            guard b.count >= offset + 4 else { return nil }
            bmi = Double(u16(b, offset)) * 0.1
            offset += 2
            let rawHeight = u16(b, offset)
            heightM = imperial ? Double(rawHeight) * 0.1 * metersPerInch : Double(rawHeight) * 0.001
            offset += 2
        }

        return WeightMeasurement(weightKg: weightKg, isImperialUnits: imperial, timestamp: timestamp,
                                  userId: userId, bmi: bmi, heightMeters: heightM)
    }

    // MARK: Body Composition Measurement (0x2A9C)

    /// Decodes a Body Composition Measurement notification per GSS §3.34.
    ///
    /// Byte layout (all multi-byte fields little-endian; every field below IS consumed in order
    /// so a device that sets several flags at once still decodes correctly — see the type's own
    /// doc for exactly which fields are exposed vs. consumed-for-offset-only):
    /// - Bytes 0–1: Flags (uint16) — bit0 units (0=SI,1=Imperial), bit1 Time Stamp present, bit2
    ///   User ID present, bit3 Basal Metabolism present, bit4 Muscle Percentage present, bit5
    ///   Muscle Mass present, bit6 Fat Free Mass present, bit7 Soft Lean Mass present, bit8 Body
    ///   Water Mass present, bit9 Impedance present, bit10 Weight present, bit11 Height present,
    ///   bit12 Multiple Packet Measurement (no associated bytes).
    /// - Bytes 2–3: Body Fat Percentage, uint16 LE, 0.1% resolution. MANDATORY.
    /// - +7 bytes if bit1: Time Stamp (same `date_time` layout as Weight Measurement).
    /// - +1 byte if bit2: User ID, uint8.
    /// - +2 bytes if bit3: Basal Metabolism, uint16 LE, kJ (resolution 1).
    /// - +2 bytes if bit4: Muscle Percentage, uint16 LE, 0.1% resolution.
    /// - +2 bytes if bit5: Muscle Mass, uint16 LE, mass-resolution (0.005 kg SI / 0.01 lb Imperial).
    /// - +2 bytes if bit6: Fat Free Mass, uint16 LE, same mass resolution.
    /// - +2 bytes if bit7: Soft Lean Mass, uint16 LE, same mass resolution (consumed for offset
    ///   only — not exposed; no BADAN consumer yet).
    /// - +2 bytes if bit8: Body Water Mass, uint16 LE, same mass resolution (consumed for offset
    ///   only — not exposed; no BADAN consumer yet).
    /// - +2 bytes if bit9: Impedance, uint16 LE, 0.1 Ohm resolution.
    /// - +2 bytes if bit10: Weight, uint16 LE, same mass resolution as Weight Measurement.
    /// - +2 bytes if bit11: Height, uint16 LE, same length resolution as Weight Measurement.
    public static func parseBodyCompositionMeasurement(_ data: Data) -> BodyCompositionMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }

        let flags = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let imperial = flags & 0x0001 != 0
        var offset = 2
        let bodyFatPercent = Double(u16(b, offset)) * 0.1
        offset += 2

        func massKg() -> Double? {
            guard b.count >= offset + 2 else { return nil }
            let raw = u16(b, offset)
            offset += 2
            return imperial ? Double(raw) * 0.01 * kgPerLb : Double(raw) * 0.005
        }

        var timestamp: GattDateTime? = nil
        if flags & 0x0002 != 0 {
            guard b.count >= offset + 7 else { return nil }
            timestamp = GattDateTime(year: Int(u16(b, offset)), month: Int(b[offset + 2]), day: Int(b[offset + 3]),
                                      hours: Int(b[offset + 4]), minutes: Int(b[offset + 5]), seconds: Int(b[offset + 6]))
            offset += 7
        }

        var userId: Int? = nil
        if flags & 0x0004 != 0 {
            guard b.count >= offset + 1 else { return nil }
            userId = Int(b[offset])
            offset += 1
        }

        var basalMetabolism: Int? = nil
        if flags & 0x0008 != 0 {
            guard b.count >= offset + 2 else { return nil }
            basalMetabolism = Int(u16(b, offset))
            offset += 2
        }

        var musclePercent: Double? = nil
        if flags & 0x0010 != 0 {
            guard b.count >= offset + 2 else { return nil }
            musclePercent = Double(u16(b, offset)) * 0.1
            offset += 2
        }

        var muscleMass: Double? = nil
        if flags & 0x0020 != 0 {
            guard let m = massKg() else { return nil }
            muscleMass = m
        }

        var fatFreeMass: Double? = nil
        if flags & 0x0040 != 0 {
            guard let m = massKg() else { return nil }
            fatFreeMass = m
        }

        if flags & 0x0080 != 0 {
            guard massKg() != nil else { return nil } // Soft Lean Mass — offset-only, see doc above.
        }

        if flags & 0x0100 != 0 {
            guard massKg() != nil else { return nil } // Body Water Mass — offset-only, see doc above.
        }

        var impedance: Double? = nil
        if flags & 0x0200 != 0 {
            guard b.count >= offset + 2 else { return nil }
            impedance = Double(u16(b, offset)) * 0.1
            offset += 2
        }

        var weightKg: Double? = nil
        if flags & 0x0400 != 0 {
            guard let m = massKg() else { return nil }
            weightKg = m
        }

        var heightM: Double? = nil
        if flags & 0x0800 != 0 {
            guard b.count >= offset + 2 else { return nil }
            let rawHeight = u16(b, offset)
            heightM = imperial ? Double(rawHeight) * 0.1 * metersPerInch : Double(rawHeight) * 0.001
            offset += 2
        }

        let multiPacket = flags & 0x1000 != 0

        return BodyCompositionMeasurement(bodyFatPercent: bodyFatPercent, isImperialUnits: imperial,
                                           timestamp: timestamp, basalMetabolismKJ: basalMetabolism,
                                           musclePercent: musclePercent, muscleMassKg: muscleMass,
                                           fatFreeMassKg: fatFreeMass, impedanceOhms: impedance,
                                           weightKg: weightKg, heightMeters: heightM,
                                           isMultiPacketMeasurement: multiPacket)
    }

    // MARK: Indoor Bike Data (0x2AD2)

    /// Decodes an Indoor Bike Data notification per GSS §3.117.
    ///
    /// Byte layout (all multi-byte fields little-endian; every field below IS consumed in the
    /// spec's fixed order so a bike that sets many flags at once still decodes correctly — see the
    /// type's own doc for exactly which fields are exposed vs. consumed-for-offset-only):
    /// - Bytes 0–1: Flags (uint16) — bit0 More Data (INVERTED: CLEAR means Instantaneous Speed IS
    ///   present, SET means it is NOT — see the type's own doc), bit1 Average Speed present, bit2
    ///   Instantaneous Cadence present, bit3 Average Cadence present, bit4 Total Distance present,
    ///   bit5 Resistance Level present, bit6 Instantaneous Power present, bit7 Average Power
    ///   present, bit8 Expended Energy present, bit9 Heart Rate present, bit10 Metabolic Equivalent
    ///   present, bit11 Elapsed Time present, bit12 Remaining Time present.
    /// - +2 bytes if bit0 CLEAR: Instantaneous Speed, uint16 LE, 0.01 km/h resolution.
    /// - +2 bytes if bit1: Average Speed, uint16 LE, 0.01 km/h resolution (offset-only — no BADAN
    ///   consumer yet).
    /// - +2 bytes if bit2: Instantaneous Cadence, uint16 LE, 0.5 rpm resolution (raw value is crank
    ///   rpm doubled per spec; this parser divides by 2).
    /// - +2 bytes if bit3: Average Cadence, uint16 LE, 0.5 rpm resolution (offset-only).
    /// - +3 bytes if bit4: Total Distance, uint24 LE, 1 m resolution (offset-only).
    /// - +2 bytes if bit5: Resistance Level, sint16, unitless (offset-only).
    /// - +2 bytes if bit6: Instantaneous Power, sint16, 1 W resolution.
    /// - +2 bytes if bit7: Average Power, sint16, 1 W resolution (offset-only).
    /// - +5 bytes if bit8: Expended Energy — Total Energy (uint16 LE, kcal), Energy Per Hour
    ///   (uint16 LE, kcal/hr), Energy Per Minute (uint8, kcal/min) (offset-only).
    /// - +1 byte if bit9: Heart Rate, uint8, bpm.
    /// - +1 byte if bit10: Metabolic Equivalent, uint8, 0.1 resolution (offset-only).
    /// - +2 bytes if bit11: Elapsed Time, uint16 LE, 1 s resolution (offset-only).
    /// - +2 bytes if bit12: Remaining Time, uint16 LE, 1 s resolution (offset-only, last field).
    public static func parseIndoorBikeDataMeasurement(_ data: Data) -> IndoorBikeDataMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }

        let flags = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let moreData = flags & 0x0001 != 0
        let avgSpeedPresent = flags & 0x0002 != 0
        let cadencePresent = flags & 0x0004 != 0
        let avgCadencePresent = flags & 0x0008 != 0
        let totalDistancePresent = flags & 0x0010 != 0
        let resistancePresent = flags & 0x0020 != 0
        let powerPresent = flags & 0x0040 != 0
        let avgPowerPresent = flags & 0x0080 != 0
        let expendedEnergyPresent = flags & 0x0100 != 0
        let heartRatePresent = flags & 0x0200 != 0
        let metabolicEquivPresent = flags & 0x0400 != 0
        let elapsedTimePresent = flags & 0x0800 != 0
        let remainingTimePresent = flags & 0x1000 != 0

        var offset = 2

        var speed: Double? = nil
        if !moreData {
            guard b.count >= offset + 2 else { return nil }
            speed = Double(u16(b, offset)) * 0.01
            offset += 2
        }

        if avgSpeedPresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Average Speed — offset-only, not decoded (see type's own doc).
        }

        var cadence: Double? = nil
        if cadencePresent {
            guard b.count >= offset + 2 else { return nil }
            cadence = Double(u16(b, offset)) * 0.5
            offset += 2
        }

        if avgCadencePresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Average Cadence — offset-only.
        }

        if totalDistancePresent {
            guard b.count >= offset + 3 else { return nil }
            offset += 3 // Total Distance (uint24) — offset-only.
        }

        if resistancePresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Resistance Level — offset-only.
        }

        var power: Int? = nil
        if powerPresent {
            guard b.count >= offset + 2 else { return nil }
            power = Int(s16(b, offset))
            offset += 2
        }

        if avgPowerPresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Average Power — offset-only.
        }

        if expendedEnergyPresent {
            guard b.count >= offset + 5 else { return nil }
            offset += 5 // Expended Energy (Total/PerHour uint16 x2 + PerMinute uint8) — offset-only.
        }

        var heartRate: Int? = nil
        if heartRatePresent {
            guard b.count >= offset + 1 else { return nil }
            heartRate = Int(b[offset])
            offset += 1
        }

        if metabolicEquivPresent {
            guard b.count >= offset + 1 else { return nil }
            offset += 1 // Metabolic Equivalent — offset-only.
        }

        if elapsedTimePresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Elapsed Time — offset-only.
        }

        if remainingTimePresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Remaining Time — offset-only.
        }

        return IndoorBikeDataMeasurement(instantaneousSpeedKmh: speed, instantaneousCadenceRpm: cadence,
                                          instantaneousPowerWatts: power, heartRateBPM: heartRate)
    }

    // MARK: Treadmill Data (0x2ACD)

    /// Decodes a Treadmill Data notification per GSS §3.203.
    ///
    /// Byte layout (all multi-byte fields little-endian; every field below IS consumed in the
    /// spec's fixed order so a treadmill that sets many flags at once still decodes correctly —
    /// see the type's own doc for exactly which fields are exposed vs. consumed-for-offset-only):
    /// - Bytes 0–1: Flags (uint16) — bit0 More Data (INVERTED, exactly as in Indoor Bike Data:
    ///   CLEAR means Instantaneous Speed IS present, SET means it is NOT — see the type's own doc),
    ///   bit1 Average Speed present, bit2 Total Distance present, bit3 Inclination and Ramp Angle
    ///   Setting present, bit4 Elevation Gain present, bit5 Instantaneous Pace present, bit6
    ///   Average Pace present, bit7 Expended Energy present, bit8 Heart Rate present, bit9
    ///   Metabolic Equivalent present, bit10 Elapsed Time present, bit11 Remaining Time present,
    ///   bit12 Force on Belt and Power Output present.
    /// - +2 bytes if bit0 CLEAR: Instantaneous Speed, uint16 LE, 0.01 km/h resolution. FTMS v1.0
    ///   §4.7 makes this conditional, not mandatory: the field shall be included only when the More
    ///   Data bit is 0.
    /// - +2 bytes if bit1: Average Speed, uint16 LE, 0.01 km/h resolution (offset-only — no BADAN
    ///   consumer yet).
    /// - +3 bytes if bit2: Total Distance, uint24 LE, 1 m resolution (offset-only).
    /// - +4 bytes if bit3: Inclination (sint16, 0.1% resolution) + Ramp Angle Setting (sint16,
    ///   0.1° resolution) (offset-only).
    /// - +4 bytes if bit4: Positive Elevation Gain (uint16 LE, 0.1 m) + Negative Elevation Gain
    ///   (uint16 LE, 0.1 m) (offset-only).
    /// - +1 byte if bit5: Instantaneous Pace, uint8, 0.1 min/km resolution (offset-only).
    /// - +1 byte if bit6: Average Pace, uint8, 0.1 min/km resolution (offset-only).
    /// - +5 bytes if bit7: Expended Energy — Total Energy (uint16 LE, kcal), Energy Per Hour
    ///   (uint16 LE, kcal/hr), Energy Per Minute (uint8, kcal/min) (offset-only).
    /// - +1 byte if bit8: Heart Rate, uint8, bpm.
    /// - +1 byte if bit9: Metabolic Equivalent, uint8, 0.1 resolution (offset-only).
    /// - +2 bytes if bit10: Elapsed Time, uint16 LE, 1 s resolution (offset-only).
    /// - +2 bytes if bit11: Remaining Time, uint16 LE, 1 s resolution (offset-only).
    /// - +4 bytes if bit12: Force on Belt (sint16, 1 N — offset-only, not decoded) + Power Output
    ///   (sint16, 1 W).
    public static func parseTreadmillDataMeasurement(_ data: Data) -> TreadmillDataMeasurement? {
        let b = [UInt8](data)
        // Only the two Flags bytes are unconditionally present. Instantaneous Speed is gated on the
        // More Data bit below, so a flags-only notification (More Data set, nothing else) is a
        // valid — if minimal — reading, not truncated input. Mirrors the Indoor Bike Data guard.
        guard b.count >= 2 else { return nil }

        let flags = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let moreData = flags & 0x0001 != 0
        let avgSpeedPresent = flags & 0x0002 != 0
        let totalDistancePresent = flags & 0x0004 != 0
        let inclinationPresent = flags & 0x0008 != 0
        let elevationGainPresent = flags & 0x0010 != 0
        let instantaneousPacePresent = flags & 0x0020 != 0
        let averagePacePresent = flags & 0x0040 != 0
        let expendedEnergyPresent = flags & 0x0080 != 0
        let heartRatePresent = flags & 0x0100 != 0
        let metabolicEquivPresent = flags & 0x0200 != 0
        let elapsedTimePresent = flags & 0x0400 != 0
        let remainingTimePresent = flags & 0x0800 != 0
        let forceAndPowerPresent = flags & 0x1000 != 0

        var offset = 2

        var speed: Double? = nil
        if !moreData {
            guard b.count >= offset + 2 else { return nil }
            speed = Double(u16(b, offset)) * 0.01
            offset += 2
        }

        if avgSpeedPresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Average Speed — offset-only.
        }

        if totalDistancePresent {
            guard b.count >= offset + 3 else { return nil }
            offset += 3 // Total Distance (uint24) — offset-only.
        }

        if inclinationPresent {
            guard b.count >= offset + 4 else { return nil }
            offset += 4 // Inclination + Ramp Angle Setting — offset-only.
        }

        if elevationGainPresent {
            guard b.count >= offset + 4 else { return nil }
            offset += 4 // Positive/Negative Elevation Gain — offset-only.
        }

        if instantaneousPacePresent {
            guard b.count >= offset + 1 else { return nil }
            offset += 1 // Instantaneous Pace — offset-only.
        }

        if averagePacePresent {
            guard b.count >= offset + 1 else { return nil }
            offset += 1 // Average Pace — offset-only.
        }

        if expendedEnergyPresent {
            guard b.count >= offset + 5 else { return nil }
            offset += 5 // Expended Energy — offset-only.
        }

        var heartRate: Int? = nil
        if heartRatePresent {
            guard b.count >= offset + 1 else { return nil }
            heartRate = Int(b[offset])
            offset += 1
        }

        if metabolicEquivPresent {
            guard b.count >= offset + 1 else { return nil }
            offset += 1 // Metabolic Equivalent — offset-only.
        }

        if elapsedTimePresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Elapsed Time — offset-only.
        }

        if remainingTimePresent {
            guard b.count >= offset + 2 else { return nil }
            offset += 2 // Remaining Time — offset-only.
        }

        var power: Int? = nil
        if forceAndPowerPresent {
            guard b.count >= offset + 4 else { return nil }
            offset += 2 // Force on Belt — offset-only, not decoded (see type's own doc).
            power = Int(s16(b, offset))
            offset += 2
        }

        return TreadmillDataMeasurement(instantaneousSpeedKmh: speed, instantaneousPowerWatts: power,
                                         heartRateBPM: heartRate)
    }
}
