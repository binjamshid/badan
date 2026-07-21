import Foundation
import SwiftUI
import os

/// The compiled sensor-quality contract (`packages/contracts/sensor_quality.json`), loaded
/// exactly like `MetricRegistry`/`InsightTemplateStore` so both platforms label the same source
/// the same way (plan §15, §4 principle 9).
///
/// **This is an honesty surface, not a ranking.** The contract's own note is emphatic and worth
/// repeating where the code lives: a `low` label NEVER suppresses, hides, downweights or
/// paywalls a reading. Raw data is not paywalled, and which of two duplicate rows survives is
/// decided by source priority + the dedup journal (I3, I4), not by this file. `low` on a wrist
/// blood-pressure reading is a statement about optical wrist sensors, never about the person —
/// `SensorQualityLevel.explainer` is worded that way on purpose.
final class SensorQualityMap {
    static let shared = SensorQualityMap()

    private static let logger = Logger(subsystem: "net.albayyan.badan", category: "Ontology")

    let version: String
    let defaultQuality: SensorQualityLevel
    private let classes: [String: SensorSourceClass]
    /// Declaration order, which is the order the Sources screen lists classes in.
    let orderedClasses: [SensorSourceClass]
    private let sourceTypeDefaults: [String: String]

    // MARK: - Decoding
    //
    // `familyNotes` is decoded ONLY to be dropped. The contract carries those notes in English
    // only, and every user-facing string in this app needs a real Arabic counterpart — rendering
    // an English-only sentence to an Arabic reader is the failure mode the en+ar rule exists to
    // prevent, and machine-translating a nuanced sensor caveat in the view layer would be worse.
    // The bilingual copy BADAN actually shows is authored in `SensorQualityLevel.explainer`
    // below. When the contract gains `familyNotesAr`, surface the notes here and delete this
    // paragraph — do not surface them before then.
    private struct File: Decodable {
        let version: String
        let defaultQuality: String
        let sourceTypeDefaults: [String: String]
        let sourceClasses: [SensorSourceClass]
    }

    init(file: Data? = nil) {
        let loaded: File?
        if let file {
            loaded = try? JSONDecoder().decode(File.self, from: file)
        } else {
            loaded = BundleJSON.load(File.self, "sensor_quality")
        }
        self.version = loaded?.version ?? "0"
        self.defaultQuality = SensorQualityLevel(rawValue: loaded?.defaultQuality ?? "") ?? .medium
        let all = loaded?.sourceClasses ?? []
        self.orderedClasses = all
        self.classes = Dictionary(all.map { ($0.sourceClassId, $0) }, uniquingKeysWith: { a, _ in a })
        self.sourceTypeDefaults = loaded?.sourceTypeDefaults ?? [:]

        if all.isEmpty {
            // Same reasoning as `MetricRegistry.minimumHealthyMetricCount`: `assertionFailure` is
            // a no-op in Release, so a broken `scripts/sync_ios_resources.sh` mirror would ship a
            // silently empty map and every source would render "we're not sure" forever.
            Self.logger.fault("SensorQualityMap loaded no source classes — bundled sensor_quality.json may be missing or corrupted")
        }
    }

    func sourceClass(id: String) -> SensorSourceClass? { classes[id] }

    /// Resolve a (source class, metric family) pair to a level, following the contract's stated
    /// resolution order: the class's own entry, else `defaultQuality`. An unlabelled family
    /// degrades toward caution rather than optimism — never to `.high`.
    func level(sourceClassId: String, family: MetricFamily) -> SensorQualityLevel {
        guard let sourceClass = classes[sourceClassId] else { return defaultQuality }
        return sourceClass.quality[family.sensorQualityKey] ?? defaultQuality
    }

    /// Which class a real, discovered source belongs to.
    ///
    /// The contract deliberately holds no model-string matchers ("it would become a stale
    /// allowlist that silently mislabels a device it has not heard of"), so the matching lives
    /// here in code, as the contract instructs. Deliberately conservative: anything unrecognized
    /// falls through to the source type's default (`unknown` for a platform store), which resolves
    /// to `medium` everywhere — an honest "we can't tell you more about this sensor" rather than
    /// a guess dressed as a fact.
    ///
    /// Arabic device-name keywords sit alongside the English ones for the same reason
    /// `SourcesScreen.deviceIcon` carries them: a device named "ساعة أبل" matches no English
    /// substring, and mislabelling it `unknown` would quietly downgrade a watch's activity data
    /// from `high` to `medium` purely because of the user's language.
    func classId(for source: Source, devices: [Device]) -> String {
        let haystack = devices
            .map { "\($0.name) \($0.model ?? "")" }
            .joined(separator: " ")
            .lowercased()

        for candidate in Self.deviceClassKeywords {
            if candidate.keywords.contains(where: haystack.contains) { return candidate.classId }
        }
        return sourceTypeDefaults[source.type.rawValue] ?? "unknown"
    }

    /// Ordered most-specific-first: "chest strap" must beat the bare "strap"-adjacent band
    /// vocabulary, and a scale must be checked before the generic fallbacks. Order is the whole
    /// contract of this table — a scale named "Watch Scale" is vanishingly rare, a watch named
    /// "Apple Watch" is not, so watch wins ties by sitting first.
    private static let deviceClassKeywords: [(classId: String, keywords: [String])] = [
        ("wrist_wearable", ["watch", "ساعة", "band", "سوار", "fitbit", "whoop", "garmin"]),
        ("ring_wearable", ["ring", "خاتم", "oura"]),
        ("chest_strap", ["chest", "strap", "حزام", "polar h", "hrm"]),
        ("smart_scale", ["scale", "ميزان", "withings body", "renpho"]),
        ("bp_cuff", ["blood pressure", "cuff", "ضغط", "omron"]),
        ("phone_handset", ["iphone", "phone", "هاتف", "جوال"]),
    ]
}

/// One class of sensor, as the shared contract describes it. Bilingual by construction — the
/// contract carries `nameEn`/`nameAr` and `descriptionEn`/`descriptionAr` precisely so this
/// surface does not have to invent Arabic for hardware categories.
struct SensorSourceClass: Decodable, Identifiable, Hashable {
    let sourceClassId: String
    let nameEn: String
    let nameAr: String
    let descriptionEn: String
    let descriptionAr: String
    let quality: [String: SensorQualityLevel]

    var id: String { sourceClassId }
    var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }
    var explainer: LocalizedString { LocalizedString(en: descriptionEn, ar: descriptionAr) }
}

/// How much a given sensor class is worth for a given family.
///
/// Decoded leniently (`init(from:)` maps anything unrecognized to `.medium` rather than throwing)
/// for the reason `CustomizationProfile` decodes leniently: a single unknown level string added
/// to the contract by a newer Android release must not fail the whole file's decode and blank the
/// map for every source.
enum SensorQualityLevel: String, Decodable, Hashable, CaseIterable {
    case high, medium, low, unsupported

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SensorQualityLevel(rawValue: raw) ?? .medium
    }

    /// Short chip label. Never a grade: "Direct measurement" / "Estimated" are statements about
    /// method, where "Good"/"Poor" would be a verdict on the user's equipment — and, by
    /// implication, on them.
    var label: LocalizedString {
        switch self {
        case .high: return LocalizedString(en: "Measured directly", ar: "قياس مباشر")
        case .medium: return LocalizedString(en: "Good for trends", ar: "مناسب لتتبّع الاتجاه")
        case .low: return LocalizedString(en: "Estimated", ar: "تقديري")
        case .unsupported: return LocalizedString(en: "Not from this device", ar: "ليس من هذا الجهاز")
        }
    }

    /// One sentence explaining what the label means for reading a number. Wellness-safe: talks
    /// about what the sensor does, never about the reliability of the person using it, and never
    /// suggests a reading should be discounted or acted on.
    var explainer: LocalizedString {
        switch self {
        case .high:
            return LocalizedString(
                en: "This kind of sensor measures this directly, so the number can be read as it is.",
                ar: "هذا النوع من المستشعرات يقيس هذه القيمة مباشرة، لذا يمكن قراءة الرقم كما هو.")
        case .medium:
            return LocalizedString(
                en: "A reasonable estimate from this kind of sensor — most useful as a trend over time rather than as one exact reading.",
                ar: "تقدير معقول من هذا النوع من المستشعرات — أنفع كاتجاه عبر الوقت منه كقراءة مفردة دقيقة.")
        case .low:
            return LocalizedString(
                en: "This kind of sensor works this out indirectly, so the direction of change tells you more than the exact figure.",
                ar: "هذا النوع من المستشعرات يستنتج هذه القيمة بطريقة غير مباشرة، لذا يخبرك اتجاه التغيّر أكثر مما يخبرك الرقم بالضبط.")
        case .unsupported:
            return LocalizedString(
                en: "This kind of sensor doesn't record this, so anything here reached your device from somewhere else.",
                ar: "هذا النوع من المستشعرات لا يسجّل هذه القيمة، لذا وصل ما هنا إلى جهازك من مكان آخر.")
        }
    }

    /// Tint for the chip. `low`/`unsupported` share the ONE calm amber the design system reserves
    /// for "outside the ordinary" — never `critical`, which stays permanently unused (see
    /// `BadanColor.critical`). A sensor telling you less than another sensor is not an alarm.
    var tint: Color {
        switch self {
        case .high: return BadanColor.inBandOnTint
        case .medium: return BadanColor.textSecondary
        case .low, .unsupported: return BadanColor.outOfBandOnTint
        }
    }

    /// Colour is never the only signal (design-system rule) — every level pairs its tint with a
    /// distinct glyph, and the chip always shows its text label too.
    var symbolName: String {
        switch self {
        case .high: return "checkmark.seal"
        case .medium: return "chart.line.uptrend.xyaxis"
        case .low: return "function"
        case .unsupported: return "minus.circle"
        }
    }
}

extension MetricFamily {
    /// The key this family is filed under in `sensor_quality.json`.
    ///
    /// Identity for every real family, with `.medications`/`.other` the sole exceptions: they are
    /// the non-registry and unknown buckets, have no contract entry by construction, and resolve
    /// through `defaultQuality` — the contract's stated behaviour for an unknown family.
    ///
    /// This used to be a shorter list with `workout` called out as a key "no `MetricFamily` case
    /// owns", plus a `workoutSensorQualityKey` constant to reach it. That was a workaround for the
    /// enum lagging the registry, and it was worse than it looked: the contract declares quality
    /// entries for `workout`, `cycle`, `hydration` and `lab`, and because those families all
    /// resolved to `.other` -> `"unmapped"`, **every one of those lookups silently returned
    /// `defaultQuality` instead of the authored label**. Sources were labelled "medium" where the
    /// contract says `high` or `unsupported`. Nothing failed; the honesty label was just wrong,
    /// which is the one failure mode plan §4 principle 9 exists to prevent. The constant had zero
    /// call sites and is deleted rather than kept as a second way to spell `.workout`.
    ///
    /// `readiness`, `effort` and `stress` have no entry in the contract *yet*. They return their
    /// identity key anyway rather than `"unmapped"`, so that if the contract later declares one it
    /// takes effect with no code change — the same reason the registry drives families in the
    /// first place. Until then they resolve through `defaultQuality` exactly as before.
    var sensorQualityKey: String {
        switch self {
        case .sleep: return "sleep"
        case .readiness: return "readiness"
        case .heart: return "heart"
        case .activity: return "activity"
        case .workout: return "workout"
        case .effort: return "effort"
        case .body: return "body"
        case .respiratory: return "respiratory"
        case .nutrition: return "nutrition"
        case .hydration: return "hydration"
        case .subjective: return "subjective"
        case .journal: return "journal"
        case .stress: return "stress"
        case .cycle: return "cycle"
        case .symptoms: return "symptoms"
        case .lab: return "lab"
        case .medications, .other: return "unmapped"
        }
    }
}
