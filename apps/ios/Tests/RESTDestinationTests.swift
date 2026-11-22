import XCTest
@testable import BADAN

/// EPIC-20 — the REST API destination (§22.7). Exercises the response contract (2xx, 409-as-success,
/// 401/403 → authExpired, capped backoff → failedDelivery), HTTPS enforcement, header/idempotency
/// shape, NDJSON part-splitting, and the value-free error record — all against a stub transport, so
/// no test touches a real socket.
///
/// The load-bearing ones:
///  - `test409IsTreatedAsDelivered` pins the idempotency contract: a duplicate is a success.
///  - `testBackoffCapsAtThreeRetriesThenFailedDelivery` pins that a failing endpoint stops, and when.
///  - `testHttpEndpointIsRefusedBeforeAnyBytesLeaveTheDevice` pins HTTPS-by-default.
///  - `testAuthFailureMarksDestinationAuthExpired` pins the reauthorize path.
final class RESTDestinationTests: XCTestCase {

    private let deviceId = "test-device"
    private let runDate = Date(timeIntervalSince1970: 1_783_080_000)
    private let sha = ManifestDigest(hex: String(repeating: "a", count: 64))!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-rest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Success + idempotency

    func testSuccessfulDeliveryReportsSuccessAndBytes() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        let artifacts = try [makeArtifact("a.json", "{\"x\":1}")]
        let receipt = await subject.deliver(request(artifacts), now: runDate)

        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertEqual(receipt.destinationStatus, .ok)
        XCTAssertNotNil(receipt.deliveredAt)
        XCTAssertEqual(receipt.bytesDelivered, artifacts[0].byteCount)
        XCTAssertNil(receipt.errorCode)
        XCTAssertEqual(transport.captured.count, 1)
    }

    func test409IsTreatedAsDelivered() async throws {
        // The whole reason `Idempotency-Key` exists: a duplicate is a success, not a failure.
        let (subject, _, _) = makeSubject(responses: [.response(status: 409)])
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertNil(receipt.errorCode)
    }

    func test2xxRangeAllSucceed() async throws {
        for status in [200, 201, 202, 204] {
            let (subject, _, _) = makeSubject(responses: [.response(status: status)])
            let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
            XCTAssertEqual(receipt.outcome, .success, "HTTP \(status)")
        }
    }

    // MARK: - Headers + idempotency key

    func testHeadersCarryBearerSchemaAndManifestSha() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        _ = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)

        let headers = try XCTUnwrap(transport.captured.first?.headers)
        XCTAssertEqual(headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(headers["X-Badan-Schema-Version"], ExportSchema.version)
        XCTAssertEqual(headers["X-Badan-Manifest-Sha"], sha.hex)
        // Idempotency-Key == manifest sha for a single-body POST (§22.7).
        XCTAssertEqual(headers["Idempotency-Key"], sha.hex)
        XCTAssertEqual(headers["Content-Type"], "application/json")
        // Single body carries no part header.
        XCTAssertNil(headers["X-Badan-Part"])
    }

    func testSchemaVersionHeaderFallsBackToBuildConstantWhenSeamCarriesNone() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        // A request without a schemaVersion still gets a header.
        let req = ExportDeliveryRequest(destination: destination(), artifacts: try [makeArtifact("a.json", "{}")],
                                        runDate: runDate, manifestSha: sha, schemaVersion: nil)
        _ = await subject.deliver(req, now: runDate)
        XCTAssertEqual(transport.captured.first?.headers["X-Badan-Schema-Version"], ExportSchema.version)
    }

    func testFallbackManifestShaIsDeterministicAndStable() async throws {
        // No manifest sha on the seam → the destination derives a stable digest of the bytes and
        // uses the same value for the header and the idempotency key.
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200), .response(status: 200)])
        let artifacts = try [makeArtifact("a.json", "{\"x\":1}")]
        let req = ExportDeliveryRequest(destination: destination(), artifacts: artifacts, runDate: runDate)
        _ = await subject.deliver(req, now: runDate)
        _ = await subject.deliver(req, now: runDate)

        let first = try XCTUnwrap(transport.captured[0].headers["Idempotency-Key"])
        let second = try XCTUnwrap(transport.captured[1].headers["Idempotency-Key"])
        XCTAssertEqual(first, second)                       // stable across retries of the same bundle
        XCTAssertEqual(first.count, 64)                     // a sha-256 hex
        XCTAssertEqual(first, transport.captured[0].headers["X-Badan-Manifest-Sha"])
    }

    // MARK: - Auth

    func testAuthFailureMarksDestinationAuthExpired() async throws {
        for status in [401, 403] {
            let (subject, transport, _) = makeSubject(responses: [.response(status: status)])
            let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
            XCTAssertEqual(receipt.outcome, .failedDelivery, "HTTP \(status)")
            XCTAssertEqual(receipt.errorCode, .destinationAuthExpired, "HTTP \(status)")
            XCTAssertEqual(receipt.destinationStatus, .authExpired, "HTTP \(status)")
            // Auth is terminal — no retries.
            XCTAssertEqual(transport.captured.count, 1, "HTTP \(status)")
        }
    }

    func testMissingCredentialFailsAuthExpiredWithoutTouchingTheNetwork() async throws {
        let transport = StubRESTTransport()
        let subject = RESTDestination(transport: transport, credentials: InMemoryRESTCredentialStore(),
                                      sleeper: { _ in })
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .destinationAuthExpired)
        XCTAssertEqual(receipt.destinationStatus, .authExpired)
        XCTAssertTrue(transport.captured.isEmpty)
    }

    // MARK: - Backoff (§22.7)

    func testBackoffCapsAtThreeRetriesThenFailedDelivery() async throws {
        // A permanently-500 endpoint: one initial send + three retries = four attempts, three
        // sleeps at the capped schedule, then failedDelivery.
        let (subject, transport, sleeps) = makeSubject(responses: [], fallback: .response(status: 500))
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)

        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .writeFailed) // the server answered, and kept rejecting
        XCTAssertEqual(receipt.destinationStatus, .ok)  // a transient 5xx does not condemn the destination
        XCTAssertEqual(transport.captured.count, 4)
        XCTAssertEqual(sleeps.recorded, [30, 300, 1_800])
    }

    func testTimeoutExhaustedReportsUnreachable() async throws {
        let (subject, transport, _) = makeSubject(responses: [], fallback: .timedOut)
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .destinationUnreachable)
        XCTAssertEqual(receipt.destinationStatus, .ok)
        XCTAssertEqual(transport.captured.count, 4)
    }

    func testRetryThenSuccessStopsEarly() async throws {
        // 429, then 503, then 200 — recovers on the third attempt with two sleeps.
        let (subject, transport, sleeps) = makeSubject(
            responses: [.response(status: 429), .response(status: 503), .response(status: 200)])
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertEqual(transport.captured.count, 3)
        XCTAssertEqual(sleeps.recorded, [30, 300])
    }

    func testNonRetryable4xxStopsImmediately() async throws {
        // A 400 is a client error — retrying an identical body will not help, so it stops at once.
        let (subject, transport, _) = makeSubject(responses: [.response(status: 400)])
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .writeFailed)
        XCTAssertEqual(transport.captured.count, 1)
    }

    // MARK: - HTTPS enforcement

    func testHttpEndpointIsRefusedBeforeAnyBytesLeaveTheDevice() async throws {
        let transport = StubRESTTransport(fallback: .response(status: 200))
        let subject = RESTDestination(transport: transport, credentials: creds(), sleeper: { _ in })
        let dest = destination(url: "http://box.local/ingest")
        let receipt = await subject.deliver(
            ExportDeliveryRequest(destination: dest, artifacts: try [makeArtifact("a.json", "{}")],
                                  runDate: runDate, manifestSha: sha), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .destinationUnreachable)
        // Nothing was sent — refusal happens before the transport is ever consulted.
        XCTAssertTrue(transport.captured.isEmpty)
    }

    func testHttpEndpointIsAllowedOnlyWithTheDeveloperToggle() async throws {
        let transport = StubRESTTransport(fallback: .response(status: 200))
        let subject = RESTDestination(transport: transport, credentials: creds(), sleeper: { _ in },
                                      allowInsecureHTTPForDevelopment: true)
        let dest = destination(url: "http://box.local/ingest")
        let receipt = await subject.deliver(
            ExportDeliveryRequest(destination: dest, artifacts: try [makeArtifact("a.json", "{}")],
                                  runDate: runDate, manifestSha: sha), now: runDate)
        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertEqual(transport.captured.count, 1)
        XCTAssertEqual(transport.captured.first?.url.scheme, "http")
    }

    // MARK: - Configuration guards

    func testMissingEndpointIsNotConfigured() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        let dest = destination(url: nil)
        let receipt = await subject.deliver(
            ExportDeliveryRequest(destination: dest, artifacts: try [makeArtifact("a.json", "{}")],
                                  runDate: runDate, manifestSha: sha), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .destinationUnreachable)
        XCTAssertTrue(transport.captured.isEmpty)
    }

    func testEmptyArtifactsIsSkippedNoData() async throws {
        let (subject, _, _) = makeSubject(responses: [.response(status: 200)])
        let receipt = await subject.deliver(request([]), now: runDate)
        XCTAssertEqual(receipt.outcome, .skippedNoData)
        XCTAssertEqual(receipt.bytesDelivered, 0)
        XCTAssertNil(receipt.deliveredAt)
    }

    func testDisabledDestinationFails() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        var dest = destination()
        dest.status = .disabled
        let receipt = await subject.deliver(
            ExportDeliveryRequest(destination: dest, artifacts: try [makeArtifact("a.json", "{}")],
                                  runDate: runDate, manifestSha: sha), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .destinationDisabled)
        XCTAssertTrue(transport.captured.isEmpty)
    }

    func testWrongKindDestinationFailsUnknown() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        let folder = ExportDestination(id: "F1", kind: .fileFolder, displayName: "folder",
                                       createdAt: runDate, updatedAt: runDate, originDeviceId: deviceId)
        let receipt = await subject.deliver(
            ExportDeliveryRequest(destination: folder, artifacts: try [makeArtifact("a.json", "{}")],
                                  runDate: runDate, manifestSha: sha), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .unknown)
        XCTAssertTrue(transport.captured.isEmpty)
    }

    // MARK: - NDJSON parts (batching >8MB)

    func testOversizedBundleIsSplitIntoIndependentlyIdempotentNdjsonParts() async throws {
        // A tiny threshold forces three artifacts into three parts without multi-megabyte fixtures.
        let transport = StubRESTTransport(fallback: .response(status: 200))
        let subject = RESTDestination(transport: transport, credentials: creds(), sleeper: { _ in },
                                      maxBundleBytes: 4)
        let artifacts = try [makeArtifact("a.json", "AAAAAAAA"),
                             makeArtifact("b.json", "BBBBBBBB"),
                             makeArtifact("c.json", "CCCCCCCC")]
        let receipt = await subject.deliver(request(artifacts), now: runDate)

        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertEqual(transport.captured.count, 3)
        for (i, captured) in transport.captured.enumerated() {
            let n = i + 1
            XCTAssertEqual(captured.headers["Content-Type"], "application/x-ndjson")
            XCTAssertEqual(captured.headers["X-Badan-Part"], "\(n)/3")
            // Each part independently idempotent: <sha>:<n> (§22.7).
            XCTAssertEqual(captured.headers["Idempotency-Key"], "\(sha.hex):\(n)")
            XCTAssertEqual(captured.headers["X-Badan-Manifest-Sha"], sha.hex)
        }
        XCTAssertEqual(receipt.bytesDelivered, artifacts.reduce(0) { $0 + $1.byteCount })
    }

    func testSingleOversizedArtifactStillStreamsAsOneNdjsonPart() async throws {
        // The commonest oversized export is one big file, not many. §22.7 keys the format on the
        // bundle exceeding the cap, so this goes NDJSON labelled 1/1 — not a plain JSON body.
        let transport = StubRESTTransport(fallback: .response(status: 200))
        let subject = RESTDestination(transport: transport, credentials: creds(), sleeper: { _ in },
                                      maxBundleBytes: 4)
        let receipt = await subject.deliver(request(try [makeArtifact("raw.csv", "AAAAAAAA")]), now: runDate)

        XCTAssertEqual(receipt.outcome, .success)
        let headers = try XCTUnwrap(transport.captured.first?.headers)
        XCTAssertEqual(headers["Content-Type"], "application/x-ndjson")
        XCTAssertEqual(headers["X-Badan-Part"], "1/1")
        XCTAssertEqual(headers["Idempotency-Key"], "\(sha.hex):1")
    }

    func testAtOrBelowTheCapStaysASingleJsonBody() async throws {
        // The boundary is "> 8 MB", so a bundle exactly at the cap is still one JSON POST.
        let transport = StubRESTTransport(fallback: .response(status: 200))
        let subject = RESTDestination(transport: transport, credentials: creds(), sleeper: { _ in },
                                      maxBundleBytes: 8)
        _ = await subject.deliver(request(try [makeArtifact("raw.csv", "AAAAAAAA")]), now: runDate)

        let headers = try XCTUnwrap(transport.captured.first?.headers)
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertNil(headers["X-Badan-Part"])
        XCTAssertEqual(headers["Idempotency-Key"], sha.hex)
    }

    func testPartialWhenALaterPartFails() async throws {
        let transport = StubRESTTransport(responses: [.response(status: 200), .response(status: 400)])
        let subject = RESTDestination(transport: transport, credentials: creds(), sleeper: { _ in },
                                      maxBundleBytes: 4)
        let artifacts = try [makeArtifact("a.json", "AAAAAAAA"), makeArtifact("b.json", "BBBBBBBB")]
        let receipt = await subject.deliver(request(artifacts), now: runDate)

        XCTAssertEqual(receipt.outcome, .partial)
        XCTAssertEqual(receipt.errorCode, .writeFailed)
        XCTAssertEqual(receipt.destinationStatus, .ok)
        XCTAssertEqual(receipt.errorDetail.filesWritten, 1)
        XCTAssertEqual(receipt.errorDetail.filesExpected, 2)
        XCTAssertEqual(receipt.bytesDelivered, artifacts[0].byteCount)
        XCTAssertNotNil(receipt.deliveredAt)
    }

    // MARK: - Source staging failure

    func testUnreadableSourceIsWriteFailedNotTheEndpointsFault() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        let missing = ExportArtifact(sourceURL: tempDir.appendingPathComponent("nope.json"),
                                     fileName: "nope.json", byteCount: 10)
        let receipt = await subject.deliver(request([missing]), now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .writeFailed)
        XCTAssertEqual(receipt.destinationStatus, .ok)
        XCTAssertFalse(receipt.needsRepick)
        XCTAssertTrue(transport.captured.isEmpty) // never sent — the body could not be built
    }

    // MARK: - Value-free error record

    func testErrorRecordCarriesNoFreeText() async throws {
        // The receipt's error detail is value-free by type: only a stage and integer counts. This
        // asserts the encoded form contains nothing but integers and known enum tokens — the same
        // guard `ExportRun` relies on to be safe to screenshot.
        let (subject, _, _) = makeSubject(responses: [.response(status: 500)])
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        let json = String(data: try JSONEncoder().encode(receipt.errorDetail), encoding: .utf8) ?? ""
        // Only the stage token, the count field names, and digits — no message, no body.
        XCTAssertTrue(json.contains("\"stage\":\"delivering\""))
        XCTAssertFalse(json.lowercased().contains("bearer"))
        XCTAssertFalse(json.contains("test-token"))
    }

    func testLedgerErrorRecordCarriesTheStatusCodeAndOnlyThat() async throws {
        // §22.7: "status code + sanitized reason only". The reason is `errorCode` (closed
        // vocabulary); the code has to survive into `errorDetail`, because that is the field the
        // runner persists to `export_runs` — the `message` is UI-only and never reaches the ledger.
        let (subject, _, _) = makeSubject(responses: [], fallback: .response(status: 503))
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(receipt.errorDetail.httpStatus, 503)

        // 401/403 are distinguishable in the ledger even though the remedy is the same.
        let (auth, _, _) = makeSubject(responses: [.response(status: 403)])
        let authReceipt = await auth.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertEqual(authReceipt.errorDetail.httpStatus, 403)
    }

    func testNoStatusIsRecordedWhenTheServerNeverAnswered() async throws {
        // A timeout has no status code, and inventing one (0, -1) would make the ledger claim the
        // server said something. `errorCode` carries "never reached" on its own.
        let (subject, _, _) = makeSubject(responses: [], fallback: .timedOut)
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertNil(receipt.errorDetail.httpStatus)
        XCTAssertEqual(receipt.errorCode, .destinationUnreachable)
    }

    func testSuccessfulDeliveryRecordsNoStatus() async throws {
        let (subject, _, _) = makeSubject(responses: [.response(status: 200)])
        let receipt = await subject.deliver(request(try [makeArtifact("a.json", "{}")]), now: runDate)
        XCTAssertNil(receipt.errorDetail.httpStatus)
    }

    // MARK: - Verify

    func testVerifyReachableEndpointIsOk() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        let probe = await subject.verify(destination(), now: runDate)
        XCTAssertEqual(probe.status, .ok)
        XCTAssertTrue(probe.isWritable)
        // The probe is marked and carries no health data.
        XCTAssertEqual(transport.captured.first?.headers["X-Badan-Probe"], "1")
        let body = String(data: try XCTUnwrap(transport.captured.first?.body), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("badan_probe"))
    }

    func testVerifyAuthFailureIsAuthExpired() async throws {
        let (subject, _, _) = makeSubject(responses: [.response(status: 401)])
        let probe = await subject.verify(destination(), now: runDate)
        XCTAssertEqual(probe.status, .authExpired)
        XCTAssertEqual(probe.errorCode, .destinationAuthExpired)
    }

    func testVerifyTimeoutIsUnreachableWithoutRetrying() async throws {
        let (subject, transport, _) = makeSubject(responses: [], fallback: .timedOut)
        let probe = await subject.verify(destination(), now: runDate)
        XCTAssertEqual(probe.status, .unreachable)
        // A probe is a single ping, never the delivery backoff.
        XCTAssertEqual(transport.captured.count, 1)
    }

    func testVerifyDisabledDestinationDoesNotTouchTheNetwork() async throws {
        let (subject, transport, _) = makeSubject(responses: [.response(status: 200)])
        var dest = destination()
        dest.status = .disabled
        let probe = await subject.verify(dest, now: runDate)
        XCTAssertEqual(probe.status, .disabled)
        XCTAssertTrue(transport.captured.isEmpty)
    }

    // MARK: - Consent copy (both languages)

    func testConsentCopyIsPresentInBothLanguagesAndNamesWhoChose() {
        let en = DestinationMessages.restConsent.en
        let ar = DestinationMessages.restConsent.ar
        XCTAssertTrue(en.contains("a server you control"))
        XCTAssertTrue(en.contains("never chooses this destination for you"))
        XCTAssertFalse(ar.isEmpty)
        XCTAssertTrue(ar.contains("خادم"))
        XCTAssertNotEqual(en, ar)
    }

    func testServerErrorCopyIsolatesTheLatinStatusTokenInArabic() {
        // The Arabic sentence ends `(HTTP 503).` — a Latin word, digits, and a paren, all neutral or
        // LTR runs inside an RTL line. Without an isolate the code renders on the wrong side of
        // `HTTP`. Both platforms substitute the whole token through `isolated(...)`, so this pins the
        // property rather than the wording.
        let message = DestinationMessages.restServerError(status: 503)
        XCTAssertTrue(message.ar.contains("\u{2068}HTTP 503\u{2069}"))
        XCTAssertTrue(message.en.contains("\u{2068}HTTP 503\u{2069}"))
        // And nothing but the code: no response body ever reaches a message.
        XCTAssertFalse(message.en.contains("{code}"))
    }

    // MARK: - Helpers

    private func makeSubject(responses: [RESTTransportResult],
                             fallback: RESTTransportResult = .response(status: 200))
        -> (RESTDestination, StubRESTTransport, SleepRecorder) {
        let transport = StubRESTTransport(responses: responses, fallback: fallback)
        let sleeps = SleepRecorder()
        // rng == 0.5 → jitter cancels to the exact delay, so sleeps are assertable.
        let subject = RESTDestination(transport: transport, credentials: creds(),
                                      sleeper: { sleeps.recorded.append($0) }, rng: { 0.5 })
        return (subject, transport, sleeps)
    }

    private func creds() -> InMemoryRESTCredentialStore {
        let ref = CredentialRef.forDestination(id: "REST1")!
        return InMemoryRESTCredentialStore(items: [ref.key: "test-token"])
    }

    private func destination(url: String? = "https://example.com/ingest") -> ExportDestination {
        ExportDestination(
            id: "REST1", kind: .restApi, displayName: "My server",
            config: ExportDestinationConfig(endpointURL: url),
            credentialRef: CredentialRef.forDestination(id: "REST1"),
            createdAt: runDate, updatedAt: runDate, originDeviceId: deviceId)
    }

    private func request(_ artifacts: [ExportArtifact]) -> ExportDeliveryRequest {
        ExportDeliveryRequest(destination: destination(), artifacts: artifacts, runDate: runDate,
                              manifestSha: sha, schemaVersion: ExportSchema.version)
    }

    private func makeArtifact(_ fileName: String, _ contents: String) throws -> ExportArtifact {
        let src = tempDir.appendingPathComponent("src-\(UUID().uuidString)-\(fileName)")
        let data = Data(contents.utf8)
        try data.write(to: src)
        return ExportArtifact(sourceURL: src, fileName: fileName, byteCount: data.count)
    }
}

/// Records the delays the destination asked to sleep, without ever sleeping.
private final class SleepRecorder {
    var recorded: [TimeInterval] = []
}

/// Scripted transport: returns `responses` in order, then `fallback`, and captures every request so
/// headers, body, and call count can be asserted. The reason `RESTTransporting` is a protocol.
final class StubRESTTransport: RESTTransporting {
    private(set) var captured: [RESTRequest] = []
    private var responses: [RESTTransportResult]
    private let fallback: RESTTransportResult

    init(responses: [RESTTransportResult] = [], fallback: RESTTransportResult = .response(status: 200)) {
        self.responses = responses
        self.fallback = fallback
    }

    func perform(_ request: RESTRequest) async -> RESTTransportResult {
        captured.append(request)
        if !responses.isEmpty { return responses.removeFirst() }
        return fallback
    }
}
