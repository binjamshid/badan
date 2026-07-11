package net.albayyan.badan.core

/**
 * Injectable time source (mirror of the iOS `Clock`). Domain code takes a `Clock` and never
 * reads the wall clock directly, so day-attribution / baseline / DST behaviour is deterministic.
 * Instants are epoch milliseconds (UTC) — matching how they are stored in SQLite.
 */
interface Clock {
    fun now(): Long
}

class SystemClock : Clock {
    override fun now(): Long = System.currentTimeMillis()
}

/** A clock pinned to a fixed instant, for tests and reproducible seeding. */
class FixedClock(var instant: Long) : Clock {
    override fun now(): Long = instant
    fun advance(byMillis: Long) { instant += byMillis }
}

const val MILLIS_PER_DAY: Long = 86_400_000L
