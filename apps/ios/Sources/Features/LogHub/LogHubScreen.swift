import SwiftUI
import UIKit

// MARK: - File-local strings (bilingual; not in the shared catalog)

private enum LogHubStrings {
    static let quickAdd = LocalizedString(en: "Quick add", ar: "إضافة سريعة")
    static let ml = LocalizedString(en: "ml", ar: "مل")
    static let storedManually = LocalizedString(en: "Saved as your own entry", ar: "يُحفَظ كإدخال منك")
    static let customAmount = LocalizedString(en: "Custom amount", ar: "كمية مخصصة")
    static let todayTotal = LocalizedString(en: "Today", ar: "اليوم")
    static let saveFailed = LocalizedString(en: "Couldn't save. Try again.", ar: "تعذّر الحفظ. حاول مرة أخرى.")
    static let weightInvalidHint = LocalizedString(
        en: "Enter a number greater than 0.",
        ar: "أدخل رقمًا أكبر من 0."
    )
    static let recentsLoadError = LocalizedString(
        en: "Couldn't load recent activity.",
        ar: "تعذّر تحميل النشاط الأخير."
    )
    static let sensitiveHiddenHint = LocalizedString(
        en: "Symptoms & medications are hidden. Turn on Sensitive records in Settings to log them.",
        ar: "الأعراض والأدوية مخفية. فعّل السجلات الحساسة من الإعدادات لتسجيلها."
    )
}

/// File-local layout constants — kept here (not in the shared `DesignSystem/Tokens.swift`)
/// because this bundle only owns `LogHubScreen.swift`; centralizing these into the shared
/// token file is a separate, cross-file change.
private enum LogHubLayout {
    static let tileMinHeight: CGFloat = 92
    static let rowMinHeight: CGFloat = 60
    static let sheetHeight: CGFloat = 260
}

// MARK: - View model

@Observable
@MainActor
final class LogHubViewModel {
    struct RecentItem: Identifiable {
        enum Kind { case symptom, workout }
        let id: String
        let label: String
        let systemImage: String
        let date: Date
        let kind: Kind
    }

    enum RecentsState {
        case loading
        case loaded([RecentItem])
        case error(String)
    }

    var recentsState: RecentsState = .loading
    private var lastLoadedAt: Date?

    /// Recent symptom/workout entries surfaced as quick "log again" chips. Debounced so
    /// re-appearing on the Log tab within a short window doesn't re-query storage.
    func load(_ env: AppEnvironment) {
        let now = env.now()
        if let lastLoadedAt, now.timeIntervalSince(lastLoadedAt) < 30 { return }

        // Only the newest few chips are ever shown, so a 7-day window is enough.
        let from = now.addingTimeInterval(-7 * 86_400)
        var items: [RecentItem] = []
        var hadError = false

        // Symptoms are sensitive — only touch that store when the module is enabled.
        if env.profile.sensitiveModulesEnabled {
            if let symptoms = try? env.logging.symptoms(from: from, to: now) {
                for s in symptoms.prefix(3) {
                    let label = env.symptoms.displayName(forId: s.symptomId, customLabel: s.customLabel)
                        .resolved(env.language)
                    items.append(RecentItem(id: s.id, label: label, systemImage: "waveform.path.ecg",
                                            date: s.occurredAt, kind: .symptom))
                }
            } else {
                hadError = true
            }
        }
        if let workouts = try? env.logging.workouts(from: from, to: now) {
            for w in workouts.prefix(3) {
                items.append(RecentItem(id: w.id, label: w.activityType, systemImage: "figure.run",
                                        date: w.startAt, kind: .workout))
            }
        } else {
            hadError = true
        }

        items.sort { $0.date > $1.date }
        lastLoadedAt = now
        // Distinguish "genuinely nothing logged yet" from a real storage failure — both used to
        // collapse to the same silent empty state.
        if items.isEmpty && hadError {
            recentsState = .error(env.s(LogHubStrings.recentsLoadError))
        } else {
            recentsState = .loaded(items)
        }
    }

    // MARK: Quick-log mutations

    @discardableResult
    func logWater(_ milliliters: Double, env: AppEnvironment) -> Bool {
        let now = env.now()
        let entry = NutritionEntry(
            id: ULID.newID(),
            description: env.s(Loc.logWater),
            mealType: .drink,
            waterMl: milliliters,
            occurredAt: now,
            tzId: TimeZone.current.identifier,
            updatedAt: now,
            originDeviceId: env.deviceId
        )
        do {
            try env.logging.upsertNutrition(entry)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func logWeight(displayValue: Double, env: AppEnvironment) -> Bool {
        let def = env.registry.definitionOrFallback(MetricID.weight)
        let displayUnit = env.format.displayUnit(for: def)
        let canonicalValue = Units.toCanonical(displayValue, from: displayUnit, canonical: def.canonicalUnit)
        let now = env.now()
        let tz = TimeZone.current.identifier
        let provenance = Provenance(
            sourceId: env.deviceId,
            deviceId: env.deviceId,
            ingestionPath: .manual,
            measuredAt: now,
            measuredTimezone: tz,
            recordedAt: now,
            ingestedAt: now
        )
        let sample = RawSample(
            id: ULID.newID(),
            metricId: def.metricId,
            value: canonicalValue,
            unit: def.canonicalUnit,
            originalValue: displayValue,
            originalUnit: displayUnit,
            startAt: now,
            tzId: tz,
            provenance: provenance,
            updatedAt: now,
            originDeviceId: env.deviceId
        )
        do {
            try env.measurements.upsertRawSample(sample)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Screen

struct LogHubScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = LogHubViewModel()
    @State private var activeSheet: LogSheet?

    private enum LogSheet: String, Identifiable {
        case water, weight
        var id: String { rawValue }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: BadanSpace.space3),
         GridItem(.flexible(), spacing: BadanSpace.space3)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space6) {
                logTypesSection
                quickAddSection
                recentsSectionIfNeeded
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logTitle))
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .water:
                WaterQuickSheet { ml in vm.logWater(ml, env: env) }
            case .weight:
                WeightQuickSheet { value in vm.logWeight(displayValue: value, env: env) }
            }
        }
        .task { vm.load(env) }
    }

    // MARK: Sections

    private var logTypesSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.tabLog))
            LazyVGrid(columns: columns, spacing: BadanSpace.space3) {
                // Symptom & Medication are sensitive — hidden entirely when that module is off.
                if env.profile.sensitiveModulesEnabled {
                    NavigationLink {
                        SymptomLogView()
                    } label: {
                        LogTile(title: env.s(Loc.logSymptom), systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        MedicationLogView()
                    } label: {
                        LogTile(title: env.s(Loc.logMedication), systemImage: "pills.fill")
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    WorkoutLogView()
                } label: {
                    LogTile(title: env.s(Loc.logWorkout), systemImage: "figure.run")
                }
                .buttonStyle(.plain)

                if env.profile.nutritionEnabled {
                    NavigationLink {
                        NutritionLogView()
                    } label: {
                        LogTile(title: env.s(Loc.logFood), systemImage: "fork.knife")
                    }
                    .buttonStyle(.plain)
                }
            }
            // Explains the (intentional) disappearance of two tiles instead of leaving it silent.
            if !env.profile.sensitiveModulesEnabled {
                Text(env.s(LogHubStrings.sensitiveHiddenHint))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(LogHubStrings.quickAdd))
            LazyVGrid(columns: columns, spacing: BadanSpace.space3) {
                Button {
                    activeSheet = .water
                } label: {
                    LogTile(title: env.s(Loc.logWater), systemImage: "drop.fill", isQuickAdd: true)
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .weight
                } label: {
                    LogTile(title: env.s(Loc.logWeight), systemImage: "scalemass.fill", isQuickAdd: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var recentsSectionIfNeeded: some View {
        switch vm.recentsState {
        case .loaded(let items) where !items.isEmpty:
            recentsSection(items: items)
        case .error(let message):
            recentsErrorSection(message)
        default:
            EmptyView()
        }
    }

    private func recentsSection(items: [LogHubViewModel.RecentItem]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.recents))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    ForEach(items) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            RecentChip(
                                label: item.label,
                                systemImage: item.systemImage,
                                detail: relativeTime(item.date)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, BadanSpace.space1)
            }
            // Trailing fade hints more chips exist off-screen, mirroring TimelineScreen's
            // filter-row fade (there's no shared modifier for it, so this mirrors that pattern
            // in-file rather than introducing a new cross-file DesignSystem dependency).
            .mask(recentsScrollFadeMask)
        }
    }

    private var recentsScrollFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func recentsErrorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(Loc.recents))
            Text(message)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    @ViewBuilder
    private func destination(for item: LogHubViewModel.RecentItem) -> some View {
        switch item.kind {
        case .symptom: SymptomLogView()
        case .workout: WorkoutLogView()
        }
    }

    private static let sharedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.sharedRelativeFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.sharedRelativeFormatter.localizedString(for: date, relativeTo: env.now())
    }
}

// MARK: - Tiles & chips

private struct LogTile: View {
    @Environment(AppEnvironment.self) private var env
    let title: String
    let systemImage: String
    var isQuickAdd: Bool = false

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(BadanColor.primary)
                    .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                    .background(
                        BadanColor.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Distinguishes "presents a sheet" tiles from "pushes a screen" tiles so the
                // navigation pattern is predictable before tapping.
                if isQuickAdd {
                    Text(env.s(LogHubStrings.quickAdd))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: LogHubLayout.tileMinHeight, maxHeight: .infinity, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
    }
}

private struct RecentChip: View {
    let label: String
    let systemImage: String
    let detail: String?

    var body: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(BadanFont.chip)
                    .foregroundStyle(BadanColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(BadanColor.separator, lineWidth: 1))
        .contentShape(Capsule())
    }
}

// MARK: - Shared quick-log row styling

private struct QuickRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BadanSpace.space4)
            .frame(maxWidth: .infinity, minHeight: LogHubLayout.rowMinHeight, alignment: .leading)
            .background(
                BadanColor.surface,
                in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                    .strokeBorder(BadanColor.separator, lineWidth: 1)
            )
    }
}

private extension View {
    func quickRowBackground() -> some View { modifier(QuickRowBackground()) }
}

// MARK: - Quick-log sheets

private struct WaterQuickSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onLog: (Double) -> Bool

    private let amounts: [Double] = [250, 500]
    @State private var customText: String = ""
    @State private var saveFailed: Bool = false

    private var customValue: Double? {
        let normalized = customText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    /// Sum of water already logged today, for a quick "you've had X so far" readout. There is
    /// no user-configurable daily goal anywhere in the profile model, so this shows a running
    /// total only, not progress toward a target.
    private var todayTotalMl: Double {
        let now = env.now()
        let start = Calendar.current.startOfDay(for: now)
        guard let entries = try? env.logging.nutrition(from: start, to: now) else { return 0 }
        return entries.reduce(0) { $0 + ($1.waterMl ?? 0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    if todayTotalMl > 0 {
                        Text("\(env.s(LogHubStrings.todayTotal)): \(env.format.integer(Int(todayTotalMl))) \(env.s(LogHubStrings.ml))")
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    ForEach(amounts, id: \.self) { ml in
                        Button {
                            commit(ml)
                        } label: {
                            HStack(spacing: BadanSpace.space3) {
                                Image(systemName: "drop.fill")
                                    .foregroundStyle(BadanColor.primary)
                                    .accessibilityHidden(true)
                                Text("+\(env.format.integer(Int(ml))) \(env.s(LogHubStrings.ml))")
                                    .font(BadanFont.body.weight(.semibold))
                                    .foregroundStyle(BadanColor.textPrimary)
                                Spacer(minLength: BadanSpace.space2)
                            }
                            .quickRowBackground()
                            .contentShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "drop")
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                        TextField(env.s(LogHubStrings.customAmount), text: $customText)
                            .keyboardType(.decimalPad)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(env.s(LogHubStrings.ml))
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                        Button(env.s(Loc.save)) {
                            if let value = customValue { commit(value) }
                        }
                        .font(BadanFont.link)
                        .disabled(customValue == nil)
                    }
                    .quickRowBackground()

                    if saveFailed {
                        Text(env.s(LogHubStrings.saveFailed))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBand)
                    }
                }
                .padding(BadanSpace.space4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(BadanColor.background)
            .navigationTitle("\(env.s(LogHubStrings.quickAdd)) · \(env.s(Loc.logWater))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
            }
        }
        .presentationDetents([.height(LogHubLayout.sheetHeight), .medium])
    }

    private func commit(_ ml: Double) {
        if onLog(ml) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            saveFailed = true
        }
    }
}

private struct WeightQuickSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onLog: (Double) -> Bool

    @State private var text: String = ""
    @State private var saveFailed: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                        TextField(env.s(Loc.logWeight), text: $text)
                            .keyboardType(.decimalPad)
                            .font(BadanFont.numeralM)
                            .foregroundStyle(BadanColor.textPrimary)
                        Text(unitLabel)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    .quickRowBackground()

                    // Explains a disabled Save instead of leaving it as an unexplained dead end.
                    if !text.isEmpty, parsedValue == nil {
                        Text(env.s(LogHubStrings.weightInvalidHint))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBand)
                    }

                    // Power altitude: name where this number will live (provenance + canonical unit).
                    if env.depth.showsPowerDetail {
                        Text("\(env.s(LogHubStrings.storedManually)) · \(canonicalUnit)")
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }

                    if saveFailed {
                        Text(env.s(LogHubStrings.saveFailed))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBand)
                    }
                }
                .padding(BadanSpace.space4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(BadanColor.background)
            .navigationTitle("\(env.s(LogHubStrings.quickAdd)) · \(env.s(Loc.logWeight))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) {
                        guard let value = parsedValue else { return }
                        if onLog(value) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                        } else {
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            saveFailed = true
                        }
                    }
                    .disabled(parsedValue == nil)
                }
            }
        }
        .presentationDetents([.height(LogHubLayout.sheetHeight), .medium])
    }

    private var parsedValue: Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private var unitLabel: String {
        env.format.unitLabel(metricId: MetricID.weight) ?? canonicalUnit
    }

    private var canonicalUnit: String {
        env.registry.definitionOrFallback(MetricID.weight).canonicalUnit
    }
}
