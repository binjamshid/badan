import SwiftUI

// MARK: - A9 / ADR-0010 / D-22 — the AI coach's single consent/settings screen.
//
// Mirrors `CycleConsentScreen`'s two-role shape exactly (onboarding vs settings, switched purely
// on `env.profile.aiCoachEnabled`) and borrows `RouteConsentScreen`'s labeled-card layout for a
// network/data-leaves-device decision — the recon precedent for this exact kind of screen. Every
// sentence below stays inside the same honesty boundary those two screens hold themselves to:
// name exactly what leaves the device, to which service, and how to reverse it — never "private,"
// "secure," or "safe" as a bare adjective, and never a diagnosis/fear/moral-judgment/causal word
// (the same 5-rule wellness lexicon `packages/contracts/insights/templates.json`'s `wellnessRules`
// enforces mechanically for insight copy — applied here by hand, since this screen's strings
// aren't in that file; see `docs/BADAN_iOS_Audit_2026-07-23.md`'s recon note on that gap).
//
// D-22's own words: "No query leaves the device until the user explicitly enables the AI coach
// feature through its own consent screen (separate from onboarding), naming what is sent (the
// query + minimal retrieved context, never raw health rows, never an export bundle) and to which
// service." This screen is that naming.
struct AICoachConsentScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var client = AICoachClient()
    @State private var isWorking = false
    @State private var navigateToChat = false
    @State private var errorNotice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if env.profile.aiCoachEnabled {
                    settingsContent
                } else {
                    onboardingContent
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(AICoachConsentStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        // `AICoachChatScreen` is the coach's own chat surface (built alongside this file) —
        // referenced here by name only, matching `CycleConsentScreen`'s identical cross-file
        // navigation-destination pattern.
        .navigationDestination(isPresented: $navigateToChat) {
            AICoachChatScreen()
        }
    }

    // MARK: - Onboarding (aiCoachEnabled == false)

    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            Text(env.s(AICoachConsentStrings.introBody))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            bulletCard(AICoachConsentStrings.leavesHeader, icon: "arrow.up.right.square", tint: BadanColor.info,
                       lines: [AICoachConsentStrings.pointQueryAndContext, AICoachConsentStrings.pointNeverRaw])
            bulletCard(AICoachConsentStrings.whereHeader, icon: "server.rack", tint: BadanColor.primary,
                       lines: [AICoachConsentStrings.pointHostedService])
            bulletCard(AICoachConsentStrings.neverHeader, icon: "hand.raised", tint: BadanColor.info,
                       lines: [AICoachConsentStrings.pointNoAccount, AICoachConsentStrings.pointReversible])

            if let errorNotice {
                noticeCard(errorNotice, icon: "exclamationmark.triangle", tint: BadanColor.outOfBand)
            }

            Button {
                enableModule()
            } label: {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(env.s(AICoachConsentStrings.enableAction))
                            .font(BadanFont.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.borderedProminent)
            .tint(BadanColor.primary)
            .disabled(isWorking)
            .accessibilityLabel(Text(AICoachConsentStrings.enableAction, language: env.language))
        }
    }

    /// Turning ON: register a fresh device token FIRST (the network call and the only place one
    /// happens in this whole flow), and only flip BADAN's own `aiCoachEnabled` flag after that
    /// succeeds — mirroring `RouteConsentStore`'s "write BADAN's own consent first, then perform
    /// the network-adjacent action" ordering discipline, just in the opposite sequence, because
    /// here the ONE thing that must never happen is the flag reading "on" with no token behind
    /// it (which would make the chat screen's "not enabled" state a lie). A failed registration
    /// leaves everything exactly as it was — no flag flip, no navigation, just an inline notice.
    private func enableModule() {
        guard !isWorking else { return }
        isWorking = true
        errorNotice = nil
        Task {
            do {
                try await client.register()
                isWorking = false
                env.update { $0.aiCoachEnabled = true }
                navigateToChat = true
            } catch AICoachError.attestationUnavailable {
                // Not a connection failure, and not retryable — telling the user to "check your
                // connection and try again" here would send them round a loop that cannot
                // succeed. See `AICoachError.attestationUnavailable`.
                isWorking = false
                errorNotice = AICoachConsentStrings.enableUnavailableNotice
                Announce.failure(env.s(AICoachConsentStrings.enableUnavailableNotice))
            } catch {
                isWorking = false
                errorNotice = AICoachConsentStrings.enableFailedNotice
                Announce.failure(env.s(AICoachConsentStrings.enableFailedNotice))
            }
        }
    }

    // MARK: - Settings (aiCoachEnabled == true)

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AICoachConsentStrings.moduleSectionHeader))
                BadanCard {
                    SettingsToggleRow(
                        title: AICoachConsentStrings.moduleToggleTitle,
                        subtitle: AICoachConsentStrings.moduleToggleSubtitle,
                        isOn: Binding(
                            get: { env.profile.aiCoachEnabled },
                            set: { newValue in disableModule(newValue) }
                        )
                    )
                }
            }

            bulletCard(AICoachConsentStrings.leavesHeader, icon: "arrow.up.right.square", tint: BadanColor.info,
                       lines: [AICoachConsentStrings.pointQueryAndContext, AICoachConsentStrings.pointNeverRaw])
            bulletCard(AICoachConsentStrings.whereHeader, icon: "server.rack", tint: BadanColor.primary,
                       lines: [AICoachConsentStrings.pointHostedService])
        }
    }

    /// AUDIT FIX-shaped note (mirrors `CycleConsentScreen.disableModule`'s own comment): this
    /// toggle is only ever shown — and only ever flips to `false` — while `aiCoachEnabled` is
    /// already `true`, so this is exactly the reverse of `enableModule()`: delete the token FIRST
    /// (so a mid-flight kill never leaves a live token behind a flag that reads "off"), then
    /// persist the flag, then leave via `dismiss()` rather than let this same still-titled-as-
    /// settings screen re-render its own body as `onboardingContent` mid-navigation.
    private func disableModule(_ newValue: Bool) {
        guard !newValue else { return }
        client.disable()
        env.update { $0.aiCoachEnabled = newValue }
        dismiss()
    }

    // MARK: - Cards

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

    private func noticeCard(_ body: LocalizedString, icon: String, tint: Color) -> some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(env.s(body))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Screen-local strings (bilingual; wellness-safe by hand — see file header)

private enum AICoachConsentStrings {
    static let title = LocalizedString(en: "AI coach", ar: "المدرب الذكي")

    static let introBody = LocalizedString(
        en: "Ask about your own numbers and get a plain-language reply. Turning this on lets you "
            + "type a question and sends it — along with a short summary of today's Readiness, "
            + "Effort, and Sleep scores — to a hosted AI service so it can answer. Off by default; "
            + "nothing is sent anywhere until you turn it on here.",
        ar: "اسأل عن أرقامك الخاصة واحصل على إجابة بلغة واضحة. تفعيل هذا الخيار يتيح لك كتابة سؤال "
            + "وإرساله — مع ملخص قصير لنتائج الجاهزية والجهد والنوم لهذا اليوم — إلى خدمة ذكاء "
            + "اصطناعي مستضافة كي تجيب عليه. هذا الخيار متوقف افتراضيًا؛ لا يُرسَل أي شيء إلى أي "
            + "مكان قبل أن تفعّله من هنا.")

    static let leavesHeader = LocalizedString(en: "What leaves this device", ar: "ما الذي يغادر جهازك")
    static let pointQueryAndContext = LocalizedString(
        en: "The question you type, plus a short named summary — for example today's Readiness, "
            + "Effort, and Sleep scores, each shown with its confidence and the published method "
            + "that produced it.",
        ar: "السؤال الذي تكتبه، مع ملخص قصير مسمّى — مثل نتائج الجاهزية والجهد والنوم لهذا اليوم، "
            + "موضّحة مع مستوى الثقة والطريقة المنشورة التي أنتجتها.")
    static let pointNeverRaw = LocalizedString(
        en: "Never your raw measurements, and never an export bundle — only the small summary "
            + "shown to you before you send.",
        ar: "لا تُرسَل قياساتك الخام أبدًا، ولا حزمة تصدير أبدًا — فقط الملخص الصغير المعروض لك قبل "
            + "الإرسال.")

    static let whereHeader = LocalizedString(en: "Where it goes", ar: "إلى أين يذهب")
    static let pointHostedService = LocalizedString(
        en: "To BADAN's own server, which forwards your question to a hosted AI service to "
            + "generate a reply. The server keeps no accounts and no copy of your questions or "
            + "replies.",
        ar: "إلى خادم بدن الخاص، الذي يمرّر سؤالك إلى خدمة ذكاء اصطناعي مستضافة لإنشاء إجابة. لا "
            + "يحتفظ الخادم بأي حسابات ولا بأي نسخة من أسئلتك أو إجاباتك.")

    static let neverHeader = LocalizedString(en: "What this never does", ar: "ما لا يفعله هذا أبداً")
    static let pointNoAccount = LocalizedString(
        en: "No account is created — BADAN still has none. Turning this on only issues an "
            + "anonymous device token so the server can tell devices apart.",
        ar: "لا يُنشأ أي حساب — يبقى بدن بلا حسابات. تفعيل هذا الخيار يصدر فقط رمزًا مجهولاً خاصًا "
            + "بالجهاز كي يستطيع الخادم التمييز بين الأجهزة.")
    static let pointReversible = LocalizedString(
        en: "Turn it off anytime, right here. Your device token is deleted immediately and "
            + "nothing more is sent — turning it back on later starts fresh with a new token.",
        ar: "أوقفه في أي وقت من هنا مباشرة. يُحذف رمز جهازك فورًا ولا يُرسَل أي شيء آخر — وإعادة "
            + "تفعيله لاحقًا تبدأ من جديد برمز جديد.")

    static let enableAction = LocalizedString(en: "Turn on AI coach", ar: "تفعيل المدرب الذكي")
    static let enableFailedNotice = LocalizedString(
        en: "Couldn't turn on the AI coach. Check your connection and try again.",
        ar: "تعذّر تفعيل المدرب الذكي. تحقّق من اتصالك وحاول مرة أخرى.")
    /// Distinct from `enableFailedNotice` because the remedy is different: this is not a
    /// connection problem and retrying will never succeed. It is what a simulator build, or a
    /// device where the platform declines to vend App Attest, hits. Worded without jargon —
    /// "verify" rather than "attest" — and without implying the user did anything wrong.
    static let enableUnavailableNotice = LocalizedString(
        en: "This device can't verify the app with Apple, so the AI coach can't be turned on "
            + "here. Everything else in BADAN works as usual.",
        ar: "لا يستطيع هذا الجهاز التحقّق من التطبيق لدى Apple، لذا لا يمكن تفعيل المدرب الذكي "
            + "هنا. بقية أجزاء بدن تعمل كالمعتاد.")

    static let moduleSectionHeader = LocalizedString(en: "AI coach", ar: "المدرب الذكي")
    static let moduleToggleTitle = LocalizedString(en: "AI coach", ar: "المدرب الذكي")
    static let moduleToggleSubtitle = LocalizedString(
        en: "Turn this off to stop sending anything to the AI service right away. Nothing from "
            + "this conversation is saved on this device or the server, so there's nothing else "
            + "to remove.",
        ar: "أوقف هذا لإيقاف إرسال أي شيء إلى خدمة الذكاء الاصطناعي فورًا. لا يُحفظ أي شيء من هذه "
            + "المحادثة على هذا الجهاز أو على الخادم، فلا يوجد شيء آخر لإزالته.")
}
