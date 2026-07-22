import SwiftUI

// MARK: - EPIC-39 (Phase 3F slice 2) — the cycle module's single consent/settings screen.
//
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §9 ("Privacy and safety architecture" / its
// "Consent design" subsection) and `docs/legal/reproductive-threat-model.md` §5 (the new,
// phase-specific mitigations this screen exists to satisfy) — read both before touching this
// file's copy. Every trust-messaging sentence below stays inside the threat model's own honesty
// boundary ("stored on this device by default," "excluded from cloud AI unless you turn that on,"
// "sensitive data is off in exports unless you choose otherwise" — never "fully private,"
// "unhackable," or "impossible for anyone else to access").
//
// ONE screen, two roles, switched purely on `env.profile.cycleModuleEnabled`:
//   - `false`: the onboarding/consent explainer, ending in a single "Turn on Cycle tracking"
//     action.
//   - `true`: the same screen re-purposed as settings — hide/pause/purge, CYCLE-08's three
//     separate controls. Reachable again later from `CycleHomeScreen`'s own toolbar (another
//     lane's screen; the Integrate phase wires that navigation).
//
// Per the threat model §5's "new, specific to this phase" mitigations: no sync-consent toggle and
// no cloud-AI-consent toggle are built here, because neither capability exists yet in this build —
// this codebase's standing principle forbids a toggle for a capability that doesn't exist. The
// copy below states both facts plainly instead.
struct CycleConsentScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var services: CycleModuleServices?
    @State private var showPurgeConfirm = false
    @State private var navigateToHome = false
    @State private var transientNotice: LocalizedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if env.profile.cycleModuleEnabled {
                    settingsContent
                } else {
                    onboardingContent
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(CycleConsentStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice = transientNotice {
                SettingsTransientNotice(notice: notice)
            }
        }
        // `CycleHomeScreen` is another lane's screen (built alongside this one, per the shared
        // cross-lane contract) — referenced here by name only, never built in this file. If it
        // isn't present yet in this checkout, this is the expected, documented cross-lane gap the
        // Integrate phase reconciles; it is not a stub this file is meant to paper over.
        .navigationDestination(isPresented: $navigateToHome) {
            CycleHomeScreen()
        }
        .confirmationDialog(
            env.s(CycleConsentStrings.purgeConfirmTitle),
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(CycleConsentStrings.purgeConfirmAction), role: .destructive) {
                performPurge()
            }
            Button(env.s(Loc.cancel), role: .cancel) {}
        } message: {
            Text(env.s(CycleConsentStrings.purgeConfirmMessage))
        }
        .task {
            if services == nil {
                services = CycleModuleServices(env: env)
            }
        }
    }

    // MARK: - Onboarding (cycleModuleEnabled == false)

    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            Text(env.s(CycleConsentStrings.introBody))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    consentPoint(icon: "iphone", text: CycleConsentStrings.pointLocalFirst)
                    consentPoint(icon: "cloud.slash", text: CycleConsentStrings.pointNoCloudAI)
                    consentPoint(icon: "arrow.triangle.2.circlepath", text: CycleConsentStrings.pointNoSyncYet)
                    consentPoint(icon: "hand.raised", text: CycleConsentStrings.pointHidePauseDelete)
                }
            }

            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "info.circle")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(CycleConsentStrings.noSingleDateNote))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                enableModule()
            } label: {
                Text(env.s(CycleConsentStrings.enableAction))
                    .font(BadanFont.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.borderedProminent)
            .tint(BadanColor.primary)
        }
    }

    private func consentPoint(icon: String, text: LocalizedString) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(BadanColor.primary)
                .frame(width: BadanSpace.space5)
                .accessibilityHidden(true)
            Text(env.s(text))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tapping "Turn on Cycle tracking": persist the opt-in, then move the user forward into
    /// `CycleHomeScreen` — there is nothing else to show on THIS screen once the module is on
    /// (its own body would otherwise flip to `settingsContent` mid-navigation, which reads as a
    /// glitch rather than a deliberate transition).
    private func enableModule() {
        env.update { $0.cycleModuleEnabled = true }
        navigateToHome = true
    }

    /// AUDIT FIX: the settings-mode module toggle is only ever shown (and only ever flips to
    /// `false`) while `cycleModuleEnabled` is already `true` — this is the exact reverse of
    /// `enableModule()`'s own transition, and needs the same symmetric treatment: persist the
    /// change, then LEAVE this screen via `dismiss()` back to `CycleHomeScreen`, rather than letting
    /// this same still-pushed, still-titled-as-settings screen instantly re-render its own body as
    /// `onboardingContent` — the identical "glitch" class `enableModule()`'s own doc comment already
    /// names and avoids, just in the opposite direction.
    private func disableModule(_ newValue: Bool) {
        env.update { $0.cycleModuleEnabled = newValue }
        if !newValue { dismiss() }
    }

    // MARK: - Settings (cycleModuleEnabled == true)

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space5) {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(CycleConsentStrings.moduleSectionHeader))
                BadanCard {
                    SettingsToggleRow(
                        title: CycleConsentStrings.moduleToggleTitle,
                        subtitle: CycleConsentStrings.moduleToggleSubtitle,
                        isOn: Binding(
                            get: { env.profile.cycleModuleEnabled },
                            set: { newValue in disableModule(newValue) }
                        )
                    )
                }
            }

            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(CycleConsentStrings.predictionsSectionHeader))
                BadanCard {
                    SettingsToggleRow(
                        title: CycleConsentStrings.pausePredictionsTitle,
                        subtitle: CycleConsentStrings.pausePredictionsSubtitle,
                        isOn: Binding(
                            get: { env.profile.cyclePredictionsPaused },
                            set: { newValue in env.update { $0.cyclePredictionsPaused = newValue } }
                        )
                    )
                }
            }

            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(CycleConsentStrings.dataSectionHeader))
                BadanCard {
                    Button {
                        showPurgeConfirm = true
                    } label: {
                        HStack(spacing: BadanSpace.space3) {
                            Image(systemName: "trash")
                                .imageScale(.medium)
                                // Anti-panic palette: muted amber for a destructive-but-calm
                                // affordance, never a raw red — mirrors
                                // `PrivacySecuritySettingsScreen`'s own "Delete all data" row.
                                .foregroundStyle(BadanColor.outOfBand)
                                .accessibilityHidden(true)
                            Text(env.s(CycleConsentStrings.purgeActionTitle))
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            Spacer(minLength: BadanSpace.space2)
                        }
                        .frame(minHeight: BadanSpace.touchMin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(env.s(CycleConsentStrings.purgeFootnote))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func performPurge() {
        guard let services else { return }
        do {
            try services.purgeCycleData()
            Announce.status(env.s(CycleConsentStrings.purgeSucceededNotice))
        } catch {
            showTransientNotice(CycleConsentStrings.purgeFailedNotice)
        }
    }

    private func showTransientNotice(_ notice: LocalizedString) {
        transientNotice = notice
        Announce.failure(env.s(notice))
        Task {
            try? await Task.sleep(for: .seconds(3))
            if transientNotice == notice { transientNotice = nil }
        }
    }
}

// MARK: - Screen-local strings

private enum CycleConsentStrings {
    static let title = LocalizedString(en: "Cycle tracking", ar: "تتبع الدورة")

    static let introBody = LocalizedString(
        en: "Track your cycle privately, at your own pace. Turning this on lets you log periods "
            + "and flow, see a range for when your next cycle might start, and get calm, "
            + "pattern-based notes if something looks different from your own recent pattern.",
        ar: "تتبّع دورتك بخصوصية وبالوتيرة التي تناسبك. تفعيل هذا الخيار يتيح لك تسجيل الدورات "
            + "والتدفق، ورؤية نطاق زمني تقريبي لبداية دورتك القادمة، وملاحظات هادئة قائمة على النمط "
            + "إذا بدا شيء مختلفًا عن نمطك المعتاد مؤخرًا.")

    static let pointLocalFirst = LocalizedString(
        en: "Stored on this device by default. Your cycle logs live in BADAN's own protected "
            + "local storage, kept separate from the rest of your health data.",
        ar: "محفوظة على جهازك افتراضيًا. تُخزَّن سجلات دورتك في التخزين المحلي المحمي الخاص بـ "
            + "BADAN، بمعزل عن بقية بياناتك الصحية.")
    static let pointNoCloudAI = LocalizedString(
        en: "Excluded from cloud AI unless you turn that on. There's no cloud-AI feature for this "
            + "data yet, and none of it is sent anywhere by default.",
        ar: "مستبعدة من الذكاء الاصطناعي السحابي ما لم تُفعّل ذلك بنفسك. لا توجد ميزة ذكاء اصطناعي "
            + "سحابي لهذه البيانات حاليًا، ولا يُرسَل أي منها إلى أي مكان افتراضيًا.")
    static let pointNoSyncYet = LocalizedString(
        en: "No sync feature exists for this data yet. When one does, it will need its own "
            + "separate on/off choice, just for cycle data.",
        ar: "لا توجد ميزة مزامنة لهذه البيانات حاليًا. وعند توفّرها مستقبلًا، ستحتاج إلى خيار "
            + "تشغيل/إيقاف مستقل خاص ببيانات الدورة فقط.")
    static let pointHidePauseDelete = LocalizedString(
        en: "You can hide, pause, or delete it anytime. Turn the whole module off, pause forecasts "
            + "without losing your history, or permanently delete every cycle record — all from "
            + "this same screen later.",
        ar: "يمكنك إخفاءه أو إيقافه مؤقتًا أو حذفه في أي وقت. أوقف الوحدة بالكامل، أو أوقف "
            + "التوقعات مؤقتًا دون فقدان سجلك، أو احذف كل سجلات الدورة نهائيًا — كل ذلك من هذه "
            + "الشاشة نفسها لاحقًا.")

    static let noSingleDateNote = LocalizedString(
        en: "BADAN never shows a single due date for your next cycle — only a range with a "
            + "confidence description. Any pattern notes stay calm and non-diagnostic, never a "
            + "verdict.",
        ar: "لا يعرض BADAN أبدًا تاريخًا محددًا لموعد دورتك القادمة — بل نطاقًا زمنيًا مع وصف "
            + "لمستوى الثقة. وأي ملاحظات عن الأنماط تبقى هادئة وغير تشخيصية، وليست حكمًا نهائيًا.")

    static let enableAction = LocalizedString(en: "Turn on Cycle tracking", ar: "تفعيل تتبع الدورة")

    static let moduleSectionHeader = LocalizedString(en: "Cycle tracking", ar: "تتبع الدورة")
    static let moduleToggleTitle = LocalizedString(en: "Cycle tracking", ar: "تتبع الدورة")
    static let moduleToggleSubtitle = LocalizedString(
        en: "Turn this off to hide the module from Log. Your logged periods and flow stay saved — "
            + "turning it back on picks up right where you left off.",
        ar: "أوقف هذا لإخفاء الوحدة من شاشة التسجيل. تبقى دوراتك وتسجيلات التدفق محفوظة — وعند "
            + "إعادة التفعيل تستأنف من حيث توقفت.")

    static let predictionsSectionHeader = LocalizedString(en: "Predictions", ar: "التوقعات")
    static let pausePredictionsTitle = LocalizedString(en: "Pause predictions", ar: "إيقاف التوقعات مؤقتًا")
    static let pausePredictionsSubtitle = LocalizedString(
        en: "Keep logging periods and flow as normal. This pauses your next-cycle forecast and "
            + "phase-based comparisons until you turn it back on.",
        ar: "استمر في تسجيل الدورات والتدفق كالمعتاد. سيؤدي هذا إلى إيقاف توقع دورتك القادمة "
            + "والمقارنات المرتبطة بمرحلة الدورة إلى أن تعيد تفعيله.")

    static let dataSectionHeader = LocalizedString(en: "Your cycle data", ar: "بيانات دورتك")
    static let purgeActionTitle = LocalizedString(en: "Delete all cycle data", ar: "حذف جميع بيانات الدورة")
    static let purgeFootnote = LocalizedString(
        en: "This removes every period, flow log, contraceptive-context entry, forecast, phase "
            + "estimate, and pattern note in the cycle module. Turning the module off above keeps "
            + "your data — this is the separate, permanent action.",
        ar: "يؤدي هذا إلى إزالة كل دورة وتسجيل تدفق وإدخال سياق وسائل منع حمل وتوقع وتقدير مرحلة "
            + "وملاحظة نمط في وحدة الدورة. أما إيقاف الوحدة أعلاه فيحتفظ ببياناتك — وهذا إجراء "
            + "منفصل ودائم.")
    static let purgeConfirmTitle = LocalizedString(en: "Delete all cycle data?", ar: "حذف جميع بيانات الدورة؟")
    static let purgeConfirmMessage = LocalizedString(
        en: "This permanently deletes every period, flow log, contraceptive-context entry, "
            + "forecast, phase estimate, and pattern note in the cycle module, including any "
            + "phase-based comparisons drawn from it. This can't be undone.",
        ar: "سيؤدي هذا إلى حذف نهائي لكل دورة وتسجيل تدفق وإدخال سياق وسائل منع حمل وتوقع وتقدير "
            + "مرحلة وملاحظة نمط في وحدة الدورة، بما في ذلك أي مقارنات مرتبطة بمرحلة الدورة مستمدة "
            + "منها. لا يمكن التراجع عن هذا الإجراء.")
    static let purgeConfirmAction = LocalizedString(en: "Delete all cycle data", ar: "حذف جميع بيانات الدورة")
    static let purgeSucceededNotice = LocalizedString(en: "Cycle data deleted.", ar: "تم حذف بيانات الدورة.")
    static let purgeFailedNotice = LocalizedString(
        en: "Couldn't delete cycle data. Try again.", ar: "تعذّر حذف بيانات الدورة. حاول مرة أخرى.")
}
