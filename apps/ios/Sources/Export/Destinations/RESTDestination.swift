import Foundation
import CryptoKit
import Security

/// EPIC-20 — deliver a finished export to a REST endpoint the **user** configured and controls.
///
/// This is the first networked code in BADAN, and its placement is the whole point of §8.3. It lives
/// under `Sources/Export/Destinations/`, the one module allowed to move a finished, checksummed
/// artifact off the device. Export *generation* (`Sources/Export/` writers + runner) stays provably
/// offline — CI's network-free lint runs there and must stay green — and this file consumes only
/// what the delivery seam hands it: file URLs, a manifest sha, a schema version. It imports no
/// writer's internals (CI's companion lint asserts that), and it never re-derives anything the
/// generator produced.
///
/// `URLSession` appears in exactly one place, `URLSessionRESTTransport`, behind the `RESTTransporting`
/// seam — so the delivery logic (idempotency, backoff, auth handling, HTTPS enforcement) is unit
/// tested against a stub, never a real socket.
///
/// The contract implemented here is §22.7:
///  - `POST <user-url>` with `Content-Type: application/json` (single bundle) or
///    `application/x-ndjson` (parts, when the bundle exceeds 8 MB).
///  - Headers: `Authorization: Bearer <token>` (from the Keychain, **never** the database),
///    `X-Badan-Schema-Version`, `X-Badan-Manifest-Sha`, `Idempotency-Key` (= manifest sha, suffixed
///    `:n` per part), `X-Badan-Part: n/of` on parts.
///  - Responses: 2xx = delivered; 409 = duplicate, **treated as delivered** (idempotent replay);
///    401/403 → `authExpired`; 408/429/5xx/timeout → capped exponential backoff (30s/5m/30m,
///    jittered) then `failedDelivery`.
///  - HTTPS enforced. Plain `http://` is refused unless a developer explicitly opts in for LAN use.
struct RESTDestination: ExportDestinationDelivering {

    let kind: ExportDestinationKind = .restApi

    private let transport: RESTTransporting
    private let credentials: RESTCredentialStoring
    private let backoff: RESTBackoffPolicy
    /// Injected so tests do not actually wait 35 minutes. Default sleeps for real.
    private let sleeper: (TimeInterval) async -> Void
    /// Injected so a test can pin the jitter. Default is a real uniform draw in `0...1`.
    private let rng: () -> Double
    /// The §22.7 escape hatch: **off by default**. When true, BADAN's own HTTPS-only check stops
    /// refusing a plain `http://` endpoint for LAN use (a developer posting to a box on their own
    /// network). This is a build/wiring-time choice a developer makes deliberately — not an end-user
    /// toggle.
    ///
    /// The risk, stated plainly so it is never a surprise: over `http://`, the bearer token and every
    /// exported health value travel in clear text and anything on the path can read or alter them.
    /// That is acceptable only on a trusted local network the developer controls, which is why the
    /// default is HTTPS-only and this has to be turned on in code.
    ///
    /// What this flag does **not** do, so the comment does not promise more than the app delivers:
    /// App Transport Security still blocks cleartext loads, and BADAN ships no ATS exception — so
    /// with the real `URLSessionRESTTransport` a plain `http://` POST fails at the transport
    /// regardless of this flag, and no shipped build can send an export unencrypted. Reaching a
    /// cleartext LAN box would additionally require an ATS exception that is deliberately not in the
    /// project. What the flag changes is only whether BADAN refuses the address itself.
    private let allowInsecureHTTPForDevelopment: Bool

    /// Bundles at or below this size go as one `application/json` POST; larger ones are split into
    /// `application/x-ndjson` parts, each independently idempotent (§22.7). Measured on the raw
    /// artifact bytes, matching the contract's "bundles > 8 MB". Injectable so part-splitting is
    /// testable without multi-megabyte fixtures.
    private let maxBundleBytes: Int

    static let defaultMaxBundleBytes = 8 * 1024 * 1024

    init(transport: RESTTransporting,
         credentials: RESTCredentialStoring,
         backoff: RESTBackoffPolicy = .standard,
         sleeper: @escaping (TimeInterval) async -> Void = RESTDestination.realSleep,
         rng: @escaping () -> Double = { Double.random(in: 0...1) },
         allowInsecureHTTPForDevelopment: Bool = false,
         maxBundleBytes: Int = RESTDestination.defaultMaxBundleBytes) {
        self.transport = transport
        self.credentials = credentials
        self.backoff = backoff
        self.sleeper = sleeper
        self.rng = rng
        self.allowInsecureHTTPForDevelopment = allowInsecureHTTPForDevelopment
        self.maxBundleBytes = maxBundleBytes
    }

    static func realSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: - Verification ping (§12 EPIC-14)

    /// A single, safe reachability + auth probe. It sends a clearly-marked, health-data-free request
    /// (`X-Badan-Probe: 1`, an empty-artifact body) so a BADAN-aware endpoint can recognise and
    /// discard it, and it does **not** retry — a probe is one ping, not a delivery. The message says
    /// exactly what was established: that the server answered, never that a real export has landed.
    func verify(_ destination: ExportDestination, now: Date) async -> ExportDestinationProbe {
        if destination.status == .disabled {
            return ExportDestinationProbe(status: .disabled, checkedAt: now,
                                          errorCode: .destinationDisabled,
                                          message: DestinationMessages.destinationDisabled)
        }
        let endpoint: Endpoint
        switch resolveEndpoint(destination) {
        case .failure(let failure): return failure.probe(at: now)
        case .success(let resolved): endpoint = resolved
        }
        guard let token = token(for: destination) else {
            return ExportDestinationProbe(status: .authExpired, checkedAt: now,
                                          errorCode: .destinationAuthExpired,
                                          message: DestinationMessages.restCredentialMissing)
        }

        let schema = destination.schemaVersionHeader(request: nil)
        let body = Data(#"{"badan_probe":true,"schema_version":"\#(schema)"}"#.utf8)
        var headers = baseHeaders(token: token, schemaVersion: schema, manifestSha: "probe")
        headers["X-Badan-Probe"] = "1"
        headers["Content-Type"] = "application/json"

        let result = await transport.perform(
            RESTRequest(url: endpoint.url, method: endpoint.method, headers: headers, body: body))
        switch categorize(result) {
        case .delivered:
            return ExportDestinationProbe(status: .ok, checkedAt: now,
                                          message: DestinationMessages.restProbeReachable)
        case .authFailed:
            return ExportDestinationProbe(status: .authExpired, checkedAt: now,
                                          errorCode: .destinationAuthExpired,
                                          message: DestinationMessages.restAuthExpired)
        case .retryableHTTP(let status), .nonRetryable(let status):
            return ExportDestinationProbe(status: .unreachable, checkedAt: now,
                                          errorCode: .destinationUnreachable,
                                          message: DestinationMessages.restServerError(status: status))
        case .retryableConnectivity:
            return ExportDestinationProbe(status: .unreachable, checkedAt: now,
                                          errorCode: .destinationUnreachable,
                                          message: DestinationMessages.restUnreachable)
        }
    }

    // MARK: - Delivery

    func deliver(_ request: ExportDeliveryRequest, now: Date) async -> ExportDeliveryReceipt {
        let destination = request.destination
        let expected = request.artifacts.count

        if destination.status == .disabled {
            return failure(.destinationDisabled, status: .disabled, expected: expected,
                           message: DestinationMessages.destinationDisabled)
        }
        guard !request.artifacts.isEmpty else {
            // "Nothing to send" is its own answer (§9.5), distinguishable in Export Health from a
            // run that silently did nothing.
            return ExportDeliveryReceipt(outcome: .skippedNoData,
                                         errorDetail: ExportErrorDetail(stage: .delivering, filesExpected: 0),
                                         bytesDelivered: 0, destinationStatus: .ok,
                                         message: DestinationMessages.nothingToDeliver)
        }
        let endpoint: Endpoint
        switch resolveEndpoint(destination) {
        case .failure(let failure): return failure.receipt(expected: expected)
        case .success(let resolved): endpoint = resolved
        }
        guard let token = token(for: destination) else {
            // No token → cannot authenticate. `authExpired` is the honest state and the same remedy
            // as an expired one (add a credential), so it shares the status.
            return ExportDeliveryReceipt(
                outcome: .failedDelivery, errorCode: .destinationAuthExpired,
                errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: 0, filesExpected: expected),
                bytesDelivered: 0, destinationStatus: .authExpired,
                message: DestinationMessages.restCredentialMissing)
        }

        let schema = destination.schemaVersionHeader(request: request)
        let sha = bundleSha(request)
        let plans = partPlans(request.artifacts)
        let of = plans.count
        // §22.7 keys the wire format on the **bundle size**, not on how many parts it happened to
        // split into: "bundles > 8 MB sent as NDJSON parts". A single artifact larger than the cap
        // is the commonest oversized export there is (one big `raw.csv`), and deciding the format
        // from `plans.count` would have sent exactly that case as one `application/json` body — the
        // contract's one hard size rule, broken by its most likely input. So the stream mode is
        // decided here, and a lone oversized part is honestly labelled `X-Badan-Part: 1/1`.
        let streamed = request.artifacts.reduce(0) { $0 + $1.byteCount } > maxBundleBytes

        var deliveredArtifacts = 0
        var deliveredBytes = 0
        for (index, plan) in plans.enumerated() {
            let n = index + 1
            let body: Data
            switch buildBody(plan: plan, partIndex: streamed ? n : nil, of: of,
                             schema: schema, manifestSha: sha) {
            case .failure:
                // A source artifact could not be read — a staging bug, not the endpoint's fault, so
                // the destination stays `.ok` and no re-pick is asked for. `.partial` if earlier
                // parts already landed.
                return ExportDeliveryReceipt(
                    outcome: deliveredArtifacts > 0 ? .partial : .failedDelivery,
                    errorCode: .writeFailed,
                    errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: deliveredArtifacts,
                                                   filesExpected: expected),
                    bytesDelivered: deliveredBytes,
                    deliveredAt: deliveredArtifacts > 0 ? now : nil,
                    destinationStatus: .ok,
                    message: deliveredArtifacts > 0
                        ? DestinationMessages.restPartiallyDelivered(sent: deliveredArtifacts, expected: expected)
                        : DestinationMessages.restSourceUnreadable,
                    needsRepick: false)
            case .success(let (data, contentType)):
                body = data
                var headers = baseHeaders(token: token, schemaVersion: schema, manifestSha: sha)
                headers["Content-Type"] = contentType
                if streamed {
                    headers["X-Badan-Part"] = "\(n)/\(of)"
                    headers["Idempotency-Key"] = "\(sha):\(n)"
                }
                let outcome = await sendWithBackoff(
                    RESTRequest(url: endpoint.url, method: endpoint.method, headers: headers, body: body))
                switch outcome {
                case .delivered:
                    deliveredArtifacts += plan.count
                    deliveredBytes += plan.reduce(0) { $0 + $1.byteCount }
                case .authFailed(let status):
                    return terminal(.destinationAuthExpired, destinationStatus: .authExpired,
                                    delivered: deliveredArtifacts, bytes: deliveredBytes,
                                    expected: expected, now: now, httpStatus: status,
                                    message: DestinationMessages.restAuthExpired)
                case .serverRejected(let status):
                    return terminal(.writeFailed, destinationStatus: .ok,
                                    delivered: deliveredArtifacts, bytes: deliveredBytes,
                                    expected: expected, now: now, httpStatus: status,
                                    message: DestinationMessages.restServerError(status: status))
                case .unreachable:
                    // No status: the endpoint never answered. `errorCode` carries that fact.
                    return terminal(.destinationUnreachable, destinationStatus: .ok,
                                    delivered: deliveredArtifacts, bytes: deliveredBytes,
                                    expected: expected, now: now, httpStatus: nil,
                                    message: DestinationMessages.restUnreachable)
                }
            }
        }

        return ExportDeliveryReceipt(
            outcome: .success,
            errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: deliveredArtifacts,
                                           filesExpected: expected),
            bytesDelivered: deliveredBytes, deliveredAt: now, destinationStatus: .ok,
            message: DestinationMessages.restDelivered)
    }

    /// A part failed after any retries. `.partial` if earlier parts landed, else `.failedDelivery`.
    /// When partial, the message states both counts so a caller cannot read "some parts sent" as
    /// "the export arrived".
    ///
    /// `httpStatus` is the §22.7 half of the ledger's error record that the closed `errorCode`
    /// vocabulary cannot express — the code the server actually answered with. It rides on
    /// `errorDetail` because that is the field the runner persists verbatim; `message` is read by
    /// the UI and never reaches `export_runs`.
    private func terminal(_ code: ExportErrorCode, destinationStatus: ExportDestinationStatus,
                          delivered: Int, bytes: Int, expected: Int, now: Date,
                          httpStatus: Int? = nil,
                          message: LocalizedString) -> ExportDeliveryReceipt {
        ExportDeliveryReceipt(
            outcome: delivered > 0 ? .partial : .failedDelivery,
            errorCode: code,
            errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: delivered,
                                           filesExpected: expected, httpStatus: httpStatus),
            bytesDelivered: bytes,
            deliveredAt: delivered > 0 ? now : nil,
            destinationStatus: destinationStatus,
            message: delivered > 0
                ? DestinationMessages.restPartiallyDelivered(sent: delivered, expected: expected)
                : message)
    }

    private func failure(_ code: ExportErrorCode, status: ExportDestinationStatus, expected: Int,
                         message: LocalizedString) -> ExportDeliveryReceipt {
        ExportDeliveryReceipt(outcome: .failedDelivery, errorCode: code,
                              errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: 0,
                                                             filesExpected: expected),
                              bytesDelivered: 0, destinationStatus: status, message: message)
    }

    // MARK: - One part, with the capped backoff (§22.7)

    private enum PartOutcome {
        case delivered
        /// 401/403. Carries the code so the ledger records which one (§22.7) — the remedy is the
        /// same for both, but "the token is rejected" and "this token may not write here" are not
        /// the same report to a user debugging their own server.
        case authFailed(status: Int)
        /// A terminal 4xx, or a 408/429/5xx that survived every retry: the server answered, and it
        /// rejected the request.
        case serverRejected(status: Int)
        /// A timeout or transport failure that survived every retry: BADAN never got an answer.
        case unreachable
    }

    private func sendWithBackoff(_ request: RESTRequest) async -> PartOutcome {
        var attempt = 0
        while true {
            switch categorize(await transport.perform(request)) {
            case .delivered:
                return .delivered
            case .authFailed(let status):
                return .authFailed(status: status)
            case .nonRetryable(let status):
                return .serverRejected(status: status)
            case .retryableHTTP(let status):
                guard attempt < backoff.delays.count else { return .serverRejected(status: status) }
                await sleeper(backoff.jittered(backoff.delays[attempt], rng: rng))
                attempt += 1
            case .retryableConnectivity:
                guard attempt < backoff.delays.count else { return .unreachable }
                await sleeper(backoff.jittered(backoff.delays[attempt], rng: rng))
                attempt += 1
            }
        }
    }

    private enum AttemptCategory {
        case delivered
        case authFailed(Int)
        case retryableHTTP(Int)
        case retryableConnectivity
        case nonRetryable(Int)
    }

    private func categorize(_ result: RESTTransportResult) -> AttemptCategory {
        switch result {
        case .response(let status):
            if (200..<300).contains(status) { return .delivered }
            // 409 Conflict = the server already has this manifest sha. Idempotent replay is a
            // success, not a failure — this is the property `Idempotency-Key` exists to buy (§22.7).
            if status == 409 { return .delivered }
            if status == 401 || status == 403 { return .authFailed(status) }
            if status == 408 || status == 429 || (500..<600).contains(status) {
                return .retryableHTTP(status)
            }
            return .nonRetryable(status)
        case .timedOut, .transportError:
            return .retryableConnectivity
        }
    }

    // MARK: - Headers, body, idempotency key

    private func baseHeaders(token: String, schemaVersion: String, manifestSha: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "X-Badan-Schema-Version": schemaVersion,
            "X-Badan-Manifest-Sha": manifestSha,
            "Idempotency-Key": manifestSha,
        ]
    }

    /// The `Idempotency-Key`/`X-Badan-Manifest-Sha` value. Prefers the manifest sha the runner
    /// computed (so it matches the `ExportRun` ledger row); falls back to a deterministic digest of
    /// the ordered artifact bytes when the seam did not carry one. Both are stable per *generated*
    /// bundle and change when the bundle is regenerated — which is exactly the idempotency semantics
    /// the contract wants: a retry of the same files replays, a fresh export is a new delivery.
    private func bundleSha(_ request: ExportDeliveryRequest) -> String {
        if let sha = request.manifestSha { return sha.hex }
        var hasher = SHA256()
        for artifact in request.artifacts.sorted(by: { $0.fileName < $1.fileName }) {
            hasher.update(data: Data(artifact.fileName.utf8))
            hasher.update(data: Data([0x1F]))
            if let data = try? Data(contentsOf: artifact.sourceURL, options: .mappedIfSafe) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0x1E]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whole artifacts are packed into parts; a single artifact is never split across two parts, so
    /// "3 of 5 files delivered" stays exactly true. An artifact larger than the cap becomes its own
    /// part.
    private func partPlans(_ artifacts: [ExportArtifact]) -> [[ExportArtifact]] {
        let total = artifacts.reduce(0) { $0 + $1.byteCount }
        if total <= maxBundleBytes { return [artifacts] }

        var plans: [[ExportArtifact]] = []
        var current: [ExportArtifact] = []
        var currentBytes = 0
        for artifact in artifacts {
            if !current.isEmpty && currentBytes + artifact.byteCount > maxBundleBytes {
                plans.append(current)
                current = []
                currentBytes = 0
            }
            current.append(artifact)
            currentBytes += artifact.byteCount
        }
        if !current.isEmpty { plans.append(current) }
        return plans
    }

    private func buildBody(plan: [ExportArtifact], partIndex: Int?, of: Int,
                           schema: String, manifestSha: String) -> Result<(Data, String), ReadError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // byte-stable body so a retry hashes identically
        do {
            if let partIndex {
                // NDJSON: one object per artifact, one line each.
                var lines: [Data] = []
                for artifact in plan {
                    let bytes = try readArtifact(artifact)
                    let line = NDJSONLine(schemaVersion: schema, manifestSha: manifestSha,
                                          part: partIndex, of: of, file: artifact.fileName,
                                          byteCount: artifact.byteCount,
                                          contentBase64: bytes.base64EncodedString())
                    lines.append(try encoder.encode(line))
                }
                var body = Data()
                for line in lines { body.append(line); body.append(0x0A) }
                return .success((body, "application/x-ndjson"))
            } else {
                var envelopes: [ArtifactEnvelope] = []
                for artifact in plan {
                    let bytes = try readArtifact(artifact)
                    envelopes.append(ArtifactEnvelope(file: artifact.fileName,
                                                      byteCount: artifact.byteCount,
                                                      contentBase64: bytes.base64EncodedString()))
                }
                let bundle = BundleEnvelope(schemaVersion: schema, manifestSha: manifestSha,
                                            artifacts: envelopes)
                return .success((try encoder.encode(bundle), "application/json"))
            }
        } catch {
            return .failure(.unreadable)
        }
    }

    private struct ReadError: Error { static let unreadable = ReadError() }

    private func readArtifact(_ artifact: ExportArtifact) throws -> Data {
        // `.mappedIfSafe` lets the kernel back the *read* with the file rather than a fresh heap
        // copy. It is not a streaming claim: the caller base64-encodes the result and hands it to
        // `JSONEncoder`, so a part is fully resident by the time it is a body. Keeping a part under
        // `maxBundleBytes` is what actually bounds the peak — the mapping just removes one copy of
        // it. If part bodies ever need to be built without materializing, that is a change to
        // `buildBody`, not to this line.
        try Data(contentsOf: artifact.sourceURL, options: .mappedIfSafe)
    }

    // MARK: - Endpoint + credential resolution

    private struct Endpoint {
        let url: URL
        let method: String
    }

    private func resolveEndpoint(_ destination: ExportDestination) -> Result<Endpoint, Failure> {
        guard destination.kind == .restApi else {
            // A dispatcher handed this to the wrong deliverer. Reported, not asserted: a trap in a
            // background export is a crash the user cannot see the cause of.
            return .failure(Failure(errorCode: .unknown, destinationStatus: destination.status,
                                    message: DestinationMessages.destinationNotConfigured))
        }
        guard let raw = destination.config.endpointURL, !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            return .failure(Failure(errorCode: .destinationUnreachable, destinationStatus: destination.status,
                                    message: DestinationMessages.restNotConfigured))
        }
        if scheme == "http" && !allowInsecureHTTPForDevelopment {
            // Refused before a single byte leaves the device — the message names the reason rather
            // than reporting a network failure that never happened. Default `httpsOnly`.
            //
            // The row's own `tlsPolicy` is deliberately not branched on here, and that is not an
            // oversight: `ExportDestination` defaults a network kind to `.httpsOnly`, and
            // `ExportTlsPolicy` has no vocabulary for "cleartext permitted" (`.notApplicable` means
            // *no transport at all*, which a `restApi` row never is). So a row cannot express the
            // opt-in, and the opt-in is a build-time developer flag instead — which is what §22.7's
            // "explicit developer toggle" asks for. This branch enforces exactly what every
            // `restApi` row declares.
            return .failure(Failure(errorCode: .destinationUnreachable, destinationStatus: destination.status,
                                    message: DestinationMessages.restInsecureBlocked))
        }
        guard scheme == "https" || scheme == "http" else {
            return .failure(Failure(errorCode: .destinationUnreachable, destinationStatus: destination.status,
                                    message: DestinationMessages.restNotConfigured))
        }
        let method = destination.config.httpMethod.map { $0.uppercased() } ?? "POST"
        return .success(Endpoint(url: url, method: method))
    }

    /// The bearer token, read from the Keychain via the destination's `CredentialRef`. **Never the
    /// database** — the `credentialRef` column holds a key, and the secret behind it lives only in
    /// protected storage (§9.4, I-enforced by `CredentialRef`).
    private func token(for destination: ExportDestination) -> String? {
        guard let ref = destination.credentialRef else { return nil }
        guard let token = credentials.token(for: ref), !token.isEmpty else { return nil }
        return token
    }

    private struct Failure: Error {
        let errorCode: ExportErrorCode
        let destinationStatus: ExportDestinationStatus
        let message: LocalizedString

        func probe(at now: Date) -> ExportDestinationProbe {
            ExportDestinationProbe(status: destinationStatus == .disabled ? .disabled : .unreachable,
                                   checkedAt: now, errorCode: errorCode, message: message)
        }
        func receipt(expected: Int) -> ExportDeliveryReceipt {
            ExportDeliveryReceipt(outcome: .failedDelivery, errorCode: errorCode,
                                  errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: 0,
                                                                 filesExpected: expected),
                                  bytesDelivered: 0, destinationStatus: destinationStatus,
                                  message: message)
        }
    }
}

private extension ExportDestination {
    /// `X-Badan-Schema-Version`. Prefers the value the seam carried (the runner's own), falling back
    /// to `ExportSchema.version` — the single build-wide constant CI pins across both platforms — so
    /// the header is never silently absent.
    func schemaVersionHeader(request: ExportDeliveryRequest?) -> String {
        request?.schemaVersion ?? ExportSchema.version
    }
}

// MARK: - Body shapes

/// One artifact inside a single-POST `application/json` bundle. Content is base64 so the envelope
/// carries CSV, JSON, or an encrypted container byte-for-byte without ever interpreting it — a
/// destination that parsed the payload would be reading a writer's output, which is the coupling
/// §8.3 forbids.
private struct ArtifactEnvelope: Encodable {
    let file: String
    let byteCount: Int
    let contentBase64: String
    enum CodingKeys: String, CodingKey {
        case file
        case byteCount = "byte_count"
        case contentBase64 = "content_base64"
    }
}

private struct BundleEnvelope: Encodable {
    let schemaVersion: String
    let manifestSha: String
    let artifacts: [ArtifactEnvelope]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestSha = "manifest_sha"
        case artifacts
    }
}

/// One NDJSON line (part mode). Every line self-describes its part so a stream reassembled out of
/// order still knows where each piece belongs.
private struct NDJSONLine: Encodable {
    let schemaVersion: String
    let manifestSha: String
    let part: Int
    let of: Int
    let file: String
    let byteCount: Int
    let contentBase64: String
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestSha = "manifest_sha"
        case part
        case of
        case file
        case byteCount = "byte_count"
        case contentBase64 = "content_base64"
    }
}

// MARK: - Transport seam (the only place URLSession is allowed)

struct RESTRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
}

/// What one POST concluded. Deliberately **carries no response body and no error message** — a
/// server's error text can echo back what BADAN sent, so surfacing it would be the health-value
/// leak §22.7 forbids. The status code is all a caller needs to classify the attempt.
enum RESTTransportResult {
    case response(status: Int)
    case timedOut
    case transportError
}

/// The seam that keeps `URLSession` out of the delivery logic. Tests implement this with a stub.
/// `URLSessionRESTTransport` is what the app would wire — and does, in exactly one place
/// (`RESTDestinationAvailability.deliverers`) — but that registration is gated off in this build,
/// so no shipped code path constructs it. Stated rather than implied: "the app wires it" is the
/// claim this gate makes untrue today.
protocol RESTTransporting {
    func perform(_ request: RESTRequest) async -> RESTTransportResult
}

/// The single networking implementation in BADAN. Isolated here so CI's network-free lint on the
/// generation module stays green and the retry/idempotency logic stays testable off the wire.
struct URLSessionRESTTransport: RESTTransporting {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 60) {
        self.session = session
        self.timeout = timeout
    }

    func perform(_ request: RESTRequest) async -> RESTTransportResult {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            // The response body is intentionally discarded — see `RESTTransportResult`.
            let (_, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { return .transportError }
            return .response(status: http.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            return .transportError
        }
    }
}

// MARK: - Backoff policy

/// Capped exponential backoff, §22.7: three retry attempts after the first send, waiting 30s / 5m /
/// 30m (jittered) before each. On a persistently failing endpoint that is four network attempts and
/// three sleeps, then `failedDelivery`.
struct RESTBackoffPolicy {
    let delays: [TimeInterval]
    /// Fraction of full jitter applied either side of each delay, so a fleet of devices does not
    /// retry in lockstep. 0 = exact delays (used by tests).
    let jitterFraction: Double

    static let standard = RESTBackoffPolicy(delays: [30, 5 * 60, 30 * 60], jitterFraction: 0.15)

    /// `delay` scaled into `[delay·(1-j), delay·(1+j)]` by a draw from `rng` in `0...1`.
    func jittered(_ delay: TimeInterval, rng: () -> Double) -> TimeInterval {
        guard jitterFraction > 0 else { return delay }
        let span = delay * jitterFraction
        return delay - span + (rng() * 2 * span)
    }
}

// MARK: - Credential storage (Keychain only)

/// Where a REST destination's bearer token lives — the Keychain, never the database.
///
/// `ExportDestination.credentialRef` is a validated Keychain *key* (`CredentialRef`); this protocol
/// is the other half of that promise, and it is a protocol so the delivery logic can be tested with
/// an in-memory double that never touches the Keychain.
protocol RESTCredentialStoring {
    func token(for ref: CredentialRef) -> String?
    @discardableResult
    func store(_ token: String, for ref: CredentialRef) -> Bool
    func remove(ref: CredentialRef)
}

/// Keychain-backed store, mirroring `KeychainFolderBookmarkStore`'s attribute choices for the same
/// reasons: `AfterFirstUnlockThisDeviceOnly` so a scheduled/background export can read the token
/// while the phone is locked (a `WhenUnlocked` item would fail every locked run), and
/// `ThisDeviceOnly` so a token never rides a backup to another device.
struct KeychainRESTCredentialStore: RESTCredentialStoring {
    static let service = "net.binjamshid.badan.export.rest-credential"

    func token(for ref: CredentialRef) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: ref.key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func store(_ token: String, for ref: CredentialRef) -> Bool {
        remove(ref: ref)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: ref.key,
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status == errSecSuccess
    }

    func remove(ref: CredentialRef) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: ref.key,
        ] as CFDictionary)
    }
}

/// Test double, and the reason `RESTCredentialStoring` is a protocol.
final class InMemoryRESTCredentialStore: RESTCredentialStoring {
    private var items: [String: String] = [:]

    init(items: [String: String] = [:]) { self.items = items }

    func token(for ref: CredentialRef) -> String? { items[ref.key] }

    @discardableResult
    func store(_ token: String, for ref: CredentialRef) -> Bool {
        items[ref.key] = token
        return true
    }

    func remove(ref: CredentialRef) { items.removeValue(forKey: ref.key) }
}
