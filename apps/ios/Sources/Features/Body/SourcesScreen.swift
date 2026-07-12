import SwiftUI
import UIKit
import os

// MARK: - Model

/// A source paired with the devices that have delivered through it.
struct SourcesSourceInfo: Identifiable {
    let source: Source
    let devices: [Device]
    var id: String { source.id }
}

struct SourcesData {
    let sources: [SourcesSourceInfo]
    let permissionStores: [String]                      // stable order
    let permissionsByStore: [String: [PermissionState]]
}

// MARK: - View model

@Observable
@MainActor
final class SourcesViewModel {
    var state: LoadState<SourcesData> = .loading

    /// Sources-specific empty copy: this screen's whole job is connecting a source, so its
    /// empty state should say that rather than reuse the generic "Nothing here yet" text
    /// (EASE-196). FEAT-01: previously pointed users to "Settings," which had no connect
    /// control and looped back here — now points at the Connect card this screen itself renders
    /// (`SourcesConnectCard`, shown above the `StatefulContainer` content in every load state).
    private static let noSourcesYet = LocalizedString(
        en: "No sources connected yet. Connect Apple Health above to see your data here.",
        ar: "لا مصادر متصلة بعد. اربط صحة آبل أعلاه لرؤية بياناتك هنا.")

    func load(_ env: AppEnvironment) {
        do {
            let sources = try env.catalog.sources()
            let infos = try sources.map { source in
                SourcesSourceInfo(source: source, devices: try env.catalog.devices(sourceId: source.id))
            }
            let permissions = try env.catalog.permissions()
            let grouped = Dictionary(grouping: permissions, by: { $0.store })
            let stores = grouped.keys.sorted()

            if infos.isEmpty && permissions.isEmpty {
                state = .empty(env.s(Self.noSourcesYet))
            } else {
                state = .loaded(SourcesData(sources: infos, permissionStores: stores, permissionsByStore: grouped))
            }
        } catch {
            state = .error(String(describing: error))
        }
    }
}

// MARK: - Screen

/// Data sources — where every number comes from. Read-only and calm: what is connected, which
/// devices have delivered, and how each permission stands. Power adds the honest note about how
/// source priority breaks duplicate ties.
struct SourcesScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = SourcesViewModel()

    private static let permissionsHeader = LocalizedString(en: "Permissions", ar: "الأذونات")
    private static let devicesLabel = LocalizedString(en: "Devices", ar: "الأجهزة")
    private static let noPermissions = LocalizedString(en: "No permissions requested yet.",
                                                       ar: "لم تُطلب أي أذونات بعد.")
    private static let priorityTitle = LocalizedString(en: "How duplicates are settled",
                                                       ar: "كيف تُسوّى النسخ المكرّرة")
    private static let priorityNote = LocalizedString(
        en: "When two sources report the same reading, BADAN keeps the one from the higher-priority source (for example a wrist device over a phone) and quietly sets the other aside. Nothing is deleted — the setting-aside can be reversed.",
        ar: "عندما يُبلّغ مصدران عن القراءة نفسها، يحتفظ بدن بالقراءة من المصدر الأعلى أولوية (مثل جهاز المعصم مقابل الهاتف) ويضع الأخرى جانباً بهدوء. لا يُحذف شيء — ويمكن التراجع عن وضعها جانباً.")

    var body: some View {
        // FEAT-01: the Connect card lives outside `StatefulContainer`'s switch so it renders in
        // every load state (loading/empty/error/loaded) whenever real HealthKit isn't connected
        // yet — `StatefulContainer`'s `.empty` case only carries a message, no action, so an
        // always-present card here (rather than something bolted onto `.empty` alone) is what
        // actually fits its shape (also satisfies "Apple Health isn't among sources": once
        // connected, `env.isHealthKitConnected` flips and the card disappears for good).
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                if !env.isHealthKitConnected {
                    SourcesConnectCard { vm.load(env) }
                }

                StatefulContainer(vm.state, emptyIcon: "antenna.radiowaves.left.and.right") { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        if !data.sources.isEmpty {
                            SectionHeader(env.s(Loc.dataSources))
                            ForEach(data.sources) { info in
                                SourcesSourceCard(info: info, devicesLabel: Self.devicesLabel)
                            }
                        }

                        SectionHeader(env.s(Self.permissionsHeader))
                            .padding(.top, data.sources.isEmpty ? 0 : BadanSpace.space2)
                        SourcesPermissionCard(data: data, emptyNote: Self.noPermissions)

                        // Shown at every depth (not just power): which source "wins" a duplicate
                        // reading is a plain-language question casual users hit too (EASE-122).
                        SourcesPriorityNote(title: Self.priorityTitle, note: Self.priorityNote)
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.dataSources))
        .task(id: env.profile) { vm.load(env) }
    }
}

// MARK: - Connect card (FEAT-01)

/// The one real "connect a source" control in the app — Onboarding's connect step and Home's
/// "Connect a source" empty-state link both eventually land here. Shown whenever real HealthKit
/// isn't connected yet, regardless of what other (manual/demo) sources exist.
private struct SourcesConnectCard: View {
    @Environment(AppEnvironment.self) private var env
    /// Re-run the screen's load after a successful connect, so the newly ingested source shows
    /// up without waiting for the next `.task(id:)` trigger.
    let onConnected: () -> Void

    @State private var isConnecting = false
    @State private var showUnavailableNotice = false

    private static let title = LocalizedString(en: "Connect Apple Health", ar: "اربط صحة آبل")
    private static let subtitle = LocalizedString(
        en: "Bring in sleep, heart rate, and steps from Apple Health. Raw data is never locked away.",
        ar: "أضِف بيانات النوم ومعدل القلب والخطوات من صحة آبل. البيانات الخام لا تُحجب أبداً.")
    private static let action = LocalizedString(en: "Connect", ar: "اتصال")
    private static let connecting = LocalizedString(en: "Connecting…", ar: "جارٍ الاتصال…")
    private static let unavailableNotice = LocalizedString(
        en: "We couldn't connect right now. You can try again anytime.",
        ar: "تعذّر الاتصال الآن. يمكنك المحاولة مرة أخرى في أي وقت.")
    /// Legible white/near-black on the primary teal in both themes (no shared design-system
    /// token for this yet — every screen with a filled primary button defines its own, matching
    /// `OnboardingView`/`MedicationLogView`).
    private static let onPrimary = Color(light: "#FFFFFF", dark: "#08201D")

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .top, spacing: BadanSpace.space3) {
                    Image(systemName: "heart.text.square.fill")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        LText(Self.title)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(Self.subtitle)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if showUnavailableNotice {
                    LText(Self.unavailableNotice)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                Button(action: connect) {
                    Text(env.s(isConnecting ? Self.connecting : Self.action))
                        .font(BadanFont.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(Self.onPrimary)
                        .background(BadanColor.primary,
                                   in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isConnecting)
                .opacity(isConnecting ? 0.7 : 1)
            }
        }
    }

    private func connect() {
        isConnecting = true
        showUnavailableNotice = false
        Task {
            let granted = await env.connectHealthKit()
            isConnecting = false
            if granted {
                onConnected()
            } else {
                showUnavailableNotice = true
            }
        }
    }
}

// MARK: - Source card

private struct SourcesSourceCard: View {
    @Environment(AppEnvironment.self) private var env
    let info: SourcesSourceInfo
    let devicesLabel: LocalizedString

    private static let connectedLabel = LocalizedString(en: "Connected", ar: "تاريخ الاتصال")
    private static let lastDeliveryLabel = LocalizedString(en: "Last delivery", ar: "آخر تسليم")
    private static let bundleLabel = LocalizedString(en: "Bundle", ar: "الحزمة")
    private static let updatedLabel = LocalizedString(en: "Updated", ar: "آخر تحديث")
    private static let lastSeenLabel = LocalizedString(en: "Last seen", ar: "آخر ظهور")
    private static let firstSeenLabel = LocalizedString(en: "First seen", ar: "أول ظهور")
    // fileprivate (not private): `statusDetail(_:)` below is a top-level helper in this file,
    // not a member/extension of this type, so it needs file-scope visibility to read these.
    fileprivate static let turnedOffDetail = LocalizedString(
        en: "Turned off — permission was revoked in iOS Settings.",
        ar: "متوقف — تم سحب الإذن من إعدادات iOS.")
    fileprivate static let hiddenDetail = LocalizedString(
        en: "Hidden — you chose to hide this source.",
        ar: "مخفي — اخترت إخفاء هذا المصدر.")

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: sourceIcon(info.source.type))
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(info.source.displayName)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(sourceTypeLabel(info.source.type))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    let status = sourceStatus(info.source.status)
                    PillLabel(env.s(status.label), systemImage: status.icon, tint: status.tint)
                }

                // Non-active statuses are dead ends without this: "Turned off" and "Hidden"
                // otherwise give the user a status word with no explanation of what caused it
                // or what to do about it (EASE-124).
                if let detail = statusDetail(info.source.status) {
                    LText(detail)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                if env.depth.showsPowerDetail {
                    if let connected = info.source.connectedAt {
                        detailLine(Self.connectedLabel, value: SourcesDateText.string(connected, env.language))
                    }
                    if let delivery = info.source.lastDeliveryAt {
                        detailLine(Self.lastDeliveryLabel, value: SourcesDateText.string(delivery, env.language))
                    }
                    detailLine(Self.updatedLabel, value: SourcesDateText.string(info.source.updatedAt, env.language))
                    if let bundle = info.source.platformBundleId {
                        detailLine(Self.bundleLabel, value: bundle)
                    }
                }

                if !info.devices.isEmpty {
                    Rectangle().fill(BadanColor.separator).frame(height: 1)
                    LText(devicesLabel)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    ForEach(info.devices) { device in
                        HStack(spacing: BadanSpace.space3) {
                            Image(systemName: deviceIcon(device))
                                .imageScale(.medium)
                                .foregroundStyle(BadanColor.textSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                                Text(device.name)
                                    .font(BadanFont.bodyCompact)
                                    .foregroundStyle(BadanColor.textPrimary)
                                if env.depth.showsPowerDetail, let model = device.model {
                                    Text(model)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                }
                            }
                            Spacer(minLength: BadanSpace.space2)
                            if env.depth.showsPowerDetail {
                                VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                                    LText(Self.firstSeenLabel)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                    Text(SourcesDateText.string(device.firstSeen, env.language))
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                    LText(Self.lastSeenLabel)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                        .padding(.top, BadanSpace.space1)
                                    Text(SourcesDateText.string(device.lastSeen, env.language))
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                }
                            } else {
                                // Casual depth still gets a freshness signal — just the relative
                                // form, not the full absolute-timestamp/bundle detail (EASE-123).
                                Text(SourcesDateText.relative(device.lastSeen, env.language, now: env.now()))
                                    .font(BadanFont.caption)
                                    .foregroundStyle(BadanColor.textSecondary)
                            }
                        }
                        .padding(.leading, BadanSpace.space3)
                        .frame(minHeight: BadanSpace.touchMin)
                    }
                }
            }
        }
    }

    private func detailLine(_ label: LocalizedString, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            // Fixed-minimum label width so "Connected"/"Bundle"/"Last delivery" line up into a
            // scannable column instead of each row's value starting at a different offset
            // (UIUX-030). `.leading` alignment mirrors automatically under RTL.
            LText(label)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .frame(minWidth: 92, alignment: .leading)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Permission card

private struct SourcesPermissionCard: View {
    @Environment(AppEnvironment.self) private var env
    let data: SourcesData
    let emptyNote: LocalizedString

    private static let lastReadLabel = LocalizedString(en: "Last read", ar: "آخر قراءة")
    private static let openSettings = LocalizedString(en: "Open Settings", ar: "فتح الإعدادات")

    var body: some View {
        BadanCard {
            if data.permissionStores.isEmpty {
                LText(emptyNote)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    ForEach(data.permissionStores, id: \.self) { store in
                        VStack(alignment: .leading, spacing: BadanSpace.space2) {
                            LText(storeLabel(store))
                                .font(BadanFont.caption.weight(.semibold))
                                .foregroundStyle(BadanColor.textSecondary)
                            ForEach(data.permissionsByStore[store] ?? []) { permission in
                                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                                    HStack(spacing: BadanSpace.space2) {
                                        LText(permissionTypeLabel(permission.platformType))
                                            .font(BadanFont.bodyCompact)
                                            .foregroundStyle(BadanColor.textPrimary)
                                        Spacer(minLength: BadanSpace.space2)
                                        let style = permissionStyle(permission.status)
                                        PillLabel(env.s(permission.status.displayLabel),
                                                  systemImage: style.icon, tint: style.tint)
                                    }
                                    .frame(minHeight: BadanSpace.touchMin)

                                    // Provenance: when this permission was last actually read,
                                    // already captured on the model but previously unused (OPT-027).
                                    if env.depth.showsPowerDetail, let lastReadAt = permission.lastReadAt {
                                        HStack(spacing: BadanSpace.space2) {
                                            LText(Self.lastReadLabel)
                                                .font(BadanFont.caption)
                                                .foregroundStyle(BadanColor.textSecondary)
                                            Spacer(minLength: BadanSpace.space2)
                                            Text(SourcesDateText.string(lastReadAt, env.language))
                                                .font(BadanFont.caption)
                                                .foregroundStyle(BadanColor.textSecondary)
                                        }
                                    }

                                    // HealthKit can never re-prompt once denied — without this,
                                    // a user who taps "Don't Allow" once has no way back (FEAT-016).
                                    if permission.status == .denied, let settingsURL {
                                        Link(destination: settingsURL) {
                                            Text(env.s(Self.openSettings))
                                                .font(BadanFont.caption.weight(.medium))
                                                .foregroundStyle(BadanColor.primary)
                                        }
                                        .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}

// MARK: - Priority note (power)

private struct SourcesPriorityNote: View {
    @Environment(AppEnvironment.self) private var env
    let title: LocalizedString
    let note: LocalizedString

    var body: some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                Image(systemName: "info.circle")
                    .imageScale(.medium)
                    .foregroundStyle(BadanColor.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    LText(title)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    LText(note)
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A thin info-tinted border marks this as explanatory/meta content rather than another
        // data card, so it doesn't read identically to the source/permission cards above it
        // (UIUX-025).
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.info.opacity(0.35), lineWidth: 1.5)
        )
    }
}

// MARK: - Presentation helpers

private func sourceIcon(_ type: SourceType) -> String {
    switch type {
    case .healthkit: return "heart.text.square.fill"
    case .healthConnect: return "heart.text.square"
    case .manual: return "square.and.pencil"
    case .fileImport: return "square.and.arrow.down"
    case .vendor: return "link"
    }
}

private func sourceTypeLabel(_ type: SourceType) -> LocalizedString {
    switch type {
    case .healthkit: return LocalizedString(en: "Apple Health", ar: "صحة آبل")
    case .healthConnect: return LocalizedString(en: "Health Connect", ar: "هيلث كونكت")
    case .manual: return LocalizedString(en: "Entered by you", ar: "إدخال يدوي")
    case .fileImport: return LocalizedString(en: "Imported file", ar: "ملف مستورد")
    case .vendor: return LocalizedString(en: "Connected service", ar: "خدمة متصلة")
    }
}

// `sourceStatus`/`permissionStyle` intentionally keep their own tint/icon mapping rather than
// routing through `StatusChip`: `StatusChip` models baseline-position semantics (in/above/below
// range, still-learning), while a source or permission's status is a different domain concept
// (connected/revoked/hidden, granted/partial/denied) with its own PillLabel presentation. Worth
// a design-system pass to unify one day (UIUX-029), not a one-off fix here.
private func sourceStatus(_ status: SourceStatus) -> (label: LocalizedString, tint: Color, icon: String) {
    switch status {
    // Neutral, not `BadanColor.primary` — `primary` is the app's interactive/brand hue used for
    // links and actions; reusing it for a passive status risks reading as tappable (UIUX-021).
    case .active: return (LocalizedString(en: "Active", ar: "نشط"), BadanColor.inBand, "checkmark.circle")
    case .revoked: return (LocalizedString(en: "Turned off", ar: "متوقف"), BadanColor.outOfBand, "minus.circle")
    case .hidden: return (LocalizedString(en: "Hidden", ar: "مخفي"), BadanColor.textSecondary, "eye.slash")
    }
}

/// Short explanatory caption for non-Active source statuses — "Turned off"/"Hidden" alone are
/// dead ends with no path to understanding or resolving them (EASE-124).
private func statusDetail(_ status: SourceStatus) -> LocalizedString? {
    switch status {
    case .active: return nil
    case .revoked: return SourcesSourceCard.turnedOffDetail
    case .hidden: return SourcesSourceCard.hiddenDetail
    }
}

private func deviceIcon(_ device: Device) -> String {
    let hay = (device.name + " " + (device.model ?? "")).lowercased()
    // Arabic keyword equivalents alongside the English ones — an Arabic-named device (e.g.
    // "ساعة أبل") previously never matched any English substring and always fell back to the
    // generic sensor icon (UIUX-027). Also widened the English vocabulary slightly (OPT-025).
    if hay.contains("watch") || hay.contains("ساعة") { return "applewatch" }
    if hay.contains("phone") || hay.contains("هاتف") || hay.contains("جوال") { return "iphone" }
    if hay.contains("ring") || hay.contains("خاتم") || hay.contains("حلقة") { return "circle.circle" }
    if hay.contains("band") || hay.contains("سوار") { return "wave.3.right.circle" }
    if hay.contains("scale") || hay.contains("ميزان") { return "scalemass" }
    return "sensor.tag.radiowaves.forward.fill"
}

private func storeLabel(_ store: String) -> LocalizedString {
    switch store {
    case "healthkit": return LocalizedString(en: "Apple Health", ar: "صحة آبل")
    case "healthConnect": return LocalizedString(en: "Health Connect", ar: "هيلث كونكت")
    case "manual": return LocalizedString(en: "Entered by you", ar: "إدخال يدوي")
    case "import": return LocalizedString(en: "Imported file", ar: "ملف مستورد")
    case "vendor": return LocalizedString(en: "Connected service", ar: "خدمة متصلة")
    default:
        // Unmapped store values fall back to the raw key in both languages — logged so a new
        // store type is caught in QA instead of silently shipping untranslated text (EASE-125,
        // OPT-028).
        SourcesLog.logger.warning("Unmapped permission store '\(store, privacy: .public)' rendered as a raw label")
        return LocalizedString(en: store, ar: store)
    }
}

private func permissionStyle(_ status: PermissionStatus) -> (tint: Color, icon: String) {
    switch status {
    case .granted: return (BadanColor.primary, "checkmark.circle")
    // Distinct from `BadanColor.info` (the "still learning" blue used elsewhere for baseline
    // status) — "partial permission" is an unrelated concept and shouldn't share that hue
    // (UIUX-020). The half-filled icon already carries the "some but not all" meaning.
    case .partial: return (BadanColor.textSecondary, "circle.lefthalf.filled")
    case .denied: return (BadanColor.outOfBand, "xmark.circle")
    case .revoked: return (BadanColor.textSecondary, "minus.circle")
    case .notRequested: return (BadanColor.textSecondary, "questionmark.circle")
    }
}

/// Friendly, bilingual names for the common platform data types; unknown technical tokens fall
/// back to a humanized form of the identifier.
private func permissionTypeLabel(_ platformType: String) -> LocalizedString {
    switch platformType {
    case "sleepAnalysis": return LocalizedString(en: "Sleep", ar: "النوم")
    case "heartRate": return LocalizedString(en: "Heart rate", ar: "معدل ضربات القلب")
    case "restingHeartRate": return LocalizedString(en: "Resting heart rate", ar: "معدل القلب أثناء الراحة")
    case "heartRateVariabilitySDNN", "hrv": return LocalizedString(en: "Heart rate variability", ar: "تغيّر معدل القلب")
    case "stepCount", "steps": return LocalizedString(en: "Steps", ar: "الخطوات")
    case "activeEnergyBurned", "activeEnergy": return LocalizedString(en: "Active energy", ar: "الطاقة النشطة")
    case "distanceWalkingRunning", "distance": return LocalizedString(en: "Distance", ar: "المسافة")
    case "respiratoryRate": return LocalizedString(en: "Respiratory rate", ar: "معدل التنفّس")
    case "oxygenSaturation", "spo2": return LocalizedString(en: "Blood oxygen", ar: "أكسجين الدم")
    case "bodyMass", "weight": return LocalizedString(en: "Weight", ar: "الوزن")
    default:
        let humanized = SourcesDateText.humanize(platformType)
        return LocalizedString(en: humanized, ar: humanized)
    }
}

private enum SourcesLog {
    static let logger = Logger(subsystem: "net.albayyan.badan", category: "Sources")
}

/// Small formatting utilities kept together so both cards format dates and tokens identically.
private enum SourcesDateText {
    // One formatter per language, built once instead of per call — this file renders several
    // source/device timestamps per row in power mode, so a fresh `DateFormatter()` per call
    // added up (PERF-033). File-local cache only; not the shared cross-file utility the audit's
    // "implementation notes" floated, which is out of scope for this file.
    private static let enFormatter: DateFormatter = makeFormatter(.en)
    private static let arFormatter: DateFormatter = makeFormatter(.ar)

    private static func makeFormatter(_ language: AppLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    static func string(_ date: Date, _ language: AppLanguage) -> String {
        (language == .en ? enFormatter : arFormatter).string(from: date)
    }

    /// Relative freshness ("2 hours ago") for casual depth, where the full absolute timestamp
    /// would be more detail than the question ("is this still talking to my phone?") needs
    /// (EASE-123).
    static func relative(_ date: Date, _ language: AppLanguage, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "sleepAnalysis" -> "Sleep analysis", "blood_oxygen" -> "Blood oxygen": splits both
    /// camelCase and snake_case/kebab-case boundaries, since a non-HealthKit store (a future
    /// file-import or vendor integration) may not use camelCase tokens at all (OPT-026).
    static func humanize(_ token: String) -> String {
        var out = ""
        for (index, character) in token.enumerated() {
            if character == "_" || character == "-" {
                out.append(" ")
                continue
            }
            if index > 0 && character.isUppercase { out.append(" ") }
            out.append(character)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }
}
