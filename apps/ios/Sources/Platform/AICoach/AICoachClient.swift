import CryptoKit
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// A single chat turn, mirroring `backend/api/main.py`'s `ChatMessage` contract exactly: `role`
/// is one of `system`/`user`/`assistant`, `content` is plain text. Codable so it can be sent as
/// JSON and (in tests) round-tripped.
struct AICoachMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Everything `AICoachClient` can fail with — a typed, exhaustive set so a caller (the chat
/// screen) can render each distinctly instead of one generic "something went wrong." `notEnabled`
/// in particular is the load-bearing case: it is the "not yet enabled" state the client task
/// calls out explicitly, handled as ordinary control flow rather than a force-unwrap or a crash.
enum AICoachError: Error, Equatable {
    /// No device token exists (the user hasn't completed opt-in, or turned it back off since —
    /// `AICoachConsentScreen.disableModule()` deletes the token precisely so this case, not a
    /// stale credential, is what a disabled coach hits).
    case notEnabled
    /// The network call itself failed (offline, DNS, timeout, non-HTTP response).
    case transportError
    /// A response arrived but its body didn't decode to the shape the endpoint promises.
    case decodingError
    /// The server answered with a non-2xx status (401 = token rejected server-side, 429 = rate
    /// limited, 502 = upstream LLM unavailable, etc.) — the raw status is kept so a caller can
    /// tell a rate limit apart from an outage if it ever needs to.
    case serverError(status: Int)
    /// App Attest is unavailable on this device, so registration cannot prove the app is
    /// genuine and the server will not issue a token. The honest cases are the simulator and
    /// a device where the platform declines to vend `DCAppAttestService`; it is a distinct
    /// case from `serverError` because it is not a failure the user can retry their way out
    /// of, and the consent screen should say so rather than offering "try again".
    ///
    /// Narrowed 2026-08-05: this used to swallow EVERY error out of `generateKey`/`attestKey`,
    /// including the retryable ones below, which made the consent screen tell a user with a
    /// flaky connection that their device can never verify the app. See
    /// `attestationError(for:)`.
    case attestationUnavailable
    /// App Attest works on this device, but this attempt did not complete — and another one
    /// can. `DCAppAttestService.attestKey` performs a live round trip to Apple's attestation
    /// service and reports a failed one as `DCError.serverUnavailable`, which is the offline /
    /// Apple-having-a-bad-ten-minutes case, not the unsupported-device case. Distinct from
    /// `transportError` because the failing hop is Apple's, not BADAN's server, and the
    /// consent screen should offer "try again" for it.
    case attestationFailedTransiently
}

/// Classify an error thrown by an `AICoachAttesting` call into one of the two attestation cases
/// above.
///
/// Only `DCError.serverUnavailable` is retryable: the rest of what DeviceCheck reports
/// (`featureUnsupported`, `invalidInput`, `invalidKey`, `unknownSystemFailure`) fails the same
/// way on the next attempt, so pushing the user round a retry loop for those would be the same
/// dishonesty in the opposite direction. Anything that is not a `DCError` at all — including a
/// test double's own error — keeps the conservative non-retryable case.
private func attestationError(for error: Error) -> AICoachError {
    #if canImport(DeviceCheck)
    if let dcError = error as? DCError, dcError.code == .serverUnavailable {
        return .attestationFailedTransiently
    }
    #endif
    return .attestationUnavailable
}

/// Transport seam for `AICoachClient` — a protocol so tests can mock the network layer without a
/// real socket touch. This is BADAN's ONE network-capable client (A9/D-22 — the sole, narrowly
/// scoped exception to ADR-0002's "no network calls anywhere in the app"), which makes this the
/// single most important seam in the file to keep swappable and testable.
protocol AICoachTransporting {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Real `URLSession`-backed transport — the only place in this file that actually opens a socket.
struct URLSessionAICoachTransport: AICoachTransporting {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AICoachError.transportError
        }
        return (data, http)
    }
}

/// BADAN's one network-capable client (A9/D-22). Talks to the stateless proxy in
/// `backend/api/main.py`: `POST /v1/register` issues a per-install device token,
/// `POST /v1/chat` sends a query (+ whatever minimal context the caller assembled) and gets a
/// completion back. Holds no user account of its own — the token is anonymous proof-of-
/// registration only (ADR-0002/D-2: BADAN has zero accounts, and this must not become one).
struct AICoachClient {
    /// The one named constant every request is built off (per the client task's own requirement:
    /// "read the host from a single named constant so it's trivial to change later"). Matches
    /// D-22's concrete parameter: "a new, isolated service at `badan.binjamshid.com`."
    static let baseURLString = "https://badan.binjamshid.com"

    private let transport: AICoachTransporting
    private let tokenStore: AICoachDeviceTokenStoring
    private let attestor: AICoachAttesting
    private let attestKeyStore: AICoachAttestKeyStoring
    private let baseURL: URL

    init(transport: AICoachTransporting = URLSessionAICoachTransport(),
         tokenStore: AICoachDeviceTokenStoring = KeychainAICoachDeviceTokenStore(),
         attestor: AICoachAttesting = DeviceCheckAICoachAttestor(),
         attestKeyStore: AICoachAttestKeyStoring = KeychainAICoachAttestKeyStore(),
         baseURL: URL = URL(string: AICoachClient.baseURLString)!) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.attestor = attestor
        self.attestKeyStore = attestKeyStore
        self.baseURL = baseURL
    }

    /// Whether a device token exists — i.e. whether `sendChat` can even attempt a request. This
    /// is the SECOND of the two gates the coach needs (`CustomizationProfile.aiCoachEnabled` is
    /// the first): a screen should check both, since a `true` flag with no token is the safe,
    /// inert state a corrupted/restored install could land in, never a crash.
    var isEnabled: Bool { tokenStore.token() != nil }

    /// Issue a fresh device token and store it in the Keychain. The ONLY caller of this should
    /// be `AICoachConsentScreen.enableModule()`, and only right before it flips
    /// `CustomizationProfile.aiCoachEnabled` — this method itself has no opinion on that flag,
    /// so a failed registration (thrown error) never leaves the flag on with no token behind it
    /// (the caller simply doesn't flip it).
    ///
    /// Three round trips, because the server will not mint a token to an unproven caller:
    ///   1. `POST /v1/attest/challenge` — a single-use, short-lived challenge.
    ///   2. App Attest over that challenge, in the Secure Enclave.
    ///   3. `POST /v2/register` — token issued only if the attestation verifies.
    ///
    /// The extra hops are the point: `/v1/register` (still live, retiring — see
    /// `backend/api/main.py`) hands a token to anyone who asks, which is what left OpenRouter
    /// spend bounded only by a rate limiter. Nothing here sends user data of any kind; the key
    /// id is a random per-install value with no identity attached, so ADR-0002 is unchanged.
    @discardableResult
    func register() async throws -> String {
        guard attestor.isSupported else { throw AICoachError.attestationUnavailable }

        let challenge = try await fetchAttestChallenge()

        // Reuse this install's existing key when there is one. A fresh key per opt-in would
        // turn the server's per-key token budget into no budget at all (see
        // `AICoachAttestKeyStoring`).
        let existingKeyId = attestKeyStore.keyId()
        let keyId: String
        if let existingKeyId {
            keyId = existingKeyId
        } else {
            do {
                keyId = try await attestor.generateKey()
            } catch {
                throw attestationError(for: error)
            }
        }

        // The server hashes the challenge the same way (`clientDataHash = SHA256(challenge)`)
        // and expects that hash inside the attestation's nonce. The two must agree exactly.
        guard let challengeData = Data(base64Encoded: challenge) else {
            throw AICoachError.decodingError
        }
        let attestation: Data
        do {
            attestation = try await attestor.attestKey(
                keyId, clientDataHash: Data(SHA256.hash(data: challengeData))
            )
        } catch {
            throw attestationError(for: error)
        }

        // Persist a freshly generated key id only HERE — after it has actually attested, and
        // only if the Keychain took it (review finding, 2026-08-05). Storing it right after
        // `generateKey()` and discarding the `Bool` was wrong twice over:
        //   * a key id that never attested was pinned for the life of the install, because
        //     `disable()` deliberately never clears this store (see `AICoachAttestKeyStoring`)
        //     — and a key is meant to be attested once, so every later opt-in reused a handle
        //     that had already spent its one attempt;
        //   * a silently failing write meant the NEXT `register()` found nothing stored and
        //     generated ANOTHER key, each carrying its own server-side `MAX_TOKENS_PER_KEY`
        //     allowance — quietly re-opening the multi-key minting that per-key budget exists
        //     to bound.
        // Throwing before `/v2/register` rather than after is deliberate: a token minted
        // against a key this device cannot remember is the expensive half of that same
        // loophole, so it is better not to spend the budget at all. The case is
        // `.attestationFailedTransiently` because a Keychain write is exactly the kind of thing
        // that can succeed next time, and nothing about this device's ability to attest is in
        // question.
        if existingKeyId == nil {
            guard attestKeyStore.store(keyId) else {
                throw AICoachError.attestationFailedTransiently
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v2/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct AttestedRegisterBody: Encodable {
            let key_id: String
            let challenge: String
            let attestation: String
        }
        // `keyId` from DeviceCheck is already base64 of the raw 32-byte key id, which is the
        // form the server decodes — passing it through unchanged is deliberate, not a missed
        // re-encoding.
        request.httpBody = try JSONEncoder().encode(
            AttestedRegisterBody(
                key_id: keyId,
                challenge: challenge,
                attestation: attestation.base64EncodedString()
            )
        )

        let (data, http) = try await performSend(request)
        guard (200...299).contains(http.statusCode) else {
            throw AICoachError.serverError(status: http.statusCode)
        }
        struct RegisterResponse: Decodable { let token: String }
        guard let decoded = try? JSONDecoder().decode(RegisterResponse.self, from: data) else {
            throw AICoachError.decodingError
        }
        // Storing is best-effort at the Keychain-API level (`store` returns `Bool`, mirroring
        // every sibling Keychain store in this codebase) — a failure here still throws, so the
        // caller never treats a token it could not actually persist as a success.
        guard tokenStore.store(decoded.token) else {
            throw AICoachError.decodingError
        }
        return decoded.token
    }

    /// `POST /v1/attest/challenge` — returns the base64 challenge string verbatim, because it
    /// has to go back to the server in exactly the form it arrived.
    private func fetchAttestChallenge() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/attest/challenge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, http) = try await performSend(request)
        guard (200...299).contains(http.statusCode) else {
            throw AICoachError.serverError(status: http.statusCode)
        }
        struct ChallengeResponse: Decodable { let challenge: String }
        guard let decoded = try? JSONDecoder().decode(ChallengeResponse.self, from: data) else {
            throw AICoachError.decodingError
        }
        return decoded.challenge
    }

    /// `POST /v1/chat`: send the full turn history (system/context + prior turns + the new query)
    /// and return the assistant's reply text. Throws `.notEnabled` — never crashes, never touches
    /// the network — when no token is stored, which is the expected state for the overwhelming
    /// majority of installs (opt-in, default off).
    func sendChat(messages: [AICoachMessage]) async throws -> String {
        guard let token = tokenStore.token() else { throw AICoachError.notEnabled }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct ChatRequestBody: Encodable { let messages: [AICoachMessage] }
        request.httpBody = try JSONEncoder().encode(ChatRequestBody(messages: messages))

        let (data, http) = try await performSend(request)
        guard (200...299).contains(http.statusCode) else {
            throw AICoachError.serverError(status: http.statusCode)
        }
        struct ChatResponseBody: Decodable { let reply: String }
        guard let decoded = try? JSONDecoder().decode(ChatResponseBody.self, from: data) else {
            throw AICoachError.decodingError
        }
        return decoded.reply
    }

    /// Turning the coach off: delete the Keychain token FIRST — so `isEnabled`/`sendChat`
    /// immediately and permanently revert to "not enabled" no matter what happens next, no silent
    /// re-enable — then best-effort ask the server to revoke that same token via `POST
    /// /v1/revoke`. Independent audit finding (2026-07-23): without the server call, a token
    /// exfiltrated from this device before the user disabled the feature (jailbreak, backup
    /// extraction, debugger attach) would keep authenticating `/v1/chat` indefinitely — the old
    /// local-only `disable()` correctly ended THIS device's use of the token but never told the
    /// server the token should stop working at all.
    ///
    /// The revoke call is fire-and-forget: this method returns as soon as the local delete is
    /// done (matching the consent screen's "deleted immediately" promise, which must not become
    /// "deleted after a network round trip"), and a dropped/offline revoke leaves local state
    /// exactly as correct as it already was — turning the feature back on always mints a fresh
    /// token via `register()`, never resurrects this one. `@discardableResult` keeps every
    /// existing call site (`AICoachConsentScreen.disableModule`) compiling unchanged; tests await
    /// the returned `Task` to observe the revoke call deterministically.
    @discardableResult
    func disable() -> Task<Void, Never> {
        let token = tokenStore.token()
        tokenStore.remove()
        guard let token else { return Task {} }
        return Task { [self] in
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/revoke"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await performSend(request)
        }
    }

    private func performSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as AICoachError {
            throw error
        } catch {
            throw AICoachError.transportError
        }
    }
}
