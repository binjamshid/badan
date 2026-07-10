package net.albayyan.badan.core

import kotlin.random.Random

/**
 * ULID — Universally Unique Lexicographically Sortable Identifier. Mirror of the iOS `ULID`.
 * BADAN mints all entity ids on-device (INVARIANT I8): offline-generatable, time-sortable,
 * sync-safe. 48-bit ms timestamp (10 Crockford-base32 chars) + 80 bits randomness (16 chars).
 */
object Ulid {
    private val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".toCharArray()

    fun generate(timeMillis: Long, random: Random): String {
        val chars = CharArray(26)
        var t = timeMillis and 0xFFFF_FFFF_FFFFL
        for (i in 9 downTo 0) {
            chars[i] = alphabet[(t and 0x1F).toInt()]
            t = t shr 5
        }
        for (i in 10 until 26) {
            chars[i] = alphabet[random.nextInt(32)]
        }
        return String(chars)
    }

    fun newId(): String = generate(System.currentTimeMillis(), Random.Default)

    /** Extract the embedded timestamp (epoch millis) from a ULID, if valid. */
    fun timestampOf(ulid: String): Long? {
        if (ulid.length != 26) return null
        var value = 0L
        for (ch in ulid.substring(0, 10)) {
            val idx = alphabet.indexOf(ch)
            if (idx < 0) return null
            value = (value shl 5) or idx.toLong()
        }
        return value
    }
}
