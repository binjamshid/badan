import SwiftUI

// MARK: - File-local strings (bilingual; not in the shared catalog)

private enum LogHubStrings {
    static let quickAdd = LocalizedString(en: "Quick add", ar: "إضافة سريعة")
    static let ml = LocalizedString(en: "ml", ar: "مل")
    static let storedManually = LocalizedString(en: "Saved as your own entry", ar: "يُحفَظ كإدخال منك")
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

    var recents: [RecentItem] = []

    /// Recent symptom/workout entries surfaced as quick "log again" chips.
    func load(_ env: AppEnvironment) {
        var items: [RecentItem] = []
        let now = env.now()
        let from = now.addingTimeInterval(-30 * 86_400)

        // Symptoms are sensitive — only touch that store when the module is enabled.
        if env.profile.sensitiveModulesEnabled,
           let symptoms = try? env.logging.symptoms(from: from, to: now) {
            for s in symptoms.prefix(3) {
                let label = env.symptoms.displayName(forId: s.symptomId, customLabel: s.customLabel)
                    .resolved(env.language)
                items.append(RecentItem(id: s.id, label: label, systemImage: "waveform.path.ecg",
                                        date: s.occurredAt, kind: .symptom))
            }
        }
        if let workouts = try? env.logging.workouts(from: from, to: now) {
            for w in workouts.prefix(3) {
                items.append(RecentItem(id: w.id, label: w.activityType, systemImage: "figure.run",
                                        date: w.startAt, kind: .workout))
            }
        }
        recents = items.sorted { $0.date > $1.date }
    }

    // MARK: Quick-log mutations

    func logWater(_ milliliters: Double, env: AppEnvironment) {
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
        try? env.logging.upsertNutrition(entry)
    }

    func logWeight(displayValue: Double, env: AppEnvironment) {
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
        try? env.measurements.upsertRawSample(sample)
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
                if !vm.recents.isEmpty { recentsSection }
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
        }
    }

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(LogHubStrings.quickAdd))
            LazyVGrid(columns: columns, spacing: BadanSpace.space3) {
                Button {
                    activeSheet = .water
                } label: {
                    LogTile(title: env.s(Loc.logWater), systemImage: "drop.fill")
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .weight
                } label: {
                    LogTile(title: env.s(Loc.logWeight), systemImage: "scalemass.fill")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(Loc.recents))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    ForEach(vm.recents) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            RecentChip(
                                label: item.label,
                                systemImage: item.systemImage,
                                detail: env.depth.showsPowerDetail ? relativeTime(item.date) : nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, BadanSpace.space1)
            }
        }
    }

    @ViewBuilder
    private func destination(for item: LogHubViewModel.RecentItem) -> some View {
        switch item.kind {
        case .symptom: SymptomLogView()
        case .workout: WorkoutLogView()
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: env.now())
    }
}

// MARK: - Tiles & chips

private struct LogTile: View {
    let title: String
    let systemImage: String

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
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
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

// MARK: - Quick-log sheets

private struct WaterQuickSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onLog: (Double) -> Void

    private let amounts: [Double] = [250, 500]

    var body: some View {
        NavigationStack {
            VStack(spacing: BadanSpace.space3) {
                ForEach(amounts, id: \.self) { ml in
                    Button {
                        onLog(ml)
                        dismiss()
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
                        .padding(.horizontal, BadanSpace.space4)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        .background(
                            BadanColor.surface,
                            in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                                .strokeBorder(BadanColor.separator, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(BadanSpace.space4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.logWater))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
            }
        }
        .presentationDetents([.height(260)])
    }
}

private struct WeightQuickSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onLog: (Double) -> Void

    @State private var text: String = ""

    var body: some View {
        NavigationStack {
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
                .padding(.horizontal, BadanSpace.space4)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(
                    BadanColor.surface,
                    in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                        .strokeBorder(BadanColor.separator, lineWidth: 1)
                )

                // Power altitude: name where this number will live (provenance + canonical unit).
                if env.depth.showsPowerDetail {
                    Text("\(env.s(LogHubStrings.storedManually)) · \(canonicalUnit)")
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                Spacer()
            }
            .padding(BadanSpace.space4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.logWeight))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) {
                        if let value = parsedValue {
                            onLog(value)
                            dismiss()
                        }
                    }
                    .disabled(parsedValue == nil)
                }
            }
        }
        .presentationDetents([.height(260)])
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
