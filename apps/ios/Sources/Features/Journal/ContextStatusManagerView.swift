import SwiftUI
import Observation

// MARK: - View model

/// The declared-interval manager's state and writes (EPIC-29, plan §9.10).
///
/// A status is one fact whose end is simply not known yet, so closing it sets `end_at` on the SAME
/// row through `closeStatus` rather than appending a second one — the repository draws that
/// distinction deliberately, and this screen respects it instead of inventing an append.
@Observable
@MainActor
final class ContextStatusViewModel {
    private(set) var list = ContextStatusList(active: [], past: [])
    private(set) var loadFailed = false
    private(set) var saveFailed = false

    /// The row a "Remove" tap tombstoned, held for the undo window. Undo re-upserts the captured row
    /// verbatim — legitimate here (and not an I2 violation) because a status is a raw user
    /// assertion, not a derived value: putting back exactly what the user had declared is a
    /// correction of a mis-tap, not a rewrite of something BADAN computed.
    var pendingUndo: ContextStatus?

    private var tz: String { TimeZone.current.identifier }

    func load(_ env: AppEnvironment) {
        do {
            list = ContextStatusList.from(try env.journal.allStatuses(), now: env.now())
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// Declare a period starting now and running until the user closes it. Open-ended is the normal
    /// shape — "I'm travelling" is said at the start, not at the end.
    func start(kind: ContextStatusKind?, customLabel: String? = nil, env: AppEnvironment) {
        let now = env.now()
        let status = ContextStatus(
            id: ULID.newID(), statusId: kind?.rawValue, customLabel: customLabel,
            startAt: now, endAt: nil, tzId: tz, note: nil,
            provenance: Provenance(sourceId: env.deviceId, deviceId: env.deviceId, ingestionPath: .manual,
                                   measuredAt: now, measuredTimezone: tz, recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: env.deviceId)
        write(env) { try env.journal.upsertStatus(status) }
        Announce.status(env.s(JournalStrings.contextStartedAnnouncement
            .filling(["name": env.s(status.displayLabel)])))
    }

    func end(_ status: ContextStatus, env: AppEnvironment) {
        let now = env.now()
        write(env) { try env.journal.closeStatus(id: status.id, endAt: now, updatedAt: now) }
        Announce.status(env.s(JournalStrings.contextEndedAnnouncement
            .filling(["name": env.s(status.displayLabel)])))
    }

    func remove(_ status: ContextStatus, env: AppEnvironment) {
        write(env) { try env.journal.deleteStatus(id: status.id, at: env.now()) }
        pendingUndo = status
    }

    func undoRemove(_ env: AppEnvironment) {
        guard let status = pendingUndo else { return }
        pendingUndo = nil
        write(env) { try env.journal.upsertStatus(status) }
    }

    /// One write shape for all four mutations: run it, reload, and bump the data bus on success —
    /// an open status changes how every score screen annotates its confidence, so the rest of the
    /// app has to hear about it.
    private func write(_ env: AppEnvironment, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            saveFailed = true
            Announce.failure(env.s(JournalStrings.saveFailed))
            return
        }
        saveFailed = false
        env.bumpDataGeneration()
        load(env)
    }
}

// MARK: - Screen

/// EPIC-29 — the context-status manager: declare that a stretch of days wasn't ordinary, and close
/// it when it is over.
///
/// The explainer at the top is load-bearing, not decoration. A `ContextStatus` may cap how
/// confidently a value is read and add a caveat sentence, and it may do NOTHING else — the entity
/// exposes no metric id, no offset and no multiplier, precisely so "a status quietly changed my
/// number" cannot happen. A user who believes marking travel will "fix" their readiness score has
/// been misled by the surface, so the surface says it plainly.
///
/// **And the promise is kept, not merely stated.** The confidence half is applied by the score
/// engines through `ContextAnnotationResolver` (readiness, sleep need/performance/consistency and
/// the stress trend all cap their stored `confidence` at `ContextAnnotator.activeContextConfidenceCeiling`
/// for a day inside a declared interval; `effort.day` stores no confidence, so a context reaches it
/// as copy only — see `EffortEngine`). The copy half is rendered by `ContextCaveatNote` on the
/// readiness hero, the metric detail + anatomy sheet and the stress card, from the SAME
/// `ContextStatus.caveat` sentence each card previews below, so nothing here promises a behaviour
/// the user will not meet.
struct ContextStatusManagerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm = ContextStatusViewModel()
    @State private var customDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                explainer
                if vm.loadFailed { inlineWarning(JournalStrings.loadFailed) }
                if vm.saveFailed { inlineWarning(JournalStrings.saveFailed) }
                if !vm.list.active.isEmpty { activeSection }
                startSection
                if !vm.list.past.isEmpty { pastSection }
                if vm.list.isEmpty { emptyNote }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(JournalStrings.contextTitle))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { undoOverlay }
        .animation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion), value: vm.pendingUndo)
        .task(id: ContextStatusLoadKey(profile: env.profile, generation: env.dataGeneration)) {
            vm.load(env)
        }
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "info.circle")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(JournalStrings.contextExplainer, language: env.language)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Active

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(JournalStrings.contextOngoing, language: env.language)
            ForEach(vm.list.active) { status in
                BadanCard {
                    HStack(alignment: .top, spacing: BadanSpace.space3) {
                        statusIcon(status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.displayLabel, language: env.language)
                                .font(BadanFont.bodyCompact.weight(.medium))
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(startedText(status))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        Spacer(minLength: BadanSpace.space2)
                        Button(env.s(JournalStrings.contextEndNow)) { vm.end(status, env: env) }
                            .font(BadanFont.link)
                            .foregroundStyle(BadanColor.primary)
                            .frame(minHeight: BadanSpace.touchMin)
                    }
                }
            }
        }
    }

    // MARK: Start

    private var startSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(JournalStrings.contextStart, language: env.language)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: BadanSpace.space2)],
                      alignment: .leading, spacing: BadanSpace.space2) {
                ForEach(ContextStatusKind.allCases, id: \.self) { kind in
                    startChip(kind)
                }
            }
            if env.depth.showsPowerDetail { customStarter }
        }
    }

    private func startChip(_ kind: ContextStatusKind) -> some View {
        let alreadyActive = vm.list.active.contains { $0.kind == kind }
        return Button { vm.start(kind: kind, env: env) } label: {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: symbol(kind))
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(kind.displayLabel, language: env.language)
                    .font(BadanFont.chip)
                    .foregroundStyle(BadanColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BadanSpace.space3)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin, alignment: .leading)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        // A kind that is already running is not startable again — a second overlapping "travelling"
        // would annotate the same days twice for no added meaning.
        .disabled(alreadyActive)
        .opacity(alreadyActive ? 0.45 : 1)
    }

    /// Power depth may name a circumstance the taxonomy doesn't. It annotates identically (BADAN has
    /// no basis for treating one user-invented circumstance differently from another) and gets the
    /// generic caveat naming the user's own words.
    private var customStarter: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space2) {
                TextField(env.s(JournalStrings.contextCustomPlaceholder), text: $customDraft)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .submitLabel(.done)
                    .onSubmit(startCustom)
                Button(env.s(JournalStrings.contextStart), action: startCustom)
                    .font(BadanFont.link)
                    .foregroundStyle(BadanColor.primary)
                    .disabled(customDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    private func startCustom() {
        let label = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        vm.start(kind: nil, customLabel: label, env: env)
        customDraft = ""
    }

    // MARK: Past

    private var pastSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(JournalStrings.contextEarlier, language: env.language)
            VStack(spacing: 0) {
                ForEach(Array(vm.list.past.enumerated()), id: \.element.id) { index, status in
                    if index > 0 {
                        Rectangle().fill(BadanColor.separator).frame(height: 1)
                    }
                    BadanSwipeToDelete(deleteLabel: env.s(JournalStrings.contextDelete)) {
                        vm.remove(status, env: env)
                    } content: {
                        pastRow(status)
                    }
                }
            }
            .background(BadanColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
        }
    }

    private func pastRow(_ status: ContextStatus) -> some View {
        HStack(alignment: .top, spacing: BadanSpace.space3) {
            statusIcon(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayLabel, language: env.language)
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Text(rangeText(status))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
        }
        .padding(BadanSpace.space4)
        .frame(minHeight: BadanSpace.touchMin)
    }

    private var emptyNote: some View {
        EmptyStateView(
            icon: "calendar",
            title: env.s(JournalStrings.contextNoneTitle),
            message: env.s(JournalStrings.contextNoneMessage))
    }

    @ViewBuilder
    private var undoOverlay: some View {
        if vm.pendingUndo != nil {
            BadanUndoToast(message: env.s(JournalStrings.contextRemoved), undoLabel: env.s(Loc.undo)) {
                vm.undoRemove(env)
            }
        }
    }

    // MARK: Presentation helpers

    private func statusIcon(_ status: ContextStatus) -> some View {
        Image(systemName: status.kind.map(symbol) ?? "tag")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(BadanColor.primary)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }

    private func symbol(_ kind: ContextStatusKind) -> String {
        switch kind {
        case .travel: return "airplane"
        case .illness: return "thermometer.medium"
        case .fasting: return "moon"
        case .altitude: return "mountain.2"
        case .injury: return "bandage"
        }
    }

    private func startedText(_ status: ContextStatus) -> String {
        env.s(JournalStrings.contextStarted.filling(["date": ContextStatusDates.day(status.startAt, language: env.language)]))
    }

    private func rangeText(_ status: ContextStatus) -> String {
        let start = ContextStatusDates.day(status.startAt, language: env.language)
        guard let endAt = status.endAt else { return startedText(status) }
        return env.s(JournalStrings.contextRange.filling([
            "start": start,
            "end": ContextStatusDates.day(endAt, language: env.language),
        ]))
    }
}

private struct ContextStatusLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

/// Cached once per file rather than allocating a fresh `DateFormatter` per row; only the locale (a
/// cheap property set) changes between calls — the same approach `InsightsDateFormatting` uses.
enum ContextStatusDates {
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
