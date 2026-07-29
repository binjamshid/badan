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

/// A18 / ADR-0010 / D-25 (EPIC-40, pregnancy module P0 slice). The user-declared pregnancy-module
/// gate — default `.off` (the SAME value both "the user has never chosen anything" and "the user
/// explicitly turned the module off" resolve to). Mirrors `FertileWindowMode`'s EXACT pattern per
/// this module's own non-negotiable requirement: an ENUM, not a `Bool`, so the tolerant-decode path
/// below can fold both "key missing" and "key present but unrecognized" into the same safe default
/// via `try?`, the identical reasoning `CustomizationProfile.init(from:)` already documents for
/// `fertileWindowMode`. This is a HARD requirement, not a convenience default: nothing about
/// pregnancy state may ever be inferred from cycle data, missed periods, symptoms, or anything else
/// — `PregnancyConsentScreen` is the ONLY place this is ever set, mirroring `CycleConsentScreen`'s
/// exact "one dedicated consent screen, no other write path" enforcement for `cycleModuleEnabled`.
public enum PregnancyModuleMode: String, Codable, Hashable, Sendable, CaseIterable {
    case off, on

    public var displayName: LocalizedString {
        switch self {
        case .off: return LocalizedString(en: "Off", ar: "إيقاف")
        case .on: return LocalizedString(en: "On", ar: "تفعيل")
        }
    }
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
    /// storage code (`readiness`, `windDown`, `deviation`, `exportHealth`, `hydration`,
    /// `pregnancy`) — i.e. every case of that enum except `meds`. A missing key means OFF — every
    /// class is opt-in and ships OFF (the existing convention), so an empty map is "nothing
    /// enabled". `meds` is deliberately NOT keyed here: it keeps using `medicationReminders` above
    /// so the existing med-reminder wiring and tests are untouched.
    public var classOptIn: [String: Bool]
    /// EPIC-32 quiet-hours window honoured by every non-med decision class. Modeled as one window
    /// (what a user means by "don't notify me at night"); the engine takes it PER class, so a future
    /// per-class override slots in without a schema change.
    public var quietHours: NotificationQuietHours
    /// How many NON-medication notifications BADAN may send in a local day, across all non-med
    /// classes combined. Medication reminders are exempt and are never counted here.
    ///
    /// This used to be the fixed constant `NotificationBudget.dailyNonMedLimit = 2`, documented in
    /// several places as "a hard invariant, not a preference". It is now a preference, clamped to
    /// `dailyNonMedLimitRange`, because a fixed 2 is not actually anti-fatigue once more than two
    /// classes exist: with the morning and evening anchors both on, every other class the user
    /// explicitly opted into was starved permanently and silently. The anti-fatigue guarantee is
    /// preserved by the CLAMP (the user cannot raise it without limit) and by the engine's
    /// deterministic priority order, not by the number being immovable.
    ///
    /// The `didSet` clamps LATER assignments too, not just construction and decode. Callers reach
    /// this through `AppEnvironment.update { $0.notifications.dailyNonMedLimit = n }`, which writes
    /// the property directly and would otherwise bypass every clamp the initialisers apply — so
    /// without this the range would hold only on the paths that happen to go through an init.
    public var dailyNonMedLimit: Int {
        didSet { dailyNonMedLimit = Self.clampDailyNonMedLimit(dailyNonMedLimit) }
    }
    /// Whether a delivered notification may name a reading on the lock screen.
    ///
    /// Ships OFF and is only ever turned on by an explicit choice (offered once during onboarding,
    /// changeable in Settings afterwards). Every notification body in this app was written to carry
    /// no health value at all — legible on a locked screen to anyone holding the phone — and that
    /// stays the default. Skipping the onboarding step leaves it off, so silence on the question is
    /// read as "no", never as consent.
    public var showValuesInNotifications: Bool

    // STUB-12: `morningNarrative`/`weeklyDigest`/`dataPausedAlerts` used to default `true` —
    // pre-consenting every user to notification categories that have no delivery mechanism at
    // all (`SettingsScreen` hides their toggles for exactly this reason — see NEW-02/UX-02).
    // All four now default `false`; only an explicit, working toggle should ever flip one on.
    public init(morningNarrative: Bool = false, weeklyDigest: Bool = false,
                medicationReminders: Bool = false, dataPausedAlerts: Bool = false,
                classOptIn: [String: Bool] = [:], quietHours: NotificationQuietHours = .defaultNight,
                dailyNonMedLimit: Int = NotificationPreference.defaultDailyNonMedLimit,
                showValuesInNotifications: Bool = false) {
        self.morningNarrative = morningNarrative; self.weeklyDigest = weeklyDigest
        self.medicationReminders = medicationReminders; self.dataPausedAlerts = dataPausedAlerts
        self.classOptIn = classOptIn; self.quietHours = quietHours
        self.dailyNonMedLimit = Self.clampDailyNonMedLimit(dailyNonMedLimit)
        self.showValuesInNotifications = showValuesInNotifications
    }

    /// The range the daily ceiling may take. 1 so a user who wants exactly one notice a day can have
    /// that; 4 so no amount of enthusiasm turns BADAN into a stream. The clamp — not a fixed number —
    /// is what carries the anti-fatigue promise now.
    public static let dailyNonMedLimitRange = 1...4

    /// The shipped default. Three, not the historical two: with the morning summary and the evening
    /// wind-down both enabled, a ceiling of 2 leaves every other class permanently starved, so 2 was
    /// silently a two-class product.
    public static let defaultDailyNonMedLimit = 3

    /// Force a limit into `dailyNonMedLimitRange`. Applied on BOTH construction and decode: a
    /// persisted profile is not a trusted input (an older build, a hand-edited export, a future
    /// build's wider range read by an older one), and a 0 or a 99 arriving from storage would break
    /// the ceiling exactly where nobody is looking.
    public static func clampDailyNonMedLimit(_ value: Int) -> Int {
        min(max(value, dailyNonMedLimitRange.lowerBound), dailyNonMedLimitRange.upperBound)
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
        // Clamped here too, not just in the memberwise init — see `clampDailyNonMedLimit`. Note
        // this decode is hand-written precisely so a field added later (like this one) reads as its
        // default on an older profile instead of failing the whole `CustomizationProfile`; a new
        // field added ONLY to the memberwise init above would decode as garbage and the compiler
        // would not say a word.
        dailyNonMedLimit = Self.clampDailyNonMedLimit(
            try c.decodeIfPresent(Int.self, forKey: .dailyNonMedLimit) ?? Self.defaultDailyNonMedLimit)
        // Defaults to false on any profile that predates the setting: a privacy choice the user has
        // not made yet must decode as "not made", never as granted.
        showValuesInNotifications =
            try c.decodeIfPresent(Bool.self, forKey: .showValuesInNotifications) ?? false
    }
}

/// The evening wind-down's schedule, mirroring `HydrationReminderSettings`: a plain, user-authored,
/// `Codable` value with a clamping init and a `legacyDefault` that reproduces the behaviour an
/// existing install already has. `BedtimeReminderPolicy` turns it into a fire time.
public struct BedtimeReminderSettings: Codable, Hashable, Sendable {
    /// Local minutes-from-midnight the user wants to WAKE, or `nil` if they have not said.
    ///
    /// `nil` is the important state and the default. Without a target wake time there is nothing to
    /// subtract a sleep need from, so the policy falls back to the user's habitual bedtime and then
    /// to the fixed hour — rather than deriving a bedtime from an assumed wake time, which would be
    /// the app inventing a personal number and presenting it as observed.
    public var targetWakeMinute: Int?
    /// How long before the derived bedtime the wind-down fires. This is the "wind-down" part: the
    /// nudge is a lead-in to bed, not an alarm at the moment of it.
    public var leadMinutes: Int
    /// "Pause tonight", the same escape hatch hydration reminders have.
    public var pausedUntil: Date?

    public init(targetWakeMinute: Int? = nil, leadMinutes: Int = 30, pausedUntil: Date? = nil) {
        self.targetWakeMinute = targetWakeMinute.map { Self.clampMinuteOfDay($0) }
        self.leadMinutes = Self.clampLead(leadMinutes)
        self.pausedUntil = pausedUntil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetWakeMinute = (try c.decodeIfPresent(Int.self, forKey: .targetWakeMinute))
            .map { Self.clampMinuteOfDay($0) }
        leadMinutes = Self.clampLead(try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 30)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
    }

    /// No target wake time ⇒ the policy's fixed-hour tier ⇒ the 21:00 the app has always used.
    public static let legacyDefault = BedtimeReminderSettings()

    /// Lead is clamped rather than trusted: a negative lead would put the "wind-down" after bedtime,
    /// and an unbounded one would drift it into the afternoon.
    public static let leadMinutesRange = 0...180

    static func clampMinuteOfDay(_ value: Int) -> Int {
        let day = 24 * 60
        return ((value % day) + day) % day
    }

    static func clampLead(_ value: Int) -> Int {
        min(max(value, leadMinutesRange.lowerBound), leadMinutesRange.upperBound)
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
    /// EPIC-33 (Phase 3D). Per-widget opt-in consent key `consent.widget.medsDue`. Medications are
    /// sensitive-plus, so the meds-due Home Screen / Lock Screen widget needs its own explicit
    /// grant — separate from `sensitiveModulesEnabled` itself, and defaulting OFF even when that
    /// one is on. Read by `AmbientSnapshotWriter`, which writes `medsDue` into the shared ambient
    /// snapshot ONLY when this is `true`; the widget extension never sees a medication name
    /// otherwise (see `AmbientSnapshotDto.medsDue`'s doc).
    public var consentWidgetMedsDue: Bool
    /// EPIC-39 (Phase 3F slice 2). Master enable/disable for the cycle-tracking module — default
    /// `false` (opt-in): the module stays off until the user explicitly turns it on from
    /// `CycleConsentScreen`. Deliberately distinct from `sensitiveModulesEnabled` (which gates
    /// Journal/Symptom/Medication as one bundle): the cycle module's own LogHub tile stays
    /// UNCONDITIONALLY visible even while this is `false` (unlike those three), because otherwise
    /// there would be no way for a user to ever discover and enable it in the first place — see
    /// `LogHubScreen`'s own tile routing.
    public var cycleModuleEnabled: Bool
    /// EPIC-39 (Phase 3F slice 2). CYCLE-08's "pause" control: keeps period/flow logging and
    /// history fully working, but is the gate `CycleModuleServices.refreshAll` checks before
    /// running the phase-conditioned baseline recompute on top of the always-appended
    /// prediction/phase-estimate rows. Default `false` (predictions/phase-conditioned baselines run
    /// normally once the module itself is on).
    public var cyclePredictionsPaused: Bool
    /// A17 / ADR-0010 / D-24 (EPIC-39 CYCLE-12). The user-declared fertile-window estimation mode —
    /// default `.suppressed` (the SAME value both "the user has never chosen anything" and "the user
    /// explicitly chose to hide fertile-window estimates" resolve to; see `FertileWindowMode`'s own
    /// doc for why one case correctly covers both). This is a HARD requirement, not just a
    /// convenience default: fertile-window estimation must never be inferred passively, must never
    /// be on by default, and must never be shown just because `cycleModuleEnabled` is on —
    /// `CycleModuleServices.refreshAll` reads this LIVE and never even calls
    /// `CycleFertileWindowEngine` while it is `.suppressed`, mirroring `cyclePredictionsPaused`'s own
    /// "read by the composition layer, never written by an engine" separation immediately above.
    public var fertileWindowMode: FertileWindowMode
    /// A9 / ADR-0010 / D-22. Master enable/disable for the AI coach — default `false` (opt-in):
    /// off until the user explicitly turns it on from `AICoachConsentScreen`, which is also the
    /// ONLY place a query ever leaves the device (D-22: "No query leaves the device until the
    /// user explicitly enables the AI coach feature through its own consent screen"). This flag
    /// alone is not the whole gate — `AICoachClient.isEnabled` additionally requires a Keychain
    /// device token to exist (issued by `enableModule()` alongside setting this), so a device
    /// that somehow has this `true` with no token (e.g. a restored backup — the token itself
    /// never leaves this device, see `KeychainAICoachDeviceTokenStore`) still can't send a
    /// request; see `AICoachChatScreen`'s own two-gate reasoning, mirroring
    /// `RouteConsentStore`'s "BADAN's toggle AND the underlying grant" pattern.
    public var aiCoachEnabled: Bool
    /// A18 / ADR-0010 / D-25 (EPIC-40, pregnancy module P0 slice). Default `.off` — see
    /// `PregnancyModuleMode`'s own doc for why this is an enum, not a bool, and why it is a hard
    /// requirement rather than a convenience default. `PregnancyModuleServices`/
    /// `PregnancyModeController` only ever READ this; `PregnancyConsentScreen` is the one place it
    /// is ever written.
    public var pregnancyModuleMode: PregnancyModuleMode
    /// HYD-004 / HYD-012 (EPIC-38 phase 2). The user's hydration reminder schedule and fasting
    /// windows. Before this existed, hydration's reminder was one hardcoded 15:00 fire — a time
    /// that falls inside the fast on essentially every day of Ramadan, which the hydration research
    /// lists among its explicit anti-goals ("notifications during an enabled fasting window").
    /// Whether reminders fire at all is still governed by `notifications.classOptIn["hydration"]`,
    /// unchanged; this only decides WHEN, and when to stay silent.
    public var hydrationReminders: HydrationReminderSettings
    /// The evening wind-down's schedule. Whether it fires at all is still governed by
    /// `notifications.classOptIn["windDown"]`, unchanged; this only decides WHEN. Defaults to a
    /// settings object with no target wake time, which `BedtimeReminderPolicy` resolves to the same
    /// fixed 21:00 the app has always used — so nobody's existing reminder moves under them.
    public var bedtimeReminders: BedtimeReminderSettings
    /// W-11 (EPIC-44 wave 1). How much personal content may reach Home Screen widgets, StandBy, the
    /// Lock Screen, and the watch glance. Defaults to `.standard` — the behaviour every existing
    /// install already has; this setting adds ways to show LESS, never more.
    public var ambientPrivacy: AmbientPrivacyConfig
    /// D-35 (development priority #2). The metrics the user has pinned to Home, in the order they
    /// chose — **array position IS display order**, which is why this is an array and not a `Set`.
    /// Capped at `maxPinnedMetrics` so Home stays a summary and the pinned fetch stays bounded.
    ///
    /// This deliberately replaces the never-used `metric_pins` table rather than reviving it: that
    /// table could only express `pinned_at` insertion order, and reorder is the first thing anyone
    /// asks for. Living on the profile also means a pin change rides the existing
    /// `AppEnvironment.update` path — optimistic UI, rollback on save failure, and a reload for
    /// free because `env.profile` is already folded into every screen's `.task(id:)` load key.
    public var pinnedMetricIds: [String] {
        didSet { pinnedMetricIds = Self.clampPins(pinnedMetricIds) }
    }
    /// D-35. Metrics the user has hidden from browsing surfaces.
    ///
    /// D-36. Whether feedback-learned calibration is applied to future derived values.
    ///
    /// Ships ON, unlike every consent flag in this file, and the difference is deliberate: this
    /// grants nothing and sends nothing. It is a purely on-device adjustment that only ever exists
    /// because the user actively tapped "doesn't match" ten or more times — silence produces no
    /// calibration at all, because the event floor is never reached. Switching it off stops future
    /// adjustment; rows already computed keep theirs (I2) and keep disclosing it.
    public var calibrationEnabled: Bool
    /// D-35. The user's chosen calculation method per derived metric — `metricId -> algorithmId`.
    ///
    /// Empty means "use the contract default", which is what every existing install has and what
    /// anyone who never opens the picker keeps. A stored id that no longer exists (the app updated
    /// and an entry was withdrawn) resolves back to the default AND says so on the surface — see
    /// `MethodResolver`. It is never silently honoured, never a crash, and never "compute nothing".
    public var methodChoices: [String: String]
    /// **Presentation only, and this is an invariant with a test behind it
    /// (`testHidingAMetricDoesNotStopItBeingIngestedOrDerived`).** A hidden metric is still
    /// ingested, still derived, still exportable, still searchable by name, and still deletable.
    /// Conflating "hidden" with "not collected" would destroy history HealthKit will not backfill
    /// later — the user would be silently choosing data loss by tidying a list.
    public var hiddenMetricIds: [String]

    public init(depthPolicy: DepthPolicy = .casual, homeModules: [HomeModule] = CustomizationProfile.defaultModules,
                unitOverrides: [String: String] = [:], unitProfile: UnitProfileMode = .display,
                language: AppLanguage = .en, arabicDigits: Bool = false, theme: AppTheme = .system,
                notifications: NotificationPreference = NotificationPreference(),
                sensitiveModulesEnabled: Bool = true, nutritionEnabled: Bool = true,
                hydrationEnabled: Bool = true,
                defaultLandingTab: Int? = nil,
                sessionPreferences: SessionPreferences = SessionPreferences(),
                consentWidgetMedsDue: Bool = false,
                cycleModuleEnabled: Bool = false,
                cyclePredictionsPaused: Bool = false,
                fertileWindowMode: FertileWindowMode = .suppressed,
                aiCoachEnabled: Bool = false,
                pregnancyModuleMode: PregnancyModuleMode = .off,
                hydrationReminders: HydrationReminderSettings = .legacyDefault,
                bedtimeReminders: BedtimeReminderSettings = .legacyDefault,
                ambientPrivacy: AmbientPrivacyConfig = .default,
                pinnedMetricIds: [String] = [],
                hiddenMetricIds: [String] = [],
                methodChoices: [String: String] = [:],
                calibrationEnabled: Bool = true) {
        self.depthPolicy = depthPolicy; self.homeModules = homeModules
        self.unitOverrides = unitOverrides; self.unitProfile = unitProfile
        self.language = language; self.arabicDigits = arabicDigits; self.theme = theme
        self.notifications = notifications; self.sensitiveModulesEnabled = sensitiveModulesEnabled
        self.nutritionEnabled = nutritionEnabled
        self.hydrationEnabled = hydrationEnabled
        self.defaultLandingTab = defaultLandingTab; self.sessionPreferences = sessionPreferences
        self.consentWidgetMedsDue = consentWidgetMedsDue
        self.cycleModuleEnabled = cycleModuleEnabled
        self.cyclePredictionsPaused = cyclePredictionsPaused
        self.fertileWindowMode = fertileWindowMode
        self.aiCoachEnabled = aiCoachEnabled
        self.pregnancyModuleMode = pregnancyModuleMode
        self.hydrationReminders = hydrationReminders
        self.bedtimeReminders = bedtimeReminders
        self.ambientPrivacy = ambientPrivacy
        self.pinnedMetricIds = Self.clampPins(pinnedMetricIds)
        self.hiddenMetricIds = hiddenMetricIds
        self.methodChoices = methodChoices
        self.calibrationEnabled = calibrationEnabled
    }

    /// The pin ceiling. Eight so Home stays a summary rather than becoming a second Body tab, and
    /// so the pinned fetch — which issues per-metric reads — stays bounded.
    public static let maxPinnedMetrics = 8

    /// De-duplicates (array position is order, so a repeat would render twice) and truncates.
    /// Applied in both initialisers AND on assignment, mirroring `dailyNonMedLimit`'s `didSet`
    /// reasoning: callers reach this through `AppEnvironment.update { $0.pinnedMetricIds = … }`,
    /// which writes the property directly and would otherwise bypass a clamp applied only in init.
    static func clampPins(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.prefix(maxPinnedMetrics).map { $0 }
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
        // D-35: union in any module this build knows about that the stored profile predates.
        //
        // Without this the fix is cosmetic for everyone who already has BADAN installed: Settings
        // renders one toggle per entry in `homeModules`, so a module added to `defaultModules` is
        // invisible — and unhideable — for every profile written before it existed. That is exactly
        // how `"effort"` came to be permanently on. Appending is additive only: an existing entry's
        // `visible` and `order` are never touched, and new modules land after everything the user
        // already has, so nobody's layout moves.
        homeModules = Self.mergingMissingDefaults(into: try c.decode([HomeModule].self, forKey: .homeModules))
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
        // decodeIfPresent (not decode): a profile persisted before this consent key existed must
        // still load, defaulting OFF — the same tolerant-decode reasoning as `hydrationEnabled`
        // above, and load-bearing here specifically because the safe default for a brand-new
        // sensitive-plus consent key is "not granted," never "on because the field was missing."
        consentWidgetMedsDue = try c.decodeIfPresent(Bool.self, forKey: .consentWidgetMedsDue) ?? false
        // decodeIfPresent (not decode): a profile persisted before these two cycle-module keys
        // existed must still load — a missing key defaults to the safe, opt-in-off state (both
        // `false`), never a whole-profile decode failure, which `ProfileRepository.load()` would
        // silently reset every other preference over.
        cycleModuleEnabled = try c.decodeIfPresent(Bool.self, forKey: .cycleModuleEnabled) ?? false
        cyclePredictionsPaused = try c.decodeIfPresent(Bool.self, forKey: .cyclePredictionsPaused) ?? false
        // `try?` (mirroring `depthPolicy`'s own tolerant-unknown-value decode above in this
        // initializer, not the plain `decodeIfPresent ?? default` shape the other cycle flags use):
        // this single call folds BOTH "key missing entirely" (a profile persisted before this
        // A17/CYCLE-12 field existed) AND "key present but an unrecognized raw value" (a future mode
        // this build doesn't know) into the same safe default, `.suppressed` — the one value this
        // field must ALWAYS default to. A decode failure or a missing key silently producing
        // `.calendar`/`.signalAssisted` would be exactly the "on by default" outcome this feature's
        // own hard requirement forbids; a whole-profile decode failure (which `ProfileRepository
        // .load()` treats as "no saved profile" and resets every other preference too) is avoided
        // the same way every other tolerant field in this initializer avoids it.
        fertileWindowMode = (try? c.decode(FertileWindowMode.self, forKey: .fertileWindowMode)) ?? .suppressed
        // decodeIfPresent (not decode): a profile persisted before this flag existed must still
        // load — a missing key defaults to the safe, opt-in-off state, never a whole-profile
        // decode failure (which `ProfileRepository.load()` would silently reset every other
        // preference over), and never `true` — the one value a missing/corrupt key must never
        // produce for a network-consent flag (A9/D-22).
        aiCoachEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiCoachEnabled) ?? false
        // `try?` (mirroring `fertileWindowMode`'s own tolerant-unknown-value decode immediately
        // above, not the plain `decodeIfPresent ?? default` shape most other flags in this
        // initializer use): folds BOTH "key missing entirely" (a profile persisted before this
        // A18/EPIC-40 field existed) AND "key present but an unrecognized raw value" into the same
        // safe default, `.off` — the one value this field must ALWAYS default to. A decode failure
        // or a missing key silently producing `.on` would be exactly the "on by default" outcome
        // this module's own hard requirement forbids; a whole-profile decode failure (which
        // `ProfileRepository.load()` treats as "no saved profile" and resets every other preference
        // too) is avoided the same way every other tolerant field in this initializer avoids it.
        pregnancyModuleMode = (try? c.decode(PregnancyModuleMode.self, forKey: .pregnancyModuleMode)) ?? .off
        // `decodeIfPresent ?? .legacyDefault`, and the default here is deliberately NOT the empty
        // schedule the other opt-in fields use. A profile persisted before this key existed belongs
        // to someone whose hydration reminder, if they opted the class in at all, WAS the hardcoded
        // 15:00 fire. Defaulting to an empty schedule would silently turn that reminder off in an
        // update — a preference the user chose, removed by a migration they never asked for. The
        // opt-in gate itself is unchanged and still lives in `notifications.classOptIn`, so this
        // default grants nothing to a user who never turned hydration reminders on.
        hydrationReminders = try c.decodeIfPresent(HydrationReminderSettings.self, forKey: .hydrationReminders)
            ?? .legacyDefault
        // Same reasoning, one step simpler: `.legacyDefault` here carries no target wake time, and a
        // profile without one keeps the fixed 21:00 it already had. Adding the key cannot move an
        // existing user's wind-down; only their own choice of a wake time can.
        bedtimeReminders = try c.decodeIfPresent(BedtimeReminderSettings.self, forKey: .bedtimeReminders)
            ?? .legacyDefault
        // `try?` rather than `decodeIfPresent`, so an unrecognized future mode falls back to
        // `.standard` instead of failing the whole profile decode. Permissive is the correct
        // default here for the reason the DTO's own decode gives: this setting changes how already-
        // visible content renders, it does not gate content that was previously ungated.
        ambientPrivacy = (try? c.decode(AmbientPrivacyConfig.self, forKey: .ambientPrivacy)) ?? .default
        // D-35. Both default empty: no pins and nothing hidden is exactly the behaviour every
        // existing install already has, so adding these keys moves nobody's screen. `decodeIfPresent`
        // rather than `decode` for the reason this whole initializer exists — every profile on disk
        // today predates both keys, and a missing-key throw here would send `ProfileRepository.load()`
        // down its "stored row present but failed to decode" path and reset every other preference.
        pinnedMetricIds = Self.clampPins(try c.decodeIfPresent([String].self, forKey: .pinnedMetricIds) ?? [])
        hiddenMetricIds = try c.decodeIfPresent([String].self, forKey: .hiddenMetricIds) ?? []
        // D-35. Empty means "contract default for everything", which is exactly the behaviour of
        // every profile written before methods were selectable.
        methodChoices = try c.decodeIfPresent([String: String].self, forKey: .methodChoices) ?? [:]
        // D-36. Defaults TRUE when the key is absent, which is the opposite of this file's usual
        // rule and correct here for the reason `calibrationEnabled`'s own doc gives: it authorises
        // no disclosure and no transmission, and it cannot do anything at all until the user has
        // supplied feedback themselves.
        calibrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .calibrationEnabled) ?? true
    }

    /// Every module id Home can render, in default order.
    ///
    /// Two entries were added by D-35 and are worth naming, because
    /// `testEveryGatedHomeModuleIdExistsInDefaultModules` now enforces the relationship:
    ///
    /// - `"pinned"` (D-35) is new. Existing profiles have no entry for it, so
    ///   `isHomeModuleVisible`'s `?? true` fallback resolves it visible — the established way this
    ///   app adds a Home surface without moving anyone's layout.
    /// - `"effort"` was **already gated by `HomeScreen` and missing here**, so it always hit that
    ///   same fallback and could never be switched off, because Settings only ever renders toggles
    ///   for modules the profile actually lists. Adding it changes no default (still visible) and
    ///   simply makes the existing switch reachable. It needs a `homeModuleLabel` case too, or the
    ///   Arabic UI shows the capitalized raw id.
    ///
    /// `"nutrition"` is the deliberate exception in the other direction: listed here, never gated by
    /// Home, because it has no Home surface — see `isHomeModuleVisible`'s own note.
    public static let defaultModules: [HomeModule] = [
        HomeModule(id: "pinned", visible: true, order: 0),
        HomeModule(id: "readiness", visible: true, order: 1),
        HomeModule(id: "effort", visible: true, order: 2),
        HomeModule(id: "sleep", visible: true, order: 3),
        HomeModule(id: "activity", visible: true, order: 4),
        HomeModule(id: "heart", visible: true, order: 5),
        HomeModule(id: "meds", visible: true, order: 6),
        HomeModule(id: "nutrition", visible: true, order: 7),
        HomeModule(id: "timeline", visible: true, order: 8),
    ]

    /// Appends any `defaultModules` entry the stored list has no id for, preserving the stored
    /// entries exactly (visibility AND order) and ordering newcomers after them. New modules
    /// therefore arrive visible-by-default, matching `isHomeModuleVisible`'s `?? true` fallback —
    /// an upgrade adds a toggle, never flips one the user already set.
    static func mergingMissingDefaults(into stored: [HomeModule]) -> [HomeModule] {
        let known = Set(stored.map(\.id))
        let missing = defaultModules.filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return stored }
        var next = (stored.map(\.order).max() ?? -1) + 1
        return stored + missing.map { module in
            defer { next += 1 }
            return HomeModule(id: module.id, visible: module.visible, order: next)
        }
    }

    /// Module ids that legitimately appear in `defaultModules` with no `HomeScreen` gate, so the
    /// parity test can be asymmetric rather than failing on a decision made on purpose.
    /// `"nutrition"` governs Settings copy only; it has no Home card to hide.
    public static let homeModulesWithoutHomeSurface: Set<String> = ["nutrition"]

    public func module(_ id: String) -> HomeModule? { homeModules.first { $0.id == id } }

    // MARK: - Metric visibility (D-35)

    /// Whether a metric is hidden from *browsing* surfaces. Never consult this to decide whether to
    /// ingest, derive, export, search or delete — see `hiddenMetricIds`' own doc.
    public func isMetricHidden(_ metricId: String) -> Bool { hiddenMetricIds.contains(metricId) }

    public func isMetricPinned(_ metricId: String) -> Bool { pinnedMetricIds.contains(metricId) }

    /// Whether another pin would fit. The UI disables the control rather than silently dropping the
    /// tap, so the ceiling is visible before it bites.
    public var canPinMore: Bool { pinnedMetricIds.count < Self.maxPinnedMetrics }

    /// Pin a metric, **un-hiding it as a side effect.** Pinned-and-hidden is contradictory — the
    /// pinned card is a browsing surface — and resolving it toward "visible" is the reading that
    /// cannot strand a metric the user just asked to see. No-op at the cap.
    public mutating func pinMetric(_ metricId: String) {
        hiddenMetricIds.removeAll { $0 == metricId }
        guard !pinnedMetricIds.contains(metricId), canPinMore else { return }
        pinnedMetricIds.append(metricId)
    }

    public mutating func unpinMetric(_ metricId: String) {
        pinnedMetricIds.removeAll { $0 == metricId }
    }

    /// Hide a metric, **un-pinning it as a side effect** — the same contradiction as above, resolved
    /// the same way: the user's most recent instruction wins.
    public mutating func hideMetric(_ metricId: String) {
        unpinMetric(metricId)
        guard !hiddenMetricIds.contains(metricId) else { return }
        hiddenMetricIds.append(metricId)
    }

    public mutating func unhideMetric(_ metricId: String) {
        hiddenMetricIds.removeAll { $0 == metricId }
    }
    public var visibleModulesOrdered: [HomeModule] {
        homeModules.filter { $0.visible }.sorted { $0.order < $1.order }
    }
}
