import SwiftUI
import StoreKit

/// The paywall. Deliberately states what stays free FIRST, and at the same size as what costs
/// money.
///
/// That ordering is the product's argument, not a courtesy: `docs/MONETIZATION.md` §1 defines the
/// line as "you never pay to see, keep, or leave with your own data — you pay for BADAN's
/// interpretation of it", and a paywall that opens with a price list quietly reverses that emphasis.
/// A user who cancels must lose interpretation, never records.
struct PaywallScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                header
                freeForeverCard
                premiumCard
                products
                restoreRow
                LText(PaywallCopy.legalNote)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(PaywallCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await env.subscription.loadProducts()
            await env.subscription.refreshEntitlements()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            LText(statusLine)
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.textPrimary)
        }
    }

    /// Says the true thing about where the user stands, rather than one generic upsell line.
    private var statusLine: LocalizedString {
        switch env.subscription.access {
        case .subscribed: return PaywallCopy.statusSubscribed
        case .trial(let days): return PaywallCopy.statusTrial(env.format.integer(days))
        case .trialExpired: return PaywallCopy.statusExpired
        case .notYetStarted: return PaywallCopy.statusTrial(env.format.integer(SubscriptionPolicy.trialDays))
        }
    }

    /// Listed first and in full. This is not filler — it is the part of the pitch that has to
    /// survive a cancellation.
    private var freeForeverCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                LText(PaywallCopy.freeTitle)
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.textPrimary)
                ForEach(PaywallCopy.freeItems, id: \.en) { item in
                    bullet(item, systemImage: "checkmark.circle.fill", tint: BadanColor.primary)
                }
            }
        }
    }

    private var premiumCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                LText(PaywallCopy.premiumTitle)
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.textPrimary)
                ForEach(PaywallCopy.premiumItems, id: \.en) { item in
                    bullet(item, systemImage: "sparkles", tint: BadanColor.textSecondary)
                }
            }
        }
    }

    private func bullet(_ text: LocalizedString, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            LText(text)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var products: some View {
        if env.subscription.access == .subscribed {
            // Nothing to sell. Showing prices to someone who already paid is the kind of small
            // insult that makes an app feel like it is not paying attention.
            EmptyView()
        } else if env.subscription.products.isEmpty {
            BadanCard {
                LText(env.subscription.storeReachable ? PaywallCopy.noProducts : PaywallCopy.offline)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: BadanSpace.space2) {
                ForEach(env.subscription.products, id: \.id) { product in
                    productRow(product)
                }
            }
        }
    }

    private func productRow(_ product: Product) -> some View {
        Button {
            purchasing = product.id
            Task {
                await env.subscription.purchase(product)
                purchasing = nil
            }
        } label: {
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        // The store's own localized price string — never hand-formatted. Prices
                        // differ by storefront, and a hardcoded "$2.99" is wrong in most countries.
                        Text(product.displayPrice)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    if purchasing == product.id {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(minHeight: BadanSpace.touchMin)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .disabled(purchasing != nil)
    }

    private var restoreRow: some View {
        Button {
            Task { await env.subscription.restore() }
        } label: {
            LText(PaywallCopy.restore)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BadanSpace.touchMin)
    }
}

enum PaywallCopy {
    static let title = LocalizedString(en: "BADAN Pro", ar: "بدن برو")

    static let statusSubscribed = LocalizedString(en: "You're subscribed. Thank you.",
                                                  ar: "أنت مشترك. شكراً لك.")
    static let statusExpired = LocalizedString(en: "Your free trial has ended.",
                                               ar: "انتهت فترتك التجريبية.")
    static func statusTrial(_ days: String) -> LocalizedString {
        LocalizedString(en: "\(days) days left in your free trial.",
                        ar: "بقي \(days) أيام في فترتك التجريبية.")
    }

    static let freeTitle = LocalizedString(en: "Always free", ar: "مجاني دائماً")
    /// Stated in full, and first. A user who cancels keeps every one of these.
    static let freeItems: [LocalizedString] = [
        LocalizedString(en: "Every reading you record, at full detail, forever.",
                        ar: "كل قراءة تسجّلها، بكامل تفاصيلها، إلى الأبد."),
        LocalizedString(en: "Where each number came from, and how it was worked out.",
                        ar: "مصدر كل رقم، وكيف تم استخراجه."),
        LocalizedString(en: "Logging, editing and deleting anything you've recorded.",
                        ar: "تسجيل وتعديل وحذف أي شيء سجّلته."),
        LocalizedString(en: "Exporting the last 7 days, complete, whenever you like.",
                        ar: "تصدير آخر ٧ أيام كاملةً متى شئت."),
    ]

    static let premiumTitle = LocalizedString(en: "With Pro", ar: "مع برو")
    static let premiumItems: [LocalizedString] = [
        LocalizedString(en: "Scores, baselines and trends BADAN works out from your data.",
                        ar: "المؤشرات والخطوط الأساسية والاتجاهات التي يستخرجها «بدن» من بياناتك."),
        LocalizedString(en: "Exporting your full history, not just the last 7 days.",
                        ar: "تصدير سجلك الكامل، لا آخر ٧ أيام فقط."),
        LocalizedString(en: "Scheduled exports and your own export templates.",
                        ar: "تصديرات مجدولة وقوالب تصدير خاصة بك."),
        LocalizedString(en: "Alternate app icons.", ar: "أيقونات بديلة للتطبيق."),
    ]

    static let restore = LocalizedString(en: "Restore purchases", ar: "استعادة المشتريات")
    static let noProducts = LocalizedString(
        en: "Subscriptions aren't available right now. Nothing you've recorded is affected.",
        ar: "الاشتراكات غير متاحة حالياً. لا يتأثر أي شيء سجّلته.")
    static let offline = LocalizedString(
        en: "Couldn't reach the App Store. Your data and your current access are unchanged.",
        ar: "تعذّر الوصول إلى App Store. بياناتك ووصولك الحالي دون تغيير.")
    /// Says plainly that cancelling costs them nothing they recorded — the promise the whole
    /// monetization line rests on.
    static let legalNote = LocalizedString(
        en: "Subscriptions renew automatically until cancelled, and can be managed in your Apple ID settings. If you cancel, you keep every reading you've recorded — only BADAN's interpretation of it pauses.",
        ar: "تتجدد الاشتراكات تلقائياً حتى تُلغى، ويمكن إدارتها من إعدادات Apple ID. إذا ألغيت، تبقى لديك كل قراءة سجّلتها — يتوقف فقط تحليل «بدن» لها.")
}
