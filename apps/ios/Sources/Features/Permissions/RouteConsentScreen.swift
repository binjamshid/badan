import SwiftUI

/// The one and only place workout routes can be turned on (EPIC-03 task 6, plan §4.11/§13.1/§17).
///
/// Routes are location data, so they gate independently of everything else: connecting Apple
/// Health does not imply them, the sensitive-records switch does not imply them, and export
/// carries its own separate route opt-in (Phase 1 — the export side is not built here; this
/// screen's job is that the toggle exists, is honest, and actually gates ingestion via
/// `RouteConsentStore` → `HealthKitAdapter`'s consent provider).
///
/// **Two gates, not one, and the screen says so.** BADAN's own toggle decides whether the adapter
/// ever asks HealthKit for a trace; Apple's permission decides whether HealthKit would answer.
/// Turning the toggle off stops route ingestion immediately regardless of what Apple still
/// permits, which is the correct reading of "off" — and is why `deniedNotice` below does not
/// treat a failed system sheet as a failure of the toggle.
struct RouteConsentScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Mirrors `RouteConsentStore.current.granted`. Held locally so the switch animates with the
    /// tap rather than after the async platform round trip, and reconciled from the store in
    /// `.task` and after every write — the store, never this, is the authority.
    @State private var granted = false
    @State private var isWorking = false
    @State private var showSystemPromptFailedNotice = false
    @State private var needsReconsent = false

    private static let title = LocalizedString(en: "Workout routes", ar: "مسارات التمارين")
    private static let toggleLabel = LocalizedString(en: "Read workout routes", ar: "قراءة مسارات التمارين")
    private static let lead = LocalizedString(
        en: "When you finish an outdoor workout, your watch or phone saves the path you took. BADAN can read that path back and show it on your workout — but only if you turn this on.",
        ar: "عند انتهائك من تمرين في الخارج، يحفظ جهازك أو هاتفك المسار الذي سلكته. يستطيع بدن قراءة ذلك المسار وعرضه مع تمرينك — لكن فقط إذا فعّلت هذا الخيار.")

    private static let readsHeader = LocalizedString(en: "What this reads", ar: "ما الذي يُقرأ")
    private static let readsRoutes = LocalizedString(
        en: "The route your device already recorded and saved with a workout you finished.",
        ar: "المسار الذي سجّله جهازك وحفظه بالفعل مع تمرين أنهيته.")
    private static let readsHistoryOnly = LocalizedString(
        en: "Only workouts that are already over — never one in progress.",
        ar: "التمارين المنتهية فقط — ولا يشمل أبداً تمريناً جارياً.")

    private static let neverHeader = LocalizedString(en: "What this never does", ar: "ما لا يفعله هذا أبداً")
    private static let neverLive = LocalizedString(
        en: "No live tracking. BADAN never follows where you are and never starts recording a new route.",
        ar: "لا تتبّع مباشر. لا يتتبّع بدن مكانك أبداً ولا يبدأ تسجيل مسار جديد.")
    private static let neverLeaves = LocalizedString(
        en: "Nothing leaves your device. Routes stay in BADAN's own store on this phone.",
        ar: "لا يغادر شيء جهازك. تبقى المسارات في مخزن بدن على هذا الهاتف.")
    private static let neverExport = LocalizedString(
        en: "Routes are never included in an export unless you switch them on there too — separately, every time.",
        ar: "لا تُدرج المسارات في أي تصدير إلا إذا فعّلتها هناك أيضاً — بشكل منفصل، في كل مرة.")

    private static let offNoticeTitle = LocalizedString(en: "If you turn this off", ar: "إذا أوقفت هذا")
    private static let offNotice = LocalizedString(
        en: "BADAN stops reading routes right away. Routes it already saved stay on your device until you delete them, and each one keeps a record of the wording you agreed to when it was read.",
        ar: "يتوقّف بدن عن قراءة المسارات فوراً. وتبقى المسارات المحفوظة سابقاً على جهازك إلى أن تحذفها، ويحتفظ كل منها بسجل للنص الذي وافقت عليه حين قُرئ.")

    private static let systemPromptFailed = LocalizedString(
        en: "Apple Health didn't complete the request. BADAN's own switch is on, so routes will be read as soon as Apple Health allows it — you can check under Privacy in the Health app.",
        ar: "لم يُكمل تطبيق صحة آبل الطلب. مفتاح بدن نفسه مفعّل، لذا ستُقرأ المسارات فور أن يسمح تطبيق صحة آبل بذلك — يمكنك التحقق من قسم الخصوصية في تطبيق الصحة.")
    private static let reconsentNotice = LocalizedString(
        en: "The wording for this changed since you last agreed, so it's switched off until you read it again and decide.",
        ar: "تغيّر نص هذا الخيار منذ موافقتك الأخيرة، لذا أُوقف إلى أن تقرأه مرة أخرى وتقرّر.")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                Text(env.s(Self.lead))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if needsReconsent {
                    noticeCard(Self.reconsentNotice, icon: "arrow.clockwise", tint: BadanColor.info)
                }

                toggleCard
                bulletCard(Self.readsHeader, icon: "map", tint: BadanColor.primary,
                           lines: [Self.readsRoutes, Self.readsHistoryOnly])
                bulletCard(Self.neverHeader, icon: "hand.raised", tint: BadanColor.info,
                           lines: [Self.neverLive, Self.neverLeaves, Self.neverExport])
                noticeCard(Self.offNotice, title: Self.offNoticeTitle,
                           icon: "info.circle", tint: BadanColor.textSecondary)

                if showSystemPromptFailedNotice {
                    noticeCard(Self.systemPromptFailed, icon: "exclamationmark.triangle",
                               tint: BadanColor.outOfBand)
                }

                if env.depth.showsPowerDetail {
                    policyVersionRow
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Self.title))
        .navigationBarTitleDisplayMode(.inline)
        .animation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion), value: granted)
        .animation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion),
                   value: showSystemPromptFailedNotice)
        .task { syncFromStore() }
    }

    // MARK: - Toggle

    private var toggleCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .imageScale(.large)
                    .foregroundStyle(granted ? BadanColor.primary : BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(Self.toggleLabel))
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { granted }, set: { setGranted($0) }))
                        .labelsHidden()
                        .tint(BadanColor.primary)
                        .accessibilityLabel(Text(Self.toggleLabel, language: env.language))
                }
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    /// Turning ON writes BADAN's consent FIRST, then asks Apple.
    ///
    /// The order matters and is not arbitrary. The stored consent is what
    /// `HealthKitAdapter`'s `RouteConsentProviding` reads at ingest time; if the platform sheet
    /// were asked first and the app were killed mid-sheet, an Apple grant would exist with no
    /// BADAN consent behind it — harmless (fail-closed, no routes) but confusing. Writing ours
    /// first can only produce the opposite state: BADAN willing, Apple not yet answering, which
    /// yields no route rows either and is what `systemPromptFailed` explains.
    ///
    /// Turning OFF never touches the platform. There is no HealthKit API to revoke a read grant,
    /// and pretending otherwise would be a lie; what BADAN can promise — and does — is that it
    /// stops asking. The screen says exactly that in `offNotice`.
    private func setGranted(_ newValue: Bool) {
        guard !isWorking else { return }
        granted = newValue
        showSystemPromptFailedNotice = false
        needsReconsent = false
        RouteConsentStore.record(granted: newValue, decidedAt: env.now())

        guard newValue else { return }
        isWorking = true
        Task {
            let completed = await env.requestRouteAuthorization()
            isWorking = false
            showSystemPromptFailedNotice = !completed
            syncFromStore()
        }
    }

    private func syncFromStore() {
        needsReconsent = RouteConsentStore.needsReconsent
        granted = RouteConsentStore.current.granted
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

    private func noticeCard(_ body: LocalizedString, title: LocalizedString? = nil,
                            icon: String, tint: Color) -> some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    if let title {
                        Text(env.s(title))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    Text(env.s(body))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Power altitude only: which version of this text the stored decision is attached to.
    /// Monospaced, matching how algorithm/rule identifiers are styled elsewhere — this is a
    /// technical identifier, not prose, so it also stays LTR in Arabic.
    private var policyVersionRow: some View {
        HStack(spacing: BadanSpace.space2) {
            Text(env.s(Self.policyVersionLabel))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(RouteConsent.currentPolicyVersion)
                .font(BadanFont.caption.monospaced())
                .foregroundStyle(BadanColor.textSecondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private static let policyVersionLabel = LocalizedString(en: "Consent text version", ar: "إصدار نص الموافقة")
}
