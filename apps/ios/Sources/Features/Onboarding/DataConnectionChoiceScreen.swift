import SwiftUI

/// STUB-01/COMP-06 (post-onboarding data choice): the one always-reachable place to act on the
/// sample-data banner, any time after onboarding.
///
/// Onboarding's connect page (`OnboardingView.connectPage`) offers this same choice once, up
/// front — but a user who tapped Skip, chose "Explore with sample data", or simply changes their
/// mind later has no way back to it: `AppEnvironment.connectHealthKit()`'s only other call site
/// is `SourcesScreen`'s Connect card (which only ever connects, never removes sample data), and
/// Settings' "Delete all data" *re-seeds a fresh demo dataset* when HealthKit isn't connected
/// (`AppEnvironment.resetDemoData()`'s documented, intentional behavior for that button) — the
/// opposite of what someone tapping a "sample data" banner actually wants. `SeedController.
/// markStartEmpty` (purge, no reseed) already existed for onboarding's own "Start empty" but had
/// no call site reachable afterward — `AppEnvironment.deleteSampleData()` is that missing call
/// site, and this screen is its UI.
///
/// Presented as a sheet from two places — the tappable `SampleDataBanner` (`RootView`/
/// `MainTabView`) and a conditional row in `PrivacySecuritySettingsScreen`'s data-management
/// section, both only shown while `SeedController.isDemoDataActive` — so it has no dismiss
/// control of its own; the presenter adds a Close toolbar item, matching `RouteConsentScreen`'s
/// convention (see `WorkoutDetailScreen`'s sheet).
struct DataConnectionChoiceScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case connecting
        case deleting
    }

    @State private var phase: Phase = .idle
    @State private var showConnectUnavailableNotice = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteFailedNotice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    LText(Self.headerTitle)
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                    LText(Self.headerSubtitle)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                connectCard
                deleteCard
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Self.navTitle))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            env.s(Self.deleteConfirmTitle),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(env.s(Self.deleteAction), role: .destructive) { delete() }
            Button(env.s(Loc.cancel), role: .cancel) { }
        } message: {
            Text(env.s(Self.deleteConfirmMessage))
        }
    }

    // MARK: - Connect card

    private var connectCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "heart.text.square.fill")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        LText(Self.connectTitle)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(Self.connectSubtitle)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if showConnectUnavailableNotice {
                    LText(Self.connectUnavailableNotice)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                Button { connect() } label: {
                    Text(env.s(phase == .connecting ? Self.connecting : Self.connectAction))
                        .font(BadanFont.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(BadanColor.onPrimary)
                        .background(BadanColor.primary,
                                   in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(phase != .idle)
                .opacity(phase == .connecting ? 0.7 : 1)
            }
        }
    }

    private func connect() {
        phase = .connecting
        showConnectUnavailableNotice = false
        Task {
            let granted = await env.connectHealthKit()
            if granted {
                _ = await env.awaitBackfillCompletion()
                phase = .idle
                dismiss()
            } else {
                phase = .idle
                showConnectUnavailableNotice = true
            }
        }
    }

    // MARK: - Delete card

    private var deleteCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "trash")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.outOfBand)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        LText(Self.deleteTitle)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(Self.deleteSubtitle)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if showDeleteFailedNotice {
                    LText(Self.deleteFailedNotice)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                Button { showDeleteConfirm = true } label: {
                    Text(env.s(phase == .deleting ? Self.deleting : Self.deleteAction))
                        .font(BadanFont.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(BadanColor.textPrimary)
                        .background(BadanColor.surfaceElevated,
                                   in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                                .strokeBorder(BadanColor.separator, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(phase != .idle)
                .opacity(phase == .deleting ? 0.7 : 1)
            }
        }
    }

    private func delete() {
        phase = .deleting
        showDeleteFailedNotice = false
        Task {
            await env.deleteSampleData()
            phase = .idle
            // `deleteSampleData()` clears `env.resetError` itself before attempting the purge, so
            // a non-nil value here is a genuine failure from THIS attempt, not a stale one from
            // something else — see its doc. Stay on screen and say so rather than dismissing as
            // if sample data were actually gone.
            if env.resetError == nil {
                dismiss()
            } else {
                showDeleteFailedNotice = true
            }
        }
    }

    // MARK: - Strings (bilingual; wellness-safe)

    private static let navTitle = LocalizedString(en: "Sample data", ar: "البيانات التجريبية")

    private static let headerTitle = LocalizedString(
        en: "Sample data is currently shown", ar: "تُعرض حالياً بيانات تجريبية")
    private static let headerSubtitle = LocalizedString(
        en: "BADAN is showing a bundled sample dataset, not your own. Connect Apple Health to "
            + "see your real data, or remove the sample data and start empty.",
        ar: "يعرض بدن مجموعة بيانات تجريبية مرفقة، وليست بياناتك. اربط صحة آبل لرؤية بياناتك "
            + "الحقيقية، أو أزِل البيانات التجريبية وابدأ بلا بيانات.")

    private static let connectTitle = LocalizedString(en: "Connect Apple Health", ar: "اربط صحة آبل")
    private static let connectSubtitle = LocalizedString(
        en: "Bring in sleep, heart rate, and steps from Apple Health. Raw data is never locked away.",
        ar: "أضِف بيانات النوم ومعدل القلب والخطوات من صحة آبل. البيانات الخام لا تُحجب أبداً.")
    private static let connectAction = LocalizedString(en: "Connect", ar: "اتصال")
    private static let connecting = LocalizedString(en: "Connecting…", ar: "جارٍ الاتصال…")
    private static let connectUnavailableNotice = LocalizedString(
        en: "We couldn't connect right now. You can try again anytime.",
        ar: "تعذّر الاتصال الآن. يمكنك المحاولة مرة أخرى في أي وقت.")

    private static let deleteTitle = LocalizedString(en: "Delete sample data", ar: "حذف البيانات التجريبية")
    private static let deleteSubtitle = LocalizedString(
        en: "Removes the bundled sample dataset for good and leaves BADAN empty until you log "
            + "something yourself or connect a real source.",
        ar: "يزيل مجموعة البيانات التجريبية المرفقة نهائياً ويترك بدن فارغاً حتى تُسجّل شيئاً "
            + "بنفسك أو تربط مصدراً حقيقياً.")
    private static let deleteAction = LocalizedString(en: "Delete sample data", ar: "حذف البيانات التجريبية")
    private static let deleting = LocalizedString(en: "Deleting…", ar: "جارٍ الحذف…")
    private static let deleteConfirmTitle = LocalizedString(
        en: "Delete sample data?", ar: "حذف البيانات التجريبية؟")
    private static let deleteConfirmMessage = LocalizedString(
        en: "The bundled sample dataset is removed for good. Nothing else is affected — there "
            + "is no real connected source yet.",
        ar: "تُزال مجموعة البيانات التجريبية المرفقة نهائياً. لا يتأثر أي شيء آخر — إذ لا يوجد "
            + "بعد مصدر حقيقي متصل.")
    private static let deleteFailedNotice = LocalizedString(
        en: "We couldn't delete the sample data right now. You can try again anytime.",
        ar: "تعذّر حذف البيانات التجريبية الآن. يمكنك المحاولة مرة أخرى في أي وقت.")
}
