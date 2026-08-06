import WidgetKit
import SwiftUI

/// effort_ring: today's effort as a Home Screen `.systemSmall` widget and a Lock Screen / StandBy
/// `.accessoryCircular` complication.
///
/// Deliberately mirrors `RingSingleWidget` rather than inventing a second visual language for the
/// same shape of thing — a 0–100 score in a ring. Both families are registered for the same reason
/// readiness registers both: effort is not sensitive-plus (plan W-11's redaction rule names only
/// `medsDue`), so it is allowed on the Lock Screen subject to the ordinary privacy check.
struct EffortRingWidget: Widget {
    static let kind = "EffortRingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotTimelineProvider()) { entry in
            EffortRingWidgetView(entry: entry)
        }
        // Widget-gallery chrome only, English for this wave — same mechanism and same limitation
        // documented on `RingSingleWidget`.
        .configurationDisplayName("Effort")
        .description("Today's effort at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

private enum EffortCopy {
    /// Verbatim match with `WatchStrings.effort` and `ReportPresentation.metricName`'s
    /// `MetricID.effortDay` case, so the same number is never called two different things across
    /// watch, widget and report.
    static let title = WidgetCopy(en: "Effort", ar: "الجهد")
    static let noData = WidgetCopy(en: "No data yet", ar: "لا توجد بيانات بعد")
}

struct EffortRingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var isArabic: Bool { WidgetLanguage.isArabic(for: entry.snapshot) }
    private var effort: EffortSnapshot? { entry.snapshot?.effort }
    /// W-11: in `.discreet` the ring still draws (a shape is not a disclosure) but the number is
    /// withheld. In `.off` the app writes no `effort` at all, so this falls through to no-data.
    private var showsValue: Bool { WidgetPrivacy.allowsValues(entry.snapshot, family: family) }

    var body: some View {
        content
            .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
            .widgetURL(WidgetDeepLinkToken.readiness.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            accessoryBody
                .containerBackground(.clear, for: .widget)
        default:
            homeBody
                .containerBackground(WidgetColor.surface, for: .widget)
        }
    }

    @ViewBuilder
    private var accessoryBody: some View {
        if let effort {
            Gauge(value: effort.score, in: 0...100) {
                Text(EffortCopy.title.resolved(isArabic: isArabic))
            } currentValueLabel: {
                if showsValue {
                    Text("\(Int(effort.score.rounded()))")
                        // S-5: iOS does NOT redact accessory-family content by itself, so without
                        // this the number renders in full on a LOCKED Lock Screen. Same reasoning,
                        // same placement as `RingSingleWidget` — see that file for the long form.
                        // The arc stays unmarked: a shape is not a disclosure.
                        .privacySensitive()
                } else {
                    Image(systemName: "eye.slash")
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            // Never a fabricated 0. An empty dashed ring reads as "nothing to show"; a filled ring
            // at zero would read as "you did nothing today", which is a claim, not an absence.
            ZStack {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Image(systemName: "figure.walk")
                    .font(.system(size: 14))
            }
        }
    }

    @ViewBuilder
    private var homeBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EffortCopy.title.resolved(isArabic: isArabic))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let effort, showsValue {
                Text("\(Int(effort.score.rounded()))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    // S-5: this `.systemSmall` body is also what StandBy renders, and StandBy
                    // redacts privacy-sensitive content while the device is locked.
                    .privacySensitive()
            } else if effort != nil {
                Image(systemName: "eye.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                Text(EffortCopy.noData.resolved(isArabic: isArabic))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
