import SwiftUI

// See `DeviceHubScreen.swift`'s file-top comment for this feature folder's scope boundary: no
// CoreBluetooth code anywhere in this lane, and no Blood Pressure / Thermometer / Pulse Oximeter
// surfaces. This screen is a plain read model over one `Source`/`Device` pair and the existing
// raw-sample store — nothing here assumes a BLE connection exists.

// MARK: - Local strings

private enum DeviceDetailStrings {
    static let syncHistoryHeader = LocalizedString(en: "Sync history", ar: "سجل المزامنة")
    static let connected = LocalizedString(en: "Connected", ar: "تاريخ الاتصال")
    static let lastDelivery = LocalizedString(en: "Last delivery", ar: "آخر تسليم")
    static let firstSeen = LocalizedString(en: "First seen", ar: "أول ظهور")
    static let lastSeen = LocalizedString(en: "Last seen", ar: "آخر ظهور")
    static let updated = LocalizedString(en: "Updated", ar: "آخر تحديث")
    static let bundle = LocalizedString(en: "Bundle", ar: "الحزمة")
    static let model = LocalizedString(en: "Model", ar: "الطراز")
    /// (honesty note) BADAN does not currently track a granular per-sync event log for a
    /// device — only the timestamps above. This says so plainly rather than implying a fuller
    /// history exists than actually does.
    static let syncHistoryNote = LocalizedString(
        en: "This is everything BADAN currently tracks about this device's sync activity — there is no per-sync event log yet, only these timestamps.",
        ar: "هذا كل ما يتتبّعه بدن حالياً عن نشاط مزامنة هذا الجهاز — لا يوجد سجل أحداث لكل مزامنة بعد، فقط هذه الطوابع الزمنية.")

    static let sensorQualityHeader = LocalizedString(en: "What this sensor is good at", ar: "ما يجيده هذا المستشعر")

    static let rawDataHeader = LocalizedString(en: "Raw data", ar: "البيانات الخام")
    static let rawDataSubtitle = LocalizedString(
        en: "Straight from your records — no extra calculation, nothing paywalled.",
        ar: "مباشرة من سجلاتك — دون أي حساب إضافي، ودون أي حجب.")
    static let noRawData = LocalizedString(
        en: "No raw readings from this device in the last 30 days.",
        ar: "لا قراءات خام من هذا الجهاز خلال آخر 30 يوماً.")
    static let windowCaption = LocalizedString(en: "Last 30 days, most recent first", ar: "آخر 30 يوماً، الأحدث أولاً")
}

// MARK: - Raw sample row (pure value type — the fetch below is the only place that builds one)

struct DeviceRawSampleRow: Identifiable, Hashable {
    let id: String
    let metricId: String
    let value: Double
    let unit: String
    let startAt: Date
    let ingestionPath: IngestionPath
    let isSuppressed: Bool
}

/// Reads recent raw samples for one device, using ONLY existing, unmodified repository methods
/// (`MeasurementRepository.rawSamples(metricId:from:to:includeSuppressed:)` takes a metric id, not
/// a device id — there is no device-scoped raw-sample query today, and none is added here). This
/// scans the metric families the device's source is known to produce
/// (`SensorQualityMap.classId`/`level`, the same classification `SourcesScreen` already surfaces),
/// then filters each metric's samples in memory to this exact device's `provenance.deviceId` —
/// honest and bounded, without any new schema or repository surface.
///
/// `includeSuppressed: true` is deliberate: a raw data browser exists precisely so raw data is
/// never hidden (I5/"raw data is not paywalled") — a dedup-suppressed reading still shows, marked,
/// rather than silently vanishing as if it had never been recorded (I3: suppress, never delete).
enum DeviceRawSampleFetch {
    static let lookbackDays = 30
    static let maxRows = 40
    private static let candidateFamilies: [MetricFamily] = [.heart, .sleep, .activity, .respiratory, .body]

    static func fetch(
        measurements: MeasurementRepository, registry: MetricRegistry, sourceClassId: String,
        deviceId: String, now: Date
    ) -> [DeviceRawSampleRow] {
        let from = now.addingTimeInterval(-Double(lookbackDays) * 24 * 3600)
        var rows: [DeviceRawSampleRow] = []
        for family in candidateFamilies {
            guard SensorQualityMap.shared.level(sourceClassId: sourceClassId, family: family) != .unsupported else { continue }
            for definition in registry.metrics(in: family) {
                guard let samples = try? measurements.rawSamples(
                    metricId: definition.metricId, from: from, to: now, includeSuppressed: true
                ) else { continue }
                for sample in samples where sample.provenance.deviceId == deviceId {
                    rows.append(DeviceRawSampleRow(
                        id: sample.id, metricId: sample.metricId, value: sample.value, unit: sample.unit,
                        startAt: sample.startAt, ingestionPath: sample.provenance.ingestionPath,
                        isSuppressed: sample.provenance.isSuppressed))
                }
            }
        }
        return Array(rows.sorted { $0.startAt > $1.startAt }.prefix(maxRows))
    }
}

// MARK: - View model

struct DeviceDetailFetchInputs {
    var measurements: MeasurementRepository
    var registry: MetricRegistry
    var sourceClassId: String
    var deviceId: String
    var now: Date
}

@Observable
@MainActor
final class DeviceDetailViewModel {
    var state: LoadState<[DeviceRawSampleRow]> = .loading

    func load(_ env: AppEnvironment, device: Device, sourceClassId: String) async {
        let inputs = DeviceDetailFetchInputs(
            measurements: env.measurements, registry: env.registry, sourceClassId: sourceClassId,
            deviceId: device.id, now: env.now())

        let rows = await Task.detached(priority: .userInitiated) {
            DeviceRawSampleFetch.fetch(
                measurements: inputs.measurements, registry: inputs.registry,
                sourceClassId: inputs.sourceClassId, deviceId: inputs.deviceId, now: inputs.now)
        }.value

        guard !Task.isCancelled else { return }
        state = rows.isEmpty ? .empty(env.s(DeviceDetailStrings.noRawData)) : .loaded(rows)
    }
}

// MARK: - Screen

/// Sync history and a raw data browser for one device. Reads only what BADAN already tracks
/// (`Source.connectedAt`/`lastDeliveryAt`, `Device.firstSeen`/`lastSeen`) — there is no granular
/// per-sync event log to show, and this screen says so rather than fabricating one.
struct DeviceDetailScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = DeviceDetailViewModel()
    let device: Device
    let source: Source
    let sourceClassId: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                headerCard
                syncHistoryCard
                DeviceDetailSensorQualitySection(sourceClassId: sourceClassId)

                SectionHeader(env.s(DeviceDetailStrings.rawDataHeader))
                LText(DeviceDetailStrings.rawDataSubtitle)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)

                StatefulContainer(
                    vm.state,
                    emptyIcon: "tray",
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env, device: device, sourceClassId: sourceClassId) } }
                ) { rows in
                    rawSamplesCard(rows)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: DeviceDetailLoadKey(deviceId: device.id, generation: env.dataGeneration)) {
            await vm.load(env, device: device, sourceClassId: sourceClassId)
        }
    }

    private var headerCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: deviceHubDeviceIcon(device))
                    .imageScale(.large)
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(device.name)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    LText(deviceHubSourceTypeLabel(source.type))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
                Spacer(minLength: BadanSpace.space2)
                let status = DeviceHealthClassifier.status(
                    of: device,
                    sourceStatus: DeviceHealthClassifier.status(of: source, now: env.now()),
                    now: env.now())
                PillLabel(env.s(status.label), systemImage: status.symbolName, tint: status.tint)
            }
        }
    }

    private var syncHistoryCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(DeviceDetailStrings.syncHistoryHeader))
                if let connectedAt = source.connectedAt {
                    DeviceHubDetailRow(label: DeviceDetailStrings.connected,
                                       value: DeviceHubDateFormat.string(connectedAt, env.language))
                }
                if let lastDelivery = source.lastDeliveryAt {
                    DeviceHubDetailRow(label: DeviceDetailStrings.lastDelivery,
                                       value: DeviceHubDateFormat.string(lastDelivery, env.language))
                }
                DeviceHubDetailRow(label: DeviceDetailStrings.firstSeen,
                                   value: DeviceHubDateFormat.string(device.firstSeen, env.language))
                DeviceHubDetailRow(label: DeviceDetailStrings.lastSeen,
                                   value: DeviceHubDateFormat.string(device.lastSeen, env.language))
                if env.depth.showsPowerDetail {
                    if let model = device.model {
                        DeviceHubDetailRow(label: DeviceDetailStrings.model, value: model)
                    }
                    if let bundle = source.platformBundleId {
                        DeviceHubDetailRow(label: DeviceDetailStrings.bundle, value: bundle)
                    }
                    DeviceHubDetailRow(label: DeviceDetailStrings.updated,
                                       value: DeviceHubDateFormat.string(source.updatedAt, env.language))
                }
                LText(DeviceDetailStrings.syncHistoryNote)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rawSamplesCard(_ rows: [DeviceRawSampleRow]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(DeviceDetailStrings.windowCaption))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            BadanCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(BadanColor.separator).frame(height: 1)
                                .padding(.leading, BadanSpace.cardPadding)
                        }
                        rawSampleRow(row)
                    }
                }
            }
        }
    }

    private func rawSampleRow(_ row: DeviceRawSampleRow) -> some View {
        HStack(spacing: BadanSpace.space3) {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(env.registry.definitionOrFallback(row.metricId).displayName.resolved(env.language))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textPrimary)
                HStack(spacing: BadanSpace.space2) {
                    LText(row.ingestionPath.displayLabel)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    if row.isSuppressed {
                        PillLabel(env.s(Loc.suppressedDuplicate), systemImage: "arrow.uturn.backward",
                                  tint: BadanColor.textSecondary, filled: false)
                    }
                }
            }
            Spacer(minLength: BadanSpace.space2)
            VStack(alignment: .trailing, spacing: BadanSpace.space1) {
                Text(env.format.full(metricId: row.metricId, canonicalValue: row.value))
                    .font(BadanFont.bodyCompact.monospacedDigit())
                    .foregroundStyle(BadanColor.textPrimary)
                Text(DeviceHubDateFormat.string(row.startAt, env.language))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    // A timestamp is a technical fragment, not prose — left-to-right in both
                    // languages, matching `ProvenanceRow`.
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.horizontal, BadanSpace.cardPadding)
        .frame(minHeight: BadanSpace.touchMin)
    }
}

private struct DeviceDetailLoadKey: Equatable {
    let deviceId: String
    let generation: Int
}

// MARK: - Sensor quality (mirrors `SourcesScreen`'s section; that one is file-private there)

private struct DeviceDetailSensorQualitySection: View {
    @Environment(AppEnvironment.self) private var env
    let sourceClassId: String

    private static let families: [MetricFamily] = [.heart, .sleep, .activity, .respiratory, .body]

    private var sourceClass: SensorSourceClass? { SensorQualityMap.shared.sourceClass(id: sourceClassId) }
    private var rows: [(family: MetricFamily, level: SensorQualityLevel)] {
        Self.families
            .map { ($0, SensorQualityMap.shared.level(sourceClassId: sourceClassId, family: $0)) }
            .filter { $0.1 != .unsupported }
    }

    var body: some View {
        if let sourceClass, !rows.isEmpty {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    SectionHeader(env.s(DeviceDetailStrings.sensorQualityHeader))
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
                            PillLabel(env.s(row.level.label), systemImage: row.level.symbolName, tint: row.level.tint)
                        }
                        .frame(minHeight: BadanSpace.touchMin)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(env.s(row.family.displayName)), \(env.s(row.level.label))")
                    }
                }
            }
        }
    }
}
