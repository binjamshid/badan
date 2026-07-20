import SwiftUI

/// EPIC-16 — the one place a raw `ExportOutcome`/`ExportErrorCode`/`ExportTrigger`/`ExportStage`
/// is turned into something a person reads.
///
/// The task rule is explicit: never show the user `skippedLocked` or `failedDelivery` (or any
/// other raw token). The trust ledger is a closed vocabulary precisely so it can be reasoned about
/// in code (`ExportOutcome.isFailure`, retry decisions) — this file is the boundary where that
/// vocabulary becomes wellness-safe, bilingual copy. Kept as pure functions (no `View`, no
/// `AppEnvironment`) so `ExportSurfacesTests` can assert the mapping is total and that no rendered
/// string is ever the raw case name.
///
/// Colour is never the only signal here either (§16 a11y: "status not color-only"): every outcome
/// resolves to an icon + a tint + text through `ExportOutcomeTone`, so a chip built from this map
/// carries its meaning three ways.
enum ExportRunPresentation {

    // MARK: - Outcome

    /// How "worried" a chip should look. Deliberately three tones, not eight: a locked device, a
    /// throttle, nothing-to-do and a user cancel are all *ordinary* — the anti-HAE point is that a
    /// real failure (`partial`/`failedGeneration`/`failedDelivery`) stands out, and it can't stand
    /// out if four benign outcomes also wear amber. Mirrors `ExportOutcome.isFailure`.
    enum Tone: Equatable {
        /// It worked, in full.
        case good
        /// Nothing went wrong; there was simply nothing to do, or the moment wasn't right.
        case ordinary
        /// A real problem the user may want to act on.
        case attention

        /// The pill tint. `attention` reuses the single calm amber the whole app uses for
        /// "something's off" (`outOfBand`) rather than `critical`, which is reserved (see its
        /// token doc) — a failed export is not an emergency.
        var tint: Color {
            switch self {
            case .good: return BadanColor.primary
            case .ordinary: return BadanColor.textSecondary
            case .attention: return BadanColor.outOfBand
            }
        }
    }

    static func tone(_ outcome: ExportOutcome) -> Tone {
        switch outcome {
        case .success: return .good
        case .skippedNoData, .skippedLocked, .throttled, .cancelled: return .ordinary
        case .partial, .failedGeneration, .failedDelivery: return .attention
        }
    }

    /// SF Symbol for the outcome. Never a bare colour — the icon carries the same meaning to a
    /// user who can't separate the tint from `surface`.
    static func icon(_ outcome: ExportOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .skippedNoData: return "tray"
        case .skippedLocked: return "lock.fill"
        case .throttled: return "hourglass"
        case .cancelled: return "xmark.circle"
        case .partial: return "exclamationmark.triangle.fill"
        case .failedGeneration, .failedDelivery: return "exclamationmark.triangle.fill"
        }
    }

    /// The plain-language label. Wellness-safe, and never the raw case name.
    static func label(_ outcome: ExportOutcome) -> LocalizedString {
        switch outcome {
        case .success:
            return LocalizedString(en: "Completed", ar: "اكتمل")
        case .partial:
            return LocalizedString(en: "Partly completed", ar: "اكتمل جزئياً")
        case .failedGeneration:
            return LocalizedString(en: "Couldn't create the file", ar: "تعذّر إنشاء الملف")
        case .failedDelivery:
            return LocalizedString(en: "Created, but didn't arrive", ar: "أُنشئ، لكنه لم يصل")
        case .skippedLocked:
            return LocalizedString(en: "Waited — device was locked", ar: "انتظر — كان الجهاز مقفلاً")
        case .skippedNoData:
            return LocalizedString(en: "Nothing new to export", ar: "لا جديد للتصدير")
        case .throttled:
            return LocalizedString(en: "Postponed by the system", ar: "أجّله النظام")
        case .cancelled:
            return LocalizedString(en: "Cancelled", ar: "أُلغي")
        }
    }

    // MARK: - Trigger

    /// What set a run going. `manual` reads as "you did this" because that is the honest answer to
    /// the ledger's first question — "was that the app, or was that me?" (§9.5).
    static func triggerLabel(_ trigger: ExportTrigger) -> LocalizedString {
        switch trigger {
        case .manual:
            return LocalizedString(en: "Run by you", ar: "بتشغيل منك")
        case .shortcut:
            return LocalizedString(en: "Shortcut", ar: "اختصار")
        case .scheduledOpportunistic:
            return LocalizedString(en: "Background", ar: "في الخلفية")
        case .scheduledWork:
            return LocalizedString(en: "Scheduled", ar: "مجدول")
        case .retry:
            return LocalizedString(en: "Automatic retry", ar: "إعادة محاولة تلقائية")
        }
    }

    // MARK: - Error

    /// A sanitized, value-free reason. `ExportErrorDetail` is already structurally value-free (all
    /// ints + enums, no message string); this is the human sentence that pairs with it. None of
    /// these quote a metric, a reading or a filename.
    static func errorLabel(_ code: ExportErrorCode) -> LocalizedString {
        switch code {
        case .storageFull:
            return LocalizedString(en: "Not enough storage on this device.",
                                   ar: "لا توجد مساحة كافية على هذا الجهاز.")
        case .storageUnavailable:
            return LocalizedString(en: "Storage wasn't available.", ar: "لم يكن التخزين متاحاً.")
        case .permissionDenied:
            return LocalizedString(en: "A permission was needed.", ar: "لزمت صلاحية.")
        case .sensitiveConfirmationMissing:
            return LocalizedString(en: "Sensitive records need confirming in the app.",
                                   ar: "تحتاج السجلات الحساسة إلى تأكيد داخل التطبيق.")
        case .passphraseMissing:
            return LocalizedString(en: "A passphrase was required.", ar: "لزمت عبارة مرور.")
        case .encryptionFailed:
            return LocalizedString(en: "Encryption couldn't finish.", ar: "تعذّر إكمال التشفير.")
        case .writeFailed:
            return LocalizedString(en: "Writing the file didn't finish.", ar: "لم تكتمل كتابة الملف.")
        case .destinationUnreachable:
            return LocalizedString(en: "The destination couldn't be reached.",
                                   ar: "تعذّر الوصول إلى الوجهة.")
        case .destinationAuthExpired:
            return LocalizedString(en: "The destination needs reconnecting.",
                                   ar: "تحتاج الوجهة إلى إعادة اتصال.")
        case .destinationDisabled:
            return LocalizedString(en: "The destination is turned off.", ar: "الوجهة متوقّفة.")
        case .cursorMissing:
            return LocalizedString(en: "No checkpoint yet — a date range was used instead.",
                                   ar: "لا نقطة مرجعية بعد — استُخدم نطاق زمني بدلاً منها.")
        case .templateMissing:
            return LocalizedString(en: "That template no longer exists.", ar: "لم يعد هذا القالب موجوداً.")
        case .cancelledByUser:
            return LocalizedString(en: "You stopped this one.", ar: "أوقفته بنفسك.")
        case .unknown:
            return LocalizedString(en: "Something didn't finish.", ar: "لم يكتمل شيء ما.")
        }
    }

    // MARK: - Background substrate (power-mode diagnostics)

    /// Plain language for a `BackgroundRunOutcome` — the same "never show the raw token" rule as
    /// export outcomes, applied to the substrate stats shown in Export Health's power section.
    static func backgroundOutcomeLabel(_ outcome: BackgroundRunOutcome) -> LocalizedString {
        switch outcome {
        case .completed: return LocalizedString(en: "Completed", ar: "اكتمل")
        case .expired: return LocalizedString(en: "Paused by the system", ar: "أوقفه النظام مؤقتاً")
        case .storeLocked: return LocalizedString(en: "Waited — device was locked", ar: "انتظر — كان الجهاز مقفلاً")
        case .throttled: return LocalizedString(en: "Skipped — already syncing", ar: "تُخطّي — مزامنة جارية")
        case .error: return LocalizedString(en: "Didn't finish", ar: "لم يكتمل")
        }
    }

    /// Plain language for a `BackgroundRunKind`.
    static func backgroundKindLabel(_ kind: BackgroundRunKind) -> LocalizedString {
        switch kind {
        case .hkObserverWake: return LocalizedString(en: "Health update", ar: "تحديث صحي")
        case .bgAppRefresh: return LocalizedString(en: "Background refresh", ar: "تحديث في الخلفية")
        case .bgProcessing: return LocalizedString(en: "Background processing", ar: "معالجة في الخلفية")
        case .workManagerPeriodic: return LocalizedString(en: "Scheduled work", ar: "عمل مجدول")
        case .foregroundSync: return LocalizedString(en: "Opened the app", ar: "فتح التطبيق")
        }
    }

    /// Which phase a failure happened in — shown only in the power-mode error detail, alongside
    /// `filesWritten`/`filesExpected`.
    static func stageLabel(_ stage: ExportStage) -> LocalizedString {
        switch stage {
        case .gathering: return LocalizedString(en: "Gathering records", ar: "جمع السجلات")
        case .writing: return LocalizedString(en: "Writing the file", ar: "كتابة الملف")
        case .checksumming: return LocalizedString(en: "Verifying", ar: "التحقّق")
        case .encrypting: return LocalizedString(en: "Encrypting", ar: "التشفير")
        case .delivering: return LocalizedString(en: "Delivering", ar: "التسليم")
        case .finalizing: return LocalizedString(en: "Finishing up", ar: "اللمسات الأخيرة")
        }
    }

    // MARK: - Range rule (shown on template rows and the "next export" estimate)

    /// A calm description of the window a rule resolves to at run time. The day count is rendered
    /// through `ValueFormatter` so Arabic gets Arabic-Indic digits (matching `ExportRange.label`).
    static func rangeRuleLabel(_ rule: ExportRangeRule, format: ValueFormatter) -> LocalizedString {
        switch rule {
        case .fixed:
            return LocalizedString(en: "A fixed date range", ar: "نطاق زمني ثابت")
        case .lastNDays(let n):
            let count = format.integer(max(1, n))
            return LocalizedString(en: "Last \(count) days", ar: "آخر \(count) يوماً")
        case .sinceLastRun:
            return LocalizedString(en: "Everything since the last run",
                                   ar: "كل شيء منذ آخر تشغيل")
        case .allTime:
            return LocalizedString(en: "All time", ar: "كل الوقت")
        }
    }
}
