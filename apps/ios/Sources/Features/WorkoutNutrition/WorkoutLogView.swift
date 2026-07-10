import SwiftUI

// MARK: - Screen-local bilingual strings

/// Strings only the workout-capture surface needs. Shared vocabulary comes from `Loc`; these
/// fill the gaps with real Arabic. Framing stays neutral — activity is never moralized and a
/// rest day is presented as valid, not as a shortfall.
private enum WorkoutLogStrings {
    static let logMovement = LocalizedString(en: "Log a workout", ar: "سجّل تمريناً")
    static let optionalDetails = LocalizedString(en: "Optional details", ar: "تفاصيل اختيارية")
    static let distance = LocalizedString(en: "Distance", ar: "المسافة")
    static let recentWorkouts = LocalizedString(en: "Recent workouts", ar: "التمارين الأخيرة")
    static let recoverySub = LocalizedString(
        en: "Nothing logged today — rest is part of movement too.",
        ar: "لم تُسجَّل حركة اليوم — الراحة جزء من النشاط أيضاً.")
    static let noneYet = LocalizedString(en: "No workouts in the last two weeks.",
                                         ar: "لا تمارين في الأسبوعين الماضيين.")
    static let effortLight = LocalizedString(en: "Light", ar: "خفيف")
    static let effortHard = LocalizedString(en: "Max effort", ar: "أقصى جهد")
    static let savedManually = LocalizedString(en: "Saved as your own entry", ar: "يُحفَظ كإدخال منك")
    static let rpe = LocalizedString(en: "RPE", ar: "الجهد")
    static let km = LocalizedString(en: "km", ar: "كم")
    static let kcal = LocalizedString(en: "kcal", ar: "سعرة")
    static let meters = LocalizedString(en: "m", ar: "م")
    static let seconds = LocalizedString(en: "s", ar: "ث")
}

// MARK: - Activity model

/// The quick-add activity types. `rawValue` is the stable English key stored on the record
/// (matching seeded data); display is bilingual and mirror-safe.
enum WorkoutActivity: String, CaseIterable, Identifiable {
    case run = "Run"
    case walk = "Walk"
    case strength = "Strength"
    case cycle = "Cycle"
    case other = "Other"

    var id: String { rawValue }

    var label: LocalizedString {
        switch self {
        case .run: return LocalizedString(en: "Run", ar: "جري")
        case .walk: return LocalizedString(en: "Walk", ar: "مشي")
        case .strength: return LocalizedString(en: "Strength", ar: "قوة")
        case .cycle: return LocalizedString(en: "Cycle", ar: "دراجة")
        case .other: return LocalizedString(en: "Other", ar: "أخرى")
        }
    }

    var symbol: String {
        switch self {
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        case .strength: return "dumbbell.fill"
        case .cycle: return "bicycle"
        case .other: return "figure.mixed.cardio"
        }
    }

    /// Bilingual label for a stored activity string; falls back to the raw value verbatim.
    static func label(forStored raw: String) -> LocalizedString {
        WorkoutActivity(rawValue: raw)?.label ?? LocalizedString(en: raw, ar: raw)
    }

    static func symbol(forStored raw: String) -> String {
        WorkoutActivity(rawValue: raw)?.symbol ?? "figure.mixed.cardio"
    }
}

// MARK: - View model

@Observable
@MainActor
final class WorkoutLogViewModel {
    var recent: [WorkoutEntry] = []
    var loggedToday: Bool = false

    private var tz: String { TimeZone.current.identifier }

    /// Load the last two weeks of workouts and note whether anything is attributed to today.
    func load(_ env: AppEnvironment) {
        let now = env.now()
        let from = now.addingTimeInterval(-14 * 86_400)
        let all = (try? env.logging.workouts(from: from, to: now)) ?? []
        recent = all
        let startOfToday = DayAttribution.startOfDay(now, tz: tz)
        loggedToday = all.contains { $0.startAt >= startOfToday }
    }

    /// Insert a manual workout ending now, then reload the list in place.
    func save(activity: WorkoutActivity, minutes: Int, rpe: Int,
              energyKcal: Double?, distanceM: Double?, env: AppEnvironment) {
        let now = env.now()
        let entry = WorkoutEntry(
            id: ULID.newID(),
            activityType: activity.rawValue,
            startAt: now.addingTimeInterval(-Double(minutes) * 60),
            endAt: now,
            tzId: tz,
            energyKcal: energyKcal,
            distanceM: distanceM,
            perceivedEffort: rpe,
            ingestionPath: .manual,
            updatedAt: now,
            originDeviceId: env.deviceId)
        try? env.logging.upsertWorkout(entry)
        load(env)
    }
}

// MARK: - Screen

/// Under-10-second workout capture, pushed as its own screen. Pick an activity, set duration
/// and perceived effort, optionally add energy + distance, then save. Recent workouts sit
/// below; when nothing is logged today a calm "recovery day" note stands in — never a nag.
struct WorkoutLogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = WorkoutLogViewModel()

    // Capture state
    @State private var activity: WorkoutActivity = .run
    @State private var minutes: Int = 30
    @State private var rpe: Double = 5
    @State private var kcalText: String = ""
    @State private var distanceText: String = ""

    private var tz: String { TimeZone.current.identifier }
    private var power: Bool { env.depth.showsPowerDetail }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                activityCard
                durationCard
                effortCard
                optionalCard
                saveButton
                recentSection
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logWorkout))
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.load(env) }
    }

    // MARK: - Form cards

    private var activityCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.activityType))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(WorkoutActivity.allCases) { option in
                            activityPill(option)
                        }
                    }
                    .padding(.vertical, BadanSpace.space1)
                }
            }
        }
    }

    private func activityPill(_ option: WorkoutActivity) -> some View {
        let selected = option == activity
        return Button {
            activity = option
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: option.symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(env.s(option.label))
                    .font(BadanFont.chip)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : BadanColor.textPrimary)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(
                (selected ? BadanColor.primary : BadanColor.surface),
                in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
    }

    private var durationCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.duration)) {
                    if power {
                        // Raw seconds are a power-only affordance.
                        Text("\(env.format.integer(minutes * 60)) \(env.s(WorkoutLogStrings.seconds))")
                            .font(BadanFont.chip.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                HStack(spacing: BadanSpace.space3) {
                    Text(env.format.duration(seconds: Double(minutes) * 60, unit: "min"))
                        .font(BadanFont.numeralM)
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    Stepper("", value: $minutes, in: 1...360, step: 5)
                        .labelsHidden()
                        .accessibilityLabel(env.s(Loc.duration))
                }
                .frame(minHeight: BadanSpace.touchMin)
            }
        }
    }

    private var effortCard: some View {
        let value = Int(rpe.rounded())
        return BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.effort)) {
                    Text("\(env.s(WorkoutLogStrings.rpe)) \(env.format.integer(value)) / \(env.format.integer(10))")
                        .font(BadanFont.chip.monospacedDigit())
                        .foregroundStyle(BadanColor.textSecondary)
                }
                // Effort is neutral — a single calm tint, never red/green.
                Slider(value: $rpe, in: 1...10, step: 1)
                    .tint(BadanColor.primary)
                    .accessibilityValue("\(env.format.integer(value))")
                HStack {
                    Text(env.s(WorkoutLogStrings.effortLight))
                    Spacer(minLength: BadanSpace.space2)
                    Text(env.s(WorkoutLogStrings.effortHard))
                }
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    private var optionalCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(WorkoutLogStrings.optionalDetails))
                numberField(icon: "flame", placeholder: env.s(Loc.calories),
                            text: $kcalText, unit: env.s(WorkoutLogStrings.kcal))
                Divider()
                numberField(icon: "ruler", placeholder: env.s(WorkoutLogStrings.distance),
                            text: $distanceText, unit: env.s(WorkoutLogStrings.km))
                if power {
                    Text(env.s(WorkoutLogStrings.savedManually))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private func numberField(icon: String, placeholder: String,
                             text: Binding<String>, unit: String) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
            Text(unit)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private var saveButton: some View {
        Button {
            vm.save(activity: activity, minutes: minutes, rpe: Int(rpe.rounded()),
                    energyKcal: parseDecimal(kcalText),
                    distanceM: parseDecimal(distanceText).map { $0 * 1000 },
                    env: env)
            // Keep the altitude and activity; clear the one-off measurements.
            kcalText = ""
            distanceText = ""
        } label: {
            Text(env.s(Loc.save))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: BadanSpace.touchMin)
                .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
    }

    // MARK: - Recent workouts

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(WorkoutLogStrings.recentWorkouts))
            if !vm.loggedToday {
                recoveryCard
            }
            if vm.recent.isEmpty {
                if vm.loggedToday {
                    Text(env.s(WorkoutLogStrings.noneYet))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            } else {
                ForEach(vm.recent) { workout in
                    workoutRow(workout)
                }
            }
        }
    }

    private var recoveryCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "leaf")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(BadanColor.primary)
                    .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                    .background(BadanColor.primary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(Loc.recoveryDay))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(WorkoutLogStrings.recoverySub))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BadanSpace.space2)
            }
        }
    }

    private func workoutRow(_ workout: WorkoutEntry) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: WorkoutActivity.symbol(forStored: workout.activityType))
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(env.s(WorkoutActivity.label(forStored: workout.activityType)))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    Text(env.format.duration(seconds: workout.durationSeconds, unit: "min"))
                        .font(BadanFont.bodyCompact.monospacedDigit())
                        .foregroundStyle(BadanColor.textSecondary)
                }

                let chips = detailChips(workout)
                if !chips.isEmpty {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(chips.indices, id: \.self) { index in
                            chips[index]
                        }
                    }
                }

                Text(dateText(workout.startAt))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)

                if power {
                    // Power altitude: raw canonical values + lineage.
                    rawLine(workout)
                    ProvenanceRow(sourceName: env.s(WorkoutLogStrings.savedManually),
                                  ingestionPath: workout.ingestionPath,
                                  timestamp: workout.startAt,
                                  language: env.language)
                }
            }
        }
    }

    private func detailChips(_ workout: WorkoutEntry) -> [PillLabel] {
        var chips: [PillLabel] = []
        if let rpe = workout.perceivedEffort {
            chips.append(PillLabel("\(env.s(WorkoutLogStrings.rpe)) \(env.format.integer(rpe))",
                                   systemImage: "gauge"))
        }
        if let kcal = workout.energyKcal {
            chips.append(PillLabel("\(env.format.integer(Int(kcal.rounded()))) \(env.s(WorkoutLogStrings.kcal))",
                                   systemImage: "flame"))
        }
        if let distance = workout.distanceM {
            chips.append(PillLabel("\(env.format.number(distance / 1000, fraction: 1)) \(env.s(WorkoutLogStrings.km))",
                                   systemImage: "ruler"))
        }
        return chips
    }

    private func rawLine(_ workout: WorkoutEntry) -> some View {
        var parts: [String] = ["\(env.format.integer(Int(workout.durationSeconds.rounded()))) \(env.s(WorkoutLogStrings.seconds))"]
        if let distance = workout.distanceM {
            parts.append("\(env.format.integer(Int(distance.rounded()))) \(env.s(WorkoutLogStrings.meters))")
        }
        return Text(parts.joined(separator: " · "))
            .font(BadanFont.caption.monospacedDigit())
            .foregroundStyle(BadanColor.textSecondary)
    }

    // MARK: - Helpers

    private func parseDecimal(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
