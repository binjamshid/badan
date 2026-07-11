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

    public init(
        id: String, type: SourceType, displayName: String, platformBundleId: String? = nil,
        status: SourceStatus = .active, connectedAt: Date? = nil, lastDeliveryAt: Date? = nil,
        updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil
    ) {
        self.id = id; self.type = type; self.displayName = displayName
        self.platformBundleId = platformBundleId; self.status = status
        self.connectedAt = connectedAt; self.lastDeliveryAt = lastDeliveryAt
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
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

    public init(id: String, sourceId: String, name: String, model: String? = nil,
                firstSeen: Date, lastSeen: Date, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.sourceId = sourceId; self.name = name; self.model = model
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
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
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, displayName: String? = nil, heightMeters: Double? = nil,
                birthYear: Int? = nil, biologicalContextNote: String? = nil,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.displayName = displayName; self.heightMeters = heightMeters
        self.birthYear = birthYear; self.biologicalContextNote = biologicalContextNote
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
