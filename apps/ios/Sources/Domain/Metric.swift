import Foundation

/// The shape of a metric's storage, which drives which table it lives in and how it
/// renders. Mirrors the ontology `kind` field.
public enum MetricKind: String, Codable, Hashable, Sendable, CaseIterable {
    case rawSample
    case intervalAggregate
    case session
    case event
    case derived
}

public enum ChartHint: String, Codable, Hashable, Sendable {
    case line, bar, range, stacked, scatter
}

public enum SensitiveClass: String, Codable, Hashable, Sendable {
    case normal
    case sensitivePlus   // meds, symptoms, conditions, mood, stress — separate DB file
}

/// High-level grouping used for pillars, icons, and colour families in the UI. Backed by
/// the free-form `family` string on a MetricDefinition so the registry can add families
/// without a code change; unknown families fall back to `.other`.
///
/// The `.other` fallback is a crash guard, not a shipping state. Registry v0.2.0 added seven
/// families at once (workout, readiness, effort, hydration, stress, cycle, lab) and, until they
/// were enumerated here, all 22 of their metrics collapsed into a single "Other" pillar with the
/// generic grid glyph — a third of the catalogue, indistinguishable in the Body browse surface.
/// `MetricFamilyParityTests` now fails the build's test run if the registry names a family this
/// enum doesn't, so the next registry bump can't repeat that silently.
///
/// Case order is load-bearing: `BodyScreen.orderIndex` sorts pillars by `allCases` position, so
/// this reads top-to-bottom as the Body screen does. New cases were *inserted* next to the family
/// they relate to rather than appended, which preserves the relative order of the original ten;
/// `.medications` and `.other` stay last because they are the non-registry and unknown buckets.
public enum MetricFamily: String, Codable, Hashable, Sendable, CaseIterable {
    case sleep, readiness, heart, activity, workout, effort, body, respiratory
    case nutrition, hydration, subjective, journal, stress, cycle, symptoms, lab, medications, other

    public init(rawValueOrOther raw: String) {
        self = MetricFamily(rawValue: raw) ?? .other
    }

    public var displayName: LocalizedString {
        switch self {
        case .sleep: return LocalizedString(en: "Sleep", ar: "النوم")
        case .readiness: return LocalizedString(en: "Readiness", ar: "الجاهزية")
        case .heart: return LocalizedString(en: "Heart", ar: "القلب")
        case .activity: return LocalizedString(en: "Activity", ar: "النشاط")
        case .workout: return LocalizedString(en: "Workouts", ar: "التمارين")
        case .effort: return LocalizedString(en: "Effort", ar: "الجهد")
        case .body: return LocalizedString(en: "Body", ar: "الجسم")
        case .respiratory: return LocalizedString(en: "Respiratory", ar: "التنفّس")
        case .nutrition: return LocalizedString(en: "Nutrition", ar: "التغذية")
        case .hydration: return LocalizedString(en: "Hydration", ar: "الترطيب")
        case .subjective: return LocalizedString(en: "How you feel", ar: "شعورك")
        // The journal family holds what you DID (behaviour tags) and what BADAN reads out of it —
        // deliberately distinct from `.subjective`, which is how you FELT. Its one registry row is
        // the `journal.correlation` namespace (EPIC-29).
        case .journal: return LocalizedString(en: "Journal", ar: "المفكرة")
        // "Stress" names what the family tracks, not a state the reader is in — the metric is a
        // day-level trend (`stress.day_trend`), and the copy inside the family keeps it directional.
        case .stress: return LocalizedString(en: "Stress", ar: "التوتر")
        case .cycle: return LocalizedString(en: "Cycle", ar: "الدورة الشهرية")
        case .symptoms: return LocalizedString(en: "Symptoms", ar: "الأعراض")
        case .lab: return LocalizedString(en: "Lab results", ar: "نتائج المختبر")
        case .medications: return LocalizedString(en: "Medications", ar: "الأدوية")
        case .other: return LocalizedString(en: "Other", ar: "أخرى")
        }
    }

    /// SF Symbol name for the family — kept here so both list and detail agree.
    ///
    /// Every name here must exist at the iOS 17 deployment target. A typo is not a build error:
    /// `Image(systemName:)` renders an empty frame, so the icon just silently vanishes in shipped
    /// UI. `MetricFamilyParityTests.testEveryFamilySymbolResolves` resolves all of them through
    /// `UIImage(systemName:)` for exactly that reason.
    public var symbolName: String {
        switch self {
        case .sleep: return "moon.stars.fill"
        case .readiness: return "bolt.heart.fill"
        case .heart: return "heart.fill"
        case .activity: return "figure.walk"
        case .workout: return "figure.run"
        case .effort: return "flame.fill"
        case .body: return "figure.stand"
        case .respiratory: return "lungs.fill"
        case .nutrition: return "fork.knife"
        case .hydration: return "drop.fill"
        case .subjective: return "face.smiling"
        case .journal: return "note.text"
        case .stress: return "brain.head.profile"
        case .cycle: return "calendar"
        case .symptoms: return "bandage.fill"
        case .lab: return "testtube.2"
        case .medications: return "pills.fill"
        case .other: return "square.grid.2x2"
        }
    }
}

/// Compiled from `packages/metric-ontology/registry.json`. Apps never hardcode metric-id
/// strings outside `MetricID` constants; this is the single description of every metric.
public struct MetricDefinition: Codable, Hashable, Sendable, Identifiable {
    public var metricId: String
    public var family: String
    public var kind: MetricKind
    public var canonicalUnit: String
    public var displayUnits: [String]
    public var nameEn: String
    public var nameAr: String
    public var casualLabel: String
    public var preciseLabel: String
    public var chartHint: ChartHint
    public var baselineEligible: Bool
    public var sensitiveClass: SensitiveClass
    public var explainerEn: String?

    public var id: String { metricId }

    public var familyGroup: MetricFamily { MetricFamily(rawValueOrOther: family) }

    public var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }

    /// The user-facing label at a given depth: casual shows the friendly label, power
    /// shows the precise term. Both localise to Arabic via `displayName` fallback.
    public func label(depth: DepthPolicy, language: AppLanguage) -> String {
        switch (depth, language) {
        case (.power, _): return language == .ar ? nameAr : preciseLabel
        case (_, .ar): return nameAr
        default: return casualLabel
        }
    }

    /// The default display unit for this metric (first of `displayUnits`, else canonical).
    public var primaryDisplayUnit: String { displayUnits.first ?? canonicalUnit }

    // Decoding tolerance: unknown chartHint -> .line, unknown kind -> .rawSample.
    private enum CodingKeys: String, CodingKey {
        case metricId, family, kind, canonicalUnit, displayUnits
        case nameEn, nameAr, casualLabel, preciseLabel, chartHint
        case baselineEligible, sensitiveClass, explainerEn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metricId = try c.decode(String.self, forKey: .metricId)
        family = try c.decode(String.self, forKey: .family)
        kind = (try? c.decode(MetricKind.self, forKey: .kind)) ?? .rawSample
        canonicalUnit = try c.decode(String.self, forKey: .canonicalUnit)
        displayUnits = (try? c.decode([String].self, forKey: .displayUnits)) ?? []
        nameEn = try c.decode(String.self, forKey: .nameEn)
        nameAr = try c.decode(String.self, forKey: .nameAr)
        casualLabel = (try? c.decode(String.self, forKey: .casualLabel)) ?? nameEn
        preciseLabel = (try? c.decode(String.self, forKey: .preciseLabel)) ?? nameEn
        chartHint = (try? c.decode(ChartHint.self, forKey: .chartHint)) ?? .line
        baselineEligible = (try? c.decode(Bool.self, forKey: .baselineEligible)) ?? false
        sensitiveClass = (try? c.decode(SensitiveClass.self, forKey: .sensitiveClass)) ?? .normal
        explainerEn = try? c.decode(String.self, forKey: .explainerEn)
    }

    public init(
        metricId: String, family: String, kind: MetricKind, canonicalUnit: String,
        displayUnits: [String], nameEn: String, nameAr: String, casualLabel: String,
        preciseLabel: String, chartHint: ChartHint, baselineEligible: Bool,
        sensitiveClass: SensitiveClass, explainerEn: String? = nil
    ) {
        self.metricId = metricId; self.family = family; self.kind = kind
        self.canonicalUnit = canonicalUnit; self.displayUnits = displayUnits
        self.nameEn = nameEn; self.nameAr = nameAr; self.casualLabel = casualLabel
        self.preciseLabel = preciseLabel; self.chartHint = chartHint
        self.baselineEligible = baselineEligible; self.sensitiveClass = sensitiveClass
        self.explainerEn = explainerEn
    }
}
