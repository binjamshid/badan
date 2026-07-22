import SwiftUI

// MARK: - EPIC-43 (device ecosystem & BLE accessory framework) — UI lane, scope note
//
// This file, `DeviceDetailScreen.swift` and `DataConflictsScreen.swift` are the UI-only slice of
// EPIC-43. They contain **no CoreBluetooth code whatsoever** — no `CBCentralManager`, no
// `CBPeripheral`, no scanning or pairing of any kind — by deliberate design, not oversight: the
// iOS Simulator has no Bluetooth hardware access, and no physical BLE accessory is available in
// this environment either, so any such code written here would ship completely unverified against
// real hardware. The GATT abstraction protocol (`GattCentralManaging`) and the spec-accurate GATT
// parsing layer (Heart Rate / Cycling Power / CSC / RSC / FTMS / Weight Scale / Body Composition)
// are a SEPARATE lane's files, not touched here. This lane is a plain read model over Source/
// Device rows that already exist in the catalog — it renders whatever connectivity data BADAN
// already has, however it arrived (HealthKit today; a real BLE adapter drops in later behind the
// same `Source`/`Device` shape once it exists).
//
// Blood Pressure / Health Thermometer / Pulse Oximeter are OUT OF SCOPE for this entire epic (the
// founder's standing do-not-build list, gated behind clinical-advisor approval A25) — nothing in
// this feature folder names, parses, or renders any of those three, not even behind a flag.
//
// PARALLEL LANE: `DataConflict`/`DataConflictRepository` (a detected-but-unresolved disagreement
// between two sources for the same metric/window) and `SourcePriorityRule` (the per-metric default
// priority order) are a different lane's domain types + repositories + migration 10 — they landed
// in the working tree partway through this slice and are read directly below (`unresolved()` for
// the summary count here; `DataConflictsScreen` lists the rows themselves). `ReconciliationDecision`
// (the ALREADY-decided dedup journal) is not new — it already exists in `InsightRepository.swift`.
// This UI lane does not construct or resolve a conflict itself (that's `ConflictDecisionEngine`,
// the parallel lane's own pure decision engine) — it only reads and displays what's already there.

/// How urgently a connected source/device wants attention, computed from data BADAN already
/// tracks (`Source.status`/`lastDeliveryAt`, `Device.lastSeen`) — never from anything BLE-specific,
/// since no BLE connection state exists in this slice.
enum DeviceHealthStatus: String, Hashable, Sendable, CaseIterable {
    case healthy
    case needsAttention
    case disconnected

    var label: LocalizedString {
        switch self {
        case .healthy: return LocalizedString(en: "Healthy", ar: "بحالة جيدة")
        case .needsAttention: return LocalizedString(en: "Needs attention", ar: "يحتاج انتباهاً")
        case .disconnected: return LocalizedString(en: "Disconnected", ar: "غير متصل")
        }
    }

    // Status colour is never the only signal (design-system rule) — every card also shows the
    // label text and a distinct glyph.
    var tint: Color {
        switch self {
        case .healthy: return BadanColor.inBand
        case .needsAttention: return BadanColor.outOfBand
        case .disconnected: return BadanColor.textSecondary
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.circle"
        case .disconnected: return "minus.circle"
        }
    }
}

/// Pure classification rules for Device Hub's card states — no I/O, no environment, so these are
/// directly unit-testable (`DeviceHubUITests`) without standing up a screen or a database.
enum DeviceHealthClassifier {
    /// How long a source can go without a delivery before it moves from "healthy" to "needs
    /// attention". Chosen generously (48h) so an ordinary once-a-day sync gap never reads as a
    /// fault — this is an honesty signal about staleness, never a nag (matches the calm, non-
    /// alarming tone `SourcesScreen`'s status pills already use).
    static let staleAfter: TimeInterval = 48 * 3600

    /// A source's own status, independent of any device rows under it.
    static func status(of source: Source, now: Date) -> DeviceHealthStatus {
        switch source.status {
        case .revoked, .hidden:
            return .disconnected
        case .active:
            guard let lastDelivery = source.lastDeliveryAt else {
                // Never delivered yet. Connected very recently is normal (it hasn't had a chance
                // to sync) and not a fault; connected a while with nothing to show for it is.
                if let connectedAt = source.connectedAt, now.timeIntervalSince(connectedAt) < staleAfter {
                    return .healthy
                }
                return .needsAttention
            }
            return now.timeIntervalSince(lastDelivery) <= staleAfter ? .healthy : .needsAttention
        }
    }

    /// The more attention-needing of two statuses (`disconnected` > `needsAttention` > `healthy`).
    static func worse(_ a: DeviceHealthStatus, _ b: DeviceHealthStatus) -> DeviceHealthStatus {
        func rank(_ s: DeviceHealthStatus) -> Int {
            switch s {
            case .healthy: return 0
            case .needsAttention: return 1
            case .disconnected: return 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }

    /// A single device row's own freshness, floored by its parent source's status: a device can
    /// never read healthier than the source carrying it (a revoked source's devices are
    /// disconnected too, whatever their own `lastSeen` says).
    static func status(of device: Device, sourceStatus: DeviceHealthStatus, now: Date) -> DeviceHealthStatus {
        if sourceStatus == .disconnected { return .disconnected }
        let freshness: DeviceHealthStatus = now.timeIntervalSince(device.lastSeen) <= staleAfter ? .healthy : .needsAttention
        return worse(sourceStatus, freshness)
    }

    /// The full card computation for one source and every device it carries: the source's own
    /// status, each device's own status, and the overall (worst-of-all) status the card badge shows.
    static func cardStatus(
        source: Source, devices: [Device], now: Date
    ) -> (source: DeviceHealthStatus, perDevice: [String: DeviceHealthStatus], overall: DeviceHealthStatus) {
        let sourceStatus = status(of: source, now: now)
        var perDevice: [String: DeviceHealthStatus] = [:]
        var overall = sourceStatus
        for device in devices {
            let deviceStatus = status(of: device, sourceStatus: sourceStatus, now: now)
            perDevice[device.id] = deviceStatus
            overall = worse(overall, deviceStatus)
        }
        return (sourceStatus, perDevice, overall)
    }
}

// MARK: - Shared small helpers (used by DeviceHubScreen, DeviceDetailScreen, DataConflictsScreen)

/// Date formatting for this feature folder, matching the per-file cached-`DateFormatter`
/// convention already established by `SourcesScreen.SourcesDateText`/`InsightsScreen.
/// InsightsDateFormatting` — kept here (not `private`) so the other two screens in this folder
/// share one instance instead of each re-declaring its own.
enum DeviceHubDateFormat {
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

    static func relative(_ date: Date, _ language: AppLanguage, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Icon + label for a `Source`, mirroring `SourcesScreen`'s private `sourceIcon`/`sourceTypeLabel`
/// (duplicated rather than imported since those are file-private there).
func deviceHubSourceIcon(_ type: SourceType) -> String {
    switch type {
    case .healthkit: return "heart.text.square.fill"
    case .healthConnect: return "heart.text.square"
    case .manual: return "square.and.pencil"
    case .fileImport: return "square.and.arrow.down"
    case .vendor: return "link"
    }
}

func deviceHubSourceTypeLabel(_ type: SourceType) -> LocalizedString {
    switch type {
    case .healthkit: return LocalizedString(en: "Apple Health", ar: "صحة آبل")
    case .healthConnect: return LocalizedString(en: "Health Connect", ar: "هيلث كونكت")
    case .manual: return LocalizedString(en: "Entered by you", ar: "إدخال يدوي")
    case .fileImport: return LocalizedString(en: "Imported file", ar: "ملف مستورد")
    case .vendor: return LocalizedString(en: "Connected service", ar: "خدمة متصلة")
    }
}

/// Best-effort device icon by keyword, mirroring `SourcesScreen.deviceIcon` (English + Arabic
/// keywords, same reasoning: an Arabic-named device must not silently fall back to the generic
/// glyph purely because of the user's language).
///
/// `Device.connectionType`/`capabilities` exist on the struct now (migration 10's additive-
/// optional columns) but `CatalogRepository.devices()` does not populate them yet — that
/// repository's read/write wiring is explicitly out of scope for migration 10's own slice (see
/// that migration's doc comment). So this still guesses from the device's name/model string; once
/// `CatalogRepository` reads the new columns, prefer switching on `device.connectionType`/
/// `device.capabilities` directly here instead.
func deviceHubDeviceIcon(_ device: Device) -> String {
    if let capabilities = device.capabilities, !capabilities.isEmpty {
        if capabilities.contains(.weightScale) || capabilities.contains(.bodyComposition) { return "scalemass" }
        if capabilities.contains(.heartRateChestStrap) { return "waveform.path.ecg" }
        if capabilities.contains(.cyclingPower) || capabilities.contains(.cyclingSpeedCadence) { return "bicycle" }
        if capabilities.contains(.runningSpeedCadence) { return "figure.run" }
    }
    let hay = (device.name + " " + (device.model ?? "")).lowercased()
    if hay.contains("watch") || hay.contains("ساعة") { return "applewatch" }
    if hay.contains("phone") || hay.contains("هاتف") || hay.contains("جوال") { return "iphone" }
    if hay.contains("ring") || hay.contains("خاتم") || hay.contains("حلقة") { return "circle.circle" }
    if hay.contains("band") || hay.contains("سوار") { return "wave.3.right.circle" }
    if hay.contains("scale") || hay.contains("ميزان") { return "scalemass" }
    if hay.contains("strap") || hay.contains("حزام") || hay.contains("polar") { return "waveform.path.ecg" }
    return "sensor.tag.radiowaves.forward.fill"
}

// MARK: - Local strings

enum DeviceHubStrings {
    static let title = LocalizedString(en: "Device Hub", ar: "مركز الأجهزة")
    static let devicesHeader = LocalizedString(en: "Connected", ar: "المتصلة")
    static let emptyMessage = LocalizedString(
        en: "No sources connected yet. Connect a source from Data sources to see it here.",
        ar: "لا مصادر متصلة بعد. اربط مصدراً من مصادر البيانات لرؤيته هنا.")
    static let lastDelivery = LocalizedString(en: "Last delivery", ar: "آخر تسليم")
    static let conflictsTitle = LocalizedString(en: "Data conflicts", ar: "تعارضات البيانات")
    static let conflictsSubtitle = LocalizedString(
        en: "Why a value came from one source instead of another.",
        ar: "لماذا جاءت قيمة من مصدر بدلاً من آخر.")
    static let resolvedCountLabel = LocalizedString(en: "{n} resolved", ar: "{n} تمت تسويتها")
    static let unresolvedCountLabel = LocalizedString(en: "{n} open", ar: "{n} مفتوحة")
}

// MARK: - Loaded data

struct DeviceHubCardInfo: Identifiable {
    let source: Source
    let devices: [Device]
    let sourceStatus: DeviceHealthStatus
    let deviceStatuses: [String: DeviceHealthStatus]
    let overallStatus: DeviceHealthStatus
    let sourceClassId: String
    var id: String { source.id }
}

struct DeviceHubData {
    let cards: [DeviceHubCardInfo]
    /// Count of already-RESOLVED dedup decisions (`ReconciliationDecision`, read from the
    /// existing `dedup_decisions` ledger) — shown on the summary row into `DataConflictsScreen`.
    let resolvedConflictCount: Int
    /// Count of live, unresolved `DataConflict` rows (`data_conflicts`, migration 10) — real data
    /// from `DataConflictRepository.unresolved()`, which landed in the working tree from the
    /// parallel Reconciliation-v2 lane partway through this slice.
    let unresolvedConflictCount: Int
}

// MARK: - View model

/// Everything `DeviceHubViewModel.fetch` needs to run off the main actor (matches `SourcesViewModel`'s
/// established pattern: PERF-01/EDGE-19 — a value-type snapshot in, the actual queries on a
/// detached task, state out). `dataConflicts` is built ad hoc over `env.database.main`, matching
/// this codebase's established convention for a repository `AppEnvironment` doesn't pre-wire
/// (see `ExportManageService`/`AutomationScheduleService`/`WorkoutHomeScreen`, all of which
/// construct a repository the same way rather than adding it to the composition root).
struct DeviceHubFetchInputs {
    var catalog: CatalogRepository
    var reconciliation: ReconciliationRepository
    var dataConflicts: DataConflictRepository
    var now: Date
}

enum DeviceHubFetchOutcome {
    case loaded(DeviceHubData)
    case empty
    case failure(Error)
}

@Observable
@MainActor
final class DeviceHubViewModel {
    var state: LoadState<DeviceHubData> = .loading

    func load(_ env: AppEnvironment) async {
        let inputs = DeviceHubFetchInputs(
            catalog: env.catalog, reconciliation: env.reconciliation,
            dataConflicts: DataConflictRepository(main: env.database.main), now: env.now())

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .loaded(let data):
            state = .loaded(data)
        case .empty:
            state = .empty(env.s(DeviceHubStrings.emptyMessage))
        case .failure(let error):
            LoadErrorLog.log(error, screen: "DeviceHub")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    nonisolated static func fetch(_ inputs: DeviceHubFetchInputs) -> DeviceHubFetchOutcome {
        do {
            let sources = try inputs.catalog.sources()
            let allDevices = try inputs.catalog.devices()
            let devicesBySource = Dictionary(grouping: allDevices, by: \.sourceId)

            let cards: [DeviceHubCardInfo] = sources.map { source in
                let devices = devicesBySource[source.id] ?? []
                let (sourceStatus, perDevice, overall) = DeviceHealthClassifier.cardStatus(
                    source: source, devices: devices, now: inputs.now)
                return DeviceHubCardInfo(
                    source: source, devices: devices, sourceStatus: sourceStatus,
                    deviceStatuses: perDevice, overallStatus: overall,
                    sourceClassId: SensorQualityMap.shared.classId(for: source, devices: devices))
            }

            guard !cards.isEmpty else { return .empty }

            let resolvedCount = try inputs.reconciliation.recent(limit: 50).count
            let unresolvedCount = try inputs.dataConflicts.unresolved().count
            return .loaded(DeviceHubData(cards: cards, resolvedConflictCount: resolvedCount,
                                         unresolvedConflictCount: unresolvedCount))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Screen

/// The device ecosystem's real, reachable home: every connected `Source` and the `Device`s
/// delivering through it, each read as healthy / needs-attention / disconnected. `SourcesScreen`
/// (Body → Data sources) stays exactly as it is — the casual projection — and this is the
/// additional, more powerful view alongside it (reachable from Settings → Privacy & security →
/// "Manage devices").
struct DeviceHubScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = DeviceHubViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                StatefulContainer(
                    vm.state,
                    emptyIcon: "antenna.radiowaves.left.and.right",
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env) } }
                ) { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        DeviceHubConflictsSummaryRow(unresolvedCount: data.unresolvedConflictCount,
                                                     resolvedCount: data.resolvedConflictCount)

                        SectionHeader(env.s(DeviceHubStrings.devicesHeader))
                        ForEach(data.cards) { card in
                            DeviceHubCard(card: card)
                        }
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(DeviceHubStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: DeviceHubLoadKey(generation: env.dataGeneration)) { await vm.load(env) }
    }
}

private struct DeviceHubLoadKey: Equatable {
    let generation: Int
}

// MARK: - Conflicts summary row

private struct DeviceHubConflictsSummaryRow: View {
    @Environment(AppEnvironment.self) private var env
    let unresolvedCount: Int
    let resolvedCount: Int

    var body: some View {
        NavigationLink {
            DataConflictsScreen()
        } label: {
            BadanCard {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "arrow.triangle.branch")
                        .imageScale(.large)
                        .foregroundStyle(unresolvedCount > 0 ? BadanColor.outOfBand : BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        LText(DeviceHubStrings.conflictsTitle)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(DeviceHubStrings.conflictsSubtitle)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    if unresolvedCount > 0 {
                        PillLabel(
                            env.s(DeviceHubStrings.unresolvedCountLabel.filling(["n": env.format.integer(unresolvedCount)])),
                            systemImage: "exclamationmark.circle", tint: BadanColor.outOfBand)
                    } else if resolvedCount > 0 {
                        PillLabel(
                            env.s(DeviceHubStrings.resolvedCountLabel.filling(["n": env.format.integer(resolvedCount)])),
                            tint: BadanColor.textSecondary)
                    }
                    Image(systemName: "chevron.forward")
                        .font(BadanFont.caption.weight(.semibold))
                        .foregroundStyle(BadanColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card

private struct DeviceHubCard: View {
    @Environment(AppEnvironment.self) private var env
    let card: DeviceHubCardInfo

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: deviceHubSourceIcon(card.source.type))
                        .imageScale(.large)
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(card.source.displayName)
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.textPrimary)
                        LText(deviceHubSourceTypeLabel(card.source.type))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    Spacer(minLength: BadanSpace.space2)
                    PillLabel(env.s(card.overallStatus.label), systemImage: card.overallStatus.symbolName,
                              tint: card.overallStatus.tint)
                }

                if card.devices.isEmpty {
                    // No discrete paired devices under this source (e.g. a platform stream with
                    // no BLE accessory behind it) — show the source's own sync facts directly,
                    // matching `SourcesSourceCard`'s "show only what's actually trackable" rule.
                    if let lastDelivery = card.source.lastDeliveryAt {
                        DeviceHubDetailRow(label: DeviceHubStrings.lastDelivery,
                                           value: DeviceHubDateFormat.string(lastDelivery, env.language))
                    }
                } else {
                    Rectangle().fill(BadanColor.separator).frame(height: 1)
                    ForEach(card.devices) { device in
                        NavigationLink {
                            DeviceDetailScreen(device: device, source: card.source, sourceClassId: card.sourceClassId)
                        } label: {
                            DeviceHubDeviceRow(device: device, status: card.deviceStatuses[device.id] ?? .needsAttention)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct DeviceHubDeviceRow: View {
    @Environment(AppEnvironment.self) private var env
    let device: Device
    let status: DeviceHealthStatus

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: deviceHubDeviceIcon(device))
                .imageScale(.medium)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(device.name)
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textPrimary)
                Text(DeviceHubDateFormat.relative(device.lastSeen, env.language, now: env.now()))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            PillLabel(env.s(status.label), systemImage: status.symbolName, tint: status.tint)
            Image(systemName: "chevron.forward")
                .font(BadanFont.caption.weight(.semibold))
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BadanSpace.touchMin)
        .contentShape(Rectangle())
    }
}

/// A fixed-label/trailing-value row for the "nothing to click into" (no discrete devices) case —
/// mirrors `SourcesSourceCard.detailLine`'s alignment convention.
struct DeviceHubDetailRow: View {
    @Environment(AppEnvironment.self) private var env
    let label: LocalizedString
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
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
