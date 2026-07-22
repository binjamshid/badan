import Foundation
import WidgetKit
import os

/// EPIC-33 (Phase 3D) — assembles an `AmbientSnapshotDto` from the live repositories and writes it
/// to the shared app-group container via `AmbientSnapshotStore`, then asks WidgetKit to reload
/// every widget kind this wave ships. This is the one place the four widgets' data is computed on
/// the main-app side; the extension itself computes nothing (blueprint §24.1, "the snapshot
/// pattern" — see `AmbientSnapshotDto`'s header).
///
/// Debounced: `writeIfNeeded` is a no-op if the last successful write was under
/// `minWriteInterval` (30s, per the plan) ago — cheap insurance against a burst of derivation runs
/// (e.g. a foreground sync immediately followed by a user-triggered reset) writing the file, and
/// reloading every widget's timeline, several times a second. The debounce state (`lastWriteAt`) is
/// per-instance, and the composition root holds exactly one instance for the app's lifetime, so
/// the guard is meaningful across every call site that triggers a write.
///
/// `actor`, not `final class` (fix pass, Phase 3D audit): `writeIfNeeded`'s check-then-act on
/// `lastWriteAt` is invoked from 25+ independent `Task`/`Task.detached` call sites across the app
/// with no serialization between them — two calls landing within the debounce window could both
/// pass the `lastWriteAt` check before either updated it, both perform a full build+write+widget-
/// reload, and both plainly race on `lastWriteAt` itself. Actor isolation makes every call to
/// `writeIfNeeded`/`forceWrite` genuinely queue on this instance rather than race, which is what
/// the doc above ("the guard is meaningful across every call site") was already assuming but
/// nothing previously enforced. External callers now `await` both methods; calls made from
/// *within* this actor (e.g. `forceWrite` calling `writeIfNeeded`) stay plain synchronous calls,
/// since they share the same isolation domain.
actor AmbientSnapshotWriter {
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let logging: LoggingRepository
    private let insights: InsightRepository
    private let store: AmbientSnapshotStore
    private let clock: Clock

    /// The four widget kinds this wave ships. Must match the `kind:` strings the `BadanWidgets`
    /// bundle registers its widgets under — that target is a separate lane this one cannot
    /// coordinate live with (see the task brief), so these are exactly the identifiers named in
    /// the EPIC-33 wave-1 scope. If the widget lane ever renames one,
    /// `WidgetCenter.reloadTimelines(ofKind:)` for the stale name is a silent no-op (WidgetKit
    /// does not error on an unknown kind) — the failure mode is a widget that stops refreshing
    /// until the next cold launch, never a crash.
    static let widgetKinds = ["ring_single", "one_true_sentence", "meds_due", "sleep_last_night"]

    /// Never write (or reload widget timelines) more than once inside this window — the plan's
    /// 30s figure. A plain "don't write more than once per 30s" guard, not a scheduler: nothing
    /// here queues a deferred write for later, it simply skips this call.
    static let minWriteInterval: TimeInterval = 30

    private var lastWriteAt: Date?

    /// Test seam: production always reloads the real WidgetKit runtime; a test injects a
    /// counting/no-op closure instead, since a plain unit-test target has no hosted widget to
    /// observe reloading anyway. Defaults to the real thing so every production call site gets it
    /// for free.
    private let reloadWidgets: ([String]) -> Void

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         logging: LoggingRepository, insights: InsightRepository, store: AmbientSnapshotStore,
         clock: Clock, reloadWidgets: @escaping ([String]) -> Void = AmbientSnapshotWriter.reloadRealWidgets) {
        self.derivation = derivation
        self.measurements = measurements
        self.logging = logging
        self.insights = insights
        self.store = store
        self.clock = clock
        self.reloadWidgets = reloadWidgets
    }

    // MARK: - Debounced write (the production entry point)

    /// Assemble the current snapshot and write it if the debounce window allows, then reload every
    /// widget kind's timeline on a successful write. Returns `true` only when a write actually
    /// landed (debounced-away and failed-to-write calls both return `false`), which doubles as the
    /// "write counter" a caller (or a test) can use to confirm the debounce actually collapsed a
    /// burst of calls into one write.
    ///
    /// Never throws: a build/write failure is logged and swallowed here, mirroring this
    /// codebase's convention for best-effort background work whose failure should not crash or
    /// propagate to a caller with no good way to act on it (e.g. `Database.
    /// performBackgroundMaintenance`) — a widget staying stale one refresh cycle is the honest,
    /// visible, self-correcting failure mode; a crashed derivation pipeline is not. Callers that
    /// need the thrown detail (tests, primarily) should call `buildSnapshot` directly instead.
    @discardableResult
    func writeIfNeeded(now: Date, tz: String, language: AppLanguage, medsDueConsentGranted: Bool) async -> Bool {
        if let last = lastWriteAt, now.timeIntervalSince(last) < Self.minWriteInterval { return false }
        do {
            let dto = try buildSnapshot(now: now, tz: tz, language: language,
                                        medsDueConsentGranted: medsDueConsentGranted)
            try store.write(dto)
        } catch {
            Log.logger.error("ambient snapshot write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        lastWriteAt = now
        reloadWidgets(Self.widgetKinds)
        return true
    }

    /// Bypasses the debounce window — used when a caller has a concrete reason the shared
    /// snapshot must reflect the current state right now rather than up to `minWriteInterval`
    /// later. The one production caller is the meds-due widget consent toggle
    /// (`PrivacySecuritySettingsScreen`): revoking `consent.widget.medsDue` should stop a
    /// medication name appearing in the shared snapshot promptly, not linger for up to 30s behind
    /// the ordinary debounce.
    @discardableResult
    func forceWrite(now: Date, tz: String, language: AppLanguage, medsDueConsentGranted: Bool) async -> Bool {
        lastWriteAt = nil
        // `await` is required here purely because `writeIfNeeded` is declared `async` — this call
        // never actually hops actors (both methods are isolated to this same instance), so it
        // cannot suspend behind another caller's in-flight write the way an external caller's
        // `await` can.
        return await writeIfNeeded(now: now, tz: tz, language: language, medsDueConsentGranted: medsDueConsentGranted)
    }

    // MARK: - Assembly (throwing, for direct testing of the DTO's content)

    /// Build today's snapshot from the live repositories. Exposed (not `private`) so tests can
    /// inspect the assembled DTO directly, independent of the debounce/reload/error-swallowing
    /// wrapper above.
    func buildSnapshot(now: Date, tz: String, language: AppLanguage, medsDueConsentGranted: Bool) throws -> AmbientSnapshotDto {
        let periodKey = DayAttribution.dayPeriodKey(now, tz: tz)

        let readiness = try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey)
            .map { RingSnapshot(score: $0.value, provisional: $0.provisional) }

        let dayKey = DayAttribution.localDayKey(now, tz: tz)
        let sentenceText = try OneTrueSentencePicker.pick(insights: insights, dayKey: dayKey)
        let sentence = SentenceSnapshot(en: sentenceText.en, ar: sentenceText.ar)

        let sleep = try buildSleepSnapshot(now: now, tz: tz, periodKey: periodKey)

        let medsDue = medsDueConsentGranted
            ? try buildMedsDueSnapshot(now: now, tz: tz, language: language)
            : nil

        return AmbientSnapshotDto(
            generatedAt: now, language: language.rawValue,
            readiness: readiness, sentence: sentence, sleep: sleep, medsDue: medsDue)
    }

    /// Last night's primary sleep session (duration) plus today's `sleep.performance` score, if
    /// the sleep engine produced one — the same "last night" query `HomeScreen.loadSleep` uses
    /// (`DayAttribution.localNight`, `MeasurementRepository.primarySleep(localNight:)`), and the
    /// same period key `ReadinessEngine.resolveSleepPerformance` reads `sleep.performance` from
    /// (`sleep.performance`'s `periodKey` is stamped with the night's `localNight`, which is the
    /// SAME string as the morning-of day key both engines call `dayKey` — see
    /// `SleepIntelligenceEngine.recompute`). `nil` when there is no primary session for the night
    /// at all (an honest gap, never a zero-duration night).
    private func buildSleepSnapshot(now: Date, tz: String, periodKey: String) throws -> SleepSnapshot? {
        let localNight = DayAttribution.localNight(sessionEnd: now, tz: tz)
        guard let session = try measurements.primarySleep(localNight: localNight) else { return nil }
        let asleepSeconds = session.detail.timeAsleepSeconds ?? session.durationSeconds
        let performance = try derivation.latestDerived(metricId: MetricID.sleepPerformance, periodKey: periodKey)
        return SleepSnapshot(
            durationMinutes: Int((asleepSeconds / 60).rounded()),
            score: performance?.value,
            // No performance row yet reads as "not yet settled," same honest default a missing
            // baseline gets elsewhere in this codebase — never a confident `false`.
            provisional: performance?.provisional ?? true)
    }

    /// Today's due medication times, from every active regimen's schedule — ONLY called when
    /// `consent.widget.medsDue` is granted (see `AmbientSnapshotDto.medsDue`'s doc). Mirrors
    /// `MedicationLogViewModel`'s existing "today's due slots" query (`dueTimes(onWeekday:)`
    /// keyed off the ISO weekday), duplicated rather than shared because that type lives in
    /// `Features/Medication/` (a UI-layer view model this Platform-layer writer must not import) —
    /// an accepted D-4 duplicated-logic tradeoff, the same one `InsightEngine`'s Arabic unit
    /// abbreviation map documents.
    private func buildMedsDueSnapshot(now: Date, tz: String, language: AppLanguage) throws -> MedsDueSnapshot {
        let regimens = try logging.regimens(activeOnly: true)
        let weekday = Self.isoWeekday(now, tz: tz)
        var items: [MedsDueItem] = []
        for regimen in regimens {
            for time in regimen.schedule.dueTimes(onWeekday: weekday) {
                items.append(MedsDueItem(
                    regimenId: regimen.id, displayName: regimen.name,
                    timeLabel: Self.timeLabel(hhmm: time, tz: tz, language: language)))
            }
        }
        return MedsDueSnapshot(items: items)
    }

    /// ISO weekday (1 = Monday … 7 = Sunday, `MedicationSchedule.dueTimes(onWeekday:)`'s
    /// convention) for `date` in `tz`. Mirrors `MedicationLogViewModel.isoWeekday(_:cal:)`'s
    /// formula — see this method's own doc for why it is duplicated rather than shared.
    private static func isoWeekday(_ date: Date, tz: String) -> Int {
        let calendarWeekday = DayAttribution.calendar(tz: tz).component(.weekday, from: date) // 1 = Sunday
        return ((calendarWeekday + 5) % 7) + 1
    }

    /// A locale-formatted "8:00 AM" / "٨:٠٠ ص" for a canonical wall-clock "HH:mm" — resolved once
    /// here so no widget needs its own locale-aware time formatter (see `MedsDueItem.timeLabel`'s
    /// doc). `hh:mm` carries no timezone of its own (same as every other `MedicationSchedule`
    /// time), so both the date this constructs AND the formatter that renders it are pinned to the
    /// SAME explicit `tz` — never the device's ambient current zone — so the displayed hour is
    /// always exactly the hour that was asked for, regardless of what zone this happens to run in.
    private static func timeLabel(hhmm: String, tz: String, language: AppLanguage) -> String {
        guard let (hour, minute) = MedicationReminderPlan.parse(hhmm) else { return hhmm }
        let calendar = DayAttribution.calendar(tz: tz)
        let referenceDay = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: referenceDay) else {
            return hhmm
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = language.locale
        formatter.timeZone = TimeZone(identifier: tz)
        return formatter.string(from: date)
    }

    // MARK: - Widget reload

    static func reloadRealWidgets(_ kinds: [String]) {
        for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    private enum Log {
        static let logger = Logger(subsystem: "net.binjamshid.badan", category: "AmbientSnapshot")
    }
}
