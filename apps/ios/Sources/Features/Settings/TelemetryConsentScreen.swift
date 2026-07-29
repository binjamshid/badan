import SwiftUI

/// Consent copy for methodology telemetry (ADR-0011 / D-37).
///
/// Three cards, mirroring `AICoachConsentScreen`'s shape — *what leaves this device*, *where it
/// goes*, *what this never does* — because a user meeting their second network feature should not
/// have to learn a second vocabulary for the same question.
///
/// Nothing here is phrased as a benefit to the user, because there is none: this helps BADAN's
/// methodology, not the person opting in. Saying otherwise would be the persuasion this screen is
/// written to avoid.
enum TelemetryConsentCopy {
    static let title = LocalizedString(en: "Help improve the methodology",
                                       ar: "المساعدة في تحسين المنهجية")

    static let intro = LocalizedString(
        en: "BADAN's calculations use constants that have never been validated against real "
            + "people — they are BADAN's own starting guesses. Your \"does this match\" answers are "
            + "the first evidence about whether they are any good, and they are useless to anyone "
            + "else while they stay on your phone.",
        ar: "تستخدم حسابات بادن ثوابت لم يجرِ التحقق منها مع أشخاص حقيقيين — فهي تخمينات بادن "
            + "الأولية. إجاباتك عن \"هل يطابق هذا\" هي أول دليل على جودتها، وهي بلا فائدة لأي شخص "
            + "آخر ما دامت على هاتفك.")

    /// Stated as a limit, not as a reassurance: this is what a submission consists of, in full.
    static let leavesHeader = LocalizedString(en: "What leaves this device", ar: "ما يغادر هذا الجهاز")
    static let leavesLines = [
        LocalizedString(en: "Which metric and which calculation method you disagreed with.",
                        ar: "أي مؤشر وأي طريقة حساب اختلفت معها."),
        LocalizedString(en: "Whether you felt better or worse than the number said — the direction only, never how far.",
                        ar: "هل شعرت بأفضل أو أسوأ مما قاله الرقم — الاتجاه فقط، لا المقدار."),
        LocalizedString(en: "Roughly how many times, as a range like \"10–19\" — never an exact count.",
                        ar: "تقريباً كم مرة، كنطاق مثل \"١٠–١٩\" — لا عدداً دقيقاً أبداً."),
        LocalizedString(en: "Whether BADAN had adjusted that number from your earlier answers.",
                        ar: "هل كان بادن قد عدّل ذلك الرقم بناءً على إجاباتك السابقة."),
    ]

    static let whereHeader = LocalizedString(en: "Where it goes", ar: "إلى أين يذهب")
    static let whereLines = [
        LocalizedString(en: "To badan.binjamshid.com — the same service the AI coach uses, run by BADAN's developer.",
                        ar: "إلى badan.binjamshid.com — الخدمة نفسها التي يستخدمها المدرّب الذكي، ويشغّلها مطوّر بادن."),
        LocalizedString(en: "At a random time one to three days after you answer, so the timing says nothing about when you disagreed.",
                        ar: "في وقت عشوائي بعد يوم إلى ثلاثة من إجابتك، فلا يكشف التوقيت متى اختلفت."),
        LocalizedString(en: "Only after you have answered about the same metric at least ten times. Below that, nothing is ever sent.",
                        ar: "فقط بعد إجابتك عن المؤشر نفسه عشر مرات على الأقل. دون ذلك لا يُرسل شيء أبداً."),
    ]

    static let neverHeader = LocalizedString(en: "What this never does", ar: "ما لا يفعله هذا أبداً")
    static let neverLines = [
        LocalizedString(en: "It never includes a reading. Not your readiness, not your sleep, not any number BADAN calculated.",
                        ar: "لا يتضمّن أي قراءة أبداً. لا جاهزيتك ولا نومك ولا أي رقم حسبه بادن."),
        LocalizedString(en: "It never includes a date — not the day a reading was for, and not the time you answered.",
                        ar: "لا يتضمّن تاريخاً أبداً — لا يوم القراءة ولا وقت إجابتك."),
        LocalizedString(en: "It never includes anything that identifies you or your phone: no account, no device id, no location, no language or country.",
                        ar: "لا يتضمّن أبداً ما يعرّفك أو يعرّف هاتفك: لا حساب ولا معرّف جهاز ولا موقع ولا لغة أو بلد."),
        LocalizedString(en: "Because there is no identifier, BADAN cannot tell your submissions apart from anyone else's — including to undo them. There is nothing to delete on the server, because nothing there is yours.",
                        ar: "لأنه لا يوجد معرّف، لا يستطيع بادن تمييز إرسالاتك عن إرسالات غيرك — ولا حتى للتراجع عنها. لا شيء لحذفه على الخادم، لأن لا شيء هناك يخصّك."),
    ]

    static let toggleTitle = LocalizedString(en: "Send methodology feedback", ar: "إرسال ملاحظات المنهجية")
    static let seeWhatWasSent = LocalizedString(en: "What has been sent", ar: "ما الذي أُرسل")
}

/// Settings → Privacy & Security → the telemetry opt-in.
///
/// Reached only from a row that appears after the user has used the feedback feature. Asking
/// someone to consent to sending "learning footprints" before they have any concept of what that
/// means is itself a dark pattern, so the gate is on having used it, not on having seen a promo.
struct TelemetryConsentScreen: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                LText(TelemetryConsentCopy.intro)
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                bulletCard(TelemetryConsentCopy.leavesHeader, icon: "arrow.up.right.square",
                           tint: BadanColor.info, lines: TelemetryConsentCopy.leavesLines)
                bulletCard(TelemetryConsentCopy.whereHeader, icon: "server.rack",
                           tint: BadanColor.primary, lines: TelemetryConsentCopy.whereLines)
                bulletCard(TelemetryConsentCopy.neverHeader, icon: "hand.raised",
                           tint: BadanColor.info, lines: TelemetryConsentCopy.neverLines)

                BadanCard {
                    // No pre-checked box, no "recommended" badge, no repeat nag. The toggle is
                    // below the three cards so the terms are read before it is reachable.
                    SettingsToggleRow(
                        title: TelemetryConsentCopy.toggleTitle,
                        subtitle: nil,
                        isOn: Binding(
                            get: { env.profile.methodologyTelemetryEnabled },
                            set: { newValue in env.update { $0.methodologyTelemetryEnabled = newValue } }))
                }

                BadanCard {
                    NavigationLink { TelemetrySubmissionLogScreen() } label: {
                        SettingsNavRowLabel(icon: "list.bullet.rectangle",
                                            title: TelemetryConsentCopy.seeWhatWasSent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(TelemetryConsentCopy.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Same shape as `AICoachConsentScreen.bulletCard`, deliberately duplicated rather than shared:
    /// the two screens are consent surfaces for different decisions, and coupling their layout
    /// would mean a change to one silently restyles the other.
    private func bulletCard(_ title: LocalizedString, icon: String, tint: Color,
                            lines: [LocalizedString]) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space2) {
                    Image(systemName: icon)
                        .imageScale(.medium)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(env.s(title))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(env.s(line))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
