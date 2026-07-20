package net.albayyan.badan.export.destinations

import net.albayyan.badan.core.LocalizedString

/**
 * EPIC-14 — every user-facing sentence a destination can produce, en+ar.
 *
 * Held here rather than in `Loc` because these are the *only* strings this module emits and they are
 * meaningless outside it; `Strings.kt`'s own doc sanctions an inline [LocalizedString] for exactly
 * this case. The rule it serves still holds in full: a destination cannot report a result without
 * both languages, because there is no code path from a probe or a receipt to a bare `String`. Kept
 * byte-identical to iOS `DestinationMessages.swift`.
 *
 * Register note: these describe **files and folders**, never the user's body, so the wellness
 * guardrails that constrain metric copy do not apply — but the honesty rule does. Nothing here
 * claims a file arrived, a folder is writable, or a retry will work unless the code that returned
 * the message actually established it.
 */
object DestinationMessages {

    // -- Verification ping --

    /**
     * Deliberately says what was *done*, not that the folder "looks fine". §12 EPIC-14 asks for a
     * real write+delete probe and the copy is what tells the user they got one.
     */
    val probeWritable = LocalizedString(
        en = "This folder is ready. BADAN wrote a test file to it and removed it again.",
        ar = "هذا المجلد جاهز. كتب بدن ملفاً تجريبياً فيه ثم حذفه.",
    )

    /**
     * The tree-URI invalidation case — a folder document deleted, a provider uninstalled, a grant
     * the system dropped. All end in the same place for the user, so they get one sentence and one
     * remedy rather than several diagnoses they cannot act on differently.
     */
    val probeNeedsRepick = LocalizedString(
        en = "BADAN can no longer reach this folder. Choose the folder again to keep exporting there.",
        ar = "لم يعد بدن قادراً على الوصول إلى هذا المجلد. اختر المجلد مرة أخرى لمتابعة التصدير إليه.",
    )

    /**
     * Split from [probeNeedsRepick] because the *cause* is worth naming: the user (or the system)
     * revoked the persisted permission, which is a thing they may remember doing, unlike a folder
     * that was deleted.
     */
    val probePermissionWithdrawn = LocalizedString(
        en = "BADAN's permission to use this folder was withdrawn. Choose the folder again to restore it.",
        ar = "سُحب إذن بدن لاستخدام هذا المجلد. اختر المجلد مرة أخرى لاستعادته.",
    )

    val probeStorageFull = LocalizedString(
        en = "There isn't enough space left to finish writing to this folder.",
        ar = "لا توجد مساحة كافية لإكمال الكتابة في هذا المجلد.",
    )

    val probeStorageUnavailable = LocalizedString(
        en = "This folder isn't available right now. The drive or service that holds it may be offline.",
        ar = "هذا المجلد غير متاح حالياً. قد يكون القرص أو الخدمة التي تحتويه غير متصل.",
    )

    val probeWriteFailed = LocalizedString(
        en = "BADAN couldn't write to this folder.",
        ar = "تعذّر على بدن الكتابة في هذا المجلد.",
    )

    /**
     * DISABLED is never set automatically (see `ExportDestinationStatus.DISABLED`), so this is always
     * describing something the user did — hence "turned off" rather than "unavailable".
     */
    val destinationDisabled = LocalizedString(
        en = "This destination is turned off. Turn it back on to export to it.",
        ar = "هذه الوجهة متوقفة. أعد تفعيلها للتصدير إليها.",
    )

    /**
     * The destination row is gone or was never given a folder, but something still references it.
     * The remedy is neither re-pick nor retry — a folder needs choosing for the first time.
     */
    val destinationNotConfigured = LocalizedString(
        en = "This destination hasn't been set up yet. Choose a folder for it first.",
        ar = "لم يتم إعداد هذه الوجهة بعد. اختر مجلداً لها أولاً.",
    )

    // -- Delivery outcomes --

    fun delivered(path: String): LocalizedString =
        LocalizedString(en = "Saved to {path}.", ar = "تم الحفظ في {path}.")
            .filling(mapOf("path" to isolated(path)))

    /**
     * The PARTIAL sentence. States both numbers, because "some files were saved" invites the user to
     * assume the missing one did not matter — the count is what tells them to look.
     */
    fun partiallyDelivered(written: Int, expected: Int): LocalizedString =
        LocalizedString(
            en = "Only {written} of {expected} files reached this folder.",
            ar = "وصل {written} من {expected} ملفات فقط إلى هذا المجلد.",
        ).filling(mapOf("written" to written.toString(), "expected" to expected.toString()))

    val nothingToDeliver = LocalizedString(
        en = "There were no files to save.",
        ar = "لم تكن هناك ملفات لحفظها.",
    )

    // -- Folder picking --

    val pickFolder = LocalizedString(en = "Choose a folder", ar = "اختر مجلداً")
    val repickFolder = LocalizedString(en = "Choose the folder again", ar = "اختر المجلد مرة أخرى")

    /**
     * Shown under the picker button. Says where files will land so the folder scheme is something the
     * user was told about rather than something they discover.
     */
    val folderSchemeNote = LocalizedString(
        en = "Exports are filed under BADAN/Exports, by year and month.",
        ar = "تُحفظ الملفات ضمن BADAN/Exports، مرتّبة حسب السنة والشهر.",
    )

    // -- Bidi --

    /**
     * Wrap an LTR path so it renders as one unit inside an Arabic sentence.
     *
     * `BADAN/Exports/2026/07` dropped raw into RTL text gets reordered by the bidi algorithm — the
     * trailing `07` migrates to the left and the path reads as nonsense. FSI/PDI (U+2068/U+2069)
     * isolate it without forcing a direction on the surrounding copy, which is what LRM or an RLE/PDF
     * pair would do.
     *
     * Note the deliberate asymmetry with [ExportArtifactNaming.slug], which *strips* these same
     * characters: bidi controls are correct in display copy and wrong in storage identity.
     */
    private fun isolated(text: String): String = "\u2068$text\u2069"
}
