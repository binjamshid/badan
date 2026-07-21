package net.albayyan.badan.core

/**
 * Normalizes a user-typed numeric string before handing it to Kotlin's own number parser.
 *
 * Byte-for-byte behavioral mirror of iOS `DecimalParsing` (Core/DecimalParsing.swift). A device set
 * to Arabic can produce Eastern-Arabic digits (٠–٩, U+0660–0669), Extended Arabic-Indic digits
 * (۰–۹, U+06F0–06F9), or the Arabic decimal separator ٫ (U+066B) from its own number pad, all of
 * which a bare `toDoubleOrNull()` silently rejects (BUG-15). This is the single, pure, testable place
 * that folds all of that to plain ASCII before parsing, so every call site shares identical, verified
 * behavior — and the hydration ledger's mL parsing matches iOS exactly.
 */
object DecimalParsing {
    /** Parses a possibly Arabic-digit / Arabic-separator numeric string as a [Double], or null. */
    fun parse(text: String): Double? = normalize(text).toDoubleOrNull()

    /** Same normalization, resolved as an [Int] — for whole-number fields. */
    fun parseInt(text: String): Int? = normalize(text).toIntOrNull()

    /**
     * Folds Eastern-Arabic and Extended Arabic-Indic digits to ASCII `0`–`9`, maps the Arabic
     * decimal separator ٫ (U+066B) and a Western comma `,` to `.`, drops the Arabic thousands
     * separator ٬ (U+066C) entirely, and trims surrounding whitespace.
     */
    fun normalize(text: String): String {
        val sb = StringBuilder(text.length)
        for (ch in text) {
            when (val cp = ch.code) {
                in 0x0660..0x0669 -> sb.append(('0' + (cp - 0x0660)))   // Eastern Arabic-Indic ٠-٩
                in 0x06F0..0x06F9 -> sb.append(('0' + (cp - 0x06F0)))   // Extended Arabic-Indic ۰-۹
                0x066B -> sb.append('.')                                // Arabic decimal separator ٫
                0x066C -> {}                                            // Arabic thousands separator ٬ — dropped
                0x002C -> sb.append('.')                                // Western comma ',' -> decimal
                else -> sb.append(ch)
            }
        }
        return sb.toString().trim()
    }
}
