import CryptoKit
import Foundation
import os

/// BADAN's SECOND network-reaching surface, and its last (ADR-0011 / D-37).
///
/// Sends learning footprints — which metric, which method, the direction of a disagreement, a
/// bucketed count, whether a calibration was in force — to `POST /v1/footprints` on the same
/// service the AI coach uses. No reading, no magnitude, no date, no identifier.
///
/// This file is one of exactly four in `apps/ios/Sources/` permitted to open a socket, and CI
/// enforces that list (`.github/workflows/ci.yml`, the network-free gate). A third BADAN service
/// requires an ADR.
///
/// ## Why an App Attest assertion and not the device token
///
/// The coach authenticates with a per-install token. Using one here would defeat the entire point:
/// a token IS an identifier, and storing one beside a footprint is the join D-37 forbids. An
/// assertion proves "a genuine app instance sent this" without the server needing to keep anything
/// that links two submissions — and the server discards the key id after verifying, which is a code
/// boundary with a test behind it rather than cryptographic unlinkability. ADR-0011 says so
/// explicitly rather than overclaiming.
enum FootprintClientError: Error, Equatable {
    case notEnabled
    case attestationUnavailable
    case transportError
    case serverError(status: Int)
}

/// Transport seam, so tests exercise every path above without a socket. Mirrors
/// `AICoachTransporting` exactly.
protocol FootprintTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The only place in this file that actually opens a socket.
struct URLSessionFootprintTransport: FootprintTransporting {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FootprintClientError.transportError }
        return (data, http)
    }
}

struct FootprintClient {
    private let transport: FootprintTransporting
    private let attestor: AICoachAttesting
    private let attestKeys: AICoachAttestKeyStoring
    private let baseURL: URL
    private let log: SubmissionLogWriting

    private static let logger = Logger(subsystem: "net.albayyan.badan", category: "telemetry")

    init(transport: FootprintTransporting = URLSessionFootprintTransport(),
         attestor: AICoachAttesting = DeviceCheckAICoachAttestor(),
         attestKeys: AICoachAttestKeyStoring = KeychainAICoachAttestKeyStore(),
         baseURL: URL = URL(string: "https://badan.binjamshid.com")!,
         log: SubmissionLogWriting = SubmissionLog()) {
        self.transport = transport
        self.attestor = attestor
        self.attestKeys = attestKeys
        self.baseURL = baseURL
        self.log = log
    }

    /// Submit a batch. Records the attempt in the local log BEFORE the request leaves and corrects
    /// its state from the response, so the "What has been sent" screen can neither be less complete
    /// than what actually left the device nor claim a refused batch as sent (see `SubmissionLog`).
    ///
    /// Requires an attestation key the coach's registration already created. If there is none —
    /// the user never enabled the coach — telemetry simply cannot send, and that is reported
    /// rather than worked around: minting a key here would create an identifier for a feature
    /// whose whole design is not to have one.
    func submit(_ batch: FootprintBatch) async throws {
        guard let keyId = attestKeys.keyId() else { throw FootprintClientError.attestationUnavailable }
        guard attestor.isSupported else { throw FootprintClientError.attestationUnavailable }

        let body = try JSONEncoder().encode(batch)
        // The assertion is over the EXACT bytes being sent, which is what binds it to this batch —
        // a captured assertion cannot be reused to vouch for different content.
        let assertion: Data
        do {
            assertion = try await attestor.generateAssertion(
                keyId, clientDataHash: Data(SHA256.hash(data: body)))
        } catch {
            throw FootprintClientError.attestationUnavailable
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/footprints"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Bounded well inside the wake that is waiting on it. A background run blocks on this
        // submission so the OS cannot suspend the app between the send and the log reconciliation
        // (see `TelemetrySubmissionRunner.runBlocking`), and the default 60s would spend most of a
        // short wake's budget on the least important step it has.
        request.timeoutInterval = Self.requestTimeout
        request.httpBody = try JSONEncoder().encode(
            WireBatch(batch: batch, keyId: keyId, assertion: assertion, clientData: body))

        // Written before the request, not after: a submission that succeeded but whose log write
        // was lost would leave the user's own record of what left the device incomplete, which is
        // the one thing the "What has been sent" screen exists to prevent. It is written as an
        // ATTEMPT, though, and reconciled below — a record written before the send and never
        // corrected reports a refusal as a delivery.
        let recordId = log.recordAttempt(batch)

        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            // No body, no payload, no key id — only a status. G8 applies on this side too.
            Self.logger.warning("Footprint submission rejected: \(response.statusCode, privacy: .public)")
            // The server answered, so this one definitively did not land. A thrown transport error
            // deliberately leaves the entry `pending` instead: without a response there is no way
            // to know whether the bytes arrived, and guessing either way misreports it.
            log.reject(recordId)
            throw FootprintClientError.serverError(status: response.statusCode)
        }
        log.confirm(recordId)
    }

    /// How long one submission may take before the transport gives up.
    static let requestTimeout: TimeInterval = 30

    /// The wire shape: the contract batch plus the attestation fields the server needs.
    ///
    /// Deliberately a separate type that COMPOSES `FootprintBatch` rather than adding attestation
    /// fields to it. `FootprintBatch` is the thing the closed schema describes and the thing the
    /// "What has been sent" screen shows; keeping the credentials out of it means neither can drift
    /// into carrying the other's concerns.
    private struct WireBatch: Encodable {
        let batch: FootprintBatch
        let keyId: String
        let assertion: Data
        let clientData: Data

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, appVersion, contractVersion, footprints
            case keyId, assertion, clientData
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(batch.schemaVersion, forKey: .schemaVersion)
            try c.encode(batch.appVersion, forKey: .appVersion)
            try c.encode(batch.contractVersion, forKey: .contractVersion)
            try c.encode(batch.footprints, forKey: .footprints)
            // The key id goes out UNCHANGED, exactly as `AICoachClient` sends it to `/v2/register`
            // (see the comment there). `DCAppAttestService.generateKey` already vends it as base64
            // of the raw 32 bytes, and the server base64-DECODES this field and looks the raw bytes
            // up by `raw.hex()` in `attested_keys` — it does not hash it.
            //
            // This line used to re-encode: `Data(keyId.utf8).base64EncodedString()`, i.e. base64 of
            // the 44 ASCII characters of the base64 string. The server decoded those 44 bytes,
            // hexed them, and the primary-key lookup could never hit — so every submission from
            // every install got a 401, forever, and no test on either side exercised the encoding a
            // real client produces. `testTheWireKeyIdIsWhatTheServerLooksUp` is that test.
            try c.encode(keyId, forKey: .keyId)
            try c.encode(assertion.base64EncodedString(), forKey: .assertion)
            try c.encode(clientData.base64EncodedString(), forKey: .clientData)
        }
    }
}

/// One telemetry submission attempt as a background wake performs it (ADR-0011 / D-37): the due
/// gate, the send, and the schedule bookkeeping that follows from the answer.
///
/// Lives here rather than inline in `BackgroundIngestBridge` so it can be driven with a fake
/// transport in a test. The bridge's version was a handful of lines inside a fire-and-forget `Task`
/// that no test could reach without a `SeedController` and a HealthKit store — which is a large
/// part of why a client that could never authenticate, a log that reported refusals as deliveries,
/// and a retry with no backoff all shipped together and unnoticed.
struct TelemetrySubmissionRunner {
    /// What one wake's telemetry step did. Every case except `.sent` leaves the schedule set, so
    /// the batch is retried — but never sooner than the backoff allows.
    enum Outcome: Equatable {
        case notDue
        /// Nothing clears the 10-event floor. The ordinary state of an opted-in install.
        case nothingToSend
        case sent
        case failed
        /// The attempt outlived what a wake is willing to wait for it.
        case timedOut
    }

    let client: FootprintClient
    let scheduler: FootprintScheduler
    let makeBatch: () -> FootprintBatch?

    /// How long a background run blocks on a submission before abandoning it. Comfortably more
    /// than `FootprintClient.requestTimeout`, so under normal failure the transport gives up first
    /// and the outcome is a clean `.failed` rather than a `.timedOut` with a task still running.
    static let attemptTimeout: TimeInterval = 45

    private static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Telemetry")

    /// Submit if due, and reconcile the schedule with what happened: cleared on success, pushed out
    /// by an exponential backoff on anything else.
    @discardableResult
    func run(now: Date) async -> Outcome {
        guard scheduler.isDue(now: now) else { return .notDue }
        guard let batch = makeBatch() else { return .nothingToSend }
        return await send(batch, now: now)
    }

    private func send(_ batch: FootprintBatch, now: Date) async -> Outcome {
        do {
            try await client.submit(batch)
            scheduler.clear()
            return .sent
        } catch {
            // Never logged with a payload, and never escalated: telemetry failing must not fail a
            // run that did real work for the user. The backoff is what stops a permanent failure
            // (a rejected key, an unreachable host) from re-sending on every single wake — nginx
            // rate-limits `/v1/footprints` to 2r/h, and a wake-rate retry would sit against that
            // limit indefinitely for a batch that is never going to be accepted.
            Self.logger.warning("Telemetry submission failed")
            scheduler.recordFailure(now: now)
            return .failed
        }
    }

    /// `run(now:)` from a synchronous background-task body, blocking the calling thread until it
    /// finishes.
    ///
    /// Blocking is correct HERE for the same reason it is in `evaluateAutomationsBlocking`, and for
    /// one more: this step runs inside a `BGProcessingTask` body, and the previous fire-and-forget
    /// `Task` could be killed by suspension *after* the log had already recorded the attempt and
    /// before anything reconciled it. The run must outlive the send it started.
    ///
    /// No deadlock: the blocked thread is a `DispatchQueue` thread (`AssertedWorkDispatcher`'s
    /// serial queue, or the queue `BGTaskScheduler` hands the handler), never a Swift-concurrency
    /// cooperative-pool thread, so the `Task` below runs on the pool independently and signals.
    ///
    /// On timeout the task is cancelled and a failure recorded. If a cancelled send had in fact
    /// already succeeded it will clear the schedule a moment later, which is the right outcome
    /// arriving late — the race is benign in both directions because every path either clears a
    /// schedule that genuinely landed or pushes one out.
    @discardableResult
    func runBlocking(now: Date) -> Outcome {
        // Both gates stay on the caller's thread: `makeBatch` reads the feedback table, and that
        // read belongs on the background queue the wake already owns rather than hopping to the
        // cooperative pool. Only the network hop goes into the task.
        guard scheduler.isDue(now: now) else { return .notDue }
        guard let batch = makeBatch() else { return .nothingToSend }

        let box = SubmissionOutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            box.outcome = await send(batch, now: now)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.attemptTimeout) == .success else {
            task.cancel()
            Self.logger.warning("Telemetry submission abandoned: the wake would not wait longer")
            scheduler.recordFailure(now: now)
            return .timedOut
        }
        return box.outcome
    }
}

/// Carries the outcome across the semaphore in `runBlocking`. `@unchecked Sendable` is safe by the
/// happens-before the semaphore establishes: the `Task`'s write completes before `signal()`, and
/// the read follows a successful `wait()`, so the two never race. (The timeout path returns without
/// reading it at all.) Mirrors `AutomationSummaryBox`.
private final class SubmissionOutcomeBox: @unchecked Sendable {
    var outcome: TelemetrySubmissionRunner.Outcome = .failed
}
