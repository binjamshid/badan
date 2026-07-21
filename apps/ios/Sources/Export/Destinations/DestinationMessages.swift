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

    // MARK: - REST destination (EPIC-20)

    /// First-save consent (§12 EPIC-20 / §22.7). The literal sentence the plan specifies, both
    /// languages. The second half is not decoration: it is the honest correction to the one
    /// misreading that matters — BADAN did not pick this server, the user did, and BADAN never picks
    /// one.
    ///
    /// **Where it is shown, honestly:** nowhere yet. This build has no screen that *creates* a REST
    /// destination, so no `restApi` row can exist and this string has no display site. It is defined
    /// (and pinned by `RESTDestinationTests`) so the sentence is settled in both languages before
    /// that screen exists — the first-save confirmation on whatever surface adds a REST destination
    /// is required to present it, and this destination will deliver to any `restApi` row it is
    /// handed without checking that it was.
    static let restConsent = LocalizedString(
        en: "BADAN will send the selected health data to a server you control. "
            + "BADAN never chooses this destination for you.",
        ar: "سيرسل بدن البيانات الصحية المحددة إلى خادم تتحكم فيه أنت. "
            + "لا يختار بدن هذه الوجهة نيابةً عنك أبداً.")

    /// The verification ping reached the server and it accepted a test request. Says exactly what
    /// happened — a marked probe was accepted — not that a real export has ever been delivered.
    static let restProbeReachable = LocalizedString(
        en: "BADAN reached this server and it accepted a test request.",
        ar: "وصل بدن إلى هذا الخادم وقبِل طلباً تجريبياً.")

    static let restDelivered = LocalizedString(
        en: "Your export was sent to the server.",
        ar: "تم إرسال تصديرك إلى الخادم.")

    /// Auth rejected (401/403). "Reauthorize" rather than "choose again": the endpoint is fine, the
    /// token is not — so this is not a re-pick, it is a new credential.
    static let restAuthExpired = LocalizedString(
        en: "The server rejected BADAN's credentials. Update the access token to send here again.",
        ar: "رفض الخادم بيانات اعتماد بدن. حدّث رمز الوصول للإرسال إلى هنا مرة أخرى.")

    /// No usable token in the Keychain for this destination — never the token value, only its
    /// absence. Same remedy as an expired one, so it borrows `authExpired`'s status upstream.
    static let restCredentialMissing = LocalizedString(
        en: "BADAN has no saved access token for this server. Add one to send here.",
        ar: "لا يملك بدن رمز وصول محفوظاً لهذا الخادم. أضف واحداً للإرسال إلى هنا.")

    /// The endpoint is not set (no URL) — a configuration gap, not a reachability failure.
    static let restNotConfigured = LocalizedString(
        en: "This destination has no server address yet. Add one to send here.",
        ar: "لا يوجد عنوان خادم لهذه الوجهة بعد. أضف عنواناً للإرسال إلى هنا.")

    /// HTTPS is required and the address is plain `http://`. Blocked **before** any bytes leave the
    /// device — the message names the reason plainly rather than reporting a network failure that
    /// never happened.
    /// `https` goes through the placeholder rather than sitting in the template so it can be bidi-
    /// isolated: a bare Latin token at the end of an Arabic sentence sits next to the sentence's
    /// full stop, which is exactly the neutral-run ambiguity `isolated` exists to settle.
    static var restInsecureBlocked: LocalizedString {
        LocalizedString(
            en: "BADAN won't send your data over an unencrypted connection. Use an {scheme} address.",
            ar: "لن يرسل بدن بياناتك عبر اتصال غير مشفّر. استخدم عنوان {scheme}.")
            .filling(["scheme": isolated("https")])
    }

    /// Could not connect at all (timeout, DNS, connection refused) after the capped retries.
    /// Deliberately says nothing about the endpoint's configuration — a server that is merely down
    /// is not a destination that needs re-picking.
    static let restUnreachable = LocalizedString(
        en: "BADAN couldn't reach this server. It may be offline — BADAN will not keep retrying now.",
        ar: "تعذّر على بدن الوصول إلى هذا الخادم. قد يكون غير متصل — لن يواصل بدن المحاولة الآن.")

    /// The server answered with an error status. Carries the status code and nothing else — no
    /// response body is ever surfaced, because a server's error text can quote back what was sent.
    /// The whole `HTTP 503` token is substituted, not just the number, so the Latin run and its
    /// digits stay one bidi-isolated unit inside the Arabic parentheses.
    static func restServerError(status: Int) -> LocalizedString {
        LocalizedString(en: "The server rejected the export ({code}).",
                        ar: "رفض الخادم التصدير ({code}).")
            .filling(["code": isolated("HTTP \(status)")])
    }

    /// The generated file could not be read back out of BADAN's own staging folder, so there was
    /// nothing to send. A local problem, and the copy says so — blaming the server for a file BADAN
    /// could not read would point the user at the wrong thing entirely.
    static let restSourceUnreadable = LocalizedString(
        en: "BADAN couldn't read the export file, so nothing was sent.",
        ar: "تعذّر على بدن قراءة ملف التصدير، لذلك لم يُرسل شيء.")

    /// Partial delivery: an earlier NDJSON part landed and a later one did not. Counts **files**,
    /// not parts, because that is what the caller passes and what the ledger row records — a part
    /// can carry several files, so "2 of 5 parts" would be a number the code never computed. States
    /// both for the same reason the folder message does: "some of it was sent" invites the reader to
    /// assume the rest did not matter.
    static func restPartiallyDelivered(sent: Int, expected: Int) -> LocalizedString {
        LocalizedString(en: "Only {sent} of {expected} files reached the server.",
                        ar: "وصل {sent} من {expected} ملفات فقط إلى الخادم.")
            .filling(["sent": "\(sent)", "expected": "\(expected)"])
    }

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
