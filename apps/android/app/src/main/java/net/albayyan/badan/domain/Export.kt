package net.albayyan.badan.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.AppLanguage

enum class ExportFormat(val code: String) {
    CSV("csv"),
    JSON("json");

    val fileExtension: String get() = code

    companion object {
        fun fromCode(code: String?): ExportFormat = entries.firstOrNull { it.code == code } ?: JSON
    }
}

enum class ExportJobStatus(val code: String) {
    PENDING("pending"),
    RUNNING("running"),
    COMPLETED("completed"),
    FAILED("failed");

    companion object {
        fun fromCode(code: String?): ExportJobStatus = entries.firstOrNull { it.code == code } ?: PENDING
    }
}

/**
 * The four-part scope picker as data. `null` list = "all". Raw / derived / suppressed /
 * sensitive are explicitly separable so the export never leaks what the user didn't ask for.
 * Stored as a JSON column.
 */
@Serializable
data class ExportScope(
    val metricIds: List<String>? = null,
    val families: List<String>? = null,
    val startDate: Long? = null,
    val endDate: Long? = null,
    val sourceIds: List<String>? = null,
    val includeRaw: Boolean = true,
    val includeDerived: Boolean = true,
    val includeSuppressed: Boolean = false,
    val includeSensitive: Boolean = false,
    val unitProfile: UnitProfileMode = UnitProfileMode.CANONICAL,
    val language: AppLanguage = AppLanguage.EN,
) {
    companion object {
        val everything = ExportScope(
            includeRaw = true, includeDerived = true,
            includeSuppressed = false, includeSensitive = false,
        )
    }
}

/**
 * Published, versioned manifest. Makes truncation and tampering detectable and the export
 * reproducible from its own description (D-8). Stored as a JSON column.
 */
@Serializable
data class ExportManifest(
    val exportId: String,
    val schemaVersion: String,
    val appVersion: String,
    val platform: String,
    val generatedAt: Long,
    val scope: ExportScope,
    val dateRange: String,
    val displayLanguage: String,
    val unitProfile: String,
    val timezonePolicy: String,
    val dedupPolicy: String,
    val perMetricRowCounts: Map<String, Int>,
    val checksums: Map<String, String>,
    val dataQualityNote: String,
    /**
     * True when the files this manifest describes were wrapped into one `ExportEncryptor`
     * container (always true for an `includeSensitive` export — see ADR-0008) rather than written
     * as plain CSV/JSON. [checksums] above still describe the real plaintext content either way;
     * only how it reached disk changes. Defaulted `false` so manifests persisted before EPIC-06
     * decode unchanged.
     */
    val encrypted: Boolean = false,
    /**
     * The container's filename inside the job's `outputPath` folder (always
     * `ExportEncryptor.CONTAINER_FILE_NAME` today; kept as a manifest field rather than a
     * hardcoded constant lookup so export UI doesn't need to import the encryptor just to know
     * what to look for). `null` when [encrypted] is false.
     */
    val encryptedContainerName: String? = null,
)

data class ExportJob(
    val id: String,
    val scope: ExportScope,
    val format: ExportFormat,
    val status: ExportJobStatus = ExportJobStatus.PENDING,
    val manifest: ExportManifest? = null,
    val outputPath: String? = null,
    val rowCount: Int? = null,
    val startedAt: Long? = null,
    val finishedAt: Long? = null,
    val createdAt: Long,
)

// MARK: - EPIC-09: the export template system (plan §9.3–§9.6)
//
// Mirror of the iOS `Domain/Export.swift` additions, entity for entity and code string for code
// string, over the same migration v4 tables. Nothing here adds or edits DDL.
//
// Two rules shape most of the decisions below, and both are load-bearing rather than stylistic:
//   1. `ExportRun` must never be able to hold a health value — enforced by types, not by review
//      (see [ExportRowCounts] / [ExportErrorDetail], which copy `BackgroundWorkDone`).
//   2. A secret must never reach the database — [ExportDestination] holds a [CredentialRef],
//      which is a Keystore *key* and is validated to look like one.

/**
 * §9.3 `rangeRule` — how a template turns "now" into a date window at run time.
 *
 * Separate from `ExportScope.startDate`/`endDate` because those two are *values* and this is a
 * *rule*: "last 30 days" saved on 1 March has to mean February when it runs in April, which a pair
 * of stored dates cannot express. [Fixed] is the one case that defers to the scope's stored dates
 * — that is what "fixed" means.
 *
 * Stored in one TEXT column, so [LastNDays] carries its N inline (`lastNDays:30`).
 */
sealed class ExportRangeRule {
    /** Use `scope.startDate`/`scope.endDate` verbatim. A window the user pinned deliberately. */
    object Fixed : ExportRangeRule()

    /**
     * A rolling window ending at run time. [days] is coerced to at least 1 — a zero-day window
     * would produce an empty export that looks like a data-loss bug.
     */
    data class LastNDays(val days: Int) : ExportRangeRule() {
        val safeDays: Int get() = maxOf(1, days)
    }

    /**
     * Everything ingested since this (template, destination) pair's `ExportCursor` watermark. Per
     * §12 EPIC-09's input rules, a runner that finds no cursor falls back to [LastNDays] *with a
     * notice* rather than silently exporting all of history.
     */
    object SinceLastRun : ExportRangeRule()

    object AllTime : ExportRangeRule()

    val storageValue: String
        get() = when (this) {
            is Fixed -> "fixed"
            is LastNDays -> "lastNDays:$safeDays"
            is SinceLastRun -> "sinceLastRun"
            is AllTime -> "allTime"
        }

    companion object {
        /**
         * Tolerant by design: a row this build cannot parse (a downgrade, a hand-edited database)
         * reads back as [AllTime] rather than dropping the template, because losing the template
         * loses the user's saved configuration while an over-wide range only costs them a bigger
         * file they can see and re-narrow.
         */
        fun fromStorage(value: String?): ExportRangeRule = when {
            value == "fixed" -> Fixed
            value == "sinceLastRun" -> SinceLastRun
            value == "allTime" -> AllTime
            value != null && value.startsWith("lastNDays:") ->
                value.removePrefix("lastNDays:").toIntOrNull()?.let { LastNDays(maxOf(1, it)) } ?: AllTime
            else -> AllTime
        }
    }
}

/**
 * §9.3's bucketing vocabulary for a template (`hour|day|week|month`).
 *
 * Deliberately narrower than EPIC-08's `granularity` CSV column (`raw|second|minute|hour|day|week|
 * month|year`). They answer different questions: the CSV column reports what a *row* actually is —
 * including `second`/`minute` values that come from the source device — while this enum is a
 * *choice the user made* about how to bucket their export, and nobody asks for per-second
 * re-bucketing of data that is already per-second.
 */
enum class ExportBucket(val code: String) {
    HOUR("hour"), DAY("day"), WEEK("week"), MONTH("month");

    companion object {
        fun fromCode(code: String?): ExportBucket? = entries.firstOrNull { it.code == code }
    }
}

/**
 * §9.3 aggregation `method`, matching EPIC-08's `aggregation_method` vocabulary minus `none`
 * (which is what [ExportAggregation.Raw] means here — see that type).
 */
enum class ExportAggregationMethod(val code: String) {
    SUM("sum"), MEAN("mean"), MIN("min"), MAX("max"),
    MIN_AVG_MAX("minAvgMax"), DURATION("duration"), LATEST("latest");

    companion object {
        fun fromCode(code: String?): ExportAggregationMethod? = entries.firstOrNull { it.code == code }
    }
}

/**
 * §9.3 `aggregation` — a sealed type rather than a `(granularity, method?)` pair on purpose.
 *
 * Migration v4 makes `aggregation_method` nullable "because it is only meaningful when
 * `aggregation` is not `raw`". A data class with an optional method can represent the two states
 * the schema comment calls impossible — raw-with-a-method, and bucketed-without-one — and
 * something downstream then has to decide what those mean. Here [Raw] simply has nowhere to put a
 * method and [Bucketed] cannot be built without one, so the schema's nullability rule is a
 * consequence of the type instead of a convention someone has to remember.
 */
sealed class ExportAggregation {
    object Raw : ExportAggregation()
    data class Bucketed(val bucket: ExportBucket, val method: ExportAggregationMethod) : ExportAggregation()

    /** The `aggregation` column. */
    val storageGranularity: String
        get() = when (this) {
            is Raw -> "raw"
            is Bucketed -> bucket.code
        }

    /** The `aggregation_method` column — null exactly when [Raw]. */
    val storageMethod: String?
        get() = when (this) {
            is Raw -> null
            is Bucketed -> method.code
        }

    companion object {
        /**
         * Reads the two columns back. Anything that does not parse as a complete bucketed
         * aggregation degrades to [Raw]: raw is the honest fallback because it is the only value
         * that adds no interpretation of its own to the data.
         */
        fun from(granularity: String?, method: String?): ExportAggregation {
            val bucket = ExportBucket.fromCode(granularity) ?: return Raw
            val parsed = ExportAggregationMethod.fromCode(method) ?: return Raw
            return Bucketed(bucket, parsed)
        }
    }
}

/**
 * §9.3 `layout`. `tidy` is one row per observation (long format, what a script or notebook wants);
 * `wide` pivots metrics into columns (what a spreadsheet user expects).
 */
enum class ExportLayout(val code: String) {
    TIDY("tidy"), WIDE("wide");

    companion object {
        fun fromCode(code: String?): ExportLayout = entries.firstOrNull { it.code == code } ?: TIDY
    }
}

/**
 * §9.3 — a saved, named, inspectable export configuration.
 *
 * The whole point relative to HAE-style presets is that this is *data the user can read back*:
 * every field that shaped an export is stored, so "what exactly did this template send" is
 * answerable from the row rather than from the code that ran.
 */
data class ExportTemplate(
    val id: String,
    /**
     * Storage identity, unique among live rows (`idx_export_templates_name`, partial on
     * `deleted_at IS NULL`). This is not display copy: the seeded presets store stable English
     * names here, and Quick Export renders its labels from [rangeRule] + [format] through the
     * existing localized formatting path so Arabic gets Arabic-Indic digits.
     */
    val name: String,
    /**
     * The existing [ExportScope], stored as JSON verbatim (v4 comment: so a template keeps working
     * unchanged when `ExportScope` gains a field).
     */
    val scope: ExportScope,
    val rangeRule: ExportRangeRule,
    /**
     * The existing [ExportFormat] (csv/json). §9.3 also lists `gpx-bundle`; it is deliberately
     * absent because no writer produces one yet — routes have no export representation until
     * EPIC-12. Adding the case here before the writer exists would let a user save a template that
     * silently produces nothing.
     */
    val format: ExportFormat,
    val aggregation: ExportAggregation = ExportAggregation.Raw,
    val layout: ExportLayout = ExportLayout.TIDY,
    val includeSchemaDocs: Boolean = false,
    /**
     * Optional: a template need not pin a destination (the user picks at run time). Note this is
     * the one place destination is optional — a *run* always resolves to one, which is why
     * `export_cursors.destination_id` is NOT NULL (see the v4 comment).
     */
    val destinationId: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    /**
     * True for the seeded Quick Export presets, which are read-only (§12 EPIC-10: "Presets are
     * seeded read-only templates"). Derived from the id rather than stored in a column because v4
     * has no `is_preset` column and this file must not add one — and because a derived answer
     * cannot be flipped by a hand-edited row into "this preset is editable now".
     */
    val isPreset: Boolean get() = QuickExportPreset.presetIds.contains(id)

    /** Whether running this template needs a fresh [SensitiveRunConsent]. */
    val requiresSensitiveConfirmation: Boolean get() = scope.includeSensitive

    /**
     * The scope to hand `ExportRunner`, resolved for one run.
     *
     * This is the only way to get a sensitive scope out of a template, which is what makes the
     * §9.3 rule enforceable rather than advisory: a runner that reads `template.scope` directly is
     * visibly bypassing a documented gate, and one that calls this cannot forget the check.
     *
     * Note what it deliberately does *not* do: a missing confirmation throws, and never silently
     * downgrades to `includeSensitive = false`. A quietly narrowed export would hand the user a
     * file missing the records they asked for, with nothing in it saying so.
     */
    fun scopeForRun(consent: SensitiveRunConsent?, now: Long): ExportScope {
        if (!requiresSensitiveConfirmation) return scope
        if (consent == null) throw ExportTemplateRunRefusal.SensitiveConfirmationRequired(id)
        if (consent.templateId != id) {
            throw ExportTemplateRunRefusal.SensitiveConfirmationForDifferentTemplate(id, consent.templateId)
        }
        // Also refuses a confirmation timestamped in the future: a clock change is not a reason to
        // widen a privacy gate.
        val age = now - consent.confirmedAt
        if (age < 0 || age > SensitiveRunConsent.VALIDITY_WINDOW_MS) {
            throw ExportTemplateRunRefusal.SensitiveConfirmationExpired(id)
        }
        return scope
    }
}

/**
 * The user's confirmation, given **at run time**, that this run may include the sensitive
 * namespace (meds/symptoms — I7).
 *
 * §9.3 requires this as defense in depth: saving a template that names a sensitive scope is not
 * standing permission to keep exporting it, and a template that will one day run from a schedule
 * or a Shortcut must not be able to carry that permission with it. It mirrors the export runner's
 * existing passphrase requirement, which stays in force independently.
 *
 * Deliberately **not** `@Serializable` and with no repository: there is nowhere to persist it, so
 * "remember my answer" cannot be implemented by accident. It also carries the template id it was
 * given for, so a confirmation the user gave for their weekly-vitals template cannot be reused to
 * authorize a different one.
 */
data class SensitiveRunConsent(val templateId: String, val confirmedAt: Long) {
    companion object {
        /**
         * How long a confirmation stays usable. Five minutes is long enough to cover a passphrase
         * entry and a share-sheet round trip, and short enough that a confirmation left on screen
         * overnight does not authorize a morning's export.
         */
        const val VALIDITY_WINDOW_MS = 300_000L
    }
}

/** Why a template refused to produce a runnable scope. */
sealed class ExportTemplateRunRefusal(message: String) : Exception(message) {
    class SensitiveConfirmationRequired(val templateId: String) :
        ExportTemplateRunRefusal("sensitive confirmation required")

    class SensitiveConfirmationForDifferentTemplate(val expected: String, val received: String) :
        ExportTemplateRunRefusal("sensitive confirmation was given for another template")

    class SensitiveConfirmationExpired(val templateId: String) :
        ExportTemplateRunRefusal("sensitive confirmation expired")
}

/**
 * The seeded, read-only Quick Export presets: Last 7 / Last 30 / All time × CSV / JSON.
 *
 * **This type is the structural exclusion of sensitive data and routes from Quick Export.** §12
 * EPIC-10 requires the exclusion to be structural rather than a default value someone can flip: a
 * preset is described entirely by a range and a format, there is no constructor, parameter or
 * field through which a caller could hand one a widened scope, and [presetScope] — the only place
 * a preset's [ExportScope] is built — is private and hardcodes the narrow one. Adding a sensitive
 * or route knob to a preset therefore means editing this type, which is exactly the review someone
 * should have to face.
 *
 * `ExportTemplateSystemTest.presetScopesGrantNoWideningPermission` walks the serialized scope and
 * fails on *any* `include*` permission that is true outside the raw/derived allowlist, so a future
 * `includeRoutes` added to `ExportScope` is covered the day it lands rather than the day someone
 * remembers to update this comment.
 */
enum class QuickExportPreset(
    /**
     * Fixed ids so seeding is idempotent (`INSERT OR IGNORE` by primary key) across every launch,
     * reinstall-over-restore and future re-seed. Identical to iOS's, so a cross-platform fixture
     * can diff two devices' template tables.
     *
     * They are real 26-character Crockford-base32 ULIDs (I8) with a zeroed timestamp half —
     * presets are not events and have no meaningful creation instant to embed. The readable half
     * spells the preset because a diagnostics dump full of anonymous ULIDs is unreadable. `MAX`
     * means all-time: Crockford base32 excludes I, L, O and U, so `ALL` and `ALLTIME` cannot be
     * spelled in a valid ULID at all.
     */
    val id: String,
    val rangeRule: ExportRangeRule,
    val format: ExportFormat,
) {
    LAST_7_CSV("0000000000PRESET7CSV000000", ExportRangeRule.LastNDays(7), ExportFormat.CSV),
    LAST_7_JSON("0000000000PRESET7JSN000000", ExportRangeRule.LastNDays(7), ExportFormat.JSON),
    LAST_30_CSV("0000000000PRESET30CSV00000", ExportRangeRule.LastNDays(30), ExportFormat.CSV),
    LAST_30_JSON("0000000000PRESET30JSN00000", ExportRangeRule.LastNDays(30), ExportFormat.JSON),
    ALL_TIME_CSV("0000000000PRESETMAXCSV0000", ExportRangeRule.AllTime, ExportFormat.CSV),
    ALL_TIME_JSON("0000000000PRESETMAXJSN0000", ExportRangeRule.AllTime, ExportFormat.JSON);

    /**
     * Storage identity only — see [ExportTemplate.name]. ASCII and stable: renaming one of these
     * would orphan the row under the unique-name index and reseed a duplicate under the new name.
     */
    val storageName: String
        get() {
            val range = when (val rule = rangeRule) {
                is ExportRangeRule.LastNDays -> "Last ${rule.safeDays} days"
                is ExportRangeRule.AllTime -> "All time"
                else -> "Quick"
            }
            return "Quick Export — $range (${format.code.uppercase()})"
        }

    /**
     * Build the seedable row. [now] and [originDeviceId] come from the caller so seeding stays
     * testable against a fixed clock.
     */
    fun template(now: Long, originDeviceId: String): ExportTemplate =
        ExportTemplate(
            id = id, name = storageName, scope = presetScope(), rangeRule = rangeRule,
            format = format,
            // Raw, tidy, no schema docs: Quick Export's promise is "your data, now", and every one
            // of those choices is the one that adds nothing between the stored rows and the file.
            aggregation = ExportAggregation.Raw, layout = ExportLayout.TIDY,
            includeSchemaDocs = false, destinationId = ExportDestination.SHARE_SHEET_ID,
            createdAt = now, updatedAt = now, originDeviceId = originDeviceId,
        )

    companion object {
        val presetIds: Set<String> = entries.map { it.id }.toSet()

        /**
         * The one place a preset's scope is built. Private, parameterless, and narrow:
         *  - `includeSensitive = false` — meds/symptoms need the explicit builder path and a
         *    passphrase (I7, ADR-0008), never a two-tap preset.
         *  - `includeSuppressed = false` — dedup losers are inspectable in the advanced builder; a
         *    casual "give me my data" export should not silently double-count a walk.
         *  - raw + derived are both on, because raw data is never paywalled or withheld and the
         *    derived values are what make the file legible.
         * Routes: no route data has an export representation yet (EPIC-12 owns the GPX writer), and
         * when it lands this factory still has no parameter through which a preset could opt in.
         */
        private fun presetScope(): ExportScope = ExportScope(
            includeRaw = true, includeDerived = true,
            includeSuppressed = false, includeSensitive = false,
        )
    }
}

/**
 * §9.4 `kind`. [MQTT] is **reserved vocabulary only**: nothing constructs it, no delivery path
 * exists, and it is present so that a future row written by a later build parses here instead of
 * collapsing to a wrong kind.
 */
enum class ExportDestinationKind(val code: String) {
    /**
     * The system share sheet — the destination for every Quick Export. Not "no destination": it is
     * a real destination row, which is what lets `export_cursors.destination_id` be NOT NULL (see
     * the v4 comment for why a nullable one corrupts `sinceLastRun`).
     */
    SHARE_SHEET("shareSheet"),

    /** A user-picked folder (persisted tree URI on Android, security-scoped bookmark on iOS). */
    FILE_FOLDER("fileFolder"),

    /**
     * Phase 3. Note the module lint: export *generation* makes no network calls, so a REST
     * destination is a delivery step outside the export module, not a writer that posts.
     */
    REST_API("restApi"),
    CLOUD_DRIVE("cloudDrive"),

    /** Reserved. See the type doc. */
    MQTT("mqtt");

    /**
     * Whether delivering here leaves the device. Drives which destinations need a TLS policy, a
     * credential, and a reachability status at all.
     */
    val leavesDevice: Boolean
        get() = when (this) {
            SHARE_SHEET, FILE_FOLDER -> false
            REST_API, CLOUD_DRIVE, MQTT -> true
        }

    companion object {
        /**
         * Falls back to [SHARE_SHEET] — the only kind that cannot leave the device. An unparseable
         * kind is a corrupted or downgraded row, and the safe reading of "I do not know where this
         * sends data" is "it does not send data anywhere".
         */
        fun fromCode(code: String?): ExportDestinationKind =
            entries.firstOrNull { it.code == code } ?: SHARE_SHEET
    }
}

/**
 * §9.4 `tlsPolicy`. [NOT_APPLICABLE] exists so an on-device destination does not have to claim a
 * transport policy it never exercises — a `fileFolder` row asserting `httpsOnly` is a small lie
 * that would eventually be read as evidence that folder writes go over TLS.
 */
enum class ExportTlsPolicy(val code: String) {
    HTTPS_ONLY("httpsOnly"), NOT_APPLICABLE("notApplicable");

    companion object {
        fun fromCode(code: String?): ExportTlsPolicy? = entries.firstOrNull { it.code == code }
    }
}

/** §9.4 `status`. */
enum class ExportDestinationStatus(val code: String) {
    OK("ok"),

    /**
     * The stored credential no longer authenticates. Distinct from [UNREACHABLE] because the user
     * action differs: reauthorize versus check the network/URL.
     */
    AUTH_EXPIRED("authExpired"),
    UNREACHABLE("unreachable"),

    /**
     * Turned off by the user. Never set automatically — a destination BADAN disabled on the user's
     * behalf would silently stop their exports.
     */
    DISABLED("disabled");

    companion object {
        fun fromCode(code: String?): ExportDestinationStatus =
            entries.firstOrNull { it.code == code } ?: DISABLED
    }
}

/**
 * A **reference** to a secret in Keystore-backed storage — never the secret.
 *
 * §9.4 says credentials live in the keystore and the database holds references. That is easy to
 * state and easy to violate: `credentialRef: String` accepts a bearer token just as happily as a
 * key name. So this type validates that its value *looks like a key BADAN minted* — the fixed
 * `badan.export.credential.` namespace, lowercase, no whitespace, at most 64 characters.
 *
 * The point is not that the check is cryptographically meaningful; it is that pasting a real secret
 * in fails. JWTs and OAuth tokens are longer than 64 characters, contain uppercase, and do not
 * start with BADAN's namespace, so [of] returns null for all three reasons at once — and the only
 * way to get a secret into this column is to first defeat this factory, which is a change a
 * reviewer sees.
 */
class CredentialRef private constructor(val key: String) {
    override fun equals(other: Any?): Boolean = other is CredentialRef && other.key == key
    override fun hashCode(): Int = key.hashCode()
    override fun toString(): String = key

    companion object {
        const val NAMESPACE = "badan.export.credential."
        const val MAX_LENGTH = 64
        private const val ALLOWED = "abcdefghijklmnopqrstuvwxyz0123456789._-"

        fun of(key: String?): CredentialRef? {
            if (key == null || !key.startsWith(NAMESPACE) || key.length > MAX_LENGTH) return null
            // A bare namespace is a reference to nothing.
            if (key.length == NAMESPACE.length) return null
            if (!key.all { ALLOWED.contains(it) }) return null
            return CredentialRef(key)
        }

        /**
         * Mint a reference for a destination. The destination id is a ULID, which is uppercase
         * Crockford base32 — lowercased here to satisfy the character rule above, and unambiguous
         * either way since ULIDs are case-insensitive by construction.
         */
        fun forDestination(id: String): CredentialRef? = of(NAMESPACE + id.lowercase())
    }
}

/**
 * §9.4 `config` — the **non-secret** half of a destination, as typed fields.
 *
 * Every field here is a reference or a routing detail, and that is the design. A `Map<String,
 * String>` bag would have made this column the path of least resistance for an `Authorization`
 * header value; instead the only header representation available is [headerTemplateIds], which
 * names header *templates* held elsewhere. There is no field on this class that a token, password,
 * cookie or signed URL fits into without renaming something.
 */
@Serializable
data class ExportDestinationConfig(
    /**
     * `fileFolder`: the preferences key under which the persisted tree URI (Android) or
     * security-scoped bookmark (iOS) is held. Not the grant itself — a persisted URI permission is
     * standing filesystem access and belongs with the other protected material.
     */
    val folderBookmarkRef: String? = null,
    /**
     * `restApi` (Phase 3): the endpoint. Carries no query string by contract — parameters that vary
     * per run belong to the delivery call, and a stored URL with a token in its query is exactly
     * the leak [CredentialRef] exists to prevent.
     */
    val endpointURL: String? = null,
    val httpMethod: String? = null,
    /** Ids of header templates, never header values. */
    val headerTemplateIds: List<String> = emptyList(),
    /** `cloudDrive`: which provider (`dropbox`, `gdrive` per §9.4). */
    val providerId: String? = null,
    val providerAccountRef: String? = null,
)

/** §9.4 — where artifacts go. */
data class ExportDestination(
    val id: String,
    val kind: ExportDestinationKind,
    val displayName: String,
    val config: ExportDestinationConfig = ExportDestinationConfig(),
    /** Keystore key. See [CredentialRef] for why this is not a `String`. */
    val credentialRef: CredentialRef? = null,
    /**
     * Defaulted from the kind rather than to a constant: §9.4 makes `httpsOnly` the default, but
     * only network destinations have a transport at all (see [ExportTlsPolicy]).
     */
    val tlsPolicy: ExportTlsPolicy = if (kind.leavesDevice) ExportTlsPolicy.HTTPS_ONLY else ExportTlsPolicy.NOT_APPLICABLE,
    val createdAt: Long,
    val lastVerifiedAt: Long? = null,
    val status: ExportDestinationStatus = ExportDestinationStatus.OK,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    companion object {
        /**
         * The share-sheet destination every Quick Export resolves to. Fixed id for the same reason
         * the presets have fixed ids — seeding must be idempotent, and a cursor keyed on a
         * regenerated destination id would restart from zero on every reinstall.
         */
        const val SHARE_SHEET_ID = "0000000000DESTSHARESHEET00"

        fun shareSheet(now: Long, originDeviceId: String): ExportDestination =
            ExportDestination(
                id = SHARE_SHEET_ID, kind = ExportDestinationKind.SHARE_SHEET,
                // Storage identity, not display copy — the export screen labels the share sheet
                // with its own localized string.
                displayName = "Share sheet",
                createdAt = now, updatedAt = now, originDeviceId = originDeviceId,
            )
    }
}

/**
 * §9.5 `trigger` — what caused this run. Stored rather than inferred, because "did my automation
 * actually fire, or was that me tapping export?" is the first question the Export Health dashboard
 * has to answer.
 */
enum class ExportTrigger(val code: String) {
    MANUAL("manual"),

    /** An App Intent / Shortcut ran it (device unlocked — §4.10's honest tier labeling). */
    SHORTCUT("shortcut"),

    /** A best-effort background wake took the opportunity. */
    SCHEDULED_OPPORTUNISTIC("scheduledOpportunistic"),

    /** Android WorkManager's periodic worker. */
    SCHEDULED_WORK("scheduledWork"),

    /** An automatic retry of a previously failed run. */
    RETRY("retry");

    companion object {
        /**
         * Falls back to [MANUAL], the trigger that makes the fewest claims: reading an unparseable
         * row as a *scheduled* run would invent evidence that an automation fired.
         */
        fun fromCode(code: String?): ExportTrigger = entries.firstOrNull { it.code == code } ?: MANUAL
    }
}

/**
 * §9.5 `outcome`. Every case is **terminal** — there is no `running`, which is why a run row is
 * appended once, when it ends (see `ExportRunRepository`).
 */
enum class ExportOutcome(val code: String) {
    SUCCESS("success"),

    /**
     * Some artifacts were produced, some were not. Recorded as its own outcome rather than as
     * success-with-a-note because a partial export is a file the user may act on believing it is
     * complete.
     */
    PARTIAL("partial"),
    FAILED_GENERATION("failedGeneration"),

    /**
     * Generated fine, never arrived. The distinction matters for retry: the artifact may already
     * exist on disk, so the retry is a delivery, not a regeneration.
     */
    FAILED_DELIVERY("failedDelivery"),

    /**
     * The sensitive store was unreadable. Not a failure — the same reasoning as
     * `BackgroundRunOutcome.STORE_LOCKED`.
     */
    SKIPPED_LOCKED("skippedLocked"),

    /**
     * Nothing new in range. A successful answer to "is there anything to export", not an error —
     * and recorded rather than skipped silently, so an automation that legitimately has nothing to
     * do is distinguishable from one that never ran.
     */
    SKIPPED_NO_DATA("skippedNoData"),
    THROTTLED("throttled"),
    CANCELLED("cancelled");

    /**
     * The single predicate any UI consults before styling a run as a problem. Deliberately narrow:
     * locked, no-data, throttled and cancelled are all ordinary.
     */
    val isFailure: Boolean get() = this == FAILED_GENERATION || this == FAILED_DELIVERY || this == PARTIAL

    companion object {
        /**
         * An unreadable outcome falls back to [FAILED_GENERATION] rather than [SUCCESS] — a ledger
         * must never round an unknown up into a claim that the export worked.
         */
        fun fromCode(code: String?): ExportOutcome =
            entries.firstOrNull { it.code == code } ?: FAILED_GENERATION
    }
}

/**
 * §9.5 `errorCode` — a closed vocabulary, so Export Health can decide whether a run is retryable
 * without parsing text.
 */
enum class ExportErrorCode(val code: String) {
    STORAGE_FULL("storageFull"),
    STORAGE_UNAVAILABLE("storageUnavailable"),
    PERMISSION_DENIED("permissionDenied"),

    /** The §9.3 run-time confirmation was missing or stale — see [ExportTemplateRunRefusal]. */
    SENSITIVE_CONFIRMATION_MISSING("sensitiveConfirmationMissing"),

    /** The export runner's existing passphrase requirement for an `includeSensitive` export. */
    PASSPHRASE_MISSING("passphraseMissing"),
    ENCRYPTION_FAILED("encryptionFailed"),
    WRITE_FAILED("writeFailed"),
    DESTINATION_UNREACHABLE("destinationUnreachable"),
    DESTINATION_AUTH_EXPIRED("destinationAuthExpired"),
    DESTINATION_DISABLED("destinationDisabled"),

    /** `sinceLastRun` with no cursor row (§12 EPIC-09's input rule). */
    CURSOR_MISSING("cursorMissing"),
    TEMPLATE_MISSING("templateMissing"),
    CANCELLED_BY_USER("cancelledByUser"),
    UNKNOWN("unknown");

    companion object {
        fun fromCode(code: String?): ExportErrorCode? = entries.firstOrNull { it.code == code }
    }
}

/**
 * Which phase of a run the failure happened in. `@SerialName` on every entry so the token written
 * into `error_detail` matches iOS's byte for byte — the two platforms' ledgers have to diff.
 */
@Serializable
enum class ExportStage {
    @SerialName("gathering") GATHERING,
    @SerialName("writing") WRITING,
    @SerialName("checksumming") CHECKSUMMING,
    @SerialName("encrypting") ENCRYPTING,
    @SerialName("delivering") DELIVERING,
    @SerialName("finalizing") FINALIZING,
}

/**
 * §9.5 `errorDetail` — "sanitized, value-free", and structurally so.
 *
 * Deliberately **not** a `String`. The obvious implementation of a detail field is the thrown
 * exception's message, and a SQLite or Health Connect message can quote row content — which is how
 * a health value ends up in a ledger the user is invited to share from the Export Health dashboard.
 * This class is the same defense `BackgroundWorkDone` uses for `background_runs`: every field is an
 * `Int` or a closed enum, so there is nowhere for a message, a metric name or a reading to go, and
 * that stays true without anyone remembering the rule at each call site.
 *
 * `ExportTemplateSystemTest.ledgerJsonColumnsCarryNoValues` asserts the encoded form contains only
 * integers and known enum tokens.
 */
@Serializable
data class ExportErrorDetail(
    val stage: ExportStage,
    val filesWritten: Int = 0,
    val filesExpected: Int = 0,
    /** Which attempt this was (0 = first). Lets a retry storm be seen as one. */
    val attempt: Int = 0,
    /**
     * EPIC-20 — the HTTP status a networked destination was last answered with, and the *only* half
     * of §22.7's "status code + sanitized reason" that was not already representable here. The
     * reason is `ExportRun.errorCode`, a closed vocabulary; this is the code, an integer.
     *
     * An `Int?` and not the response body, deliberately: a server's error text can echo back the
     * bytes BADAN just posted, so a body in this column would put health values into the one record
     * Export Health invites the user to share. Null for every non-network destination, and null when
     * the endpoint never answered at all (a timeout has no status — that case is carried by
     * `errorCode == DESTINATION_UNREACHABLE`).
     *
     * Additive and migration-free: `error_detail` is a JSON TEXT column, and an older row that
     * predates this field decodes with it null (`ignoreUnknownKeys` + this default).
     */
    val httpStatus: Int? = null,
)

/**
 * §9.5 `rowCounts` — how much left, by record class.
 *
 * **By class, not by metric.** `ExportManifest.perMetricRowCounts` keys on metric ids because a
 * manifest describes one file the user already has; this table is a durable log that Export Health
 * displays and a full backup carries, and a per-metric map there would be a standing record of
 * *which metrics this person tracks* — the same disclosure `BackgroundWorkDone`'s doc refuses for
 * `unmappedMetricIds`. Six integers answer "did my export get everything" without ever naming a
 * metric.
 */
@Serializable
data class ExportRowCounts(
    val measurements: Int = 0,
    val intervals: Int = 0,
    val sessions: Int = 0,
    val logs: Int = 0,
    val derived: Int = 0,
    /**
     * Dedup losers included because the scope asked for them (I3/I5 — raw and derived stay
     * separable, and suppressed rows are never silently dropped).
     */
    val suppressed: Int = 0,
) {
    val total: Int get() = measurements + intervals + sessions + logs + derived + suppressed
    val isEmpty: Boolean get() = total == 0
}

/**
 * A validated SHA-256 digest.
 *
 * `manifestSha256` is the last field on [ExportRun] that could plausibly have been a free `String`,
 * so it is the last hole through which arbitrary text could reach the ledger. 64 lowercase hex
 * characters or nothing.
 */
class ManifestDigest private constructor(val hex: String) {
    override fun equals(other: Any?): Boolean = other is ManifestDigest && other.hex == hex
    override fun hashCode(): Int = hex.hashCode()
    override fun toString(): String = hex

    companion object {
        fun of(hex: String?): ManifestDigest? {
            val lowered = hex?.lowercase() ?: return null
            if (lowered.length != 64) return null
            if (!lowered.all { it in '0'..'9' || it in 'a'..'f' }) return null
            return ManifestDigest(lowered)
        }
    }
}

/**
 * §9.5 — one row per **attempted** export, successful or not. The trust ledger, and the whole
 * anti-HAE thesis in one table: an export that fails leaves evidence that it failed.
 *
 * **This type must never be able to hold a health value.** Every field is an id, an instant, a
 * closed enum, or an integer count — there is no free-text field at all (see [ExportErrorDetail],
 * [ExportRowCounts], [ManifestDigest]). That is not a convention; it is the reason those three
 * types exist, and it is what makes the Export Health dashboard safe to screenshot.
 */
data class ExportRun(
    val id: String,
    /** null for an ad-hoc export from the builder — those have no template. */
    val templateId: String? = null,
    /**
     * The `export_jobs` row that produced the artifacts. null when the run never got as far as
     * creating a job (a refusal at the gate: no confirmation, no cursor, destination disabled).
     */
    val jobId: String? = null,
    val trigger: ExportTrigger,
    val startedAt: Long,
    val finishedAt: Long? = null,
    val outcome: ExportOutcome,
    val errorCode: ExportErrorCode? = null,
    val errorDetail: ExportErrorDetail? = null,
    val bytesWritten: Long? = null,
    val rowCounts: ExportRowCounts? = null,
    val destinationId: String? = null,
    /**
     * When delivery completed, which is not when generation completed. The gap between
     * [finishedAt] and this is precisely the "it said it exported but nothing arrived" case.
     */
    val deliveredAt: Long? = null,
    /**
     * Cursor watermarks either side of a delta run (both `ingested_at` instants — see
     * [ExportCursor]). Recorded so a wrong-looking delta export can be reconstructed after the fact
     * instead of guessed at.
     */
    val cursorBefore: Long? = null,
    val cursorAfter: Long? = null,
    val manifestSha256: ManifestDigest? = null,
)

/**
 * §9.6 — the incremental-export checkpoint for one (template, destination) pair.
 *
 * **[highWatermark] is a max `ingested_at`, never a max `measured_at`.** This is the field most
 * likely to be "corrected" by a future reader, so: a watch that syncs Saturday's workout on Monday
 * writes a row whose `measured_at` (Saturday) is already behind a Sunday watermark, and a
 * `measured_at` cursor would skip it forever — the export silently loses every late-arriving and
 * backfilled row, and the loss is invisible because the file looks complete. Only `ingested_at`,
 * stamped when BADAN wrote the row, is monotonic with respect to what this device has actually had
 * available to export.
 */
data class ExportCursor(
    val templateId: String,
    /**
     * NOT nullable, matching the NOT NULL column: `shareSheet` is a destination, not the absence of
     * one. The v4 comment explains what a nullable one does to `sinceLastRun`.
     */
    val destinationId: String,
    val highWatermark: Long,
    /**
     * The SHA-256 of the bundle FILE the last successful delta delivered — the chain link the next
     * run carries forward as its `previous_manifest_sha` (§22.6). Bundle-file sha, not the sha of
     * the `ExportManifest` struct: it is the value a consumer recomputes from the delivered file, so
     * `scripts/verify_export_chain.py` can walk the chain from the artifacts alone.
     */
    val lastManifestSha: ManifestDigest? = null,
    val lastRunId: String? = null,
    val updatedAt: Long,
)

// ===== §22.6 delta-export reconciliation records =====

/**
 * One tombstoned row a delta export reports in its `deletions[]` section (§22.6) so a downstream
 * store can reconcile a removal it would otherwise never learn about — a delta that only ever
 * *adds* rows can never tell a consumer a record went away.
 *
 * [entity] is the bundle array the record lived in (`raw_sample` | `interval_record` | `session`),
 * matching the `deletions[]` `entity` vocabulary `JsonBundleWriter` already emits. Mirror of iOS
 * `ExportTombstone`.
 */
data class ExportTombstone(
    val recordId: String,
    val entity: String,
    val deletedAt: Long,
    val tzId: String,
) {
    companion object {
        /**
         * The canonical emission order for a delta's tombstone set, shared by every format so the
         * JSON `deletions[]` array and the CSV `deletions.csv` rows list the same removals in the
         * same sequence. `record_id` alone is a TOTAL order: ids are ULIDs unique across every
         * table (I8), so no two tombstones can tie and neither platform's sort has a tie to break
         * differently. Mirror of iOS `ExportTombstone.exportSorted`.
         */
        fun exportSorted(tombstones: List<ExportTombstone>): List<ExportTombstone> =
            tombstones.sortedBy { it.recordId }
    }
}

/**
 * One suppression-flip correction a delta export reports in its `corrections[]` section (§22.6).
 *
 * The subtle desync EPIC-17 exists to close: a delta that only adds rows silently corrupts a
 * downstream store when a dedup decision *reverses* since the last cursor — the row it already has
 * as authoritative is now suppressed (or a suppressed one now wins) and nothing in an add-only delta
 * says so. [suppressedBy] is the winning record id when this record is now suppressed, or null when
 * the flip *cleared* a prior suppression (this record wins again). Mirror of iOS
 * `ExportSuppressionCorrection`.
 */
data class ExportSuppressionCorrection(
    val recordId: String,
    val suppressedBy: String?,
    val changedAt: Long,
) {
    companion object {
        /**
         * The canonical emission order for a delta's correction set, shared by every format so the
         * JSON `corrections[]` array and the CSV `corrections.csv` rows apply in the same sequence.
         *
         * `record_id`, then `changed_at`, then `suppressed_by` — a TOTAL order, not `record_id`
         * alone. One record CAN flip more than once inside a single delta window (suppressed by A,
         * then by B after a source-priority change), so `record_id` alone leaves ties, and while
         * this platform's sort is stable, Swift's `sorted(by:)` is documented as not guaranteed to
         * be — a tie would be free to resolve differently on the two platforms, quietly ending the
         * byte-identical guarantee the shared goldens assert. The `changed_at` tiebreaker also puts
         * a record's flips in the order they happened, so a consumer applying them in order lands
         * on that record's current state rather than on an intermediate one. A null [suppressedBy]
         * sorts as the empty string, which orders a clearing before a re-suppression at the same
         * instant; that is a tiebreaker of last resort, never a rendered value. Mirror of iOS
         * `ExportSuppressionCorrection.exportSorted`.
         */
        fun exportSorted(corrections: List<ExportSuppressionCorrection>): List<ExportSuppressionCorrection> =
            corrections.sortedWith(compareBy({ it.recordId }, { it.changedAt }, { it.suppressedBy ?: "" }))
    }
}
