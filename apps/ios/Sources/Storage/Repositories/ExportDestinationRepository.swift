import Foundation

/// `export_destinations` (migration v4, plan §9.4) — where artifacts go.
///
/// **No secret ever passes through this repository.** The only credential-shaped thing it writes
/// is `ExportDestination.credentialRef`, which is a validated Keychain key (see `CredentialRef`);
/// the secret itself is written by whatever owns the Keychain, and this file deliberately has no
/// import, parameter or column for it. The `config` column takes `ExportDestinationConfig`, whose
/// fields are references and routing details rather than a `[String: String]` bag — the shape
/// that would otherwise make this the easiest place in the codebase to stash a bearer token.
final class ExportDestinationRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Writes

    func upsert(_ destination: ExportDestination) throws {
        try write(destination)
    }

    /// Seed the share-sheet destination, returning true if it was created by this call.
    ///
    /// Quick Export needs a destination row to exist before its first run, because
    /// `export_cursors.destination_id` is NOT NULL and `shareSheet` is a destination kind rather
    /// than the absence of one (v4 comment). Fixed id, so this is idempotent.
    @discardableResult
    func seedShareSheet(now: Date, originDeviceId: String) throws -> Bool {
        let existed = try destination(id: ExportDestination.shareSheetId) != nil
        try write(ExportDestination.shareSheet(now: now, originDeviceId: originDeviceId),
                  conflictPolicy: "OR IGNORE")
        return !existed
    }

    /// Record the result of a reachability/auth check.
    ///
    /// `lastVerifiedAt` is only advanced on `ok`: it means "last known good", and stamping it on
    /// a failed check would make a destination that has been broken for a week look freshly
    /// verified in the Export Health dashboard.
    func updateStatus(id: String, status: ExportDestinationStatus, checkedAt: Date) throws {
        if status == .ok {
            try db.run("""
                UPDATE export_destinations SET status = ?, last_verified_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """, [.text(status.rawValue), .date(checkedAt), .date(checkedAt), .text(id)])
        } else {
            try db.run("""
                UPDATE export_destinations SET status = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;
                """, [.text(status.rawValue), .date(checkedAt), .text(id)])
        }
    }

    /// Tombstone a destination. Templates pointing at it keep their `destination_id`: a run
    /// against a deleted destination should fail loudly with `destinationMissing`-shaped
    /// evidence in the ledger, not silently redirect somewhere the user did not choose.
    func softDelete(id: String, at date: Date) throws {
        try db.run("""
            UPDATE export_destinations SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;
            """, [.date(date), .date(date), .text(id)])
    }

    private func write(_ d: ExportDestination, conflictPolicy: String = "OR REPLACE") throws {
        try db.run("""
            INSERT \(conflictPolicy) INTO export_destinations
              (id, kind, display_name, config, credential_ref, tls_policy, created_at,
               last_verified_at, status, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(d.id), .text(d.kind.rawValue), .text(d.displayName),
             .text(try JSONCoding.encodeOrThrow(d.config)),
             .string(d.credentialRef?.key), .text(d.tlsPolicy.rawValue), .date(d.createdAt),
             .date(d.lastVerifiedAt), .text(d.status.rawValue)]
            + Rows.convParams(updatedAt: d.updatedAt, originDeviceId: d.originDeviceId,
                              deletedAt: d.deletedAt))
    }

    // MARK: - Reads

    func all() throws -> [ExportDestination] {
        try db.query("SELECT * FROM export_destinations WHERE deleted_at IS NULL ORDER BY created_at ASC;")
            .map(Self.read)
    }

    func destination(id: String) throws -> ExportDestination? {
        try db.query("SELECT * FROM export_destinations WHERE id = ? AND deleted_at IS NULL;", [.text(id)])
            .first.map(Self.read)
    }

    static func read(_ r: SQLiteRow) -> ExportDestination {
        ExportDestination(
            id: r.requireString("id"),
            // Falls back to `shareSheet` — the only kind that cannot leave the device. An
            // unparseable kind is a corrupted or downgraded row, and the safe reading of "I do
            // not know where this sends data" is "it does not send data anywhere".
            kind: ExportDestinationKind(rawValue: r.requireString("kind")) ?? .shareSheet,
            displayName: r.requireString("display_name"),
            config: JSONCoding.decode(ExportDestinationConfig.self, from: r.string("config"))
                ?? ExportDestinationConfig(),
            // A stored value that no longer validates as a `CredentialRef` reads back as nil
            // rather than as a string. The consequence is honest: the secret becomes unreachable
            // and the destination will report `authExpired` on its next check, which is the
            // truth — BADAN has lost the handle to it. The alternative, widening the type to
            // carry arbitrary text back out of the database, is the leak this guards.
            credentialRef: r.string("credential_ref").flatMap { CredentialRef(key: $0) },
            tlsPolicy: ExportTlsPolicy(rawValue: r.requireString("tls_policy")),
            createdAt: r.requireDate("created_at"),
            lastVerifiedAt: r.date("last_verified_at"),
            status: ExportDestinationStatus(rawValue: r.requireString("status")) ?? .disabled,
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
