package net.albayyan.badan

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.features.hydration.HydrationFavorite
import net.albayyan.badan.features.hydration.HydrationProgress
import net.albayyan.badan.features.hydration.HydrationStrings
import net.albayyan.badan.features.hydration.HydrationTodayState
import net.albayyan.badan.features.hydration.HydrationWeek
import net.albayyan.badan.features.hydration.HydrationWeekDay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-38 — the hydration surface's PURE presentation logic, the view-independent half the Compose
 * screens delegate to. Like `HealthMonitorPresentationTest`, this pins the calm-progress mapping and
 * the anti-nag copy on the JVM (no Robolectric); the DB-backed data layer is exercised on iOS by
 * `HydrationTests` and the Android ledger/goal core by `HydrationTest`.
 *
 * The through-line under test is §7A.1: no-goal is an equal-status state that never becomes a
 * percentage-of-nothing, an over-target day never turns into an alarm, and the weekly wording is an
 * observation ("logged on N of 7 days"), never a streak.
 */
class HydrationSurfacePresentationTest {

    private fun manualGoal(targetMl: Double?): HydrationGoal = HydrationGoal(
        id = "g", kind = HydrationGoalKind.MANUAL, targetMl = targetMl, dayType = null,
        active = true, createdAt = 0L, updatedAt = 0L, originDeviceId = "d",
    )

    private fun noGoal(): HydrationGoal = HydrationGoal.noGoal(
        id = "g", createdAt = 0L, updatedAt = 0L, originDeviceId = "d",
    )

    // --- Progress: no-goal is equal-status, never a percentage-of-nothing ---

    @Test fun nullGoalResolvesToNoGoalProgress() {
        val p = HydrationProgress.of(totalMl = 1250.0, goal = null)
        assertTrue(p is HydrationProgress.NoGoal)
        assertEquals(1250.0, p.totalMl, 1e-9)
    }

    @Test fun noneGoalResolvesToNoGoalProgress() {
        val p = HydrationProgress.of(totalMl = 1250.0, goal = noGoal())
        assertTrue("a NONE goal must never fabricate a target", p is HydrationProgress.NoGoal)
    }

    @Test fun manualGoalWithoutPositiveTargetIsNoGoal() {
        assertTrue(HydrationProgress.of(500.0, manualGoal(0.0)) is HydrationProgress.NoGoal)
        assertTrue(HydrationProgress.of(500.0, manualGoal(null)) is HydrationProgress.NoGoal)
    }

    // --- Progress: a real target gives a gentle, capped bar that never alarms when exceeded ---

    @Test fun manualGoalUnderTargetHasProportionalBar() {
        val p = HydrationProgress.of(totalMl = 1000.0, goal = manualGoal(2000.0))
        assertTrue(p is HydrationProgress.WithGoal)
        p as HydrationProgress.WithGoal
        assertEquals(2000.0, p.targetMl, 1e-9)
        assertEquals(0.5, p.fraction, 1e-9)
        assertEquals(0.5f, p.barFraction, 1e-6f)
    }

    @Test fun overTargetKeepsRawFractionButCapsTheBar() {
        val p = HydrationProgress.of(totalMl = 2500.0, goal = manualGoal(2000.0)) as HydrationProgress.WithGoal
        assertEquals(1.25, p.fraction, 1e-9)     // the honest number is preserved
        assertEquals(1.0f, p.barFraction, 1e-6f) // ...but the bar never overflows into "you failed"
    }

    // --- Today state delegates to the same progress rule ---

    @Test fun todayStateProgressDelegates() {
        val withGoal = HydrationTodayState(entries = emptyList(), totalMl = 800.0, goal = manualGoal(1600.0), favorites = emptyList())
        assertTrue(withGoal.progress is HydrationProgress.WithGoal)
        val without = HydrationTodayState(entries = emptyList(), totalMl = 800.0, goal = noGoal(), favorites = emptyList())
        assertTrue(without.progress is HydrationProgress.NoGoal)
    }

    // --- Favorites: curated defaults are always present and never absent ---

    @Test fun defaultFavoritesAreTwoBuiltinWaterSizes() {
        val defaults = HydrationFavorite.defaults
        assertEquals(2, defaults.size)
        assertTrue(defaults.all { it.isBuiltin })
        assertEquals(setOf(250.0, 500.0), defaults.map { it.volumeMl }.toSet())
    }

    // --- Confirmation copy names the container / drink, bilingually ---

    // The `unit`/`amount` args are caller-pre-resolved for the current language (the codebase idiom
    // — see `env.s(HydrationStrings.ml)`), so they are embedded verbatim into BOTH language variants;
    // only the surrounding words differ. The tests pass the Arabic unit token when checking Arabic.

    @Test fun confirmationFromContainerNamesIt() {
        val en = HydrationStrings.addedFrom(amount = "500", unit = "mL", container = "Bottle", beverage = null)
        assertEquals("Added 500 mL from Bottle", en.resolved(AppLanguage.EN))
        val ar = HydrationStrings.addedFrom(amount = "500", unit = "مل", container = "زجاجة", beverage = null)
        assertEquals("أُضيف 500 مل من زجاجة", ar.resolved(AppLanguage.AR))
    }

    @Test fun confirmationOfDrinkWhenThereIsNoContainer() {
        val en = HydrationStrings.addedFrom(amount = "200", unit = "mL", container = null, beverage = "Coffee")
        assertEquals("Added 200 mL of Coffee", en.resolved(AppLanguage.EN))
    }

    @Test fun confirmationBarePlainWater() {
        val en = HydrationStrings.addedFrom(amount = "330", unit = "mL", container = null, beverage = null)
        assertEquals("Added 330 mL", en.resolved(AppLanguage.EN))
        val ar = HydrationStrings.addedFrom(amount = "330", unit = "مل", container = null, beverage = null)
        assertEquals("أُضيف 330 مل", ar.resolved(AppLanguage.AR))
    }

    // --- No-goal / goal progress lines ---

    @Test fun noGoalLineIsAFactNotAShortfall() {
        val en = HydrationStrings.totalLine(amount = "1,250", unit = "mL")
        assertEquals("1,250 mL logged today", en.resolved(AppLanguage.EN))
        val ar = HydrationStrings.totalLine(amount = "1,250", unit = "مل")
        assertEquals("1,250 مل مُسجَّل اليوم", ar.resolved(AppLanguage.AR))
    }

    @Test fun goalLineShowsLoggedOverTarget() {
        val s = HydrationStrings.goalLine(amount = "1,250", target = "2,000", unit = "mL")
        assertEquals("1,250 / 2,000 mL", s.resolved(AppLanguage.EN))
    }

    // --- Weekly card: observational count, never a streak ---

    private fun day(ml: Double, isToday: Boolean = false): HydrationWeekDay =
        HydrationWeekDay(dayKey = "2026-07-0${if (isToday) 7 else 1}", label = "Mon", totalMl = ml, isToday = isToday)

    @Test fun weeklyCountsOnlyDaysWithALog() {
        val week = HydrationWeek(
            days = listOf(day(0.0), day(500.0), day(0.0), day(750.0), day(0.0), day(0.0), day(250.0, isToday = true)),
        )
        assertEquals(3, week.daysWithLogs)
        assertEquals(7, week.span)
        assertEquals(750.0, week.maxMl, 1e-9)
        assertTrue(week.anyLogs)
    }

    @Test fun weeklyWithNoLogsReportsNothingToObserve() {
        val week = HydrationWeek(days = List(7) { day(0.0) })
        assertEquals(0, week.daysWithLogs)
        assertFalse(week.anyLogs)
    }

    @Test fun weekDayHasLogOnlyWhenPositive() {
        assertTrue(day(1.0).hasLog)
        assertFalse(day(0.0).hasLog)
    }

    @Test fun weeklyObservationWordingIsACount() {
        val s = HydrationStrings.daysLogged(days = "5", of = "7")
        assertEquals("You logged drinks on 5 of the last 7 days.", s.resolved(AppLanguage.EN))
        assertEquals("سجّلت مشروبات في 5 من آخر 7 أيام.", s.resolved(AppLanguage.AR))
    }
}
