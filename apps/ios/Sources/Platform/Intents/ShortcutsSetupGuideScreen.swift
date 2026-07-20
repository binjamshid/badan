import SwiftUI

/// EPIC-19 — the in-app guide for scheduling an export via a Shortcuts time-of-day automation.
///
/// **This screen is the honesty obligation the epic is built around.** Shortcuts is the only path
/// on iOS that runs at a wall-clock time, and it runs *only if the phone is unlocked* at the
/// trigger (plan §13.7). So the screen states that rule — in the sanctioned §13.7 wording — near
/// the top, before the step-by-step, so the user reads it before deciding to set anything up. It
/// never says "every day at", never promises a guaranteed time, and it links Shortcuts directly
/// rather than describing where the app is.
///
/// It deliberately does NOT enable anything itself. BADAN cannot create the automation for the
/// user (iOS gives no API to author a personal automation), and pretending otherwise with a
/// toggle here would be exactly the false-capability dishonesty this codebase keeps removing —
/// the automation is built in Shortcuts, and this screen is a truthful map to it.
struct ShortcutsSetupGuideScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var shortcutsUnavailable = false

    /// The Shortcuts app URL scheme. Opening it lands the user in Shortcuts; from there the
    /// Automation tab is one tap. There is no public URL that deep-links straight into the
    /// new-automation flow, so the guide's steps take over from here rather than the copy
    /// implying a link can skip them.
    private static let shortcutsURL = URL(string: "shortcuts://")!
    /// App Store fallback if Shortcuts was removed (it is removable since iOS 16).
    private static let shortcutsAppStoreURL = URL(string: "https://apps.apple.com/app/shortcuts/id915249334")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                lead
                beforeYouStart
                steps
                otherWays
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(IntentStrings.guideTitle))
        .navigationBarTitleDisplayMode(.inline)
        .alert(env.s(IntentStrings.guideShortcutsMissing), isPresented: $shortcutsUnavailable) {
            Button(env.s(Loc.close), role: .cancel) { }
            Button(env.s(IntentStrings.guideOpenShortcuts)) { openURL(Self.shortcutsAppStoreURL) }
        }
    }

    private var lead: some View {
        LText(IntentStrings.guideLead)
            .font(BadanFont.body)
            .foregroundStyle(BadanColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Unlock requirement, stated first

    private var beforeYouStart: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(IntentStrings.guideBeforeYouStartHeader, language: env.language)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    // The §13.7 line, given visual weight: it is the single sentence the user
                    // most needs to have read before enabling anything.
                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        LText(IntentStrings.guideUnlockRule)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LText(IntentStrings.guideUnlockDetail)
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(BadanColor.separator)
                    LText(IntentStrings.guideLedgerNote)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LText(IntentStrings.guideSensitiveNote)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Step-by-step

    private var steps: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(IntentStrings.guideStepsHeader, language: env.language)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    ForEach(Array(Self.stepStrings.enumerated()), id: \.offset) { index, step in
                        stepRow(number: index + 1, text: step)
                    }
                }
            }
            Button {
                // `shortcuts://` should always resolve on a device that has Shortcuts; the
                // completion tells us if it didn't (removed), and only then do we offer the
                // App Store. `canOpenURL` is avoided because it needs an LSApplicationQueriesSchemes
                // entry for `shortcuts` and this single call site doesn't warrant widening the
                // Info.plist query list — the open-with-completion answers the same question.
                openURL(Self.shortcutsURL) { accepted in
                    if !accepted { shortcutsUnavailable = true }
                }
            } label: {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: "arrow.up.forward.app")
                        .accessibilityHidden(true)
                    LText(IntentStrings.guideOpenShortcuts)
                }
                .font(BadanFont.link)
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.borderedProminent)
            .tint(BadanColor.primary)
        }
    }

    private func stepRow(number: Int, text: LocalizedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space3) {
            Text(env.format.integer(number))
                .font(BadanFont.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(BadanColor.primary)
                .frame(minWidth: BadanSpace.space5, alignment: .leading)
                .accessibilityHidden(true)
            LText(text)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private static let stepStrings: [LocalizedString] = [
        IntentStrings.guideStep1, IntentStrings.guideStep2, IntentStrings.guideStep3,
        IntentStrings.guideStep4, IntentStrings.guideStep5, IntentStrings.guideStep6,
        IntentStrings.guideStep7,
    ]

    // MARK: - The full reliability picture

    private var otherWays: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(IntentStrings.guideOtherWaysHeader, language: env.language)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    reliabilityRow(icon: "hand.tap", text: IntentStrings.guideManualRun)
                    reliabilityRow(icon: "app.badge", text: IntentStrings.guideWhenYouOpen)
                    reliabilityRow(icon: "clock.badge.questionmark", text: IntentStrings.guideShortcutsRow)
                    reliabilityRow(icon: "arrow.triangle.2.circlepath", text: IntentStrings.guideBackground)
                }
            }
        }
    }

    private func reliabilityRow(icon: String, text: LocalizedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(BadanColor.textSecondary)
                .frame(minWidth: BadanSpace.space5)
                .accessibilityHidden(true)
            LText(text)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
