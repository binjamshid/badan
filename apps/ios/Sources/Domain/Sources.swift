import Foundation

/// Where data comes from — a platform store, a manual entry channel, an import, or (later)
/// a vendor. Hidden ≠ deleted: a hidden source stops contributing but its history stays.
public enum SourceType: String, Codable, Hashable, Sendable {
    case healthkit
    case healthConnect
    case manual
    case fileImport = "import"
    case vendor
}

public enum SourceStatus: String, Codable, Hashable, Sendable {
    case active
    case revoked
    case hidden
}

/// EPIC-43 (plan §9.19): the primary provenance signal for HOW a source/device connects — a
/// finer-grained classification than `SourceType`, which only distinguishes platform-store vs.
/// manual vs. import vs. vendor. Every case here is a real, already-scoped integration route from
/// plan §7A.6's doctrine table; there is no `bleBloodPressure`/`bleThermometer`/`blePulseOximeter`
/// case because those three surfaces are gated behind approval A25 (a retained clinical advisor)
/// and are on the founder's standing do-not-build list — they are not represented here even as an
/// unused case.
public enum ConnectionType: String, Codable, Hashable, Sendable {
    case healthkit
    case healthConnect = "health_connect"
    case bleDirect = "ble_direct"
    case fitnessMachine = "fitness_machine"
    case manual
    case vendorOAuth = "vendor_oauth"
    case vendorSDK = "vendor_sdk"
    case broker
    case fileImport = "file_import"
}

/// EPIC-43 (plan §9.19): what a source/device can PROVIDE — independent of `ConnectionType`
/// (which says HOW it connects). A BLE chest strap and a BLE cycling computer are both
/// `.bleDirect`, but only one carries `.heartRateChestStrap`; `ConflictDecisionEngine`'s
/// chest-strap-beats-wrist default reads exactly this distinction (via a caller-supplied
/// `CandidateReading.classification`, not this enum directly — see that type's own doc). No
/// blood-pressure/thermometer/pulse-oximeter case, for the same do-not-build reason
/// `ConnectionType` omits `bleDirect`'s clinically-adjacent siblings.
public enum DeviceCapability: String, Codable, Hashable, Sendable {
    case heartRate = "heart_rate"
    case heartRateChestStrap = "heart_rate_chest_strap"
    case cyclingPower = "cycling_power"
    case cyclingSpeedCadence = "cycling_speed_cadence"
    case runningSpeedCadence = "running_speed_cadence"
    case fitnessMachine = "fitness_machine"
    case weightScale = "weight_scale"
    case bodyComposition = "body_composition"
}

public struct Source: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: SourceType
    public var displayName: String
    public var platformBundleId: String?
    public var status: SourceStatus
    public var connectedAt: Date?
    public var lastDeliveryAt: Date?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?
    // MARK: - EPIC-43 (plan §9.19) — additive, all-optional per this struct's own contract above.
    // A source written before this slice (or by `CatalogRepository`, which does not populate these
    // yet — see migration 10's own doc) decodes them as `nil` rather than failing, exactly like
    // `WorkoutDetail`'s EPIC-42 slice-2 fields: Swift's synthesized decoder treats a missing key for
    // an `Optional` as `nil`, which is the whole reason these are added optionals rather than a
    // second, parallel struct.
    public var connectionType: ConnectionType?
    public var capabilities: Set<DeviceCapability>?

    public init(
        id: String, type: SourceType, displayName: String, platformBundleId: String? = nil,
        status: SourceStatus = .active, connectedAt: Date? = nil, lastDeliveryAt: Date? = nil,
        updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil,
        connectionType: ConnectionType? = nil, capabilities: Set<DeviceCapability>? = nil
    ) {
        self.id = id; self.type = type; self.displayName = displayName
        self.platformBundleId = platformBundleId; self.status = status
        self.connectedAt = connectedAt; self.lastDeliveryAt = lastDeliveryAt
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
        self.connectionType = connectionType; self.capabilities = capabilities
    }
}

public struct Device: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceId: String
    public var name: String
    public var model: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?
    // MARK: - EPIC-43 (plan §9.19) — additive, all-optional; see `Source`'s own doc above for why.
    public var connectionType: ConnectionType?
    public var capabilities: Set<DeviceCapability>?

    public init(id: String, sourceId: String, name: String, model: String? = nil,
                firstSeen: Date, lastSeen: Date, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil, connectionType: ConnectionType? = nil,
                capabilities: Set<DeviceCapability>? = nil) {
        self.id = id; self.sourceId = sourceId; self.name = name; self.model = model
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
        self.connectionType = connectionType; self.capabilities = capabilities
    }
}

/// Permission is a first-class UI state, not an error. This drives honest granted /
/// denied / partial matrices in Settings and Onboarding.
public enum PermissionStatus: String, Codable, Hashable, Sendable {
    case notRequested
    case granted
    case denied
    case partial
    case revoked

    public var displayLabel: LocalizedString {
        switch self {
        case .notRequested: return LocalizedString(en: "Not requested", ar: "لم يُطلب")
        case .granted: return LocalizedString(en: "Connected", ar: "متصل")
        case .denied: return LocalizedString(en: "Not allowed", ar: "غير مسموح")
        case .partial: return LocalizedString(en: "Partly allowed", ar: "مسموح جزئياً")
        case .revoked: return LocalizedString(en: "Turned off", ar: "متوقف")
        }
    }
}

public struct PermissionState: Codable, Hashable, Sendable, Identifiable {
    public var store: String        // "healthkit" | "healthConnect"
    public var platformType: String // e.g. "sleepAnalysis"
    public var status: PermissionStatus
    public var lastCheckedAt: Date
    public var lastReadAt: Date?

    public var id: String { "\(store):\(platformType)" }

    public init(store: String, platformType: String, status: PermissionStatus,
                lastCheckedAt: Date, lastReadAt: Date? = nil) {
        self.store = store; self.platformType = platformType; self.status = status
        self.lastCheckedAt = lastCheckedAt; self.lastReadAt = lastReadAt
    }
}

/// The single local user. BADAN MVP has no accounts; the profile is device-local and
/// exists to hold demographics used only for on-device derivations (e.g. BMI needs height).
public struct UserProfile: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String?
    public var heightMeters: Double?
    public var birthYear: Int?
    public var biologicalContextNote: String?
    /// Overriding maximum heart rate in bpm, or `nil` to use the age-derived default (EPIC-26
    /// computes `208 − 0.7·age` from `birthYear`). A physiological attribute of the person — it
    /// sits here beside height, not in the presentation profile, and `nil` is a meaningful default
    /// ("derive it"), never "unset to zero". `Double?` because the derived fallback is fractional
    /// and this layer must not pre-round a value the Effort engine owns the precision of.
    public var hrMax: Double?
    /// The user's personal five-zone override, or `nil` to let EPIC-26 derive the zones from
    /// `hrMax`. Persisted as JSON in `user_profile.hr_zones`; see `HRZones`.
    public var hrZones: HRZones?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, displayName: String? = nil, heightMeters: Double? = nil,
                birthYear: Int? = nil, biologicalContextNote: String? = nil,
                hrMax: Double? = nil, hrZones: HRZones? = nil,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.displayName = displayName; self.heightMeters = heightMeters
        self.birthYear = birthYear; self.biologicalContextNote = biologicalContextNote
        self.hrMax = hrMax; self.hrZones = hrZones
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
