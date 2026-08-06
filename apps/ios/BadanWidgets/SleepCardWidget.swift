import WidgetKit
import SwiftUI

/// sleep_last_night (EPIC-33 wave 1): last night's sleep, as a Home Screen `.systemMedium` widget
/// and a Lock Screen / StandBy `.accessoryRectangular` complication. Sleep is not sensitive-plus
/// (plan W-11's redaction rule names only `medsDue`), so both families are registered here.
struct SleepCardWidget: Widget {
    static let kind = "SleepCardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotTimelineProvider()) { entry in
            SleepCardWidgetView(entry: entry)
        }
        .configurationDisplayName("Sleep")
        .description("Last night's sleep duration and score.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

private enum SleepCopy {
    static let title = WidgetCopy(en: "Last night", ar: "الليلة الماضية")
    static let noData = WidgetCopy(en: "No sleep data yet", ar: "لا توجد بيانات نوم بعد")
    static let provisional = WidgetCopy(en: "Provisional", ar: "أولي")
    static let noScore = WidgetCopy(en: "Score not available yet", ar: "لا يتوفر تقييم بعد")
}

struct SleepCardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var isArabic: Bool { WidgetLanguage.isArabic(for: entry.snapshot) }
    /// W-11: withheld entirely in `.discreet` — a sleep duration has no shape-only form, so this
    /// view treats "values not allowed" the same way it treats "no sleep recorded", which is
    /// already a calm, non-alarming state it renders correctly. `.off` writes no sleep at all.
    private var sleep: SleepSnapshot? {
        WidgetPrivacy.allowsValues(entry.snapshot, family: family) ? entry.snapshot?.sleep : nil
    }

    var body: some View {
        content
            .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
            .widgetURL(WidgetDeepLinkToken.sleep.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            accessoryBody
                .containerBackground(.clear, for: .widget)
        default:
            homeBody
                .containerBackground(WidgetColor.surface, for: .widget)
        }
    }

    @ViewBuilder
    private var accessoryBody: some View {
        // Fixed `.leading` — here and everywhere else below, it is NOT swapped to `.trailing`
        // when the language is Arabic. `.leading`/`.trailing` already auto-mirror against the
        // `.environment(\.layoutDirection, ...)` override applied on `body`. Swapping them a
        // second time based on the language double-flips: under the Arabic branch, the "opposite
        // edge" value evaluated inside a `.rightToLeft` environment resolves to the SAME visual
        // side as the "same edge" value does under `.leftToRight`, so the two mirrors cancel and
        // Arabic text never actually moves. Keep the environment override, leave these fixed.
        VStack(alignment: .leading, spacing: 2) {
            Text(SleepCopy.title.resolved(isArabic: isArabic))
                .font(.caption2)
            if let sleep {
                Text(durationText(sleep.durationMinutes))
                    .font(.headline)
                    // S-5: iOS does NOT redact accessory-family content by itself — without this
                    // last night's sleep duration renders in full on a LOCKED Lock Screen. Only
                    // the value is marked; the "Last night" label above stays visible, so the
                    // complication still reads as a BADAN sleep tile rather than an empty box.
                    .privacySensitive()
            } else {
                Text(SleepCopy.noData.resolved(isArabic: isArabic))
                    .font(.caption2)
            }
        }
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var homeBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 26))
                .foregroundStyle(WidgetColor.primary)
            // Fixed `.leading` (see `accessoryBody`'s comment above for why this is never
            // conditioned on `isArabic`).
            VStack(alignment: .leading, spacing: 3) {
                Text(SleepCopy.title.resolved(isArabic: isArabic))
                    .font(.caption)
                    .foregroundStyle(WidgetColor.textSecondary)
                if let sleep {
                    Text(durationText(sleep.durationMinutes))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(WidgetColor.textPrimary)
                        // S-5: `.systemMedium` is a StandBy surface too, and StandBy redacts
                        // privacy-sensitive content while the device is locked.
                        .privacySensitive()
                    scoreLine(sleep)
                        .privacySensitive()
                } else {
                    Text(SleepCopy.noData.resolved(isArabic: isArabic))
                        .font(.footnote)
                        .foregroundStyle(WidgetColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private func scoreLine(_ sleep: SleepSnapshot) -> some View {
        if let score = sleep.score {
            HStack(spacing: 4) {
                Text("\(Int(score.rounded()))")
                    .font(.footnote)
                    .foregroundStyle(WidgetColor.textSecondary)
                if sleep.provisional {
                    Text("•").font(.footnote).foregroundStyle(WidgetColor.textSecondary)
                    Text(SleepCopy.provisional.resolved(isArabic: isArabic))
                        .font(.footnote)
                        .foregroundStyle(WidgetColor.textSecondary)
                }
            }
        } else {
            // A missing score (e.g. no baseline yet) is shown honestly rather than fabricated —
            // the duration above still renders on its own.
            Text(SleepCopy.noScore.resolved(isArabic: isArabic))
                .font(.footnote)
                .foregroundStyle(WidgetColor.textSecondary)
        }
    }

    /// `DateComponentsFormatter` rather than a hand-rolled "Xh Ym" string, so the Arabic rendering
    /// is grammatically real localized output (this target has no `Numerals`/locale-aware
    /// formatter of its own to import — see `AmbientSnapshotDto.swift`'s header comment).
    private func durationText(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        // `DateComponentsFormatter` has no direct `locale` property — it localizes off its
        // `calendar`'s locale instead.
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: isArabic ? "ar" : "en_US")
        formatter.calendar = calendar
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        return formatter.string(from: components) ?? "\(minutes)m"
    }
}
