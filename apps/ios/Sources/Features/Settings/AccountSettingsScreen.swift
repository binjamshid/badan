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
    static let accountBlurb = LocalizedString(
        en: "An optional BADAN account lets you share and use referral codes. Your health data stays on this device.",
        ar: "يتيح لك حساب بدن الاختياري مشاركة رموز الإحالة واستخدامها. تبقى بياناتك الصحية على هذا الجهاز.")
    static let signedInAs = LocalizedString(en: "Signed in", ar: "مسجَّل الدخول")
    static let signOut = LocalizedString(en: "Sign out on this device", ar: "تسجيل الخروج من هذا الجهاز")
    static let deleteAccount = LocalizedString(en: "Delete account", ar: "حذف الحساب")
    static let deleteConfirmTitle = LocalizedString(en: "Delete your account?", ar: "حذف حسابك؟")
    static let deleteConfirmBody = LocalizedString(
        en: "This removes your BADAN account, referral code, and any purchase records held in the account. "
            + "Your health data stays on this device. Manage any existing App Store subscription through Apple.",
        ar: "يؤدي هذا إلى حذف حسابك في بدن ورمز الإحالة وأي سجلات مشتريات محفوظة في الحساب. "
            + "تبقى بياناتك الصحية على هذا الجهاز. يمكنك إدارة أي اشتراك قائم في App Store عبر Apple.")
    static let deleteConfirmAction = LocalizedString(en: "Delete", ar: "حذف")
    static let cancel = LocalizedString(en: "Cancel", ar: "إلغاء")

    static let referralRow = LocalizedString(en: "Referral codes", ar: "رموز الإحالة")

    static let signInFailed = LocalizedString(
        en: "Sign in didn't complete. Nothing changed — try again when you're ready.",
        ar: "لم يكتمل تسجيل الدخول. لم يتغيّر شيء — أعد المحاولة عندما تكون مستعداً.")

    static let billingHeader = LocalizedString(en: "App Store billing", ar: "فوترة App Store")
    static let billingNote = LocalizedString(
        en: "BADAN's features are free. Apple handles existing App Store subscriptions, including cancellation.",
        ar: "ميزات بدن مجانية. تدير Apple اشتراكات App Store القائمة، بما في ذلك الإلغاء.")
}

/// Settings for the optional BADAN account and the link to manage existing Apple subscriptions.
struct AccountSettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                localSection
                accountSection
                legacyBillingSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SettingsCategory.account.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.account.refresh() }
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
                LText(AccountStrings.signedInAs)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
            }
            .frame(minHeight: BadanSpace.touchMin)
            .accessibilityElement(children: .combine)
        }
    }

    private var referralRow: some View {
        NavigationLink { ReferralScreen() } label: {
            BadanCard {
                SettingsNavRowLabel(icon: "person.badge.plus", title: AccountStrings.referralRow)
            }
        }
        .buttonStyle(.plain)
    }

    private var signOutRow: some View {
        Button {
            env.account.signOut()
        } label: {
            LText(AccountStrings.signOut)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BadanSpace.touchMin)
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

    private var legacyBillingSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(AccountStrings.billingHeader))
            BadanCard {
                Link(destination: SettingsStrings.manageSubscriptionsURL) {
                    SettingsNavRowLabel(icon: "creditcard", title: SettingsStrings.manageSubscriptionsTitle)
                }
                .buttonStyle(.plain)
            }
            LText(AccountStrings.billingNote)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
