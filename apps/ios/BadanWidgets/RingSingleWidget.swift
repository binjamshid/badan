import WidgetKit
import SwiftUI

/// ring_single (EPIC-33 wave 1): the Readiness ring, as a Home Screen `.systemSmall` widget and a
/// Lock Screen / StandBy `.accessoryCircular` complication. Readiness is not sensitive-plus (plan
/// W-11's redaction rule names only `medsDue`), so — unlike `MedsDueWidget` — both families are
/// registered here.
struct RingSingleWidget: Widget {
    static let kind = "RingSingleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotTimelineProvider()) { entry in
            RingSingleWidgetView(entry: entry)
        }
        // Widget-gallery chrome only (the picker's title/subtitle shown before a widget is
        // placed) — English only for this wave. This is OS-level metadata sourced from this
        // extension's own Info.plist localization, a different mechanism entirely from the
        // bilingual ON-WIDGET CONTENT below (which always follows `snapshot.language`); giving
        // this string a real second localization would mean adding `CFBundleLocalizations`/a
        // String Catalog to this target's `project.yml` block, which is out of this slice's
        // owned-files scope.
        .configurationDisplayName("Readiness")
        .description("Today's readiness at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

private enum RingCopy {
    static let title = WidgetCopy(en: "Readiness", ar: "الاستعداد")
    static let noData = WidgetCopy(en: "No data yet", ar: "لا توجد بيانات بعد")
    static let provisional = WidgetCopy(en: "Provisional", ar: "أولي")
}

struct RingSingleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var isArabic: Bool { WidgetLanguage.isArabic(for: entry.snapshot) }
    private var readiness: RingSnapshot? { entry.snapshot?.readiness }

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
        if let readiness {
            Gauge(value: readiness.score, in: 0...100) {
                Text(RingCopy.title.resolved(isArabic: isArabic))
            } currentValueLabel: {
                Text("\(Int(readiness.score.rounded()))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            // Calm "no data yet" state — never a fabricated 0 rendered as if it were a real
            // reading. An empty ring outline plus a moon glyph reads as "nothing to show", not
            // "your readiness is zero".
            ZStack {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Image(systemName: "moon.zzz")
                    .font(.system(size: 14))
            }
        }
    }

    @ViewBuilder
    private var homeBody: some View {
        VStack(spacing: 8) {
            if let readiness {
                ZStack {
                    Circle()
                        .stroke(WidgetColor.textSecondary.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: max(0, min(1, readiness.score / 100)))
                        .stroke(WidgetColor.primary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("\(Int(readiness.score.rounded()))")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(WidgetColor.textPrimary)
                        if readiness.provisional {
                            Text(RingCopy.provisional.resolved(isArabic: isArabic))
                                .font(.system(size: 9))
                                .foregroundStyle(WidgetColor.textSecondary)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                Text(RingCopy.title.resolved(isArabic: isArabic))
                    .font(.caption2)
                    .foregroundStyle(WidgetColor.textSecondary)
            } else {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 32))
                    .foregroundStyle(WidgetColor.textSecondary)
                Text(RingCopy.noData.resolved(isArabic: isArabic))
                    .font(.caption2)
                    .foregroundStyle(WidgetColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(8)
    }
}
