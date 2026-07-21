import SwiftUI

/// The cold-start calibration state shown on a score card while a contributing baseline is still
/// filling its window — "Day 9 of 14", the reassurance, and (at power depth) the method and window.
///
/// This is the surface behind plan §16's cold-start row: *"We don't guess before we know you."* It
/// exists so a still-thin baseline is never dressed up as an established personal normal, and so the
/// wait reads as a countdown with an end rather than an open-ended "not enough data" (EASE-139 spirit).
/// It renders from a `BaselineCalibration` read model (`BaselineEngine.calibration(metricId:)`), which
/// carries the numbers and the tier; this owns only the bilingual strings and the progress bar.
struct CalibrationNote: View {
    let calibration: BaselineCalibration
    var language: AppLanguage
    var format: ValueFormatter
    /// Power depth adds the method + window line; casual keeps to the countdown + reassurance.
    var showsDetail: Bool

    private enum Copy {
        static let reassurance = LocalizedString(
            en: "We don't guess before we know you.",
            ar: "لا نُخمّن قبل أن نعرفك.")
        static let dayOf = LocalizedString(en: "Day {n} of {total}", ar: "اليوم {n} من {total}")
        static let learning = LocalizedString(en: "Still learning your baseline", ar: "ما زلنا نتعرّف على مستواك المعتاد")
        // Method line (power). Named locally so wording can evolve without touching the anatomy
        // sheet's own `AnatomyStrings.typicalRange`.
        static let method = LocalizedString(
            en: "Method: your personal median ± typical variation over {total} days",
            ar: "الطريقة: وسيطك الشخصي ± التغيّر المعتاد عبر {total} يوم")
        static let methodLog = LocalizedString(
            en: "Method: your personal median ± typical variation (log-scaled) over {total} days",
            ar: "الطريقة: وسيطك الشخصي ± التغيّر المعتاد (بمقياس لوغاريتمي) عبر {total} يوم")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            HStack(spacing: BadanSpace.space2) {
                ProvisionalBadge(language: language)
                Text(progressText)
                    .font(BadanFont.caption.monospacedDigit())
                    .foregroundStyle(BadanColor.textSecondary)
            }
            CalibrationProgressBar(fraction: fraction)
                .frame(height: 6)
                .accessibilityHidden(true)
            Text(Copy.reassurance, language: language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsDetail {
                Text(methodText)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Copy.learning.resolved(language)). \(progressText). \(Copy.reassurance.resolved(language))")
    }

    /// The countdown target: the full window the band aims to fill. `nPoints` is clamped to it so a
    /// backfilled baseline that briefly overshoots never reads "Day 20 of 14".
    private var progressText: String {
        let n = min(calibration.nPoints, calibration.windowDays)
        return CalibrationCount.dayPhrase(n: n, total: calibration.windowDays,
                                          language: language, format: format, template: Copy.dayOf)
    }

    private var fraction: Double {
        guard calibration.windowDays > 0 else { return 0 }
        return min(1, max(0, Double(calibration.nPoints) / Double(calibration.windowDays)))
    }

    private var methodText: String {
        let template = calibration.transform == .log ? Copy.methodLog : Copy.method
        return template.filling(["total": format.integer(calibration.windowDays)]).resolved(language)
    }
}

/// A thin, non-alarming progress track for the calibration countdown. Uses `primary` (the app's own
/// brand tint) rather than a status colour — filling a window is neutral progress, never a verdict.
private struct CalibrationProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BadanColor.surfaceElevated)
                Capsule()
                    .fill(BadanColor.primary.opacity(0.55))
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        // Progress reads left-to-right; only the fill origin is pinned, the surrounding card mirrors.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Arabic count-noun agreement for the calibration countdown, mirroring `HomeArabicCount`'s rule
/// (1 singular · 2 dual · 3–10 plural · 11+ indeclinable) for the day noun that agrees with `total`.
/// English needs no counted noun ("Day 9 of 14"), so only the Arabic branch appends one. Kept local
/// to the DesignSystem layer rather than reaching into `Features/Home` so this component stays
/// self-contained. Not `private` so a test can exercise the 1/2/3–10/11+ boundaries directly.
enum CalibrationCount {
    static func dayPhrase(n: Int, total: Int, language: AppLanguage,
                          format: ValueFormatter, template: LocalizedString) -> String {
        let filled = template.filling(["n": format.integer(n), "total": format.integer(total)])
        guard language == .ar else { return filled.en }
        let noun: String
        switch total {
        case 1: noun = "يوم"
        case 2: noun = "يومان"
        case 3...10: noun = "أيام"
        default: noun = "يوماً"
        }
        // "اليوم 9 من 14 يوماً" — the appended noun agrees with `total` (the window being described).
        return "\(filled.ar) \(noun)"
    }
}
