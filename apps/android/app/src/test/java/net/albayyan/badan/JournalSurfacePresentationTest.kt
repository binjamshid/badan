package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.domain.journal.BehaviorValueKind
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.ContextStatusKind
import net.albayyan.badan.domain.journal.JournalEntry
import net.albayyan.badan.features.journal.ContextStatusList
import net.albayyan.badan.features.journal.JournalCategory
import net.albayyan.badan.features.journal.JournalDayBuilder
import net.albayyan.badan.features.journal.JournalDayChoice
import net.albayyan.badan.features.journal.JournalStrings
import net.albayyan.badan.ontology.BehaviorDefinition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * EPIC-29 — the journal surface's PURE presentation logic, the view-independent half the Compose
 * screens delegate to, and the Android mirror of the iOS `JournalSurfacesTests` scope. Same
 * statement as `HydrationSurfacePresentationTest`: no Robolectric, no database, no Compose runtime —
 * what is pinned here is the chip state, the day arithmetic, the dictionary coverage and the copy,
 * which are the parts a screen edit can silently break.
 *
 * The through-line is honesty about what the user actually said: a chip binds to the CURRENT row for
 * its behaviour, a tap is never allowed to invent a number, and the §16 trust line is verbatim.
 */
class JournalSurfacePresentationTest {

    private val device = "test-device"
    private val at = 1_784_000_000_000L

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private val behaviorsFile = File("../../../packages/contracts/dictionaries/behaviors.json")

    private fun prov(occurredAt: Long, recordedAt: Long = occurredAt): Provenance = Provenance(
        sourceId = device, deviceId = device, ingestionPath = IngestionPath.MANUAL,
        measuredAt = occurredAt, measuredTimezone = "UTC", recordedAt = recordedAt, ingestedAt = recordedAt,
    )

    private fun entry(
        id: String,
        behaviorId: String? = null,
        customLabel: String? = null,
        kind: BehaviorValueKind = BehaviorValueKind.BOOLEAN,
        value: Double? = null,
        occurredAt: Long = at,
        recordedAt: Long = occurredAt,
        deletedAt: Long? = null,
    ): JournalEntry = JournalEntry(
        id = id, behaviorId = behaviorId, customLabel = customLabel, valueKind = kind, value = value,
        occurredAt = occurredAt, tzId = "UTC", provenance = prov(occurredAt, recordedAt),
        updatedAt = recordedAt, originDeviceId = device, deletedAt = deletedAt,
    )

    private fun definition(
        id: String,
        category: String,
        kind: BehaviorValueKind = BehaviorValueKind.BOOLEAN,
        unit: String? = null,
    ): BehaviorDefinition = BehaviorDefinition(
        id = id, nameEn = id, nameAr = id, valueKind = kind, unit = unit,
        category = category, sensitiveClass = SensitiveClass.SENSITIVE_PLUS,
    )

    private val dictionary = listOf(
        definition("caffeine", "stimulants", BehaviorValueKind.COUNT),
        definition("nicotine", "stimulants"),
        definition("nap", "sleep", BehaviorValueKind.QUANTITY, unit = "min"),
    )

    private val arabicLetters = Regex("[\\u0600-\\u06FF]")

    private fun assertRealArabic(label: String, s: LocalizedString) {
        assertTrue("$label must have English copy", s.en.isNotBlank())
        assertTrue("$label must have Arabic copy", s.ar.isNotBlank())
        assertTrue("$label Arabic must be Arabic script, not a copy of the English", arabicLetters.containsMatchIn(s.ar))
        assertNotEquals("$label must be translated, not duplicated", s.en, s.ar)
    }

    // --- Chip binding ---

    @Test fun everyDictionaryBehaviourAlwaysGetsAChip() {
        val chips = JournalDayBuilder.chips(dictionary, emptyList())
        assertEquals(dictionary.map { it.id }, chips.map { it.id })
        assertTrue("an untagged day shows the whole vocabulary, not an empty screen", chips.none { it.isOn })
    }

    @Test fun groupsFollowTheDictionarysOwnOrder() {
        val groups = JournalDayBuilder.groups(JournalDayBuilder.chips(dictionary, emptyList()))
        assertEquals(listOf("stimulants", "sleep"), groups.map { it.category })
        assertEquals(listOf("caffeine", "nicotine"), groups.first().chips.map { it.id })
    }

    @Test fun aTaggedBehaviourReadsAsOnAndCarriesItsAmount() {
        val chips = JournalDayBuilder.chips(
            dictionary,
            listOf(entry("e1", behaviorId = "caffeine", kind = BehaviorValueKind.COUNT, value = 2.0)),
        ).associateBy { it.id }
        assertTrue(chips["caffeine"]!!.isOn)
        assertEquals(2.0, chips["caffeine"]!!.amount!!, 1e-9)
        assertFalse(chips["nicotine"]!!.isOn)
        assertNull(chips["nicotine"]!!.amount)
    }

    /**
     * A plain tap stores a BOOLEAN row even for a behaviour the dictionary calls count or quantity,
     * so a tagged-but-unnumbered chip must report no amount — showing "1" or "20 min" there would be
     * the screen inventing a value the user never gave.
     */
    @Test fun aTapWithoutANumberShowsNoNumber() {
        val chips = JournalDayBuilder.chips(
            dictionary,
            listOf(entry("e1", behaviorId = "nap", kind = BehaviorValueKind.BOOLEAN)),
        ).associateBy { it.id }
        assertTrue(chips["nap"]!!.isOn)
        assertNull("a boolean row has no amount to show", chips["nap"]!!.amount)
    }

    /**
     * The chip must bind to the CURRENT row, whatever order the query returned. A chip bound to a
     * superseded row would show the wrong amount and remove the wrong entry — invisible in review,
     * and a lie about what the user said.
     */
    @Test fun latestEntryWinsRegardlessOfListOrder() {
        val older = entry("old", behaviorId = "caffeine", kind = BehaviorValueKind.COUNT, value = 1.0, occurredAt = at)
        val newer = entry("new", behaviorId = "caffeine", kind = BehaviorValueKind.COUNT, value = 3.0, occurredAt = at + 60_000)
        fun boundId(rows: List<JournalEntry>) =
            JournalDayBuilder.chips(dictionary, rows).first { it.id == "caffeine" }.entry!!.id
        assertEquals("new", boundId(listOf(older, newer)))
        assertEquals("new", boundId(listOf(newer, older)))
    }

    /** Two rows at the same instant break on when they were RECORDED — the later assertion wins. */
    @Test fun sameInstantBreaksOnRecordedAt() {
        val first = entry("first", behaviorId = "caffeine", kind = BehaviorValueKind.COUNT, value = 1.0, occurredAt = at, recordedAt = at)
        val corrected = entry("second", behaviorId = "caffeine", kind = BehaviorValueKind.COUNT, value = 2.0, occurredAt = at, recordedAt = at + 5_000)
        val chip = JournalDayBuilder.chips(dictionary, listOf(first, corrected)).first { it.id == "caffeine" }
        assertEquals("second", chip.entry!!.id)
    }

    @Test fun tombstonedRowsNeverLightAChip() {
        val chips = JournalDayBuilder.chips(dictionary, listOf(entry("gone", behaviorId = "caffeine", deletedAt = at + 1)))
        assertTrue(chips.none { it.isOn })
    }

    // --- What the amount affordance may do ---

    /**
     * The stepper is offered from the DICTIONARY's shape, never from the stored row: a nap tagged
     * with a plain tap still offers minutes, and a boolean behaviour never does.
     */
    @Test fun onlyCountAndQuantityBehavioursOfferAnAmount() {
        val chips = JournalDayBuilder.chips(dictionary, emptyList()).associateBy { it.id }
        assertFalse(chips["nicotine"]!!.offersAmount)
        assertTrue(chips["caffeine"]!!.offersAmount)
        assertTrue(chips["nap"]!!.offersAmount)
    }

    /** Minutes step in fives (a nap is not timed to the minute); counts step in ones. */
    @Test fun stepSizeMatchesWhatTheBehaviourMeasures() {
        val chips = JournalDayBuilder.chips(dictionary, emptyList()).associateBy { it.id }
        assertEquals(1.0, chips["caffeine"]!!.amountStep, 1e-9)
        assertEquals(5.0, chips["nap"]!!.amountStep, 1e-9)
    }

    /** A count counts the behaviour itself, so it carries no physical unit — 2 coffees is just 2. */
    @Test fun onlyAQuantityCarriesAUnit() {
        val chips = JournalDayBuilder.chips(dictionary, emptyList()).associateBy { it.id }
        assertNull(chips["caffeine"]!!.amountUnit)
        assertEquals(JournalStrings.minutes, chips["nap"]!!.amountUnit)
    }

    // --- Custom tags and the day count ---

    @Test fun customTagsAreListedApartFromTheChips() {
        val rows = listOf(
            entry("c1", customLabel = "sauna at the gym", occurredAt = at),
            entry("c2", customLabel = "long drive", occurredAt = at + 60_000),
            entry("b1", behaviorId = "caffeine"),
        )
        val custom = JournalDayBuilder.customEntries(rows)
        assertEquals(listOf("c2", "c1"), custom.map { it.id })
        assertTrue(JournalDayBuilder.chips(dictionary, rows).none { it.entry?.customLabel != null })
    }

    @Test fun taggedCountAddsChipsAndOwnTags() {
        val rows = listOf(entry("b1", behaviorId = "caffeine"), entry("c1", customLabel = "long drive"))
        val chips = JournalDayBuilder.chips(dictionary, rows)
        assertEquals(2, JournalDayBuilder.taggedCount(chips, JournalDayBuilder.customEntries(rows)))
        assertEquals(0, JournalDayBuilder.taggedCount(JournalDayBuilder.chips(dictionary, emptyList()), emptyList()))
    }

    // --- Day choice ---

    @Test fun yesterdayIsTheRecallPathAndTodayIsNot() {
        assertEquals(listOf(JournalDayChoice.TODAY, JournalDayChoice.YESTERDAY), JournalDayChoice.entries.toList())
        assertFalse(JournalDayChoice.TODAY.isRecall)
        assertTrue(JournalDayChoice.YESTERDAY.isRecall)
        assertEquals(at, JournalDayChoice.TODAY.occurredAt(at, "UTC"))
        assertEquals("أمس", JournalDayChoice.YESTERDAY.displayName.resolved(AppLanguage.AR))
    }

    /** Calendar arithmetic, not a fixed 86 400 000 — a DST boundary would file it under the wrong day. */
    @Test fun yesterdayIsTheSameWallClockTimeOnThePreviousLocalDay() {
        // 2026-03-29 is the European DST spring-forward; the previous local day is 23 hours long.
        val zone = "Europe/London"
        val noonAfterTheShift = java.time.ZonedDateTime
            .of(2026, 3, 29, 12, 0, 0, 0, java.time.ZoneId.of(zone))
            .toInstant().toEpochMilli()
        val yesterday = JournalDayChoice.YESTERDAY.occurredAt(noonAfterTheShift, zone)
        val local = java.time.Instant.ofEpochMilli(yesterday).atZone(java.time.ZoneId.of(zone))
        assertEquals(28, local.dayOfMonth)
        assertEquals("the wall-clock hour is preserved across the shift", 12, local.hour)
    }

    // --- Copy ---

    /** The §16 trust line for this surface, verbatim, and identical to the iOS copy. */
    @Test fun trustCopyIsTheSixteenSectionLine() {
        assertEquals(
            "Used only on your device to find your patterns.",
            JournalStrings.trust.resolved(AppLanguage.EN),
        )
        assertRealArabic("trust", JournalStrings.trust)
    }

    /**
     * The arm rule has to be on the screen where the tapping happens: `CorrelationEngine` reads an
     * untapped behaviour on a journaled day as a day it did not happen, so silence is evidence.
     */
    @Test fun theUntappedRuleIsStatedOnTheSurface() {
        assertTrue(JournalStrings.untappedNote.en.contains("didn’t happen"))
        assertRealArabic("untappedNote", JournalStrings.untappedNote)
    }

    /** The free-text tag's honest limit, stated where the tag is created. */
    @Test fun ownTagsNoteAdmitsTheyAreNotCorrelated() {
        assertTrue(JournalStrings.ownTagsNote.en.contains("aren’t compared"))
        assertRealArabic("ownTagsNote", JournalStrings.ownTagsNote)
    }

    /**
     * Every category in the SHIPPED dictionary must resolve to authored bilingual copy rather than
     * the raw-key fallback, so a new category in the contract fails this suite instead of shipping as
     * an untranslated heading.
     */
    @Test fun everyShippedCategoryResolvesToAuthoredCopy() {
        assertTrue("behaviors.json must be readable at ${behaviorsFile.absolutePath}", behaviorsFile.exists())
        val root = Json.parseToJsonElement(behaviorsFile.readText()).jsonObject
        val categories = root["behaviors"]!!.jsonArray
            .map { it.jsonObject["category"]!!.jsonPrimitive.content }
            .distinct()
        assertTrue("the dictionary must actually have categories", categories.isNotEmpty())
        for (key in categories) {
            val named = JournalCategory.displayName(key)
            assertTrue("category '$key' has no authored heading", named != null)
            assertRealArabic("category '$key'", named!!)
        }
    }

    @Test fun anUnknownCategoryFallsBackToItsKeyRatherThanDisappearing() {
        assertNull(JournalCategory.displayName("bicycles"))
        assertEquals("bicycles", JournalCategory.heading("bicycles").resolved(AppLanguage.AR))
    }

    @Test fun journalCopyIsBilingualThroughout() {
        listOf(
            "title" to JournalStrings.title,
            "logTile" to JournalStrings.logTile,
            "dayPickerLabel" to JournalStrings.dayPickerLabel,
            "recallNote" to JournalStrings.recallNote,
            "taggedCount" to JournalStrings.taggedCount,
            "nothingTaggedYet" to JournalStrings.nothingTaggedYet,
            "amount" to JournalStrings.amount,
            "minutes" to JournalStrings.minutes,
            "times" to JournalStrings.times,
            "decreaseAmount" to JournalStrings.decreaseAmount,
            "increaseAmount" to JournalStrings.increaseAmount,
            "ownTagsTitle" to JournalStrings.ownTagsTitle,
            "ownTagPlaceholder" to JournalStrings.ownTagPlaceholder,
            "logged" to JournalStrings.logged,
            "notLogged" to JournalStrings.notLogged,
            "saveFailed" to JournalStrings.saveFailed,
            "loadFailed" to JournalStrings.loadFailed,
            "sensitiveOffTitle" to JournalStrings.sensitiveOffTitle,
            "sensitiveOffMessage" to JournalStrings.sensitiveOffMessage,
            "contextTitle" to JournalStrings.contextTitle,
            "contextExplainer" to JournalStrings.contextExplainer,
            "contextStart" to JournalStrings.contextStart,
            "contextOngoing" to JournalStrings.contextOngoing,
            "contextEndNow" to JournalStrings.contextEndNow,
            "contextStarted" to JournalStrings.contextStarted,
            "contextRange" to JournalStrings.contextRange,
            "contextEarlier" to JournalStrings.contextEarlier,
            "contextNoneTitle" to JournalStrings.contextNoneTitle,
            "contextNoneMessage" to JournalStrings.contextNoneMessage,
            "contextCustomPlaceholder" to JournalStrings.contextCustomPlaceholder,
            "contextDelete" to JournalStrings.contextDelete,
        ).forEach { (label, s) -> assertRealArabic(label, s) }
    }

    /** The explainer must promise what `ContextStatus` structurally guarantees: no value changes. */
    @Test fun theContextExplainerPromisesNoNumberChanges() {
        assertTrue(JournalStrings.contextExplainer.en.contains("changes no number"))
    }

    // --- Context statuses ---

    private fun status(id: String, kind: ContextStatusKind?, startAt: Long, endAt: Long? = null, deletedAt: Long? = null) =
        ContextStatus(
            id = id, statusId = kind?.code, startAt = startAt, endAt = endAt, tzId = "UTC",
            provenance = prov(startAt), updatedAt = startAt, originDeviceId = device, deletedAt = deletedAt,
        )

    @Test fun openEndedStatusesAreActiveAndTombstonesAreDropped() {
        val open = status("open", ContextStatusKind.TRAVEL, at)
        val openOlder = status("openOlder", ContextStatusKind.ILLNESS, at - 86_400_000)
        val closed = status("closed", ContextStatusKind.FASTING, at - 172_800_000, endAt = at - 86_400_000)
        val removed = status("removed", ContextStatusKind.INJURY, at, deletedAt = at)

        val list = ContextStatusList.from(listOf(closed, removed, openOlder, open), now = at)
        assertEquals(listOf("open", "openOlder"), list.active.map { it.id })
        assertEquals(listOf("closed"), list.past.map { it.id })
        assertFalse(list.isEmpty)
    }

    /** A status whose end lies ahead of `now` is still being lived through — active, not past. */
    @Test fun anEndDateInTheFutureStillReadsAsActive() {
        val list = ContextStatusList.from(
            listOf(status("future", ContextStatusKind.TRAVEL, at - 1000, endAt = at + 86_400_000)),
            now = at,
        )
        assertEquals(listOf("future"), list.active.map { it.id })
        assertTrue(list.past.isEmpty())
    }

    @Test fun noStatusesIsAnEmptyListNotAnError() {
        assertTrue(ContextStatusList.from(emptyList(), now = at).isEmpty)
    }

    /**
     * Every kind the manager offers must carry a caveat in both languages — an annotation the user
     * cannot see the effect of would be a rule applied behind their back.
     */
    @Test fun everyContextKindExplainsWhatMarkingItDoes() {
        for (kind in ContextStatusKind.entries) {
            assertRealArabic("${kind.code} label", kind.displayLabel)
            assertRealArabic("${kind.code} caveat", kind.caveat)
        }
    }
}
