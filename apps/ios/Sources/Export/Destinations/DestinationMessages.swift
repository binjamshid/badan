import Foundation

/// EPIC-14 — every user-facing sentence a destination can produce, en+ar.
///
/// Held here rather than in `Loc` because these are the *only* strings this module emits and they
/// are meaningless outside it; `Strings.swift`'s own doc sanctions an inline `LocalizedString` for
/// exactly this case. The rule it exists to serve still applies in full: a destination cannot
/// report a result without both languages, because there is no code path from a probe or a receipt
/// to a bare `String`.
///
/// Register note: these describe **files and folders**, never the user's body, so the wellness
/// guardrails that constrain metric copy do not apply — but the honesty rule does. Nothing here
/// claims a file arrived, a folder is writable, or a retry will work unless the code that returned
/// the message actually established it.
enum DestinationMessages {

    // MARK: - Verification ping

    /// Deliberately says what was *done*, not that the folder "looks fine". §12 EPIC-14 asks for a
    /// real write+delete probe and the copy is what tells the user they got one.
    static let probeWritable = LocalizedString(
        en: "This folder is ready. BADAN wrote a test file to it and removed it again.",
        ar: "هذا المجلد جاهز. كتب بدن ملفاً تجريبياً فيه ثم حذفه.")

    /// The bookmark/tree-URI invalidation case — a moved folder, an unmounted volume, an evicted
    /// iCloud directory, a grant the system dropped. All of them end in the same place for the
    /// user, so they get one sentence and one remedy rather than four diagnoses they cannot act on
    /// differently.
    static let probeNeedsRepick = LocalizedString(
        en: "BADAN can no longer reach this folder. Choose the folder again to keep exporting there.",
        ar: "لم يعد بدن قادراً على الوصول إلى هذا المجلد. اختر المجلد مرة أخرى لمتابعة التصدير إليه.")

    /// Split from `probeNeedsRepick` because the *cause* is worth naming: the user (or the system)
    /// withdrew the grant, which is a thing they may remember doing, unlike a folder that moved.
    static let probePermissionWithdrawn = LocalizedString(
        en: "BADAN's permission to use this folder was withdrawn. Choose the folder again to restore it.",
        ar: "سُحب إذن بدن لاستخدام هذا المجلد. اختر المجلد مرة أخرى لاستعادته.")

    static let probeStorageFull = LocalizedString(
        en: "There isn't enough space left to finish writing to this folder.",
        ar: "لا توجد مساحة كافية لإكمال الكتابة في هذا المجلد.")

    static let probeStorageUnavailable = LocalizedString(
        en: "This folder isn't available right now. The drive or service that holds it may be offline.",
        ar: "هذا المجلد غير متاح حالياً. قد يكون القرص أو الخدمة التي تحتويه غير متصل.")

    static let probeWriteFailed = LocalizedString(
        en: "BADAN couldn't write to this folder.",
        ar: "تعذّر على بدن الكتابة في هذا المجلد.")

    /// `disabled` is never set automatically (see `ExportDestinationStatus.disabled`), so this is
    /// always describing something the user did — hence "turned off" rather than "unavailable".
    static let destinationDisabled = LocalizedString(
        en: "This destination is turned off. Turn it back on to export to it.",
        ar: "هذه الوجهة متوقفة. أعد تفعيلها للتصدير إليها.")

    /// The destination row is gone or was never given a folder, but something still references it.
    /// Named separately because the remedy is neither re-pick nor retry — the template needs a
    /// folder chosen for the first time.
    static let destinationNotConfigured = LocalizedString(
        en: "This destination hasn't been set up yet. Choose a folder for it first.",
        ar: "لم يتم إعداد هذه الوجهة بعد. اختر مجلداً لها أولاً.")

    // MARK: - Delivery outcomes

    static func delivered(to path: String) -> LocalizedString {
        LocalizedString(en: "Saved to {path}.", ar: "تم الحفظ في {path}.")
            .filling(["path": isolated(path)])
    }

    /// The `.partial` sentence. States both numbers, because "some files were saved" invites the
    /// user to assume the missing one did not matter — the count is what tells them to look.
    static func partiallyDelivered(written: Int, expected: Int) -> LocalizedString {
        LocalizedString(en: "Only {written} of {expected} files reached this folder.",
                        ar: "وصل {written} من {expected} ملفات فقط إلى هذا المجلد.")
            .filling(["written": "\(written)", "expected": "\(expected)"])
    }

    static let nothingToDeliver = LocalizedString(
        en: "There were no files to save.",
        ar: "لم تكن هناك ملفات لحفظها.")

    // MARK: - Folder picking

    static let pickFolder = LocalizedString(en: "Choose a folder", ar: "اختر مجلداً")
    static let repickFolder = LocalizedString(en: "Choose the folder again", ar: "اختر المجلد مرة أخرى")

    /// Shown under the picker button. Says where files will land so the folder scheme is something
    /// the user was told about rather than something they discover.
    static let folderSchemeNote = LocalizedString(
        en: "Exports are filed under BADAN/Exports, by year and month.",
        ar: "تُحفظ الملفات ضمن BADAN/Exports، مرتّبة حسب السنة والشهر.")

    // MARK: - Bidi

    /// Wrap an LTR path so it renders as one unit inside an Arabic sentence.
    ///
    /// `BADAN/Exports/2026/07` dropped raw into RTL text gets reordered by the bidi algorithm — the
    /// trailing `07` migrates to the left of the sentence and the path reads as nonsense. FSI/PDI
    /// (U+2068/U+2069) isolate it without forcing a direction on the surrounding copy, which is
    /// what LRM or an RLE/PDF pair would do.
    ///
    /// Note the deliberate asymmetry with `ExportArtifactNaming.slug`, which *strips* these same
    /// characters: bidi controls are correct in display copy and wrong in storage identity. A
    /// filename carrying an isolate sorts and globs differently from its siblings and can be made
    /// to display an extension it does not have.
    private static func isolated(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }
}
