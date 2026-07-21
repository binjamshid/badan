import Foundation

/// The single source of a report's *wording* — the wellness-safe, bilingual copy and the
/// number→sentence logic that both the PDF renderer (`ReportRenderer`) and the on-screen surface
/// (`ReportsScreen`) draw from, so the shared PDF and the in-app view can never say different
/// things. Keeping it here (over the language-neutral `ReportModel`) is what lets one wellness-copy
/// lint and one snapshot cover every place a report speaks.
///
/// Register: neutral and non-punitive. Directions are "higher/lower than the previous week", never
/// "good/bad"; adherence is counted, never judged. The persistent disclaimer states plainly that a
/// report is a wellness summary, not a medical assessment.
public enum ReportPresentation {

    // MARK: - Titles / labels

    public static func title(_ kind: ReportPeriodKind) -> LocalizedString {
        switch kind {
        case .week: return LocalizedString(en: "Weekly report", ar: "التقرير الأسبوعي")
        case .month: return LocalizedString(en: "Monthly report", ar: "التقرير الشهري")
        }
    }

    public static func sectionTitle(_ kind: ReportSectionKind) -> LocalizedString {
        switch kind {
        case .sleep: return LocalizedString(en: "Sleep", ar: "النوم")
        case .effort: return LocalizedString(en: "Effort", ar: "الجهد")
        case .readiness: return LocalizedString(en: "Readiness", ar: "الجاهزية")
        case .adherence: return LocalizedString(en: "Medication adherence", ar: "الالتزام بالدواء")
        case .changes: return LocalizedString(en: "Notable changes", ar: "تغيّرات ملحوظة")
        }
    }

    public static func metricLabel(_ metricId: String) -> LocalizedString {
        switch metricId {
        case MetricID.sleepPerformance: return LocalizedString(en: "Sleep performance", ar: "أداء النوم")
        case MetricID.sleepDebt: return LocalizedString(en: "Sleep debt", ar: "عجز النوم")
        case MetricID.sleepConsistency: return LocalizedString(en: "Sleep consistency", ar: "انتظام النوم")
        case MetricID.effortDay: return LocalizedString(en: "Effort", ar: "الجهد")
        case MetricID.readinessScore: return LocalizedString(en: "Readiness", ar: "الجاهزية")
        default: return LocalizedString(en: metricId, ar: metricId)
        }
    }

    // MARK: - Stat labels

    public static let averageLabel = LocalizedString(en: "Average", ar: "المتوسط")
    public static let rangeLabel = LocalizedString(en: "Range", ar: "المدى")
    public static let latestLabel = LocalizedString(en: "Latest", ar: "الأحدث")
    public static let regenerateLabel = LocalizedString(en: "Regenerate", ar: "إعادة الإنشاء")

    /// Shown when a build fails. Deliberately distinct from the empty-period copy AND from the
    /// generic load-error copy: a period with nothing logged DOES produce a report (an honest one),
    /// and nothing failed to *load* — so neither of those would be a true sentence here. Lives with
    /// the rest of the report wording so the list and the detail surface say the same thing.
    public static let generateError = LocalizedString(
        en: "Couldn't build that report. Try again.",
        ar: "تعذّر إنشاء هذا التقرير. حاول مرة أخرى.")

    public static let disclaimer = LocalizedString(
        en: "This is a wellness summary, not a medical assessment.",
        ar: "هذا ملخّص للعافية وليس تقييماً طبياً.")

    public static func emptyMessage(_ kind: ReportPeriodKind) -> LocalizedString {
        switch kind {
        case .week: return LocalizedString(
            en: "Not enough logged this week to build a report yet.",
            ar: "لا توجد بيانات كافية هذا الأسبوع لإنشاء تقرير بعد.")
        case .month: return LocalizedString(
            en: "Not enough logged this month to build a report yet.",
            ar: "لا توجد بيانات كافية هذا الشهر لإنشاء تقرير بعد.")
        }
    }

    // MARK: - Period label

    /// A human period label: "Week 29, 2026" / "July 2026" and their Arabic forms.
    public static func periodLabel(_ model: ReportModel, language: AppLanguage, arabicDigits: Bool) -> String {
        switch model.periodKind {
        case .week:
            // periodKey is "week:YYYY-Www".
            let body = model.periodKey.replacingOccurrences(of: "week:", with: "")
            let parts = body.split(separator: "-")
            let yearStr = parts.first.map(String.init) ?? ""
            let weekStr = parts.count > 1 ? String(parts[1].dropFirst()) : ""
            let year = number(Double(Int(yearStr) ?? 0), language, arabicDigits, fractionDigits: 0)
            let week = number(Double(Int(weekStr) ?? 0), language, arabicDigits, fractionDigits: 0)
            switch language {
            case .en: return "Week \(week), \(year)"
            case .ar: return "الأسبوع \(week)، \(year)"
            }
        case .month:
            let df = DateFormatter()
            df.locale = language.locale
            df.timeZone = TimeZone(identifier: model.timezone) ?? .current
            df.dateFormat = "MMMM yyyy"
            return df.string(from: model.periodStart)
        }
    }

    // MARK: - Counted nouns

    /// Count-noun agreement for the nouns a report counts (days, doses, records). English needs
    /// only singular/plural; Arabic follows the app-wide rule `HomeArabicCount` already applies —
    /// 1 singular · 2 dual · 3–10 plural · 11+ indeclinable singular — with the dual carrying no
    /// numeral, since "يومين" already says two. This is not a nicety: a week's counts land squarely
    /// in the 3–10 band, so a fixed "\(n) يوماً" would be wrong in nearly every Arabic report.
    /// A count of 0 takes the 3–10 plural form; in practice it never reaches here, because a
    /// section exists only when it has content.
    public static func countedNoun(_ n: Int, language: AppLanguage, arabicDigits: Bool,
                                   enSingular: String, enPlural: String,
                                   arOne: String, arTwo: String, arFew: String, arMany: String) -> String {
        let digits = number(Double(n), language, arabicDigits, fractionDigits: 0)
        switch language {
        case .en:
            return "\(digits) \(n == 1 ? enSingular : enPlural)"
        case .ar:
            switch n {
            case 1: return arOne
            case 2: return arTwo
            case 11...: return "\(digits) \(arMany)"
            default: return "\(digits) \(arFew)"
            }
        }
    }

    /// "5 days" / "٥ أيام" — the days a metric summary covers.
    public static func dayCount(_ n: Int, language: AppLanguage, arabicDigits: Bool) -> String {
        countedNoun(n, language: language, arabicDigits: arabicDigits,
                    enSingular: "day", enPlural: "days",
                    arOne: "يوم واحد", arTwo: "يومين", arFew: "أيام", arMany: "يوماً")
    }

    /// "5 records" / "٥ سجلات" — the evidence rows a claim rests on.
    public static func recordCount(_ n: Int, language: AppLanguage, arabicDigits: Bool) -> String {
        countedNoun(n, language: language, arabicDigits: arabicDigits,
                    enSingular: "record", enPlural: "records",
                    arOne: "سجل واحد", arTwo: "سجلين", arFew: "سجلات", arMany: "سجلاً")
    }

    /// "5 doses" / "٥ جرعات" — logged medication doses.
    public static func doseCount(_ n: Int, language: AppLanguage, arabicDigits: Bool) -> String {
        countedNoun(n, language: language, arabicDigits: arabicDigits,
                    enSingular: "dose", enPlural: "doses",
                    arOne: "جرعة واحدة", arTwo: "جرعتين", arFew: "جرعات", arMany: "جرعة")
    }

    /// "3 sections" / "٣ أقسام" — how much of a report a row summarises.
    public static func sectionCount(_ n: Int, language: AppLanguage, arabicDigits: Bool) -> String {
        countedNoun(n, language: language, arabicDigits: arabicDigits,
                    enSingular: "section", enPlural: "sections",
                    arOne: "قسم واحد", arTwo: "قسمين", arFew: "أقسام", arMany: "قسماً")
    }

    // MARK: - Narratives (numbers resolved into wellness-safe sentences)

    public static func metricNarrative(_ s: MetricSummary, kind: ReportPeriodKind,
                                       language: AppLanguage, arabicDigits: Bool) -> String {
        let label = metricLabel(s.metricId).resolved(language)
        let meanStr = number(s.mean ?? 0, language, arabicDigits, fractionDigits: 0)
        let days = dayCount(s.count, language: language, arabicDigits: arabicDigits)
        let dir = directionClause(s.direction, kind: kind).resolved(language)
        switch language {
        case .en:
            if s.direction == .insufficient { return "Average \(label) was \(meanStr) across \(days)." }
            return "Average \(label) was \(meanStr) across \(days), \(dir)."
        case .ar:
            if s.direction == .insufficient { return "بلغ متوسط \(label) \(meanStr) خلال \(days)." }
            return "بلغ متوسط \(label) \(meanStr) خلال \(days)، \(dir)."
        }
    }

    public static func changeNarrative(_ c: ChangeItem, kind: ReportPeriodKind,
                                       language: AppLanguage, arabicDigits: Bool) -> String {
        let label = metricLabel(c.metricId).resolved(language)
        let cur = number(c.currentMean, language, arabicDigits, fractionDigits: 0)
        let prior = number(c.priorMean, language, arabicDigits, fractionDigits: 0)
        let periodEn = kind == .week ? "week" : "month"
        let periodAr = kind == .week ? "الأسبوع" : "الشهر"
        switch language {
        case .en:
            let word = c.direction == .up ? "higher" : "lower"
            return "\(label) was \(word) this \(periodEn): \(cur) vs \(prior)."
        case .ar:
            let word = c.direction == .up ? "أعلى" : "أدنى"
            return "كان \(label) \(word) هذا \(periodAr): \(cur) مقابل \(prior)."
        }
    }

    public static func adherenceNarrative(_ a: AdherenceSummary, kind: ReportPeriodKind,
                                          language: AppLanguage, arabicDigits: Bool) -> String {
        let logged = doseCount(a.logged, language: language, arabicDigits: arabicDigits)
        let taken = number(Double(a.taken), language, arabicDigits, fractionDigits: 0)
        let late = number(Double(a.late), language, arabicDigits, fractionDigits: 0)
        let skipped = number(Double(a.skipped), language, arabicDigits, fractionDigits: 0)
        let periodEn = kind == .week ? "week" : "month"
        let periodAr = kind == .week ? "الأسبوع" : "الشهر"
        var base: String
        switch language {
        case .en:
            base = "You logged \(logged) this \(periodEn): \(taken) taken, \(late) late, \(skipped) skipped."
        case .ar:
            // The counts after the first are elided doses, so each adjective agrees with a
            // non-human plural — feminine singular ("٣ مأخوذة"), which is the correct form.
            base = "سجّلت \(logged) هذا \(periodAr): \(taken) مأخوذة، و\(late) متأخرة، و\(skipped) متخطّاة."
        }
        if let rate = a.adherenceRate {
            let pct = number(rate * 100, language, arabicDigits, fractionDigits: 0)
            switch language {
            case .en: base += " That's \(pct)% on schedule."
            case .ar: base += " أي \(pct)% ضمن الموعد."
            }
        }
        return base
    }

    /// "Based on {n} records" — the transparency line under a claim.
    public static func evidenceCountPhrase(_ n: Int, language: AppLanguage, arabicDigits: Bool) -> String {
        let count = recordCount(n, language: language, arabicDigits: arabicDigits)
        switch language {
        case .en: return "Based on \(count)"
        case .ar: return "استناداً إلى \(count)"
        }
    }

    // MARK: - Helpers

    private static func directionClause(_ d: TrendDirection, kind: ReportPeriodKind) -> LocalizedString {
        let periodEn = kind == .week ? "week" : "month"
        let periodAr = kind == .week ? "الأسبوع" : "الشهر"
        switch d {
        case .up: return LocalizedString(en: "higher than the previous \(periodEn)", ar: "أعلى من \(periodAr) السابق")
        case .down: return LocalizedString(en: "lower than the previous \(periodEn)", ar: "أدنى من \(periodAr) السابق")
        case .flat: return LocalizedString(en: "about the same as the previous \(periodEn)", ar: "قريب من \(periodAr) السابق")
        case .insufficient: return LocalizedString(en: "no prior \(periodEn) to compare", ar: "لا يوجد \(periodAr) سابق للمقارنة")
        }
    }

    public static func number(_ v: Double, _ language: AppLanguage, _ arabicDigits: Bool, fractionDigits: Int = 0) -> String {
        Numerals.format(v, language: language, arabicDigits: arabicDigits, fractionDigits: fractionDigits)
    }
}
