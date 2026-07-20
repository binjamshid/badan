package net.albayyan.badan.export.destinations

import java.util.Calendar
import java.util.GregorianCalendar
import java.util.TimeZone

/**
 * EPIC-14 — the folder scheme and file-naming convention, in one place on each platform.
 *
 * `BADAN/Exports/<year>/<month>/` and `BADAN_<template-or-bundle>_<YYYYMMDD>-<YYYYMMDD>[_partN].<ext>`
 * are a published contract, not a formatting preference: a user who has dropped exports into a SAF
 * folder for a year has a directory their own scripts glob over, and a "tidier" name in a later
 * release silently splits their archive in two. This is the byte-for-byte mirror of iOS
 * `Export/Destinations/ExportArtifactNaming.swift`, and `ExportDestinationsTest` pins the exact
 * strings on both platforms so a drift here fails a fixture rather than a user's folder.
 */
object ExportArtifactNaming {

    /** The fixed root every BADAN export lives under, regardless of where the user pointed us. */
    const val ROOT_FOLDER = "BADAN"
    const val EXPORTS_FOLDER = "Exports"

    /** Fallback slug when a template name sanitizes to nothing (see [slug]). */
    const val BUNDLE_LABEL = "bundle"

    /**
     * Longest slug we will put in a filename. The rest of the name is bounded (`BADAN_` + two
     * 8-digit dates + a separator + `_partNN` + extension ≈ 45 characters), so 60 keeps the whole
     * filename inside the 255-byte limit every file provider imposes, with room for a provider that
     * appends its own " 2" on a name collision.
     */
    const val MAX_SLUG_LENGTH = 60

    // -- Folder scheme --

    /**
     * `["BADAN", "Exports", "2026", "07"]` — the components, not a joined path, because SAF walks
     * them one `createDocument` at a time and a joined string would just have to be split again.
     *
     * Bucketed by the **run** instant, not by the data's date range. A "last 30 days" export run on
     * 2 August covers July, and filing it under `2026/07` would put this month's export in last
     * month's folder — the folder answers "when did BADAN write this", the filename answers "what is
     * inside it", and conflating the two makes the directory listing lie about both.
     */
    fun folderComponents(runDate: Long, timeZone: TimeZone): List<String> {
        val cal = GregorianCalendar(timeZone).apply { timeInMillis = runDate }
        // Gregorian year/month regardless of the user's calendar preference, and ASCII digits
        // regardless of their numeral preference — see [dateStamp] for why display formatting has no
        // business here. Calendar.MONTH is 0-based.
        val year = cal.get(Calendar.YEAR)
        val month = cal.get(Calendar.MONTH) + 1
        return listOf(ROOT_FOLDER, EXPORTS_FOLDER, pad4(year), pad2(month))
    }

    /**
     * The same components as a display/logging path (`BADAN/Exports/2026/07`). Always
     * forward-slashed and always relative to the destination root: an absolute content URI would
     * carry the provider's document-id scheme into [ExportDeliveryReceipt], and from there into an
     * Export Health screenshot.
     */
    fun folderPath(runDate: Long, timeZone: TimeZone): String =
        folderComponents(runDate, timeZone).joinToString("/")

    // -- File naming --

    /**
     * `BADAN_weekly-vitals_20260701-20260707.csv`, or `…_part2.csv` when the export was split.
     *
     * @param label the template name, or null for an ad-hoc builder export (which has no template —
     *   see `ExportRun.templateId`) and therefore files under `bundle`.
     * @param part null for a single-file export. 1-based when present, so a reader who sees `_part2`
     *   knows to look for `_part1` — a 0-based `_part0` reads as a bug report.
     */
    fun fileName(
        label: String?,
        start: Long,
        end: Long,
        fileExtension: String,
        timeZone: TimeZone,
        part: Int? = null,
    ): String {
        val stampedStart = dateStamp(start, timeZone)
        val stampedEnd = dateStamp(end, timeZone)
        var name = "${ROOT_FOLDER}_${slug(label)}_$stampedStart-$stampedEnd"
        if (part != null && part >= 1) name += "_part$part"
        return "$name.$fileExtension"
    }

    /**
     * `YYYYMMDD` in the given zone, with **ASCII digits, always**.
     *
     * This is the one place in the codebase where the Arabic-numeral preference must not reach.
     * `Numerals`/`ValueFormatter` render Arabic-Indic digits (٢٠٢٦٠٧٠١) for display and that is
     * correct everywhere a human reads a number — but a filename is storage identity: an Arabic-digit
     * filename does not sort next to its English-digit siblings, does not match a user's
     * `BADAN_*_2026*` glob, and changes if the user switches language. Hence a manual pad over any
     * locale-carrying formatter.
     */
    fun dateStamp(date: Long, timeZone: TimeZone): String {
        val cal = GregorianCalendar(timeZone).apply { timeInMillis = date }
        return pad4(cal.get(Calendar.YEAR)) + pad2(cal.get(Calendar.MONTH) + 1) +
            pad2(cal.get(Calendar.DAY_OF_MONTH))
    }

    /**
     * Turn a user-chosen template name into a filename-safe slug.
     *
     * Deliberately **keeps non-Latin letters**. Transliterating or stripping Arabic would mean a
     * user whose templates are named in Arabic gets a folder full of `BADAN_bundle_…` files they
     * cannot tell apart — the exact "Arabic is a second-class locale" failure VS-5 exists to
     * prevent. Every SAF provider handles Unicode document names.
     *
     * What it does remove:
     *  - Bidi control characters (U+200E/F, U+202A–U+202E, U+2066–U+2069). Invisible, they survive a
     *    copy/paste, and an embedded RLO can make `…_part1.csv` *render* as `…vsc.1trap_` — a name
     *    that looks like one type and opens as another. A mixed Arabic/ASCII name still lays out
     *    right-to-left without them; the app just never writes an explicit override into storage
     *    identity.
     *  - Path separators and the Windows-reserved set, so a slug cannot escape its directory or
     *    become unwritable on an exFAT drive the user syncs the folder to.
     *  - Leading dots, which would hide the file on every Unix-derived filesystem.
     */
    fun slug(label: String?): String {
        if (label == null) return BUNDLE_LABEL

        val out = StringBuilder()
        var pendingSeparator = false
        for (ch in label) {
            if (isStripped(ch)) continue
            // `_` joins the reserved set even though filesystems accept it: it is this convention's
            // own field separator, so a template named "weekly_vitals" would otherwise produce a
            // name with five underscore-delimited fields where a parser expects three or four.
            if (ch.isWhitespace() || ch in RESERVED || ch == '-') {
                pendingSeparator = out.isNotEmpty()
                continue
            }
            if (pendingSeparator) {
                out.append('-')
                pendingSeparator = false
            }
            out.append(ch)
            if (out.length >= MAX_SLUG_LENGTH) break
        }

        // A name made entirely of separators and control characters leaves nothing to file under.
        // `bundle` is the honest answer — it is what an export with no template is already called,
        // and it never collides with the date range that follows it.
        val trimmed = out.toString().trim('.', '-')
        return trimmed.ifEmpty { BUNDLE_LABEL }
    }

    private val RESERVED = setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|', '_')

    /**
     * Strip Unicode categories Cc (control) and Cf (format). This is exactly what iOS's
     * `CharacterSet.controlCharacters` covers — that set is documented as "General Category Cc and
     * Cf" — so the two platforms strip the same characters, and the bidi controls the doc comment
     * calls out (U+200E/F, U+202A–U+202E, U+2066–U+2069) are all Cf and covered here without an
     * explicit list to drift from.
     */
    private fun isStripped(ch: Char): Boolean {
        val type = Character.getType(ch)
        return type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
    }

    private fun pad2(value: Int): String = value.toString().padStart(2, '0')
    private fun pad4(value: Int): String = value.toString().padStart(4, '0')
}
