import Foundation

/// Gathers the recent past from every store into a single, chronological `[TimelineEvent]` —
/// BADAN's anti-fragmentation spine. Sleep and workouts come from measurement sessions;
/// symptoms, medications, meals and notes from the logging repository; body weight from raw
/// samples. Every row carries its own provenance (ingestion path) so the Timeline can show
/// "where this came from" without a join. Sensitive rows (meds/symptoms) are gated behind the
/// same module switches that govern the sensitive database.
@MainActor
struct TimelineAssembler {
    let env: AppEnvironment

    /// How far back the unified spine reaches.
    static let windowDays = 21

    /// Assemble every event in the window, sorted newest-first.
    func assemble() throws -> [TimelineEvent] {
        let now = env.now()
        let from = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let to = now
        var events: [TimelineEvent] = []

        // Sleep + workout episodes (auto-ingested; provenance-locked).
        for session in try env.measurements.sessions(kind: .sleepPrimary, from: from, to: to) {
            events.append(sleepEvent(session))
        }
        for session in try env.measurements.sessions(kind: .workout, from: from, to: to) {
            events.append(workoutEvent(session))
        }

        // Meds + symptoms live in the sensitive store — only read when that module is on.
        if env.profile.sensitiveModulesEnabled {
            for symptom in try env.logging.symptoms(from: from, to: to) {
                events.append(symptomEvent(symptom))
            }
            let regimens = try env.logging.regimens()
            let regimenById = Dictionary(regimens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for adherence in try env.logging.adherence(from: from, to: to) {
                events.append(medicationEvent(adherence, regimen: regimenById[adherence.regimenId]))
            }
        }

        // Meals are gated behind the nutrition module.
        if env.profile.nutritionEnabled {
            for meal in try env.logging.nutrition(from: from, to: to) {
                events.append(mealEvent(meal))
            }
        }

        // Notes (normal sensitivity).
        for note in try env.logging.notes(from: from, to: to) {
            events.append(noteEvent(note))
        }

        // Body weight measurements.
        for sample in try env.measurements.rawSamples(metricId: MetricID.weight, from: from, to: to) {
            events.append(weightEvent(sample))
        }

        return events.sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: - Event builders

    private func sleepEvent(_ s: Session) -> TimelineEvent {
        let asleep = s.detail.timeAsleepSeconds ?? s.durationSeconds
        // Sleep is attributed to the morning it ends (the "last night" anchor).
        return TimelineEvent(
            id: "sleep:\(s.id)", type: .sleep, occurredAt: s.endAt, tzId: s.tzId,
            title: TimelineEventType.sleep.displayName,
            valueText: env.format.duration(seconds: asleep),
            sourceRecordId: s.id, ingestionPath: s.provenance.ingestionPath,
            sensitive: false, deletable: false)
    }

    private func workoutEvent(_ s: Session) -> TimelineEvent {
        let activity = s.subtype.map { LocalizedString(en: $0, ar: $0) }
        return TimelineEvent(
            id: "workout:\(s.id)", type: .workout, occurredAt: s.startAt, tzId: s.tzId,
            title: TimelineEventType.workout.displayName, subtitle: activity,
            valueText: env.format.duration(seconds: s.durationSeconds),
            sourceRecordId: s.id, ingestionPath: s.provenance.ingestionPath,
            sensitive: false, deletable: false)
    }

    private func symptomEvent(_ s: SymptomEntry) -> TimelineEvent {
        TimelineEvent(
            id: "symptom:\(s.id)", type: .symptom, occurredAt: s.occurredAt, tzId: s.tzId,
            title: env.symptoms.displayName(forId: s.symptomId, customLabel: s.customLabel),
            valueText: severityLabel(s.severity).map(env.s),
            sourceRecordId: s.id, ingestionPath: .manual,
            sensitive: true, deletable: false)
    }

    private func medicationEvent(_ a: AdherenceEvent, regimen: MedicationRegimen?) -> TimelineEvent {
        let title = regimen.map { LocalizedString(en: $0.name, ar: $0.name) } ?? Loc.logMedication
        let strength = regimen?.strength.map { LocalizedString(en: $0, ar: $0) }
        return TimelineEvent(
            id: "medication:\(a.id)", type: .medication, occurredAt: a.occurredAt, tzId: a.tzId,
            title: title, subtitle: strength, valueText: env.s(kindLabel(a.kind)),
            sourceRecordId: a.id, ingestionPath: .manual,
            sensitive: true, deletable: true)
    }

    private func mealEvent(_ m: NutritionEntry) -> TimelineEvent {
        TimelineEvent(
            id: "meal:\(m.id)", type: .meal, occurredAt: m.occurredAt, tzId: m.tzId,
            title: LocalizedString(en: m.description, ar: m.description),
            subtitle: m.mealType.displayName,
            valueText: m.energyKcal.map(caloriesText),
            sourceRecordId: m.id, ingestionPath: .manual,
            sensitive: false, deletable: true)
    }

    private func noteEvent(_ n: NoteEntry) -> TimelineEvent {
        TimelineEvent(
            id: "note:\(n.id)", type: .note, occurredAt: n.occurredAt, tzId: n.tzId,
            title: LocalizedString(en: n.text, ar: n.text),
            sourceRecordId: n.id, ingestionPath: .manual,
            sensitive: false, deletable: true)
    }

    private func weightEvent(_ sample: RawSample) -> TimelineEvent {
        let def = env.registry.definitionOrFallback(MetricID.weight)
        return TimelineEvent(
            id: "weight:\(sample.id)", type: .measurement, occurredAt: sample.startAt, tzId: sample.tzId,
            title: def.displayName,
            valueText: env.format.full(metricId: MetricID.weight, canonicalValue: sample.value),
            sourceRecordId: sample.id, ingestionPath: sample.provenance.ingestionPath,
            sensitive: false, deletable: false)
    }

    // MARK: - Localized value helpers

    private func severityLabel(_ severity: Int) -> LocalizedString? {
        switch severity {
        case ..<1: return nil
        case 1...3: return Loc.mild
        case 4...6: return Loc.moderate
        default: return Loc.severe
        }
    }

    private func kindLabel(_ kind: AdherenceKind) -> LocalizedString {
        switch kind {
        case .taken: return Loc.taken
        case .skipped: return Loc.skipped
        case .late: return LocalizedString(en: "Taken late", ar: "تم تناوله متأخراً")
        }
    }

    private func caloriesText(_ kcal: Double) -> String {
        let unit = env.language == .ar ? "سعرة" : "kcal"
        return "\(env.format.integer(Int(kcal.rounded()))) \(unit)"
    }
}
