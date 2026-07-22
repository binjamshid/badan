import SwiftUI

// ============================================================================
// MARK: - CYCLE-07: contraceptive-context logging (Phase 3F slice 2)
// ============================================================================
//
// Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §4/§9/§12 and
// `docs/legal/reproductive-threat-model.md` §5's CYCLE-07 mitigation: awareness of an active
// contraceptive method is what lets `CyclePredictionEngine` PAUSE or BROADEN a forecast instead of
// confidently predicting through a context where a calendar-only model's normal assumptions don't
// hold. This screen's ONLY job is to keep `ContraceptiveContextLog` current — it makes no efficacy
// or adherence claim of its own (research doc §4: "the interface must avoid advising on adherence
// or efficacy beyond neutral record-keeping"), and it never surfaces the prediction/phase-estimate/
// anomaly rows this logging feeds — those are a different screen's job.
//
// Domain types (`ContraceptiveContextLog`, `ContraceptiveMethodType`) and the sensitive-only
// `ContraceptiveContextRepository` are already committed (commit c8fa895) — read both before
// touching this file. Every write here goes through that repository against
// `CycleModuleServices.contraceptiveContext`, never a repository constructed against
// `env.database.main` (I7).
//
// ONE editable "current method" slot, mirroring the repository's own documented posture ("a
// context legitimately CHANGES in place... this is one fact whose end was simply not known yet"):
// there is no separate create-flow and edit-flow, just one form that is either pre-filled from the
// live active row (editing) or blank (creating). Saving with "still using this method" off ends
// the row in place (same id, `endAt` populated); saving again afterward with the form reset starts
// a fresh row. This keeps the "zero or one active context" shape the repository itself declines to
// enforce (see its own doc) true by construction of the UI, without adding a second, redundant
// invariant check.
//
// Past (ended) entries are shown read-only. There is no delete here: `ContraceptiveContextRepository`
// exposes no tombstone method for this table (unlike `CycleRecordRepository.deleteChain`) — a
// declared method interval is corrected by re-saving over it, not removed.

// MARK: - Bilingual display name for ContraceptiveMethodType (mirrors `LabSensitivityTier
// .displayName`'s exact fix — never a raw `rawValue` rendered to the user). `ContraceptiveMethodType`
// itself is domain core (`Domain/Cycle/CycleModels.swift`, already committed); this extension adds
// only presentation, the same way a Feature-layer file is free to extend a Domain enum with UI-only
// vocabulary elsewhere in this codebase.
extension ContraceptiveMethodType {
    var displayName: LocalizedString {
        switch self {
        case .pill: return LocalizedString(en: "Pill", ar: "حبوب منع الحمل")
        case .iud: return LocalizedString(en: "IUD", ar: "لولب رحمي")
        case .patch: return LocalizedString(en: "Patch", ar: "لاصقة")
        case .ring: return LocalizedString(en: "Ring", ar: "حلقة مهبلية")
        case .injection: return LocalizedString(en: "Injection", ar: "حقنة")
        case .implant: return LocalizedString(en: "Implant", ar: "غرسة")
        case .emergencyContraception: return LocalizedString(en: "Emergency contraception", ar: "منع حمل طارئ")
        case .hormoneTherapy: return LocalizedString(en: "Hormone therapy", ar: "علاج هرموني")
        }
    }
}

// MARK: - Screen-local strings

/// Neutral record-keeping tone throughout, per research doc §4 — no efficacy claim, no adherence
/// nagging, no diagnostic language. "Cycle" (never "period") per the threat model's neutral-
/// language-default (§5), matching `MetricFamily.cycle`'s own framing.
enum ContraceptiveContextStrings {
    static let title = LocalizedString(en: "Contraceptive method", ar: "وسيلة منع الحمل")
    static let subtitle = LocalizedString(
        en: "A record of your contraceptive method, kept for your own reference. This lets BADAN "
            + "pause or widen its cycle estimates while a method might affect your usual pattern, "
            + "instead of guessing through it. BADAN doesn't track adherence or effectiveness.",
        ar: "سجلّ لوسيلة منع الحمل التي تستخدمينها، لمرجعك الشخصي فقط. يتيح هذا لتطبيق بدن إيقاف "
            + "تقديرات الدورة مؤقتاً أو توسيعها أثناء استخدام وسيلة قد تؤثر في نمطك المعتاد، بدلاً "
            + "من التخمين. لا يتتبع بدن مدى الالتزام بالوسيلة أو فعاليتها.")
    static let detailsSectionTitle = LocalizedString(en: "Details", ar: "التفاصيل")
    static let currentlyLogged = LocalizedString(en: "Currently logged", ar: "مسجَّلة حالياً")
    static let noCurrentMethod = LocalizedString(
        en: "No method currently logged. Fill in the details below to add one.",
        ar: "لا توجد وسيلة مسجّلة حالياً. أدخل التفاصيل أدناه لإضافة واحدة.")
    static let methodLabel = LocalizedString(en: "Method", ar: "الوسيلة")
    static let startedLabel = LocalizedString(en: "Started", ar: "تاريخ البدء")
    static let stillActiveToggle = LocalizedString(en: "Still using this method", ar: "ما زلت أستخدم هذه الوسيلة")
    static let endedOnLabel = LocalizedString(en: "Ended on", ar: "تاريخ الانتهاء")
    static let noteLabel = LocalizedString(en: "Note (optional)", ar: "ملاحظة (اختياري)")
    static let notePlaceholder = LocalizedString(en: "Add a note", ar: "أضف ملاحظة")
    static let saveAction = LocalizedString(en: "Save", ar: "حفظ")
    static let historySectionTitle = LocalizedString(en: "Earlier methods", ar: "وسائل سابقة")
    static let dateRange = LocalizedString(en: "{start} – {end}", ar: "{start} – {end}")
    static let savedAnnouncement = LocalizedString(en: "Saved", ar: "تم الحفظ")
    static let saveFailed = LocalizedString(
        en: "Couldn't save this right now. Try again.", ar: "تعذّر الحفظ الآن. حاول مرة أخرى.")
    static let loadFailed = LocalizedString(en: "Couldn't load this right now.", ar: "تعذّر التحميل الآن.")
}

// MARK: - Loaded data

private struct ContraceptiveContextData {
    var past: [ContraceptiveContextLog]
}

// MARK: - Date formatting (mirrors `ContextStatusDates` in `ContextStatusManagerView.swift` exactly
// — one cached, per-language `DateFormatter` rather than allocating fresh on every row)

private enum ContraceptiveContextDates {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func day(_ date: Date, language: AppLanguage) -> String {
        formatter.locale = Locale(identifier: language.localeIdentifier)
        return formatter.string(from: date)
    }
}

// MARK: - Screen

/// Log or edit the user's current `ContraceptiveContextLog` (CYCLE-07). Takes `CycleModuleServices`
/// exactly like every other Cycle-module screen (per this slice's shared cross-lane contract) —
/// constructed once per top-level screen instance by the caller, never by this screen itself.
struct ContraceptiveContextScreen: View {
    @Environment(AppEnvironment.self) private var env
    let services: CycleModuleServices

    @State private var state: LoadState<ContraceptiveContextData> = .loading
    /// `nil` while the form represents a NEW row to be created; non-nil while it represents the
    /// live active row being edited in place (same id re-saved on `save()`).
    @State private var editingId: String?
    @State private var methodType: ContraceptiveMethodType = .pill
    @State private var startAt = Date()
    @State private var isActive = true
    @State private var endAt = Date()
    @State private var note = ""
    /// Upper bound for both date pickers — set from `env.now()` at load, matching
    /// `SymptomLogView`'s own `maxDate` pattern, so neither field can be back-dated into the future.
    @State private var maxDate = Date()
    @State private var saveFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                Text(env.s(ContraceptiveContextStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if saveFailed {
                    inlineWarning(ContraceptiveContextStrings.saveFailed)
                }

                StatefulContainer(state, emptyIcon: "calendar") { data in
                    VStack(alignment: .leading, spacing: BadanSpace.space5) {
                        formSection
                        if !data.past.isEmpty { historySection(data) }
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(ContraceptiveContextStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    // MARK: Form (create-or-edit the one current row)

    private var formSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ContraceptiveContextStrings.detailsSectionTitle))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    if editingId != nil {
                        PillLabel(env.s(ContraceptiveContextStrings.currentlyLogged), systemImage: "checkmark.circle",
                                  tint: BadanColor.inBand, filled: false)
                    } else {
                        Text(env.s(ContraceptiveContextStrings.noCurrentMethod))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker(env.s(ContraceptiveContextStrings.methodLabel), selection: $methodType) {
                        ForEach(ContraceptiveMethodType.allCases, id: \.self) { method in
                            Text(env.s(method.displayName)).tag(method)
                        }
                    }

                    DatePicker(env.s(ContraceptiveContextStrings.startedLabel), selection: $startAt,
                               in: ...maxDate, displayedComponents: .date)

                    Toggle(env.s(ContraceptiveContextStrings.stillActiveToggle), isOn: $isActive)

                    if !isActive {
                        DatePicker(env.s(ContraceptiveContextStrings.endedOnLabel), selection: $endAt,
                                   in: startAt...maxDate, displayedComponents: .date)
                    }

                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        Text(env.s(ContraceptiveContextStrings.noteLabel))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        TextField(env.s(ContraceptiveContextStrings.notePlaceholder), text: $note, axis: .vertical)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                            .padding(BadanSpace.space2)
                            .background(BadanColor.surfaceElevated,
                                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    }

                    Button(action: save) {
                        Text(env.s(ContraceptiveContextStrings.saveAction))
                            .font(BadanFont.body.weight(.semibold))
                            .foregroundStyle(BadanColor.onPrimary)
                            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                            .background(BadanColor.primary,
                                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    }
                }
            }
        }
    }

    private func inlineWarning(_ text: LocalizedString) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.outOfBandOnTint)
                .accessibilityHidden(true)
            Text(text, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: History (read-only — see file header for why there is no delete action here)

    private func historySection(_ data: ContraceptiveContextData) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(ContraceptiveContextStrings.historySectionTitle))
            VStack(spacing: 0) {
                ForEach(Array(data.past.enumerated()), id: \.element.id) { index, context in
                    if index > 0 {
                        Rectangle().fill(BadanColor.separator).frame(height: 1)
                    }
                    historyRow(context)
                }
            }
            .background(BadanColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
        }
    }

    private func historyRow(_ context: ContraceptiveContextLog) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(env.s(context.methodType.displayName))
                .font(BadanFont.bodyCompact.weight(.medium))
                .foregroundStyle(BadanColor.textPrimary)
            Text(rangeText(context))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            if let note = context.adherenceNote, !note.isEmpty {
                Text(note)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BadanSpace.space4)
        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin, alignment: .leading)
    }

    private func rangeText(_ context: ContraceptiveContextLog) -> String {
        let start = ContraceptiveContextDates.day(context.startAt, language: env.language)
        guard let endAt = context.endAt else { return start }
        return env.s(ContraceptiveContextStrings.dateRange.filling([
            "start": start, "end": ContraceptiveContextDates.day(endAt, language: env.language),
        ]))
    }

    // MARK: Load / save

    private func load() {
        maxDate = env.now()
        do {
            let all = try services.contraceptiveContext.liveContexts()
            let active = all.first { $0.isActive }
            let past = all.filter { !$0.isActive }
            populateForm(active)
            state = .loaded(ContraceptiveContextData(past: past))
        } catch {
            state = .error(env.s(ContraceptiveContextStrings.loadFailed))
        }
    }

    /// `nil` resets the form to blank defaults for logging a fresh method (the state right after
    /// the previously-active row was just ended). A non-nil row pre-fills the form for in-place
    /// editing — see the file header for why there is only ever one editable slot.
    private func populateForm(_ active: ContraceptiveContextLog?) {
        let now = env.now()
        guard let active else {
            editingId = nil
            methodType = .pill
            startAt = now
            isActive = true
            endAt = now
            note = ""
            return
        }
        editingId = active.id
        methodType = active.methodType
        startAt = active.startAt
        isActive = true // filtered to `isActive == true` above by construction.
        endAt = now
        note = active.adherenceNote ?? ""
    }

    /// Re-inserts `editingId` (same id — a genuine in-place edit/close, per the repository's own
    /// doc) when one is set, or a fresh id otherwise. Always calls `CycleModuleServices.refreshAll`
    /// afterward: a contraceptive-context change is one of the explicit triggers that method
    /// documents, since it can flip whether `CyclePredictionEngine` pauses its forecast.
    private func save() {
        let now = env.now()
        let tz = TimeZone.current.identifier
        let id = editingId ?? ULID.newID()
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive clamp: `endAt`'s own DatePicker is range-bound to `startAt...maxDate`, but a
        // rapid `startAt` edit right before tapping Save could otherwise leave a stale, out-of-range
        // `endAt` in state.
        let clampedEnd = max(startAt, min(endAt, now))
        let context = ContraceptiveContextLog(
            id: id,
            methodType: methodType,
            startAt: startAt,
            endAt: isActive ? nil : clampedEnd,
            adherenceNote: trimmedNote.isEmpty ? nil : trimmedNote,
            provenance: Provenance(sourceId: services.deviceId, deviceId: services.deviceId, ingestionPath: .manual,
                                   measuredAt: now, measuredTimezone: tz, recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: services.deviceId)
        do {
            try services.contraceptiveContext.insert(context)
            try services.refreshAll(asOf: now)
            saveFailed = false
            env.bumpDataGeneration()
            Announce.status(env.s(ContraceptiveContextStrings.savedAnnouncement))
            load()
        } catch {
            saveFailed = true
            Announce.failure(env.s(ContraceptiveContextStrings.saveFailed))
        }
    }
}
