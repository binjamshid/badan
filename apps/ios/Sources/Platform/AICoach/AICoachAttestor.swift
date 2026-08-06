import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// App Attest seam for `AICoachClient` — the device's half of proving to
/// `backend/api` that a registration request comes from a genuine, unmodified BADAN
/// install rather than a script holding the URL.
///
/// Why this exists at all: `/v1/register` had nothing to authenticate a caller against,
/// by design — BADAN has zero accounts (ADR-0002/D-2) — which left rate limiting as the
/// only bound on OpenRouter spend. Attestation supplies proof-of-genuine-app WITHOUT
/// supplying an identity: the key id below is a random per-install value, and no user
/// data, health or otherwise, is involved. That keeps ADR-0002 intact; it does not widen
/// it.
///
/// A protocol rather than a direct `DCAppAttestService` call for the same reason
/// `AICoachTransporting` is one: the real service only works on physical hardware, so
/// every test would otherwise have to be skipped on the simulator.
protocol AICoachAttesting {
    /// Whether this device can attest at all. `false` on the simulator and on any device
    /// where the platform declines to vend the service.
    var isSupported: Bool { get }

    /// Generate a fresh App Attest key. Returns the key id, which is what the server
    /// stores and what identifies this install to it thereafter.
    func generateKey() async throws -> String

    /// Attest `keyId` against a server-issued challenge. The returned blob is what
    /// `POST /v2/register` verifies.
    ///
    /// This makes a live round trip to Apple's attestation service, so it can fail for reasons
    /// that say nothing about whether this device is *able* to attest — a dropped connection
    /// arrives here as `DCError.serverUnavailable`. `AICoachClient` classifies that one as
    /// retryable and everything else as not; see `attestationError(for:)`.
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data

    /// Sign a request body with the already-attested key (ADR-0011 / D-37).
    ///
    /// This is the per-REQUEST half, and `POST /v1/footprints` is its only caller. Telemetry
    /// uses an assertion rather than the device token deliberately: a token is an identifier,
    /// and sending one alongside a footprint is precisely the join that decision forbids.
    ///
    /// The server rejects any assertion whose counter does not strictly exceed the stored
    /// one, so the platform's own monotonic counter is what prevents replay.
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Where the App Attest key id is remembered between registrations.
///
/// Not a credential: the private key never leaves the Secure Enclave and cannot be
/// exported, so this is only the public handle to it. It is persisted anyway because
/// reusing one key per install is what makes the server's per-key token budget mean
/// anything — if every opt-in generated a fresh key, "at most N tokens per install" would
/// silently become "N tokens per opt-in", i.e. no bound at all.
///
/// Deliberately NOT cleared by `AICoachClient.disable()`. The token is a credential and is
/// deleted there; this is the device's stable attestation identity, and forgetting it on
/// every disable is exactly the loophole described above.
protocol AICoachAttestKeyStoring {
    func keyId() -> String?
    @discardableResult
    func store(_ keyId: String) -> Bool
}

/// Keychain-backed, with the same attribute choices and the same reasoning as
/// `KeychainAICoachDeviceTokenStore` — see that type's doc comment. `ThisDeviceOnly`
/// matters twice over here: an App Attest key is bound to the hardware that generated it,
/// so a key id restored onto a different device would name a key that device cannot use.
struct KeychainAICoachAttestKeyStore: AICoachAttestKeyStoring {
    static let service = "net.binjamshid.badan.aicoach.attest-key-id"
    static let account = "attest-key-id"

    func keyId() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func store(_ keyId: String) -> Bool {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
        ] as CFDictionary)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecValueData: Data(keyId.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status == errSecSuccess
    }
}

/// In-memory test double, same dual purpose as `InMemoryAICoachDeviceTokenStore`.
final class InMemoryAICoachAttestKeyStore: AICoachAttestKeyStoring {
    private var stored: String?
    init(_ initial: String? = nil) { stored = initial }
    func keyId() -> String? { stored }
    @discardableResult func store(_ keyId: String) -> Bool { stored = keyId; return true }
}

/// The real implementation, backed by `DCAppAttestService`.
///
/// Requires the `com.apple.developer.devicecheck.appattest-environment` entitlement
/// (`apps/ios/App/BADAN.entitlements`) whose value is per-configuration: Debug builds
/// attest against Apple's development service, Release against production. The server
/// checks which environment produced a blob and, in production, accepts only production
/// attestations — a mismatch surfaces there as a rejected registration, never as a build
/// error, so a Debug build talking to the production API failing to enable the coach is
/// expected behaviour and not a bug to chase.
struct DeviceCheckAICoachAttestor: AICoachAttesting {
    #if canImport(DeviceCheck)
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyId, error in
                if let keyId {
                    continuation.resume(returning: keyId)
                } else {
                    continuation.resume(throwing: error ?? AICoachError.attestationUnavailable)
                }
            }
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
                if let attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: error ?? AICoachError.attestationUnavailable)
                }
            }
        }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
                if let assertion {
                    continuation.resume(returning: assertion)
                } else {
                    continuation.resume(throwing: error ?? AICoachError.attestationUnavailable)
                }
            }
        }
    }
    #else
    // DeviceCheck is unavailable on this platform — report unsupported rather than fail
    // to compile, so the module still builds anywhere the rest of BADAN does.
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw AICoachError.attestationUnavailable }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        throw AICoachError.attestationUnavailable
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        throw AICoachError.attestationUnavailable
    }
    #endif
}
