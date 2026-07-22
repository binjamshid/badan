import SwiftUI

// MARK: - Screen-local strings

private enum PostWorkoutSummaryStrings {
    static let title = LocalizedString(en: "Workout saved", ar: "تم حفظ التمرين")
    static let duration = LocalizedString(en: "Duration", ar: "المدة")
    static let setsLogged = LocalizedString(en: "Sets logged", ar: "المجموعات المسجَّلة")
    static let newRecords = LocalizedString(en: "New records", ar: "أرقام جديدة")
    // Celebratory but calm, per templates.json's wellnessRules: no fear/alarm words, no moral
    // judgment, no comparison-shaming ("beat your last session" etc.) — states the fact plainly.
    static let newRecordLine = LocalizedString(en: "New record", ar: "رقم جديد")
    static let qualityNote = LocalizedString(
        en: "A few things to know about this session", ar: "بعض الملاحظات حول هذه الجلسة")
    static let done = LocalizedString(en: "Done", ar: "تم")
    static let reps = LocalizedString(en: "reps", ar: "تكرارات")
    static let kg = LocalizedString(en: "kg", ar: "كغم")
}

// MARK: - Screen

/// EPIC-42 slice 2 — renders a `WorkoutSessionSummary` once `coordinator.finalize()` returns:
/// duration, set count, and any new personal records, named plainly and calmly (no false
/// precision, no comparison-shaming language — see `templates.json`'s `wellnessRules`).
///
/// **This is a summary, not the full plan-scoped post-workout notebook.** No timeline, splits,
/// zones, or reflections yet — that is later work (plan §9.18's fuller notebook), not silently
/// under-delivered here without a note: this screen is deliberately just the immediate payoff for
/// finishing a session.
struct PostWorkoutSummaryScreen: View {
    @Environment(AppEnvironment.self) private var env
    let summary: WorkoutSessionSummary
    /// Pops the entire workout flow back to the Log tab — the same closure `WorkoutHomeScreen`
    /// captured at the top of this flow, threaded through unchanged.
    let returnToLog: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                headerCard
                if summary.strengthSetCount > 0 {
                    setsCard
                }
                if !summary.newPersonalRecords.isEmpty {
                    recordsCard
                }
                if !summary.degradedConditions.isEmpty {
                    qualityCard
                }
                doneButton
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(PostWorkoutSummaryStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var activityDisplayName: String {
        ActivityCatalog.shared.definition(summary.activityType)?.displayName.resolved(env.language) ?? summary.activityType
    }

    private var headerCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(activityDisplayName)
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                }
                StatBox(value: WorkoutTimeFormat.string(seconds: summary.durationSeconds,
                                                        language: env.language, arabicDigits: env.profile.arabicDigits),
                       label: env.s(PostWorkoutSummaryStrings.duration))
            }
        }
    }

    private var setsCard: some View {
        BadanCard {
            StatBox(value: env.format.integer(summary.strengthSetCount),
                   label: env.s(PostWorkoutSummaryStrings.setsLogged), size: .compact)
        }
    }

    private var recordsCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(PostWorkoutSummaryStrings.newRecords))
                ForEach(summary.newPersonalRecords.indices, id: \.self) { index in
                    recordRow(summary.newPersonalRecords[index])
                }
            }
        }
    }

    private func recordRow(_ record: PersonalRecord) -> some View {
        let movementName = MovementCatalog.shared.definition(record.movementId)?.displayName.resolved(env.language)
            ?? record.movementId
        return HStack(spacing: BadanSpace.space3) {
            Image(systemName: "trophy")
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(movementName)
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Text("\(env.s(PostWorkoutSummaryStrings.newRecordLine)) · \(env.format.number(record.weightKg, fraction: 1)) \(env.s(PostWorkoutSummaryStrings.kg)) × \(env.format.integer(record.reps)) \(env.s(PostWorkoutSummaryStrings.reps))")
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
        }
    }

    private var qualityCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(PostWorkoutSummaryStrings.qualityNote))
                ForEach(DegradedBannerFormat.lines(for: summary.degradedConditions).indices, id: \.self) { index in
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(BadanColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(env.s(DegradedBannerFormat.lines(for: summary.degradedConditions)[index]))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
    }

    private var doneButton: some View {
        Button {
            returnToLog()
        } label: {
            Text(env.s(PostWorkoutSummaryStrings.done))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.onPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: BadanSpace.touchMin)
                .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
    }
}
