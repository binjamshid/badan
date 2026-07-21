package net.albayyan.badan.domain.hydration

import net.albayyan.badan.core.DecimalParsing
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.Provenance

// MARK: - Fluid type

/**
 * The display/grouping category of a logged drink. Stored as a bare string on [HydrationEntry] (the
 * same open-vocabulary choice `WorkoutEntry.activityType` makes) so a beverage the dictionary does
 * not yet list is never rejected — this enum only names the curated set for bilingual display.
 * `WATER` is the safe default for anything unrecognized.
 *
 * A fluid type is NEVER a hydration weight. §7A.1 rejects "net hydration" multipliers outright: 500
 * mL of coffee is logged as 500 mL, exactly like 500 mL of water. Mirror of iOS `HydrationFluidType`.
 */
enum class HydrationFluidType(val code: String) {
    WATER("water"),
    COFFEE("coffee"),
    TEA("tea"),
    DAIRY("dairy"),
    JUICE("juice"),
    SOFT_DRINK("soft_drink"),
    ELECTROLYTE("electrolyte"),
    OTHER("other");

    val displayLabel: LocalizedString
        get() = when (this) {
            WATER -> LocalizedString(en = "Water", ar = "ماء")
            COFFEE -> LocalizedString(en = "Coffee", ar = "قهوة")
            TEA -> LocalizedString(en = "Tea", ar = "شاي")
            DAIRY -> LocalizedString(en = "Dairy", ar = "منتجات الألبان")
            JUICE -> LocalizedString(en = "Juice", ar = "عصير")
            SOFT_DRINK -> LocalizedString(en = "Soft drink", ar = "مشروب غازي")
            ELECTROLYTE -> LocalizedString(en = "Electrolyte drink", ar = "مشروب إلكتروليت")
            OTHER -> LocalizedString(en = "Other drink", ar = "مشروب آخر")
        }

    companion object {
        /** Folds an arbitrary stored string to a known category for display, defaulting to [WATER]. */
        fun known(raw: String): HydrationFluidType = entries.firstOrNull { it.code == raw } ?: WATER
    }
}

// MARK: - Beverage & container catalog

/**
 * A user-added beverage definition (the built-ins ship in `beverages.json`; this table is the custom
 * half of the dictionary-vs-custom split, exactly like `symptoms.json` / `symptom_entries`).
 *
 * [caffeineMgPer100ml] / [alcoholPct] / [electrolyteNote] are **display metadata only** this phase.
 * They are carried so a later phase can *show* them, but nothing reads them into a hydration total or
 * a "net hydration" multiplier — that is a §7A.1 Reject item. Mirror of iOS `BeverageDefinition`.
 */
data class BeverageDefinition(
    val id: String,
    val nameEn: String,
    val nameAr: String,
    val fluidType: String,
    val defaultVolumeMl: Double? = null,
    val caffeineMgPer100ml: Double? = null,   // display metadata only — never a hydration weight
    val alcoholPct: Double? = null,           // display metadata only — never a hydration weight
    val electrolyteNote: String? = null,      // display metadata only — never a hydration weight
    val isBuiltin: Boolean = false,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)
}

/**
 * A saved container ("My Bottle", "Glass") — the favorite that makes a log ≤2 actions and gives the
 * "Added 500 mL from My Bottle" confirmation its name. [beverageId] is the default drink (null =
 * plain water). Mirror of iOS `ContainerPreset`.
 */
data class ContainerPreset(
    val id: String,
    val nameEn: String,
    val nameAr: String,
    val volumeMl: Double,
    val beverageId: String? = null,
    val sortOrder: Int = 0,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)
}

// MARK: - Hydration entry (append-first ledger)

/**
 * One logged drink. The ledger is **append-first with an auditable revision chain** (§9.14): an edit
 * never overwrites a row, it appends a new one that supersedes the old, so "what the user said, and
 * how they later corrected it" is always recoverable (I2-flavored).
 *
 * - [originalId] is the stable identity of a logical drink across every revision; an un-revised entry
 *   has `originalId == id`.
 * - [supersedes] points at the row this one replaces (null for an original) — the backward link that
 *   lets the LIVE view be computed without mutating any old row (see [HydrationLedger.liveEntries]).
 * - [revision] is a 1-based counter (1 = original).
 *
 * [note] is redacted from the default export (§7A.1) — stored, but withheld unless explicitly opted
 * in. Mirror of iOS `HydrationEntry`.
 */
data class HydrationEntry(
    val id: String,
    val volumeMl: Double,        // canonical mL, always > 0
    val fluidType: String,       // category key, e.g. "water"
    val beverageId: String? = null,
    val containerId: String? = null,
    val occurredAt: Long,
    val tzId: String,
    val note: String? = null,    // REDACTED from the default export
    val originalId: String,
    val supersedes: String? = null,
    val revision: Int = 1,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val isOriginal: Boolean get() = supersedes == null
    val isRevised: Boolean get() = revision > 1
}

// MARK: - Ledger logic

/**
 * Pure, storage-free logic for the hydration ledger: volume parsing (Arabic-numeral aware), building
 * originals and revisions, and computing the LIVE set. Every function is total over its inputs so it
 * is testable without a database, and the repository's SQL mirrors [liveEntries] exactly. Mirror of
 * iOS `HydrationLedger`.
 */
object HydrationLedger {

    /**
     * Parses a user-typed volume as canonical mL, folding Arabic digits and the Arabic decimal
     * separator through the shared [DecimalParsing] (BUG-15). Rejects non-positive, non-finite, and
     * unparseable input — a drink with no positive volume is not a log, it is a mistake.
     */
    fun parseVolumeMl(text: String): Double? {
        val value = DecimalParsing.parse(text) ?: return null
        return if (value.isFinite() && value > 0.0) value else null
    }

    /** Builds an original (first-time) entry: `originalId == id`, no `supersedes`, revision 1. */
    fun makeEntry(
        id: String, volumeMl: Double, fluidType: String, beverageId: String? = null,
        containerId: String? = null, occurredAt: Long, tzId: String, note: String? = null,
        provenance: Provenance, updatedAt: Long, originDeviceId: String,
    ): HydrationEntry = HydrationEntry(
        id = id, volumeMl = volumeMl, fluidType = fluidType, beverageId = beverageId,
        containerId = containerId, occurredAt = occurredAt, tzId = tzId, note = note,
        originalId = id, supersedes = null, revision = 1, provenance = provenance,
        updatedAt = updatedAt, originDeviceId = originDeviceId,
    )

    /**
     * Builds a revision that supersedes [live] — an APPEND, never a mutation of [live]. The new row
     * inherits the chain's `originalId`, links back via `supersedes`, and bumps `revision`. Fields not
     * passed default to [live], so a "just fix the volume" edit keeps everything else.
     */
    fun makeRevision(
        live: HydrationEntry, id: String, volumeMl: Double = live.volumeMl,
        fluidType: String = live.fluidType, beverageId: String? = live.beverageId,
        containerId: String? = live.containerId, occurredAt: Long = live.occurredAt,
        tzId: String = live.tzId, note: String? = live.note, provenance: Provenance,
        updatedAt: Long, originDeviceId: String,
    ): HydrationEntry = HydrationEntry(
        id = id, volumeMl = volumeMl, fluidType = fluidType, beverageId = beverageId,
        containerId = containerId, occurredAt = occurredAt, tzId = tzId, note = note,
        originalId = live.originalId, supersedes = live.id, revision = live.revision + 1,
        provenance = provenance, updatedAt = updatedAt, originDeviceId = originDeviceId,
    )

    /**
     * The LIVE set over a group of rows: a row is live iff it is not tombstoned AND no *non-deleted*
     * row supersedes it. That "non-deleted superseder" qualifier is what makes `undo` (tombstone one
     * revision → the prior version becomes live again) and `delete` (tombstone the whole chain →
     * nothing is live) both fall out of the same rule. Input order is preserved.
     */
    fun liveEntries(all: List<HydrationEntry>): List<HydrationEntry> {
        val supersededByLive = all.filter { it.deletedAt == null }.mapNotNull { it.supersedes }.toSet()
        return all.filter { it.deletedAt == null && it.id !in supersededByLive }
    }
}
