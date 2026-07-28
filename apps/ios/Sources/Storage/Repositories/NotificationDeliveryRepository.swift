import Foundation

// MARK: - Domain (EPIC-32 `notification_deliveries`, migration v8)
//
// These types live beside their repository rather than under `Sources/Domain/`, for the same
// reason `BackgroundRun` does: a notification-delivery row is not a health entity. It carries no
// provenance, no measured value and no metric id (I1 has nothing to say about it) — it is
// operational metadata about a scheduling decision. Putting it in `Domain/` would imply it is part
// of the canonical health model the two platforms mirror entity-for-entity; it is not.

/// The state of one queued/delivered notification. These are the `outcome` values the v8 migration
/// documents (`scheduled|delivered|suppressed|cancelled`); the schema deliberately does not pin the
/// enum, so it is owned here.
enum NotificationOutcome: String, CaseIterable, Sendable {
    /// Queued with the OS but not yet fired. A scheduled row STILL counts toward the day's budget:
    /// the engine has committed the slot even though the notification hasn't left the device.
    case scheduled
    /// The notification fired (the app observed the delivery/response).
    case delivered
    /// The engine decided against sending — over budget, in quiet hours, or capped. Recorded for
    /// diagnostics by `AppEnvironment.evaluateAndScheduleDecision` on every non-`scheduled` verdict
    /// (the same as Android), so "why didn't I get my morning summary?" is answerable from history
    /// rather than guesswork. A suppressed row does NOT consume budget (see `countBudgeted`).
    case suppressed
    /// A previously-scheduled notification was cancelled before it fired (e.g. the class was turned
    /// off). Does not consume budget.
    case cancelled
}

/// One row of the notification budget ledger (plan §9.12 / EPIC-32). VALUE-FREE by contract: it
/// records that a notification of some CLASS was scheduled/delivered, never the health value the
/// notification was about — "a readiness summary was scheduled for 07:00" is metadata; the
/// readiness score itself is nowhere in this struct.
struct NotificationDelivery: Equatable {
    var id: String
    var notificationClass: NotificationClass
    var scheduledFor: Date
    var deliveredAt: Date?
    var outcome: NotificationOutcome
    var updatedAt: Date
    var originDeviceId: String
    var deletedAt: Date?

    /// The `userInfo` key a scheduled request carries its reserved ledger row's id under, so the
    /// notification-center delegate can close that exact row out when the notification is observed.
    /// Carrying the id (rather than looking up "the most recent scheduled row of this class", which
    /// is what Android must do because WorkManager input data is keyed by class) means the delegate
    /// closes the row that actually fired, even if two days' rows are live at once. It is an opaque
    /// ULID for a row that holds no health value, so nothing about the user rides on the request.
    static let ledgerRowIdUserInfoKey = "badan.notificationLedgerRow"
}

// MARK: - Repository

/// `notification_deliveries` (migration v8) — the budget ledger EPIC-32's decision engine counts
/// against. It answers exactly one question for the engine ("how many budgeted notifications have I
/// already committed for this day?") and records what it decides, so the daily invariant survives
/// process death, backgrounding, and multiple evaluations in a day.
///
/// Device-local and pruned like `background_runs`/`export_runs`: this is a record of BADAN's own
/// scheduling, not user data, so it neither needs to accumulate forever nor to merge across devices
/// (a delivery describes what happened on THIS phone).
final class NotificationDeliveryRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    /// The ledger is a rolling budget window, not history to keep — 30 days is far more than the
    /// 1-day budget window needs and leaves a short trail for Diagnostics.
    static let retentionDays = 30

    // MARK: - Writes

    /// Record one delivery decision. Plain INSERT (ids are fresh ULIDs), so a collision is an
    /// id-generation bug worth surfacing rather than silently overwriting an earlier row.
    func insert(_ row: NotificationDelivery) throws {
        try db.run("""
            INSERT INTO notification_deliveries
              (id, notification_class, scheduled_for, delivered_at, outcome, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(row.id), .text(row.notificationClass.rawValue), .date(row.scheduledFor),
             .date(row.deliveredAt), .text(row.outcome.rawValue)]
            + Rows.convParams(updatedAt: row.updatedAt, originDeviceId: row.originDeviceId,
                              deletedAt: row.deletedAt))
    }

    /// Convenience: record a freshly-decided delivery for `cls`, returning the row so a caller can
    /// hold its id (e.g. to mark it delivered later). The ledger stores state transitions, so
    /// `updatedAt` is set to `now` on every write.
    @discardableResult
    func record(_ cls: NotificationClass, scheduledFor: Date, outcome: NotificationOutcome,
                now: Date, deviceId: String) throws -> NotificationDelivery {
        let row = NotificationDelivery(
            id: ULID.newID(), notificationClass: cls, scheduledFor: scheduledFor,
            deliveredAt: outcome == .delivered ? now : nil, outcome: outcome,
            updatedAt: now, originDeviceId: deviceId, deletedAt: nil)
        try insert(row)
        return row
    }

    /// Transition an existing row to `delivered`. Called from `NotificationForegroundDelegate` —
    /// both from the foreground delivery observation (`willPresent`) and from the response handler
    /// (`didReceive`) — via `AppEnvironment.markNotificationDelivered(ledgerRowId:at:)`, using the
    /// row id the request carries in `userInfo`. Idempotent: updating a missing id is a no-op, and
    /// a notification that is both presented in the foreground and then tapped simply lands here
    /// twice.
    ///
    /// What this deliberately does NOT claim: a notification delivered while BADAN is not running
    /// and never tapped is unobservable on iOS, so its row stays `scheduled`. That is honest rather
    /// than lossy — `scheduled` and `delivered` are counted identically by `countBudgeted`, so the
    /// daily budget is exact either way; only the diagnostic distinction is missing.
    func markDelivered(id: String, at date: Date) throws {
        try transition(id: id, to: .delivered, at: date)
    }

    /// Transition the row with `id` to `outcome` — how a slot reserved at decision time is closed
    /// out once we know what actually happened to it. `delivered_at` is stamped only for a real
    /// delivery; any other outcome clears it, because a row that never fired must not carry a
    /// delivery timestamp. Idempotent: updating a missing id is a no-op.
    ///
    /// Mirror of Android `NotificationDeliveryRepository.transition`.
    func transition(id: String, to outcome: NotificationOutcome, at date: Date) throws {
        try db.run("""
            UPDATE notification_deliveries SET outcome = ?, delivered_at = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL;
            """,
            [.text(outcome.rawValue), .date(outcome == .delivered ? date : nil), .date(date), .text(id)])
    }

    // MARK: - Reads (the budget count)

    /// How many BUDGETED (non-med) notifications are already committed for the local day containing
    /// `day`. This is the number the daily invariant is checked against, so it counts only rows
    /// that consumed a slot — `scheduled` and `delivered` — and never `suppressed`/`cancelled` ones.
    /// Meds are excluded structurally (`notification_class <> 'meds'`): a med reminder is exempt
    /// from the budget by design.
    func countBudgeted(inDayOf day: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        let rows = (try? db.query("""
            SELECT COUNT(*) AS c FROM notification_deliveries
            WHERE notification_class <> ?
              AND outcome IN (?, ?)
              AND scheduled_for >= ? AND scheduled_for < ?
              AND deleted_at IS NULL;
            """,
            [.text(NotificationClass.meds.rawValue),
             .text(NotificationOutcome.scheduled.rawValue), .text(NotificationOutcome.delivered.rawValue),
             .date(start), .date(end)])) ?? []
        return rows.first?.intValue("c") ?? 0
    }

    /// Whether a live (scheduled/delivered) row already exists for `cls` on the local day of `day`.
    /// The engine uses this for idempotency — re-evaluating on a second app open the same day must
    /// not schedule a duplicate morning summary.
    func hasScheduled(_ cls: NotificationClass, inDayOf day: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        let rows = (try? db.query("""
            SELECT COUNT(*) AS c FROM notification_deliveries
            WHERE notification_class = ?
              AND outcome IN (?, ?)
              AND scheduled_for >= ? AND scheduled_for < ?
              AND deleted_at IS NULL;
            """,
            [.text(cls.rawValue),
             .text(NotificationOutcome.scheduled.rawValue), .text(NotificationOutcome.delivered.rawValue),
             .date(start), .date(end)])) ?? []
        return (rows.first?.intValue("c") ?? 0) > 0
    }

    /// The live (scheduled/delivered) row for `cls` on the local day of `day`, if there is one.
    ///
    /// `hasScheduled` answers "may I schedule?"; this answers "which row is already holding that
    /// slot?" — the question the wake-triggered summary has to ask. When a wake is detected at 06:40
    /// the 08:00 row was reserved the evening before, so firing now must MOVE that reservation, not
    /// take a second one. Without the row's id there is nothing to move, and the only alternatives
    /// are a duplicate notification or a second budget slot spent on the same summary.
    func scheduledRow(_ cls: NotificationClass, inDayOf day: Date, calendar: Calendar) -> NotificationDelivery? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let rows = (try? db.query("""
            SELECT * FROM notification_deliveries
            WHERE notification_class = ?
              AND outcome IN (?, ?)
              AND scheduled_for >= ? AND scheduled_for < ?
              AND deleted_at IS NULL
            ORDER BY scheduled_for ASC LIMIT 1;
            """,
            [.text(cls.rawValue),
             .text(NotificationOutcome.scheduled.rawValue), .text(NotificationOutcome.delivered.rawValue),
             .date(start), .date(end)])) ?? []
        return rows.first.map(Self.read)
    }

    /// Move an existing reservation to a new fire time, keeping its id and its budget slot.
    ///
    /// Only `scheduled_for` changes. The row is not re-created, because re-creating it would spend a
    /// second slot against the day's ceiling for a notification the user receives once. Kept honest
    /// rather than left stale: the ledger's stated purpose is that "why didn't I get my summary?"
    /// stays answerable, and a row claiming 08:00 for a notification delivered at 06:40 answers it
    /// wrongly.
    func retarget(id: String, to scheduledFor: Date, now: Date) throws {
        try db.run("""
            UPDATE notification_deliveries
            SET scheduled_for = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL;
            """,
            [.date(scheduledFor), .date(now), .text(id)])
    }

    func recent(limit: Int = 50) throws -> [NotificationDelivery] {
        try db.query("""
            SELECT * FROM notification_deliveries WHERE deleted_at IS NULL
            ORDER BY scheduled_for DESC LIMIT ?;
            """, [.int(limit)]).map(Self.read)
    }

    // MARK: - Prune

    /// Drop rows older than `retentionDays`. Hard DELETE, not a soft delete: this is a disposable
    /// budget ledger, not user data — there is nothing here worth keeping a tombstone for.
    @discardableResult
    func prune(now: Date, retentionDays: Int = NotificationDeliveryRepository.retentionDays) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return try db.run("DELETE FROM notification_deliveries WHERE scheduled_for < ?;", [.date(cutoff)])
    }

    // MARK: - Mapping

    static func read(_ r: SQLiteRow) -> NotificationDelivery {
        NotificationDelivery(
            id: r.requireString("id"),
            // A row whose class no longer parses can only come from a downgrade or a hand-edited
            // DB. Fall back to the most conservative registered class rather than dropping the row
            // (and skewing the budget count); `meds` is exempt from the budget, so an unrecognized
            // row falling here never wrongly consumes a non-med slot.
            notificationClass: NotificationClass(rawValue: r.requireString("notification_class")) ?? .meds,
            scheduledFor: r.requireDate("scheduled_for"),
            deliveredAt: r.date("delivered_at"),
            outcome: NotificationOutcome(rawValue: r.requireString("outcome")) ?? .scheduled,
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
