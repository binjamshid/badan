import Foundation

/// The mandatory clinical-boundary line for blood glucose (A21/ADR-0010, D-26): "never for
/// treatment decisions" is load-bearing copy the plan requires on every glucose surface, not a
/// suggestion a screen can phrase however it likes.
///
/// Mirrors `DeviationEngine.disclaimer`'s shape exactly, for the same reason: authored ONCE in the
/// domain layer (not a view), so its presence and exact wording are asserted by a test rather than
/// left to a screen that could forget it (`GlucoseDisclaimerTests`), and rendered through one small
/// reusable footer view (`GlucoseDisclaimerFooter`) everywhere a glucose value is shown — the same
/// "cannot render this content without also rendering the disclaimer" guarantee
/// `PregnancyContentDisclaimerFooter` documents for pregnancy content.
///
/// Wellness-safe throughout: states what the number is for (personal awareness) and what it is
/// never for (a treatment decision) — never a verdict about the reading itself, never dosing
/// language, never a diagnosis frame.
public enum GlucoseDisclaimer {
    public static let text = LocalizedString(
        en: "This reading is for personal awareness only — never for treatment decisions. Always "
            + "follow the guidance of your own healthcare provider for managing your glucose.",
        ar: "هذه القراءة لِلوعي الشخصي فقط — ولا تُستخدم أبدًا لاتخاذ أي قرار علاجي. اتبع دائمًا "
            + "إرشادات مقدّم الرعاية الصحية الخاص بك لإدارة سكر الدم.")

    /// Whether `metricId` is a glucose reading and therefore must carry this disclaimer wherever
    /// its value is shown. A function (not a bare `==` at each call site) so every surface asks
    /// the same question the same way — today just `MetricDetailScreen`, the one place recon found
    /// a raw glucose value actually renders — and a future second glucose-family id only needs one
    /// line changed here rather than a grep across every screen.
    public static func applies(to metricId: String) -> Bool {
        metricId == MetricID.glucose
    }
}
