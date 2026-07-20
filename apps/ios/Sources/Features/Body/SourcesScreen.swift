import SwiftUI
import UIKit
import os

// MARK: - Model

/// A source paired with the devices that have delivered through it.
struct SourcesSourceInfo: Identifiable {
    let source: Source
    let devices: [Device]
    /// Which `sensor_quality.json` class this source resolves to (EPIC-27's honesty labelling,
    /// plan §4 principle 9). Resolved once during the off-main-actor fetch rather than per
    /// render: classification lowercases and scans every device name, which is cheap once and
    /// wasteful on every layout pass of a scrolling list.
    let sourceClassId: String
    var id: String { source.id }
}

struct SourcesData {
    let sources: [SourcesSourceInfo]
    let permissionStores: [String]                      // stable order
    let permissionsByStore: [String: [PermissionState]]
}

// MARK: - View model

/// Everything `SourcesViewModel.fetch` needs to run off the main actor (PERF-01/EDGE-19) — the
/// thread-safe catalog reference plus the one bit of `AppEnvironment` state the empty-copy
/// choice depends on.
struct SourcesFetchInputs {
    var catalog: CatalogRepository
    var isHealthKitConnected: Bool
}

enum SourcesFetchOutcome {
    case loaded(SourcesData)
    case empty(hasConnectedSource: Bool)
    case failure(Error)
}

@Observable
@MainActor
final class SourcesViewModel {
    var state: LoadState<SourcesData> = .loading

    /// Sources-specific empty copy: this screen's whole job is connecting a source, so its
    /// empty state should say that rather than reuse the generic "Nothing here yet" text
    /// (EASE-196). FEAT-01: previously pointed users to "Settings," which had no connect
    /// control and looped back here — now points at the Connect card this screen itself renders
    /// (`SourcesConnectCard`, shown above the `StatefulContainer` content in every load state).
    private static let noSourcesYetDisconnected = LocalizedString(
        en: "No sources connected yet. Connect Apple Health above to see your data here.",
        ar: "لا مصادر متصلة بعد. اربط صحة آبل أعلاه لرؤية بياناتك هنا.")
    /// BUG-12 (partial): the Connect card disappears entirely once `env.isHealthKitConnected`
    /// flips — "Connect Apple Health above" is simply false at that point (there's nothing
    /// above to connect), e.g. right after connecting while the backfill is still catching up,
    /// or for a connected user who genuinely has no HealthKit history yet.
    private static let noSourcesYetConnected = LocalizedString(
        en: "Apple Health is connected. Your data will appear here shortly.",
        ar: "تم ربط صحة آبل. ستظهر بياناتك هنا قريباً.")

    /// (EDGE-19) Was synchronous on the main actor with an N+1 `devices(sourceId:)` query per
    /// source. Now mirrors `BodyViewModel`/`HomeViewModel`'s pattern: a value-type snapshot in,
    /// the actual queries on a detached task, state out, with a `Task.isCancelled` guard so a
    /// `.task(id:)` re-firing before this finishes never clobbers state.
    ///
    /// (BUG-12 full) With the data-change bus in place, this screen's `.task(id:)` now also
    /// keys on `env.dataGeneration`, so it self-corrects once the post-connect backfill lands
    /// instead of only reacting to a manual `onConnected()` reload — see `SourcesScreen.body`.
    func load(_ env: AppEnvironment) async {
        let inputs = SourcesFetchInputs(catalog: env.catalog, isHealthKitConnected: env.isHealthKitConnected)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .loaded(let data):
            state = .loaded(data)
        case .empty(let hasConnectedSource):
            let copy = hasConnectedSource ? Self.noSourcesYetConnected : Self.noSourcesYetDisconnected
            state = .empty(env.s(copy))
        case .failure(let error):
            // The raw error goes to the debug log, not the UI (BUG-14, matching every other
            // screen this fix touches) — users see one calm, bilingual "couldn't load" message.
            LoadErrorLog.log(error, screen: "Sources")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    // MARK: Fetch core (nonisolated — runs on a detached task)

    nonisolated static func fetch(_ inputs: SourcesFetchInputs) -> SourcesFetchOutcome {
        do {
            let sources = try inputs.catalog.sources()
            // (EDGE-19) One batched query instead of one `devices(sourceId:)` call per source —
            // `devices(sourceId: nil)` already returns every device with its own `sourceId`, so
            // grouping in memory is strictly cheaper than the N+1 this replaced, with no schema
            // or `CatalogRepository` change needed.
            let allDevices = try inputs.catalog.devices()
            let devicesBySource = Dictionary(grouping: allDevices, by: \.sourceId)
            let quality = SensorQualityMap.shared
            let infos = sources.map { source in
                let devices = devicesBySource[source.id] ?? []
                return SourcesSourceInfo(source: source, devices: devices,
                                         sourceClassId: quality.classId(for: source, devices: devices))
            }
            let permissions = try inputs.catalog.permissions()
            let grouped = Dictionary(grouping: permissions, by: { $0.store })
            let stores = grouped.keys.sorted()

            if infos.isEmpty && permissions.isEmpty {
                return .empty(hasConnectedSource: inputs.isHealthKitConnected)
            }
            return .loaded(SourcesData(sources: infos, permissionStores: stores, permissionsByStore: grouped))
        } catch {
            return .failure(error)
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
    private static let familiesHeader = LocalizedString(en: "What BADAN reads", ar: "ما يقرأه بدن")
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
                    SourcesConnectCard { Task { await vm.load(env) } }
                }

                StatefulContainer(
                    vm.state,
                    emptyIcon: "antenna.radiowaves.left.and.right",
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env) } }
                ) { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        if !data.sources.isEmpty {
                            SectionHeader(env.s(Loc.dataSources))
                            ForEach(data.sources) { info in
                                SourcesSourceCard(info: info, devicesLabel: Self.devicesLabel)
                            }
                        }

                        // (EPIC-01 task 5) The widened read set added four families the Sources
                        // screen never named. Listing them here — each opening its own explainer
                        // — is what makes "what does BADAN actually read from me" answerable in
                        // one place, rather than only inferable from a permission matrix full of
                        // platform identifiers.
                        SectionHeader(env.s(Self.familiesHeader))
                            .padding(.top, data.sources.isEmpty ? 0 : BadanSpace.space2)
                        SourcesFamiliesCard()

                        // (EPIC-03 task 6) Routes sit apart from the families above, visually and
                        // structurally, because they gate apart: location data never rides along
                        // with a health family.
                        SourcesRouteRow()

                        SectionHeader(env.s(Self.permissionsHeader))
                            .padding(.top, BadanSpace.space2)
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
        .task(id: SourcesLoadKey(profile: env.profile, generation: env.dataGeneration)) { await vm.load(env) }
    }
}

/// (BUG-12 full) The standardized `.task(id:)` identity — see `HomeLoadKey`
/// (`HomeScreen.swift`). Folding `dataGeneration` in is what makes this screen self-correct once
/// a post-connect backfill actually lands, on top of the existing manual `onConnected()` kick.
private struct SourcesLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
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
                        .foregroundStyle(BadanColor.onPrimary)
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
            if granted {
                // BUG-12 (partial): `connectHealthKit()` returns as soon as authorization is
                // granted — the actual wipe+backfill keeps running detached. Reloading
                // immediately used to race that, so this screen almost always redrew while the
                // backfill was still mid-flight (typically still showing empty). Stay in the
                // "Connecting…" state until the backfill actually lands (bounded by
                // `awaitBackfillCompletion`'s own timeout either way) before reloading.
                _ = await env.awaitBackfillCompletion()
                isConnecting = false
                onConnected()
            } else {
                isConnecting = false
                showUnavailableNotice = true
            }
        }
    }
}

// MARK: - Families (EPIC-01 task 5)

/// The metric families BADAN reads, each opening its own explainer sheet.
///
/// Families rather than permission bundles: a bundle is a consent-flow grouping (what gets asked
/// for together, and when), while this list answers "what kinds of thing does BADAN hold about
/// me" — the question someone opens Sources to answer. Ordered as the registry orders them, and
/// filtered to families that actually have metrics, so a family with nothing behind it never
/// appears as a promise the app doesn't keep.
private struct SourcesFamiliesCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var explainerFamily: MetricFamily?

    /// The families the widened read set covers. `.sleep` is included even though it predates
    /// EPIC-01 — a list of "what BADAN reads" that omitted sleep because it happened to be older
    /// would be a list organized around our release history rather than the user's data.
    private static let shown: [MetricFamily] = [.heart, .respiratory, .activity, .body, .sleep]

    private static let metricCount = LocalizedString(en: "{n} tracked", ar: "{n} مؤشر متابَع")

    var body: some View {
        BadanCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(families.enumerated()), id: \.element.family) { index, entry in
                    if index > 0 {
                        Rectangle().fill(BadanColor.separator).frame(height: 1)
                            .padding(.leading, BadanSpace.cardPadding)
                    }
                    Button {
                        explainerFamily = entry.family
                    } label: {
                        HStack(spacing: BadanSpace.space3) {
                            Image(systemName: entry.family.symbolName)
                                .font(.system(size: 17))
                                .foregroundStyle(BadanColor.primary)
                                .frame(width: 26)
                                .accessibilityHidden(true)
                            LText(entry.family.displayName)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            Spacer(minLength: BadanSpace.space2)
                            Text(env.s(Self.metricCount.filling(["n": env.format.integer(entry.count)])))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                            Image(systemName: "info.circle")
                                .font(BadanFont.caption.weight(.semibold))
                                .foregroundStyle(BadanColor.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, BadanSpace.cardPadding)
                        .frame(minHeight: BadanSpace.touchMin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(Self.explainerHint, language: env.language))
                }
            }
        }
        .sheet(item: $explainerFamily) { family in
            MetricFamilyExplainerSheet(family: family)
        }
    }

    private static let explainerHint = LocalizedString(
        en: "Explains what this is and how it's recorded",
        ar: "يشرح ما هذا وكيف يُسجَّل")

    private var families: [(family: MetricFamily, count: Int)] {
        Self.shown.compactMap { family in
            let count = env.registry.metrics(in: family).count
            return count > 0 ? (family, count) : nil
        }
    }
}

/// `MetricFamily` is `Hashable` but not `Identifiable`, which `.sheet(item:)` needs. Adding the
/// conformance here rather than on the domain enum keeps a SwiftUI presentation requirement out
/// of `Domain/Metric.swift`, which has no business knowing about sheets.
///
/// Deliberately NOT `@retroactive`: that attribute is only for conforming another module's type
/// to another module's protocol, and `MetricFamily` is declared in this same target. Marking it
/// retroactive warns today and is a hard error under the Swift 6 language mode. If this enum is
/// ever extracted into its own module, the attribute becomes correct — until then it is noise
/// that breaks the build on a language-mode bump.
extension MetricFamily: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Routes (EPIC-03 task 6)

/// The route-consent entry point.
///
/// A row of its own, outside the families card, because routes are location data and gate
/// independently of every health family (plan §4.11/§17). Grouping it with the families would
/// imply it travels with them — which is precisely the inference the separate toggle exists to
/// prevent.
private struct SourcesRouteRow: View {
    @Environment(AppEnvironment.self) private var env

    /// Mirrors `RouteConsentStore.current.granted`, refreshed in `onAppear`.
    ///
    /// Reading the store directly inside `body` would compile and look right, but `UserDefaults`
    /// is not observable: after the user toggles routes on and navigates back, SwiftUI has no
    /// reason to re-evaluate, so the row would keep saying "Off" about a switch that is on.
    /// `onAppear` fires on return from a pushed screen, which is exactly the moment this can go
    /// stale.
    @State private var granted = false

    private static let title = LocalizedString(en: "Workout routes", ar: "مسارات التمارين")
    private static let subtitle = LocalizedString(
        en: "Location data, with its own switch. Off unless you turn it on.",
        ar: "بيانات موقع، ولها مفتاحها الخاص. متوقّفة ما لم تفعّلها.")
    private static let on = LocalizedString(en: "On", ar: "مفعّل")
    private static let off = LocalizedString(en: "Off", ar: "متوقّف")

    var body: some View {
        NavigationLink {
            RouteConsentScreen()
        } label: {
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "map")
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        LText(Self.title)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(Self.subtitle)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    // State is text, not colour alone — a location switch is the last place to
                    // rely on hue to say whether something is on.
                    PillLabel(env.s(granted ? Self.on : Self.off),
                              systemImage: granted ? "checkmark.circle" : "minus.circle",
                              tint: granted ? BadanColor.primary : BadanColor.textSecondary)
                    Image(systemName: "chevron.forward")
                        .font(BadanFont.caption.weight(.semibold))
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .onAppear { granted = RouteConsentStore.current.granted }
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

                SourcesSensorQualitySection(sourceClassId: info.sourceClassId)

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

// MARK: - Sensor quality (plan §4 principle 9, §16 "sensor-quality labels")

/// What kind of sensor this source is, and what that means per family.
///
/// **This is an honesty label, never a ranking or a gate.** Nothing here suppresses, hides,
/// reorders or downweights a reading — dedup and source priority are decided by entirely separate
/// machinery (I3/I4), and raw data is never paywalled. A `low` label says what the sensor class
/// does, not how much the person should trust their own body.
///
/// Only families this class actually produces are listed. `unsupported` rows are dropped rather
/// than shown as a wall of "not from this device": a smart scale would otherwise render ten
/// negative rows and one useful one, which reads as a fault report about hardware that is working
/// exactly as designed.
private struct SourcesSensorQualitySection: View {
    @Environment(AppEnvironment.self) private var env
    let sourceClassId: String

    private static let header = LocalizedString(en: "What this sensor is good at", ar: "ما يجيده هذا المستشعر")

    /// Families worth labelling, in the order the Sources screen reads best. Deliberately not
    /// `MetricFamily.allCases`: subjective/symptom/medication entries describe things a person
    /// types, where "sensor quality" is a category error.
    private static let families: [MetricFamily] = [.heart, .sleep, .activity, .respiratory, .body]

    private var sourceClass: SensorSourceClass? { SensorQualityMap.shared.sourceClass(id: sourceClassId) }

    var body: some View {
        if let sourceClass, !rows.isEmpty {
            Rectangle().fill(BadanColor.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                LText(Self.header)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(env.s(sourceClass.displayName))
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                if env.depth.showsPowerDetail {
                    Text(env.s(sourceClass.explainer))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows, id: \.family) { row in
                    HStack(spacing: BadanSpace.space2) {
                        LText(row.family.displayName)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        PillLabel(env.s(row.level.label), systemImage: row.level.symbolName,
                                  tint: row.level.tint)
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    // One phrase per family instead of a label stop and a chip stop, matching
                    // `StatBox`'s combined-label convention.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(env.s(row.family.displayName)), \(env.s(row.level.label))")
                }
            }
        }
    }

    private var rows: [(family: MetricFamily, level: SensorQualityLevel)] {
        Self.families
            .map { ($0, SensorQualityMap.shared.level(sourceClassId: sourceClassId, family: $0)) }
            .filter { $0.1 != .unsupported }
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
    // (EPIC-01/03) The families the widened read set added. Without these rows the permission
    // matrix falls through to `humanize`, which turns `HKQuantityTypeIdentifierVO2Max` into
    // "Hkquantitytypeidentifiervo2max" in English and leaves it untranslated in Arabic — the
    // exact case the `default` branch logs a warning for.
    case "vo2Max", "HKQuantityTypeIdentifierVO2Max":
        return LocalizedString(en: "Cardio fitness", ar: "اللياقة القلبية")
    case "basalEnergyBurned", "restingEnergy", "HKQuantityTypeIdentifierBasalEnergyBurned":
        return LocalizedString(en: "Resting energy", ar: "طاقة الراحة")
    case "flightsClimbed", "floors", "HKQuantityTypeIdentifierFlightsClimbed":
        return LocalizedString(en: "Flights climbed", ar: "الطوابق المصعودة")
    case "bodyFatPercentage", "HKQuantityTypeIdentifierBodyFatPercentage":
        return LocalizedString(en: "Body fat", ar: "نسبة الدهون")
    case "leanBodyMass", "HKQuantityTypeIdentifierLeanBodyMass":
        return LocalizedString(en: "Lean mass", ar: "الكتلة الصافية")
    case "height", "HKQuantityTypeIdentifierHeight":
        return LocalizedString(en: "Height", ar: "الطول")
    case "appleSleepingWristTemperature", "HKQuantityTypeIdentifierAppleSleepingWristTemperature":
        return LocalizedString(en: "Wrist temperature", ar: "حرارة المعصم")
    case "workoutType", "HKWorkoutTypeIdentifier", "workouts":
        return LocalizedString(en: "Workouts", ar: "التمارين")
    case "workoutRoute", "HKWorkoutRouteTypeIdentifier", "routes":
        return LocalizedString(en: "Workout routes", ar: "مسارات التمارين")
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
