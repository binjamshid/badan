package net.albayyan.badan

import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.NotificationPreference
import net.albayyan.badan.domain.NotificationQuietHours
import net.albayyan.badan.platform.notifications.NotificationBudget
import net.albayyan.badan.platform.notifications.NotificationClass
import net.albayyan.badan.platform.notifications.NotificationClassCopy
import net.albayyan.badan.platform.notifications.NotificationDecisionEngine
import net.albayyan.badan.platform.notifications.NotificationDeepLink
import net.albayyan.badan.platform.notifications.contains
import net.albayyan.badan.storage.Schema
import net.albayyan.badan.storage.repositories.NotificationDayWindow
import net.albayyan.badan.storage.repositories.NotificationOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-32 acceptance suite, Android half — the mirror of iOS `NotificationDecisionEngineTests`.
 *
 * Scope, stated honestly (the same caveat `HydrationTest` and `ReportsNotificationsMigrationTest`
 * carry): this module has no `androidTest` source set and no Robolectric, so nothing here opens a
 * SQLite database or a `NotificationManager`. The DB-backed ledger behaviour is exercised against a
 * real connection on iOS by `NotificationDeliveryRepositoryTests`; what is verifiable on the JVM is
 * pinned here — the pure decision engine (the ≤2/day budget under load, the per-class opt-in matrix,
 * quiet hours, the shared-ceiling interplay), the day-window arithmetic the budget count is measured
 * over, the storage-code contract with migration v8, and the copy's parity with iOS.
 *
 * The medication-reminder regression suite has no Android counterpart because Android schedules no
 * medication reminders (standing parity debt, documented on `AndroidNotificationScheduler`); the
 * iOS `NotificationSchedulerTests` own that. What IS asserted here is the half that must hold on
 * both platforms regardless: `meds` is budget-exempt and is never suppressed by the shared ceiling.
 */
class NotificationDecisionEngineTest {

    /** A fixed, UTC zone so quiet-hours boundaries are deterministic regardless of the host tz. */
    private val zone: ZoneId = ZoneId.of("UTC")

    private fun at(hour: Int, day: Int = 20): Long =
        ZonedDateTime.of(2026, 7, day, hour, 0, 0, 0, zone).toInstant().toEpochMilli()

    private fun context(
        optedIn: Boolean = true,
        quiet: NotificationQuietHours? = null,
        nonMedToday: Int = 0,
        pendingMed: Int = 0,
        pendingNonMed: Int = 0,
    ) = NotificationDecisionEngine.Context(
        zone = zone,
        optedIn = { optedIn },
        quietHours = { quiet },
        nonMedScheduledToday = nonMedToday,
        pendingMedCount = pendingMed,
        pendingNonMedCount = pendingNonMed,
    )

    private fun candidate(cls: NotificationClass, hour: Int) =
        NotificationDecisionEngine.Candidate(cls, at(hour))

    // MARK: - Registry (the storage-code contract with migration v8 and iOS)

    @Test fun storageCodesMatchMigrationAndIos() {
        assertEquals("readiness", NotificationClass.MORNING_READINESS_SUMMARY.code)
        assertEquals("windDown", NotificationClass.EVENING_WIND_DOWN.code)
        assertEquals("deviation", NotificationClass.DEVIATION_NOTICE.code)
        assertEquals("exportHealth", NotificationClass.EXPORT_HEALTH_ALERT.code)
        assertEquals("hydration", NotificationClass.HYDRATION.code)
        assertEquals("meds", NotificationClass.MEDS.code)
    }

    /**
     * The ledger the codes are written into exists, and its discriminator is the non-reserved column
     * name. The v8 schema deliberately does NOT pin the class vocabulary (it is EPIC-32's, not the
     * schema's — see `ReportsNotificationsMigrationTest`), so this asserts the column, not the enum.
     */
    @Test fun theLedgerTheCodesAreWrittenIntoExists() {
        val v8 = Schema.mainMigrations.first { it.version == 8 }.statements.joinToString("\n")
        assertTrue(v8.contains("CREATE TABLE notification_deliveries"))
        assertTrue(v8.contains("notification_class TEXT NOT NULL"))
    }

    @Test fun medsIsTheOnlyBudgetExemptClass() {
        assertFalse(NotificationClass.MEDS.countsAgainstDailyBudget)
        for (cls in NotificationClass.entries.filter { it != NotificationClass.MEDS }) {
            assertTrue("$cls must count against the ≤2/day budget", cls.countsAgainstDailyBudget)
        }
    }

    /**
     * Channel ids are user-visible state (the importance and sound a user sets survive under the id),
     * so they must be stable, unique per class, and derived from the storage code — renaming one
     * silently resets the user's per-channel choices.
     */
    @Test fun channelIdsAreStableUniqueAndDerivedFromTheStorageCode() {
        val ids = NotificationClass.entries.map { it.channelId }
        assertEquals("one channel per class, no collisions", ids.size, ids.toSet().size)
        for (cls in NotificationClass.entries) {
            assertEquals("badan.notif.${cls.code}", cls.channelId)
        }
    }

    /**
     * Every non-med work tag carries the shared `decision.` prefix so the engine can cancel its own
     * work without ever touching the EPIC-15 automation-pause notice or the sync work.
     */
    @Test fun workTagsShareTheDecisionPrefixAndAreUnique() {
        val tags = NotificationClass.entries.map { it.workTag }
        assertEquals(tags.size, tags.toSet().size)
        for (cls in NotificationClass.entries) {
            assertTrue("$cls work tag must be namespaced", cls.workTag.startsWith(NotificationClass.DECISION_PREFIX))
        }
    }

    /** Every class deep-links somewhere, and the codes round-trip through the intent extra. */
    @Test fun everyClassHasARoundTrippableDeepLink() {
        for (cls in NotificationClass.entries) {
            val link = cls.deepLink
            assertEquals(link, NotificationDeepLink.fromCode(link.code))
        }
        assertNull("an unknown code must not resolve to a default surface", NotificationDeepLink.fromCode("nope"))
        assertNull(NotificationDeepLink.fromCode(null))
    }

    /**
     * Every toggle the settings surface offers must correspond to a notification the app can
     * actually send. A toggle whose copy says "a heads-up when a reading drifts from your usual" is
     * a promise; offering it with no producer behind it is a lie the user cannot detect, because the
     * failure mode is silence — indistinguishable from "nothing drifted."
     *
     * The only producer today is the time-based reconcile loop, so `userFacing == timeBased` exactly.
     * `MEDS` (no Android delivery at all) and the two event-driven classes (registered for the
     * ledger vocabulary and their deep links, but raised by nothing) are all correctly absent.
     *
     * When a deviation detector or export-health producer lands and calls `raiseDecisionNotification`,
     * this assertion moves in the same change that adds the toggle — deliberately, never silently.
     */
    @Test fun everyUserFacingClassHasAProducerBehindIt() {
        assertEquals(
            "a class may be offered in Settings only once something schedules it",
            NotificationClass.timeBased.toSet(),
            NotificationClass.userFacing.toSet(),
        )
        assertFalse("Android schedules no medication reminders — no toggle may claim otherwise",
            NotificationClass.userFacing.contains(NotificationClass.MEDS))
        for (cls in listOf(NotificationClass.DEVIATION_NOTICE, NotificationClass.EXPORT_HEALTH_ALERT)) {
            assertFalse("$cls has no producer — a toggle would promise a notice that never arrives",
                NotificationClass.userFacing.contains(cls))
        }
        // Still true, and still worth pinning: nothing unbudgeted sneaks onto the surface.
        assertTrue("every offered class must count against the ≤2/day budget",
            NotificationClass.userFacing.all { it.countsAgainstDailyBudget })
    }

    // MARK: - Opt-in matrix (defaults ALL OFF)

    /** The shipped default: an untouched profile has every class off. */
    @Test fun everyClassDefaultsOff() {
        val prefs = NotificationPreference()
        assertTrue("classOptIn must ship empty — a missing key is OFF", prefs.classOptIn.isEmpty())
        assertFalse("meds keeps its own preference, and it ships off too", prefs.medicationReminders)
        for (cls in NotificationClass.entries.filter { it != NotificationClass.MEDS }) {
            assertFalse("$cls must default OFF", prefs.classOptIn[cls.code] ?: false)
        }
    }

    @Test fun optedOutClassIsSuppressed() {
        assertEquals(
            NotificationDecisionEngine.Decision.SUPPRESSED_OPTED_OUT,
            NotificationDecisionEngine.decide(candidate(NotificationClass.MORNING_READINESS_SUMMARY, 8),
                context(optedIn = false)),
        )
    }

    /**
     * Every non-med class, toggled independently, is scheduled when on and suppressed when off —
     * nothing leaks across classes.
     */
    @Test fun perClassOptInMatrix() {
        for (cls in NotificationClass.entries.filter { it != NotificationClass.MEDS }) {
            assertEquals("$cls on must schedule",
                NotificationDecisionEngine.Decision.SCHEDULED,
                NotificationDecisionEngine.decide(candidate(cls, 12), context(optedIn = true)))
            assertEquals("$cls off must suppress",
                NotificationDecisionEngine.Decision.SUPPRESSED_OPTED_OUT,
                NotificationDecisionEngine.decide(candidate(cls, 12), context(optedIn = false)))
        }
    }

    // MARK: - Daily budget (≤2/day, held under load)

    @Test fun dailyBudgetHoldsUnderLoad() {
        // 100 candidates in one day, all opted in, no quiet hours: exactly the ceiling is scheduled.
        val candidates = List(100) { candidate(NotificationClass.HYDRATION, 12) }
        val results = NotificationDecisionEngine.decideBatch(candidates, context(optedIn = true))
        assertEquals(
            NotificationBudget.DAILY_NON_MED_LIMIT,
            results.count { it.second == NotificationDecisionEngine.Decision.SCHEDULED },
        )
        assertTrue(
            "every candidate past the ceiling must be budget-suppressed, not silently dropped",
            results.drop(NotificationBudget.DAILY_NON_MED_LIMIT)
                .all { it.second == NotificationDecisionEngine.Decision.SUPPRESSED_DAILY_BUDGET },
        )
    }

    @Test fun budgetSpansAllNonMedClassesCombined() {
        // The budget is a combined non-med ceiling, not per-class: morning + wind-down spends it,
        // and a third class (hydration) is then held.
        val results = NotificationDecisionEngine.decideBatch(
            listOf(
                candidate(NotificationClass.MORNING_READINESS_SUMMARY, 8),
                candidate(NotificationClass.EVENING_WIND_DOWN, 21),
                candidate(NotificationClass.HYDRATION, 15),
            ),
            context(),
        )
        assertEquals(NotificationDecisionEngine.Decision.SCHEDULED, results[0].second)
        assertEquals(NotificationDecisionEngine.Decision.SCHEDULED, results[1].second)
        assertEquals(NotificationDecisionEngine.Decision.SUPPRESSED_DAILY_BUDGET, results[2].second)
    }

    /**
     * The budget is a HARD invariant, not a preference: the ceiling is 2 and there is no per-user
     * override anywhere in the shipped path. Pinned as a constant so raising it is a deliberate,
     * reviewable change rather than a quiet tweak.
     */
    @Test fun theDailyCeilingIsTwoAndIsSharedWithIos() {
        assertEquals(2, NotificationBudget.DAILY_NON_MED_LIMIT)
        assertEquals(64, NotificationBudget.SYSTEM_PENDING_LIMIT)
    }

    @Test fun medsAreExemptFromTheDailyBudget() {
        // Even with the non-med budget fully spent, a med candidate is never budget-suppressed.
        assertEquals(
            NotificationDecisionEngine.Decision.SCHEDULED,
            NotificationDecisionEngine.decide(candidate(NotificationClass.MEDS, 8), context(nonMedToday = 99)),
        )
    }

    /** A batch of meds never consumes a non-med slot, so a following non-med candidate still fits. */
    @Test fun medsInABatchNeverSpendTheNonMedBudget() {
        val results = NotificationDecisionEngine.decideBatch(
            listOf(
                candidate(NotificationClass.MEDS, 8),
                candidate(NotificationClass.MEDS, 9),
                candidate(NotificationClass.MEDS, 10),
                candidate(NotificationClass.HYDRATION, 15),
            ),
            context(),
        )
        assertTrue(results.all { it.second == NotificationDecisionEngine.Decision.SCHEDULED })
    }

    // MARK: - Quiet hours

    @Test fun quietHoursSuppressesInsideTheWindow() {
        val quiet = NotificationQuietHours(startHour = 22, endHour = 7)   // wraps midnight
        assertEquals(
            NotificationDecisionEngine.Decision.SUPPRESSED_QUIET_HOURS,
            NotificationDecisionEngine.decide(candidate(NotificationClass.HYDRATION, 2), context(quiet = quiet)),
        )
        assertEquals(
            NotificationDecisionEngine.Decision.SCHEDULED,
            NotificationDecisionEngine.decide(candidate(NotificationClass.HYDRATION, 12), context(quiet = quiet)),
        )
    }

    @Test fun quietHoursBoundariesAndEmptyWindow() {
        val q = NotificationQuietHours(startHour = 22, endHour = 7)
        assertTrue("start is inclusive", q.contains(at(22), zone))
        assertTrue(q.contains(at(6), zone))
        assertFalse("end is exclusive", q.contains(at(7), zone))
        assertFalse(q.contains(at(12), zone))
        // A collapsed window means "no quiet hours", never "always quiet".
        val empty = NotificationQuietHours(startHour = 9, endHour = 9)
        assertFalse(empty.contains(at(9), zone))
        // A non-wrapping window behaves the same way at both edges.
        val day = NotificationQuietHours(startHour = 9, endHour = 17)
        assertTrue(day.contains(at(9), zone))
        assertTrue(day.contains(at(16), zone))
        assertFalse(day.contains(at(17), zone))
        assertFalse(day.contains(at(8), zone))
    }

    /** The shipped default is a night window, so a brand-new opt-in never lands at 3am. */
    @Test fun defaultQuietHoursIsTheNightWindow() {
        assertEquals(22, NotificationQuietHours.defaultNight.startHour)
        assertEquals(7, NotificationQuietHours.defaultNight.endHour)
        assertEquals(NotificationQuietHours.defaultNight, NotificationPreference().quietHours)
    }

    /**
     * The trap this guards: a time-based class whose DEFAULT fire hour sits inside the DEFAULT
     * quiet-hours window can never fire, so a user who opts it in gets silence and nothing anywhere
     * says why. Every other test here supplies its own hour and its own window, so none of them
     * compares the two DEFAULTS — moving the wind-down to 22:00, or widening the night window to
     * start at 21:00, would ship a permanently silent toggle with the whole suite still green.
     *
     * Iterates the real [NotificationClass.timeBased] list (not a copy), and asserts the fallback
     * branch of [NotificationClass.defaultHour] too, so a class added to that list later is safe by
     * default even before someone remembers to extend this test.
     */
    @Test fun defaultFireHoursFallOutsideTheDefaultQuietWindow() {
        val night = NotificationQuietHours.defaultNight
        for (cls in NotificationClass.timeBased) {
            val hour = NotificationClass.defaultHour(cls)
            assertFalse(
                "$cls defaults to $hour:00, inside the default quiet window — an opted-in user could never receive it",
                night.contains(at(hour), zone),
            )
        }
        assertFalse(
            "the fallback default hour is inside the default quiet window",
            night.contains(at(NotificationClass.defaultHour(NotificationClass.DEVIATION_NOTICE)), zone),
        )
    }

    // MARK: - Shared-ceiling interplay (meds never starved)

    @Test fun medPendingLimitReservesRoomForNonMed() {
        assertEquals(
            "with nothing non-med pending, meds keep the full 64 — no regression",
            NotificationBudget.SYSTEM_PENDING_LIMIT,
            NotificationDecisionEngine.medPendingLimit(nonMedPending = 0),
        )
        assertEquals(
            NotificationBudget.SYSTEM_PENDING_LIMIT - 2,
            NotificationDecisionEngine.medPendingLimit(nonMedPending = 2),
        )
        assertEquals("the med limit never goes negative", 0,
            NotificationDecisionEngine.medPendingLimit(nonMedPending = 999))
    }

    @Test fun medsAndNonMedNeverExceedTheCeilingTogether() {
        for (nonMed in 0..NotificationBudget.DAILY_NON_MED_LIMIT) {
            val medCap = NotificationDecisionEngine.medPendingLimit(nonMedPending = nonMed)
            assertTrue(
                "meds + non-med must never exceed the shared ceiling",
                medCap + nonMed <= NotificationBudget.SYSTEM_PENDING_LIMIT,
            )
        }
    }

    @Test fun medsAreNeverStarvedByNonMed() {
        // At the very most the non-med budget can put 2 notices pending. Meds still keep 62 of 64 —
        // and the iOS med cap keeps the SOONEST reminders, so this is not starvation.
        val medCap = NotificationDecisionEngine.medPendingLimit(nonMedPending = NotificationBudget.DAILY_NON_MED_LIMIT)
        assertEquals(62, medCap)
        assertTrue(medCap >= NotificationBudget.SYSTEM_PENDING_LIMIT - NotificationBudget.DAILY_NON_MED_LIMIT)
    }

    @Test fun nonMedYieldsWhenTheCeilingIsFull() {
        // Meds fill the ceiling: a non-med candidate is capped out. Meds win — never evicted.
        assertEquals(
            NotificationDecisionEngine.Decision.SUPPRESSED_SYSTEM_CAP,
            NotificationDecisionEngine.decide(
                candidate(NotificationClass.MORNING_READINESS_SUMMARY, 8),
                context(pendingMed = NotificationBudget.SYSTEM_PENDING_LIMIT, pendingNonMed = 0),
            ),
        )
    }

    @Test fun nonMedTakesAFreeSlotBelowTheCeiling() {
        assertEquals(
            NotificationDecisionEngine.Decision.SCHEDULED,
            NotificationDecisionEngine.decide(
                candidate(NotificationClass.HYDRATION, 12),
                context(pendingMed = 60, pendingNonMed = 1),   // 61 pending < 64
            ),
        )
    }

    @Test fun medsAreNeverSuppressedByTheSystemCap() {
        // A meds candidate is exempt from the cap check entirely (its own path caps itself).
        assertEquals(
            NotificationDecisionEngine.Decision.SCHEDULED,
            NotificationDecisionEngine.decide(
                candidate(NotificationClass.MEDS, 8),
                context(pendingMed = NotificationBudget.SYSTEM_PENDING_LIMIT, pendingNonMed = 5),
            ),
        )
    }

    /**
     * The batch path must respect the ceiling too, not just the daily budget: with one slot left,
     * one candidate fits and the next is cap-suppressed rather than silently over-committing.
     */
    @Test fun batchRespectsTheSharedCeilingAsItAccepts() {
        val results = NotificationDecisionEngine.decideBatch(
            listOf(candidate(NotificationClass.HYDRATION, 12), candidate(NotificationClass.DEVIATION_NOTICE, 13)),
            context(pendingMed = NotificationBudget.SYSTEM_PENDING_LIMIT - 1, pendingNonMed = 0),
        )
        assertEquals(NotificationDecisionEngine.Decision.SCHEDULED, results[0].second)
        assertEquals(NotificationDecisionEngine.Decision.SUPPRESSED_SYSTEM_CAP, results[1].second)
    }

    // MARK: - Decision order

    @Test fun decisionOrderOptOutThenQuietThenBudgetThenCap() {
        val quietAllDay = NotificationQuietHours(startHour = 0, endHour = 23)
        // Opt-out wins over everything.
        assertEquals(
            NotificationDecisionEngine.Decision.SUPPRESSED_OPTED_OUT,
            NotificationDecisionEngine.decide(
                candidate(NotificationClass.HYDRATION, 3),
                context(optedIn = false, quiet = quietAllDay, nonMedToday = 99, pendingMed = 64),
            ),
        )
        // Quiet hours wins over budget + cap.
        assertEquals(
            NotificationDecisionEngine.Decision.SUPPRESSED_QUIET_HOURS,
            NotificationDecisionEngine.decide(
                candidate(NotificationClass.HYDRATION, 3),
                context(optedIn = true, quiet = quietAllDay, nonMedToday = 99, pendingMed = 64),
            ),
        )
        // Budget wins over cap.
        assertEquals(
            NotificationDecisionEngine.Decision.SUPPRESSED_DAILY_BUDGET,
            NotificationDecisionEngine.decide(
                candidate(NotificationClass.HYDRATION, 12),
                context(optedIn = true, quiet = null,
                    nonMedToday = NotificationBudget.DAILY_NON_MED_LIMIT, pendingMed = 64),
            ),
        )
    }

    /**
     * `SUPPRESSED_NOT_AUTHORIZED` and `SUPPRESSED_LEDGER_UNAVAILABLE` are ADAPTER verdicts —
     * permission and storage are I/O facts the pure engine is never handed, so
     * [NotificationDecisionEngine.decide] must never invent either. One case per branch the engine
     * can actually take (schedule, opt-out, quiet, budget, cap), which is every path that can
     * produce a verdict at all.
     */
    @Test fun thePureEngineNeverClaimsNotAuthorized() {
        val quietAllDay = NotificationQuietHours(startHour = 0, endHour = 23)
        val cases = listOf(
            context(),                                                       // -> SCHEDULED
            context(optedIn = false),                                        // -> OPTED_OUT
            context(quiet = quietAllDay),                                    // -> QUIET_HOURS
            context(nonMedToday = NotificationBudget.DAILY_NON_MED_LIMIT),   // -> DAILY_BUDGET
            context(pendingMed = NotificationBudget.SYSTEM_PENDING_LIMIT),   // -> SYSTEM_CAP
        )
        val seen = mutableSetOf<NotificationDecisionEngine.Decision>()
        for (ctx in cases) {
            for (cls in NotificationClass.entries) {
                val decision = NotificationDecisionEngine.decide(candidate(cls, 3), ctx)
                assertFalse(
                    "the pure engine cannot see permission state",
                    decision == NotificationDecisionEngine.Decision.SUPPRESSED_NOT_AUTHORIZED,
                )
                assertFalse(
                    "the pure engine cannot see storage state",
                    decision == NotificationDecisionEngine.Decision.SUPPRESSED_LEDGER_UNAVAILABLE,
                )
                seen.add(decision)
            }
        }
        // The sweep is only meaningful if it actually reached every non-adapter verdict.
        assertEquals(
            setOf(
                NotificationDecisionEngine.Decision.SCHEDULED,
                NotificationDecisionEngine.Decision.SUPPRESSED_OPTED_OUT,
                NotificationDecisionEngine.Decision.SUPPRESSED_QUIET_HOURS,
                NotificationDecisionEngine.Decision.SUPPRESSED_DAILY_BUDGET,
                NotificationDecisionEngine.Decision.SUPPRESSED_SYSTEM_CAP,
            ),
            seen,
        )
    }

    // MARK: - The day window the budget is counted over

    /**
     * `[start, end)` over the LOCAL day, which is what makes the ≤2/day ceiling mean "per day the
     * user lived", not "per UTC day". Riyadh is UTC+3 with no DST, so a 00:00 local boundary is a
     * 21:00-the-previous-day UTC instant — the off-by-one this pins.
     */
    @Test fun dayWindowIsTheLocalDayHalfOpen() {
        val riyadh = ZoneId.of("Asia/Riyadh")
        val noon = ZonedDateTime.of(2026, 7, 20, 12, 0, 0, 0, riyadh).toInstant().toEpochMilli()
        val (start, end) = NotificationDayWindow.bounds(noon, riyadh)
        assertEquals(ZonedDateTime.of(2026, 7, 20, 0, 0, 0, 0, riyadh).toInstant().toEpochMilli(), start)
        assertEquals(ZonedDateTime.of(2026, 7, 21, 0, 0, 0, 0, riyadh).toInstant().toEpochMilli(), end)
        assertTrue(start <= noon && noon < end)
        // The boundary instant itself belongs to the NEXT day, never to both.
        val (nextStart, _) = NotificationDayWindow.bounds(end, riyadh)
        assertEquals(end, nextStart)
    }

    /**
     * A DST day is 23 or 25 hours long, and the window must be exactly that — computed from the
     * calendar, never as `start + 86_400_000`. A 24h-arithmetic window would leak an hour of the
     * neighbouring day into the budget count twice a year.
     */
    @Test fun dayWindowHandlesDstTransitions() {
        val berlin = ZoneId.of("Europe/Berlin")
        val springForward = ZonedDateTime.of(2026, 3, 29, 12, 0, 0, 0, berlin).toInstant().toEpochMilli()
        val (s1, e1) = NotificationDayWindow.bounds(springForward, berlin)
        assertEquals("a spring-forward day is 23 hours", 23L * 3_600_000L, e1 - s1)

        val fallBack = ZonedDateTime.of(2026, 10, 25, 12, 0, 0, 0, berlin).toInstant().toEpochMilli()
        val (s2, e2) = NotificationDayWindow.bounds(fallBack, berlin)
        assertEquals("a fall-back day is 25 hours", 25L * 3_600_000L, e2 - s2)
    }

    // MARK: - Ledger outcome vocabulary

    /** The four outcome codes migration v8 documents, and the unknown-code fallback. */
    @Test fun outcomeCodesMatchTheMigrationVocabulary() {
        assertEquals(
            listOf("scheduled", "delivered", "suppressed", "cancelled"),
            NotificationOutcome.entries.map { it.code },
        )
        assertEquals(NotificationOutcome.SCHEDULED, NotificationOutcome.fromCode("nope"))
        assertEquals(NotificationOutcome.SCHEDULED, NotificationOutcome.fromCode(null))
    }

    // MARK: - Copy (privacy + wellness-safe register)

    @Test fun copyIsPresentInBothLanguagesAndCarriesNoTokens() {
        for (cls in NotificationClass.entries) {
            val (title, body) = NotificationClassCopy.content(cls)
            val (label, hint) = NotificationClassCopy.settingsRow(cls)
            for (s in listOf(title.en, title.ar, body.en, body.ar, label.en, label.ar, hint.en, hint.ar)) {
                assertTrue("$cls copy must exist in both languages", s.isNotEmpty())
                assertFalse("$cls copy must not interpolate dynamic (leakable) data", s.contains("{"))
                assertFalse(s.contains("}"))
            }
            // Arabic must actually be Arabic, not an English string copied across.
            assertTrue("$cls Arabic body must be written in Arabic script", body.ar.any { it in ARABIC_RANGE })
            assertTrue("$cls Arabic label must be written in Arabic script", label.ar.any { it in ARABIC_RANGE })
            assertFalse("$cls Arabic body must not be the English string", body.ar == body.en)
        }
        for (s in listOf(
            NotificationClassCopy.dailyBudgetNote(arabicDigits = false),
            NotificationClassCopy.schedulingHonestyNote,
            NotificationClassCopy.systemOffNote, NotificationClassCopy.permissionDeniedNote,
            NotificationClassCopy.sectionHeader, NotificationClassCopy.medsNotOnAndroidNote,
        )) {
            assertTrue(s.en.isNotEmpty())
            assertTrue(s.ar.any { it in ARABIC_RANGE })
        }
    }

    /**
     * (D-11) The delivered body is the part that shows on a lock screen, so it must stay calm: no
     * clinical or alarming vocabulary, and no imperative about training. A shifted reading is
     * "a little different", never "abnormal".
     */
    @Test fun deliveredCopyStaysInsideTheWellnessRegister() {
        val banned = listOf(
            "abnormal", "critical", "danger", "diagnos", "disease", "urgent", "warning", "alarm",
            "risk", "symptom", "unhealthy", "bad ", "must ", "do not train", "don't train",
        )
        for (cls in NotificationClass.entries) {
            val body = NotificationClassCopy.content(cls).second.en.lowercase()
            for (term in banned) {
                assertFalse("$cls body must not say '$term': \"$body\"", body.contains(term))
            }
        }
    }

    /** A notification body must never carry a number — that is how a health value leaks to a lock screen. */
    @Test fun deliveredCopyCarriesNoDigits() {
        for (cls in NotificationClass.entries) {
            val (title, body) = NotificationClassCopy.content(cls)
            for (s in listOf(title.en, title.ar, body.en, body.ar)) {
                assertFalse("$cls notification copy must carry no digits: \"$s\"", s.any { it.isDigit() })
            }
        }
    }

    @Test fun copyResolvesPerLanguage() {
        val (_, body) = NotificationClassCopy.content(NotificationClass.HYDRATION)
        assertEquals(body.en, body.resolved(AppLanguage.EN))
        assertEquals(body.ar, body.resolved(AppLanguage.AR))
    }

    /**
     * Arabic 2 takes the DUAL, not the plural. The budget note used to read "يرسل «بدن» 2 إشعارات":
     * the 3–10 plural with a Latin digit in front of it, wrong twice over in a language the app
     * treats as first-order. It now goes through the same `ReportPresentation.countedNoun` machinery
     * (dual slot included) that every other counted noun in the app uses, so the noun form follows
     * the number instead of being frozen at the plural.
     *
     * The digit-shape half of that machinery — that the count is rendered through `Numerals` rather
     * than interpolated raw — is pinned by `ReportRendererTest.countedNounFormatsItsNumberThroughNumerals`;
     * it cannot be re-asserted here, because at the shipped limit of 2 the Arabic dual carries the
     * number itself and no numeral is emitted at all. That absence is what the digit assertion below
     * checks. Mirror of iOS `testDailyBudgetNoteUsesTheArabicDual`.
     */
    @Test fun dailyBudgetNoteUsesTheArabicDual() {
        assertEquals(
            "this test is about the dual specifically — a changed limit needs the forms re-checked",
            2, NotificationBudget.DAILY_NON_MED_LIMIT,
        )
        val note = NotificationClassCopy.dailyBudgetNote(arabicDigits = false)
        assertTrue("Arabic 2 is the dual إشعارين", note.ar.contains("إشعارين"))
        assertFalse("the 3–10 plural must not be used for 2", note.ar.contains("إشعارات"))
        assertFalse(
            "the dual carries the two itself — no numeral belongs in front of it",
            note.ar.any { it.isDigit() },
        )
        assertTrue("English pluralises and keeps the numeral", note.en.contains("2 notifications"))
        // The Arabic-digit preference must not change the dual (there is no numeral to reshape).
        assertEquals(note.ar, NotificationClassCopy.dailyBudgetNote(arabicDigits = true).ar)
    }

    // MARK: - Cross-platform parity with the iOS source

    /**
     * The Kotlin copy's doc comment claims it is byte-identical to iOS `NotificationClassCopy`. This
     * is what makes that a checked statement rather than an assertion: every delivered body string,
     * in both languages, is looked for verbatim in the Swift source. A one-sided copy edit — the
     * ordinary way two platforms drift — fails here naming the string.
     *
     * Skipped (rather than failed) when the iOS tree is not checked out beside this one, so the
     * Android suite still runs in an Android-only checkout; CI always has both.
     */
    @Test fun deliveredCopyIsByteIdenticalToIos() {
        val swift = File(IOS_ENGINE_PATH)
        if (!swift.exists()) return
        val source = swift.readText()
        for (cls in NotificationClass.entries) {
            if (cls == NotificationClass.MEDS) continue   // iOS routes meds through MedicationReminderCopy
            val (_, body) = NotificationClassCopy.content(cls)
            assertTrue("iOS is missing the English $cls body — copy has drifted: \"${body.en}\"",
                source.contains(body.en))
            assertTrue("iOS is missing the Arabic $cls body — copy has drifted: \"${body.ar}\"",
                source.contains(body.ar))
        }
    }

    /**
     * The storage codes and the two hard limits are the contract the two platforms share; a change on
     * one side without the other is a schema/behaviour divergence, not a refactor.
     */
    @Test fun registryAndLimitsMatchTheIosSource() {
        val swift = File(IOS_ENGINE_PATH)
        if (!swift.exists()) return
        val source = swift.readText()
        for (cls in NotificationClass.entries) {
            assertTrue("iOS must register the '${cls.code}' class", source.contains("\"${cls.code}\""))
        }
        assertTrue("iOS must hold the same ≤2/day ceiling",
            source.contains("dailyNonMedLimit = ${NotificationBudget.DAILY_NON_MED_LIMIT}"))
        for (link in NotificationDeepLink.entries) {
            assertTrue("iOS must carry the '${link.code}' deep link", source.contains("case ${link.code}"))
        }
        assertNotNull(NotificationClass.fromCode("readiness"))
    }

    private companion object {
        /** Arabic (0600–06FF) plus the presentation forms the copy uses (»«, ـ). */
        val ARABIC_RANGE = '؀'..'ۿ'

        /** Test working directory is `apps/android/app`, so `../../ios` is the iOS tree. */
        const val IOS_ENGINE_PATH =
            "../../ios/Sources/Platform/Notifications/NotificationDecisionEngine.swift"
    }
}
