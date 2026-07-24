import Foundation
import HealthKit

/// The staged permission bundles (plan §13.1, EPIC-01 task 5): the families BADAN asks for, in
/// the moment each one becomes relevant, each behind its own in-app explainer.
///
/// **The rule this type exists to enforce: the system dialog is never the first explanation the
/// user sees.** Every path that can reach a HealthKit authorization sheet goes through
/// `HealthPermissionGate`, which presents this bundle's explainer first and only then requests.
/// A new caller that wants a prompt has to name a bundle to get one, and naming a bundle gets it
/// the explainer whether it remembered to ask for one or not.
///
/// **Bundle contents are derived from `HKTypeMap`, never listed by hand.** The read set already
/// has exactly one source of truth (that table, itself coupled to the two `InfoPlist.strings` and
/// `project.yml`); a second hand-maintained list here would drift the first time somebody adds a
/// type, and the failure would be silent — an explainer that promises less than the sheet asks
/// for, which is the precise thing plan §13.1 forbids. `family(of:)` below is the only mapping
/// this file owns, and `PermissionStagingTests` asserts every ingesting row in the table
/// lands in exactly one bundle.
enum HealthPermissionBundle: String, CaseIterable, Identifiable, Sendable {
    /// Heart, HRV, breathing, blood oxygen, wrist temperature. Requested at onboarding's connect
    /// step and from the Health Monitor — the vitals the calm daily surfaces are built on.
    case coreVitals
    /// Steps, distance, flights, active/resting energy. Requested alongside `workouts` when a
    /// workout surface opens, because a workout with no energy or distance reads as broken.
    case activity
    /// Sleep sessions and stages.
    case sleep
    /// Weight, body fat, lean mass, height. Requested from Body, not at connect: most people
    /// have none of it, and asking up front spends trust on an empty family.
    case body
    /// Workout episodes. Requested when a workout surface opens.
    case workouts
    /// Blood glucose (A21/ADR-0010, D-26). Requested from Body, alongside `.body` — not at
    /// connect: like weight, most people have none of it, and it is `sensitivePlus` besides, so
    /// it earns its own explainer rather than riding along inside `.coreVitals`'s generic
    /// boundary copy, which says nothing about treatment decisions.
    case glucose
    /// GPS traces. Location data, gated on its own — see `RouteConsentScreen`. Deliberately in
    /// this enum so it is impossible to enumerate "what BADAN asks for" and miss it, but it is
    /// the only case whose `requestsPlatformReadTypes` is false: routes are never bundled into a
    /// family prompt.
    case routes

    var id: String { rawValue }

    // MARK: - Platform types

    /// The HealthKit types this bundle covers, derived from `HKTypeMap.table`.
    ///
    /// `.authorizationOnly` rows are INCLUDED. Height and wrist temperature produce no
    /// measurement rows today (see `HKTypeMap.NoIngestReason`), but they are in the sheet the
    /// user is shown, so the explainer that precedes that sheet has to name them. Omitting them
    /// here would understate the ask by exactly the two types most likely to surprise someone.
    var quantityTypes: [HKTypeMap.Entry] {
        HKTypeMap.table.filter { Self.family(of: $0) == self }
    }

    /// Everything this bundle would request, including the non-quantity types (`sleepAnalysis`,
    /// `workoutType`, `workoutRoute`) that `HKTypeMap` tracks outside its quantity table.
    var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(quantityTypes.compactMap(\.quantityType))
        switch self {
        case .sleep:
            if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        case .workouts:
            types.insert(HKObjectType.workoutType())
        case .routes:
            types.formUnion(HealthKitAdapter.routeReadTypes)
        case .coreVitals, .activity, .body, .glucose:
            break
        }
        return types
    }

    /// Which bundle a type belongs to. The single hand-authored mapping in this file.
    ///
    /// Grouped by what the user would recognize as one ask, not by `MetricFamily`: VO2 max is a
    /// `heart` metric in the registry but sits with core vitals here because "cardio fitness" is
    /// something a person understands as part of the same passive-heart-sensing story. Energy is
    /// `activity` rather than `body` for the same reason — nobody thinks of calories burned as a
    /// body measurement.
    static func family(of entry: HKTypeMap.Entry) -> HealthPermissionBundle {
        switch entry.identifier {
        case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max,
             .respiratoryRate, .oxygenSaturation, .appleSleepingWristTemperature:
            return .coreVitals
        case .stepCount, .distanceWalkingRunning, .flightsClimbed,
             .activeEnergyBurned, .basalEnergyBurned:
            return .activity
        case .bodyMass, .bodyFatPercentage, .leanBodyMass, .height:
            return .body
        case .bloodGlucose:
            return .glucose
        default:
            // A newly added type with no explicit home lands in core vitals rather than silently
            // dropping out of every explainer. Over-explaining one type is recoverable; shipping
            // a sheet that asks for something no screen ever mentioned is not.
            return .coreVitals
        }
    }

    /// Whether asking for this bundle means asking the platform for read types.
    ///
    /// False only for `routes`, whose gate is BADAN's own consent toggle plus its own separate
    /// HealthKit sheet, driven from `RouteConsentScreen` rather than from the family staging.
    var requestsPlatformReadTypes: Bool { self != .routes }

    // MARK: - Contextual staging (plan §13.1)

    /// The bundles onboarding's connect step covers. Vitals + sleep + activity: the three that
    /// make Home say something real on day one. Body and workouts are deliberately absent —
    /// they are asked for by the surfaces that need them.
    static let onboardingConnect: [HealthPermissionBundle] = [.coreVitals, .sleep, .activity]

    /// What a workout surface asks for on open (plan §13.1: "workouts+energy+distance when
    /// opening workout surfaces").
    static let workoutSurface: [HealthPermissionBundle] = [.workouts, .activity]

    // MARK: - Explainer copy
    //
    // Wellness-safe throughout: describes what is read and what is not, never what BADAN will
    // conclude about the reader. No claim about accuracy, no health advice, no urgency.

    var title: LocalizedString {
        switch self {
        case .coreVitals:
            return LocalizedString(en: "Your everyday vitals", ar: "مؤشراتك الحيوية اليومية")
        case .activity:
            return LocalizedString(en: "Movement and energy", ar: "الحركة والطاقة")
        case .sleep:
            return LocalizedString(en: "Your sleep", ar: "نومك")
        case .body:
            return LocalizedString(en: "Body measurements", ar: "قياسات الجسم")
        case .workouts:
            return LocalizedString(en: "Your workouts", ar: "تمارينك")
        case .glucose:
            return LocalizedString(en: "Blood glucose", ar: "سكر الدم")
        case .routes:
            return LocalizedString(en: "Workout routes", ar: "مسارات التمارين")
        }
    }

    /// One sentence on why this family is being asked for, at this moment.
    var purpose: LocalizedString {
        switch self {
        case .coreVitals:
            return LocalizedString(
                en: "These are the readings your daily summary is built from, so BADAN can show you your own usual range instead of someone else's average.",
                ar: "هذه هي القراءات التي يُبنى منها ملخّصك اليومي، ليعرض لك بدن نطاقك المعتاد أنت لا متوسط شخص آخر.")
        case .activity:
            return LocalizedString(
                en: "Steps, distance and energy give your days shape, and they're what turns a workout into more than a stopwatch reading.",
                ar: "الخطوات والمسافة والطاقة تعطي أيامك شكلاً، وهي ما يجعل التمرين أكثر من مجرد قراءة ساعة إيقاف.")
        case .sleep:
            return LocalizedString(
                en: "Sleep sessions recorded by your device, so last night can sit next to the rest of your record.",
                ar: "جلسات النوم التي سجّلها جهازك، لتظهر ليلتك الماضية إلى جانب بقية سجلّك.")
        case .body:
            return LocalizedString(
                en: "Read only if you measure them. Nothing here is expected of you, and Body works without any of it.",
                ar: "تُقرأ فقط إن كنت تقيسها. لا شيء هنا مطلوب منك، وصفحة الجسم تعمل بدونها تماماً.")
        case .workouts:
            return LocalizedString(
                en: "Workouts your watch or phone already finished recording, with the heart rate that went with them.",
                ar: "التمارين التي انتهى جهازك أو هاتفك من تسجيلها بالفعل، مع معدل ضربات القلب المرافق لها.")
        case .glucose:
            return LocalizedString(
                en: "If a connected sensor or meter has already written glucose readings to Apple Health, BADAN can show them alongside the rest of your record — for your own awareness, never as medical guidance.",
                ar: "إن كان جهاز استشعار أو جهاز قياس متصل قد كتب قراءات سكر الدم في تطبيق صحة آبل بالفعل، يمكن لبدن عرضها إلى جانب بقية سجلّك — لوعيك الشخصي فقط، وليس كإرشاد طبي.")
        case .routes:
            return LocalizedString(
                en: "The path a finished workout took, if your device saved one.",
                ar: "المسار الذي سلكه تمرين منتهٍ، إن كان جهازك قد حفظه.")
        }
    }

    /// The plain-language list of what is read — one row per thing, so the explainer is checkable
    /// against the system sheet that follows it rather than a vague summary.
    var reads: [LocalizedString] {
        switch self {
        case .coreVitals:
            return [
                LocalizedString(en: "Heart rate and resting heart rate", ar: "معدل ضربات القلب ومعدله أثناء الراحة"),
                LocalizedString(en: "Heart rate variability", ar: "تغيّر معدل ضربات القلب"),
                LocalizedString(en: "Breathing rate and blood oxygen", ar: "معدل التنفّس وأكسجين الدم"),
                LocalizedString(en: "Wrist temperature while you sleep", ar: "حرارة المعصم أثناء النوم"),
                LocalizedString(en: "Cardio fitness estimate", ar: "تقدير اللياقة القلبية"),
            ]
        case .activity:
            return [
                LocalizedString(en: "Steps and distance", ar: "الخطوات والمسافة"),
                LocalizedString(en: "Flights climbed", ar: "الطوابق المصعودة"),
                LocalizedString(en: "Active and resting energy", ar: "الطاقة النشطة وطاقة الراحة"),
            ]
        case .sleep:
            return [
                LocalizedString(en: "When you were asleep and in bed", ar: "أوقات نومك وبقائك في الفراش"),
                LocalizedString(en: "Sleep stages, where your device records them", ar: "مراحل النوم، حيث يسجّلها جهازك"),
            ]
        case .body:
            return [
                LocalizedString(en: "Weight", ar: "الوزن"),
                LocalizedString(en: "Body fat and lean mass", ar: "نسبة الدهون والكتلة الصافية"),
                LocalizedString(en: "Height", ar: "الطول"),
            ]
        case .workouts:
            return [
                LocalizedString(en: "Workout type, start and end time", ar: "نوع التمرين ووقت بدايته ونهايته"),
                LocalizedString(en: "Duration, energy and distance", ar: "المدة والطاقة والمسافة"),
                LocalizedString(en: "Average and highest heart rate", ar: "متوسط معدل القلب وأعلاه"),
            ]
        case .glucose:
            return [
                LocalizedString(en: "Blood glucose readings from a connected sensor or meter",
                                ar: "قراءات سكر الدم من جهاز استشعار أو جهاز قياس متصل"),
            ]
        case .routes:
            return [
                LocalizedString(en: "The route your device already saved with a finished workout",
                                ar: "المسار الذي حفظه جهازك مع تمرين منتهٍ بالفعل"),
            ]
        }
    }

    /// What this bundle does NOT do. Present on every bundle, not just routes: naming the
    /// boundary is the whole point of explaining before prompting, and a bundle with no stated
    /// limit reads as an open-ended ask.
    var boundary: LocalizedString {
        switch self {
        case .coreVitals, .activity, .sleep, .body:
            return LocalizedString(
                en: "BADAN reads this from your device and never writes anything back to Apple Health. Nothing is sent anywhere unless you export it yourself.",
                ar: "يقرأ بدن هذا من جهازك ولا يكتب أي شيء في تطبيق صحة آبل. لا يُرسل شيء إلى أي مكان إلا إذا صدّرته بنفسك.")
        case .glucose:
            // A21/D-26: "never for treatment decisions" is load-bearing copy on every glucose
            // surface, not just where the value itself renders — see `GlucoseDisclaimer` for the
            // identically-worded value-surface disclaimer this line mirrors.
            return LocalizedString(
                en: "BADAN reads this from your device and never writes anything back to Apple Health. Shown for personal awareness only — never for treatment decisions. Always follow your own healthcare provider's guidance for managing your glucose.",
                ar: "يقرأ بدن هذا من جهازك ولا يكتب أي شيء في تطبيق صحة آبل. يُعرض لِلوعي الشخصي فقط — ولا يُستخدم أبدًا لاتخاذ أي قرار علاجي. اتبع دائمًا إرشادات مقدّم الرعاية الصحية الخاص بك لإدارة سكر الدم.")
        case .workouts:
            return LocalizedString(
                en: "Only finished workouts, read after the fact. BADAN doesn't start, stop or track a workout, and the route is a separate choice you make on its own screen.",
                ar: "التمارين المنتهية فقط، وتُقرأ بعد انتهائها. لا يبدأ بدن تمريناً ولا يوقفه ولا يتتبّعه، والمسار خيار منفصل تتّخذه في شاشته الخاصة.")
        case .routes:
            return LocalizedString(
                en: "No live tracking, ever. BADAN never follows where you are and never records a new route — it only reads back a path your device already saved. Nothing leaves your device.",
                ar: "لا تتبّع مباشر إطلاقاً. لا يتتبّع بدن مكانك ولا يسجّل مساراً جديداً — يقرأ فقط مساراً حفظه جهازك من قبل. ولا يغادر شيء جهازك.")
        }
    }

    var symbolName: String {
        switch self {
        case .coreVitals: return "heart.text.square"
        case .activity: return "figure.walk"
        case .sleep: return "moon.stars"
        case .body: return "figure.stand"
        case .workouts: return "figure.run"
        case .glucose: return "drop.circle"
        case .routes: return "map"
        }
    }
}
