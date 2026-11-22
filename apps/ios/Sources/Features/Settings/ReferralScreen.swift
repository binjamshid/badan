import SwiftUI

private enum ReferralStrings {
    static let title = LocalizedString(en: "Referral codes", ar: "رموز الإحالة")
    static let yourCodeHeader = LocalizedString(en: "Your code", ar: "رمزك")
    static let explainer = LocalizedString(
        en: "Share your code with someone who is new to BADAN.",
        ar: "شارك رمزك مع شخص جديد على بدن.")
    static let invitation = LocalizedString(
        en: "Use this referral code after you sign in to BADAN:",
        ar: "استخدم رمز الإحالة هذا بعد تسجيل الدخول إلى بدن:")
    static let share = LocalizedString(en: "Share", ar: "مشاركة")
    static let copy = LocalizedString(en: "Copy", ar: "نسخ")
    static let copied = LocalizedString(en: "Copied", ar: "تم النسخ")

    static let claimHeader = LocalizedString(en: "Have a code?", ar: "لديك رمز؟")
    static let claimField = LocalizedString(en: "Enter a friend's code", ar: "أدخل رمز صديق")
    static let claimAction = LocalizedString(en: "Use code", ar: "استخدام الرمز")
    static let claimed = LocalizedString(
        en: "Code added to your account.", ar: "أُضيف الرمز إلى حسابك.")
    static let alreadyClaimed = LocalizedString(
        en: "You've already used a referral code. One per account.",
        ar: "لقد استخدمت رمزاً بالفعل. رمز واحد لكل حساب.")

    // Every refusal says which rule was hit. "That didn't work" is the message that makes people
    // write to support instead of fixing the typo themselves.
    static let refusalMalformed = LocalizedString(
        en: "That code isn't one of ours. Check for a typo — codes are 8 characters.",
        ar: "هذا الرمز ليس من رموزنا. تحقق من وجود خطأ مطبعي — الرموز من ٨ خانات.")
    static let refusalOwnCode = LocalizedString(
        en: "That's your own code. Share it with someone else.",
        ar: "هذا رمزك أنت. شاركه مع شخص آخر.")
    static func refusalWindowClosed(_ days: String) -> LocalizedString {
        LocalizedString(
            en: "You can use a code in your first \(days) days. Yours has passed.",
            ar: "لا يمكن استخدام الرموز إلا خلال أول \(days) يوماً. وقد انقضت مدتك.")
    }
}

/// Share your account’s referral code or add a code from someone else.
struct ReferralScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var entered = ""
    @State private var refusal: ReferralPolicy.ClaimRefusal?
    @State private var justClaimed = false
    @State private var justCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                if let identity = env.account.state.identity {
                    ownCodeSection(identity)
                    claimSection(identity)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(ReferralStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.account.refresh() }
    }

    // MARK: - Your code

    private func ownCodeSection(_ identity: AccountIdentity) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ReferralStrings.yourCodeHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    // Grouped as `2F3K-9WXY`. The hyphen is presentation only — `normalise` strips
                    // it again — so someone reading it aloud, typing it from a screenshot, or
                    // pasting it back with the hyphen all land in the same place.
                    Text(ReferralPolicy.formatted(identity.referralCode))
                        .font(BadanFont.numeralM.monospaced())
                        .foregroundStyle(BadanColor.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityLabel(spelledOut(identity.referralCode))
                    HStack(spacing: BadanSpace.space4) {
                        ShareLink(item: shareText(identity.referralCode)) {
                            LText(ReferralStrings.share)
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.primary)
                        }
                        Button {
                            // The normalised code, not the formatted one. Someone pasting this
                            // into a message and someone else pasting it back into the field
                            // should be the same eight characters at both ends.
                            UIPasteboard.general.string = identity.referralCode
                            justCopied = true
                        } label: {
                            LText(justCopied ? ReferralStrings.copied : ReferralStrings.copy)
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.primary)
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                }
            }
            LText(ReferralStrings.explainer)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read character by character. VoiceOver pronounces `2F3K9WXY` as a word-shaped mumble, which
    /// is useless for a value whose entire job is to be transcribed correctly by someone else.
    private func spelledOut(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    private func shareText(_ code: String) -> String {
        // Plain text, no tracking link, no campaign parameters. The code is the whole mechanism,
        // and a URL that phoned home on open would be a network surface nobody decided to add.
        "\(env.s(ReferralStrings.invitation))\n\n\(ReferralPolicy.formatted(code))"
    }

    // MARK: - Claim

    @ViewBuilder
    private func claimSection(_ identity: AccountIdentity) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ReferralStrings.claimHeader))
            if identity.hasClaimedReferral {
                LText(justClaimed ? ReferralStrings.claimed : ReferralStrings.alreadyClaimed)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                BadanCard {
                    VStack(alignment: .leading, spacing: BadanSpace.space3) {
                        TextField(env.s(ReferralStrings.claimField), text: $entered)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(BadanFont.body.monospaced())
                            .frame(minHeight: BadanSpace.touchMin)
                        Button {
                            Task { await claim() }
                        } label: {
                            LText(ReferralStrings.claimAction)
                                .font(BadanFont.bodyCompact)
                                .foregroundStyle(BadanColor.primary)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: BadanSpace.touchMin)
                        .disabled(env.account.isBusy
                                  || !ReferralPolicy.isWellFormed(ReferralPolicy.normalise(entered)))
                    }
                }
            }
            if let refusal {
                LText(message(for: refusal))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.outOfBand)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func claim() async {
        refusal = await env.account.claimReferral(entered)
        if refusal == nil {
            justClaimed = true
            entered = ""
        }
    }

    private func message(for refusal: ReferralPolicy.ClaimRefusal) -> LocalizedString {
        switch refusal {
        case .malformedCode: return ReferralStrings.refusalMalformed
        case .ownCode: return ReferralStrings.refusalOwnCode
        case .alreadyClaimed: return ReferralStrings.alreadyClaimed
        case .windowClosed:
            return ReferralStrings.refusalWindowClosed(
                env.format.integer(ReferralPolicy.claimWindowDays))
        }
    }
}
