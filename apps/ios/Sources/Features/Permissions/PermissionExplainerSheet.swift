import SwiftUI

/// The in-app explainer that precedes every HealthKit system prompt (plan §13.1).
///
/// Deliberately shaped like `MetricAnatomySheet` — its own `NavigationStack`, medium/large
/// detents, a `Close` confirmation item — because it answers the same class of question ("what is
/// about to happen and why") and should not read as a different kind of object.
///
/// Layout is three fixed sections in a fixed order: purpose, what is read, what is not done. The
/// third is not optional and not collapsed. A consent explainer that only lists what it takes,
/// with the limits left to a privacy policy, is the pattern this screen exists to not be.
struct PermissionExplainerSheet: View {
    @Environment(AppEnvironment.self) private var env
    let bundle: HealthPermissionBundle
    /// Whether the system prompt is already in flight, so Continue can show progress and refuse
    /// a second tap.
    let isRequesting: Bool
    let onContinue: () -> Void
    let onDismiss: () -> Void

    private static let readsHeader = LocalizedString(en: "What BADAN reads", ar: "ما يقرأه بدن")
    private static let boundaryHeader = LocalizedString(en: "What BADAN doesn't do", ar: "ما لا يفعله بدن")
    private static let continueLabel = LocalizedString(en: "Continue", ar: "متابعة")
    private static let notNow = LocalizedString(en: "Not now", ar: "ليس الآن")
    /// The one thing an in-app explainer can promise that a system sheet cannot: that saying no
    /// costs the user nothing they already have.
    private static let reversible = LocalizedString(
        en: "You can change this later in Apple Health. Everything you've already got in BADAN stays either way.",
        ar: "يمكنك تغيير هذا لاحقاً من تطبيق صحة آبل. وكل ما لديك في بدن يبقى كما هو في الحالتين.")
    /// Sets expectations for the sheet that follows. Apple's dialog lists types in its own
    /// wording and its own order; a user who reads a tidy three-line explainer and then meets a
    /// long scrolling list has been surprised by us, not by Apple.
    private static let nextStep = LocalizedString(
        en: "Apple Health will ask next. You choose there, one type at a time.",
        ar: "سيسألك تطبيق صحة آبل بعد ذلك. وأنت من يختار هناك، نوعاً نوعاً.")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    header
                    readsCard
                    boundaryCard
                    Text(env.s(Self.nextStep))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    actions
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(bundle.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            Image(systemName: bundle.symbolName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(BadanColor.primary)
                .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                .background(BadanColor.primary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                .accessibilityHidden(true)
            Text(env.s(bundle.purpose))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readsCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(Self.readsHeader, language: env.language)
                ForEach(Array(bundle.reads.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: BadanSpace.space2) {
                        Image(systemName: "checkmark")
                            .imageScale(.small)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        Text(env.s(line))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var boundaryCard: some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                Image(systemName: "hand.raised")
                    .imageScale(.medium)
                    .foregroundStyle(BadanColor.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    Text(env.s(Self.boundaryHeader))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(bundle.boundary))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Matches `SourcesPriorityNote`'s info-tinted border: this is explanatory/meta content,
        // not another data card.
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.info.opacity(0.35), lineWidth: 1.5)
        )
    }

    private var actions: some View {
        VStack(spacing: BadanSpace.space2) {
            Button(action: onContinue) {
                Group {
                    if isRequesting {
                        ProgressView().controlSize(.small).tint(BadanColor.onPrimary)
                    } else {
                        Text(env.s(Self.continueLabel))
                            .font(BadanFont.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                .foregroundStyle(BadanColor.onPrimary) // (DS1)
                .background(BadanColor.primary,
                            in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)

            Button(action: onDismiss) {
                Text(env.s(Self.notNow))
                    .font(BadanFont.body)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)

            Text(env.s(Self.reversible))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Attaches the staged-permission explainer to any screen that stages bundles.
///
/// A modifier rather than per-screen `.sheet` plumbing so every host presents the same sheet with
/// the same wiring — a screen that forgets a callback would otherwise get a Continue button that
/// silently does nothing, and the failure would look identical to a denied prompt.
struct PermissionExplainerHost: ViewModifier {
    @Bindable var gate: HealthPermissionGate

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { gate.pendingExplainer != nil },
                // A swipe-to-dismiss is a decline, and has to be recorded as one — otherwise the
                // sheet reappears on the very next `.task`, which is exactly the nag loop the
                // decision memory exists to prevent.
                set: { if !$0 { gate.declinePending() } }
            )
        ) {
            if let bundle = gate.pendingExplainer {
                PermissionExplainerSheet(
                    bundle: bundle,
                    isRequesting: gate.isRequesting,
                    onContinue: { Task { await gate.confirmPending() } },
                    onDismiss: { gate.declinePending() })
            }
        }
    }
}

extension View {
    func permissionExplainer(_ gate: HealthPermissionGate) -> some View {
        modifier(PermissionExplainerHost(gate: gate))
    }
}
