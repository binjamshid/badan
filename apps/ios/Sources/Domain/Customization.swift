import Foundation

/// The dual-altitude mechanism (D-5). Casual and power are presentation policies over a
/// single component library and identical queries — never separate products. (UX-03: a third
/// "balanced" tier used to exist here but rendered identically to casual everywhere while
/// badged as "Recommended" in Settings; it was removed rather than actually implemented as a
/// distinct altitude. See `CustomizationProfile.init(from:)` for the tolerant decode that maps
/// any persisted "balanced" — or other unknown — value to `.casual`.)
public enum DepthPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case casual, power

    public var displayName: LocalizedString {
        switch self {
        case .casual: return LocalizedString(en: "Simple", ar: "مبسّط")
        case .power: return LocalizedString(en: "Detailed", ar: "مفصّل")
        }
    }

    /// Whether power-only affordances (raw values, lineage, tables, algorithm strings) show.
    public var showsPowerDetail: Bool { self == .power }
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

/// A notification quiet-hours window, in local wall-clock hours. `startHour` is inclusive,
/// `endHour` exclusive; a window may wrap past midnight (e.g. 22→07). EPIC-32's decision engine
/// consults it per notification class so a calm nudge never lands in the middle of the night.
/// Stored as two ints rather than `Date`s because it is a recurring wall-clock rule, not an instant.
///
/// Deliberately distinct from `Domain/Automation`'s minute-based `QuietHours` (EPIC-15): that one
/// carries an export-schedule's `"HH:mm-HH:mm"` storage-string parity contract, this one is an
/// hour-granularity user preference. Coupling the two types would tie a notification-prefs change to
/// the automation-schedule storage format for no shared benefit.
public struct NotificationQuietHours: Codable, Hashable, Sendable {
    public var startHour: Int   // 0…23, inclusive
    public var endHour: Int     // 0…23, exclusive (may be < startHour to wrap midnight)

    public init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }

    /// The default night window applied to non-med classes: 22:00 → 07:00 local.
    public static let defaultNight = NotificationQuietHours(startHour: 22, endHour: 7)
}

public struct NotificationPreference: Codable, Hashable, Sendable {
    public var morningNarrative: Bool
    public var weeklyDigest: Bool
    public var medicationReminders: Bool
    public var dataPausedAlerts: Bool
    /// EPIC-32 per-class opt-in for the decision-engine classes, keyed by `NotificationClass`'s
    /// storage code (`readiness`, `windDown`, `deviation`, `exportHealth`, `hydration`). A missing
    /// key means OFF — every class is opt-in and ships OFF (the existing convention), so an empty
    /// map is "nothing enabled". `meds` is deliberately NOT keyed here: it keeps using
    /// `medicationReminders` above so the existing med-reminder wiring and tests are untouched.
    public var classOptIn: [String: Bool]
    /// EPIC-32 quiet-hours window honoured by every non-med decision class. Modeled as one window
    /// (what a user means by "don't notify me at night"); the engine takes it PER class, so a future
    /// per-class override slots in without a schema change.
    public var quietHours: NotificationQuietHours

    // STUB-12: `morningNarrative`/`weeklyDigest`/`dataPausedAlerts` used to default `true` —
    // pre-consenting every user to notification categories that have no delivery mechanism at
    // all (`SettingsScreen` hides their toggles for exactly this reason — see NEW-02/UX-02).
    // All four now default `false`; only an explicit, working toggle should ever flip one on.
    public init(morningNarrative: Bool = false, weeklyDigest: Bool = false,
                medicationReminders: Bool = false, dataPausedAlerts: Bool = false,
                classOptIn: [String: Bool] = [:], quietHours: NotificationQuietHours = .defaultNight) {
        self.morningNarrative = morningNarrative; self.weeklyDigest = weeklyDigest
        self.medicationReminders = medicationReminders; self.dataPausedAlerts = dataPausedAlerts
        self.classOptIn = classOptIn; self.quietHours = quietHours
    }

    // STUB-12: tolerant decode — any of these fields missing from a persisted profile (an older
    // install, or a preference added after that profile was last saved) decodes to its default,
    // instead of the synthesized all-or-nothing `Decodable` failing the whole
    // `NotificationPreference` decode — which would fail the enclosing `CustomizationProfile` decode
    // in turn, and `ProfileRepository.load()` treats any decode failure as "no saved profile,"
    // silently resetting every other preference too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        morningNarrative = try c.decodeIfPresent(Bool.self, forKey: .morningNarrative) ?? false
        weeklyDigest = try c.decodeIfPresent(Bool.self, forKey: .weeklyDigest) ?? false
        medicationReminders = try c.decodeIfPresent(Bool.self, forKey: .medicationReminders) ?? false
        dataPausedAlerts = try c.decodeIfPresent(Bool.self, forKey: .dataPausedAlerts) ?? false
        classOptIn = try c.decodeIfPresent([String: Bool].self, forKey: .classOptIn) ?? [:]
        quietHours = try c.decodeIfPresent(NotificationQuietHours.self, forKey: .quietHours) ?? .defaultNight
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

/// Remembered-but-not-precious navigation/session state (last tab, last-viewed metric
/// windows, last export choices). Deliberately separate from the rest of
/// `CustomizationProfile`: nothing here is a user-authored preference, so a future "reset
/// customization" flow can clear it without touching depth/units/theme/etc, and every
/// "remember the last X" fix has one seam to write into instead of inventing its own.
public struct SessionPreferences: Codable, Hashable, Sendable {
    /// Index into the root tab shell (Today/Body/Log/Insights/Settings); nil = no memory yet.
    public var lastActiveTab: Int?
    /// metricId -> last-viewed chart window, in days (e.g. MetricDetail's 7/30/90 picker).
    public var lastMetricPeriodDays: [String: Int]
    public var lastExportFormat: String?
    public var lastExportRange: String?

    public init(lastActiveTab: Int? = nil, lastMetricPeriodDays: [String: Int] = [:],
                lastExportFormat: String? = nil, lastExportRange: String? = nil) {
        self.lastActiveTab = lastActiveTab; self.lastMetricPeriodDays = lastMetricPeriodDays
        self.lastExportFormat = lastExportFormat; self.lastExportRange = lastExportRange
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
    /// EPIC-38: whether the hydration module shows on the Log tab. A pure presentation flag —
    /// hiding the module never touches the drink ledger (§16.1 "hideable without deletion"), so
    /// turning it back on restores every logged drink untouched. Defaults on; a user who never
    /// visits hydration simply leaves it on.
    public var hydrationEnabled: Bool
    /// Explicit user choice of which tab the app opens on; nil = today's default (Home/Today).
    public var defaultLandingTab: Int?
    /// Remembered-but-not-precious session/navigation state — see `SessionPreferences`.
    public var sessionPreferences: SessionPreferences

    public init(depthPolicy: DepthPolicy = .casual, homeModules: [HomeModule] = CustomizationProfile.defaultModules,
                unitOverrides: [String: String] = [:], unitProfile: UnitProfileMode = .display,
                language: AppLanguage = .en, arabicDigits: Bool = false, theme: AppTheme = .system,
                notifications: NotificationPreference = NotificationPreference(),
                sensitiveModulesEnabled: Bool = true, nutritionEnabled: Bool = true,
                hydrationEnabled: Bool = true,
                defaultLandingTab: Int? = nil,
                sessionPreferences: SessionPreferences = SessionPreferences()) {
        self.depthPolicy = depthPolicy; self.homeModules = homeModules
        self.unitOverrides = unitOverrides; self.unitProfile = unitProfile
        self.language = language; self.arabicDigits = arabicDigits; self.theme = theme
        self.notifications = notifications; self.sensitiveModulesEnabled = sensitiveModulesEnabled
        self.nutritionEnabled = nutritionEnabled
        self.hydrationEnabled = hydrationEnabled
        self.defaultLandingTab = defaultLandingTab; self.sessionPreferences = sessionPreferences
    }

    // Custom decode so a profile JSON persisted before these two fields existed still loads
    // (ProfileRepository.load() treats any decode failure as "no saved profile" and silently
    // resets the user to defaults — a missing-key decode error must never do that here).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decoding tolerance (UX-03): a profile persisted before the "balanced" tier was
        // removed may still have depthPolicy == "balanced" on disk — or, in principle, any
        // other future-and-then-removed value. Map anything DepthPolicy doesn't recognize to
        // `.casual` rather than letting the whole profile decode fail (which ProfileRepository
        // treats as "no saved profile" and silently resets every other preference too).
        depthPolicy = (try? c.decode(DepthPolicy.self, forKey: .depthPolicy)) ?? .casual
        homeModules = try c.decode([HomeModule].self, forKey: .homeModules)
        unitOverrides = try c.decode([String: String].self, forKey: .unitOverrides)
        unitProfile = try c.decode(UnitProfileMode.self, forKey: .unitProfile)
        language = try c.decode(AppLanguage.self, forKey: .language)
        arabicDigits = try c.decode(Bool.self, forKey: .arabicDigits)
        theme = try c.decode(AppTheme.self, forKey: .theme)
        notifications = try c.decode(NotificationPreference.self, forKey: .notifications)
        sensitiveModulesEnabled = try c.decode(Bool.self, forKey: .sensitiveModulesEnabled)
        nutritionEnabled = try c.decode(Bool.self, forKey: .nutritionEnabled)
        // decodeIfPresent (not decode): a profile persisted before this flag existed must still
        // load — a missing key is treated as the default (on), never a whole-profile decode
        // failure, which ProfileRepository.load() would silently reset every preference over.
        hydrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .hydrationEnabled) ?? true
        defaultLandingTab = try c.decodeIfPresent(Int.self, forKey: .defaultLandingTab)
        sessionPreferences = try c.decodeIfPresent(SessionPreferences.self, forKey: .sessionPreferences)
            ?? SessionPreferences()
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
