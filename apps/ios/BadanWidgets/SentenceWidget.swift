import WidgetKit
import SwiftUI

/// one_true_sentence (EPIC-33 wave 1): the day's single calm summary sentence, as a Home Screen
/// `.systemSmall` widget and a Lock Screen / StandBy `.accessoryRectangular` complication.
///
/// Family choice for the accessory variant — `.accessoryRectangular` over `.accessoryInline`,
/// documented per this slice's task notes: a "one true sentence" is meant to read as a complete
/// thought, not be cut down to whatever fits on one line next to the clock. `.accessoryInline`
/// allows exactly one line and suits a short fragment ("3 steps to go"), not a full sentence.
/// `.accessoryRectangular`'s multi-line layout lets the actual bilingual, RTL-correct sentence
/// render whole far more often.
struct SentenceWidget: Widget {
    static let kind = "SentenceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotTimelineProvider()) { entry in
            SentenceWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Sentence")
        .description("One calm sentence about how today is going.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

private enum SentenceCopy {
    static let noData = WidgetCopy(
        en: "Nothing to summarize yet — open BADAN to catch up.",
        ar: "لا شيء لتلخيصه بعد — افتح بدن للاطّلاع."
    )
}

struct SentenceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var isArabic: Bool { WidgetLanguage.isArabic(for: entry.snapshot) }

    private var sentenceText: String {
        guard let sentence = entry.snapshot?.sentence else {
            return SentenceCopy.noData.resolved(isArabic: isArabic)
        }
        return isArabic ? sentence.ar : sentence.en
    }

    var body: some View {
        content
            .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
            // Same `.readiness` deep-link token as `RingSingleWidget`: the sentence is presented on
            // Home/Today alongside the readiness ring, and `NotificationDeepLink` — the ONLY
            // existing deep-link vocabulary this target may reuse (see `WidgetDeepLinkToken`'s
            // header comment) — has no dedicated "daily summary" case of its own to reach for.
            .widgetURL(WidgetDeepLinkToken.readiness.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            Text(sentenceText)
                .font(.footnote)
                // Fixed `.leading` — it is NOT swapped to `.trailing` when the language is
                // Arabic. `.leading`/`.trailing` already auto-mirror against the ambient
                // `layoutDirection` set on `body` above. Swapping this a second time based on the
                // language double-flips it — under the Arabic branch, the "opposite edge" value
                // evaluated inside a `.rightToLeft` environment resolves to the SAME visual side
                // as the "same edge" value does under `.leftToRight`, so the two mirrors cancel
                // and Arabic text never actually moves. Leave every alignment below fixed and let
                // the environment override do the mirroring.
                .multilineTextAlignment(.leading)
                .containerBackground(.clear, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text(sentenceText)
                    .font(.subheadline)
                    .foregroundStyle(WidgetColor.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(10)
            .containerBackground(WidgetColor.surface, for: .widget)
        }
    }
}
