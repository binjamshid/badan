package net.albayyan.badan.platform.health

import android.content.Context
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.BodyFatRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseRouteResult
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.FloorsClimbedRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.LeanBodyMassRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SkinTemperatureRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ChangesTokenRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.response.ReadRecordsResponse
import androidx.health.connect.client.time.TimeRangeFilter
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.storage.repositories.ReadAnchorRepository
import java.time.Instant
import java.time.ZoneOffset
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.reflect.KClass

/**
 * Real Health Connect integration. Conforms to the same [HealthStorePort] the FakeHealthStore
 * does, so the ingestion pipeline is identical regardless of source.
 *
 * The record set is driven by [HcTypeMap], not by a method per type: which metric a record
 * becomes, in what unit, under which permission and which `read_anchors` key is stated once,
 * as data, in a file that is pure enough to unit-test. What remains here is the part that
 * genuinely needs the SDK — pulling a value out of a record, paging, changes tokens, consent.
 *
 * It is entitlement-safe: the client is created lazily and guarded, so with no provider installed
 * (or no permissions granted) reads simply return empty rather than crashing. A denied type is
 * not an error state — Health Connect throws `SecurityException` for it, which is caught per type
 * so one missing grant cannot empty out the fourteen the user did grant.
 *
 * Two behaviours here are worth reading before changing anything:
 *  * **Incremental reads** use changes tokens ([readIncremental]) and fall back to a windowed
 *    full re-read on expiry. Tokens are held in memory until [commitPendingReadState], and a
 *    token is only held at all once the read it belongs to reached its last page — see
 *    [WindowedTypeRead].
 *  * **Measured timezone** comes from each record's own `ZoneOffset` where it has one, not from
 *    the device's current zone — see [measuredZone]. The class doc used to describe the current
 *    zone as "a pragmatic approximation"; it was one, and it misfiled every night recorded before
 *    a flight.
 */
class HealthConnectAdapter(
    private val context: Context,
    /**
     * Where changes tokens are persisted. Null (the default) keeps the previous behaviour exactly:
     * every sync is a full windowed re-read. Defaulted rather than required so that a construction
     * site with no database handle — a preview, a permission-check-only path — is not forced to
     * fabricate one, and so this change could not break an existing caller by signature alone.
     */
    private val anchors: ReadAnchorRepository? = null,
    /**
     * BADAN's own route-capture toggle, read fresh on every call rather than captured at
     * construction so that turning it off takes effect on the very next sync instead of the next
     * process launch. Location data is the one place where "eventually consistent consent" is not
     * good enough (plan §4 rule 11).
     */
    private val routeConsentGranted: () -> Boolean = { false },
    /**
     * User-set dedup priority per writing app, resolved fresh per sync. See
     * [HcTypeMap.writerPriority] — no defensible default ordering exists for, say, Garmin versus
     * Samsung Health on sleep, so the default table has to be overridable.
     */
    private val writerPriorityOverrides: () -> Map<String, Int> = { emptyMap() },
) : HealthStorePort {

    private val client: HealthConnectClient? by lazy {
        runCatching { HealthConnectClient.getOrCreate(context) }.getOrNull()
    }

    private val deviceTz: String get() = TimeZone.getDefault().id

    /**
     * Changes tokens advanced by the reads since the last commit, and NOT yet persisted.
     *
     * (DATA-08, mirroring iOS's `pendingAnchors`.) A token that is persisted before the rows it
     * covers are committed is a silent, permanent data loss: the next sync resumes *after* those
     * rows, and nothing will ever return them again. Health Connect's changes feed has no "replay
     * from before the last token" — the token is the only handle — so unlike a windowed re-read
     * there is no accidental second chance. Held here and written by [commitPendingReadState].
     *
     * "The rows it covers" means every row, not most of them. A token reaches this map only from a
     * read that ran to completion — [readIncremental] drains the whole feed before staging, and
     * [WindowedTypeRead] stages nothing unless it read its last page. Before the audit's finding #3
     * the windowed path staged the token *before* reading and kept it regardless, which reopened
     * exactly the hole this field exists to close, one level further down.
     */
    private val pendingTokens = ConcurrentHashMap<String, String>()

    /**
     * Per-type honesty about what the last read could actually cover, drained by
     * [backfillWindows]. Recorded at read time rather than computed afterwards because only the
     * read knows whether it ran incrementally or re-read the whole window.
     */
    private val readWindows = ConcurrentHashMap<String, BackfillWindow>()

    /**
     * Writing packages seen in this process, package -> `Metadata.device.type`. Populated both by
     * the cheap discovery probe ([discoverWriters]) and by every real read, so a writer that
     * appears mid-session gets a Source row on the next sync rather than the next launch.
     */
    private val observedWriters = ConcurrentHashMap<String, Int>()

    /**
     * Routes collected during [readSessions], drained by [readRoutes] — the same in-process
     * hand-off iOS uses for deletions, and for the same reason: `ExerciseSessionRecord` carries
     * its route inline, so re-querying Health Connect a second time purely to recover something
     * already in hand would double the exercise read for no new information.
     */
    private var pendingRoutes: List<RouteDto> = emptyList()

    /**
     * Deletions reported by the changes feed since the last read, counted but deliberately not
     * acted on.
     *
     * Android has no deletion path today — `MeasurementRepository` cannot soft-delete by upstream
     * id, and building that is iOS's BUG-10 work, unbuilt on this platform. Under the previous
     * full-window re-read a deleted record also left its BADAN row behind, so nothing regresses
     * here; what changes is that the gap is now *countable* instead of invisible. Surfaced for
     * diagnostics so "why is a workout I deleted in Samsung Health still in BADAN" has an answer
     * that is not a shrug.
     */
    private val deletionCount = AtomicInteger(0)

    val observedDeletionCount: Int get() = deletionCount.get()

    /**
     * Map Health Connect's SDK status onto BADAN's three states.
     *
     * `SDK_UNAVAILABLE` used to fall into `else -> unsupported`, which told a large share of real
     * users their phone couldn't do this at all. It usually means the opposite: below Android 14
     * Health Connect is a separate Play app, so "unavailable" is simply "not installed yet" — one
     * install away, and the UI already has a `notInstalled` branch that offers exactly that. Only
     * on Android 14+, where Health Connect ships as part of the platform, does `SDK_UNAVAILABLE`
     * genuinely mean this device cannot support it (e.g. an Android Go or otherwise stripped
     * build), and there is nothing to install.
     */
    override fun availability(): HealthAvailability =
        when (HealthConnectClient.getSdkStatus(context)) {
            HealthConnectClient.SDK_AVAILABLE -> HealthAvailability.available
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> HealthAvailability.notInstalled
            HealthConnectClient.SDK_UNAVAILABLE ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    HealthAvailability.notInstalled
                } else {
                    HealthAvailability.unsupported
                }
            else -> HealthAvailability.unsupported
        }

    /**
     * One descriptor per *writing app*, plus the generic Health Connect descriptor.
     *
     * This used to return the single `healthConnect` descriptor while the record mappers stamped
     * `sourceId = metadata.dataOrigin.packageName`, which broke two things at once: every ingested
     * row's `source_id` pointed at a Source row that did not exist (so the provenance sheet had
     * nothing to resolve), and `IngestionPipeline`'s priority map — keyed by source id — never
     * had an entry for any real writer, so every writer tied at priority 0 and sleep dedup between
     * Samsung Health and Google Fit was decided by ULID ordering. On Android that is not an edge
     * case: multiple apps writing the same metric is the normal configuration (plan §10).
     *
     * The generic descriptor is kept and always emitted because it is the fallback `sourceId` for
     * a record whose `dataOrigin` is empty, which must still resolve to a catalogued source —
     * the same reason iOS keeps its `fallbackSourceId` descriptor alongside real ones (DATA-06a).
     */
    override fun sourceDescriptors(): List<SourceDescriptor> {
        val overrides = writerPriorityOverrides()
        discoverWriters()
        val writers = observedWriters.entries
            .filter { it.key.isNotEmpty() && it.key != healthConnectPackage }
            .map { (pkg, deviceType) ->
                SourceDescriptor(
                    id = pkg,
                    displayName = writerLabel(pkg),
                    type = SourceType.HEALTH_CONNECT,
                    bundleId = pkg,
                    priority = HcTypeMap.writerPriority(pkg, deviceType, overrides),
                )
            }
        val generic = SourceDescriptor(
            id = fallbackSourceId, displayName = "Health Connect", type = SourceType.HEALTH_CONNECT,
            bundleId = healthConnectPackage,
            priority = HcTypeMap.writerPriority(healthConnectPackage, null, overrides),
        )
        // Sorted by id so the descriptor order (and therefore any id-tiebreak downstream) is
        // deterministic across runs rather than dependent on ConcurrentHashMap iteration order.
        return (writers + generic).sortedBy { it.id }
    }

    /**
     * Learn which apps write the types BADAN reads, without reading their data.
     *
     * One newest-record page of size 1 per ingested type — the direct analogue of iOS's
     * `representativeInfo`, which also learns a source's device from a single newest sample
     * because that is the only place the platform exposes it. It runs before the real read
     * (`IngestionPipeline` asks for descriptors first), which is exactly why it cannot be
     * replaced by "collect packages as we read": on a first connect the read would stamp
     * `source_id`s for sources that had not been catalogued yet.
     *
     * Memoized per instance: the writer set changes when a user installs a health app, not
     * between two syncs, and re-probing on every sourceDescriptors() call would add fifteen IPC
     * round trips to every ingest for an answer that does not move.
     */
    private var writersDiscovered = false

    private fun discoverWriters() {
        if (writersDiscovered) return
        val c = client ?: return
        val now = System.currentTimeMillis()
        val range = HealthDateRange(now - HcTypeMap.defaultHistoryWindowDays * MILLIS_PER_DAY, now)
        runBlocking {
            for (entry in HcTypeMap.ingested) {
                runCatching {
                    val response = c.readRecords(
                        ReadRecordsRequest(
                            recordType = entry.recordType,
                            timeRangeFilter = TimeRangeFilter.between(
                                Instant.ofEpochMilli(range.start), Instant.ofEpochMilli(range.end),
                            ),
                            ascendingOrder = false,
                            pageSize = 1,
                        ),
                    )
                    response.records.forEach { noteWriter(it.metadata) }
                }
            }
        }
        writersDiscovered = true
    }

    /**
     * The writing app's user-visible name, resolved through `PackageManager` and falling back to
     * the package id.
     *
     * The fallback is not a formality: a writer can be uninstalled while the data it wrote stays
     * in Health Connect, and "com.sec.android.app.shealth" is a worse label than "Samsung Health"
     * but a far better one than a blank or an invented name. The package id is always the honest
     * answer, so it is what the failure path returns rather than something friendlier and wrong.
     */
    private fun writerLabel(packageName: String): String = runCatching {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    }.getOrDefault(packageName)

    private fun noteWriter(meta: Metadata) {
        val pkg = meta.dataOrigin.packageName
        if (pkg.isNotEmpty()) observedWriters[pkg] = meta.device?.type ?: 0
    }

    /** Permissions granted so far (empty if HC unavailable). Denial is first-class state, not error. */
    suspend fun grantedPermissions(): Set<String> =
        client?.permissionController?.getGrantedPermissions() ?: emptySet()

    suspend fun hasAllPermissions(): Boolean = grantedPermissions().containsAll(permissions)

    /**
     * Whether every type in one consent family is granted — the honest unit to report against now
     * that the read set spans five families. "All or nothing" would tell a user who granted sleep
     * and vitals but declined body measurements that nothing is connected.
     */
    suspend fun hasPermissions(family: HcTypeMap.Family): Boolean =
        grantedPermissions().containsAll(HcTypeMap.permissions(family))

    // MARK: - Reads
    //
    // The suspend HC calls are bridged with runBlocking, which is safe because ingestion runs off
    // the main thread (`AppEnvironment.syncHealthConnect` uses Dispatchers.IO).

    override fun readSamples(range: HealthDateRange): List<SampleDto> = runBlocking {
        if (client == null) return@runBlocking emptyList()
        val entries = HcTypeMap.ingested.filter { it.shape == HcTypeMap.Shape.SAMPLE }
        coroutineScope {
            entries.map { entry -> async { readSampleEntry(entry, range) } }.flatMap { it.await() }
        }
    }

    override fun readIntervals(range: HealthDateRange): List<IntervalDto> = runBlocking {
        if (client == null) return@runBlocking emptyList()
        val entries = HcTypeMap.ingested.filter { it.shape == HcTypeMap.Shape.INTERVAL }
        coroutineScope {
            entries.map { entry -> async { readIntervalEntry(entry, range) } }.flatMap { it.await() }
        }
    }

    /**
     * Sleep sessions and workout sessions. Workout routes are extracted in the same pass and
     * parked in [pendingRoutes] for [readRoutes] to drain.
     */
    override fun readSessions(range: HealthDateRange): List<SessionDto> = runBlocking {
        if (client == null) return@runBlocking emptyList()
        val sleepEntry = HcTypeMap.entry("SleepSessionRecord")
        val workoutEntry = HcTypeMap.entry("ExerciseSessionRecord")
        coroutineScope {
            val sleep = async { if (sleepEntry != null) readSleep(sleepEntry, range) else emptyList() }
            val workouts = async { if (workoutEntry != null) readWorkouts(workoutEntry, range) else emptyList() }
            sleep.await() + workouts.await()
        }
    }

    /**
     * Routes for the workouts the preceding [readSessions] returned.
     *
     * Two independent gates, checked in this order and both required:
     *  1. BADAN's own route toggle ([routeConsentGranted]). Checked first and checked here, so
     *     that with the toggle off no coordinate is ever copied out of a record — not into a DTO,
     *     not into a log, not into memory that outlives the read.
     *  2. Health Connect's own per-route consent. connect-client 1.1.0 has no bulk route-read
     *     permission; a session's `exerciseRouteResult` is `ConsentRequired` until the user
     *     approves that specific route through the system dialog, and BADAN treats that as "no
     *     route" rather than prompting mid-sync. Silence is the correct behaviour for a
     *     background pass over location data.
     */
    override fun readRoutes(range: HealthDateRange): List<RouteDto> {
        val drained = pendingRoutes
        pendingRoutes = emptyList()
        return if (routeConsentGranted()) drained else emptyList()
    }

    /**
     * Persist every changes token advanced since the last commit (DATA-08).
     *
     * Correct today because of a specific fact about the caller, and that fact is the reason this
     * comment exists: `AppEnvironment.syncHealthConnect` wraps `IngestionPipeline.ingest` in a
     * `database.main.transaction { }`, and [anchors] writes through that same connection. The
     * token write therefore joins the same transaction as the rows it covers — they commit
     * together or roll back together, which is exactly the guarantee needed.
     *
     * What breaks if someone "optimizes" this: move the Health Connect reads outside that
     * transaction (the P2 change iOS made, to stop holding the write lock across IPC), and the
     * token write is suddenly outside it too. It would then commit while the row writes could
     * still fail — advancing past data that was never stored, permanently. If the reads move out,
     * this call must move out with them, after the write commits, and `ingest` must stop calling
     * it. Do not separate the two.
     *
     * This guarantee only ever held for the *write* half. The audit's finding #3 found the read
     * half open underneath it: a page that failed mid-pagination still left a fresh token staged
     * here, so a transaction that committed perfectly committed a cursor past records the read had
     * silently dropped. Two-phase commit over a token that was already wrong is still wrong.
     * [WindowedTypeRead] is what makes the token in this map mean "everything it covers was read".
     */
    override fun commitPendingReadState() {
        val repo = anchors ?: return
        val now = System.currentTimeMillis()
        val snapshot = pendingTokens.toMap()
        pendingTokens.clear()
        for ((platformType, token) in snapshot) {
            runCatching { repo.setToken(anchorStore, platformType, token, now) }
        }
    }

    override fun backfillWindows(): List<BackfillWindow> = readWindows.values.sortedBy { it.platformType }

    // MARK: - Per-type read strategy

    /**
     * Read one record type, either incrementally (changes token) or as a full windowed read, and
     * fold each page into DTOs as it arrives.
     *
     * [emit] is called once per record and the raw page is released immediately afterwards. That
     * is the whole OOM story for the plan's 100k-record acceptance criterion: peak memory is one
     * page of records (Health Connect's own page size) plus the accumulated DTOs, not the entire
     * result set of `Record` objects *and* the DTOs derived from them. The previous
     * `readAll(...).map { }` shape held both at once.
     */
    private suspend fun <T : Record> readType(
        entry: HcTypeMap.Entry,
        recordType: KClass<T>,
        range: HealthDateRange,
        emit: (T) -> Unit,
    ) {
        val c = client ?: return
        val token = anchors?.let { runCatching { it.token(anchorStore, entry.platformType) }.getOrNull() }

        if (token != null) {
            val consumed = readIncremental(c, entry, recordType, range, token, emit)
            if (consumed) {
                recordWindow(entry, range, incremental = true)
                return
            }
            // Token expired or the changes feed failed: drop the dead cursor so the next sync
            // does not pay a round trip to rediscover that, then fall through to a full re-read.
            // Safe by construction — every write below is idempotent by (metric, external, source),
            // so the cost of losing a cursor is time, never correctness.
            anchors?.let { runCatching { it.clearAnchor(anchorStore, entry.platformType) } }
        }

        // Full windowed read. The fresh token is requested BEFORE the read, not after: a record
        // written between the read finishing and the token being minted would fall in the gap
        // between "not in this read" and "before this token" and would never be returned by
        // anything, ever. Requesting first makes the overlap redundant instead of lossy, and
        // redundant is free because re-ingest is idempotent.
        //
        // It is *held*, not staged, until the last page has actually been read (audit finding #3).
        // This used to call `requestFreshToken`, which wrote straight into `pendingTokens`, and
        // then `recordWindow(incremental = false)` unconditionally — while the page loop
        // underneath simply `break`ed out when `readPageWithRetry` exhausted its retries. A
        // provider hiccup on page two therefore committed a cursor sitting *after* records that
        // were never ingested, claimed the whole window as covered on top of it, and the run
        // recorded COMPLETED. Health Connect cannot replay from before a token, so those records
        // were gone until it expired (~30 days) or the user reconnected. iOS has never had this
        // hole: `HealthKitAdapter.runAnchoredQuery` leaves `result.anchor` at the OLD anchor when
        // the query errors, so a failed read replays. Revert this and Android loses data silently
        // again, with a truthful-looking coverage claim to say it did not.
        val freshToken = requestFreshToken(c, entry)
        WindowedTypeRead<T>(
            fetchPage = { pageToken ->
                readPageWithRetry(c, recordType, range, pageToken)
                    ?.let { HealthPage(it.records, it.pageToken) }
            },
            emit = emit,
            stageToken = { pendingTokens[entry.platformType] = it },
            claimCoverage = { covered ->
                if (covered) {
                    recordWindow(entry, range, incremental = false)
                } else {
                    // Not merely "don't add a claim" — actively drop one made earlier. [readWindows]
                    // outlives a single run (the adapter is process-scoped and `AppEnvironment`
                    // holds one instance), so leaving a previous sync's entry in place would let
                    // `backfillWindows()` keep reporting that coverage for a type whose read just
                    // failed. That is the same false claim, one run later.
                    readWindows.remove(entry.platformType)
                }
            },
        ).run(freshToken)
    }

    /**
     * Drain the changes feed for one type. Returns true when the feed was consumed successfully,
     * false when the caller must fall back to a full windowed re-read.
     *
     * Health Connect expires a changes token after roughly 30 days of not being used, and also
     * invalidates it when the user revokes and re-grants a permission — neither is an error
     * condition, both are ordinary, and both surface as `changesTokenExpired`. Treating expiry as
     * a failure (rather than as "re-read the window") is how an app ends up silently never syncing
     * again after a fortnight of not being opened.
     */
    private suspend fun <T : Record> readIncremental(
        c: HealthConnectClient,
        entry: HcTypeMap.Entry,
        recordType: KClass<T>,
        range: HealthDateRange,
        token: String,
        emit: (T) -> Unit,
    ): Boolean {
        var cursor = token
        var deletions = 0
        // Buffered rather than emitted as we go: a mid-feed expiry means the caller re-reads the
        // whole window, and records already emitted would then be handed to the pipeline twice.
        // Idempotent upserts make that harmless but not free, and a doubled `IngestSummary` would
        // misreport what actually happened.
        val collected = ArrayList<T>()
        while (true) {
            val response = runCatching { c.getChanges(cursor) }.getOrNull() ?: return false
            if (response.changesTokenExpired) return false
            for (change in response.changes) {
                when (change) {
                    is UpsertionChange -> {
                        val record = change.record
                        if (!recordType.isInstance(record)) continue
                        @Suppress("UNCHECKED_CAST")
                        val typed = record as T
                        // The changes feed is not range-scoped — it reports everything that moved,
                        // including a record outside the caller's window (another app backfilling
                        // last year, say). Filtered to the requested range so an incremental sync
                        // and a full re-read of the same range produce the same rows; without this
                        // the two paths would disagree and no fixture could pin either down.
                        if (!inRange(typed, range)) continue
                        collected.add(typed)
                    }
                    else -> deletions += 1
                }
            }
            cursor = response.nextChangesToken
            if (!response.hasMore) break
        }
        collected.forEach(emit)
        deletionCount.addAndGet(deletions)
        pendingTokens[entry.platformType] = cursor
        return true
    }

    /**
     * Mint a changes token for one type and hand it back — deliberately *not* staged here.
     *
     * It used to write straight into [pendingTokens], which made the token's fate independent of
     * whether the read that follows it succeeds. That independence is the whole of audit finding
     * #3; see the call site in [readType]. Returning the token forces the caller to decide when it
     * becomes real, and there is exactly one correct answer.
     */
    private suspend fun requestFreshToken(c: HealthConnectClient, entry: HcTypeMap.Entry): String? {
        if (anchors == null) return null
        return runCatching {
            c.getChangesToken(ChangesTokenRequest(recordTypes = setOf(entry.recordType)))
        }.getOrNull()
    }

    /**
     * Reads one page, retrying transient failures (provider hiccups/IO) with a short backoff
     * before giving up. A [SecurityException] means the permission was denied/revoked — that's
     * not transient, so it's not retried and the page loop is terminated immediately.
     *
     * Null is the honest "this page could not be read", and [WindowedTypeRead] now treats it that
     * way. It previously meant the same thing and was handled as if it meant "no more pages",
     * which is how a recoverable provider hiccup turned into permanent data loss.
     */
    private suspend fun <T : Record> readPageWithRetry(
        c: HealthConnectClient,
        type: KClass<T>,
        range: HealthDateRange,
        token: String?,
    ): ReadRecordsResponse<T>? {
        var attempt = 0
        while (true) {
            val result = runCatching {
                c.readRecords(
                    ReadRecordsRequest(
                        recordType = type,
                        timeRangeFilter = TimeRangeFilter.between(
                            Instant.ofEpochMilli(range.start), Instant.ofEpochMilli(range.end)
                        ),
                        pageToken = token,
                    )
                )
            }
            result.getOrNull()?.let { return it }
            val error = result.exceptionOrNull() ?: return null
            if (error is SecurityException || attempt >= maxPageReadRetries) return null
            attempt += 1
            delay(pageReadRetryBaseDelayMs * (1L shl (attempt - 1)))
        }
    }

    /**
     * Record what this type's read could honestly cover (plan §14 backfill honesty).
     *
     * `achievableStart` is clamped to Health Connect's default 30-day window because BADAN does
     * not request `READ_HEALTH_DATA_HISTORY` (see AndroidManifest). Asking for 90 days and
     * silently receiving 30 is how a user concludes their watch stopped recording in April.
     */
    private fun recordWindow(entry: HcTypeMap.Entry, range: HealthDateRange, incremental: Boolean) {
        val limit = range.end - HcTypeMap.achievableWindowDays(entry) * MILLIS_PER_DAY
        readWindows[entry.platformType] = BackfillWindow(
            platformType = entry.platformType,
            requestedStart = range.start,
            achievableStart = maxOf(range.start, limit),
            end = range.end,
            incremental = incremental,
        )
    }

    private fun inRange(record: Record, range: HealthDateRange): Boolean {
        val t = recordStart(record) ?: return true
        return t in range.start..range.end
    }

    /** Start instant of a record, whichever of the two Health Connect record shapes it is. */
    private fun recordStart(record: Record): Long? = when (record) {
        is StepsRecord -> record.startTime.toEpochMilli()
        is ActiveCaloriesBurnedRecord -> record.startTime.toEpochMilli()
        is DistanceRecord -> record.startTime.toEpochMilli()
        is FloorsClimbedRecord -> record.startTime.toEpochMilli()
        is HeartRateRecord -> record.startTime.toEpochMilli()
        is SkinTemperatureRecord -> record.startTime.toEpochMilli()
        is SleepSessionRecord -> record.startTime.toEpochMilli()
        is ExerciseSessionRecord -> record.startTime.toEpochMilli()
        is RestingHeartRateRecord -> record.time.toEpochMilli()
        is HeartRateVariabilityRmssdRecord -> record.time.toEpochMilli()
        is RespiratoryRateRecord -> record.time.toEpochMilli()
        is OxygenSaturationRecord -> record.time.toEpochMilli()
        is WeightRecord -> record.time.toEpochMilli()
        is BodyFatRecord -> record.time.toEpochMilli()
        is LeanBodyMassRecord -> record.time.toEpochMilli()
        is Vo2MaxRecord -> record.time.toEpochMilli()
        else -> null
    }

    // MARK: - Mappers

    private fun source(meta: Metadata): String =
        meta.dataOrigin.packageName.ifEmpty { fallbackSourceId }

    private fun device(meta: Metadata) = meta.device?.model

    /**
     * The timezone a record was actually measured in, and whether that had to be assumed
     * (DATA-07 parity with iOS's `measuredTimeZone(for:)`).
     *
     * Health Connect stamps a `ZoneOffset` on records whose writer knew its offset — which is what
     * `DayAttribution`'s "timezone at measurement" contract needs, and what stops a post-travel
     * backfill from filing historical nights under today's zone. When absent, the device's current
     * zone is used and [QualityFlag.TZ_ASSUMED] is stamped, so the assumption is visible on the
     * row rather than only in this comment.
     */
    private fun measuredZone(offset: ZoneOffset?): Pair<String, Boolean> {
        val id = HcTypeMap.zoneId(offset)
        return if (id != null) id to false else deviceTz to true
    }

    private fun flags(tzAssumed: Boolean): List<QualityFlag> =
        if (tzAssumed) listOf(QualityFlag.TZ_ASSUMED) else emptyList()

    private suspend fun readIntervalEntry(entry: HcTypeMap.Entry, range: HealthDateRange): List<IntervalDto> {
        val metricId = entry.metricId ?: return emptyList()
        val out = ArrayList<IntervalDto>()

        fun add(
            value: Double, start: Long, end: Long, offset: ZoneOffset?, meta: Metadata,
            externalId: String = HcTypeMap.externalId(meta.id),
        ) {
            noteWriter(meta)
            val (tz, assumed) = measuredZone(offset)
            out.add(
                IntervalDto(
                    metricId = metricId, value = value, unit = entry.unit, start = start, end = end,
                    tz = tz, aggregation = entry.aggregation, sourceId = source(meta),
                    deviceId = device(meta), externalId = externalId, qualityFlags = flags(assumed),
                ),
            )
        }

        when (entry.platformType) {
            "StepsRecord" -> readType(entry, StepsRecord::class, range) {
                add(it.count.toDouble(), it.startTime.toEpochMilli(), it.endTime.toEpochMilli(), it.startZoneOffset, it.metadata)
            }
            "ActiveCaloriesBurnedRecord" -> readType(entry, ActiveCaloriesBurnedRecord::class, range) {
                add(it.energy.inKilojoules, it.startTime.toEpochMilli(), it.endTime.toEpochMilli(), it.startZoneOffset, it.metadata)
            }
            "DistanceRecord" -> readType(entry, DistanceRecord::class, range) {
                add(it.distance.inMeters, it.startTime.toEpochMilli(), it.endTime.toEpochMilli(), it.startZoneOffset, it.metadata)
            }
            "FloorsClimbedRecord" -> readType(entry, FloorsClimbedRecord::class, range) {
                add(it.floors, it.startTime.toEpochMilli(), it.endTime.toEpochMilli(), it.startZoneOffset, it.metadata)
            }
            "RestingHeartRateRecord" -> readType(entry, RestingHeartRateRecord::class, range) {
                val t = it.time.toEpochMilli()
                add(it.beatsPerMinute.toDouble(), t, t, it.zoneOffset, it.metadata)
            }
            "HeartRateVariabilityRmssdRecord" -> readType(entry, HeartRateVariabilityRmssdRecord::class, range) {
                val t = it.time.toEpochMilli()
                add(it.heartRateVariabilityMillis, t, t, it.zoneOffset, it.metadata)
            }
            "RespiratoryRateRecord" -> readType(entry, RespiratoryRateRecord::class, range) {
                val t = it.time.toEpochMilli()
                add(it.rate, t, t, it.zoneOffset, it.metadata)
            }
            // One row per delta, not one per record: a skin-temperature record is a whole night's
            // session carrying a series of deviations, and collapsing it to a single value would
            // discard the shape of the night that makes a deviation readable at all. Each delta
            // gets a sample-scoped external id for the same reason heart-rate samples do — the
            // parent record id is not unique across its own children.
            "SkinTemperatureRecord" -> readType(entry, SkinTemperatureRecord::class, range) { record ->
                for (delta in record.deltas) {
                    val t = delta.time.toEpochMilli()
                    add(
                        delta.delta.inCelsius, t, t, record.startZoneOffset, record.metadata,
                        externalId = HcTypeMap.sampleExternalId(record.metadata.id, t),
                    )
                }
            }
        }
        return out
    }

    private suspend fun readSampleEntry(entry: HcTypeMap.Entry, range: HealthDateRange): List<SampleDto> {
        val metricId = entry.metricId ?: return emptyList()
        val out = ArrayList<SampleDto>()

        fun add(
            value: Double, at: Long, offset: ZoneOffset?, meta: Metadata,
            externalId: String = HcTypeMap.externalId(meta.id), subtypeFlags: List<QualityFlag> = emptyList(),
        ) {
            noteWriter(meta)
            val (tz, assumed) = measuredZone(offset)
            out.add(
                SampleDto(
                    metricId = metricId, value = value, unit = entry.unit, start = at, end = at,
                    tz = tz, sourceId = source(meta), deviceId = device(meta), externalId = externalId,
                    qualityFlags = flags(assumed) + subtypeFlags,
                ),
            )
        }

        when (entry.platformType) {
            "HeartRateRecord" -> readType(entry, HeartRateRecord::class, range) { record ->
                for (sample in record.samples) {
                    val t = sample.time.toEpochMilli()
                    add(
                        sample.beatsPerMinute.toDouble(), t, record.startZoneOffset, record.metadata,
                        externalId = HcTypeMap.sampleExternalId(record.metadata.id, t),
                    )
                }
            }
            "OxygenSaturationRecord" -> readType(entry, OxygenSaturationRecord::class, range) {
                add(it.percentage.value, it.time.toEpochMilli(), it.zoneOffset, it.metadata)
            }
            "WeightRecord" -> readType(entry, WeightRecord::class, range) {
                add(it.weight.inKilograms, it.time.toEpochMilli(), it.zoneOffset, it.metadata)
            }
            "BodyFatRecord" -> readType(entry, BodyFatRecord::class, range) {
                add(it.percentage.value, it.time.toEpochMilli(), it.zoneOffset, it.metadata)
            }
            "LeanBodyMassRecord" -> readType(entry, LeanBodyMassRecord::class, range) {
                add(it.mass.inKilograms, it.time.toEpochMilli(), it.zoneOffset, it.metadata)
            }
            // VO2 max carries an ESTIMATE flag for every method except a metabolic cart, because
            // that is the truth of the number: a heart-rate-ratio VO2 is a model output, not a
            // measurement, and plan §4 rule 7 forbids presenting the two as the same kind of
            // fact. The flag is what lets the detail screen label methodology without the display
            // layer having to re-derive it from a subtype string.
            "Vo2MaxRecord" -> readType(entry, Vo2MaxRecord::class, range) {
                val estimated = it.measurementMethod != Vo2MaxRecord.MEASUREMENT_METHOD_METABOLIC_CART
                add(
                    it.vo2MillilitersPerMinuteKilogram, it.time.toEpochMilli(), it.zoneOffset, it.metadata,
                    subtypeFlags = if (estimated) listOf(QualityFlag.ESTIMATE) else emptyList(),
                )
            }
        }
        return out
    }

    private suspend fun readSleep(entry: HcTypeMap.Entry, range: HealthDateRange): List<SessionDto> {
        val out = ArrayList<SessionDto>()
        readType(entry, SleepSessionRecord::class, range) { record ->
            noteWriter(record.metadata)
            val (tz, assumed) = measuredZone(record.startZoneOffset)
            val stages = record.stages.map {
                StageDto(mapStage(it.stage), it.startTime.toEpochMilli(), it.endTime.toEpochMilli())
            }
            val asleepSeconds = stages.filter { it.stage != SleepStage.AWAKE && it.stage != SleepStage.IN_BED }
                .sumOf { (it.end - it.start).toDouble() / 1000.0 }
            val inBedSeconds = (record.endTime.toEpochMilli() - record.startTime.toEpochMilli()).toDouble() / 1000.0
            out.add(
                SessionDto(
                    kind = SessionKind.SLEEP_PRIMARY, subtype = record.title,
                    start = record.startTime.toEpochMilli(), end = record.endTime.toEpochMilli(), tz = tz,
                    sourceId = source(record.metadata), deviceId = device(record.metadata),
                    externalId = HcTypeMap.externalId(record.metadata.id), stages = stages,
                    timeAsleepSeconds = if (asleepSeconds > 0) asleepSeconds else null,
                    timeInBedSeconds = inBedSeconds,
                    qualityFlags = flags(assumed),
                ),
            )
        }
        return out
    }

    /**
     * Exercise sessions -> `sessions` with kind=workout (plan §9.1).
     *
     * Totals are deliberately NOT computed here. Health Connect models a workout as a bare
     * envelope — type, title, segments, laps — with energy, distance and heart rate living in
     * separate records that merely overlap the session window. Reading those a second time to
     * total them would double every activity read; `IngestionPipeline` already holds all three
     * lists and links them there (see `WorkoutLinkage`), which also keeps the linkage rule
     * testable and identical no matter which store produced the DTOs.
     */
    private suspend fun readWorkouts(entry: HcTypeMap.Entry, range: HealthDateRange): List<SessionDto> {
        val out = ArrayList<SessionDto>()
        val routes = ArrayList<RouteDto>()
        val consented = routeConsentGranted()
        readType(entry, ExerciseSessionRecord::class, range) { record ->
            noteWriter(record.metadata)
            val (tz, assumed) = measuredZone(record.startZoneOffset)
            val externalId = HcTypeMap.externalId(record.metadata.id)
            out.add(
                SessionDto(
                    kind = SessionKind.WORKOUT, subtype = record.title,
                    start = record.startTime.toEpochMilli(), end = record.endTime.toEpochMilli(), tz = tz,
                    sourceId = source(record.metadata), deviceId = device(record.metadata),
                    externalId = externalId,
                    activityType = activityTypeCode(record.exerciseType),
                    totals = null,
                    qualityFlags = flags(assumed),
                ),
            )
            if (consented) extractRoute(record, externalId, tz, assumed)?.let { routes.add(it) }
        }
        pendingRoutes = routes
        return out
    }

    /**
     * Pull a session's GPS trace, if there is one and the platform has consented to it.
     *
     * The consent snapshot recorded on the row is BADAN's own toggle state plus the fact that
     * Health Connect released the data — both were true at this instant, and both are what plan
     * §9.2 means by "the route-consent state at ingest time".
     */
    private fun extractRoute(
        record: ExerciseSessionRecord,
        sessionExternalId: String,
        tz: String,
        tzAssumed: Boolean,
    ): RouteDto? {
        val result = record.exerciseRouteResult
        if (result !is ExerciseRouteResult.Data) return null
        val locations = result.exerciseRoute.route
        if (locations.isEmpty()) return null
        // Sorted by time, then sequenced. `seq` is the primary key alongside route_id and is what
        // orders the trace on read, so it must reflect the path walked rather than the order the
        // platform happened to hand the fixes over.
        val points = locations.sortedBy { it.time }.mapIndexed { index, location ->
            RoutePointDto(
                seq = index,
                lat = location.latitude,
                lon = location.longitude,
                altitudeM = location.altitude?.inMeters,
                horizontalAccuracyM = location.horizontalAccuracy?.inMeters,
                timestamp = location.time.toEpochMilli(),
            )
        }
        return RouteDto(
            sessionExternalId = sessionExternalId,
            externalId = HcTypeMap.routeExternalId(record.metadata.id),
            sourceId = source(record.metadata),
            deviceId = device(record.metadata),
            start = points.first().timestamp,
            end = points.last().timestamp,
            tz = tz,
            consentSnapshot = routeConsentSnapshot,
            points = points,
            qualityFlags = flags(tzAssumed),
        )
    }

    /**
     * Health Connect's integer exercise type -> a stable string code stored in the workout detail
     * JSON.
     *
     * A string, not the raw int: the int is an SDK constant whose meaning is defined by the
     * version of connect-client that produced it, and an exported workout is meant to still be
     * readable in five years by something that never linked that SDK. The unknown branch keeps the
     * numeric value rather than discarding it, so an exercise type added after this build still
     * round-trips through export instead of becoming "other".
     */
    private fun activityTypeCode(exerciseType: Int): String =
        exerciseTypeCodes[exerciseType] ?: "hc_type_$exerciseType"

    private fun mapStage(hcStage: Int): SleepStage = when (hcStage) {
        SleepSessionRecord.STAGE_TYPE_DEEP -> SleepStage.DEEP
        SleepSessionRecord.STAGE_TYPE_REM -> SleepStage.REM
        SleepSessionRecord.STAGE_TYPE_LIGHT -> SleepStage.LIGHT
        SleepSessionRecord.STAGE_TYPE_AWAKE,
        SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> SleepStage.AWAKE
        else -> SleepStage.ASLEEP_UNSPECIFIED
    }

    companion object {
        /** Bounded retry budget for a single page read before treating the failure as terminal. */
        private const val maxPageReadRetries = 2
        private const val pageReadRetryBaseDelayMs = 200L

        private const val MILLIS_PER_DAY = 24L * 60 * 60 * 1000

        /**
         * The `read_anchors.store` value for every Health Connect cursor — the counterpart of
         * iOS's `"healthkit"`, and the same token the permission-state rows are filed under
         * (`AppEnvironment.readHealthConnectedFromDisk`).
         */
        const val anchorStore = "healthConnect"

        /**
         * `source_id` for a record whose `dataOrigin` package is empty, and the id of the generic
         * descriptor. An honest label for "Health Connect gave us this and did not say who wrote
         * it" — never a fabricated writer.
         */
        const val fallbackSourceId = "healthConnect"

        private const val healthConnectPackage = "com.google.android.apps.healthdata"

        /**
         * Value written to `workout_routes.consent_snapshot`. Versioned so that a later consent
         * model (per-route, per-source, time-limited) is distinguishable on old rows rather than
         * retroactively assumed to have been the current one.
         */
        const val routeConsentSnapshot = "route.consent.v1:granted"

        /** READ permissions for the record types BADAN maps (I: raw data is not paywalled). */
        val permissions: Set<String> = HcTypeMap.permissions

        /** Contract to register in a Compose launcher for requesting the [permissions] above. */
        fun requestPermissionsContract() = PermissionController.createRequestPermissionResultContract()

        /**
         * Exercise-type codes shared with iOS's workout vocabulary. Deliberately a partial map of
         * the ~80 Health Connect types: only entries with a real HealthKit counterpart are named,
         * so a code means the same activity on both platforms. Anything else falls through to
         * `hc_type_<n>` rather than being coerced into a near-neighbour that would make a
         * cross-platform fixture pass while describing the wrong sport.
         */
        private val exerciseTypeCodes: Map<Int, String> = mapOf(
            ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON to "badminton",
            ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL to "baseball",
            ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL to "basketball",
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING to "cycling",
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY to "cycling_indoor",
            ExerciseSessionRecord.EXERCISE_TYPE_BOXING to "boxing",
            ExerciseSessionRecord.EXERCISE_TYPE_CALISTHENICS to "calisthenics",
            ExerciseSessionRecord.EXERCISE_TYPE_CRICKET to "cricket",
            ExerciseSessionRecord.EXERCISE_TYPE_DANCING to "dance",
            ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL to "elliptical",
            ExerciseSessionRecord.EXERCISE_TYPE_GOLF to "golf",
            ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS to "gymnastics",
            ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING to "hiit",
            ExerciseSessionRecord.EXERCISE_TYPE_HIKING to "hiking",
            ExerciseSessionRecord.EXERCISE_TYPE_PILATES to "pilates",
            ExerciseSessionRecord.EXERCISE_TYPE_ROWING to "rowing",
            ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE to "rowing_indoor",
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING to "running",
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL to "running_indoor",
            ExerciseSessionRecord.EXERCISE_TYPE_SKIING to "skiing",
            ExerciseSessionRecord.EXERCISE_TYPE_SOCCER to "soccer",
            ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING to "stair_climbing",
            ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING to "strength_training",
            ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "swimming_open_water",
            ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL to "swimming_pool",
            ExerciseSessionRecord.EXERCISE_TYPE_TENNIS to "tennis",
            ExerciseSessionRecord.EXERCISE_TYPE_VOLLEYBALL to "volleyball",
            ExerciseSessionRecord.EXERCISE_TYPE_WALKING to "walking",
            ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING to "weightlifting",
            ExerciseSessionRecord.EXERCISE_TYPE_YOGA to "yoga",
            ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT to "other",
        )
    }
}

/**
 * One page of a windowed Health Connect read, with the SDK response type stripped off.
 *
 * Deliberately not `ReadRecordsResponse`: keeping [WindowedTypeRead] free of connect-client types
 * is what lets a plain JVM test drive the page loop, and the page loop is where audit finding #3
 * lived.
 */
internal data class HealthPage<T>(val records: List<T>, val nextPageToken: String?)

/**
 * One record type's full windowed read, and the two-phase commit hanging off it.
 *
 * Extracted from [HealthConnectAdapter] for the same reason `StopReasonMapping` was extracted from
 * `SyncWorker`: the adapter needs a `Context`, a provider and a live `HealthConnectClient` and is
 * not JVM testable, but the rule stated here can be wrong — and was, for the whole of Phase 0. See
 * `HealthConnectCursorTest`.
 *
 * **The rule: a windowed read that did not reach its last page advances nothing.** Not the changes
 * cursor ([stageToken] is never called), and not the coverage claim ([claimCoverage] is called with
 * false so [HealthConnectAdapter] can drop a stale one). What breaks if this is "simplified" back
 * into a `break` out of the loop: Health Connect's changes feed can only be resumed from the most
 * recent token, so a cursor committed past records that were never ingested is not a delay, it is
 * data loss until the token expires (~30 days) or the user reconnects — and the sync that caused
 * it reports success, because from the caller's side nothing threw.
 *
 * Records from the pages that *did* succeed are still emitted rather than discarded, which is the
 * one place this diverges from iOS's `runAnchoredQuery` (it drops the whole result on error). The
 * reason is memory, not preference: [emit] streams, so peak usage is one page rather than the whole
 * result set — the plan's 100k-record acceptance criterion — and buffering to make the read
 * all-or-nothing would reintroduce precisely the shape that criterion removed. It is safe because
 * nothing was *committed*: the next sync re-reads the same window, and every write is idempotent by
 * (metric, external_id, source_id), so the overlap is a no-op rather than a duplicate.
 */
internal class WindowedTypeRead<T>(
    /** Reads one page. Null means "this page could not be read", never "there are no more pages". */
    private val fetchPage: suspend (pageToken: String?) -> HealthPage<T>?,
    private val emit: (T) -> Unit,
    /** Stage the fresh changes token for the post-write commit. Reached only by a complete read. */
    private val stageToken: (String) -> Unit,
    /** Called exactly once, with whether the whole window was actually read. */
    private val claimCoverage: (Boolean) -> Unit,
) {
    /**
     * Walk every page. [freshToken] is the cursor minted before the read started (null when no
     * anchor store is wired, or when Health Connect declined to mint one); it is staged only after
     * the final page, never before.
     */
    suspend fun run(freshToken: String?): Boolean {
        var pageToken: String? = null
        do {
            val page = fetchPage(pageToken)
            if (page == null) {
                claimCoverage(false)
                return false
            }
            page.records.forEach(emit)
            pageToken = page.nextPageToken
        } while (pageToken != null)
        freshToken?.let(stageToken)
        claimCoverage(true)
        return true
    }
}
