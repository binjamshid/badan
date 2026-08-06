import AuthenticationServices
import CryptoKit
import Foundation
import UIKit
import os

/// The Sign in with Apple leg (ADR-0014 / D-44).
///
/// ## No scopes are requested
///
/// `requestedScopes` is left EMPTY. Apple would hand over `fullName` and `email` on first
/// authorisation for the asking, and every SIWA tutorial asks. BADAN does not: it has no use for
/// either, and a field that is never collected cannot later leak, cannot appear in a breach, cannot
/// be subpoenaed, and cannot quietly start being used by a feature written two years from now.
/// D-44 reversed the no-accounts posture; it did not reverse the reason that posture existed.
///
/// What comes back is an identity token — a JWT Apple signed, carrying an opaque `sub` that is
/// stable for this Apple ID against this app team and useless to anyone else. That is the entire
/// identity BADAN receives, and the server stores only a salted hash of it.
///
/// ## The nonce
///
/// A random nonce is generated per attempt, SHA-256'd into the request, and returned in the clear
/// alongside the token so the server can hash it and compare against the JWT's `nonce` claim. This
/// is what stops an identity token captured from one app instance being replayed to create or hijack
/// an account elsewhere. It is not optional and the server rejects a token whose nonce does not
/// match, rather than treating a missing nonce as acceptable.
enum AppleSignInError: Error, Equatable {
    case cancelled
    case noIdentityToken
    case failed(String)
}

/// One completed Apple authorisation, reduced to exactly what the server needs.
struct AppleSignInResult: Equatable, Sendable {
    /// The raw JWT, as Apple issued it.
    let identityToken: String
    /// The unhashed nonce. The server hashes this itself and compares to the token's claim.
    let nonce: String
}

/// Seam so `AccountController` is testable without a real Apple sheet, which cannot run headless.
protocol AppleSignInProviding: Sendable {
    func signIn() async throws -> AppleSignInResult
}

@MainActor
final class AppleSignInController: NSObject, AppleSignInProviding {
    private static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Account")

    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var currentNonce: String?

    nonisolated func signIn() async throws -> AppleSignInResult {
        try await MainActor.run { self }.present()
    }

    private func present() async throws -> AppleSignInResult {
        // A second sheet while one is open would strand the first continuation forever. Refusing is
        // correct rather than queueing: the user tapped twice on one button.
        if continuation != nil { throw AppleSignInError.failed("a sign-in is already in progress") }

        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        // Intentionally empty. See the type doc — this is the whole privacy argument, in one line
        // that looks like an omission.
        request.requestedScopes = []
        request.nonce = Self.sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<AppleSignInResult, Error>) {
        // Cleared BEFORE resuming: a caller that immediately retries from the resumed task must not
        // find a stale continuation still parked here.
        let pending = continuation
        continuation = nil
        currentNonce = nil
        pending?.resume(with: result)
    }

    // MARK: - Nonce

    /// 32 bytes of `SecRandomCopyBytes`, base64url-encoded.
    ///
    /// Not `UUID().uuidString`: a UUID is 122 bits with a documented structure, and while that is
    /// almost certainly enough here, "almost certainly enough" is the wrong standard for the value
    /// whose unpredictability is the only thing preventing token replay.
    static func randomNonce(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // `SecRandomCopyBytes` failing means the system CSPRNG is unavailable, which is not a
            // condition to paper over with `Int.random`. Trapping is the honest response: there is
            // no safe weaker nonce, and continuing would produce a sign-in that looks fine and is
            // not replay-safe.
            fatalError("SecRandomCopyBytes failed — cannot mint a sign-in nonce")
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppleSignInController: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization auth: ASAuthorization) {
        Task { @MainActor in
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                finish(.failure(AppleSignInError.noIdentityToken))
                return
            }
            // `credential.fullName` and `credential.email` are deliberately not read. They are nil
            // anyway with no scopes requested, and not touching them keeps that a fact about the
            // code rather than a fact about the request that a later edit could quietly change.
            finish(.success(AppleSignInResult(identityToken: token, nonce: nonce)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        Task { @MainActor in
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                finish(.failure(AppleSignInError.cancelled))
                return
            }
            Self.logger.error("Apple sign-in failed: \(String(describing: error), privacy: .public)")
            finish(.failure(AppleSignInError.failed(String(describing: error))))
        }
    }
}

extension AppleSignInController: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    /// base64url, unpadded — the encoding the nonce claim in a JWT is compared in.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
