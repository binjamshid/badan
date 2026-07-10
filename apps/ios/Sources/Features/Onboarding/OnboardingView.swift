import SwiftUI

/// The pre-shell welcome flow. The app shell gates the tab UI on `env.onboardingComplete`;
/// this view manages its own full-screen layout (no external NavigationStack) and, on the
/// final step, calls `env.completeOnboarding()` to hand off to the shell.
///
/// Four calm steps over `BadanColor.background`:
///   1. Welcome — with a live EN/AR language toggle so RTL flips immediately.
///   2. A short "why BADAN" value set (private repository · your data is yours · works offline).
///   3. A depth preset choice — "Keep it simple" (.casual) vs "Show me detail" (.power).
///   4. A connect step — a primary connect action and a secondary "continue without connecting",
///      both of which complete onboarding.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var step = 0
    @State private var selectedDepth: DepthPolicy?

    private let lastStep = 3
    private var pageCount: Int { lastStep + 1 }

    var body: some View {
        ZStack {
            BadanColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                TabView(selection: $step) {
                    welcomePage.tag(0)
                    valuePage.tag(1)
                    depthPage.tag(2)
                    connectPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: step)

                footer
            }
        }
        .onAppear {
            // Reflect any already-chosen depth so returning to the picker shows it selected.
            selectedDepth = (env.depth == .balanced) ? nil : env.depth
        }
    }

    // MARK: - Header (progress + back / skip)

    private var header: some View {
        ZStack {
            progressDots

            HStack {
                if step > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { step -= 1 }
                    } label: {
                        Label(env.s(Loc.back), systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin,
                                   alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                }

                Spacer()

                if step < lastStep {
                    Button { env.completeOnboarding() } label: {
                        Text(env.s(Loc.skip))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin,
                                   alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                }
            }
        }
        .padding(.horizontal, BadanSpace.space5)
        .padding(.top, BadanSpace.space2)
    }

    private var progressDots: some View {
        HStack(spacing: BadanSpace.space1) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == step ? BadanColor.primary : BadanColor.separator)
                    .frame(width: index == step ? 22 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .accessibilityHidden(true)
    }

    // MARK: - Page 1: Welcome + language

    private var welcomePage: some View {
        VStack(spacing: BadanSpace.space6) {
            Spacer(minLength: 0)

            iconMark("heart.text.square", tint: BadanColor.primary, diameter: 84)

            VStack(spacing: BadanSpace.space3) {
                Text(env.s(Loc.welcomeTitle))
                    .font(Self.titleFont)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(env.s(Loc.welcomeSubtitle))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: BadanSpace.space2) {
                Text(env.s(Loc.language))
                    .font(BadanFont.chip)
                    .foregroundStyle(BadanColor.textSecondary)
                languageToggle
                Text(env.s(Self.languageHint))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, BadanSpace.space2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, BadanSpace.space5)
    }

    private var languageToggle: some View {
        HStack(spacing: BadanSpace.space2) {
            ForEach(AppLanguage.allCases) { lang in
                let isSelected = env.language == lang
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        env.update { $0.language = lang }
                    }
                } label: {
                    Text(lang.displayName)
                        .font(BadanFont.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.textSecondary)
                        .background(
                            (isSelected ? BadanColor.primary.opacity(0.14) : BadanColor.surface),
                            in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                                .strokeBorder(isSelected ? BadanColor.primary : BadanColor.separator,
                                              lineWidth: isSelected ? 1.5 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: - Page 2: Value set

    private var valuePage: some View {
        ScrollView {
            VStack(spacing: BadanSpace.space4) {
                Text(env.s(Self.whyTitle))
                    .font(Self.titleFont)
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, BadanSpace.space4)

                VStack(spacing: BadanSpace.space3) {
                    valueCard(icon: "lock.shield", tint: BadanColor.primary,
                              title: Self.valuePrivateTitle, body: Self.valuePrivateBody)
                    valueCard(icon: "square.and.arrow.up", tint: BadanColor.info,
                              title: Self.valueOwnTitle, body: Self.valueOwnBody)
                    valueCard(icon: "wifi.slash", tint: BadanColor.inBand,
                              title: Self.valueOfflineTitle, body: Self.valueOfflineBody)
                }
            }
            .padding(.horizontal, BadanSpace.space5)
            .padding(.bottom, BadanSpace.space4)
        }
    }

    private func valueCard(icon: String, tint: Color,
                           title: LocalizedString, body: LocalizedString) -> some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                iconMark(icon, tint: tint, diameter: 44)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(title))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(body))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Page 3: Depth preset

    private var depthPage: some View {
        ScrollView {
            VStack(spacing: BadanSpace.space4) {
                VStack(spacing: BadanSpace.space2) {
                    Text(env.s(Self.depthTitle))
                        .font(Self.titleFont)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(Self.depthSubtitle))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, BadanSpace.space4)

                VStack(spacing: BadanSpace.space3) {
                    depthOption(.casual, icon: "leaf",
                                title: Self.depthSimpleTitle, body: Self.depthSimpleBody)
                    depthOption(.power, icon: "slider.horizontal.3",
                                title: Self.depthDetailTitle, body: Self.depthDetailBody)
                }
            }
            .padding(.horizontal, BadanSpace.space5)
            .padding(.bottom, BadanSpace.space4)
        }
    }

    private func depthOption(_ policy: DepthPolicy, icon: String,
                             title: LocalizedString, body: LocalizedString) -> some View {
        let isSelected = selectedDepth == policy
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedDepth = policy
                env.update { $0.depthPolicy = policy }
            }
        } label: {
            BadanCard {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    iconMark(icon, tint: BadanColor.primary, diameter: 44)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(env.s(title))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(body))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.separator)
                        .accessibilityHidden(true)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? BadanColor.primary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Page 4: Connect

    private var connectPage: some View {
        VStack(spacing: BadanSpace.space6) {
            Spacer(minLength: 0)

            iconMark("waveform.path.ecg", tint: BadanColor.primary, diameter: 84)

            VStack(spacing: BadanSpace.space3) {
                Text(env.s(Self.connectTitle))
                    .font(Self.titleFont)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(env.s(Self.connectSubtitle))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            VStack(spacing: BadanSpace.space3) {
                primaryButton(Self.connectPrimary) { env.completeOnboarding() }
                Button { env.completeOnboarding() } label: {
                    Text(env.s(Loc.continueWithoutConnecting))
                        .font(BadanFont.body)
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, BadanSpace.space5)
        .padding(.bottom, BadanSpace.space5)
    }

    // MARK: - Footer (Next for steps 0–2)

    @ViewBuilder private var footer: some View {
        if step < lastStep {
            let disabled = (step == 2 && selectedDepth == nil)
            primaryButton(Loc.next) {
                withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
            }
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
            .padding(.horizontal, BadanSpace.space5)
            .padding(.top, BadanSpace.space3)
            .padding(.bottom, BadanSpace.space5)
        }
    }

    // MARK: - Shared building blocks

    private func primaryButton(_ label: LocalizedString, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(env.s(label))
                .font(BadanFont.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                .foregroundStyle(Self.onPrimary)
                .background(BadanColor.primary,
                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconMark(_ systemImage: String, tint: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.12))
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.42, weight: .regular))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    // MARK: - Local tokens

    /// A rounded display title — the token ramp tops out at `sectionTitle` (20pt), so onboarding
    /// heroes use one slightly larger rounded weight for a warmer welcome.
    private static let titleFont = Font.system(size: 28, weight: .bold, design: .rounded)

    /// Foreground for filled primary buttons: white on the light-theme teal, near-black on the
    /// light dark-theme teal — legible in both, since there is no dedicated on-primary token.
    private static let onPrimary = Color(light: "#FFFFFF", dark: "#08201D")

    // MARK: - Strings (bilingual; wellness-safe)

    private static let languageHint = LocalizedString(
        en: "Choose your language. You can change it anytime.",
        ar: "اختر لغتك. يمكنك تغييرها في أي وقت.")

    private static let whyTitle = LocalizedString(en: "Why BADAN", ar: "لماذا بدن")

    private static let valuePrivateTitle = LocalizedString(en: "A private repository", ar: "مستودع خاص")
    private static let valuePrivateBody = LocalizedString(
        en: "Your health lives in one place that belongs to you.",
        ar: "صحتك في مكان واحد يخصّك وحدك.")

    private static let valueOwnTitle = LocalizedString(en: "Your data is yours", ar: "بياناتك ملكك")
    private static let valueOwnBody = LocalizedString(
        en: "Export everything, anytime. Raw data is never locked away.",
        ar: "صدّر كل شيء في أي وقت. البيانات الخام لا تُحجب أبداً.")

    private static let valueOfflineTitle = LocalizedString(en: "Works offline", ar: "يعمل دون اتصال")
    private static let valueOfflineBody = LocalizedString(
        en: "Everything stays on your device. No account needed.",
        ar: "كل شيء يبقى على جهازك. لا حاجة إلى حساب.")

    private static let depthTitle = LocalizedString(en: "How much detail?", ar: "كم من التفاصيل؟")
    private static let depthSubtitle = LocalizedString(
        en: "Two views over the same data. Switch anytime in Settings.",
        ar: "عرضان لنفس البيانات. بدّل في أي وقت من الإعدادات.")

    private static let depthSimpleTitle = LocalizedString(en: "Keep it simple", ar: "أبقِه بسيطاً")
    private static let depthSimpleBody = LocalizedString(
        en: "Calm summaries and the numbers that matter most.",
        ar: "ملخّصات هادئة والأرقام الأهم.")

    private static let depthDetailTitle = LocalizedString(en: "Show me detail", ar: "أرِني التفاصيل")
    private static let depthDetailBody = LocalizedString(
        en: "Raw values, your ranges, and where each number came from.",
        ar: "القيم الخام ونطاقاتك ومصدر كل رقم.")

    private static let connectTitle = LocalizedString(en: "Bring in your health data", ar: "أحضِر بياناتك الصحية")
    private static let connectSubtitle = LocalizedString(
        en: "Connect a source now, or add it later — BADAN works either way.",
        ar: "اربط مصدراً الآن أو أضِفه لاحقاً — يعمل بدن في الحالتين.")

    private static let connectPrimary = LocalizedString(en: "Connect health data", ar: "ربط البيانات الصحية")
}
