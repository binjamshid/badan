import Foundation
import os

/// BADAN's THIRD network-reaching surface (ADR-0014 / D-44).
///
/// Until this file, `CLAUDE.md` said there were exactly two, and that a third required an ADR. This
/// is that third, and ADR-0014 is that ADR. It reverses D-32 (which dropped Sign in with Apple by
/// name), extends past D-40 (which carried the no-accounts posture to Android), and widens
/// ADR-0002/ADR-0010 from "no accounts, no sync, no server-side state" to "accounts and entitlement
/// state, and nothing else". The CI allowlist in `.github/workflows/ci.yml` gains one entry for this
/// file and no others; a fourth still requires a new decision.
///
/// ## What may travel on this wire, and what may not
///
/// May: an account id, an Apple identity token during sign-in, a referral code, and account metadata. Responses can include legacy purchase records.
///
/// May not, ever: a reading, a derived score, a baseline, a date or period key that says anything
/// about the user's body, a metric id, a source, a device model, a region. The
/// **"send no health data off device"** Never survives ADR-0014 completely intact — accounts were
/// the thing that changed, not that. `AccountPayloadShapeTests` asserts the encoded bytes of every
/// request type here against a closed field list and fails if one grows.
///
/// Optional account operations return errors independently of local feature access.
enum AccountClientError: Error, Equatable {
    case notSignedIn
    case transportError
    /// The session token was rejected. The caller signs out locally rather than retrying — a 401
    /// here means the account was deleted or the token revoked, and both are terminal.
    case unauthorized
    case referralRefused(String)
    case serverError(status: Int)
    case malformedResponse
}

/// Transport seam, mirroring `FootprintTransporting` and `AICoachTransporting` exactly.
protocol AccountTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The only place in this file that opens a socket.
struct URLSessionAccountTransport: AccountTransporting {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountClientError.transportError }
        return (data, http)
    }
}

/// The account state as the server reports it. One shape for every route that returns account
/// state, so there is a single decoder and a single place a new field would have to be added —
/// which is what makes the closed-shape test meaningful.
struct AccountStateResponse: Decodable, Equatable {
    var accountId: String
    var createdAt: Date
    var referralCode: String
    var successfulReferrals: Int
    var hasClaimedReferral: Bool
    var entitlements: [SyncedEntitlement]
    var referralGrantExpiresAt: Date?
    /// Present only on the sign-in route. Absent elsewhere, because re-issuing a session on every
    /// read would multiply live credentials for no reason.
    var accountToken: String?

    var identity: AccountIdentity {
        .init(accountId: accountId, createdAt: createdAt, referralCode: referralCode,
              successfulReferrals: successfulReferrals, hasClaimedReferral: hasClaimedReferral)
    }

    /// `syncedAt` is stamped by the CALLER from its own clock, never taken from the body. See
    /// `EntitlementSnapshot.syncedAt` — a server-supplied value would let the server extend the
    /// offline grace window that exists to bound it.
    func snapshot(syncedAt: Date) -> EntitlementSnapshot {
        .init(entitlements: entitlements,
              referralGrantExpiresAt: referralGrantExpiresAt,
              successfulReferrals: successfulReferrals,
              syncedAt: syncedAt)
    }
}

struct AccountClient {
    private let transport: AccountTransporting
    private let session: AccountSessionStoring
    private let baseURL: URL

    private static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Account")

    static let requestTimeout: TimeInterval = 30

    init(transport: AccountTransporting = URLSessionAccountTransport(),
         session: AccountSessionStoring = KeychainAccountSessionStore(),
         baseURL: URL = URL(string: "https://badan.binjamshid.com")!) {
        self.transport = transport
        self.session = session
        self.baseURL = baseURL
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Routes

    /// Exchange an Apple identity token for a BADAN session. Creates the account if this is the
    /// first time this Apple ID has signed in, and resolves to the existing one otherwise —
    /// the server decides which, because only it can compare the hashed subject.
    ///
    /// Stores the returned session token on success.
    func signIn(_ result: AppleSignInResult) async throws -> AccountStateResponse {
        let body = SignInRequest(identityToken: result.identityToken, nonce: result.nonce)
        let response = try await perform(.post, "v1/account/apple", body: body, authenticated: false)
        guard let token = response.accountToken else { throw AccountClientError.malformedResponse }
        session.store(token)
        return response
    }

    /// Re-read account state and entitlements.
    func refresh() async throws -> AccountStateResponse {
        try await perform(.get, "v1/account", body: Optional<SignInRequest>.none, authenticated: true)
    }

    /// Redeem someone else's referral code. The server re-checks every rule `ReferralPolicy` checks
    /// and owns the answer; a refusal comes back as `.referralRefused` carrying the server's reason
    /// code so the UI can say which rule was hit.
    func claimReferral(code: String) async throws -> AccountStateResponse {
        try await perform(.post, "v1/account/referral/claim",
                          body: ReferralClaimRequest(code: ReferralPolicy.normalise(code)),
                          authenticated: true)
    }

    /// Delete the account, server-side, permanently.
    ///
    /// Required by App Review guideline 5.1.1(v) for any app that offers account creation — and
    /// required by this repository's own posture regardless, since an account that cannot be removed
    /// is a worse reversal of ADR-0002 than one that can. The local session and cache are cleared by
    /// `AccountController` after this returns; the two are separate steps so a server-side failure
    /// never leaves the user believing a deletion happened that did not.
    func deleteAccount() async throws {
        _ = try await perform(.delete, "v1/account", body: Optional<SignInRequest>.none,
                              authenticated: true, expectsBody: false)
    }

    /// Clear only the local session. Not a deletion — the account still exists and signing in again
    /// resolves to it.
    func signOutLocally() {
        session.remove()
    }

    // MARK: - Transport

    private enum Method: String { case post = "POST", get = "GET", delete = "DELETE" }

    @discardableResult
    private func perform<Body: Encodable>(_ method: Method, _ path: String, body: Body?,
                                          authenticated: Bool,
                                          expectsBody: Bool = true) async throws
        -> AccountStateResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method.rawValue
        request.timeoutInterval = Self.requestTimeout

        if authenticated {
            guard let token = session.token() else { throw AccountClientError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let (data, http) = try await transport.send(request)

        if http.statusCode == 401 { throw AccountClientError.unauthorized }
        if http.statusCode == 409 || http.statusCode == 422 {
            // The referral routes are the only ones that answer with a machine-readable reason, and
            // it is a reason code from a closed set — never free text, and never anything derived
            // from the other account.
            let reason = (try? Self.decoder.decode(RefusalResponse.self, from: data))?.reason
            throw AccountClientError.referralRefused(reason ?? "refused")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Status only. No body echoed into the log — G8 applies here exactly as it does to
            // telemetry, and an account route's body is the one place an identifier could appear.
            Self.logger.warning("Account request rejected: \(http.statusCode, privacy: .public)")
            throw AccountClientError.serverError(status: http.statusCode)
        }

        guard expectsBody else { return .init(accountId: "", createdAt: .distantPast,
                                              referralCode: "", successfulReferrals: 0,
                                              hasClaimedReferral: false, entitlements: [],
                                              referralGrantExpiresAt: nil, accountToken: nil) }
        do {
            return try Self.decoder.decode(AccountStateResponse.self, from: data)
        } catch {
            throw AccountClientError.malformedResponse
        }
    }

    // MARK: - Wire bodies

    /// Every request body this client can produce. Kept together and deliberately small: the whole
    /// list is pinned by `AccountPayloadShapeTests`.
    struct SignInRequest: Encodable {
        let identityToken: String
        let nonce: String
    }

    struct ReferralClaimRequest: Encodable {
        let code: String
    }

    private struct RefusalResponse: Decodable {
        let reason: String
    }
}
