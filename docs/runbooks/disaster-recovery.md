# Runbook — disaster recovery

Scope: **the on-device store only** — `badan.db` (main) and `badan_sensitive.db`
(medications/symptoms/conditions), both under Application Support/BADAN on the user's own
iPhone (Android's Health Connect-backed port has no local SQLite store of its own to recover;
see "Android" under Known gaps). Modeled on
[albayyan-rag/docs/runbooks/disaster-recovery.md](../../../albayyan-rag/docs/runbooks/disaster-recovery.md)
(portfolio review 2026-07-17, Matrix #15), adapted for a local-first app with **no server, no
sync, and no built restore path** (ADR-0002, ADR-0004) — the shape of "disaster recovery" here
is necessarily different, and this runbook says so rather than papering over it with borrowed
language that doesn't apply.

Written 2026-07-20. Never rehearsed end-to-end, because the one step a rehearsal would exercise
— restore — does not exist yet. See "Known gaps." An untested backup is a guess; an untestable
one is worse, and that is the honest starting point for this document.

---

## 0. What exists

| Thing | Where | Notes |
|---|---|---|
| Live store | `Application Support/BADAN/badan.db` + `badan_sensitive.db` (+ `-wal`/`-shm`) | The only copy of the user's data. Local-first by design (ADR-0002): no backend, no sync, nothing leaves the device unless the user exports it. |
| Backup path | **Export** — `ExportCenterScreen` (CSV or JSON), user-initiated, no schedule | Not a backup product feature; it is the general-purpose export feature doubling as the only backup path, exactly as `BackupRestoreSettingsScreen`'s own copy says: "A backup is just an export." |
| Restore path | **Does not exist.** `BackupRestoreSettingsScreen` ships an honest "not built yet" notice (`UnbuiltFeatureNotice`) instead of a dead button. `import_batches` is a table reserved since migration v1 and never used. | This is the load-bearing fact this whole runbook has to be honest about — see §1 and Known gaps. |
| OS-level device backup (iTunes/Finder encrypted local backup, iCloud device backup) | N/A by design | `Database.applyHardening` deliberately excludes both DB files from iCloud/device backup (`isExcludedFromBackup = true`) — a **privacy** feature (medication and symptom history must not silently leave the device via a channel the user didn't choose), which is in direct tension with disaster recovery: it removes the one automatic safety net the OS would otherwise provide for free. That tension is deliberate and accepted, not an oversight (ADR-0004), but it means recoverability rests entirely on the user manually running Export. |
| Encryption | On-device: OS file-level (iOS Data Protection: `.completeUntilFirstUserAuthentication`), verified via read-back (see `Database.hardeningStatus`, ledger #20). Exported files: `includeSensitive` exports are now wrapped in a passphrase-encrypted container (AES-256-GCM, PBKDF2-HMAC-SHA256 — `ExportEncryptor`, ADR-0008) before they reach the share sheet. | On-device is still not SQLCipher — ADR-0004 tracks that as a future decision, not yet adopted; losing the device doesn't expose plaintext to whoever finds it, but device-at-rest and exported-file encryption are two separate mechanisms (ADR-0008 only covers the latter). FEAT-185 (no passphrase-protected export) is closed by ADR-0008 — see the "Known gaps" entries below for what replaces it. |

## 1. The honest shape of "disaster recovery" here

There is no server to fail over, no offsite copy to restore from, and no `restore_db.py` — so
this runbook cannot mirror albayyan-rag's shape past this point without inventing tooling that
does not exist. What follows is scoped to what is actually true today:

- **Device lost, stolen, wiped, or destroyed with no prior export:** total, permanent data loss.
  There is no recovery. This is the default outcome for any user who never opened Export.
- **Device lost, stolen, wiped, or destroyed with a prior export saved somewhere durable
  (Files, AirDrop'd to a Mac, emailed to self):** the export file survives. **It cannot be
  loaded back into a fresh install of BADAN** — there is no importer. The file is, today, only
  a human-readable record (a spreadsheet, or a JSON bundle a developer could script against),
  not a working backup in the "restore and continue" sense this runbook's albayyan-rag model
  assumes.
- **App reinstalled or a new device set up, with the old device still available:** not a
  disaster-recovery scenario at all — there is no device-to-device transfer path either, because
  there is no sync (ADR-0002) and no restore. The user re-onboards from zero on the new device
  regardless of whether the old one is reachable.

**The practical guidance for a user today, until restore ships:** export regularly, keep the
file somewhere durable and private (§2 of `ExportCenterScreen`'s own copy already says "keep the
file somewhere private" — for the same reason, keep it somewhere that outlives the phone), and
understand that doing so protects the *record* but not, currently, the ability to *resume inside
the app* on a new device.

## 2. Corrupt or misbehaving local database (single-device recovery)

The one recovery scenario that **is** real today: the on-device store itself is intact but the
app is misbehaving (a bad read, a crash on launch, a suspiciously empty screen), and the goal is
to determine whether the database is the cause before doing anything destructive.

```text
1. Settings → Diagnostics. Read, before touching anything:
   - "Database version" (schema_version) — a stale/unexpected number can itself be the story.
   - "Main database" / "Sensitive database" sizes — a 0-byte or implausibly small size after
     months of use is the strongest single signal of real corruption or a fallback store.
   - "Storage mode" — if this reads "Temporary — nothing is being saved," the app fell back to
     an in-memory/scratch store (EDGE-05) and NOTHING the user does now will persist; this is
     the single most urgent Diagnostics row (badan/apps/ios/Sources/Features/Settings/
     DiagnosticsScreen.swift).
   - "Backup exclusion & protection" — "Not confirmed" here means the file-protection read-back
     (ledger #20) disagreed with docs/PRIVACY_POLICY.md §3 on THIS device; treat it as a signal
     worth escalating, not a data-loss event by itself.
2. Export everything (CSV + JSON, all scope toggles on, all time) NOW, before any further
   action — this is the closest thing to "copy before restore" available today: it captures the
   current state of the live store as a separate, checksummed artifact before anything below
   risks making things worse. This is deliberately step 2, not step 4 — the copy-before-restore
   discipline the albayyan-rag runbook models applies just as much to a single-device app; there
   is simply no separate "restore location" to copy TO, so the export IS the copy.
3. If the export in step 2 itself fails or produces implausible counts, that is stronger
   evidence of real corruption than anything visible in the UI.
4. There is no repair tool and no `sqlite3` shell reachable from the shipped app. The only
   remaining lever a user has is Settings → "Delete all data" (`Database.resetAll()`), which
   drops and re-migrates both databases from empty — a deliberate, irreversible last resort, not
   a repair. Do not reach for it before step 2 has produced a checksummed export of whatever is
   still readable.
```

## 3. Proving the backup path still works

Do this on a **real device**, quarterly or after any schema/export-format change — the same
cadence discipline as albayyan-rag §5, adapted since there is no server-side script to run it
against.

```text
1. Settings → Backup & restore → Export your data. Run CSV + JSON, scope: everything, all time.
2. Confirm the export's own self-checks instead of trusting that "it finished" means "it
   worked" — ExportRunner already computes these for exactly this reason:
   - Every file listed in the manifest has a SHA-256 checksum (`manifest.json` /
     `bundle.json`'s embedded manifest) — recompute one by hand (Files app → Get Info won't do
     this; AirDrop the file to a Mac and `shasum -a 256` it) and confirm it matches.
   - `perMetricRowCounts` in the manifest is non-empty and plausible for the account being
     tested (zero rows across the board on an account with months of use is a red flag, not a
     clean export).
   - If sample/demo data was ever active on the device, `sampleDataRowCount` and the
     `dataQualityNote`'s "SAMPLE DATA" sentence are present and the count is right — a real
     export silently including fabricated rows with no marker would itself be the disaster.
3. Confirm the file actually left the device somewhere durable — the point of §1's guidance is
   worthless if "exported" only ever means "sat in Files on the same phone that might be lost."
   AirDrop or otherwise move it off-device as part of this check, not as a separate step assumed
   to happen later.
4. There is no step 4 that reads the export back into BADAN — restore does not exist (§0, §1).
   "Proving it still works" for this app currently means proving the export is complete,
   checksummed, and reaches durable storage — not proving a round trip, because no round trip
   is possible yet. Re-run this checklist the day restore ships, and add the missing step then.
5. `ExportScope.everything` (used in step 1) deliberately leaves `includeSensitive` off, so the
   above never exercises the encrypted path (ADR-0008). Separately, run one more export with
   Sensitive on, supply a passphrase, confirm the result is a single `.badanenc` file (not
   `raw.csv`/`bundle.json`), and — since there is no in-app "open encrypted export" screen yet —
   confirm decryptability the only way currently possible: via
   `ExportEncryptor.decrypt(_:passphrase:)` from a debug build or `ExportEncryptionTests.swift`'s
   coverage, not by hand on the device.
```

## 4. Known gaps

Stated plainly, per the house rule this runbook borrows from albayyan-rag: a gap named here is
worth more than a gap discovered during an actual incident.

- **No restore path exists.** This is the central gap this entire document exists to be honest
  about, not a footnote — see §1. `BackupRestoreSettingsScreen` already says so in-app; this
  runbook does not get to claim more than the app itself claims.
- **No round-trip has ever been rehearsed, because there is nothing to rehearse.** Every other
  "proving it still works" section in this portfolio (see albayyan-rag §5) describes a restore
  that was seeded, corrupted, restored, and reopened. That is not possible here yet. §3 above is
  the closest honest substitute available today.
- **No offsite or automatic backup of any kind.** Export is entirely manual and unscheduled;
  a user who never opens Export has zero recovery options, permanently, by design (§0).
- **The privacy/DR tension is real and unresolved, not merely noted.** Excluding both databases
  from iCloud/device backup (ADR-0004, verified via the ledger #20 read-back) is the right
  privacy default and is not being reconsidered here — but it means BADAN has deliberately
  opted out of the one recovery mechanism every other iOS app gets for free. No mitigation is
  proposed in this pass beyond making the trade-off visible.
- **Closed: exported files are no longer plaintext for the sensitive case.** FEAT-185 (review
  ledger #19, deferred fix 3) previously tracked this as open — `includeSensitive` exports carried
  medication and symptom rows in plain CSV/JSON. As of ADR-0008, an `includeSensitive` export is a
  single passphrase-encrypted container (AES-256-GCM, PBKDF2-HMAC-SHA256, 600,000 rounds —
  `ExportEncryptor`); a non-`includeSensitive` export is unchanged and still plain. A backup file
  kept "somewhere private" per §0/§3 is now backed by something technical for the sensitive case,
  not only the location it's kept in.
- **New, honest gap that replaces it: a forgotten export passphrase is unrecoverable, by design,
  not by defect.** The passphrase is never stored anywhere in BADAN — not in the database, not in
  Keychain, not anywhere sync could later read it from (there is no sync — ADR-0002/0003). This is
  the direct consequence of this runbook's own threat model (ADR-0008): the passphrase is the only
  portable secret once a file leaves the device, so BADAN holding a copy of it would defeat the
  point. `ExportCenterScreen` says this plainly at the point of typing the passphrase and offers
  `.newPassword` content-type so iOS can suggest saving it to the user's own password manager —
  but if a user declines that and forgets the passphrase, the export is gone as data, exactly like
  losing the device with no prior export at all (§1). There is no in-app recovery flow to build
  for this; there cannot be, without contradicting the reason it's encrypted in the first place.
- **Android has no on-device store of its own to back up or restore.** The Android port reads
  from Health Connect directly; there is no equivalent of `badan.db`/`badan_sensitive.db` on
  that platform today, so this runbook's scope (§0) is iOS-only. If Android grows a local store,
  this document needs a second scope section, not a silent assumption that iOS's applies.
- **The tmp/ export-lifetime hardening (ledger #19) reduces but does not eliminate a related
  window:** a freshly-run export sits in `tmp/` — file-protected and swept within hours, or
  deleted immediately on a completed share — but between "export finishes" and "share sheet
  dismisses or the sweep fires," a copy exists outside Application Support's hardened directory.
  For an `includeSensitive` export this window now ends much sooner and in ciphertext, not
  plaintext: `ExportRunner.encryptResult` deletes the plaintext files the moment the encrypted
  container is written, before the share sheet even appears (ADR-0008). For a non-sensitive
  export the window is unchanged from before — still plaintext, still bounded by the same
  hours-not-days sweep. Relevant to this runbook because that window is also, technically, an
  unbacked-up copy with its own (short) exposure, not because it changes the backup story above.
- **This runbook itself is unrehearsed as a document**, not just its (nonexistent) restore step:
  no one has yet followed §2 against a real corrupted device. The Diagnostics-first triage in §2
  is reasoned from what `DiagnosticsScreen` exposes today, not proven against an actual incident.
