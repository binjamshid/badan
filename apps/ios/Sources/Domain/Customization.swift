import Foundation

/// The dual-altitude mechanism (D-5). Casual and power are presentation policies over a
/// single component library and identical queries — never separate products.
public enum DepthPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case casual, balanced, power

    public var displayName: LocalizedString {
        switch self {
        case .casual: return LocalizedString(en: "Simple", ar: "مبسّط")
        case .balanced: return LocalizedString(en: "Balanced", ar: "متوازن")
        case .power: return LocalizedString(en: "Detailed", ar: "مفصّل")
        }
    }

    /// Whether power-only affordances (raw values, lineage, tables, algorithm strings) show.
    public var showsPowerDetail: Bool { self == .power }
    /// The most compact number of home modules this depth prefers to show.
    public var maxHomeModules: Int { self == .casual ? 5 : 12 }
}

public enum AppTheme: String, Codable, Hashable, Sendable, CaseIterable {
    case system, light, dark
    public var displayName: LocalizedString {
        switch self {
        case .system: return LocalizedString(en: "Match device", ar: "حسب الجهاز")
        case .light: return LocalizedString(en: "Light", ar: "فاتح")
        case .dark: return LocalizedString(en: "Dark", ar: "داكن")
        }
    }
}

public enum UnitProfileMode: String, Codable, Hashable, Sendable {
    case canonical   // SI units, provenance-faithful
    case display     // the user's chosen display units
}

/// An orderable, hideable home surface. This is the DashboardCard/DashboardLayout concept.
public struct HomeModule: Codable, Hashable, Sendable, Identifiable {
    public var id: String            // "sleep" | "readiness" | "activity" | "meds" | ...
    public var visible: Bool
    public var order: Int

    public init(id: String, visible: Bool, order: Int) {
        self.id = id; self.visible = visible; self.order = order
    }
}

public struct NotificationPreference: Codable, Hashable, Sendable {
    public var morningNarrative: Bool
    public var weeklyDigest: Bool
    public var medicationReminders: Bool
    public var dataPausedAlerts: Bool

    public init(morningNarrative: Bool = true, weeklyDigest: Bool = true,
                medicationReminders: Bool = false, dataPausedAlerts: Bool = true) {
        self.morningNarrative = morningNarrative; self.weeklyDigest = weeklyDigest
        self.medicationReminders = medicationReminders; self.dataPausedAlerts = dataPausedAlerts
    }
}

public enum GoalDirection: String, Codable, Hashable, Sendable {
    case atLeast, atMost, around
}

public struct Goal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var target: Double
    public var unit: String
    public var direction: GoalDirection
    public var active: Bool
    public var createdAt: Date

    public init(id: String, metricId: String, target: Double, unit: String,
                direction: GoalDirection, active: Bool = true, createdAt: Date) {
        self.id = id; self.metricId = metricId; self.target = target; self.unit = unit
        self.direction = direction; self.active = active; self.createdAt = createdAt
    }
}

/// The single presentation/preferences record. This IS the "one model, two altitudes"
/// switch plus units, language, theme and dashboard layout — a UserPreference aggregate.
public struct CustomizationProfile: Codable, Hashable, Sendable {
    public var depthPolicy: DepthPolicy
    public var homeModules: [HomeModule]
    public var unitOverrides: [String: String]   // metricId -> preferred display unit
    public var unitProfile: UnitProfileMode
    public var language: AppLanguage
    public var arabicDigits: Bool
    public var theme: AppTheme
    public var notifications: NotificationPreference
    public var sensitiveModulesEnabled: Bool
    public var nutritionEnabled: Bool

    public init(depthPolicy: DepthPolicy = .balanced, homeModules: [HomeModule] = CustomizationProfile.defaultModules,
                unitOverrides: [String: String] = [:], unitProfile: UnitProfileMode = .display,
                language: AppLanguage = .en, arabicDigits: Bool = false, theme: AppTheme = .system,
                notifications: NotificationPreference = NotificationPreference(),
                sensitiveModulesEnabled: Bool = true, nutritionEnabled: Bool = true) {
        self.depthPolicy = depthPolicy; self.homeModules = homeModules
        self.unitOverrides = unitOverrides; self.unitProfile = unitProfile
        self.language = language; self.arabicDigits = arabicDigits; self.theme = theme
        self.notifications = notifications; self.sensitiveModulesEnabled = sensitiveModulesEnabled
        self.nutritionEnabled = nutritionEnabled
    }

    public static let defaultModules: [HomeModule] = [
        HomeModule(id: "readiness", visible: true, order: 0),
        HomeModule(id: "sleep", visible: true, order: 1),
        HomeModule(id: "activity", visible: true, order: 2),
        HomeModule(id: "heart", visible: true, order: 3),
        HomeModule(id: "meds", visible: true, order: 4),
        HomeModule(id: "nutrition", visible: true, order: 5),
        HomeModule(id: "timeline", visible: true, order: 6),
    ]

    public func module(_ id: String) -> HomeModule? { homeModules.first { $0.id == id } }
    public var visibleModulesOrdered: [HomeModule] {
        homeModules.filter { $0.visible }.sorted { $0.order < $1.order }
    }
}
