package net.albayyan.badan

import kotlinx.coroutines.runBlocking
import net.albayyan.badan.domain.CredentialRef
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationConfig
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ManifestDigest
import net.albayyan.badan.export.ExportSchema
import net.albayyan.badan.export.destinations.DestinationMessages
import net.albayyan.badan.export.destinations.ExportArtifact
import net.albayyan.badan.export.destinations.ExportDeliveryRequest
import net.albayyan.badan.export.destinations.InMemoryRestCredentialStore
import net.albayyan.badan.export.destinations.RestBackoffPolicy
import net.albayyan.badan.export.destinations.RestDestination
import net.albayyan.badan.export.destinations.RestRequest
import net.albayyan.badan.export.destinations.RestTransport
import net.albayyan.badan.export.destinations.RestTransportResult
import net.albayyan.badan.storage.JsonCoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * EPIC-20 — the REST API destination (§22.7), the Android mirror of `RESTDestinationTests.swift`.
 * Exercises the response contract (2xx, 409-as-success, 401/403 → authExpired, capped backoff →
 * failedDelivery), HTTPS enforcement, header/idempotency shape, NDJSON part-splitting, and the
 * value-free error record — all against a stub transport, so no test touches a real socket.
 */
class RestDestinationTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val deviceId = "test-device"
    private val runDate = 1_783_080_000_000L
    private val sha = ManifestDigest.of("a".repeat(64))!!

    // -- Success + idempotency --

    @Test
    fun successfulDeliveryReportsSuccessAndBytes() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        val subject = subject(transport)
        val artifacts = listOf(artifact("a.json", "{\"x\":1}"))
        val receipt = subject.deliver(request(artifacts), runDate)

        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertNotNull(receipt.deliveredAt)
        assertEquals(artifacts[0].byteCount, receipt.bytesDelivered)
        assertNull(receipt.errorCode)
        assertEquals(1, transport.captured.size)
    }

    @Test
    fun conflict409IsTreatedAsDelivered() = runBlocking {
        val subject = subject(StubRestTransport(listOf(RestTransportResult.Response(409))))
        val receipt = subject.deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        assertNull(receipt.errorCode)
    }

    // -- Headers + idempotency key --

    @Test
    fun headersCarryBearerSchemaAndManifestSha() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)

        val headers = transport.captured.first().headers
        assertEquals("Bearer test-token", headers["Authorization"])
        assertEquals(ExportSchema.VERSION, headers["X-Badan-Schema-Version"])
        assertEquals(sha.hex, headers["X-Badan-Manifest-Sha"])
        assertEquals(sha.hex, headers["Idempotency-Key"]) // == manifest sha for a single POST (§22.7)
        assertEquals("application/json", headers["Content-Type"])
        assertNull(headers["X-Badan-Part"])
    }

    @Test
    fun schemaVersionFallsBackToBuildConstant() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        val req = ExportDeliveryRequest(destination(), listOf(artifact("a.json", "{}")), runDate,
            manifestSha = sha, schemaVersion = null)
        subject(transport).deliver(req, runDate)
        assertEquals(ExportSchema.VERSION, transport.captured.first().headers["X-Badan-Schema-Version"])
    }

    @Test
    fun fallbackManifestShaIsDeterministicAndStable() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200), RestTransportResult.Response(200)))
        val subject = subject(transport)
        val req = ExportDeliveryRequest(destination(), listOf(artifact("a.json", "{\"x\":1}")), runDate)
        subject.deliver(req, runDate)
        subject.deliver(req, runDate)

        val first = transport.captured[0].headers["Idempotency-Key"]!!
        val second = transport.captured[1].headers["Idempotency-Key"]!!
        assertEquals(first, second)
        assertEquals(64, first.length)
        assertEquals(first, transport.captured[0].headers["X-Badan-Manifest-Sha"])
    }

    // -- Auth --

    @Test
    fun authFailureMarksDestinationAuthExpired() = runBlocking {
        for (status in listOf(401, 403)) {
            val transport = StubRestTransport(listOf(RestTransportResult.Response(status)))
            val receipt = subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
            assertEquals("HTTP $status", ExportOutcome.FAILED_DELIVERY, receipt.outcome)
            assertEquals("HTTP $status", ExportErrorCode.DESTINATION_AUTH_EXPIRED, receipt.errorCode)
            assertEquals("HTTP $status", ExportDestinationStatus.AUTH_EXPIRED, receipt.destinationStatus)
            assertEquals("HTTP $status", 1, transport.captured.size)
        }
    }

    @Test
    fun missingCredentialFailsAuthExpiredWithoutTouchingNetwork() = runBlocking {
        val transport = StubRestTransport(emptyList())
        val subject = RestDestination(transport, InMemoryRestCredentialStore(), sleeper = {})
        val receipt = subject.deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.DESTINATION_AUTH_EXPIRED, receipt.errorCode)
        assertEquals(ExportDestinationStatus.AUTH_EXPIRED, receipt.destinationStatus)
        assertTrue(transport.captured.isEmpty())
    }

    // -- Backoff (§22.7) --

    @Test
    fun backoffCapsAtThreeRetriesThenFailedDelivery() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(500))
        val sleeps = mutableListOf<Long>()
        val subject = subject(transport, sleeper = { sleeps.add(it) })
        val receipt = subject.deliver(request(listOf(artifact("a.json", "{}"))), runDate)

        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.WRITE_FAILED, receipt.errorCode)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertEquals(4, transport.captured.size)
        assertEquals(listOf(30_000L, 300_000L, 1_800_000L), sleeps)
    }

    @Test
    fun timeoutExhaustedReportsUnreachable() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.TimedOut)
        val receipt = subject(transport, sleeper = {}).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, receipt.errorCode)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertEquals(4, transport.captured.size)
    }

    @Test
    fun retryThenSuccessStopsEarly() = runBlocking {
        val transport = StubRestTransport(listOf(
            RestTransportResult.Response(429), RestTransportResult.Response(503), RestTransportResult.Response(200)))
        val sleeps = mutableListOf<Long>()
        val receipt = subject(transport, sleeper = { sleeps.add(it) })
            .deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        assertEquals(3, transport.captured.size)
        assertEquals(listOf(30_000L, 300_000L), sleeps)
    }

    @Test
    fun nonRetryable4xxStopsImmediately() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(400)))
        val receipt = subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.WRITE_FAILED, receipt.errorCode)
        assertEquals(1, transport.captured.size)
    }

    // -- HTTPS enforcement --

    @Test
    fun httpEndpointIsRefusedBeforeAnyBytesLeaveTheDevice() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val subject = RestDestination(transport, creds(), sleeper = {})
        val dest = destination(url = "http://box.local/ingest")
        val receipt = subject.deliver(
            ExportDeliveryRequest(dest, listOf(artifact("a.json", "{}")), runDate, manifestSha = sha), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, receipt.errorCode)
        assertTrue(transport.captured.isEmpty())
    }

    @Test
    fun httpEndpointIsAllowedOnlyWithTheDeveloperToggle() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val subject = RestDestination(transport, creds(), sleeper = {}, allowInsecureHttpForDevelopment = true)
        val dest = destination(url = "http://box.local/ingest")
        val receipt = subject.deliver(
            ExportDeliveryRequest(dest, listOf(artifact("a.json", "{}")), runDate, manifestSha = sha), runDate)
        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        assertEquals(1, transport.captured.size)
    }

    // -- Configuration guards --

    @Test
    fun missingEndpointIsNotConfigured() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val dest = destination(url = null)
        val receipt = subject(transport).deliver(
            ExportDeliveryRequest(dest, listOf(artifact("a.json", "{}")), runDate, manifestSha = sha), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, receipt.errorCode)
        assertTrue(transport.captured.isEmpty())
    }

    @Test
    fun emptyArtifactsIsSkippedNoData() = runBlocking {
        val receipt = subject(StubRestTransport(emptyList())).deliver(request(emptyList()), runDate)
        assertEquals(ExportOutcome.SKIPPED_NO_DATA, receipt.outcome)
        assertEquals(0L, receipt.bytesDelivered)
        assertNull(receipt.deliveredAt)
    }

    @Test
    fun disabledDestinationFails() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val dest = destination().copy(status = ExportDestinationStatus.DISABLED)
        val receipt = subject(transport).deliver(
            ExportDeliveryRequest(dest, listOf(artifact("a.json", "{}")), runDate, manifestSha = sha), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.DESTINATION_DISABLED, receipt.errorCode)
        assertTrue(transport.captured.isEmpty())
    }

    @Test
    fun wrongKindDestinationFailsUnknown() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val folder = ExportDestination(id = "F1", kind = ExportDestinationKind.FILE_FOLDER,
            displayName = "folder", createdAt = runDate, updatedAt = runDate, originDeviceId = deviceId)
        val receipt = subject(transport).deliver(
            ExportDeliveryRequest(folder, listOf(artifact("a.json", "{}")), runDate, manifestSha = sha), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.UNKNOWN, receipt.errorCode)
        assertTrue(transport.captured.isEmpty())
    }

    // -- NDJSON parts (batching >8MB) --

    @Test
    fun oversizedBundleIsSplitIntoIndependentlyIdempotentNdjsonParts() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val subject = RestDestination(transport, creds(), sleeper = {}, maxBundleBytes = 4)
        val artifacts = listOf(artifact("a.json", "AAAAAAAA"), artifact("b.json", "BBBBBBBB"),
            artifact("c.json", "CCCCCCCC"))
        val receipt = subject.deliver(request(artifacts), runDate)

        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        assertEquals(3, transport.captured.size)
        transport.captured.forEachIndexed { i, captured ->
            val n = i + 1
            assertEquals("application/x-ndjson", captured.headers["Content-Type"])
            assertEquals("$n/3", captured.headers["X-Badan-Part"])
            assertEquals("${sha.hex}:$n", captured.headers["Idempotency-Key"])
            assertEquals(sha.hex, captured.headers["X-Badan-Manifest-Sha"])
        }
        assertEquals(artifacts.sumOf { it.byteCount }, receipt.bytesDelivered)
    }

    @Test
    fun singleOversizedArtifactStillStreamsAsOneNdjsonPart() = runBlocking {
        // The commonest oversized export is one big file, not many. §22.7 keys the format on the
        // bundle exceeding the cap, so this goes NDJSON labelled 1/1 — not a plain JSON body.
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val subject = RestDestination(transport, creds(), sleeper = {}, maxBundleBytes = 4)
        val receipt = subject.deliver(request(listOf(artifact("raw.csv", "AAAAAAAA"))), runDate)

        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        val headers = transport.captured.first().headers
        assertEquals("application/x-ndjson", headers["Content-Type"])
        assertEquals("1/1", headers["X-Badan-Part"])
        assertEquals("${sha.hex}:1", headers["Idempotency-Key"])
    }

    @Test
    fun atOrBelowTheCapStaysASingleJsonBody() = runBlocking {
        // The boundary is "> 8 MB", so a bundle exactly at the cap is still one JSON POST.
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(200))
        val subject = RestDestination(transport, creds(), sleeper = {}, maxBundleBytes = 8)
        subject.deliver(request(listOf(artifact("raw.csv", "AAAAAAAA"))), runDate)

        val headers = transport.captured.first().headers
        assertEquals("application/json", headers["Content-Type"])
        assertNull(headers["X-Badan-Part"])
        assertEquals(sha.hex, headers["Idempotency-Key"])
    }

    @Test
    fun partialWhenALaterPartFails() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200), RestTransportResult.Response(400)))
        val subject = RestDestination(transport, creds(), sleeper = {}, maxBundleBytes = 4)
        val artifacts = listOf(artifact("a.json", "AAAAAAAA"), artifact("b.json", "BBBBBBBB"))
        val receipt = subject.deliver(request(artifacts), runDate)

        assertEquals(ExportOutcome.PARTIAL, receipt.outcome)
        assertEquals(ExportErrorCode.WRITE_FAILED, receipt.errorCode)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertEquals(1, receipt.errorDetail.filesWritten)
        assertEquals(2, receipt.errorDetail.filesExpected)
        assertEquals(artifacts[0].byteCount, receipt.bytesDelivered)
        assertNotNull(receipt.deliveredAt)
    }

    // -- Source staging failure --

    @Test
    fun unreadableSourceIsWriteFailedNotTheEndpointsFault() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        val missing = ExportArtifact(File(temp.root, "nope.json"), "nope.json", 10L)
        val receipt = subject(transport).deliver(request(listOf(missing)), runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.WRITE_FAILED, receipt.errorCode)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertFalse(receipt.needsRepick)
        assertTrue(transport.captured.isEmpty())
    }

    // -- Value-free error record --

    @Test
    fun errorRecordCarriesNoFreeText() = runBlocking {
        // The receipt's error detail is value-free by type: a stage and integers, nothing else. This
        // asserts the encoded form — the exact text that lands in `export_runs.error_detail` — holds
        // no token, no header and no response body, the guard that makes the row safe to screenshot.
        val transport = StubRestTransport(listOf(RestTransportResult.Response(500)))
        val receipt = subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        val json = JsonCoding.encode(receipt.errorDetail)
        assertTrue(json.contains("\"stage\":\"delivering\""))
        assertFalse(json.lowercase().contains("bearer"))
        assertFalse(json.contains("test-token"))
    }

    @Test
    fun ledgerErrorRecordCarriesTheStatusCodeAndOnlyThat() = runBlocking {
        // §22.7: "status code + sanitized reason only". The reason is `errorCode` (closed
        // vocabulary); the code has to survive into `errorDetail`, because that is the field the
        // runner persists to `export_runs` — `message` is UI-only and never reaches the ledger.
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.Response(503))
        val receipt = subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertEquals(503, receipt.errorDetail.httpStatus)

        // 401/403 stay distinguishable in the ledger even though the remedy is the same.
        val auth = StubRestTransport(listOf(RestTransportResult.Response(403)))
        val authReceipt = subject(auth).deliver(request(listOf(artifact("b.json", "{}"))), runDate)
        assertEquals(403, authReceipt.errorDetail.httpStatus)
    }

    @Test
    fun noStatusIsRecordedWhenTheServerNeverAnswered() = runBlocking {
        // A timeout has no status code, and inventing one (0, -1) would make the ledger claim the
        // server said something. `errorCode` carries "never reached" on its own.
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.TimedOut)
        val receipt = subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertNull(receipt.errorDetail.httpStatus)
        assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, receipt.errorCode)
    }

    @Test
    fun successfulDeliveryRecordsNoStatus() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        val receipt = subject(transport).deliver(request(listOf(artifact("a.json", "{}"))), runDate)
        assertNull(receipt.errorDetail.httpStatus)
    }

    // -- Verify --

    @Test
    fun verifyReachableEndpointIsOk() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        val probe = subject(transport).verify(destination(), runDate)
        assertEquals(ExportDestinationStatus.OK, probe.status)
        assertTrue(probe.isWritable)
        assertEquals("1", transport.captured.first().headers["X-Badan-Probe"])
        assertTrue(String(transport.captured.first().body, Charsets.UTF_8).contains("badan_probe"))
    }

    @Test
    fun verifyAuthFailureIsAuthExpired() = runBlocking {
        val probe = subject(StubRestTransport(listOf(RestTransportResult.Response(403)))).verify(destination(), runDate)
        assertEquals(ExportDestinationStatus.AUTH_EXPIRED, probe.status)
        assertEquals(ExportErrorCode.DESTINATION_AUTH_EXPIRED, probe.errorCode)
    }

    @Test
    fun verifyTimeoutIsUnreachableWithoutRetrying() = runBlocking {
        val transport = StubRestTransport(emptyList(), fallback = RestTransportResult.TimedOut)
        val probe = subject(transport).verify(destination(), runDate)
        assertEquals(ExportDestinationStatus.UNREACHABLE, probe.status)
        assertEquals(1, transport.captured.size)
    }

    @Test
    fun verifyDisabledDestinationDoesNotTouchNetwork() = runBlocking {
        val transport = StubRestTransport(listOf(RestTransportResult.Response(200)))
        val dest = destination().copy(status = ExportDestinationStatus.DISABLED)
        val probe = subject(transport).verify(dest, runDate)
        assertEquals(ExportDestinationStatus.DISABLED, probe.status)
        assertTrue(transport.captured.isEmpty())
    }

    // -- Consent copy (both languages) --

    @Test
    fun consentCopyIsPresentInBothLanguagesAndNamesWhoChose() {
        val en = DestinationMessages.restConsent.en
        val ar = DestinationMessages.restConsent.ar
        assertTrue(en.contains("a server you control"))
        assertTrue(en.contains("never chooses this destination for you"))
        assertTrue(ar.isNotEmpty())
        assertTrue(ar.contains("خادم"))
        assertFalse(en == ar)
    }

    @Test
    fun serverErrorCopyIsolatesTheLatinStatusTokenInArabic() {
        // The Arabic sentence ends `(HTTP 503).` — a Latin word, digits, and a paren, all neutral or
        // LTR runs inside an RTL line. Without an isolate the code renders on the wrong side of
        // `HTTP`. Both platforms substitute the whole token through `isolated(...)`, so this pins the
        // property rather than the wording.
        val message = DestinationMessages.restServerError(503)
        assertTrue(message.ar.contains("⁨HTTP 503⁩"))
        assertTrue(message.en.contains("⁨HTTP 503⁩"))
        // And nothing but the code: no response body ever reaches a message.
        assertFalse(message.en.contains("{code}"))
    }

    // -- Helpers --

    private fun subject(
        transport: RestTransport,
        sleeper: suspend (Long) -> Unit = {},
    ): RestDestination = RestDestination(
        transport = transport,
        credentials = creds(),
        backoff = RestBackoffPolicy.STANDARD,
        sleeper = sleeper,
        // rng == 0.5 → jitter cancels to the exact delay, so sleeps are assertable.
        rng = { 0.5 },
    )

    private fun creds(): InMemoryRestCredentialStore {
        val ref = CredentialRef.forDestination("REST1")!!
        return InMemoryRestCredentialStore(mapOf(ref.key to "test-token"))
    }

    private fun destination(url: String? = "https://example.com/ingest"): ExportDestination =
        ExportDestination(
            id = "REST1", kind = ExportDestinationKind.REST_API, displayName = "My server",
            config = ExportDestinationConfig(endpointURL = url),
            credentialRef = CredentialRef.forDestination("REST1"),
            createdAt = runDate, updatedAt = runDate, originDeviceId = deviceId)

    private fun request(artifacts: List<ExportArtifact>): ExportDeliveryRequest =
        ExportDeliveryRequest(destination(), artifacts, runDate, manifestSha = sha, schemaVersion = ExportSchema.VERSION)

    private fun artifact(fileName: String, contents: String): ExportArtifact {
        val file = temp.newFile("src-${fileName.replace('/', '_')}-${System.nanoTime()}")
        file.writeText(contents)
        return ExportArtifact(file, fileName, contents.toByteArray(Charsets.UTF_8).size.toLong())
    }
}

/**
 * Scripted transport: returns [responses] in order, then [fallback], and captures every request so
 * headers, body, and call count can be asserted. The reason [RestTransport] is an interface.
 */
private class StubRestTransport(
    responses: List<RestTransportResult>,
    private val fallback: RestTransportResult = RestTransportResult.Response(200),
) : RestTransport {
    private val queue = ArrayDeque(responses)
    val captured = mutableListOf<RestRequest>()

    override suspend fun perform(request: RestRequest): RestTransportResult {
        captured.add(request)
        return if (queue.isNotEmpty()) queue.removeFirst() else fallback
    }
}
