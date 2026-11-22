import Foundation
import CryptoKit

/// Thrown by `ExportRunner.run` when `scope.includeSensitive` is set without a passphrase
/// meeting `ExportPassphrasePolicy` — the runner's own defense-in-depth so a caller that bypassed
/// `ExportCenterScreen`'s required passphrase fields (a future automation surface, a test, a
/// bug in the UI's disable logic) still cannot produce an unencrypted sensitive export (review
/// ledger #19, deferred fix 3 / FEAT-185; see `docs/adr/ADR-0008-*.md`).
enum ExportRunError: Error, Equatable {
    case sensitiveExportRequiresPassphrase
}

/// Runs a fully offline export: gathers scoped records from the repositories, renders them
/// (CSV split into raw/derived files, or one JSON bundle), checksums every file, writes a
/// versioned manifest, and records the completed `ExportJob`. No networking or entitlement
/// imports live on this path — Foundation + CryptoKit only (D-8).
final class ExportRunner {

    /// The artifact produced by a run: the persisted job (with manifest), the written files,
    /// and the total exported record count.
    struct ExportResult {
        let job: ExportJob
        let fileURLs: [URL]
        let rowCount: Int
        /// The largest `provenance.ingestedAt` among the raw/interval/session rows this export
        /// actually wrote — the cursor watermark a successful `sinceLastRun` delivery advances to
        /// (EPIC-17). `nil` when the export contained no ingested measurement rows (e.g. a
        /// derived-only or log-only scope), in which case a delta run leaves the cursor untouched
        /// rather than inventing a watermark from a non-ingested axis. Defaulted so the many
        /// existing `ExportResult(job:fileURLs:rowCount:)` call sites are unaffected.
        var maxIngestedAt: Date? = nil
        /// Row counts by record class, for the `ExportRun` ledger (§9.5). By class, never by
        /// metric — see `ExportRowCounts`. Defaulted for the same reason as `maxIngestedAt`.
        var rowCounts: ExportRowCounts? = nil
    }

    private let measurements: MeasurementRepository
    private let derivation: DerivationRepository
    private let logging: LoggingRepository
    /// The drink ledger (EPIC-38), or nil. Optional-and-defaulted for the same reason the template
    /// collaborators below are: the automation runner, `runRouteExport`/`runAggregated`, and every
    /// pre-hydration test construct an `ExportRunner` without it and must keep compiling and
    /// behaving byte-for-byte unchanged. When it is nil — or when a run's scope catches no drinks —
    /// the JSON `logs.hydration` block and the hydration CSV set stay ABSENT, so a store with no
    /// hydration produces the exact bytes it did before (the absent-not-empty rule `JSONBundleWriter`
    /// documents, which is what keeps the pre-hydration goldens byte-stable). A logged drink is
    /// normal-class (main DB), so it rides the DEFAULT export exactly like workouts/nutrition — it is
    /// the user's own data and is never paywalled or withheld. Only the free-text `note` is redacted,
    /// and structurally, by the default `HydrationRedactionPolicy` — never by the sensitive gate.
    private let hydration: HydrationRepository?
    /// The behavior journal + context statuses (EPIC-29), or nil. Optional-and-defaulted for the
    /// same compile-compatibility reason as `hydration` — but the resemblance stops there: both
    /// families are SENSITIVE-PLUS (I7), so unlike drinks they are gathered only when the scope's
    /// `includeSensitive` is set, exactly like symptoms and adherence. A default export carries
    /// neither array, and because the JSON keys are absent-when-empty, it carries no evidence that
    /// a journal was even consulted. This repository holds only the sensitive connection, so a
    /// journal row cannot be read from — or written to — `badan.db` from here.
    private let journal: JournalRepository?
    private let exportJobs: ExportJobRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let appVersion: String
    private let deviceId: String

    // EPIC-09/13/14/17 template-run collaborators. All optional and defaulted to nil/[] so the
    // existing `ExportRunner(measurements:…:deviceId:)` construction — used by `AppEnvironment`
    // and every Phase-0/1 test — compiles and behaves exactly as before. `runTemplate` guards on
    // their presence; the plain `run(scope:format:)` path never touches them, so a runner built
    // without them keeps producing artifacts and `ExportJob` rows unchanged.
    private let templates: ExportTemplateRepository?
    private let destinations: ExportDestinationRepository?
    private let runs: ExportRunRepository?
    private let cursors: ExportCursorRepository?
    private let routes: RouteRepository?
    /// The dedup journal (EPIC-17). Optional/defaulted like the other template collaborators: a
    /// runner built without it simply emits no `corrections[]` (a delta then still carries new rows
    /// and `deletions[]`, just not suppression-flip reconciliation). Only read on the delta path.
    private let reconciliation: ReconciliationRepository?
    /// One `ExportDestinationDelivering` per non-local destination kind. `shareSheet` is handled
    /// in-process (the artifacts stay in the temp folder for the UI's share sheet) and needs no
    /// entry here; a kind with no registered deliverer fails loudly as `failedDelivery` rather
    /// than silently writing the user's data nowhere.
    private let deliverers: [ExportDestinationDelivering]

    init(measurements: MeasurementRepository, derivation: DerivationRepository,
         logging: LoggingRepository, exportJobs: ExportJobRepository,
         registry: MetricRegistry, clock: Clock, appVersion: String, deviceId: String,
         hydration: HydrationRepository? = nil,
         journal: JournalRepository? = nil,
         templates: ExportTemplateRepository? = nil, destinations: ExportDestinationRepository? = nil,
         runs: ExportRunRepository? = nil, cursors: ExportCursorRepository? = nil,
         routes: RouteRepository? = nil, deliverers: [ExportDestinationDelivering] = [],
         reconciliation: ReconciliationRepository? = nil) {
        self.measurements = measurements
        self.derivation = derivation
        self.logging = logging
        self.hydration = hydration
        self.journal = journal
        self.exportJobs = exportJobs
        self.registry = registry
        self.clock = clock
        self.appVersion = appVersion
        self.deviceId = deviceId
        self.templates = templates
        self.destinations = destinations
        self.runs = runs
        self.cursors = cursors
        self.routes = routes
        self.deliverers = deliverers
        self.reconciliation = reconciliation
    }

    // MARK: - Entry point

    /// `passphrase` is required (and validated against `ExportPassphrasePolicy`) whenever
    /// `scope.includeSensitive` is true — a sensitive export can no longer leave this function as
    /// plaintext. Ignored (and may be omitted) for a non-sensitive scope, which stays exactly the
    /// unencrypted behavior it always was.
    ///
    /// `ingestedSince` is the incremental-export delta filter (EPIC-17). When set, a row is
    /// included only if it arrived on THIS device after the watermark — `provenance.ingestedAt`
    /// for the measurement chain, `updatedAt`/`computedAt` for derived/baseline/log rows. This is
    /// deliberately the ingested axis, never the measured one: a watch that syncs Saturday's
    /// workout on Monday has `measured_at` behind an existing Sunday watermark, and filtering by
    /// measured time would drop it forever (the exact silent-loss failure `ExportCursor`'s doc
    /// and DATA-08 warn against). `nil` — the only value the plain UI export path passes — is a
    /// no-op, so a non-delta run is byte-identical to before. The caller that sets `ingestedSince`
    /// (`runTemplate`'s `sinceLastRun` path) also passes a scope with no measured-date window, so
    /// only the ingested filter narrows the set.
    /// `previousManifestSha` (EPIC-17) is the prior delta's bundle-file sha, carried into THIS
    /// bundle's manifest as `previous_manifest_sha` so a consumer can verify the chain link
    /// (§22.6). Meaningful only alongside a non-nil `ingestedSince` (a real delta); a whole-window
    /// or non-delta run ignores it and the manifest's `is_delta` stays false with null cursors.
    func run(scope: ExportScope, format: ExportFormat, passphrase: String? = nil,
             ingestedSince: Date? = nil, previousManifestSha: String? = nil) throws -> ExportResult {
        if scope.includeSensitive {
            guard let passphrase, ExportPassphrasePolicy.isValid(passphrase) else {
                throw ExportRunError.sensitiveExportRequiresPassphrase
            }
        }

        // Best-effort housekeeping for folders orphaned by a past interrupted export (a crash
        // or force-quit mid-run never reaches the cleanup below) — never blocks this run
        // (EDGE-02c).
        sweepOrphanedExportFolders()

        let startedAt = clock.now()
        let exportId = ULID.newID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-\(exportId)", isDirectory: true)
        // `tmp/` inherits no hardening from `Database.applyHardening` (that only covers
        // Application Support), so these plaintext CSV/JSON files would otherwise sit in the
        // weakest default protection class on disk. `.complete` is safe here specifically
        // because export/share is a foreground-only flow — the file only needs to be readable
        // while the user is actively running or sharing it, never from a background refresh
        // (ledger #19 / dossier "Sensitive health data is exported as plaintext to the temp
        // directory").
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])

        // Record the attempt immediately (status .running) so a crash or memory-pressure
        // termination mid-export is diagnosable via `export_jobs` rather than the attempt
        // vanishing entirely; `insert` is an upsert keyed by `exportId`, so the same row is
        // updated to .completed/.failed below rather than duplicated (PERF-176).
        let runningJob = ExportJob(id: exportId, scope: scope, format: format, status: .running,
                                   outputPath: folder.path, startedAt: startedAt, createdAt: startedAt)
        try exportJobs.insert(runningJob)

        do {
            let ids = metricIdsInScope(scope)
            let rangeStart = scope.startDate ?? Date(timeIntervalSince1970: 0)
            let rangeEnd = scope.endDate ?? startedAt
            let wantRaw = scope.includeRaw

            // Snapshot-isolate the whole gather phase against a concurrent ingest (EDGE-03).
            // `measurements` and `derivation` share the same main-DB `SQLiteConnection` (see
            // `AppEnvironment` init), and `SQLiteConnection.transaction` joins a same-thread
            // nested call onto the same transaction rather than starting a second one, so
            // wrapping every main-DB read in one `measurements.transaction { ... }` block gives
            // all of raw/derived/workouts/nutrition one consistent snapshot. Symptom/adherence
            // reads go through `LoggingRepository`'s separate `sensitive` connection/file — a
            // pre-existing, documented architectural split (see
            // `LoggingRepository.transactionMain`/`transactionSensitive`) that a single
            // in-process transaction can't span, so those two reads stay outside this block.
            let gathered = try measurements.transaction { () -> GatheredMainDB in
                var rawSamples: [RawSample] = []
                var intervalRecords: [IntervalRecord] = []
                if scope.includeRaw {
                    for id in ids where metricAllowed(id, scope) {
                        rawSamples += try measurements
                            .rawSamples(metricId: id, from: scope.startDate, to: scope.endDate, includeSuppressed: scope.includeSuppressed)
                            .filter { sourceAllowed($0.provenance, scope) && Self.ingestedAfter($0.provenance.ingestedAt, ingestedSince) }
                        intervalRecords += try measurements
                            .intervalRecords(metricId: id, from: scope.startDate, to: scope.endDate, includeSuppressed: scope.includeSuppressed)
                            .filter { sourceAllowed($0.provenance, scope) && Self.ingestedAfter($0.provenance.ingestedAt, ingestedSince) }
                    }
                }

                var sessions: [Session] = []
                if scope.includeRaw {
                    sessions = try measurements
                        .sessions(kind: nil, from: scope.startDate, to: scope.endDate, includeSuppressed: scope.includeSuppressed)
                        .filter { sessionInScope($0, scope) && sourceAllowed($0.provenance, scope)
                            && Self.ingestedAfter($0.provenance.ingestedAt, ingestedSince) }
                }

                // Rows whose period key couldn't be parsed as a `day:` key are still included
                // (best-effort) when a date range was requested, but counted so the manifest can
                // disclose that they weren't actually range-verified (OPT-143).
                var derivedValues: [DerivedValue] = []
                var baselines: [Baseline] = []
                var derivedRangeFallbackCount = 0
                if scope.includeDerived {
                    for id in ids where metricAllowed(id, scope) {
                        for v in try derivation.latestDerivedSeries(metricId: id)
                        where derivedInRange(v, scope) && Self.ingestedAfter(v.updatedAt, ingestedSince) {
                            derivedValues.append(v)
                            if derivedIncludedByRangeFallback(v, scope) { derivedRangeFallbackCount += 1 }
                        }
                        // A derived value carries no `ingested_at` (it was computed here, not
                        // ingested), so its delta axis is `updatedAt`/`computedAt` — "recomputed
                        // since the last run" — never the raw watermark. The cursor itself only
                        // ever advances on the raw ingested axis (see `maxIngestedAt`), so a
                        // baseline recomputation cannot drag the watermark past unexported raw rows.
                        if registry.definition(id)?.baselineEligible == true,
                           let baseline = try derivation.latestBaseline(metricId: id),
                           Self.ingestedAfter(baseline.computedAt, ingestedSince) {
                            baselines.append(baseline)
                        }
                    }
                }

                // Structured logs kept in the main DB (workouts/nutrition/hydration are normal-class).
                let workouts = (wantRaw && logFamilyIncluded("activity", scope))
                    ? try logging.workouts(from: rangeStart, to: rangeEnd)
                        .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) } : []
                let nutrition = (wantRaw && logFamilyIncluded("nutrition", scope))
                    ? try logging.nutrition(from: rangeStart, to: rangeEnd)
                        .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) } : []
                // Hydration rides the same normal-class log gate as workouts/nutrition — the
                // "hydration" family, mirroring their "activity"/"nutrition" gating exactly. Gathered
                // inside THIS `measurements.transaction` block (not after it) because the drink ledger
                // shares the same main-DB connection, so a same-thread nested read joins this one
                // snapshot (EDGE-03) rather than opening a second.
                let hydrationPayload = (wantRaw && logFamilyIncluded("hydration", scope))
                    ? try gatherHydration(from: rangeStart, to: rangeEnd, ingestedSince: ingestedSince) : nil

                return GatheredMainDB(rawSamples: rawSamples, intervalRecords: intervalRecords, sessions: sessions,
                                      derivedValues: derivedValues, baselines: baselines,
                                      derivedRangeFallbackCount: derivedRangeFallbackCount,
                                      workouts: workouts, nutrition: nutrition, hydration: hydrationPayload)
            }

            // Sensitive-class logs (medications/symptoms) — separate `sensitive` DB connection,
            // additionally gated by `includeSensitive` (matches the JSON bundle's existing gate).
            let symptoms = (wantRaw && scope.includeSensitive && logFamilyIncluded("symptoms", scope))
                ? try logging.symptoms(from: rangeStart, to: rangeEnd)
                    .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) } : []
            let adherence = (wantRaw && scope.includeSensitive && logFamilyIncluded("medications", scope))
                ? try logging.adherence(from: rangeStart, to: rangeEnd)
                    .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) } : []

            // The behavior journal + declared context intervals (EPIC-29), sensitive-plus (I7) and
            // therefore behind the SAME `includeSensitive` gate as symptoms/adherence — not the
            // normal-class gate hydration rides. Gathered from the sensitive connection only.
            //
            // Journal entries are windowed on `occurred_at`, so a tag the user backdated to
            // yesterday exports under yesterday. Statuses are windowed on `start_at` (see
            // `JournalRepository.statuses(from:to:)`): an export answers "what did the user declare
            // in this period", so a still-open, year-long status is not dragged into every window.
            let journalPayload = (wantRaw && scope.includeSensitive && logFamilyIncluded("journal", scope))
                ? try gatherJournal(from: rangeStart, to: rangeEnd, ingestedSince: ingestedSince) : nil

            // The delta watermark, computed over the rows the file actually contains (raw/interval/
            // session — the ingested axis a `sinceLastRun` cursor advances on), so a derived- or
            // log-only export reports `nil` and leaves the cursor untouched. Hoisted above
            // generation so the JSON manifest can carry it as `cursor_after` — the exact value
            // `runTemplate`'s two-phase commit will advance the cursor to on a successful delivery.
            let ingestMax = ([gathered.rawSamples.map(\.provenance.ingestedAt),
                              gathered.intervalRecords.map(\.provenance.ingestedAt),
                              gathered.sessions.map(\.provenance.ingestedAt)].flatMap { $0 }).max()

            // Delta reconciliation (§22.6), gathered ONLY on a real delta run (`ingestedSince` set).
            // A delta gathers only LIVE rows, so a removal or a dedup flip since the cursor would be
            // invisible to an add-only consumer; these two queries close that. Both filter on the
            // deletion/decision instant, not the ingested axis — an ingested-axis watermark says
            // nothing about WHEN a row was later removed or a decision reversed. Re-reporting the
            // same tombstone/flip on a later run (until the cursor advances past it) is idempotent
            // for a downstream store, the same forgiving property the cursor's `>` window relies on.
            //
            // Gathered for BOTH formats, because the desync is a property of "delta" and not of
            // "JSON": the cursor advances format-blind (see `runTemplate`'s two-phase commit), so a
            // CSV delta that dropped these would move its watermark past removals it never reported
            // — the exact silent desync this section exists to prevent. JSON carries them as the
            // bundle's `deletions[]`/`corrections[]`; CSV carries them as `deletions.csv` /
            // `corrections.csv` (`ExportDeltaCSVWriter`), same records, same order.
            //
            // Coverage bound, stated rather than papered over: corrections are read from the dedup
            // JOURNAL (`dedup_decisions`), which is the reversible, inspectable record I3 requires,
            // so a `suppressed_by` written WITHOUT journaling a decision produces no correction
            // here. As of today that is three paths, all in `IngestionPipeline` and all listed so
            // the gap is countable rather than vague: un-suppressing a session whose winner went
            // stale (`dedup`), re-pointing the derived nightly rollups on a winner flip
            // (`upsertDailySleepInterval`), and suppressing a stage rollup left without a basis
            // (`suppressStageRollupWithoutABasis`). A downstream store learns of those only from a
            // full re-export. Closing them means journaling those flips at the ingestion end, not
            // widening this query. Import undo used to be a fourth; it now journals its
            // un-suppression as a reversal (`ImportBatchRepository.undo`), so it emits a correction
            // like any other flip.
            let isDelta = ingestedSince != nil
            var deltaDeletions: [ExportTombstone] = []
            var corrections: [ExportSuppressionCorrection] = []
            if let ingestedSince {
                deltaDeletions = (try? measurements.tombstones(since: ingestedSince)) ?? []
                if let reconciliation {
                    let flipped = (try? reconciliation.decisionsChangedSince(ingestedSince)) ?? []
                    corrections = flipped.map(Self.correction(from:))
                }
            }

            // Delta metadata is stamped ONLY on a real delta run. `ingestMax` is computed for every
            // run (the cursor two-phase commit below needs it regardless), but writing it into a
            // whole-window manifest as `cursor_after` would publish `is_delta: false` beside a
            // populated window — a contradiction a consumer cannot resolve, and one that would make
            // a plain "export everything" file read as a link in an incremental chain. Same for
            // `previous_manifest_sha`: the caller reads it off the cursor row, which exists as soon
            // as ANY delta has run for that (template, destination), so a later full export from the
            // same template would otherwise chain itself to a delta it does not continue.
            let deltaCursorAfter = isDelta ? ingestMax : nil
            let deltaPreviousSha = isDelta ? previousManifestSha : nil

            let result: ExportResult
            switch format {
            case .csv:
                result = try runCSV(scope: scope, exportId: exportId, folder: folder, startedAt: startedAt,
                                    rawSamples: gathered.rawSamples, intervalRecords: gathered.intervalRecords,
                                    sessions: gathered.sessions, derivedValues: gathered.derivedValues,
                                    baselines: gathered.baselines,
                                    derivedRangeFallbackCount: gathered.derivedRangeFallbackCount,
                                    symptoms: symptoms, adherence: adherence,
                                    workouts: gathered.workouts, nutrition: gathered.nutrition,
                                    hydration: gathered.hydration, journal: journalPayload,
                                    isDelta: isDelta, deltaDeletions: deltaDeletions,
                                    corrections: corrections)
            case .json:
                result = try runJSON(scope: scope, exportId: exportId, folder: folder, startedAt: startedAt,
                                     rawSamples: gathered.rawSamples, intervalRecords: gathered.intervalRecords,
                                     sessions: gathered.sessions, derivedValues: gathered.derivedValues,
                                     baselines: gathered.baselines,
                                     derivedRangeFallbackCount: gathered.derivedRangeFallbackCount,
                                     symptoms: symptoms, adherence: adherence,
                                     workouts: gathered.workouts, nutrition: gathered.nutrition,
                                     hydration: gathered.hydration, journal: journalPayload,
                                     isDelta: isDelta, cursorBefore: ingestedSince, cursorAfter: deltaCursorAfter,
                                     previousManifestSha: deltaPreviousSha,
                                     deltaDeletions: deltaDeletions, corrections: corrections)
            }
            let suppressedCount = gathered.rawSamples.filter { $0.provenance.isSuppressed }.count
                + gathered.intervalRecords.filter { $0.provenance.isSuppressed }.count
                + gathered.sessions.filter { $0.provenance.isSuppressed }.count
            let counts = ExportRowCounts(
                measurements: gathered.rawSamples.count, intervals: gathered.intervalRecords.count,
                sessions: gathered.sessions.count,
                logs: symptoms.count + adherence.count + gathered.workouts.count + gathered.nutrition.count
                    + (gathered.hydration?.entries.count ?? 0)
                    + (journalPayload?.entries.count ?? 0) + (journalPayload?.statuses.count ?? 0),
                derived: gathered.derivedValues.count + gathered.baselines.count,
                suppressed: suppressedCount)

            var finalResult: ExportResult
            if scope.includeSensitive, let passphrase {
                // Any failure here (encryption, write, re-persist) falls through to the `catch`
                // below exactly like a gather/write failure would — the job is marked `.failed`
                // and the whole folder (plaintext files included) is removed, so a sensitive
                // export never survives half-encrypted (ledger #19 / dossier "Sensitive health
                // data is exported as plaintext to the temp directory").
                finalResult = try encryptResult(result, exportId: exportId, folder: folder, scope: scope,
                                                format: format, startedAt: startedAt, passphrase: passphrase)
            } else {
                finalResult = result
            }
            finalResult.maxIngestedAt = ingestMax
            finalResult.rowCounts = counts
            return finalResult
        } catch {
            let failedJob = ExportJob(id: exportId, scope: scope, format: format, status: .failed,
                                      outputPath: folder.path, startedAt: startedAt,
                                      finishedAt: clock.now(), createdAt: startedAt)
            try? exportJobs.insert(failedJob)
            // Nothing left behind from a failed run (EDGE-02c).
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - Encryption (includeSensitive only)

    /// Wraps every file `runCSV`/`runJSON` just wrote into one `ExportEncryptor` container,
    /// writes it as `ExportEncryptor.containerFileName` in the same folder, deletes the plaintext
    /// originals, and re-persists the job with `manifest.encrypted = true` pointing at the
    /// container instead. The manifest's checksums are left exactly as computed (they describe
    /// the real plaintext content, the thing a user actually wants to verify after decrypting —
    /// see the ADR) — only `encrypted`/`encryptedContainerName` change.
    ///
    /// Reading each file back off disk rather than threading the in-memory bytes through
    /// `runCSV`/`runJSON` keeps this step decoupled from both writers (CSV's three files are
    /// streamed straight to a `FileHandle` and never held as one in-memory `Data`, PERF-168/170)
    /// at the cost of one extra read pass — acceptable for a step that already pays a ~600k-round
    /// KDF.
    private func encryptResult(_ result: ExportResult, exportId: String, folder: URL, scope: ExportScope,
                               format: ExportFormat, startedAt: Date, passphrase: String) throws -> ExportResult {
        let files = try result.fileURLs.map { url in
            ExportContainerFile(name: url.lastPathComponent, data: try Data(contentsOf: url))
        }
        let containerData = try ExportEncryptor.encrypt(files: files, passphrase: passphrase)
        let containerURL = folder.appendingPathComponent(ExportEncryptor.containerFileName)
        try containerData.write(to: containerURL, options: .completeFileProtection)

        // The plaintext files have a real, encrypted copy now — same reasoning as the
        // share-sheet-dismissal delete below, just triggered earlier: once a durable encrypted
        // replacement exists, the plaintext copy has no further reason to sit in `tmp/`
        // (ledger #19).
        for url in result.fileURLs { try? FileManager.default.removeItem(at: url) }

        var manifest = result.job.manifest
        manifest?.encrypted = true
        manifest?.encryptedContainerName = ExportEncryptor.containerFileName
        let finishedAt = clock.now()
        let job = ExportJob(id: exportId, scope: scope, format: format, status: .completed,
                            manifest: manifest, outputPath: folder.path, rowCount: result.rowCount,
                            startedAt: startedAt, finishedAt: finishedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        return ExportResult(job: job, fileURLs: [containerURL], rowCount: result.rowCount)
    }

    /// The main-DB portion of one run's gathered records — everything read inside the single
    /// `measurements.transaction { ... }` snapshot in `run(scope:format:)` (EDGE-03).
    private struct GatheredMainDB {
        let rawSamples: [RawSample]
        let intervalRecords: [IntervalRecord]
        let sessions: [Session]
        let derivedValues: [DerivedValue]
        let baselines: [Baseline]
        let derivedRangeFallbackCount: Int
        let workouts: [WorkoutEntry]
        let nutrition: [NutritionEntry]
        /// The drink slice, or nil when hydration isn't wired in or caught no data in range — kept
        /// nil (never an empty payload) so the JSON block and CSV set stay absent, not empty.
        let hydration: HydrationExportPayload?
    }

    /// Gathers the hydration slice within the export window and assembles a `HydrationExportPayload`,
    /// or returns nil when the module isn't wired in (`hydration == nil`) or nothing falls in range.
    /// Nil — not an empty payload — is deliberate: `JSONBundleWriter` and `HydrationCSVWriter` add
    /// nothing for a nil/empty payload, so an install with no drinks emits the exact pre-hydration
    /// bytes (the goldens stay byte-stable).
    ///
    /// MUST be called inside `run`'s `measurements.transaction` snapshot — the drink ledger shares
    /// the main-DB connection, so this nested same-thread read joins that one transaction (EDGE-03).
    /// Gathers the journal slice (behavior tags + declared context intervals) within the window,
    /// or returns nil when the module isn't wired in or nothing falls in range. Nil — not an empty
    /// payload — for the same absent-not-empty reason `gatherHydration` returns nil, plus the I7
    /// one: an empty `logs.journal` would disclose that a sensitive log was read.
    ///
    /// Callers MUST have checked `scope.includeSensitive` first; this function does not re-derive
    /// the consent gate, so there is exactly one place it lives (the `run` gather above).
    ///
    /// The delta filter runs on `updatedAt`, matching symptoms/adherence: a journal entry is not
    /// ingested from anywhere, it is typed here, so there is no ingested axis to filter on.
    private func gatherJournal(from rangeStart: Date, to rangeEnd: Date,
                               ingestedSince: Date?) throws -> JournalExportPayload? {
        guard let journal else { return nil }
        let entries = try journal.entries(from: rangeStart, to: rangeEnd)
            .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) }
        let statuses = try journal.statuses(from: rangeStart, to: rangeEnd)
            .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) }
        let payload = JournalExportPayload(entries: entries, statuses: statuses)
        return payload.isEmpty ? nil : payload
    }

    private func gatherHydration(from rangeStart: Date, to rangeEnd: Date,
                                 ingestedSince: Date?) throws -> HydrationExportPayload? {
        guard let hydration else { return nil }
        // Entries carry full provenance, so the delta filter runs on the honest ingested axis (the
        // same axis raw samples use) rather than `updated_at` — a drink logged before the watermark
        // but stored after it is still delivered, never silently dropped (the DATA-08 hazard).
        let entries = try hydration.liveEntries(from: rangeStart, to: rangeEnd)
            .filter { Self.ingestedAfter($0.provenance.ingestedAt, ingestedSince) }
        // Summaries are keyed by local calendar day and queried by lexical (== chronological) day-key
        // comparison. The window's day keys are computed in UTC to match the instants the runner
        // works in; an all-time export (nil dates) spans 1970-01-01..today and catches every day.
        let startKey = GoalEngine.dayKey(for: rangeStart, tzId: "UTC")
        let endKey = GoalEngine.dayKey(for: rangeEnd, tzId: "UTC")
        let summaries = try hydration.summaries(from: startKey, to: endKey)
            .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) }
        let goals = try hydration.allGoals()
            .filter { Self.ingestedAfter($0.updatedAt, ingestedSince) }
        // Only the custom beverages the exported entries actually reference — enough to name every
        // drink in the file without shipping the whole catalog (HydrationExportPayload's contract).
        // Not delta-filtered: a dictionary entry a delta's rows point at must travel with them.
        let referenced = Set(entries.compactMap { $0.beverageId })
        let beverages = referenced.isEmpty
            ? [] : try hydration.beverages().filter { referenced.contains($0.id) }
        let payload = HydrationExportPayload(entries: entries, summaries: summaries,
                                             goals: goals, beverages: beverages)
        return payload.isEmpty ? nil : payload
    }

    /// Deletes `badan-export-*` temp folders older than `hours` — orphaned by an interrupted
    /// export whose own cleanup never ran (app killed, crash), or by a completed export the user
    /// never opened the share sheet for. Best-effort and silent: a failure here must never block
    /// the export this call is part of (EDGE-02c).
    ///
    /// The primary defense against a plaintext export lingering in `tmp/` is
    /// `deleteExportedFiles(at:)`, fired the moment the share sheet dismisses — this sweep is
    /// only the backstop for exports nobody ever shared. Was 7 days; ledger #19 / dossier
    /// "Sensitive health data is exported as plaintext to the temp directory" calls that far too
    /// long for unencrypted symptom/medication rows, so the backstop window is now hours, not
    /// days.
    private func sweepOrphanedExportFolders(olderThan hours: Double = 4) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = clock.now().addingTimeInterval(-hours * 3_600)
        for url in items where url.lastPathComponent.hasPrefix("badan-export-") {
            guard let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if modDate < cutoff { try? fm.removeItem(at: url) }
        }
    }

    /// Deletes one export's temp folder immediately — the caller (`ExportCenterScreen`) invokes
    /// this the moment the share sheet dismisses, rather than waiting for the next run's sweep
    /// (ledger #19 / dossier "Sensitive health data is exported as plaintext to the temp
    /// directory"). Once the user has handed the file to AirDrop/Files/Mail/etc. — or explicitly
    /// dismissed without sharing — the plaintext temp copy has no further reason to exist; the
    /// destination the user chose, if any, now holds its own copy.
    ///
    /// Scoped to `tmp/badan-export-*` only, so a caller passing a wrong or manipulated path can
    /// never turn this into an arbitrary-path delete. Best-effort and silent, matching
    /// `sweepOrphanedExportFolders`'s failure posture — a delete failure here must never surface
    /// as a user-facing error for an export the user already successfully shared.
    func deleteExportedFiles(at folderPath: String) {
        let fm = FileManager.default
        guard folderPath.hasPrefix(fm.temporaryDirectory.path),
              URL(fileURLWithPath: folderPath).lastPathComponent.hasPrefix("badan-export-") else { return }
        try? fm.removeItem(atPath: folderPath)
    }

    // MARK: - CSV

    private func runCSV(scope: ExportScope, exportId: String, folder: URL, startedAt: Date,
                        rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
                        derivedValues: [DerivedValue], baselines: [Baseline],
                        derivedRangeFallbackCount: Int, symptoms: [SymptomEntry], adherence: [AdherenceEvent],
                        workouts: [WorkoutEntry], nutrition: [NutritionEntry],
                        hydration: HydrationExportPayload?,
                        journal: JournalExportPayload? = nil,
                        isDelta: Bool = false,
                        deltaDeletions: [ExportTombstone] = [],
                        corrections: [ExportSuppressionCorrection] = []) throws -> ExportResult {
        let generatedAt = clock.now()
        let writer = CSVWriter()

        // Route measured rows to raw.csv, engine-computed rows to derived.csv, and structured
        // logs (medications/symptoms/workouts/nutrition) to their own events.csv — the CSV
        // export previously omitted logs entirely even though the Sensitive toggle's own copy
        // promises them (DATA-03); JSON already carried them in its `logs` section.
        let rawRows = rawSamples.map { rowFor(sample: $0, scope) }
            + intervalRecords.map { rowFor(interval: $0, scope) }
            + sessions.map { rowFor(session: $0, scope) }
        let derivedRows = derivedValues.map { rowFor(derived: $0, scope) }
            + baselines.map { rowFor(baseline: $0, scope) }
        let regimenNames = Self.regimenNameLookup(adherence: adherence, logging: logging)
        // Journal tags and context intervals join the same events.csv rather than getting their own
        // files (the way hydration did): unlike a drink ledger, both are exactly the shape
        // events.csv already carries — a labelled thing that happened at a time — and a CSV-only
        // consumer should find them beside the symptoms they will be read against. They are here
        // only when the scope opted into sensitive data; `journal` is nil otherwise, so a default
        // export's events.csv is byte-identical to before.
        let eventRows = symptoms.map { rowForEvent(symptom: $0, scope) }
            + adherence.map { rowForEvent(adherence: $0, regimenNames: regimenNames, scope) }
            + workouts.map { rowForEvent(workout: $0, scope) }
            + nutrition.map { rowForEvent(nutrition: $0, scope) }
            + (journal?.entries ?? []).map { rowForEvent(journal: $0, scope) }
            + (journal?.statuses ?? []).map { rowForEvent(contextStatus: $0, scope) }

        // Written and hashed directly, chunk by chunk, so the full CSV is never simultaneously
        // resident as a `String` and a second `Data` copy, and doesn't need a separate
        // whole-buffer hashing pass afterward (PERF-168/170).
        let rawURL = folder.appendingPathComponent("raw.csv")
        let derivedURL = folder.appendingPathComponent("derived.csv")
        let eventsURL = folder.appendingPathComponent("events.csv")
        let rawChecksum = try Self.streamWrite(rawRows, using: writer, to: rawURL)
        let derivedChecksum = try Self.streamWrite(derivedRows, using: writer, to: derivedURL)
        let eventsChecksum = try Self.streamWrite(eventRows, using: writer, to: eventsURL)

        var checksums = [
            "raw.csv": rawChecksum,
            "derived.csv": derivedChecksum,
            "events.csv": eventsChecksum
        ]

        // Hydration rides its own small `hydration_*` CSV set (a drink ledger is a different shape
        // from the 26-column contract, so it gets self-describing tables rather than being forced
        // onto events.csv), written ONLY when the export actually caught drinks — so a CSV export
        // with no hydration is byte-identical to before. This is the CSV analogue of the JSON
        // bundle's absent-not-empty `logs.hydration`, and mirrors how DATA-03 added events.csv.
        // Notes are excluded structurally by the default policy, whose byte-identical redaction
        // manifest (`hydration_redaction.json`) states exactly what the file leaves out.
        var hydrationURLs: [URL] = []
        if let hydration {
            for (name, contents) in HydrationCSVWriter(policy: .default).files(hydration).sorted(by: { $0.key < $1.key }) {
                let url = folder.appendingPathComponent(name)
                let data = Data(contents.utf8)
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.complete])
                try data.write(to: url, options: .completeFileProtection)
                checksums[name] = Self.sha256Hex(data)
                hydrationURLs.append(url)
            }
        }

        // The CSV delta's reconciliation pair (§22.6). Written on EVERY delta run and on no other
        // run: their presence is what tells a CSV consumer this artifact is a delta (the CSV
        // `manifest.json` carries no `is_delta` field), and a header-only file is the affirmative
        // "nothing was removed / nothing flipped" a reconciling consumer needs — see
        // `ExportDeltaCSVWriter`'s doc. Checksummed into the manifest exactly like every other CSV,
        // so tampering or truncation is as detectable here as in raw.csv.
        //
        // What this does NOT give a CSV consumer, stated so nobody reads more into it: a CSV export
        // carries no `previous_manifest_sha`, so the artifacts can be reconciled one by one but the
        // SEQUENCE cannot be proven complete the way `scripts/verify_export_chain.py` proves it for
        // JSON bundles. Delta chaining remains a JSON-bundle property (see `chainSha`).
        var deltaURLs: [URL] = []
        if isDelta {
            for (name, contents) in ExportDeltaCSVWriter()
                .files(deletions: deltaDeletions, corrections: corrections)
                .sorted(by: { $0.key < $1.key }) {
                let url = folder.appendingPathComponent(name)
                let data = Data(contents.utf8)
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.complete])
                try data.write(to: url, options: .completeFileProtection)
                checksums[name] = Self.sha256Hex(data)
                deltaURLs.append(url)
            }
        }

        var counts: [String: Int] = [:]
        addCounts(rawRows.map { $0.metricId }, into: &counts)
        addCounts(derivedRows.map { $0.metricId }, into: &counts)
        addCounts(eventRows.map { $0.metricId }, into: &counts)
        // Disclosed in `per_metric_row_counts` under the same synthetic-id convention the other logs
        // use ("nutrition.entry" etc.), so the CSV manifest discloses drinks the way the JSON one does.
        addCounts((hydration?.entries ?? []).map { _ in "hydration.entry" }, into: &counts)
        let rowCount = rawRows.count + derivedRows.count + eventRows.count + (hydration?.entries.count ?? 0)

        let manifest = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                    checksums: checksums, perMetricRowCounts: counts,
                                    derivedRangeFallbackCount: derivedRangeFallbackCount,
                                    sampleDataRowCount: Self.sampleDataRowCount(
                                        rawSamples: rawSamples, intervalRecords: intervalRecords,
                                        sessions: sessions))
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONCoding.encoder.encode(manifest).write(to: manifestURL, options: .completeFileProtection)

        let job = ExportJob(id: exportId, scope: scope, format: .csv, status: .completed,
                            manifest: manifest, outputPath: folder.path, rowCount: rowCount,
                            startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        // `rowCount` deliberately excludes the delta pair: a tombstone is a record going away, not a
        // record exported, and `runTemplate` reads `rowCount == 0` as `skippedNoData`. Counting
        // removals as exported rows would report "this run moved data" for a run that moved none —
        // and would also stop a deletions-only delta from being re-reported on the next run, which
        // is the property that makes the tombstone set forgiving.
        return ExportResult(job: job,
                            fileURLs: [rawURL, derivedURL, eventsURL] + hydrationURLs + deltaURLs + [manifestURL],
                            rowCount: rowCount)
    }

    // MARK: - JSON

    private func runJSON(scope: ExportScope, exportId: String, folder: URL, startedAt: Date,
                         rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
                         derivedValues: [DerivedValue], baselines: [Baseline],
                         derivedRangeFallbackCount: Int, symptoms: [SymptomEntry], adherence: [AdherenceEvent],
                         workouts: [WorkoutEntry], nutrition: [NutritionEntry],
                         hydration: HydrationExportPayload?,
                         journal: JournalExportPayload? = nil,
                         isDelta: Bool = false, cursorBefore: Date? = nil, cursorAfter: Date? = nil,
                         previousManifestSha: String? = nil,
                         deltaDeletions: [ExportTombstone] = [],
                         corrections: [ExportSuppressionCorrection] = []) throws -> ExportResult {
        let generatedAt = clock.now()

        var counts: [String: Int] = [:]
        addCounts(rawSamples.map { $0.metricId }, into: &counts)
        addCounts(intervalRecords.map { $0.metricId }, into: &counts)
        addCounts(sessions.map { sessionMetricId($0.kind) }, into: &counts)
        addCounts(derivedValues.map { $0.metricId }, into: &counts)
        addCounts(baselines.map { $0.metricId }, into: &counts)
        addCounts(symptoms.map { _ in "symptoms.entry" }, into: &counts)
        addCounts(adherence.map { _ in "medications.adherence" }, into: &counts)
        addCounts(workouts.map { _ in "activity.workout" }, into: &counts)
        addCounts(nutrition.map { _ in "nutrition.entry" }, into: &counts)
        addCounts((hydration?.entries ?? []).map { _ in "hydration.entry" }, into: &counts)
        // Same synthetic-id convention as the other log families ("symptoms.entry" etc.), so the
        // manifest discloses journal rows the way it discloses every other kind. These ids are
        // export-local labels, not registry metrics — the registry's `journal.correlation.*` ids
        // belong to the correlation engine's DERIVED rows, which are a different thing entirely.
        addCounts((journal?.entries ?? []).map { _ in "journal.entry" }, into: &counts)
        addCounts((journal?.statuses ?? []).map { _ in "context.status" }, into: &counts)
        let rowCount = rawSamples.count + intervalRecords.count + sessions.count
            + derivedValues.count + baselines.count
            + symptoms.count + adherence.count + workouts.count + nutrition.count
            + (hydration?.entries.count ?? 0)
            + (journal?.entries.count ?? 0) + (journal?.statuses.count ?? 0)

        let sampleRows = Self.sampleDataRowCount(rawSamples: rawSamples,
                                                 intervalRecords: intervalRecords, sessions: sessions)

        // A single self-contained file cannot checksum itself, so the embedded manifest carries
        // no checksums; the file-level SHA is recorded on the persisted job below.
        let embedded = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                    checksums: [:], perMetricRowCounts: counts,
                                    derivedRangeFallbackCount: derivedRangeFallbackCount,
                                    sampleDataRowCount: sampleRows)
        // `hydrationRedaction: .default` withholds notes structurally (the key is absent, not
        // blanked). The writer adds `logs.hydration` only for a non-empty payload, so a nil/empty
        // one contributes nothing and the pre-hydration goldens stay byte-identical.
        let bundleData = try JSONBundleWriter().data(
            manifest: embedded, rawSamples: rawSamples, intervalRecords: intervalRecords,
            sessions: sessions, derivedValues: derivedValues, baselines: baselines,
            symptoms: symptoms, adherence: adherence, workouts: workouts, nutrition: nutrition,
            isDelta: isDelta, cursorBefore: cursorBefore, cursorAfter: cursorAfter,
            previousManifestSha: previousManifestSha,
            additionalDeletions: deltaDeletions, corrections: corrections,
            hydration: hydration, hydrationRedaction: .default, journal: journal)
        let bundleURL = folder.appendingPathComponent("bundle.json")
        try bundleData.write(to: bundleURL, options: .completeFileProtection)

        let checksums = ["bundle.json": Self.sha256Hex(bundleData)]
        let persisted = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                     checksums: checksums, perMetricRowCounts: counts,
                                     derivedRangeFallbackCount: derivedRangeFallbackCount,
                                     sampleDataRowCount: sampleRows)
        let job = ExportJob(id: exportId, scope: scope, format: .json, status: .completed,
                            manifest: persisted, outputPath: folder.path, rowCount: rowCount,
                            startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
        try exportJobs.insert(job)
        return ExportResult(job: job, fileURLs: [bundleURL], rowCount: rowCount)
    }

    // MARK: - Manifest

    private func makeManifest(exportId: String, scope: ExportScope, generatedAt: Date,
                              checksums: [String: String], perMetricRowCounts: [String: Int],
                              derivedRangeFallbackCount: Int = 0,
                              sampleDataRowCount: Int = 0) -> ExportManifest {
        ExportManifest(
            exportId: exportId,
            schemaVersion: "0.1.0",
            appVersion: appVersion,
            platform: "iOS",
            generatedAt: generatedAt,
            scope: scope,
            dateRange: dateRangeString(scope),
            displayLanguage: scope.language.rawValue,
            unitProfile: scope.unitProfile.rawValue,
            timezonePolicy: "timestamps carry original offsets; day boundaries computed in tz-at-measurement",
            dedupPolicy: dedupPolicyNote(scope),
            perMetricRowCounts: perMetricRowCounts,
            checksums: checksums,
            dataQualityNote: dataQualityNote(derivedRangeFallbackCount: derivedRangeFallbackCount,
                                             sampleDataRowCount: sampleDataRowCount),
            sampleDataRowCount: sampleDataRowCount
        )
    }

    /// How many of the rows about to be written were fabricated by sample mode.
    ///
    /// Read off each row's own `.sampleData` quality flag rather than off an app-level demo flag,
    /// so the manifest describes the FILE rather than the app's current mode — the two disagree
    /// for anyone who explored with sample data before connecting a real source.
    private static func sampleDataRowCount(rawSamples: [RawSample], intervalRecords: [IntervalRecord],
                                           sessions: [Session]) -> Int {
        func isSample(_ provenance: Provenance) -> Bool { provenance.qualityFlags.contains(.sampleData) }
        return rawSamples.filter { isSample($0.provenance) }.count
            + intervalRecords.filter { isSample($0.provenance) }.count
            + sessions.filter { isSample($0.provenance) }.count
    }

    private static let dataQualityNote =
        "Rows reflect stored records only; coverage gaps are not backfilled. Interval aggregates "
        + "carry a 0–1 coverage fraction in the JSON bundle. Derived values and baselines are "
        + "engine-computed, physically separated from raw, and each carries its algorithm id and version."

    /// The base data-quality note, plus a disclosure of how many derived rows in a date-bounded
    /// export were included via best-effort period-key matching rather than a confirmed in-range
    /// check (OPT-143) — today only reachable if a non-`day:`-keyed derived value is ever
    /// produced, since every derived value currently uses `day:` period keys.
    ///
    /// The sample-data sentence leads when present: a reader who takes one thing from this file
    /// must take away that some of it was never measured. The count is also machine-readable as
    /// `sampleDataRowCount`; this is the human-readable half.
    private func dataQualityNote(derivedRangeFallbackCount: Int, sampleDataRowCount: Int = 0) -> String {
        var note = ""
        if sampleDataRowCount > 0 {
            note += "SAMPLE DATA: \(sampleDataRowCount) row(s) in this export were generated by "
                + "BADAN's sample/demo mode and were never measured from a real person or device. "
                + "They are attributed to simulated sources (\"Sample watch (simulated)\" / "
                + "\"Sample phone (simulated)\") and each carries the quality flag 'sampleData'. "
                + "Do not treat them as health measurements. "
        }
        note += Self.dataQualityNote
        if derivedRangeFallbackCount > 0 {
            note += " \(derivedRangeFallbackCount) derived row(s) were included without date-range "
                + "verification because their period key could not be parsed as a calendar day."
        }
        return note
    }

    private func dedupPolicyNote(_ scope: ExportScope) -> String {
        let inclusion = scope.includeSuppressed
            ? "included (each keeps suppressed_by = winning record_id)"
            : "excluded"
        return "suppress-not-delete; identity (metric_id, external_id, source_id), latest-wins; "
            + "suppressed duplicates \(inclusion)."
    }

    private func dateRangeString(_ scope: ExportScope) -> String {
        switch (scope.startDate, scope.endDate) {
        case (nil, nil):
            return "all"
        case let (start, end):
            let lower = start.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? ".."
            let upper = end.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? ".."
            return "\(lower)/\(upper)"
        }
    }

    // MARK: - Row builders

    private func rowFor(sample s: RawSample, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: s.metricId, canonicalValue: s.value, canonicalUnit: s.unit, scope)
        return ExportRow(
            recordId: s.id,
            recordKind: "sample",
            metricId: s.metricId,
            metricDisplay: metricDisplay(s.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(s.value),
            canonicalUnit: s.unit,
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.startAt, tzId: s.tzId),
            timestampEnd: s.endAt.map { CSVWriter.iso8601($0, tzId: s.tzId) },
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.provenance.recordedAt, tzId: s.tzId),
            sourceApp: s.provenance.sourceId,
            sourceDevice: s.provenance.deviceId,
            ingestionPath: s.provenance.ingestionPath.rawValue,
            sourceExternalId: s.provenance.externalId,
            importBatchId: s.provenance.importBatchId,
            qualityFlags: qualityFlagsString(s.provenance.qualityFlags, tzId: s.tzId),
            suppressedBy: s.provenance.suppressedBy
        )
    }

    private func rowFor(interval r: IntervalRecord, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: r.metricId, canonicalValue: r.value, canonicalUnit: r.unit, scope)
        return ExportRow(
            recordId: r.id,
            recordKind: "interval",
            metricId: r.metricId,
            metricDisplay: metricDisplay(r.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(r.value),
            canonicalUnit: r.unit,
            valueType: "aggregate",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(r.startAt, tzId: r.tzId),
            timestampEnd: CSVWriter.iso8601(r.endAt, tzId: r.tzId),
            timezone: r.tzId,
            recordedAt: CSVWriter.iso8601(r.provenance.recordedAt, tzId: r.tzId),
            sourceApp: r.provenance.sourceId,
            sourceDevice: r.provenance.deviceId,
            ingestionPath: r.provenance.ingestionPath.rawValue,
            sourceExternalId: r.provenance.externalId,
            importBatchId: r.provenance.importBatchId,
            qualityFlags: qualityFlagsString(r.provenance.qualityFlags, tzId: r.tzId),
            suppressedBy: r.provenance.suppressedBy
        )
    }

    private func rowFor(session s: Session, _ scope: ExportScope) -> ExportRow {
        let metricId = sessionMetricId(s.kind)
        return ExportRow(
            recordId: s.id,
            recordKind: "session",
            metricId: metricId,
            metricDisplay: sessionDisplay(s.kind, scope.language),
            value: CSVWriter.decimal(s.durationSeconds),
            unit: "s",
            canonicalValue: CSVWriter.decimal(s.durationSeconds),
            canonicalUnit: "s",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.startAt, tzId: s.tzId),
            timestampEnd: CSVWriter.iso8601(s.endAt, tzId: s.tzId),
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.provenance.recordedAt, tzId: s.tzId),
            sourceApp: s.provenance.sourceId,
            sourceDevice: s.provenance.deviceId,
            ingestionPath: s.provenance.ingestionPath.rawValue,
            sourceExternalId: s.provenance.externalId,
            importBatchId: s.provenance.importBatchId,
            qualityFlags: qualityFlagsString(s.provenance.qualityFlags, tzId: s.tzId),
            suppressedBy: s.provenance.suppressedBy
        )
    }

    private func rowFor(derived v: DerivedValue, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: v.metricId, canonicalValue: v.value, canonicalUnit: v.unit, scope)
        let start = periodStartDate(v.periodKey) ?? v.computedAt
        return ExportRow(
            recordId: v.id,
            recordKind: "derived",
            metricId: v.metricId,
            metricDisplay: metricDisplay(v.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(v.value),
            canonicalUnit: v.unit,
            valueType: "derived",
            isDerived: true,
            timestampStart: CSVWriter.iso8601(start, tzId: "UTC"),
            timezone: "UTC",
            recordedAt: CSVWriter.iso8601(v.updatedAt, tzId: "UTC"),
            sourceDevice: v.originDeviceId,
            ingestionPath: IngestionPath.derived.rawValue,
            qualityFlags: v.provisional ? QualityFlag.estimate.rawValue : nil,
            confidence: v.confidence.map { CSVWriter.decimal($0) },
            algorithmId: v.algorithmId,
            algorithmVersion: v.algorithmVersion
        )
    }

    private func rowFor(baseline b: Baseline, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: b.metricId, canonicalValue: b.center, canonicalUnit: b.unit, scope)
        return ExportRow(
            recordId: b.id,
            recordKind: "baseline",
            metricId: b.metricId,
            metricDisplay: metricDisplay(b.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(b.center),
            canonicalUnit: b.unit,
            valueType: "derived",
            isDerived: true,
            timestampStart: CSVWriter.iso8601(b.validFrom, tzId: "UTC"),
            timezone: "UTC",
            recordedAt: CSVWriter.iso8601(b.computedAt, tzId: "UTC"),
            ingestionPath: IngestionPath.derived.rawValue,
            qualityFlags: b.provisional ? QualityFlag.provisionalBaseline.rawValue : nil,
            algorithmId: "baseline.\(b.method.rawValue)",
            algorithmVersion: b.algorithmVersion
        )
    }

    // MARK: - Events (structured logs projected onto the CSV contract, DATA-03)

    /// `record_kind = "event"` rows for the four structured-log types, mapped onto the same
    /// 24-column contract used by samples/intervals/sessions/derived/baselines. Mapping choices
    /// (documented per type below) favor a defensible, always-populated `value`/`unit` over
    /// perfect fidelity — richer detail (triggers, notes, all six macros) already lives in the
    /// JSON bundle's `logs` section; this file exists so a CSV-only export isn't missing the
    /// records its own Sensitive-toggle copy promises.

    /// Symptom entries: `value` is the 0–10 severity (the one number a symptom entry always
    /// has); `metric_display` is the symptom's own bilingual name (or the free-text custom
    /// label). No physical unit applies, so `unit`/`canonical_unit` use "level" — an ordinal
    /// scale token, distinct from "score" (reserved for derived/baseline scores elsewhere in
    /// this contract).
    private func rowForEvent(symptom s: SymptomEntry, _ scope: ExportScope) -> ExportRow {
        let display = SymptomDictionary.shared.displayName(forId: s.symptomId, customLabel: s.customLabel)
            .resolved(scope.language)
        return ExportRow(
            recordId: s.id,
            recordKind: "event",
            metricId: "symptoms.entry",
            metricDisplay: display,
            value: CSVWriter.decimal(Double(s.severity)),
            unit: "level",
            canonicalValue: CSVWriter.decimal(Double(s.severity)),
            canonicalUnit: "level",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.occurredAt, tzId: s.tzId),
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.updatedAt, tzId: s.tzId),
            sourceDevice: s.originDeviceId,
            ingestionPath: IngestionPath.manual.rawValue
        )
    }

    /// Adherence events: `value` is 1 for a taken/late dose, 0 for a skip — "was this dose
    /// taken" is the one boolean every adherence event answers unambiguously. The actual status
    /// (and skip reason, if any) is preserved in `quality_flags` rather than discarded, since
    /// the contract has no dedicated status column for events. `metric_display` resolves the
    /// regimen's name via `regimenNames` (looked up once per run, not per row).
    private func rowForEvent(adherence e: AdherenceEvent, regimenNames: [String: String], _ scope: ExportScope) -> ExportRow {
        let display = regimenNames[e.regimenId] ?? e.regimenId
        let taken = e.kind == .taken || e.kind == .late
        var flags = e.kind.rawValue
        if let reason = e.skipReason { flags += ";skip_reason:\(reason.rawValue)" }
        return ExportRow(
            recordId: e.id,
            recordKind: "event",
            metricId: "medications.adherence",
            metricDisplay: display,
            value: CSVWriter.decimal(taken ? 1 : 0),
            unit: "bool",
            canonicalValue: CSVWriter.decimal(taken ? 1 : 0),
            canonicalUnit: "bool",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(e.scheduledFor ?? e.occurredAt, tzId: e.tzId),
            timezone: e.tzId,
            recordedAt: CSVWriter.iso8601(e.occurredAt, tzId: e.tzId),
            sourceDevice: e.originDeviceId,
            ingestionPath: IngestionPath.manual.rawValue,
            qualityFlags: flags
        )
    }

    /// Workouts: `value` is the session duration in seconds — the one measurement every workout
    /// always has (kcal/distance are optional). Unlike sleep/HealthKit sessions (already routed
    /// to raw.csv's "session" rows via `MeasurementRepository.sessions`), manually-logged
    /// `WorkoutEntry` rows were never represented in CSV at all before this fix, so there's no
    /// duplication risk in choosing the same duration-based shape here. Optional kcal/distance
    /// are preserved in `quality_flags` rather than silently dropped.
    private func rowForEvent(workout w: WorkoutEntry, _ scope: ExportScope) -> ExportRow {
        var flags: [String] = []
        if let kcal = w.energyKcal { flags.append("kcal:\(CSVWriter.decimal(kcal))") }
        if let distance = w.distanceM { flags.append("distance_m:\(CSVWriter.decimal(distance))") }
        return ExportRow(
            recordId: w.id,
            recordKind: "event",
            metricId: "activity.workout",
            metricDisplay: WorkoutActivity.label(forStored: w.activityType).resolved(scope.language),
            value: CSVWriter.decimal(w.durationSeconds),
            unit: "s",
            canonicalValue: CSVWriter.decimal(w.durationSeconds),
            canonicalUnit: "s",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(w.startAt, tzId: w.tzId),
            timestampEnd: CSVWriter.iso8601(w.endAt, tzId: w.tzId),
            timezone: w.tzId,
            recordedAt: CSVWriter.iso8601(w.updatedAt, tzId: w.tzId),
            sourceDevice: w.originDeviceId,
            ingestionPath: w.ingestionPath.rawValue,
            qualityFlags: flags.isEmpty ? nil : flags.joined(separator: ";")
        )
    }

    /// Nutrition entries: `value` is kcal (0 when not entered — the meal was still logged, just
    /// without an energy estimate; `low_detail` in `quality_flags` distinguishes that from a
    /// confirmed zero). `metric_display` is the entry's own description, mapped through
    /// `WaterEntryIdentity` so a quick-logged water entry reads as "Water"/"ماء" in the export's
    /// own `scope.language` rather than whatever language it happened to be logged in (EDGE-17).
    private func rowForEvent(nutrition n: NutritionEntry, _ scope: ExportScope) -> ExportRow {
        var flags: [String] = ["meal:\(n.mealType.rawValue)"]
        if n.lowDetail { flags.append("low_detail") }
        return ExportRow(
            recordId: n.id,
            recordKind: "event",
            metricId: "nutrition.entry",
            metricDisplay: WaterEntryIdentity.displayDescription(n.description, language: scope.language),
            value: CSVWriter.decimal(n.energyKcal ?? 0),
            unit: "kcal",
            canonicalValue: CSVWriter.decimal(n.energyKcal ?? 0),
            canonicalUnit: "kcal",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(n.occurredAt, tzId: n.tzId),
            timezone: n.tzId,
            recordedAt: CSVWriter.iso8601(n.updatedAt, tzId: n.tzId),
            sourceDevice: n.originDeviceId,
            ingestionPath: IngestionPath.manual.rawValue,
            qualityFlags: flags.joined(separator: ";")
        )
    }

    /// Journal entries (EPIC-29): `value` is the assertion the row makes — 1 for a `boolean` tag
    /// ("it happened"), the count or amount otherwise — and `unit` follows the entry's own
    /// `valueKind`, so a nap's 45 lands as minutes and two coffees as a unitless count.
    ///
    /// The `boolean` → 1 mapping is a CSV-contract accommodation (the value column is always
    /// populated), not a claim that the behavior happened exactly once; `value_kind:boolean` in
    /// `quality_flags` is what tells a consumer to read the 1 as a yes. The JSON bundle, which has
    /// no such constraint, keeps `value` null for those rows instead.
    ///
    /// `recalled` rides `quality_flags` when the entry was logged after the fact (yesterday
    /// recall). It is disclosure, not a discount — the row counts exactly like a live one — and it
    /// stays checkable because `timestamp_start` (when it happened) and `recorded_at` (when it was
    /// typed) are both in the row.
    private func rowForEvent(journal e: JournalEntry, _ scope: ExportScope) -> ExportRow {
        let display = BehaviorDictionary.shared.displayName(forId: e.behaviorId, customLabel: e.customLabel)
            .resolved(scope.language)
        let value: Double
        let unit: String
        switch e.valueKind {
        case .boolean: value = 1; unit = "bool"
        case .count: value = e.value ?? 0; unit = "count"
        case .quantity: value = e.value ?? 0; unit = e.unit ?? ""
        }
        var flags = ["value_kind:\(e.valueKind.rawValue)"]
        if e.isRecalled { flags.append("recalled") }
        return ExportRow(
            recordId: e.id,
            recordKind: "event",
            metricId: "journal.entry",
            metricDisplay: display,
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(value),
            canonicalUnit: unit,
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(e.occurredAt, tzId: e.tzId),
            timezone: e.tzId,
            recordedAt: CSVWriter.iso8601(e.provenance.recordedAt, tzId: e.tzId),
            sourceApp: e.provenance.sourceId,
            sourceDevice: e.provenance.deviceId ?? e.originDeviceId,
            ingestionPath: e.provenance.ingestionPath.rawValue,
            qualityFlags: flags.joined(separator: ";")
        )
    }

    /// Context statuses (EPIC-29 / §9.10): the interval lives in `timestamp_start`/`timestamp_end`,
    /// and `value` is a flat 1 meaning "this circumstance was declared".
    ///
    /// Duration is deliberately NOT the value. An open-ended status has no end, and computing one
    /// from "now" would write an end instant the user never declared into a file they may hand to
    /// someone else — so an ongoing status exports with an empty `timestamp_end`, which is the
    /// honest cell, and `open_ended` in `quality_flags` names it rather than leaving a consumer to
    /// infer the blank.
    ///
    /// Nothing about confidence appears on this row. A status annotates how a value should be READ
    /// and never alters one, so there is no adjusted number here to export.
    private func rowForEvent(contextStatus s: ContextStatus, _ scope: ExportScope) -> ExportRow {
        var flags: [String] = []
        if let statusId = s.statusId { flags.append("status:\(statusId)") }
        if s.isOpenEnded { flags.append("open_ended") }
        return ExportRow(
            recordId: s.id,
            recordKind: "event",
            metricId: "context.status",
            metricDisplay: s.displayLabel.resolved(scope.language),
            value: CSVWriter.decimal(1),
            unit: "bool",
            canonicalValue: CSVWriter.decimal(1),
            canonicalUnit: "bool",
            valueType: "raw",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(s.startAt, tzId: s.tzId),
            timestampEnd: s.endAt.map { CSVWriter.iso8601($0, tzId: s.tzId) },
            timezone: s.tzId,
            recordedAt: CSVWriter.iso8601(s.provenance.recordedAt, tzId: s.tzId),
            sourceApp: s.provenance.sourceId,
            sourceDevice: s.provenance.deviceId ?? s.originDeviceId,
            ingestionPath: s.provenance.ingestionPath.rawValue,
            qualityFlags: flags.isEmpty ? nil : flags.joined(separator: ";")
        )
    }

    /// Regimen id -> name, resolved once per run instead of once per adherence row. Best-effort:
    /// a lookup failure (or a since-deleted regimen) falls back to the bare regimen id rather
    /// than failing the export.
    private static func regimenNameLookup(adherence: [AdherenceEvent], logging: LoggingRepository) -> [String: String] {
        guard !adherence.isEmpty else { return [:] }
        let regimens = (try? logging.regimens(activeOnly: false)) ?? []
        return Dictionary(uniqueKeysWithValues: regimens.map { ($0.id, $0.name) })
    }

    // MARK: - Unit profile & display

    /// The (value, unit) for the display columns. Canonical unless the scope asks for the display
    /// profile, in which case the metric's primary display unit is used; canonical columns are
    /// unaffected. Unknown/incompatible units fall back to canonical rather than fail the export.
    private func displayValueUnit(metricId: String, canonicalValue: Double, canonicalUnit: String,
                                  _ scope: ExportScope) -> (value: Double, unit: String) {
        guard scope.unitProfile == .display else { return (canonicalValue, canonicalUnit) }
        let target = registry.definitionOrFallback(metricId).primaryDisplayUnit
        guard !target.isEmpty, target != canonicalUnit,
              let converted = try? Units.convert(canonicalValue, from: canonicalUnit, to: target) else {
            return (canonicalValue, canonicalUnit)
        }
        return (converted, target)
    }

    private func metricDisplay(_ metricId: String, _ scope: ExportScope) -> String {
        registry.definitionOrFallback(metricId).displayName.resolved(scope.language)
    }

    /// Renders a row's quality flags, also appending `.tzAssumed` when `tzId` doesn't
    /// resolve to a real time zone — `CSVWriter.iso8601`/`TimestampFormatting` silently render
    /// such rows in UTC, and this makes that substitution visible on the row itself rather than
    /// a silent, undisclosed correction (OPT-151).
    private func qualityFlagsString(_ flags: [QualityFlag], tzId: String) -> String? {
        var all = flags
        if TimeZone(identifier: tzId) == nil, !all.contains(.tzAssumed) {
            all.append(.tzAssumed)
        }
        return all.isEmpty ? nil : all.map { $0.rawValue }.joined(separator: ";")
    }

    // MARK: - Scope helpers

    /// The metric ids to query, honoring an explicit metric picklist and/or a family filter.
    private func metricIdsInScope(_ scope: ExportScope) -> [String] {
        if let picked = scope.metricIds, !picked.isEmpty {
            guard let families = scope.families, !families.isEmpty else { return picked }
            let familySet = Set(families)
            return picked.filter { registry.definition($0).map { familySet.contains($0.family) } ?? true }
        }
        var defs = registry.all
        if let families = scope.families, !families.isEmpty {
            let familySet = Set(families)
            defs = defs.filter { familySet.contains($0.family) }
        }
        return defs.map { $0.metricId }
    }

    /// Sensitive-class metrics are only gathered when the scope opts into sensitive data.
    private func metricAllowed(_ metricId: String, _ scope: ExportScope) -> Bool {
        if scope.includeSensitive { return true }
        return registry.definition(metricId)?.sensitiveClass != .sensitivePlus
    }

    private func sourceAllowed(_ provenance: Provenance, _ scope: ExportScope) -> Bool {
        guard let sources = scope.sourceIds, !sources.isEmpty else { return true }
        return sources.contains(provenance.sourceId)
    }

    private func sessionInScope(_ session: Session, _ scope: ExportScope) -> Bool {
        let metricId = sessionMetricId(session.kind)
        if let picked = scope.metricIds, !picked.isEmpty, !picked.contains(metricId) { return false }
        if let families = scope.families, !families.isEmpty {
            if !families.contains(sessionFamily(metricId)) { return false }
        }
        return true
    }

    /// The family for a (possibly synthetic) session metric id, routed through the registry —
    /// the single authoritative source also used by `metricIdsInScope` — rather than re-deriving
    /// it from a hand-rolled string split. Synthetic session ids (`sleep.session`,
    /// `activity.workout_session`) aren't registered as real metrics, so they fall back to the
    /// dot-prefix convention (OPT-145).
    private func sessionFamily(_ metricId: String) -> String {
        if let family = registry.definition(metricId)?.family { return family }
        return metricId.split(separator: ".").first.map(String.init) ?? "other"
    }

    /// A narrowed metric picklist excludes logs entirely; a family filter includes a log
    /// category only when its family is selected; an unnarrowed scope includes all logs.
    private func logFamilyIncluded(_ family: String, _ scope: ExportScope) -> Bool {
        if let picked = scope.metricIds, !picked.isEmpty { return false }
        if let families = scope.families, !families.isEmpty { return families.contains(family) }
        return true
    }

    /// Best-effort period date filter: applies the scope range only when a day-keyed period can
    /// be parsed; otherwise the value is included (its period is not a simple calendar day).
    private func derivedInRange(_ v: DerivedValue, _ scope: ExportScope) -> Bool {
        guard scope.startDate != nil || scope.endDate != nil else { return true }
        guard let day = periodStartDate(v.periodKey) else { return true }
        if let start = scope.startDate, day < start { return false }
        if let end = scope.endDate, day > end { return false }
        return true
    }

    /// True when `v` passed `derivedInRange` only via its best-effort fallback — a date range
    /// was requested but `v.periodKey` couldn't be parsed as a `day:` key, so it was included
    /// without actually being range-checked. Counted so the manifest can disclose how many rows
    /// in a date-bounded export weren't confirmed to be in range (OPT-143).
    private func derivedIncludedByRangeFallback(_ v: DerivedValue, _ scope: ExportScope) -> Bool {
        guard scope.startDate != nil || scope.endDate != nil else { return false }
        return periodStartDate(v.periodKey) == nil
    }

    // MARK: - Synthetic ids & period parsing

    private func sessionMetricId(_ kind: SessionKind) -> String {
        switch kind {
        case .sleepPrimary, .sleepNap: return "sleep.session"
        case .workout: return "activity.workout_session"
        }
    }

    private func sessionDisplay(_ kind: SessionKind, _ language: AppLanguage) -> String {
        switch kind {
        case .sleepPrimary: return language == .ar ? "نوم" : "Sleep"
        case .sleepNap: return language == .ar ? "قيلولة" : "Nap"
        case .workout: return language == .ar ? "تمرين" : "Workout"
        }
    }

    /// Parses the calendar day from a `day:YYYY-MM-DD` period key (UTC midnight). Other period
    /// shapes (session:, week:) return nil and are treated as always-in-range. Delegates to
    /// `DayAttribution`'s existing `DateComponents`-based parser instead of constructing a fresh
    /// `DateFormatter` per call, which otherwise dominates large derived-value-heavy exports
    /// (PERF-161/171/197).
    private func periodStartDate(_ periodKey: String) -> Date? {
        guard periodKey.hasPrefix("day:") else { return nil }
        let day = String(periodKey.dropFirst("day:".count))
        return DayAttribution.date(fromDayKey: day, tz: "UTC")
    }

    // MARK: - Counting & checksums

    private func addCounts(_ metricIds: [String], into counts: inout [String: Int]) {
        for id in metricIds { counts[id, default: 0] += 1 }
    }

    /// The incremental-export inclusion test (EPIC-17). A `nil` watermark (every non-delta run)
    /// includes everything, so the plain export path is unchanged. Strictly greater than the
    /// watermark, matching `ExportCursorRepository.advance`'s forward-only guard: the cursor is
    /// advanced to the max `ingested_at` this run *included*, so the next run's `> watermark`
    /// window starts exactly one past the last row already delivered — a row can neither be
    /// skipped (the query has no upper bound, so nothing ingested after the watermark is missed)
    /// nor duplicated (the boundary row is `== watermark`, not `>`).
    private static func ingestedAfter(_ ingestedAt: Date, _ watermark: Date?) -> Bool {
        guard let watermark else { return true }
        return ingestedAt > watermark
    }

    /// Projects a dedup-journal decision onto the delta `corrections[]` record (§22.6). The
    /// suppressed row is the one whose authority flipped; `suppressedBy` is the winner when the
    /// decision is live, or `nil` when it was reversed (the row wins again). `changedAt` is the
    /// most recent flip instant — the reversal if there was one, else the original decision — so a
    /// consumer applies the CURRENT net state, not an intermediate one it never saw.
    private static func correction(from d: ReconciliationDecision) -> ExportSuppressionCorrection {
        ExportSuppressionCorrection(recordId: d.suppressedRecordId,
                                    suppressedBy: d.isReversed ? nil : d.keptRecordId,
                                    changedAt: d.reversedAt ?? d.decidedAt)
    }

    /// The delta-chain link a successful run stores on the cursor and the ledger: `sha256` of the
    /// delivered bundle file (JSON), which a consumer recomputes from the file to verify the chain.
    /// For CSV — several files, no single bundle, and not a delta-chain vehicle — falls back to the
    /// sha of the `ExportManifest` struct so the ledger field stays populated.
    private static func chainSha(for result: ExportResult) -> ManifestDigest? {
        if let bundleSha = result.job.manifest?.checksums["bundle.json"],
           let digest = ManifestDigest(hex: bundleSha) {
            return digest
        }
        return result.job.manifest.flatMap {
            ManifestDigest(hex: Self.sha256Hex(Data(JSONCoding.encode($0).utf8)))
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates `url`, streams `rows` to it via `writer.write(_:to:)`, and returns the
    /// incrementally-computed SHA-256 hex digest (PERF-168/170).
    private static func streamWrite(_ rows: [ExportRow], using writer: CSVWriter, to url: URL) throws -> String {
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        return try writer.write(rows, to: handle)
    }
}

// MARK: - EPIC-09/13/14/15/17: template-driven runs, delivery, and the ExportRun ledger
//
// Everything below turns a saved `ExportTemplate` into an artifact that has actually been
// delivered and recorded. It sits ON TOP of `run(scope:format:passphrase:ingestedSince:)` above —
// that function is still the one place gather + generation + encryption + cleanup happen, and it
// is unchanged for the plain UI export path. This layer only adds what a *template* run needs:
// range/cursor resolution, run-time sensitive re-confirmation, delivery to a destination, the
// `ExportRun` trust ledger, and the incremental cursor.
//
// Two disciplines run through all of it and are load-bearing, not stylistic:
//
//  1. EVERY attempt writes exactly one `ExportRun` (§9.5), including an attempt refused before a
//     single byte was generated. A run that leaves no ledger row is the precise HAE failure this
//     subsystem exists to make impossible — "it just never happened and nothing said so."
//
//  2. The cursor moves ONLY after a run has both succeeded AND been handed off, and only to a
//     watermark every unexported row sits above. This is the same two-phase-commit discipline as
//     Phase 0's HealthKit anchors (DATA-08) and Health Connect change tokens: never move a
//     watermark past data you have not durably handed off. Phase 0's audit found a HIGH-severity
//     bug where Android advanced a cursor past records it had dropped; the guard here — advance to
//     `result.maxIngestedAt`, computed over the rows the file contains and never over the rows the
//     query could have returned — is what keeps that from recurring.
//
//     There are exactly two writes, and they differ because the runs differ. A real delta closes at
//     `result.maxIngestedAt`. The no-cursor FALLBACK run — bounded on the measured axis, so no max
//     `ingested_at` describes it safely — instead BOOTSTRAPS the checkpoint at the fallback
//     window's start, which is the newest watermark that still cannot skip a row that arrived
//     during the window. Without that second write the first delta run could never create a
//     checkpoint and every run after it fell back forever; see the bootstrap comment in
//     `runTemplate` for the full argument.
extension ExportRunner {

    /// The outcome of one template run.
    ///
    /// `run` is ALWAYS present and already persisted — see discipline (1) above.
    struct TemplateRunResult {
        let run: ExportRun
        /// The generated artifact, when generation got that far. `nil` for a pre-generation refusal.
        let result: ExportResult?
        /// The delivery receipt, when a delivery was attempted. `nil` for a pre-generation refusal
        /// and for the share-sheet destination (whose "delivery" is the UI presenting a share
        /// sheet over the temp files, not a copy this layer performs).
        let receipt: ExportDeliveryReceipt?
        /// Set when a `sinceLastRun` template ran with no cursor and fell back to `lastNDays`.
        /// The caller MUST surface this — a silent fallback is exactly the HAE failure mode §12
        /// EPIC-09's input rule forbids. It is ALSO recorded machine-readably as
        /// `run.errorCode == .cursorMissing` on the (successful) ledger row, so the notice reaches
        /// Export Health and a backup, not only this return value.
        var cursorFallbackNotice: Bool = false
    }

    /// How many days a `sinceLastRun` template falls back to when it has no cursor yet. Matches the
    /// Last-30 Quick Export preset (and `ExportManageService`'s own fallback) so a first delta run
    /// produces a familiar-sized file rather than all of history — a safety net, not a full backfill.
    ///
    /// It is also where the resulting chain BEGINS: a delivered fallback run checkpoints at the
    /// start of this window, so anything ingested before it is outside the chain as well as outside
    /// the file. That is the bound the fallback notice is disclosing, said once in both directions.
    static let cursorMissingFallbackDays = 30

    /// Run one template end to end: resolve → deliver → record. Never throws — every failure mode
    /// is a recorded `ExportRun`, because a thrown error a caller might swallow is the opposite of
    /// the trust ledger this returns.
    ///
    /// - Parameters:
    ///   - consent: the run-time sensitive re-confirmation (§9.3). Required, and freshly checked
    ///     HERE — not at template-save time — whenever `template.scope.includeSensitive` is true.
    ///     A template that will one day fire from a schedule or a Shortcut must not carry standing
    ///     permission to export meds/symptoms.
    ///   - passphrase: the encryption passphrase, forwarded to `run` unchanged. A sensitive scope
    ///     needs BOTH a fresh `consent` and a valid passphrase; they gate independently.
    ///   - attempt: 0 for a first attempt, incremented by a caller retrying a failed run. A retry
    ///     is idempotent by construction: the cursor only advanced on the prior run if it
    ///     succeeded, so a retry re-reads the SAME watermark and re-exports the SAME window — it
    ///     can neither skip nor duplicate rows.
    func runTemplate(_ template: ExportTemplate, trigger: ExportTrigger,
                     consent: SensitiveRunConsent? = nil, passphrase: String? = nil,
                     timeZone: TimeZone = .current, attempt: Int = 0) async -> TemplateRunResult {
        let startedAt = clock.now()
        let runId = ULID.newID()

        guard let runs = self.runs, let cursors = self.cursors, let destinations = self.destinations else {
            // A runner built without the template collaborators cannot honor this call. Returned
            // as a synthetic (unpersisted) failed result rather than crashing, so a misconfigured
            // call site is diagnosable; there is no ledger to write it to by definition.
            let run = ExportRun(id: runId, templateId: template.id, trigger: trigger,
                                startedAt: startedAt, finishedAt: clock.now(),
                                outcome: .failedGeneration, errorCode: .unknown,
                                errorDetail: ExportErrorDetail(stage: .finalizing, attempt: attempt))
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }

        // Reconcile any job stranded `running` by a past crash before starting a new one — the
        // same two observation points `ExportJobRepository.markStaleRunningAsFailed` is documented
        // to be called from (EDGE-02a).
        try? exportJobs.markStaleRunningAsFailed()

        // 1. Destination. A template need not pin one (the user picks at run time); absent, it is
        //    the share sheet — a real destination row, not "no destination" (§9.4).
        let destinationId = template.destinationId ?? ExportDestination.shareSheetId
        let destination = (try? destinations.destination(id: destinationId)) ?? nil
        guard let destination else {
            // The row was deleted out from under the template. Fail loudly in the ledger rather
            // than silently redirecting the user's data somewhere they did not choose
            // (`ExportDestinationRepository.softDelete`'s stated contract). No `destinationMissing`
            // code exists, and `.destinationUnreachable` is the honest reading: BADAN cannot reach
            // a destination that is not there.
            let run = record(runs, id: runId, template: template, trigger: trigger, jobId: nil,
                             startedAt: startedAt, outcome: .failedGeneration,
                             errorCode: .destinationUnreachable, stage: .finalizing, attempt: attempt,
                             destinationId: destinationId)
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }

        // 2. Run-time sensitive re-confirmation (§9.3). `scopeForRun` is the ONLY way to get a
        //    sensitive scope out of a template, and it throws rather than silently narrowing — a
        //    quietly de-sensitized export would hand the user a file missing the records they
        //    asked for, with nothing saying so.
        let resolvedScope: ExportScope
        do {
            resolvedScope = try template.scopeForRun(consent: consent, now: startedAt)
        } catch {
            let run = record(runs, id: runId, template: template, trigger: trigger, jobId: nil,
                             startedAt: startedAt, outcome: .failedGeneration,
                             errorCode: .sensitiveConfirmationMissing, stage: .gathering, attempt: attempt,
                             destinationId: destinationId)
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }

        // 3. Range + cursor. `sinceLastRun` with no cursor falls back to `lastNDays` WITH A NOTICE
        //    (never a silent all-history dump).
        let cursor = (try? cursors.cursor(templateId: template.id, destinationId: destinationId)) ?? nil
        let plan = Self.resolveRange(template.rangeRule, scope: resolvedScope, cursor: cursor, now: startedAt)

        // 4. Generate. `.raw` templates reuse `run` verbatim; `.bucketed` templates route through
        //    the aggregation path. A `sinceLastRun` delta passes its ingested watermark to `run`
        //    (and a date-less scope), so the delta is taken on the ingested axis, never the
        //    measured one (see `run`'s `ingestedSince` doc).
        let result: ExportResult
        do {
            switch template.aggregation {
            case .raw:
                // A delta carries the PRIOR run's bundle sha into this bundle's manifest as
                // `previous_manifest_sha` — the chain link `verify_export_chain.py` walks. Read off
                // the cursor (which stored it on the last successful delivery), so a retry that
                // re-reads the same cursor re-emits the same link: the chain stays idempotent.
                result = try run(scope: plan.scope, format: template.format,
                                 passphrase: passphrase, ingestedSince: plan.ingestedSince,
                                 previousManifestSha: cursor?.lastManifestSha?.hex)
            case .bucketed(let bucket, let method):
                result = try runAggregated(scope: plan.scope, template: template, bucket: bucket,
                                           method: method, passphrase: passphrase,
                                           ingestedSince: plan.ingestedSince, startedAt: startedAt)
            }
        } catch let error as ExportRunError where error == .sensitiveExportRequiresPassphrase {
            let run = record(runs, id: runId, template: template, trigger: trigger, jobId: nil,
                             startedAt: startedAt, outcome: .failedGeneration,
                             errorCode: .passphraseMissing, stage: .encrypting, attempt: attempt,
                             destinationId: destinationId, cursorBefore: plan.cursorBefore)
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        } catch {
            // Generation itself failed (gather, write, encrypt). `run` already marked the
            // `export_jobs` row `.failed` and removed the folder; this records the ledger side.
            let run = record(runs, id: runId, template: template, trigger: trigger, jobId: nil,
                             startedAt: startedAt, outcome: .failedGeneration,
                             errorCode: .writeFailed, stage: .writing, attempt: attempt,
                             destinationId: destinationId, cursorBefore: plan.cursorBefore)
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }

        // 5. Deliver.
        let receipt = await deliver(result: result, template: template, destination: destination,
                                    plan: plan, runDate: startedAt, timeZone: timeZone, attempt: attempt)

        // Persist the destination's concluded status (a delivery is also a reachability signal).
        if destination.kind.leavesDevice || receipt.destinationStatus != .ok {
            try? destinations.updateStatus(id: destinationId, status: receipt.destinationStatus,
                                           checkedAt: clock.now())
        }

        // 6. Ledger + cursor (two-phase commit).
        // The chain link is the delivered BUNDLE'S sha, not the sha of the `ExportManifest` struct:
        // it is the value a consumer recomputes from the file on disk, so the next run's
        // `previous_manifest_sha` (read back off this cursor) matches `sha256(bundle.json)` and
        // `verify_export_chain.py` can walk the chain from the artifacts alone. Falls back to the
        // struct sha for a format with no single bundle file (CSV), which is not a chain vehicle.
        let manifestSha = Self.chainSha(for: result)
        // A delivered run that carried no rows is "there was nothing to export" (§9.5
        // `skippedNoData`), not a plain success — so an automation that legitimately had nothing to
        // do is distinguishable in Export Health from one that moved data. Matches
        // `ExportManageService`'s rowCount==0 mapping.
        let effectiveOutcome: ExportOutcome =
            (receipt.outcome == .success && result.rowCount == 0) ? .skippedNoData : receipt.outcome

        // A `.success` receipt is not by itself proof that anybody received anything. Every
        // destination kind copies or uploads the artifacts somewhere durable EXCEPT the share
        // sheet, whose "delivery" is the UI presenting a sheet over the runner's temp folder — real
        // when a person is there, and nobody at all when an unattended automation fires it. The
        // receipt reports `.success` with a byte count either way (see `deliver`), so a checkpoint
        // that trusted that word would close a window over files that were then deleted with the
        // temp folder. The cursor asks the harder question instead.
        let handedOff = destination.kind != .shareSheet || trigger.isAttended
        var cursorAfter: Date?
        if effectiveOutcome == .success, template.rangeRule == .sinceLastRun, handedOff {
            if !plan.fellBackFromSinceLastRun, let watermark = result.maxIngestedAt {
                // TWO-PHASE COMMIT (the DATA-08 parallel): the watermark moves only now, after a
                // delivery that fully succeeded, and only to a value computed over the rows the file
                // actually contains (`result.maxIngestedAt`). `advance` is itself forward-only, so an
                // out-of-order retry reporting an older watermark is refused, not obeyed. Nothing here
                // can move the cursor past a row this run dropped.
                _ = try? cursors.advance(templateId: template.id, destinationId: destinationId,
                                         to: watermark, lastRunId: runId, manifestSha: manifestSha,
                                         now: clock.now())
                cursorAfter = watermark
            } else if plan.fellBackFromSinceLastRun, let bootstrap = plan.scope.startDate {
                // BOOTSTRAP (EPIC-17's missing first step). The no-cursor fallback used to establish
                // nothing, and both cursor-writing call sites refused to write on it — so the FIRST
                // delta run could not create a checkpoint, every later run therefore found none and
                // fell back too, and the delta chain `scripts/verify_export_chain.py` exists to walk
                // could never be produced by the shipped app at all. A permanent deadlock, disclosed
                // each time as a one-off notice.
                //
                // The watermark is the fallback WINDOW'S START, not `result.maxIngestedAt`, and the
                // difference is the whole correctness argument. The fallback file is bounded on the
                // MEASURED axis (the last `cursorMissingFallbackDays` days), while a cursor is a
                // point on the INGESTED axis; a row measured before the window but ingested during it
                // is absent from this file yet sits below its max `ingested_at`, so checkpointing
                // there would skip it on this run and on every run after it — exactly the permanent
                // silent loss DATA-08 and `run`'s `ingestedSince` doc are written against. Starting
                // at the window's start instead yields an invariant that can be stated plainly:
                // nothing that ARRIVED during or after the fallback window can be skipped. The next
                // run re-reads that overlap once (rows this file already carried), which a consumer
                // keyed by `record_id` absorbs and which is merely wasteful — the tradeoff
                // `ExportCursorRepository.advance` already names as the acceptable side of this
                // choice. Data ingested BEFORE the window is outside the bounded safety net the
                // notice already told the user about; a full backfill is `resetCursor` plus a wider
                // rule, not something a checkpoint should quietly invent.
                //
                // The chain link is stored too, so the next run's `previous_manifest_sha` points at
                // this bundle: the fallback file is the chain's ROOT (it declares `is_delta: false`
                // and no cursors of its own, because it is not a delta), and the first real delta
                // links to it. That is the same shape `resetCursor`'s doc describes for a re-export.
                _ = try? cursors.advance(templateId: template.id, destinationId: destinationId,
                                         to: bootstrap, lastRunId: runId, manifestSha: manifestSha,
                                         now: clock.now())
                cursorAfter = bootstrap
            }
        }

        // A `sinceLastRun` fallback rides a SUCCESS row as `.cursorMissing` — a note, not a
        // failure (`ExportOutcome.isFailure` excludes it). The run genuinely succeeded; the code
        // records that it did so via the fallback so the notice is durable, not just returned.
        let noticeCode: ExportErrorCode? = plan.fellBackFromSinceLastRun ? .cursorMissing : receipt.errorCode
        let run = ExportRun(
            id: runId, templateId: template.id, jobId: result.job.id, trigger: trigger,
            startedAt: startedAt, finishedAt: clock.now(), outcome: effectiveOutcome,
            errorCode: noticeCode, errorDetail: receipt.errorDetail,
            bytesWritten: receipt.bytesDelivered, rowCounts: result.rowCounts,
            destinationId: destinationId, deliveredAt: receipt.deliveredAt,
            cursorBefore: plan.cursorBefore, cursorAfter: cursorAfter, manifestSha256: manifestSha)
        try? runs.insert(run)

        return TemplateRunResult(run: run, result: result, receipt: receipt,
                                 cursorFallbackNotice: plan.fellBackFromSinceLastRun)
    }

    /// "Re-export everything" (§12 EPIC-17 edge rule): drop the incremental checkpoint for one
    /// (template, destination) so the NEXT `sinceLastRun` run starts from scratch — it re-reads
    /// with no watermark (the disclosed `lastNDays` fallback with a `cursorFallbackNotice`), and a
    /// subsequent run rebuilds a fresh cursor + manifest chain. The chain deliberately breaks here:
    /// the next run's `previous_manifest_sha` is null, marking a new chain root a consumer can see.
    ///
    /// Deliberately a distinct call, never a side effect of a run (the same discipline
    /// `ExportCursorRepository.reset` vs `advance` draws): re-exporting is a user action, never
    /// something a retry can trigger by accident. Returns false — a no-op — when the runner was
    /// built without the cursor collaborator, so a misconfigured call site is diagnosable rather
    /// than silently "succeeding". The UI hook (a "Re-export everything" control) is a later lane;
    /// this exposes the capability and is what the reset test drives.
    @discardableResult
    func resetCursor(templateId: String, destinationId: String? = nil) -> Bool {
        guard let cursors = self.cursors else { return false }
        let destinationId = destinationId ?? ExportDestination.shareSheetId
        do {
            try cursors.reset(templateId: templateId, destinationId: destinationId)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Range resolution

    /// The concrete window one run will use, plus the delta filter and the cursor bookkeeping.
    struct ResolvedRun {
        /// The scope handed to generation — a copy of the template scope with its date window set
        /// per the range rule. For a delta run this window is CLEARED (nil/nil) so only the
        /// ingested watermark narrows the set.
        var scope: ExportScope
        /// The incremental delta watermark, or `nil` for a whole-window run.
        var ingestedSince: Date?
        /// The watermark the run started from, recorded on the ledger row for reconstruction.
        var cursorBefore: Date?
        /// True when `sinceLastRun` had no cursor and fell back to `lastNDays`. Such a run is NOT a
        /// delta (`ingestedSince` is nil, the manifest declares `is_delta: false`), but when it is
        /// delivered it does bootstrap the checkpoint the next run reads — so this flag means "the
        /// chain starts here", not "the chain cannot start".
        var fellBackFromSinceLastRun: Bool
    }

    /// Turn a template's `ExportRangeRule` into the concrete window (and, for `sinceLastRun`, the
    /// delta watermark) one run will use.
    ///
    /// **Static and pure on purpose.** Three surfaces run a template — `runTemplate` here, the
    /// in-app Export Center (`ExportManageService`) and a Shortcut (`IntentExportService`) — and
    /// they must turn the same rule + the same cursor into the same window, or "the Shortcut and the
    /// button export different data" is a real, silent bug. It used to be exactly that: both
    /// services hard-coded a 30-day fallback for `sinceLastRun` and never read the cursor at all, so
    /// the same template took a delta from one entry point and a fixed window from another. One
    /// function, three call sites, nothing to keep in step by hand.
    ///
    /// It takes the cursor rather than reading one because the three callers legitimately hold
    /// different cursors: the cursor is keyed `(template, destination)`, and only the caller knows
    /// which destination this run is actually handing its artifacts to.
    static func resolveRange(_ rule: ExportRangeRule, scope: ExportScope,
                             cursor: ExportCursor?, now: Date) -> ResolvedRun {
        var scope = scope
        switch rule {
        case .fixed:
            // The window the user pinned deliberately — the scope's own dates, verbatim.
            return ResolvedRun(scope: scope, ingestedSince: nil, cursorBefore: nil,
                               fellBackFromSinceLastRun: false)
        case .lastNDays(let n):
            scope.startDate = now.addingTimeInterval(-Double(max(1, n)) * 86_400)
            scope.endDate = now
            return ResolvedRun(scope: scope, ingestedSince: nil, cursorBefore: nil,
                               fellBackFromSinceLastRun: false)
        case .allTime:
            scope.startDate = nil
            scope.endDate = nil
            return ResolvedRun(scope: scope, ingestedSince: nil, cursorBefore: nil,
                               fellBackFromSinceLastRun: false)
        case .sinceLastRun:
            guard let cursor else {
                // No cursor yet: fall back to a bounded window rather than dumping all of history,
                // and flag it so the caller surfaces a notice. This is the one place the plan
                // singles out — a silent fallback here is the HAE failure the whole subsystem
                // exists to avoid.
                //
                // The window is still MEASURED-axis and this function still establishes no
                // checkpoint of its own — it is pure, and it does not know whether the run it is
                // planning will be delivered. What changed is that a delivered fallback run is no
                // longer a dead end: `runTemplate` bootstraps the checkpoint afterwards, at exactly
                // this `startDate`. A caller that resolves a fallback and never writes a cursor
                // leaves the template unable to ever take a delta (`IntentExportService` is still
                // in that state — see its `advanceCursorIfDelta`).
                scope.startDate = now.addingTimeInterval(-Double(Self.cursorMissingFallbackDays) * 86_400)
                scope.endDate = now
                return ResolvedRun(scope: scope, ingestedSince: nil, cursorBefore: nil,
                                   fellBackFromSinceLastRun: true)
            }
            // Delta: clear the measured-date window entirely and filter on the ingested axis, so a
            // late-arriving row (measured before the watermark, ingested after it) is included
            // rather than dropped forever.
            scope.startDate = nil
            scope.endDate = nil
            return ResolvedRun(scope: scope, ingestedSince: cursor.highWatermark,
                               cursorBefore: cursor.highWatermark, fellBackFromSinceLastRun: false)
        }
    }

    // MARK: - Delivery

    private func deliver(result: ExportResult, template: ExportTemplate, destination: ExportDestination,
                         plan: ResolvedRun, runDate: Date, timeZone: TimeZone,
                         attempt: Int) async -> ExportDeliveryReceipt {
        let artifacts = destinationArtifacts(from: result, label: template.name, plan: plan,
                                             runDate: runDate, timeZone: timeZone)

        // The share sheet is delivered in-process: the artifacts stay in the runner's temp folder
        // for the UI to hand to AirDrop/Files/Mail. There is nothing for this layer to copy, and
        // no network deliverer is (or should be) registered for it — a share-sheet "delivery" that
        // reached a deliverer would be a category error.
        if destination.kind == .shareSheet {
            let bytes = artifacts.reduce(0) { $0 + $1.byteCount }
            return ExportDeliveryReceipt(
                outcome: .success,
                errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: artifacts.count,
                                               filesExpected: artifacts.count, attempt: attempt),
                bytesDelivered: bytes, deliveredAt: clock.now(), destinationStatus: .ok,
                // Inline en+ar, sanctioned for this module (see `DestinationMessages`' doc): the
                // share sheet is delivered by the UI, so the "receipt" only says the files are
                // ready to hand off — never that they arrived anywhere, which for a share sheet
                // BADAN cannot know.
                message: LocalizedString(en: "Your export is ready to share.",
                                         ar: "تصديرك جاهز للمشاركة."))
        }

        guard let deliverer = deliverers.first(where: { $0.kind == destination.kind }) else {
            // A destination kind with no registered deliverer (a Phase-3 REST/cloud row reached on
            // a Phase-2 build) fails loudly rather than silently writing nowhere.
            return ExportDeliveryReceipt(
                outcome: .failedDelivery, errorCode: .destinationUnreachable,
                errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: 0,
                                               filesExpected: artifacts.count, attempt: attempt),
                bytesDelivered: 0, destinationStatus: destination.status,
                message: DestinationMessages.destinationNotConfigured)
        }

        let request = ExportDeliveryRequest(destination: destination, artifacts: artifacts,
                                            runDate: runDate, timeZone: timeZone)
        return await deliverer.deliver(request, now: clock.now())
    }

    /// Maps the runner's temp files onto the names they carry at the destination.
    ///
    /// A single-file export (a JSON bundle, or the one encrypted `.badanenc` container) uses the
    /// bare house name `BADAN_<slug>_<start>-<end>.<ext>` (`ExportArtifactNaming.fileName`). A
    /// multi-file export (CSV's raw/derived/events, plus the `hydration_*` set and — on a delta —
    /// `deletions.csv`/`corrections.csv`, plus the manifest) keeps each file's role as a
    /// discriminator — `…_raw.csv`, `…_deletions.csv`, `…_manifest.json` — because raw and derived
    /// must never collapse into one name (I5) and files sharing one `.csv` name would do exactly
    /// that.
    /// The role suffix reuses the same `slug`/`dateStamp` atoms `fileName` is built from, so it
    /// cannot drift from the house convention the parity fixtures pin.
    private func destinationArtifacts(from result: ExportResult, label: String, plan: ResolvedRun,
                                      runDate: Date, timeZone: TimeZone) -> [ExportArtifact] {
        let start = plan.scope.startDate ?? Date(timeIntervalSince1970: 0)
        let end = plan.scope.endDate ?? runDate
        let single = result.fileURLs.count == 1
        let slug = ExportArtifactNaming.slug(label)
        let startStamp = ExportArtifactNaming.dateStamp(start, timeZone: timeZone)
        let endStamp = ExportArtifactNaming.dateStamp(end, timeZone: timeZone)

        return result.fileURLs.map { url in
            let ext = url.pathExtension
            let name: String
            if single {
                name = ExportArtifactNaming.fileName(label: label, start: start, end: end,
                                                     fileExtension: ext, timeZone: timeZone)
            } else {
                // raw | derived | events | hydration_* | deletions | corrections | manifest
                let role = url.deletingPathExtension().lastPathComponent
                name = "\(ExportArtifactNaming.rootFolder)_\(slug)_\(startStamp)-\(endStamp)_\(role).\(ext)"
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            return ExportArtifact(sourceURL: url, fileName: name, byteCount: size ?? 0)
        }
    }

    // MARK: - Ledger helper

    /// Append one pre-generation or failed `ExportRun` and return it. Keeps the several early-exit
    /// paths in `runTemplate` from each hand-rolling the same 12-field initializer differently.
    private func record(_ runs: ExportRunRepository, id: String, template: ExportTemplate,
                        trigger: ExportTrigger, jobId: String?, startedAt: Date,
                        outcome: ExportOutcome, errorCode: ExportErrorCode?, stage: ExportStage,
                        attempt: Int, destinationId: String?, cursorBefore: Date? = nil) -> ExportRun {
        let run = ExportRun(id: id, templateId: template.id, jobId: jobId, trigger: trigger,
                            startedAt: startedAt, finishedAt: clock.now(), outcome: outcome,
                            errorCode: errorCode,
                            errorDetail: ExportErrorDetail(stage: stage, attempt: attempt),
                            destinationId: destinationId, cursorBefore: cursorBefore)
        try? runs.insert(run)
        return run
    }
}

// MARK: - EPIC-13: aggregated CSV generation (bucketed templates)
//
// A `.bucketed` template rolls raw measurements up into hour/day/week/month buckets instead of
// emitting one row per reading. This is the CSV analysis convenience EPIC-13 specifies; it is
// deliberately CSV-only:
//
//   - The JSON bundle is BADAN's full-fidelity archival format and its schema defines no bucketed
//     shape, so a `.bucketed` template whose format is JSON produces the ordinary raw+derived
//     bundle (raw data is never withheld). That routing lives in `runTemplate` — this path is
//     reached only for CSV.
//   - Aggregation is over the measurement chain (raw samples + interval records) only. Derived
//     values are already period-keyed and are not re-bucketed here; the sensitive namespace is
//     logs, not measurements, so an aggregated file never contains meds/symptoms regardless of
//     `includeSensitive`. `includeSensitive` still triggers encryption (defense in depth, matching
//     `run`) even though the content is measurement buckets.
//
// The bucketing itself is `MetricAggregator` (DST-correct, tz-at-measurement, byte-parity with
// Android) and the wide pivot is `WideCSVProjector` — this method only gathers the inputs, stamps
// each produced record with its `granularity`+`aggregation_method` (CSV columns 25/26, the
// ambiguity-closing pair EPIC-08 left for the runner to fill), writes the file + manifest + job,
// and hands the result back to `runTemplate` for delivery.
//
// One limit, named rather than left to be discovered: an aggregated run emits NO `deletions.csv` /
// `corrections.csv`, even on a `sinceLastRun` delta. Those tables report by `record_id`, and an
// aggregated file has no record ids — its rows are buckets keyed by (metric, bucket, stat), so a
// tombstone naming a raw row would point at something that never appeared in the file. A consumer
// of bucketed deltas therefore cannot reconcile removals from the artifacts alone and must
// periodically take a full-window aggregated export to re-settle its buckets. The row-level delta
// (`run`'s raw CSV or JSON path) is the shape that carries reconciliation.
extension ExportRunner {

    func runAggregated(scope: ExportScope, template: ExportTemplate, bucket: ExportBucket,
                       method: ExportAggregationMethod, passphrase: String?,
                       ingestedSince: Date?, startedAt: Date) throws -> ExportResult {
        if scope.includeSensitive {
            guard let passphrase, ExportPassphrasePolicy.isValid(passphrase) else {
                throw ExportRunError.sensitiveExportRequiresPassphrase
            }
        }

        sweepOrphanedExportFolders()
        let exportId = ULID.newID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-\(exportId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])

        let runningJob = ExportJob(id: exportId, scope: scope, format: .csv, status: .running,
                                   outputPath: folder.path, startedAt: startedAt, createdAt: startedAt)
        try exportJobs.insert(runningJob)

        do {
            let inputs = try gatherAggregateInputs(scope: scope, ingestedSince: ingestedSince)
            let ingestMax = inputs.maxIngestedAt
            let granularity = Self.aggregateGranularity(bucket)
            let definitions = Dictionary(uniqueKeysWithValues: registry.all.map { ($0.metricId, $0) })
            let records = MetricAggregator().aggregate(rows: inputs.rows, granularity: granularity,
                                                       method: method, definitions: definitions)

            let generatedAt = clock.now()
            let fileURL = folder.appendingPathComponent("aggregated.csv")
            let checksum: String
            if template.layout == .wide {
                // Wide is a pure pivot of the tidy records — one file, its own `#`-comment header.
                let wide = WideCSVProjector().render(records)
                let data = Data(wide.utf8)
                FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.complete])
                try data.write(to: fileURL, options: .completeFileProtection)
                checksum = Self.sha256Hex(data)
            } else {
                let rows = records.map { aggregateRow($0, scope) }
                checksum = try Self.streamWrite(rows, using: CSVWriter(), to: fileURL)
            }

            var counts: [String: Int] = [:]
            for record in records { counts[record.metricId, default: 0] += 1 }

            let manifest = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                        checksums: ["aggregated.csv": checksum], perMetricRowCounts: counts)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            try JSONCoding.encoder.encode(manifest).write(to: manifestURL, options: .completeFileProtection)

            let job = ExportJob(id: exportId, scope: scope, format: .csv, status: .completed,
                                manifest: manifest, outputPath: folder.path, rowCount: records.count,
                                startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
            try exportJobs.insert(job)

            // Aggregate buckets are neither measurements, intervals, sessions, logs nor engine
            // derivations — they are a rollup of raw. `ExportRowCounts` has no aggregate class, so
            // they are reported under `intervals` (the closest existing class: a bucket IS an
            // interval aggregate) rather than invented into a class that would misdescribe them.
            let rowCounts = ExportRowCounts(intervals: records.count)
            var result = ExportResult(job: job, fileURLs: [fileURL, manifestURL], rowCount: records.count,
                                      maxIngestedAt: ingestMax, rowCounts: rowCounts)

            if scope.includeSensitive, let passphrase {
                result = try encryptResult(result, exportId: exportId, folder: folder, scope: scope,
                                           format: .csv, startedAt: startedAt, passphrase: passphrase)
                result.maxIngestedAt = ingestMax
                result.rowCounts = rowCounts
            }
            return result
        } catch {
            let failedJob = ExportJob(id: exportId, scope: scope, format: .csv, status: .failed,
                                      outputPath: folder.path, startedAt: startedAt,
                                      finishedAt: clock.now(), createdAt: startedAt)
            try? exportJobs.insert(failedJob)
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The raw + interval rows in scope, projected onto `AggregateInputRow` for `MetricAggregator`.
    /// Applies the same metric/source/ingested filters as `run`'s gather. Aggregation happens in
    /// canonical units only (the aggregator's contract), so `value`/`unit` are the canonical ones.
    private func gatherAggregateInputs(scope: ExportScope,
                                       ingestedSince: Date?) throws -> (rows: [AggregateInputRow], maxIngestedAt: Date?) {
        let ids = metricIdsInScope(scope)
        var rows: [AggregateInputRow] = []
        var ingestMax: Date?
        func note(_ ingestedAt: Date) { if ingestMax == nil || ingestedAt > ingestMax! { ingestMax = ingestedAt } }

        try measurements.transaction {
            for id in ids where metricAllowed(id, scope) {
                for s in try measurements.rawSamples(metricId: id, from: scope.startDate, to: scope.endDate,
                                                     includeSuppressed: scope.includeSuppressed)
                where sourceAllowed(s.provenance, scope) && Self.ingestedAfter(s.provenance.ingestedAt, ingestedSince) {
                    rows.append(AggregateInputRow(metricId: s.metricId, value: s.value, unit: s.unit,
                                                  startAt: s.startAt, endAt: s.endAt, tzId: s.tzId))
                    note(s.provenance.ingestedAt)
                }
                for r in try measurements.intervalRecords(metricId: id, from: scope.startDate, to: scope.endDate,
                                                          includeSuppressed: scope.includeSuppressed)
                where sourceAllowed(r.provenance, scope) && Self.ingestedAfter(r.provenance.ingestedAt, ingestedSince) {
                    rows.append(AggregateInputRow(metricId: r.metricId, value: r.value, unit: r.unit,
                                                  startAt: r.startAt, endAt: r.endAt, tzId: r.tzId,
                                                  storedAggregation: r.aggregation))
                    note(r.provenance.ingestedAt)
                }
            }
        }
        return (rows, ingestMax)
    }

    /// One aggregated bucket as a tidy CSV row. `record_kind`/`value_type` are `aggregate` and
    /// `ingestion_path` is `derived` — the bucket was computed by BADAN, not ingested — while
    /// `is_derived` stays false: it is a rollup of RAW, kept separable from engine-derived values
    /// like baselines (I5). Columns 25/26 carry the granularity and method that make the number
    /// self-describing (the whole point of EPIC-13). `sample_count` and the multi-zone flag have no
    /// column in the 26-column contract and are dropped here (present in a future bundle shape).
    private func aggregateRow(_ record: AggregateRecord, _ scope: ExportScope) -> ExportRow {
        let (value, unit) = displayValueUnit(metricId: record.metricId, canonicalValue: record.value,
                                             canonicalUnit: record.unit, scope)
        return ExportRow(
            recordId: "\(record.metricId)|\(record.bucketKey)|\(record.stat.rawValue)",
            // `interval`, not `aggregate`: a bucket IS an interval aggregate, and the frozen
            // record_kind vocabulary (`sample|interval|session|event|derived|baseline`) has no
            // `aggregate`. `value_type` = aggregate + columns 25/26 are what distinguish this
            // computed rollup from a source interval record.
            recordKind: "interval",
            metricId: record.metricId,
            metricDisplay: metricDisplay(record.metricId, scope),
            value: CSVWriter.decimal(value),
            unit: unit,
            canonicalValue: CSVWriter.decimal(record.value),
            canonicalUnit: record.unit,
            valueType: "aggregate",
            isDerived: false,
            timestampStart: CSVWriter.iso8601(record.bucketStart, tzId: record.tzId),
            timestampEnd: CSVWriter.iso8601(record.bucketEnd, tzId: record.tzId),
            timezone: record.tzId,
            recordedAt: CSVWriter.iso8601(record.bucketStart, tzId: record.tzId),
            ingestionPath: IngestionPath.derived.rawValue,
            granularity: record.granularity.csvGranularity,
            aggregationMethod: record.stat.csvMethod)
    }

    private static func aggregateGranularity(_ bucket: ExportBucket) -> AggregateGranularity {
        switch bucket {
        case .hour: return .hour
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }
}

// MARK: - EPIC-12: GPX route export
//
// Routes are the one thing that can NOT ride the template path: `ExportFormat` deliberately has no
// `gpx` case (see `ExportTemplate.format`'s doc — no template may request a format no writer can
// silently produce), and routes are excluded from Quick Export structurally. So GPX gets its own
// entry point, gated the way §22.4 / §4.11 require: the route-export toggle AND a per-run
// confirmation that fingerprints the exact routes being written. Both gates live in
// `GPXWriter.artifacts`; this method's job is to turn its output into a recorded, delivered export
// — an `ExportJob` and an `ExportRun` — exactly like the template path does for CSV/JSON.
//
// The caller assembles the `GPXWorkout`s (from `RouteRepository`) and the `RouteExportConfirmation`
// over the SAME list, so the confirmation the user saw and the routes actually written cannot
// drift; ExportRunner does not re-read routes here, precisely so it cannot substitute a different
// set behind the confirmation. Delivery is the share sheet (the explicit, foreground route-export
// flow); a folder destination for routes is a later follow-up.
extension ExportRunner {

    /// The Advanced Export Builder's ad-hoc path (no template) — the "just run this scope now"
    /// button. It exists as a runner entry point, rather than the view model calling `run(...)`
    /// directly, for one reason that matters to trust: it records an `ExportRun` on both success
    /// AND failure, exactly like `runTemplate` and `runRouteExport` do.
    ///
    /// (BUG-EXPORT-P1a) Before this, the builder called `ExportRunner.run` straight through and
    /// wrote only an `ExportJob`, never a run. `ExportRunRepository.jobIdsWithoutRun` then counted
    /// every such job, and `ExportHealthScreen` rendered it as "started but left no record — likely
    /// the app was closed mid-export": a *successful, deliberately-run* custom export was reported
    /// to the user as a probable crash, in the one surface whose whole job is honest run history.
    /// Android never had the gap (every export there goes through `runAndRecordExport`), so this was
    /// also a cross-platform parity break (I6/§4.6). Writing the run here closes both, and lights up
    /// the previously-dead `templateId == nil` -> `ExportHealthCopy.customExport` title branch, which
    /// is exactly what `ExportRun.templateId`'s own doc means by "an ad-hoc export from the builder".
    ///
    /// A ledger-write failure is swallowed (`try?`): the artifact is already on disk, so raising a
    /// scary error after the export plainly worked would be its own small dishonesty. The run just
    /// won't appear in Export Health — the same tradeoff `runRouteExport` and Android's helper make.
    @discardableResult
    func runAdHoc(scope: ExportScope, format: ExportFormat, passphrase: String? = nil,
                  trigger: ExportTrigger = .manual) throws -> ExportResult {
        let startedAt = clock.now()
        let runId = ULID.newID()
        do {
            let result = try run(scope: scope, format: format, passphrase: passphrase)
            var bytes = 0
            for url in result.fileURLs {
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
                    bytes += size
                }
            }
            // `manifestSha256` mirrors the route path: the sha of the manifest JSON, or nil when
            // the job carries no manifest (never on the success path, but the optional is honest).
            let digest = result.job.manifest.map {
                ManifestDigest(hex: Self.sha256Hex(Data(JSONCoding.encode($0).utf8)))
            } ?? nil
            let run = ExportRun(id: runId, templateId: nil, jobId: result.job.id, trigger: trigger,
                                startedAt: startedAt, finishedAt: clock.now(), outcome: .success,
                                bytesWritten: bytes, rowCounts: result.rowCounts,
                                destinationId: ExportDestination.shareSheetId,
                                deliveredAt: clock.now(), manifestSha256: digest)
            try? runs?.insert(run)
            return result
        } catch {
            // Generation threw before (or during) the job write. The ledger row is keyed to the
            // attempt, not an artifact that may not exist — jobId nil, like the route gate failures.
            let run = ExportRun(id: runId, templateId: nil, jobId: nil, trigger: trigger,
                                startedAt: startedAt, finishedAt: clock.now(), outcome: .failedGeneration,
                                errorCode: .writeFailed,
                                errorDetail: ExportErrorDetail(stage: .writing, attempt: 0),
                                destinationId: ExportDestination.shareSheetId)
            try? runs?.insert(run)
            throw error
        }
    }

    func runRouteExport(workouts: [GPXWorkout], routeExportEnabled: Bool,
                        confirmation: RouteExportConfirmation, trigger: ExportTrigger = .manual,
                        attempt: Int = 0) -> TemplateRunResult {
        let startedAt = clock.now()
        let runId = ULID.newID()
        // Routes are location data; the manifest records a raw, non-sensitive-namespace scope
        // (the sensitive namespace is meds/symptoms — routes are their own class, gated above).
        let scope = ExportScope(includeRaw: true, includeDerived: false)

        guard let runs = self.runs else {
            let run = ExportRun(id: runId, trigger: trigger, startedAt: startedAt,
                                finishedAt: clock.now(), outcome: .failedGeneration, errorCode: .unknown,
                                errorDetail: ExportErrorDetail(stage: .finalizing, attempt: attempt))
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }

        try? exportJobs.markStaleRunningAsFailed()

        let artifacts: [GPXWriter.Artifact]
        do {
            artifacts = try GPXWriter(appVersion: appVersion, generatedAt: startedAt)
                .artifacts(for: workouts, routeExportEnabled: routeExportEnabled, confirmation: confirmation)
        } catch {
            // Map the two gate failures onto the closed ledger vocabulary: the toggle being off is
            // a permission refusal; a stale confirmation is a missing run-time confirmation (the
            // routes changed under the user's acknowledgement). An empty route is a generation
            // problem. None of these produced a job.
            let code: ExportErrorCode
            switch error {
            case GPXExportError.routeExportNotEnabled: code = .permissionDenied
            case GPXExportError.confirmationStale: code = .sensitiveConfirmationMissing
            default: code = .writeFailed
            }
            let run = ExportRun(id: runId, trigger: trigger, startedAt: startedAt,
                                finishedAt: clock.now(), outcome: .failedGeneration, errorCode: code,
                                errorDetail: ExportErrorDetail(stage: .gathering, attempt: attempt))
            try? runs.insert(run)
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }

        let exportId = ULID.newID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-\(exportId)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            try exportJobs.insert(ExportJob(id: exportId, scope: scope, format: .csv, status: .running,
                                            outputPath: folder.path, startedAt: startedAt, createdAt: startedAt))

            var fileURLs: [URL] = []
            var checksums: [String: String] = [:]
            var bytes = 0
            for artifact in artifacts {
                let url = folder.appendingPathComponent(artifact.fileName)
                let data = Data(artifact.gpx.utf8)
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.complete])
                try data.write(to: url, options: .completeFileProtection)
                checksums[artifact.fileName] = Self.sha256Hex(data)
                bytes += data.count
                fileURLs.append(url)
            }

            let generatedAt = clock.now()
            let manifest = makeManifest(exportId: exportId, scope: scope, generatedAt: generatedAt,
                                        checksums: checksums, perMetricRowCounts: [:])
            let manifestURL = folder.appendingPathComponent("manifest.json")
            try JSONCoding.encoder.encode(manifest).write(to: manifestURL, options: .completeFileProtection)
            fileURLs.append(manifestURL)

            let pointCount = workouts.reduce(0) { $0 + $1.routes.reduce(0) { $0 + $1.points.count } }
            let job = ExportJob(id: exportId, scope: scope, format: .csv, status: .completed,
                                manifest: manifest, outputPath: folder.path, rowCount: pointCount,
                                startedAt: startedAt, finishedAt: generatedAt, createdAt: startedAt)
            try exportJobs.insert(job)

            let result = ExportResult(job: job, fileURLs: fileURLs, rowCount: pointCount)
            // Route traces are sessions in `ExportRowCounts`' vocabulary (one per workout).
            let rowCounts = ExportRowCounts(sessions: workouts.count)
            let run = ExportRun(id: runId, jobId: exportId, trigger: trigger, startedAt: startedAt,
                                finishedAt: generatedAt, outcome: .success, bytesWritten: bytes,
                                rowCounts: rowCounts, deliveredAt: generatedAt,
                                manifestSha256: ManifestDigest(hex: Self.sha256Hex(Data(JSONCoding.encode(manifest).utf8))))
            try? runs.insert(run)
            return TemplateRunResult(run: run, result: result, receipt: nil)
        } catch {
            try? exportJobs.insert(ExportJob(id: exportId, scope: scope, format: .csv, status: .failed,
                                             outputPath: folder.path, startedAt: startedAt,
                                             finishedAt: clock.now(), createdAt: startedAt))
            try? FileManager.default.removeItem(at: folder)
            let run = ExportRun(id: runId, jobId: exportId, trigger: trigger, startedAt: startedAt,
                                finishedAt: clock.now(), outcome: .failedGeneration, errorCode: .writeFailed,
                                errorDetail: ExportErrorDetail(stage: .writing, attempt: attempt))
            try? runs.insert(run)
            return TemplateRunResult(run: run, result: nil, receipt: nil)
        }
    }
}
