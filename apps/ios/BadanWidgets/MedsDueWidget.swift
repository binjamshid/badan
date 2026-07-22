import WidgetKit
import SwiftUI

/// meds_due (EPIC-33 wave 1): Home Screen `.systemSmall` ONLY.
///
/// Medications are sensitive-plus (INVARIANTS.md I7 — a physically separate, purgeable namespace),
/// and plan W-11's redaction rule for this content is structural, not a "hide when locked" toggle
/// a user could ever configure around: "lock screens never show disallowed data" is stated as
/// non-overridable for sensitive-plus. The safest way to GUARANTEE that structurally — rather than
/// trusting a shared view to correctly branch on "am I rendering on a lock screen right now?" — is
/// to never register an accessory family for this widget kind at all. There is then no code path
/// in this file that could ever be asked to draw `medsDue` content anywhere but the Home Screen.
///
/// Do NOT add `.accessoryCircular` / `.accessoryRectangular` / `.accessoryInline` to
/// `supportedFamilies` below. `WidgetDeepLinkTests.swift` (`apps/ios/Tests/`) asserts this file
/// never even mentions those family names, as a ratchet against it happening by accident later.
struct MedsDueWidget: Widget {
    static let kind = "MedsDueWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotTimelineProvider()) { entry in
            MedsDueWidgetView(entry: entry)
        }
        .configurationDisplayName("Meds Due")
        .description("Medications due soon, once you turn this on in Settings.")
        .supportedFamilies([.systemSmall])
    }
}

private enum MedsDueCopy {
    static let title = WidgetCopy(en: "Meds", ar: "الأدوية")
    static let consentPrompt = WidgetCopy(
        en: "Turn this on in Settings to see medications due here.",
        ar: "فعّل هذا من الإعدادات لرؤية الأدوية المستحقة هنا."
    )
    static let allClear = WidgetCopy(en: "Nothing due right now", ar: "لا شيء مستحق الآن")
    static let andMoreTemplate = WidgetCopy(en: "+{n} more", ar: "+{n} أخرى")
}

struct MedsDueWidgetView: View {
    let entry: SnapshotEntry

    private var isArabic: Bool { WidgetLanguage.isArabic(for: entry.snapshot) }
    /// nil (key absent from the snapshot) = consent not granted; present-with-empty-items =
    /// consent granted, nothing due right now. Two different, real states — the frozen DTO's own
    /// doc comment is explicit that these must never share copy.
    private var medsDue: MedsDueSnapshot? { entry.snapshot?.medsDue }

    var body: some View {
        // Every `.leading`/`.trailing` value in this body (including the inner due-list `HStack`
        // in `dueListBody` below, which correctly has NO conditional at all) is fixed — it is
        // NOT swapped to the opposite edge when the language is Arabic. `.leading`/`.trailing`
        // already auto-mirror against the `.environment(\.layoutDirection, ...)` override two
        // lines down — swapping them a second time based on the language double-flips: under the
        // Arabic branch, the "opposite edge" value evaluated inside a `.rightToLeft` environment
        // resolves to the SAME visual side as the "same edge" value does under `.leftToRight`, so
        // the two mirrors cancel and Arabic text never actually moves. Keep the environment
        // override (it IS needed — see its own site) and leave alignment fixed.
        VStack(alignment: .leading, spacing: 4) {
            Text(MedsDueCopy.title.resolved(isArabic: isArabic))
                .font(.caption)
                .foregroundStyle(WidgetColor.textSecondary)
            Spacer(minLength: 0)
            stateBody
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .padding(10)
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        // Tab-granularity deep link (the only granularity `NotificationDeepLink` offers today — see
        // its own `.tab` doc comment in `NotificationDecisionEngine.swift`): `.meds` resolves to the
        // Log tab, where medication management is anchored in this app, for all three states below
        // — including the "enable in Settings" prompt, since there is no dedicated Settings case in
        // the vocabulary this target may reuse (see `WidgetDeepLinkToken`'s header comment).
        .widgetURL(WidgetDeepLinkToken.meds.url)
        .containerBackground(WidgetColor.surface, for: .widget)
    }

    @ViewBuilder
    private var stateBody: some View {
        if let medsDue {
            if medsDue.items.isEmpty {
                allClearBody
            } else {
                dueListBody(medsDue.items)
            }
        } else {
            consentPromptBody
        }
    }

    /// State 1: consent not granted.
    private var consentPromptBody: some View {
        Text(MedsDueCopy.consentPrompt.resolved(isArabic: isArabic))
            .font(.footnote)
            .foregroundStyle(WidgetColor.textSecondary)
    }

    /// State 2: consent granted, nothing due right now.
    private var allClearBody: some View {
        Label {
            Text(MedsDueCopy.allClear.resolved(isArabic: isArabic))
                .font(.footnote)
                .foregroundStyle(WidgetColor.textPrimary)
        } icon: {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(WidgetColor.primary)
        }
    }

    /// State 3: consent granted, one or more medications due.
    private func dueListBody(_ items: [MedsDueItem]) -> some View {
        // Fixed `.leading` — see the comment on `body` above for why this is never conditioned on
        // `isArabic`. The `HStack` below has no alignment conditional at all (it never did), which
        // is exactly the pattern the fix above brings the rest of this file in line with: the
        // ambient `layoutDirection` environment alone is what mirrors it for Arabic.
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.prefix(2), id: \.regimenId) { item in
                HStack {
                    Text(item.displayName)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(WidgetColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.timeLabel)
                        .font(.caption2)
                        .foregroundStyle(WidgetColor.textSecondary)
                }
            }
            if items.count > 2 {
                Text(MedsDueCopy.andMoreTemplate.resolved(isArabic: isArabic)
                    .replacingOccurrences(of: "{n}", with: "\(items.count - 2)"))
                    .font(.caption2)
                    .foregroundStyle(WidgetColor.textSecondary)
            }
        }
    }
}
