package net.albayyan.badan.export.destinations

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.CredentialRef
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.export.ExportSchema
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.random.Random

/**
 * EPIC-20 — deliver a finished export to a REST endpoint the **user** configured and controls. The
 * Android mirror of iOS `Export/Destinations/RESTDestination.swift`, decision for decision.
 *
 * This is the first networked code in the Android app, and its placement is the whole point of §8.3.
 * It lives in `export/destinations`, the one package allowed to move a finished, checksummed artifact
 * off the device. Export *generation* (`export/` writers + runner) stays provably offline — CI's
 * network-free lint runs there and must stay green — and this file consumes only what the delivery
 * seam hands it: files, a manifest sha, a schema version. It reaches into no writer's internals.
 *
 * [HttpURLConnection] appears in exactly one place, [HttpUrlConnectionRestTransport], behind the
 * [RestTransport] seam — so the delivery logic (idempotency, backoff, auth, HTTPS enforcement) is
 * unit tested against a stub, never a real socket.
 *
 * Contract §22.7:
 *  - `POST <user-url>` with `Content-Type: application/json` (single bundle) or `application/x-ndjson`
 *    (parts, when the bundle exceeds 8 MB).
 *  - Headers: `Authorization: Bearer <token>` (from the Keystore, **never** the database),
 *    `X-Badan-Schema-Version`, `X-Badan-Manifest-Sha`, `Idempotency-Key` (= manifest sha, suffixed
 *    `:n` per part), `X-Badan-Part: n/of` on parts.
 *  - Responses: 2xx = delivered; 409 = duplicate, **treated as delivered**; 401/403 → `authExpired`;
 *    408/429/5xx/timeout → capped exponential backoff (30s/5m/30m, jittered) then `failedDelivery`.
 *  - HTTPS enforced. Plain `http://` is refused unless a developer explicitly opts in for LAN use.
 */
class RestDestination(
    private val transport: RestTransport,
    private val credentials: RestCredentialStore,
    private val backoff: RestBackoffPolicy = RestBackoffPolicy.STANDARD,
    /** Injected so tests do not wait 35 minutes. Default suspends for real. */
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
    /** Injected so a test can pin the jitter. Default is a real uniform draw in `0.0..1.0`. */
    private val rng: () -> Double = { Random.nextDouble() },
    /**
     * The §22.7 escape hatch: **off by default**. When true, BADAN's own HTTPS-only check stops
     * rejecting a plain `http://` endpoint for LAN use (a developer posting to a box on their own
     * network). A build/wiring-time choice a developer makes deliberately — not an end-user toggle.
     *
     * The risk, stated plainly: over `http://`, the bearer token and every exported health value
     * travel in clear text and anything on the path can read or alter them. Acceptable only on a
     * trusted local network the developer controls — which is why the default is HTTPS-only.
     *
     * On Android this flag alone is **not** sufficient, and that is deliberate: with `targetSdk` 36
     * the platform blocks cleartext traffic by default, so a shipped build refuses `http://` even
     * with this set. Reaching a cleartext LAN box additionally requires a debug-only
     * `networkSecurityConfig`, which BADAN does not ship — so no release build can send an export
     * unencrypted, whatever this flag says.
     */
    private val allowInsecureHttpForDevelopment: Boolean = false,
    /**
     * Bundles at or below this size go as one `application/json` POST; larger ones split into
     * `application/x-ndjson` parts (§22.7). Measured on raw artifact bytes ("bundles > 8 MB").
     * Injectable so part-splitting is testable without multi-megabyte fixtures.
     */
    private val maxBundleBytes: Long = DEFAULT_MAX_BUNDLE_BYTES,
) : ExportDestinationDelivering {

    override val kind: ExportDestinationKind = ExportDestinationKind.REST_API

    private val json = Json

    // -- Verification ping (§12 EPIC-14) --

    override suspend fun verify(destination: ExportDestination, now: Long): ExportDestinationProbe {
        if (destination.status == ExportDestinationStatus.DISABLED) {
            return ExportDestinationProbe(
                status = ExportDestinationStatus.DISABLED, checkedAt = now,
                errorCode = ExportErrorCode.DESTINATION_DISABLED,
                message = DestinationMessages.destinationDisabled,
            )
        }
        val endpoint = when (val r = resolveEndpoint(destination)) {
            is EndpointResolution.Failure -> return r.failure.probe(now)
            is EndpointResolution.Ok -> r.endpoint
        }
        val token = token(destination) ?: return ExportDestinationProbe(
            status = ExportDestinationStatus.AUTH_EXPIRED, checkedAt = now,
            errorCode = ExportErrorCode.DESTINATION_AUTH_EXPIRED,
            message = DestinationMessages.restCredentialMissing,
        )

        val schema = schemaVersionHeader(null)
        val body = """{"badan_probe":true,"schema_version":"$schema"}""".toByteArray(Charsets.UTF_8)
        val headers = baseHeaders(token, schema, "probe").toMutableMap().apply {
            put("X-Badan-Probe", "1")
            put("Content-Type", "application/json")
        }
        return when (val category = categorize(transport.perform(
            RestRequest(endpoint.url, endpoint.method, headers, body)))) {
            is AttemptCategory.Delivered -> ExportDestinationProbe(
                status = ExportDestinationStatus.OK, checkedAt = now,
                message = DestinationMessages.restProbeReachable,
            )
            is AttemptCategory.AuthFailed -> ExportDestinationProbe(
                status = ExportDestinationStatus.AUTH_EXPIRED, checkedAt = now,
                errorCode = ExportErrorCode.DESTINATION_AUTH_EXPIRED,
                message = DestinationMessages.restAuthExpired,
            )
            is AttemptCategory.RetryableHttp -> ExportDestinationProbe(
                status = ExportDestinationStatus.UNREACHABLE, checkedAt = now,
                errorCode = ExportErrorCode.DESTINATION_UNREACHABLE,
                message = DestinationMessages.restServerError(category.status),
            )
            is AttemptCategory.NonRetryable -> ExportDestinationProbe(
                status = ExportDestinationStatus.UNREACHABLE, checkedAt = now,
                errorCode = ExportErrorCode.DESTINATION_UNREACHABLE,
                message = DestinationMessages.restServerError(category.status),
            )
            is AttemptCategory.RetryableConnectivity -> ExportDestinationProbe(
                status = ExportDestinationStatus.UNREACHABLE, checkedAt = now,
                errorCode = ExportErrorCode.DESTINATION_UNREACHABLE,
                message = DestinationMessages.restUnreachable,
            )
        }
    }

    // -- Delivery --

    override suspend fun deliver(request: ExportDeliveryRequest, now: Long): ExportDeliveryReceipt {
        val destination = request.destination
        val expected = request.artifacts.size

        if (destination.status == ExportDestinationStatus.DISABLED) {
            return failure(ExportErrorCode.DESTINATION_DISABLED, ExportDestinationStatus.DISABLED,
                expected, DestinationMessages.destinationDisabled)
        }
        if (request.artifacts.isEmpty()) {
            return ExportDeliveryReceipt(
                outcome = net.albayyan.badan.domain.ExportOutcome.SKIPPED_NO_DATA,
                errorDetail = deliveringDetail(filesExpected = 0),
                bytesDelivered = 0L, destinationStatus = ExportDestinationStatus.OK,
                message = DestinationMessages.nothingToDeliver,
            )
        }
        val endpoint = when (val r = resolveEndpoint(destination)) {
            is EndpointResolution.Failure -> return r.failure.receipt(expected)
            is EndpointResolution.Ok -> r.endpoint
        }
        val token = token(destination) ?: return ExportDeliveryReceipt(
            outcome = net.albayyan.badan.domain.ExportOutcome.FAILED_DELIVERY,
            errorCode = ExportErrorCode.DESTINATION_AUTH_EXPIRED,
            errorDetail = deliveringDetail(filesWritten = 0, filesExpected = expected),
            bytesDelivered = 0L, destinationStatus = ExportDestinationStatus.AUTH_EXPIRED,
            message = DestinationMessages.restCredentialMissing,
        )

        val schema = schemaVersionHeader(request)
        val sha = bundleSha(request)
        val plans = partPlans(request.artifacts)
        val of = plans.size
        // §22.7 keys the wire format on the **bundle size**, not on how many parts it happened to
        // split into: "bundles > 8 MB sent as NDJSON parts". A single artifact larger than the cap is
        // the commonest oversized export there is (one big `raw.csv`), and deciding the format from
        // `plans.size` would have sent exactly that case as one `application/json` body — the
        // contract's one hard size rule, broken by its most likely input. So the stream mode is
        // decided here, and a lone oversized part is honestly labelled `X-Badan-Part: 1/1`.
        val streamed = request.artifacts.sumOf { it.byteCount } > maxBundleBytes

        var deliveredArtifacts = 0
        var deliveredBytes = 0L
        for ((index, plan) in plans.withIndex()) {
            val n = index + 1
            val built = buildBody(plan, if (streamed) n else null, of, schema, sha)
                ?: return ExportDeliveryReceipt(
                    // A source artifact could not be read — a staging bug, not the endpoint's fault.
                    outcome = if (deliveredArtifacts > 0) {
                        net.albayyan.badan.domain.ExportOutcome.PARTIAL
                    } else {
                        net.albayyan.badan.domain.ExportOutcome.FAILED_DELIVERY
                    },
                    errorCode = ExportErrorCode.WRITE_FAILED,
                    errorDetail = deliveringDetail(filesWritten = deliveredArtifacts, filesExpected = expected),
                    bytesDelivered = deliveredBytes,
                    deliveredAt = if (deliveredArtifacts > 0) now else null,
                    destinationStatus = ExportDestinationStatus.OK,
                    message = if (deliveredArtifacts > 0) {
                        DestinationMessages.restPartiallyDelivered(deliveredArtifacts, expected)
                    } else {
                        DestinationMessages.restSourceUnreadable
                    },
                    needsRepick = false,
                )
            val (data, contentType) = built
            val headers = baseHeaders(token, schema, sha).toMutableMap().apply {
                put("Content-Type", contentType)
                if (streamed) {
                    put("X-Badan-Part", "$n/$of")
                    put("Idempotency-Key", "$sha:$n")
                }
            }
            when (val outcome = sendWithBackoff(RestRequest(endpoint.url, endpoint.method, headers, data))) {
                is PartOutcome.Delivered -> {
                    deliveredArtifacts += plan.size
                    deliveredBytes += plan.sumOf { it.byteCount }
                }
                is PartOutcome.AuthFailed -> return terminal(
                    ExportErrorCode.DESTINATION_AUTH_EXPIRED, ExportDestinationStatus.AUTH_EXPIRED,
                    deliveredArtifacts, deliveredBytes, expected, now,
                    DestinationMessages.restAuthExpired, httpStatus = outcome.status)
                is PartOutcome.ServerRejected -> return terminal(
                    ExportErrorCode.WRITE_FAILED, ExportDestinationStatus.OK,
                    deliveredArtifacts, deliveredBytes, expected, now,
                    DestinationMessages.restServerError(outcome.status), httpStatus = outcome.status)
                // No status: the endpoint never answered. `errorCode` carries that fact.
                is PartOutcome.Unreachable -> return terminal(
                    ExportErrorCode.DESTINATION_UNREACHABLE, ExportDestinationStatus.OK,
                    deliveredArtifacts, deliveredBytes, expected, now,
                    DestinationMessages.restUnreachable, httpStatus = null)
            }
        }

        return ExportDeliveryReceipt(
            outcome = net.albayyan.badan.domain.ExportOutcome.SUCCESS,
            errorDetail = deliveringDetail(filesWritten = deliveredArtifacts, filesExpected = expected),
            bytesDelivered = deliveredBytes, deliveredAt = now,
            destinationStatus = ExportDestinationStatus.OK,
            message = DestinationMessages.restDelivered,
        )
    }

    /**
     * A part failed after any retries. `PARTIAL` if earlier parts landed, else `FAILED_DELIVERY`.
     *
     * [httpStatus] is the §22.7 half of the ledger's error record that the closed [ExportErrorCode]
     * vocabulary cannot express — the code the server actually answered with. It rides on
     * `errorDetail` because that is the field the runner persists verbatim; `message` is read by the
     * UI and never reaches `export_runs`.
     */
    private fun terminal(
        code: ExportErrorCode,
        destinationStatus: ExportDestinationStatus,
        delivered: Int,
        bytes: Long,
        expected: Int,
        now: Long,
        message: LocalizedString,
        httpStatus: Int? = null,
    ): ExportDeliveryReceipt = ExportDeliveryReceipt(
        outcome = if (delivered > 0) {
            net.albayyan.badan.domain.ExportOutcome.PARTIAL
        } else {
            net.albayyan.badan.domain.ExportOutcome.FAILED_DELIVERY
        },
        errorCode = code,
        errorDetail = deliveringDetail(filesWritten = delivered, filesExpected = expected,
            httpStatus = httpStatus),
        bytesDelivered = bytes,
        deliveredAt = if (delivered > 0) now else null,
        destinationStatus = destinationStatus,
        message = if (delivered > 0) {
            DestinationMessages.restPartiallyDelivered(delivered, expected)
        } else {
            message
        },
    )

    private fun failure(
        code: ExportErrorCode,
        status: ExportDestinationStatus,
        expected: Int,
        message: LocalizedString,
    ): ExportDeliveryReceipt = ExportDeliveryReceipt(
        outcome = net.albayyan.badan.domain.ExportOutcome.FAILED_DELIVERY, errorCode = code,
        errorDetail = deliveringDetail(filesWritten = 0, filesExpected = expected),
        bytesDelivered = 0L, destinationStatus = status, message = message,
    )

    // -- One part, with the capped backoff (§22.7) --

    private sealed class PartOutcome {
        object Delivered : PartOutcome()

        /**
         * 401/403. Carries the code so the ledger records which one (§22.7) — the remedy is the same
         * for both, but "the token is rejected" and "this token may not write here" are not the same
         * report to a user debugging their own server.
         */
        data class AuthFailed(val status: Int) : PartOutcome()

        /** A terminal 4xx, or a 408/429/5xx that survived every retry: the server rejected it. */
        data class ServerRejected(val status: Int) : PartOutcome()

        /** A timeout/transport failure that survived every retry: BADAN never got an answer. */
        object Unreachable : PartOutcome()
    }

    private suspend fun sendWithBackoff(request: RestRequest): PartOutcome {
        var attempt = 0
        while (true) {
            when (val category = categorize(transport.perform(request))) {
                is AttemptCategory.Delivered -> return PartOutcome.Delivered
                is AttemptCategory.AuthFailed -> return PartOutcome.AuthFailed(category.status)
                is AttemptCategory.NonRetryable -> return PartOutcome.ServerRejected(category.status)
                is AttemptCategory.RetryableHttp -> {
                    if (attempt >= backoff.delaysMs.size) return PartOutcome.ServerRejected(category.status)
                    sleeper(backoff.jittered(backoff.delaysMs[attempt], rng))
                    attempt += 1
                }
                is AttemptCategory.RetryableConnectivity -> {
                    if (attempt >= backoff.delaysMs.size) return PartOutcome.Unreachable
                    sleeper(backoff.jittered(backoff.delaysMs[attempt], rng))
                    attempt += 1
                }
            }
        }
    }

    private sealed class AttemptCategory {
        object Delivered : AttemptCategory()
        data class AuthFailed(val status: Int) : AttemptCategory()
        data class RetryableHttp(val status: Int) : AttemptCategory()
        object RetryableConnectivity : AttemptCategory()
        data class NonRetryable(val status: Int) : AttemptCategory()
    }

    private fun categorize(result: RestTransportResult): AttemptCategory = when (result) {
        is RestTransportResult.Response -> {
            val s = result.status
            when {
                s in 200..299 -> AttemptCategory.Delivered
                // 409 = the server already has this manifest sha. Idempotent replay is a success.
                s == 409 -> AttemptCategory.Delivered
                s == 401 || s == 403 -> AttemptCategory.AuthFailed(s)
                s == 408 || s == 429 || s in 500..599 -> AttemptCategory.RetryableHttp(s)
                else -> AttemptCategory.NonRetryable(s)
            }
        }
        is RestTransportResult.TimedOut -> AttemptCategory.RetryableConnectivity
        is RestTransportResult.TransportError -> AttemptCategory.RetryableConnectivity
    }

    // -- Headers, body, idempotency key --

    private fun baseHeaders(token: String, schemaVersion: String, manifestSha: String): Map<String, String> =
        mapOf(
            "Authorization" to "Bearer $token",
            "X-Badan-Schema-Version" to schemaVersion,
            "X-Badan-Manifest-Sha" to manifestSha,
            "Idempotency-Key" to manifestSha,
        )

    private fun schemaVersionHeader(request: ExportDeliveryRequest?): String =
        request?.schemaVersion ?: ExportSchema.VERSION

    /**
     * The `Idempotency-Key`/`X-Badan-Manifest-Sha` value. Prefers the manifest sha the runner
     * computed (so it matches the `ExportRun` ledger row); falls back to a deterministic digest of
     * the ordered artifact bytes. Both are stable per *generated* bundle and change on regeneration —
     * exactly the idempotency semantics the contract wants.
     */
    private fun bundleSha(request: ExportDeliveryRequest): String {
        request.manifestSha?.let { return it.hex }
        val digest = MessageDigest.getInstance("SHA-256")
        for (artifact in request.artifacts.sortedBy { it.fileName }) {
            digest.update(artifact.fileName.toByteArray(Charsets.UTF_8))
            digest.update(0x1F)
            if (artifact.source.exists()) digest.update(artifact.source.readBytes())
            digest.update(0x1E)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Whole artifacts are packed into parts; a single artifact is never split across two. */
    private fun partPlans(artifacts: List<ExportArtifact>): List<List<ExportArtifact>> {
        val total = artifacts.sumOf { it.byteCount }
        if (total <= maxBundleBytes) return listOf(artifacts)

        val plans = mutableListOf<List<ExportArtifact>>()
        var current = mutableListOf<ExportArtifact>()
        var currentBytes = 0L
        for (artifact in artifacts) {
            if (current.isNotEmpty() && currentBytes + artifact.byteCount > maxBundleBytes) {
                plans.add(current)
                current = mutableListOf()
                currentBytes = 0L
            }
            current.add(artifact)
            currentBytes += artifact.byteCount
        }
        if (current.isNotEmpty()) plans.add(current)
        return plans
    }

    /** Returns (body, contentType), or null if a source artifact could not be read. */
    private fun buildBody(
        plan: List<ExportArtifact>,
        partIndex: Int?,
        of: Int,
        schema: String,
        manifestSha: String,
    ): Pair<ByteArray, String>? = try {
        val encoder = Base64.getEncoder()
        if (partIndex != null) {
            val lines = plan.map { artifact ->
                val bytes = artifact.source.readBytes()
                json.encodeToString(
                    NdjsonLine(schema, manifestSha, partIndex, of, artifact.fileName,
                        artifact.byteCount, encoder.encodeToString(bytes)))
            }
            (lines.joinToString("\n") + "\n").toByteArray(Charsets.UTF_8) to "application/x-ndjson"
        } else {
            val envelopes = plan.map { artifact ->
                val bytes = artifact.source.readBytes()
                ArtifactEnvelope(artifact.fileName, artifact.byteCount, encoder.encodeToString(bytes))
            }
            json.encodeToString(BundleEnvelope(schema, manifestSha, envelopes))
                .toByteArray(Charsets.UTF_8) to "application/json"
        }
    } catch (_: Exception) {
        null
    }

    // -- Endpoint + credential resolution --

    private data class Endpoint(val url: String, val method: String)

    private sealed class EndpointResolution {
        data class Ok(val endpoint: Endpoint) : EndpointResolution()
        data class Failure(val failure: RestFailure) : EndpointResolution()
    }

    private fun resolveEndpoint(destination: ExportDestination): EndpointResolution {
        if (destination.kind != ExportDestinationKind.REST_API) {
            return EndpointResolution.Failure(
                RestFailure(ExportErrorCode.UNKNOWN, destination.status,
                    DestinationMessages.destinationNotConfigured))
        }
        val raw = destination.config.endpointURL
        val scheme = raw?.let { runCatching { URI(it).scheme?.lowercase() }.getOrNull() }
        val host = raw?.let { runCatching { URI(it).host }.getOrNull() }
        if (raw.isNullOrEmpty() || scheme == null || host.isNullOrEmpty()) {
            return EndpointResolution.Failure(
                RestFailure(ExportErrorCode.DESTINATION_UNREACHABLE, destination.status,
                    DestinationMessages.restNotConfigured))
        }
        if (scheme == "http" && !allowInsecureHttpForDevelopment) {
            // Refused before a single byte leaves the device. Default HTTPS-only.
            //
            // The row's own `tlsPolicy` is deliberately not branched on here, and that is not an
            // oversight: `ExportDestination` defaults a network kind to `HTTPS_ONLY`, and
            // `ExportTlsPolicy` has no vocabulary for "cleartext permitted" (`NOT_APPLICABLE` means
            // *no transport at all*, which a `REST_API` row never is). So a row cannot express the
            // opt-in, and the opt-in is a build-time developer flag instead — what §22.7's "explicit
            // developer toggle" asks for. This branch enforces exactly what every `REST_API` row
            // declares.
            return EndpointResolution.Failure(
                RestFailure(ExportErrorCode.DESTINATION_UNREACHABLE, destination.status,
                    DestinationMessages.restInsecureBlocked))
        }
        if (scheme != "https" && scheme != "http") {
            return EndpointResolution.Failure(
                RestFailure(ExportErrorCode.DESTINATION_UNREACHABLE, destination.status,
                    DestinationMessages.restNotConfigured))
        }
        val method = destination.config.httpMethod?.uppercase() ?: "POST"
        return EndpointResolution.Ok(Endpoint(raw, method))
    }

    /**
     * The bearer token, read from the Keystore-backed store via the destination's [CredentialRef].
     * **Never the database** — the `credentialRef` column holds a key, and the secret behind it lives
     * only in protected storage (§9.4, enforced by [CredentialRef]).
     */
    private fun token(destination: ExportDestination): String? {
        val ref = destination.credentialRef ?: return null
        return credentials.token(ref)?.takeIf { it.isNotEmpty() }
    }

    private data class RestFailure(
        val errorCode: ExportErrorCode,
        val destinationStatus: ExportDestinationStatus,
        val message: LocalizedString,
    ) {
        fun probe(now: Long): ExportDestinationProbe = ExportDestinationProbe(
            status = if (destinationStatus == ExportDestinationStatus.DISABLED) {
                ExportDestinationStatus.DISABLED
            } else {
                ExportDestinationStatus.UNREACHABLE
            },
            checkedAt = now, errorCode = errorCode, message = message,
        )

        fun receipt(expected: Int): ExportDeliveryReceipt = ExportDeliveryReceipt(
            outcome = net.albayyan.badan.domain.ExportOutcome.FAILED_DELIVERY, errorCode = errorCode,
            errorDetail = deliveringDetail(filesWritten = 0, filesExpected = expected),
            bytesDelivered = 0L, destinationStatus = destinationStatus, message = message,
        )
    }

    companion object {
        const val DEFAULT_MAX_BUNDLE_BYTES = 8L * 1024 * 1024
    }
}

// -- Body shapes --

/**
 * One artifact inside a single-POST `application/json` bundle. Content is base64 so the envelope
 * carries CSV, JSON, or an encrypted container byte-for-byte without ever interpreting it — a
 * destination that parsed the payload would be reading a writer's output, the coupling §8.3 forbids.
 */
@Serializable
private data class ArtifactEnvelope(
    val file: String,
    @SerialName("byte_count") val byteCount: Long,
    @SerialName("content_base64") val contentBase64: String,
)

@Serializable
private data class BundleEnvelope(
    @SerialName("schema_version") val schemaVersion: String,
    @SerialName("manifest_sha") val manifestSha: String,
    val artifacts: List<ArtifactEnvelope>,
)

/** One NDJSON line (part mode). Every line self-describes its part. */
@Serializable
private data class NdjsonLine(
    @SerialName("schema_version") val schemaVersion: String,
    @SerialName("manifest_sha") val manifestSha: String,
    val part: Int,
    val of: Int,
    val file: String,
    @SerialName("byte_count") val byteCount: Long,
    @SerialName("content_base64") val contentBase64: String,
)

// -- Transport seam (the only place HttpURLConnection is allowed) --

data class RestRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    // Arrays don't get structural equals from data classes; the delivery logic never compares
    // requests, but keeping these honest avoids a surprising == elsewhere.
    override fun equals(other: Any?): Boolean =
        other is RestRequest && url == other.url && method == other.method &&
            headers == other.headers && body.contentEquals(other.body)

    override fun hashCode(): Int =
        (((url.hashCode() * 31 + method.hashCode()) * 31 + headers.hashCode()) * 31) + body.contentHashCode()
}

/**
 * What one POST concluded. Deliberately **carries no response body and no error message** — a
 * server's error text can echo back what BADAN sent, so surfacing it would be a health-value leak.
 * The status code is all a caller needs.
 */
sealed class RestTransportResult {
    data class Response(val status: Int) : RestTransportResult()
    object TimedOut : RestTransportResult()
    object TransportError : RestTransportResult()
}

/** The seam that keeps [HttpURLConnection] out of the delivery logic. Tests use a stub. */
interface RestTransport {
    suspend fun perform(request: RestRequest): RestTransportResult
}

/**
 * The single networking implementation in BADAN Android. Isolated here so CI's network-free lint on
 * the generation module stays green and the retry/idempotency logic stays testable off the wire.
 *
 * It is constructed in exactly one place, [RestDestinationAvailability.deliverers], and that branch
 * is gated off in this build — so nothing in a shipped APK reaches this class, and the manifest
 * declares no `INTERNET` permission for it to use if it did.
 */
class HttpUrlConnectionRestTransport(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 60_000,
) : RestTransport {
    override suspend fun perform(request: RestRequest): RestTransportResult = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
                requestMethod = request.method
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
                doOutput = true
                for ((name, value) in request.headers) setRequestProperty(name, value)
            }
            connection.outputStream.use { it.write(request.body) }
            // Triggers the request. The response body is intentionally never read or surfaced.
            RestTransportResult.Response(connection.responseCode)
        } catch (_: SocketTimeoutException) {
            RestTransportResult.TimedOut
        } catch (_: Exception) {
            RestTransportResult.TransportError
        } finally {
            connection?.disconnect()
        }
    }
}

// -- Backoff policy --

/**
 * Capped exponential backoff, §22.7: three retry attempts after the first send, waiting 30s / 5m /
 * 30m (jittered) before each. On a persistently failing endpoint that is four network attempts and
 * three sleeps, then `failedDelivery`.
 */
data class RestBackoffPolicy(
    val delaysMs: List<Long>,
    /** Fraction of jitter applied either side of each delay. 0 = exact delays (used by tests). */
    val jitterFraction: Double,
) {
    /** `delay` scaled into `[delay·(1-j), delay·(1+j)]` by a draw from `rng` in `0.0..1.0`. */
    fun jittered(delayMs: Long, rng: () -> Double): Long {
        if (jitterFraction <= 0.0) return delayMs
        val span = delayMs * jitterFraction
        return (delayMs - span + (rng() * 2 * span)).toLong()
    }

    companion object {
        val STANDARD = RestBackoffPolicy(
            delaysMs = listOf(30_000L, 5 * 60_000L, 30 * 60_000L), jitterFraction = 0.15)
    }
}

// -- Credential storage (Keystore only) --

/**
 * Where a REST destination's bearer token lives — the Keystore, never the database.
 *
 * [ExportDestination.credentialRef] is a validated Keystore *key* ([CredentialRef]); this interface
 * is the other half of that promise, and it is an interface so the delivery logic can be tested with
 * an in-memory double that never touches the Keystore.
 */
interface RestCredentialStore {
    fun token(ref: CredentialRef): String?
    fun store(ref: CredentialRef, token: String): Boolean
    fun remove(ref: CredentialRef)
}

/**
 * AndroidKeyStore-backed store: the token is encrypted with an AES-256-GCM key held in the hardware
 * keystore and only the ciphertext (iv‖ct) is kept in a private prefs file. This is the Android
 * analogue of iOS's Keychain item — the secret bytes never sit in plaintext storage, and never in
 * the database. Framework-dependent, so it is exercised on device rather than by the JVM unit tests,
 * exactly like [SharedPrefsTreeUriStore]; the delivery logic is tested through [InMemoryRestCredentialStore].
 */
class KeystoreRestCredentialStore(context: Context) : RestCredentialStore {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun secretKey(): SecretKey {
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    override fun token(ref: CredentialRef): String? {
        val stored = prefs.getString(ref.key, null) ?: return null
        return try {
            val blob = Base64.getDecoder().decode(stored)
            val iv = blob.copyOfRange(0, GCM_IV_BYTES)
            val cipherText = blob.copyOfRange(GCM_IV_BYTES, blob.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    override fun store(ref: CredentialRef, token: String): Boolean = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val cipherText = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(ref.key, Base64.getEncoder().encodeToString(iv + cipherText)).commit()
    } catch (_: Exception) {
        false
    }

    override fun remove(ref: CredentialRef) {
        prefs.edit().remove(ref.key).apply()
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "badan.export.rest-credential"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        const val PREFS = "badan.export.rest_credentials"
    }
}

/** Test double, and the reason [RestCredentialStore] is an interface. */
class InMemoryRestCredentialStore(initial: Map<String, String> = emptyMap()) : RestCredentialStore {
    private val items = initial.toMutableMap()

    override fun token(ref: CredentialRef): String? = items[ref.key]
    override fun store(ref: CredentialRef, token: String): Boolean {
        items[ref.key] = token
        return true
    }
    override fun remove(ref: CredentialRef) { items.remove(ref.key) }
}
