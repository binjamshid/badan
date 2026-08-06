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
    /// The blurb used to end "…never to hold your health data" in the future tense, because the
    /// account did not exist. It exists now (D-44) and the sentence is unchanged in substance: what
    /// the account carries is a subscription and a referral code, and nothing else.
    static let accountBlurb = LocalizedString(
        en: "An account is optional — it exists to carry a subscription between your iPhone and "
            + "your Android phone, and to run referrals. It never holds your health data. BADAN "
            + "works exactly the same signed out.",
        ar: "الحساب اختياري — وُجد لنقل الاشتراك بين هاتفك الآيفون وهاتف أندرويد، ولتشغيل الإحالات. "
            + "ولا يحتفظ ببياناتك الصحية أبداً. ويعمل بدن بالطريقة نفسها تماماً دون تسجيل دخول.")
    static let signedInAs = LocalizedString(en: "Signed in", ar: "مسجَّل الدخول")
    static let signOut = LocalizedString(en: "Sign out on this device", ar: "تسجيل الخروج من هذا الجهاز")
    static let signOutBlurb = LocalizedString(
        en: "Your account and subscription stay as they are. Sign in again any time.",
        ar: "يبقى حسابك واشتراكك كما هما. يمكنك تسجيل الدخول مجدداً في أي وقت.")
    static let deleteAccount = LocalizedString(en: "Delete account", ar: "حذف الحساب")
    static let deleteConfirmTitle = LocalizedString(en: "Delete your account?", ar: "حذف حسابك؟")
    static let deleteConfirmBody = LocalizedString(
        en: "This removes your account, your referral code and the record of which platforms you "
            + "are subscribed on. It does not touch a single reading — your health data is on this "
            + "device and was never on ours. A subscription bought on this device keeps working.",
        ar: "يؤدي هذا إلى حذف حسابك ورمز الإحالة الخاص بك وسجل المنصات المشترك فيها. ولا يمسّ أي "
            + "قراءة — فبياناتك الصحية على هذا الجهاز ولم تكن يوماً على خوادمنا. ويستمر الاشتراك "
            + "المشترى على هذا الجهاز في العمل.")
    static let deleteConfirmAction = LocalizedString(en: "Delete", ar: "حذف")
    static let cancel = LocalizedString(en: "Cancel", ar: "إلغاء")

    static let referralRow = LocalizedString(en: "Invite a friend", ar: "ادعُ صديقاً")
    static let referralRowSubtitle = LocalizedString(
        en: "You both get a free month", ar: "تحصلان كلاكما على شهر مجاني")

    static let sourceLocal = LocalizedString(en: "Bought on this device", ar: "مُشترى على هذا الجهاز")
    static let sourceSyncediOS = LocalizedString(
        en: "Bought on your iPhone or iPad", ar: "مُشترى على هاتفك آيفون أو آيباد")
    static let sourceSyncedAndroid = LocalizedString(
        en: "Bought on your Android phone", ar: "مُشترى على هاتفك أندرويد")
    static let sourceReferral = LocalizedString(en: "From a referral", ar: "من إحالة")
    static let sourceStale = LocalizedString(
        en: "Connect to the internet to confirm your subscription",
        ar: "اتصل بالإنترنت لتأكيد اشتراكك")
    static let signInFailed = LocalizedString(
        en: "Sign in didn't complete. Nothing changed — try again when you're ready.",
        ar: "لم يكتمل تسجيل الدخول. لم يتغيّر شيء — أعد المحاولة عندما تكون مستعداً.")

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
/// Both exist now. This doc comment used to open by explaining that neither did — that BADAN had
/// no accounts, no payments and no network calls, per `ADR-0002`. Payments arrived with D-32/D-33,
/// and accounts with **ADR-0014 / D-44**, which reversed the no-accounts posture to carry a
/// subscription between iOS and Android and to run referrals.
///
/// What the reversal did NOT touch is the reason the old posture existed, and this screen is where
/// that has to be legible to a user rather than only to a reader of the ADR:
///
/// - Signed out is a complete, permanent, first-class state. Every reading, derivation, log and
///   export within the D-33 window works identically without an account, and nothing in the app may
///   ever require one.
/// - The account holds a subscription and a referral code. It holds no health data, and
///   `AccountPayloadShapeTests` plus `test_the_accounts_schema_holds_no_health_column` are what keep
///   that true rather than merely stated.
/// - Deleting the account is offered here, in one tap, and deletes it server-side for real (App
///   Review 5.1.1(v)).
///
/// See `docs/MONETIZATION.md` for the free/premium line and the sequencing — chiefly that only a
/// fraction of the ontology's metrics are actually ingested today, so the features a subscription
/// sells still have less data to run on than the pricing implies.
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
    @State private var confirmingDelete = false

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
        .task {
            // Pull on appear rather than on a timer. A refresh failing is silent and harmless —
            // the cached snapshot keeps answering, which is the whole design of `EntitlementMerge`.
            await env.account.refresh()
        }
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
            if env.account.state.isSignedIn {
                signedInCard
                referralRow
                signOutRow
                deleteAccountRow
            } else {
                signInCard
            }
            LText(AccountStrings.accountBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            AppleSignInButton {
                Task { await env.account.signIn() }
            }
            // Apple's own control, at the height the HIG specifies. Not stretched to fill and not
            // restyled — the artwork and the proportions are Apple's to set.
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .disabled(env.account.isBusy)
            .opacity(env.account.isBusy ? 0.5 : 1)

            // A failure says nothing changed, because nothing did: `AccountController` leaves the
            // cached snapshot untouched on every error path.
            if env.account.lastError != nil {
                LText(AccountStrings.signInFailed)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.outOfBand)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signedInCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .imageScale(.medium)
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    LText(AccountStrings.signedInAs)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    // Where the entitlement actually comes from. "Bought on your Android phone" is
                    // a materially different sentence from "subscribed", and a user who cancels on
                    // the wrong platform because we blurred them has been failed by this line.
                    if let source = entitlementSourceLine {
                        LText(source)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                Spacer(minLength: BadanSpace.space2)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .accessibilityElement(children: .combine)
        }
    }

    private var entitlementSourceLine: LocalizedString? {
        switch env.subscription.entitlementSource {
        case .localStore: return AccountStrings.sourceLocal
        case .synced(.ios): return AccountStrings.sourceSyncediOS
        case .synced(.android): return AccountStrings.sourceSyncedAndroid
        case .referralGrant: return AccountStrings.sourceReferral
        case .syncedButStale, .referralGrantButStale: return AccountStrings.sourceStale
        case .none: return nil
        }
    }

    private var referralRow: some View {
        NavigationLink { ReferralScreen() } label: {
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "gift")
                        .imageScale(.medium)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AccountStrings.referralRow, language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(AccountStrings.referralRowSubtitle, language: env.language)
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
    }

    private var signOutRow: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            Button {
                env.account.signOut()
            } label: {
                LText(AccountStrings.signOut)
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.primary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: BadanSpace.touchMin)
            LText(AccountStrings.signOutBlurb)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// App Review 5.1.1(v): an app that offers account creation must offer account deletion from
    /// inside the app. One tap to reach, one confirmation, and it is a real server-side delete —
    /// `AccountController.deleteAccount` only clears local state after the server confirms, so this
    /// can never report a deletion that did not happen.
    private var deleteAccountRow: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            LText(AccountStrings.deleteAccount)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.outOfBand)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BadanSpace.touchMin)
        .disabled(env.account.isBusy)
        .confirmationDialog(env.s(AccountStrings.deleteConfirmTitle),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(env.s(AccountStrings.deleteConfirmAction), role: .destructive) {
                Task { await env.account.deleteAccount() }
            }
            Button(env.s(AccountStrings.cancel), role: .cancel) {}
        } message: {
            // Says plainly what is and is not destroyed. A deletion dialog that implies health data
            // is at stake would be frightening and false; one that hides that the referral code
            // goes would be the other kind of dishonest.
            LText(AccountStrings.deleteConfirmBody)
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
