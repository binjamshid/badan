import SwiftUI

// ============================================================================
// MARK: - EPIC-39 (Phase 3F slice 2) — start/end a cycle + flow quick-log (Lane B).
// ============================================================================
//
// Sibling to `CycleHomeScreen.swift` (same lane, same owned-file pair) — read that file's own
// header first. Presented as a sheet from `CycleHomeScreen`'s quick actions; the three modes below
// (`start`/`end`/`logFlow`) are exactly the three actions that screen's brief names.
//
// Writes go through `CycleModuleServices` exactly as that composition layer declares it
// (`cycleRecords.insertRecord`, `flowLogs.insert`, `refreshAll(asOf:)`) — this file constructs no
// repository of its own and never opens a database connection directly (I7).
//
// `CycleRecord`'s own append-first revision-chain contract (`Domain/Cycle/CycleModels.swift`) is
// followed exactly: starting a cycle INSERTs a fresh original row (`revision == 1`, `supersedes ==
// nil`); ending one INSERTs a NEW revision (fresh id, same `originalId`, `supersedes` = the live
// row's own id, `revision + 1`) — never an UPDATE of the row already on file, since
// `CycleRecordRepository` exposes no update method at all, only `insertRecord`.
//
// Backdating is supported everywhere a date is picked (`DatePicker(in:)` only ever bounds the upper
// edge at "now" and, for ending a cycle, the lower edge at that cycle's own start — never a fixed
// "today only" default), per the research doc's "permit backdating everywhere" recommendation.
//
// After every successful write: `services.refreshAll(asOf:)` (produces the fresh prediction/phase-
// estimate/anomaly rows this action should trigger — see that method's own doc, which scopes its
// trigger to exactly "a period/flow/contraceptive-context change", i.e. every write this file makes)
// then `env.bumpDataGeneration()` (mirrors `ContraceptiveContextScreen.save()`'s own exact sequence
// for the same reason: `CycleHomeScreen`'s `.task(id:)` watches `env.dataGeneration` and reloads
// automatically the moment this sheet's write lands, even before it dismisses).
//
// Never renders `CycleFlowIntensity`'s raw `rawValue` — see the `displayName` extension below,
// added HERE (a Features-layer extension on a Domain enum, not a change to the audited
// `CycleModels.swift` core) following `LabSensitivityTier`'s own fix
// (`Domain/Labs/LabModels.swift`) as the exact template, the same pattern
// `ContraceptiveContextScreen.swift`'s sibling `ContraceptiveMethodType.displayName` extension and
// `CycleHistoryScreen.swift`'s sibling `CyclePhase.displayName` extension already use elsewhere in
// this same slice.

// MARK: - CycleFlowIntensity display name (never the raw rawValue rendered to a user)

extension CycleFlowIntensity {
    var displayName: LocalizedString {
        switch self {
        case .spotting: return LocalizedString(en: "Spotting", ar: "نقاط خفيفة")
        case .light: return LocalizedString(en: "Light", ar: "خفيف")
        case .medium: return LocalizedString(en: "Medium", ar: "متوسط")
        case .heavy: return LocalizedString(en: "Heavy", ar: "غزير")
        }
    }
}

/// The write-time mapping from a tapped dictionary label to `FlowLog.normalizedIntensity`'s 0...1
/// scale (`CycleModels.swift`'s own doc: "a SEPARATE, additional 0...1 scale mapped from
/// originalLabel at write time" — this lane's UI is exactly where that mapping happens, since the
/// domain layer intentionally does not fix these values itself). Monotonically increasing with the
/// dictionary's own casual ordering (spotting < light < medium < heavy), which is what the anomaly
/// engine's flow-deviation check implicitly relies on this scale meaning.
enum CycleFlowNormalization {
    static func normalizedIntensity(for intensity: CycleFlowIntensity) -> Double {
        switch intensity {
        case .spotting: return 0.1
        case .light: return 0.35
        case .medium: return 0.65
        case .heavy: return 0.9
        }
    }
}

// MARK: - Screen-local strings ("cycle", never "period" — see file header)

enum PeriodLogStrings {
    static let startTitle = LocalizedString(en: "Start cycle", ar: "بدء الدورة")
    static let endTitle = LocalizedString(en: "End cycle", ar: "إنهاء الدورة")
    static let logFlowTitle = LocalizedString(en: "Log flow", ar: "تسجيل التدفق")
    static let startDateLabel = LocalizedString(en: "Start date", ar: "تاريخ البدء")
    static let endDateLabel = LocalizedString(en: "End date", ar: "تاريخ الانتهاء")
    static let flowDateLabel = LocalizedString(en: "When", ar: "الوقت")
    static let flowIntensityLabel = LocalizedString(en: "Flow", ar: "التدفق")
    static let saveFailed = LocalizedString(
        en: "Couldn't save that right now — try again.", ar: "تعذّر الحفظ الآن — حاول مرة أخرى.")
    static let savedAnnouncement = LocalizedString(en: "Saved", ar: "تم الحفظ")
}

// MARK: - Screen

/// Start a cycle (optionally backdated), end an ongoing one, or quick-log a flow moment against a
/// cycle — one screen, three modes, per this lane's brief. Presented as a sheet; a bare Save after
/// opening is the entire repeat-case interaction for start/end (2 taps total from `CycleHomeScreen`'s
/// own quick action), well inside the ≤3-interaction budget.
struct PeriodLogScreen: View {
    enum Mode: Identifiable, Equatable {
        case start
        case end(CycleRecord)
        case logFlow(cycle: CycleRecord)

        var id: String {
            switch self {
            case .start: return "start"
            case .end(let record): return "end:\(record.id)"
            case .logFlow(let cycle): return "logFlow:\(cycle.id)"
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let services: CycleModuleServices
    let mode: Mode

    @State private var pickedDate = Date()
    @State private var selectedIntensity: CycleFlowIntensity = .medium
    @State private var saveFailed = false
    @State private var didPrime = false

    private var maxDate: Date { env.now() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    switch mode {
                    case .start:
                        dateRow(label: PeriodLogStrings.startDateLabel) {
                            DatePicker("", selection: $pickedDate, in: ...maxDate, displayedComponents: [.date])
                                .labelsHidden()
                        }
                    case .end(let record):
                        dateRow(label: PeriodLogStrings.endDateLabel) {
                            DatePicker("", selection: $pickedDate, in: record.startAt...maxDate,
                                      displayedComponents: [.date])
                                .labelsHidden()
                        }
                    case .logFlow(let cycle):
                        dateRow(label: PeriodLogStrings.flowDateLabel) {
                            DatePicker("", selection: $pickedDate, in: cycle.startAt...maxDate,
                                      displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                        }
                        flowIntensityCard
                    }
                    if saveFailed {
                        notice(env.s(PeriodLogStrings.saveFailed))
                    }
                }
                .padding(BadanSpace.space4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(titleForMode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(env.s(Loc.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.save)) { save() }
                }
            }
            .task { primeIfNeeded() }
        }
        .presentationDetents([.medium])
    }

    // MARK: Cards

    private func dateRow<Picker: View>(
        label: LocalizedString, @ViewBuilder picker: @escaping () -> Picker
    ) -> some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "calendar")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(label))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                picker()
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    private var flowIntensityCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                Text(env.s(PeriodLogStrings.flowIntensityLabel))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                HStack(spacing: BadanSpace.space2) {
                    ForEach(CycleFlowIntensity.allCases, id: \.self) { intensity in
                        intensityChip(intensity)
                    }
                }
            }
        }
    }

    private func intensityChip(_ intensity: CycleFlowIntensity) -> some View {
        let selected = intensity == selectedIntensity
        return Button {
            selectedIntensity = intensity
        } label: {
            Text(env.s(intensity.displayName))
                .font(BadanFont.chip)
                .lineLimit(1)
                .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary)
                .padding(.horizontal, BadanSpace.space3)
                .frame(minHeight: BadanSpace.touchMin)
                .background(
                    (selected ? BadanColor.primary : BadanColor.surface),
                    in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                        .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func notice(_ message: String) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            Text(message)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
        }
    }

    // MARK: Priming

    private var titleForMode: LocalizedString {
        switch mode {
        case .start: return PeriodLogStrings.startTitle
        case .end: return PeriodLogStrings.endTitle
        case .logFlow: return PeriodLogStrings.logFlowTitle
        }
    }

    /// Defaults every mode's date field to "now", clamped forward to each mode's own lower bound
    /// (a cycle/flow moment can never be logged before the cycle it belongs to started) so a rare
    /// clock-skew edge case never leaves the picker's bound selection outside its own valid range.
    private func primeIfNeeded() {
        guard !didPrime else { return }
        didPrime = true
        switch mode {
        case .start:
            pickedDate = env.now()
        case .end(let record):
            pickedDate = max(record.startAt, env.now())
        case .logFlow(let cycle):
            pickedDate = max(cycle.startAt, env.now())
        }
    }

    // MARK: Save

    private func save() {
        do {
            switch mode {
            case .start:
                try startCycle(at: pickedDate)
            case .end(let record):
                try endCycle(record, endAt: pickedDate)
            case .logFlow(let cycle):
                try logFlow(cycle: cycle, occurredAt: pickedDate, intensity: selectedIntensity)
            }
            try services.refreshAll(asOf: env.now())
            env.bumpDataGeneration()
            Announce.status(env.s(PeriodLogStrings.savedAnnouncement))
            dismiss()
        } catch {
            saveFailed = true
            Announce.failure(env.s(PeriodLogStrings.saveFailed))
        }
    }

    /// A fresh ORIGINAL `CycleRecord` (`revision == 1`, `supersedes == nil`, `originalId == id`) —
    /// still `ongoing`, no `endAt` yet, per that struct's own "never ambiguously ended-we-don't-know-
    /// when vs. still-happening" contract.
    private func startCycle(at startAt: Date) throws {
        let id = ULID.newID()
        let now = env.now()
        let record = CycleRecord(
            id: id, startAt: startAt, endAt: nil, ongoing: true, note: nil,
            originalId: id, supersedes: nil, revision: 1,
            provenance: manualProvenance(measuredAt: startAt, at: now),
            updatedAt: now, originDeviceId: services.deviceId)
        try services.cycleRecords.insertRecord(record)
    }

    /// A NEW revision superseding the live row — never an UPDATE (`CycleRecordRepository` exposes no
    /// update method; a revision is the only way this table's own row content ever changes). Keeps
    /// the original's own `measuredTimezone` so the day-arithmetic every downstream engine performs
    /// against this record's `startAt` never silently shifts a day boundary across the revision.
    private func endCycle(_ record: CycleRecord, endAt: Date) throws {
        let now = env.now()
        let revised = CycleRecord(
            id: ULID.newID(), startAt: record.startAt, endAt: endAt, ongoing: false, note: record.note,
            originalId: record.originalId, supersedes: record.id, revision: record.revision + 1,
            provenance: manualProvenance(measuredAt: record.startAt, at: now,
                                         tz: record.provenance.measuredTimezone),
            updatedAt: now, originDeviceId: services.deviceId)
        try services.cycleRecords.insertRecord(revised)
    }

    /// `originalLabel` stores the dictionary key exactly as this quick-log UI's own closed set names
    /// it (`CycleFlowIntensity.rawValue`, e.g. "light") — never the localized display word — matching
    /// `FlowLog.originalLabel`'s own doc example ("light"/"medium"/custom free text) and preserving
    /// the source wording even if a future revision to the dictionary's display copy changes.
    private func logFlow(cycle: CycleRecord, occurredAt: Date, intensity: CycleFlowIntensity) throws {
        let now = env.now()
        let log = FlowLog(
            id: ULID.newID(), cycleId: cycle.id, occurredAt: occurredAt,
            originalLabel: intensity.rawValue,
            normalizedIntensity: CycleFlowNormalization.normalizedIntensity(for: intensity),
            note: nil, provenance: manualProvenance(measuredAt: occurredAt, at: now),
            updatedAt: now, originDeviceId: services.deviceId)
        try services.flowLogs.insert(log)
    }

    /// Mirrors `HydrationViewModel.manualProvenance`/`ContraceptiveContextScreen.save()`'s own exact
    /// shape for a manually-entered fact.
    private func manualProvenance(measuredAt: Date, at now: Date, tz: String = TimeZone.current.identifier) -> Provenance {
        Provenance(sourceId: services.deviceId, deviceId: services.deviceId, ingestionPath: .manual,
                  measuredAt: measuredAt, measuredTimezone: tz, recordedAt: now, ingestedAt: now)
    }
}
