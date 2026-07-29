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

    /// Submit a batch. Records what was sent in the local log FIRST, so the "What has been sent"
    /// screen can never be less complete than what actually left the device.
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
        request.httpBody = try JSONEncoder().encode(
            WireBatch(batch: batch, keyId: keyId, assertion: assertion, clientData: body))

        // Written before the request, not after: a submission that succeeded but whose log write
        // was lost would leave the user's own record of what left the device incomplete, which is
        // the one thing the "What has been sent" screen exists to prevent.
        log.record(batch)

        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            // No body, no payload, no key id — only a status. G8 applies on this side too.
            Self.logger.warning("Footprint submission rejected: \(response.statusCode, privacy: .public)")
            throw FootprintClientError.serverError(status: response.statusCode)
        }
    }

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
            // The key id is base64 of its UTF-8 bytes: App Attest vends it as a base64 string
            // already, and the server base64-decodes whatever it is given before hashing.
            try c.encode(Data(keyId.utf8).base64EncodedString(), forKey: .keyId)
            try c.encode(assertion.base64EncodedString(), forKey: .assertion)
            try c.encode(clientData.base64EncodedString(), forKey: .clientData)
        }
    }
}
