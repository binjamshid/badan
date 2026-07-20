package net.albayyan.badan.ontology

import android.content.res.AssetManager
import android.util.Log
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.Source

/**
 * The compiled sensor-quality contract (`packages/contracts/sensor_quality.json`), loaded exactly
 * like [MetricRegistry]/[AlgorithmRegistry] so both platforms label the same source the same way
 * (plan §15, §4 principle 9). Mirror of the iOS `SensorQualityMap`.
 *
 * **Why this exists — audit finding #6.** The contract was consumed on iOS and had no Android
 * consumer at all, while `scripts/sync_android_assets.sh` bundled it into `assets/` and CI gated
 * the mirror for parity. Half of a "shared contract" is not a shared contract: the Android Sources
 * screen showed which apps and devices had delivered data with no statement of what any of those
 * sensors is actually good at, and CI was policing a file the app never opened.
 *
 * It matters more here than on iOS, not less. Health Connect hands BADAN one source row per
 * *writing app*, several of which routinely write the same metric under near-identical labels, so
 * "which of these is the appropriate instrument for this family" is a question an Android user has
 * to answer more often than an iOS one.
 *
 * **This is an honesty surface, not a ranking.** The contract's own note is emphatic and worth
 * repeating where the code lives: a `low` label NEVER suppresses, hides, downweights or paywalls a
 * reading. Raw data is not paywalled, and which of two duplicate rows survives is decided by
 * writer priority + the dedup journal (I3, I4) — `SourcesPriorityCard` and `DedupLite`, not this
 * file. `low` on a wrist blood-pressure reading is a statement about optical wrist sensors, never
 * about the person; [SensorQualityLevel.explainer] is worded that way on purpose.
 *
 * The primary constructor takes an already-decoded file (mirrors iOS `init(file:)`, and is what
 * JVM unit tests use since they have no [AssetManager]); the [AssetManager] secondary constructor
 * loads `sensor_quality.json`.
 */
class SensorQualityMap(file: SensorQualityFile?) {

    val version: String = file?.version ?: MISSING_VERSION
    val defaultQuality: SensorQualityLevel = file?.defaultQuality ?: SensorQualityLevel.MEDIUM

    /** Declaration order, which is the order the Sources screen lists classes in. */
    val orderedClasses: List<SensorSourceClass> = file?.sourceClasses ?: emptyList()
    private val classes: Map<String, SensorSourceClass> = orderedClasses.keyedFirst { it.sourceClassId }
    private val sourceTypeDefaults: Map<String, String> = file?.sourceTypeDefaults ?: emptyMap()

    constructor(assets: AssetManager) : this(BundleJson.load<SensorQualityFile>(assets, "sensor_quality"))

    init {
        if (orderedClasses.isEmpty()) {
            // Mirrors the iOS `Logger.fault` on the same condition: a broken
            // `scripts/sync_android_assets.sh` mirror would otherwise ship a silently empty map and
            // every source would render the fallback label forever — which looks plausible and is
            // wrong, on a surface whose entire job is honesty about sensors.
            Log.e(TAG, "SensorQualityMap loaded no source classes — bundled sensor_quality.json may be missing or corrupted")
        }
    }

    fun sourceClass(id: String): SensorSourceClass? = classes[id]

    /**
     * Resolve a (source class, metric family) pair to a level, following the contract's stated
     * resolution order: the class's own entry, else [defaultQuality]. An unlabelled family degrades
     * toward caution rather than optimism — never to [SensorQualityLevel.HIGH].
     */
    fun level(sourceClassId: String, family: MetricFamily): SensorQualityLevel {
        val sourceClass = classes[sourceClassId] ?: return defaultQuality
        return sourceClass.quality[family.sensorQualityKey] ?: defaultQuality
    }

    /**
     * Which class a real, discovered source belongs to.
     *
     * The contract deliberately holds no model-string matchers ("it would become a stale allowlist
     * that silently mislabels a device it has not heard of"), so the matching lives here in code, as
     * the contract instructs. Deliberately conservative: anything unrecognized falls through to the
     * source type's default (`unknown` for a platform store), which resolves to `medium` everywhere
     * — an honest "we can't tell you more about this sensor" rather than a guess dressed as a fact.
     *
     * Arabic device-name keywords sit alongside the English ones for the same reason
     * `SourcesScreen.deviceIcon` should: a device named "ساعة أبل" matches no English substring, and
     * mislabelling it `unknown` would quietly downgrade a watch's activity data from `high` to
     * `medium` purely because of the user's language.
     */
    fun classId(source: Source, devices: List<Device>): String {
        val haystack = devices.joinToString(" ") { "${it.name} ${it.model ?: ""}" }.lowercase()
        for ((classId, keywords) in DEVICE_CLASS_KEYWORDS) {
            if (keywords.any { haystack.contains(it) }) return classId
        }
        return sourceTypeDefaults[source.type.code] ?: "unknown"
    }

    companion object {
        private const val TAG = "SensorQualityMap"

        /** Sentinel for "the file did not load", matching iOS's `version` fallback of "0". */
        const val MISSING_VERSION: String = "0"

        /**
         * Ordered most-specific-first: "chest strap" must beat the bare "strap"-adjacent band
         * vocabulary, and a scale must be checked before the generic fallbacks. Order is the whole
         * contract of this table — a scale named "Watch Scale" is vanishingly rare, a watch named
         * "Apple Watch" is not, so watch wins ties by sitting first. Byte-for-byte the same table
         * as iOS `SensorQualityMap.deviceClassKeywords`; the two are asserted equivalent by
         * `SensorQualityTest`'s classification cases, which mirror `SensorQualityTests`.
         */
        private val DEVICE_CLASS_KEYWORDS: List<Pair<String, List<String>>> = listOf(
            "wrist_wearable" to listOf("watch", "ساعة", "band", "سوار", "fitbit", "whoop", "garmin"),
            "ring_wearable" to listOf("ring", "خاتم", "oura"),
            "chest_strap" to listOf("chest", "strap", "حزام", "polar h", "hrm"),
            "smart_scale" to listOf("scale", "ميزان", "withings body", "renpho"),
            "bp_cuff" to listOf("blood pressure", "cuff", "ضغط", "omron"),
            "phone_handset" to listOf("iphone", "phone", "هاتف", "جوال"),
        )

        /**
         * One process-wide instance of an immutable bundled contract, mirroring the iOS
         * `SensorQualityMap.shared` singleton. Kept here rather than in `AppEnvironment` so a
         * screen can read the contract without the composition root growing a field for every
         * bundled file; the asset is read once and never mutated.
         */
        @Volatile
        private var cached: SensorQualityMap? = null

        fun from(assets: AssetManager): SensorQualityMap =
            cached ?: synchronized(this) {
                cached ?: SensorQualityMap(assets).also { cached = it }
            }
    }
}

/** The whole contract file. Public so JVM unit tests can decode the asset without an AssetManager. */
@Serializable
data class SensorQualityFile(
    val version: String = "",
    val defaultQuality: SensorQualityLevel = SensorQualityLevel.MEDIUM,
    val sourceTypeDefaults: Map<String, String> = emptyMap(),
    val sourceClasses: List<SensorSourceClass> = emptyList(),
)

/**
 * One class of sensor, as the shared contract describes it. Bilingual by construction — the
 * contract carries `nameEn`/`nameAr` and `descriptionEn`/`descriptionAr` precisely so this surface
 * does not have to invent Arabic for hardware categories.
 *
 * The contract's `familyNotes` are deliberately NOT decoded, matching iOS. Those notes are English
 * only, and every user-facing string in this app needs a real Arabic counterpart — rendering an
 * English-only sentence to an Arabic reader is the failure mode the en+ar rule exists to prevent,
 * and machine-translating a nuanced sensor caveat in the view layer would be worse. The bilingual
 * copy BADAN actually shows is authored in [SensorQualityLevel.explainer]. When the contract gains
 * `familyNotesAr`, surface the notes here and delete this paragraph — not before.
 * (`JsonCoding.json` has `ignoreUnknownKeys = true`, so the undecoded key is simply skipped.)
 */
@Serializable
data class SensorSourceClass(
    val sourceClassId: String,
    val nameEn: String,
    val nameAr: String,
    val descriptionEn: String,
    val descriptionAr: String,
    val quality: Map<String, SensorQualityLevel> = emptyMap(),
) {
    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)
    val explainer: LocalizedString get() = LocalizedString(en = descriptionEn, ar = descriptionAr)
}

/**
 * How much a given sensor class is worth for a given family.
 *
 * Decoded leniently ([LenientSensorQualityLevelSerializer] maps anything unrecognized to [MEDIUM]
 * rather than throwing) for the reason `CustomizationProfile` decodes leniently: a single unknown
 * level string added to the contract by a newer iOS release must not fail the whole file's decode
 * and blank the map for every source.
 */
@Serializable(with = LenientSensorQualityLevelSerializer::class)
enum class SensorQualityLevel(val code: String) {
    HIGH("high"),
    MEDIUM("medium"),
    LOW("low"),
    UNSUPPORTED("unsupported");

    /**
     * Short chip label. Never a grade: "Measured directly" / "Estimated" are statements about
     * method, where "Good"/"Poor" would be a verdict on the user's equipment — and, by implication,
     * on them. Kept word-for-word identical to iOS `SensorQualityLevel.label`.
     */
    val label: LocalizedString
        get() = when (this) {
            HIGH -> LocalizedString(en = "Measured directly", ar = "قياس مباشر")
            MEDIUM -> LocalizedString(en = "Good for trends", ar = "مناسب لتتبّع الاتجاه")
            LOW -> LocalizedString(en = "Estimated", ar = "تقديري")
            UNSUPPORTED -> LocalizedString(en = "Not from this device", ar = "ليس من هذا الجهاز")
        }

    /**
     * One sentence explaining what the label means for reading a number. Wellness-safe: talks about
     * what the sensor does, never about the reliability of the person using it, and never suggests a
     * reading should be discounted or acted on.
     */
    val explainer: LocalizedString
        get() = when (this) {
            HIGH -> LocalizedString(
                en = "This kind of sensor measures this directly, so the number can be read as it is.",
                ar = "هذا النوع من المستشعرات يقيس هذه القيمة مباشرة، لذا يمكن قراءة الرقم كما هو.",
            )
            MEDIUM -> LocalizedString(
                en = "A reasonable estimate from this kind of sensor — most useful as a trend over time rather than as one exact reading.",
                ar = "تقدير معقول من هذا النوع من المستشعرات — أنفع كاتجاه عبر الوقت منه كقراءة مفردة دقيقة.",
            )
            LOW -> LocalizedString(
                en = "This kind of sensor works this out indirectly, so the direction of change tells you more than the exact figure.",
                ar = "هذا النوع من المستشعرات يستنتج هذه القيمة بطريقة غير مباشرة، لذا يخبرك اتجاه التغيّر أكثر مما يخبرك الرقم بالضبط.",
            )
            UNSUPPORTED -> LocalizedString(
                en = "This kind of sensor doesn't record this, so anything here reached your device from somewhere else.",
                ar = "هذا النوع من المستشعرات لا يسجّل هذه القيمة، لذا وصل ما هنا إلى جهازك من مكان آخر.",
            )
        }

    companion object {
        fun fromCode(code: String?): SensorQualityLevel =
            entries.firstOrNull { it.code == code } ?: MEDIUM
    }
}

/**
 * Lenient enum decoding. Unlike the `fromCode` companions on `SourceType`/`SourceStatus` (which are
 * called by hand from the SQL row mappers), this one has to be installed as the enum's serializer
 * because the levels arrive as *map values* inside [SensorSourceClass.quality], where kotlinx
 * generates the lookup itself and would throw on an unrecognized string.
 */
object LenientSensorQualityLevelSerializer : KSerializer<SensorQualityLevel> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("net.albayyan.badan.ontology.SensorQualityLevel", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): SensorQualityLevel =
        SensorQualityLevel.fromCode(decoder.decodeString())

    override fun serialize(encoder: Encoder, value: SensorQualityLevel) = encoder.encodeString(value.code)
}

/**
 * The key this family is filed under in `sensor_quality.json`.
 *
 * Identity for every real family, with `MEDICATIONS`/`OTHER` the sole exceptions: they are the
 * non-registry and unknown buckets, have no contract entry by construction, and resolve through
 * `defaultQuality` — the contract's stated behaviour for an unknown family.
 *
 * `READINESS`, `EFFORT` and `STRESS` have no entry in the contract *yet*. They return their identity
 * key anyway rather than `"unmapped"`, so that if the contract later declares one it takes effect
 * with no code change — the same reason the registry drives families in the first place. Until then
 * they resolve through `defaultQuality` exactly as if they were absent.
 *
 * Written as an exhaustive `when` rather than `family.code` so that adding a `MetricFamily` case
 * forces a decision here. That is not hypothetical: on iOS the equivalent mapping lagged the
 * registry, four families resolved to `"unmapped"`, and every one of those lookups silently
 * returned `defaultQuality` instead of the authored level — sources labelled "medium" where the
 * contract says `high` or `unsupported`. Nothing failed; the honesty label was just wrong.
 */
val MetricFamily.sensorQualityKey: String
    get() = when (this) {
        MetricFamily.SLEEP -> "sleep"
        MetricFamily.READINESS -> "readiness"
        MetricFamily.HEART -> "heart"
        MetricFamily.ACTIVITY -> "activity"
        MetricFamily.WORKOUT -> "workout"
        MetricFamily.EFFORT -> "effort"
        MetricFamily.BODY -> "body"
        MetricFamily.RESPIRATORY -> "respiratory"
        MetricFamily.NUTRITION -> "nutrition"
        MetricFamily.HYDRATION -> "hydration"
        MetricFamily.SUBJECTIVE -> "subjective"
        MetricFamily.STRESS -> "stress"
        MetricFamily.CYCLE -> "cycle"
        MetricFamily.SYMPTOMS -> "symptoms"
        MetricFamily.LAB -> "lab"
        MetricFamily.MEDICATIONS, MetricFamily.OTHER -> "unmapped"
    }
