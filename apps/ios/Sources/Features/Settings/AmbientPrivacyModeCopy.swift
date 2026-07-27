import Foundation

/// Bilingual copy for W-11's ambient privacy modes.
///
/// Its own file rather than nested in `PrivacySecuritySettingsScreen` because the mode is a domain
/// concept the settings screen happens to present — and because these strings say what BADAN
/// actually does, so they need to be readable next to `AmbientPrivacyConfig` when either changes.
/// Every line describes observable behaviour; none of them reassure in the abstract.
enum AmbientPrivacyModeCopy {
    static func name(_ mode: AmbientPrivacyMode) -> LocalizedString {
        switch mode {
        case .standard: return LocalizedString(en: "Normal", ar: "عادي")
        case .discreet: return LocalizedString(en: "Discreet", ar: "متحفّظ")
        case .off: return LocalizedString(en: "Nothing", ar: "لا شيء")
        }
    }

    static func explanation(_ mode: AmbientPrivacyMode) -> LocalizedString {
        switch mode {
        case .standard:
            return LocalizedString(
                en: "Scores and your daily sentence appear on widgets. iOS still hides them while your phone is locked.",
                ar: "تظهر النتائج وجملتك اليومية على الأدوات. ويبقى iOS يخفيها ما دام هاتفك مقفلًا.")
        case .discreet:
            return LocalizedString(
                en: "Widgets show shapes and labels, never numbers or sentences. Your ring still fills; it just doesn't say how much.",
                ar: "تعرض الأدوات الأشكال والعناوين فقط، دون أرقام أو جمل. تبقى دائرتك ممتلئة دون أن تذكر المقدار.")
        case .off:
            return LocalizedString(
                en: "Nothing personal leaves the app. Widgets stay on your screen but carry no health information at all.",
                ar: "لا يخرج شيء من بياناتك من التطبيق. تبقى الأدوات على شاشتك دون أي معلومات صحية إطلاقًا.")
        }
    }
}
