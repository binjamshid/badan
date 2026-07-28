import SwiftUI

private enum AccountStrings {
    static let localHeader = LocalizedString(en: "This device", ar: "هذا الجهاز")
    static let localBlurb = LocalizedString(
        en: "BADAN works with no account at all. Your data lives on this device and is yours "
            + "whether or not you ever sign in.",
        ar: "يعمل بدن دون أي حساب. تعيش بياناتك على هذا الجهاز وهي ملكك سواء سجّلت الدخول أم لا.")
    static let storageMode = LocalizedString(en: "Data location", ar: "موقع البيانات")
    static let onDevice = LocalizedString(en: "On this device", ar: "على هذا الجهاز")
    static let temporary = LocalizedString(en: "Temporary — not being saved", ar: "مؤقت — لا يُحفَظ")

    static let accountHeader = LocalizedString(en: "Account", ar: "الحساب")
    static let signIn = LocalizedString(en: "Sign in with Apple", ar: "تسجيل الدخول عبر Apple")
    static let accountBlurb = LocalizedString(
        en: "An account will be optional — it exists to carry a subscription across your devices, "
            + "never to hold your health data.",
        ar: "سيكون الحساب اختيارياً — وُجد لنقل الاشتراك بين أجهزتك، لا للاحتفاظ ببياناتك الصحية.")

    static let subscriptionHeader = LocalizedString(en: "Subscription", ar: "الاشتراك")
    static let subscribe = LocalizedString(en: "BADAN premium", ar: "بدن بريميوم")
    static let freeForeverTitle = LocalizedString(en: "Free, always", ar: "مجاني، دائماً")
    static let freeForeverBody = LocalizedString(
        en: "Your readings, their full history and provenance, the metric browser, export in every "
            + "format, and deletion are free and always will be. A subscription would only ever "
            + "buy BADAN's interpretation of your data — never access to it.",
        ar: "قراءاتك وسِجلّها الكامل ومصدرها، ومتصفّح المقاييس، والتصدير بكل صيغه، والحذف — كلها "
            + "مجانية وستبقى كذلك. ولن يشتري الاشتراك يوماً سوى تفسير بدن لبياناتك — لا الوصول إليها.")
}

/// Settings -> Account & subscription.
///
/// Neither exists yet. BADAN has no accounts, no payments and no network calls of any kind — that
/// is `ADR-0002` ("No backend in MVP"), and it is load-bearing: `backend/` and `infra/` are empty
/// by decision, the export module is lint-forbidden from importing networking (D-8), and "zero
/// network calls" is a verified claim in the privacy policy, the hosted policy, and the App Store
/// submission record.
///
/// So this page shows what IS true today (your data is on this device, no account needed) and
/// names what isn't built, rather than a sign-in button that would do nothing. See
/// `docs/MONETIZATION.md` for the proposed free/premium line and the sequencing — chiefly that
/// only a fraction of the ontology's metrics are actually ingested today, so the features a
/// subscription would sell do not yet have data to run on.
///
/// Both figures are deliberately left unwritten here (audit finding #9): this line used to read
/// "only 4 of the ontology's 44 metrics", and both halves had gone stale — the registry is well
/// past 44 and the ingested set has grown several times since. Two numbers that move on different
/// schedules, hand-copied into a doc comment, are two numbers that will be wrong again. The live
/// counts are `MetricRegistry.shared.all.count` for the catalogue and the `HKTypeMap` entries
/// carrying a non-nil `metricId` for the ingested set; read them there rather than restoring a
/// literal.
///
/// The "free, always" card is not marketing. It is the guardrail (`CLAUDE.md`: raw data is not
/// paywalled) stated where a user would come looking for the catch, and it should survive
/// whatever monetization lands.
struct AccountSettingsScreen: View {
    /// The row's subtitle states where the user actually stands rather than a generic upsell — the
    /// same posture `PaywallScreen.statusLine` takes.
    private var subscriptionStatus: LocalizedString {
        switch env.subscription.access {
        case .subscribed: return PaywallCopy.statusSubscribed
        case .trial(let days): return PaywallCopy.statusTrial(env.format.integer(days))
        case .trialExpired: return PaywallCopy.statusExpired
        case .notYetStarted: return PaywallCopy.statusTrial(env.format.integer(SubscriptionPolicy.trialDays))
        }
    }

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                localSection
                accountSection
                subscriptionSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.account.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(AccountStrings.localHeader))
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    LText(AccountStrings.storageMode)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    // Honest about the fallback here too: a user asking "where is my data?" on a
                    // scratch-DB session deserves the real answer (EDGE-05).
                    LText(env.isStorageFallback ? AccountStrings.temporary : AccountStrings.onDevice)
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(env.isStorageFallback ? BadanColor.outOfBand : BadanColor.textSecondary)
                }
                .frame(minHeight: BadanSpace.touchMin)
                .accessibilityElement(children: .combine)
            }
            LText(AccountStrings.localBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(AccountStrings.accountHeader))
            UnbuiltFeatureNotice(feature: AccountStrings.signIn)
            LText(AccountStrings.accountBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(AccountStrings.subscriptionHeader))
            // Was an `UnbuiltFeatureNotice` — the honest placeholder this codebase uses for a
            // surface that does not exist yet. It exists now, so the notice goes rather than
            // sitting above a working paywall telling the user it is unbuilt.
            NavigationLink { PaywallScreen() } label: {
                BadanCard {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "sparkles")
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SettingsStrings.subscriptionRow, language: env.language)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(subscriptionStatus, language: env.language)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        Spacer(minLength: BadanSpace.space2)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "lock.open")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.inBand)
                            .accessibilityHidden(true)
                        LText(AccountStrings.freeForeverTitle)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    LText(AccountStrings.freeForeverBody)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
