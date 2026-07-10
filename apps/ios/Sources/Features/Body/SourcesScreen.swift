import SwiftUI

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
                state = .empty(env.s(Loc.nothingYet))
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
        StatefulContainer(vm.state) { data in
            ScrollView {
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

                    if env.depth.showsPowerDetail {
                        SourcesPriorityNote(title: Self.priorityTitle, note: Self.priorityNote)
                    }
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(Loc.dataSources))
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
    private static let lastSeenLabel = LocalizedString(en: "Last seen", ar: "آخر ظهور")

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

                if env.depth.showsPowerDetail {
                    if let connected = info.source.connectedAt {
                        detailLine(Self.connectedLabel, value: SourcesDateText.string(connected, env.language))
                    }
                    if let delivery = info.source.lastDeliveryAt {
                        detailLine(Self.lastDeliveryLabel, value: SourcesDateText.string(delivery, env.language))
                    }
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
                                    LText(Self.lastSeenLabel)
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                    Text(SourcesDateText.string(device.lastSeen, env.language))
                                        .font(BadanFont.caption)
                                        .foregroundStyle(BadanColor.textSecondary)
                                }
                            }
                        }
                        .frame(minHeight: BadanSpace.touchMin)
                    }
                }
            }
        }
    }

    private func detailLine(_ label: LocalizedString, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
            LText(label)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
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
                            }
                        }
                    }
                }
            }
        }
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

private func sourceStatus(_ status: SourceStatus) -> (label: LocalizedString, tint: Color, icon: String) {
    switch status {
    case .active: return (LocalizedString(en: "Active", ar: "نشط"), BadanColor.primary, "checkmark.circle")
    case .revoked: return (LocalizedString(en: "Turned off", ar: "متوقف"), BadanColor.outOfBand, "minus.circle")
    case .hidden: return (LocalizedString(en: "Hidden", ar: "مخفي"), BadanColor.textSecondary, "eye.slash")
    }
}

private func deviceIcon(_ device: Device) -> String {
    let hay = (device.name + " " + (device.model ?? "")).lowercased()
    if hay.contains("watch") { return "applewatch" }
    if hay.contains("phone") { return "iphone" }
    if hay.contains("ring") { return "circle.circle" }
    if hay.contains("band") { return "wave.3.right.circle" }
    return "sensor.tag.radiowaves.forward.fill"
}

private func storeLabel(_ store: String) -> LocalizedString {
    switch store {
    case "healthkit": return LocalizedString(en: "Apple Health", ar: "صحة آبل")
    case "healthConnect": return LocalizedString(en: "Health Connect", ar: "هيلث كونكت")
    default: return LocalizedString(en: store, ar: store)
    }
}

private func permissionStyle(_ status: PermissionStatus) -> (tint: Color, icon: String) {
    switch status {
    case .granted: return (BadanColor.primary, "checkmark.circle")
    case .partial: return (BadanColor.info, "circle.lefthalf.filled")
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

/// Small formatting utilities kept together so both cards format dates and tokens identically.
private enum SourcesDateText {
    static func string(_ date: Date, _ language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "sleepAnalysis" -> "Sleep analysis": split camelCase and capitalize the first word.
    static func humanize(_ token: String) -> String {
        var out = ""
        for (index, character) in token.enumerated() {
            if index > 0 && character.isUppercase { out.append(" ") }
            out.append(character)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }
}
