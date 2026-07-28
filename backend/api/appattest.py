"""Apple App Attest verification — pure functions, no FastAPI, no I/O.

Why this exists (A9 / ADR-0010 / D-22 follow-up): `/v1/register` mints a device
token to anyone who asks. That is by design — BADAN has zero accounts (ADR-0002/
D-2), so there is no identity to gate registration behind — but it also means the
only thing bounding OpenRouter spend is a rate limiter on an endpoint that anyone
holding the URL can call. The 2026-07-23 audit already noted that minting tokens
must not be free and unbounded; rate limiting slows that down, it does not stop
it.

App Attest closes it without reintroducing accounts. Apple's attestation proves a
request came from a genuine, unmodified BADAN install on real Apple hardware. It
carries NO user identity, no health data, and nothing that could be joined back to
a person — the key id is a random per-install value. So this strengthens the
posture ADR-0002 sets rather than widening it: still no accounts, still no health
data server-side.

This module implements the checks in Apple's "Validating Apps That Connect to Your
Server". It deliberately takes the trust root as a parameter rather than reaching
for the network or a global: tests inject a throwaway CA, production passes
`APPLE_APP_ATTEST_ROOT_CA_PEM` below.

Nothing here logs. Callers must keep the G8 rule (no request bodies in logs) —
an attestation blob is caller-supplied content and must never reach the log.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime, timezone

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

# Apple App Attestation Root CA, downloaded 2026-07-28 from
# https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
#   subject/issuer : CN=Apple App Attestation Root CA, O=Apple Inc., ST=California
#   SHA-256        : 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:
#                    D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
#   validity       : 2020-03-18 → 2045-03-15
# Self-signed P-384. Embedded rather than fetched at runtime on purpose: a trust
# root fetched over the network is only as trustworthy as that fetch, and this
# service must keep working when apple.com does not. Re-verify the fingerprint
# above if this is ever replaced.
APPLE_APP_ATTEST_ROOT_CA_PEM = b"""-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
"""

# Apple's OID for the attestation nonce, carried as an extension on the leaf
# ("credential") certificate.
NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")

# The AAGUID field in authenticator data says which attestation environment
# produced the blob. Development attestations are NOT interchangeable with
# production ones, which is the same split the app's
# $(APP_ATTEST_ENV) entitlement value encodes — a mismatch shows up here, as a
# rejected attestation, and nowhere earlier.
AAGUID_DEVELOPMENT = b"appattestdevelop"
AAGUID_PRODUCTION = b"appattest" + b"\x00" * 7

ENVIRONMENT_BY_AAGUID = {
    AAGUID_DEVELOPMENT: "development",
    AAGUID_PRODUCTION: "production",
}


class AttestationError(Exception):
    """Any failed check. Deliberately one type with a short, non-specific message:
    the caller turns this into a flat 401 and must not hand an attacker a probe
    that says which step failed."""


@dataclass(frozen=True)
class VerifiedAttestation:
    """What a caller needs to persist after a successful attestation."""

    key_id: bytes
    #: SubjectPublicKeyInfo DER — the form to store and reload for later assertions.
    public_key_der: bytes
    #: authData's signature counter. Always 0 for a fresh attestation; assertions
    #: must strictly increase from it.
    counter: int
    #: "development" or "production", derived from the AAGUID.
    environment: str


# --- minimal DER reader, used only for the nonce extension --------------------
#
# The extension body is a fixed, tiny shape:
#     SEQUENCE { [1] EXPLICIT { OCTET STRING (32 bytes) } }
# A strict hand-walk of exactly that shape is preferable to a general ASN.1
# parser here: the input is attacker-supplied, and "parse only the one structure
# we expect, reject everything else" is a much smaller surface than "parse
# arbitrary ASN.1 and then look for something that resembles a nonce".


def _read_der_tlv(data: bytes, offset: int) -> tuple[int, bytes, int]:
    """Read one DER tag-length-value at `offset`. Returns (tag, value, next_offset).

    Supports short form and multi-byte long form lengths, rejects indefinite
    length (invalid in DER) and any length that runs past the buffer.
    """
    if offset + 2 > len(data):
        raise AttestationError("attestation rejected")
    tag = data[offset]
    length_byte = data[offset + 1]
    cursor = offset + 2
    if length_byte < 0x80:
        length = length_byte
    elif length_byte == 0x80:
        raise AttestationError("attestation rejected")  # indefinite length
    else:
        num_bytes = length_byte & 0x7F
        if num_bytes > 4 or cursor + num_bytes > len(data):
            raise AttestationError("attestation rejected")
        length = int.from_bytes(data[cursor:cursor + num_bytes], "big")
        cursor += num_bytes
    if cursor + length > len(data):
        raise AttestationError("attestation rejected")
    return tag, data[cursor:cursor + length], cursor + length


def _nonce_from_extension(extension_value: bytes) -> bytes:
    """Pull the 32-byte nonce out of the leaf certificate's Apple extension."""
    tag, sequence, _ = _read_der_tlv(extension_value, 0)
    if tag != 0x30:  # SEQUENCE
        raise AttestationError("attestation rejected")
    tag, context, _ = _read_der_tlv(sequence, 0)
    if tag != 0xA1:  # [1] constructed
        raise AttestationError("attestation rejected")
    tag, nonce, _ = _read_der_tlv(context, 0)
    if tag != 0x04 or len(nonce) != 32:  # OCTET STRING
        raise AttestationError("attestation rejected")
    return nonce


# --- certificate chain --------------------------------------------------------


def _verify_signed_by(child: x509.Certificate, parent: x509.Certificate) -> None:
    """Verify `child`'s signature with `parent`'s public key.

    Hand-rolled rather than using `cryptography`'s verification API on purpose:
    that API builds paths for TLS server certs and enforces SAN/hostname rules an
    attestation chain does not have and would fail. The checks that actually
    matter here are the signature and the validity window, both done explicitly.
    """
    public_key = parent.public_key()
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise AttestationError("attestation rejected")
    try:
        public_key.verify(
            child.signature,
            child.tbs_certificate_bytes,
            ec.ECDSA(child.signature_hash_algorithm),
        )
    except (InvalidSignature, ValueError, TypeError) as exc:
        raise AttestationError("attestation rejected") from exc


def _check_validity(certificate: x509.Certificate, now: datetime) -> None:
    if not (certificate.not_valid_before_utc <= now <= certificate.not_valid_after_utc):
        raise AttestationError("attestation rejected")


# --- authenticator data -------------------------------------------------------


@dataclass(frozen=True)
class _AuthenticatorData:
    rp_id_hash: bytes
    counter: int
    aaguid: bytes
    credential_id: bytes


def _parse_authenticator_data(auth_data: bytes, *, expect_credential: bool) -> _AuthenticatorData:
    """Parse the WebAuthn-shaped authenticator data App Attest reuses.

    Layout: rpIdHash(32) | flags(1) | counter(4, big-endian) | then, for an
    attestation, attested credential data: aaguid(16) | credIdLen(2) | credId.
    Assertions stop after the counter.
    """
    if len(auth_data) < 37:
        raise AttestationError("attestation rejected")
    rp_id_hash = auth_data[0:32]
    counter = int.from_bytes(auth_data[33:37], "big")
    if not expect_credential:
        return _AuthenticatorData(rp_id_hash, counter, b"", b"")
    if len(auth_data) < 55:
        raise AttestationError("attestation rejected")
    aaguid = auth_data[37:53]
    credential_id_length = int.from_bytes(auth_data[53:55], "big")
    credential_id = auth_data[55:55 + credential_id_length]
    if len(credential_id) != credential_id_length:
        raise AttestationError("attestation rejected")
    return _AuthenticatorData(rp_id_hash, counter, aaguid, credential_id)


# --- public API ---------------------------------------------------------------


def verify_attestation(
    *,
    attestation: bytes,
    key_id: bytes,
    challenge: bytes,
    app_id: str,
    allowed_environments: frozenset[str] = frozenset({"production"}),
    root_ca_pem: bytes = APPLE_APP_ATTEST_ROOT_CA_PEM,
    now: datetime | None = None,
) -> VerifiedAttestation:
    """Verify a `DCAppAttestService.attestKey` blob.

    `app_id` is "<team id>.<bundle id>" — for BADAN, 54T3MDUR7H.net.binjamshid.badan.
    `challenge` must be a server-issued, single-use value the caller has already
    confirmed was issued and not yet spent; nothing here can tell a replayed
    challenge from a fresh one.

    Raises `AttestationError` on any failure. Returns what to persist on success.
    """
    now = now or datetime.now(timezone.utc)

    try:
        decoded = cbor2.loads(attestation)
    except Exception as exc:  # noqa: BLE001 — any malformed CBOR is one outcome
        raise AttestationError("attestation rejected") from exc
    if not isinstance(decoded, dict):
        raise AttestationError("attestation rejected")
    if decoded.get("fmt") != "apple-appattest":
        raise AttestationError("attestation rejected")
    statement = decoded.get("attStmt")
    auth_data = decoded.get("authData")
    if not isinstance(statement, dict) or not isinstance(auth_data, bytes):
        raise AttestationError("attestation rejected")
    chain_der = statement.get("x5c")
    if not isinstance(chain_der, list) or len(chain_der) != 2:
        raise AttestationError("attestation rejected")
    if not all(isinstance(entry, bytes) for entry in chain_der):
        raise AttestationError("attestation rejected")

    # 1. Chain: leaf ← intermediate ← Apple root. The root is our pinned copy, not
    #    whatever the caller sent, so a self-consistent attacker-built chain fails
    #    at the last hop no matter how well-formed the first two are.
    try:
        leaf = x509.load_der_x509_certificate(chain_der[0])
        intermediate = x509.load_der_x509_certificate(chain_der[1])
        root = x509.load_pem_x509_certificate(root_ca_pem)
    except ValueError as exc:
        raise AttestationError("attestation rejected") from exc

    for certificate in (leaf, intermediate):
        _check_validity(certificate, now)
    _verify_signed_by(leaf, intermediate)
    _verify_signed_by(intermediate, root)

    # 2. Nonce: SHA256(authData || SHA256(challenge)) must equal the value Apple
    #    baked into the leaf certificate's extension. This is the step that binds
    #    the attestation to OUR challenge — without it a captured attestation from
    #    any install replays forever.
    client_data_hash = hashlib.sha256(challenge).digest()
    expected_nonce = hashlib.sha256(auth_data + client_data_hash).digest()
    try:
        extension = leaf.extensions.get_extension_for_oid(NONCE_OID)
    except x509.ExtensionNotFound as exc:
        raise AttestationError("attestation rejected") from exc
    if not isinstance(extension.value, x509.UnrecognizedExtension):
        raise AttestationError("attestation rejected")
    if not _constant_time_eq(_nonce_from_extension(extension.value.value), expected_nonce):
        raise AttestationError("attestation rejected")

    # 3. The key id the caller claims must be the hash of the leaf's public key —
    #    i.e. the caller cannot present someone else's valid attestation under a
    #    key id it controls.
    public_key = leaf.public_key()
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise AttestationError("attestation rejected")
    uncompressed_point = public_key.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    if not _constant_time_eq(hashlib.sha256(uncompressed_point).digest(), key_id):
        raise AttestationError("attestation rejected")

    # 4. authData: right app, fresh key, known environment, matching credential id.
    parsed = _parse_authenticator_data(auth_data, expect_credential=True)
    if not _constant_time_eq(parsed.rp_id_hash, hashlib.sha256(app_id.encode("utf-8")).digest()):
        raise AttestationError("attestation rejected")
    if parsed.counter != 0:
        raise AttestationError("attestation rejected")
    environment = ENVIRONMENT_BY_AAGUID.get(parsed.aaguid)
    if environment is None or environment not in allowed_environments:
        raise AttestationError("attestation rejected")
    if not _constant_time_eq(parsed.credential_id, key_id):
        raise AttestationError("attestation rejected")

    return VerifiedAttestation(
        key_id=key_id,
        public_key_der=public_key.public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
        ),
        counter=parsed.counter,
        environment=environment,
    )


def verify_assertion(
    *,
    assertion: bytes,
    client_data: bytes,
    public_key_der: bytes,
    previous_counter: int,
    app_id: str,
) -> int:
    """Verify a `DCAppAttestService.generateAssertion` blob; return the new counter.

    Not used by `/v1/register` (one attestation per install is what gates token
    issuance there), but this is the half a per-request scheme needs, and it is
    the same trust material, so it lives here rather than being reinvented
    alongside it. The caller must persist the returned counter and must reject any
    assertion whose counter does not strictly exceed the stored one — that is the
    only thing preventing replay of a captured assertion.
    """
    try:
        decoded = cbor2.loads(assertion)
    except Exception as exc:  # noqa: BLE001
        raise AttestationError("assertion rejected") from exc
    if not isinstance(decoded, dict):
        raise AttestationError("assertion rejected")
    signature = decoded.get("signature")
    auth_data = decoded.get("authenticatorData")
    if not isinstance(signature, bytes) or not isinstance(auth_data, bytes):
        raise AttestationError("assertion rejected")

    try:
        public_key = serialization.load_der_public_key(public_key_der)
    except ValueError as exc:
        raise AttestationError("assertion rejected") from exc
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise AttestationError("assertion rejected")

    nonce = hashlib.sha256(auth_data + hashlib.sha256(client_data).digest()).digest()
    try:
        public_key.verify(signature, nonce, ec.ECDSA(hashes.SHA256()))
    except (InvalidSignature, ValueError) as exc:
        raise AttestationError("assertion rejected") from exc

    parsed = _parse_authenticator_data(auth_data, expect_credential=False)
    if not _constant_time_eq(parsed.rp_id_hash, hashlib.sha256(app_id.encode("utf-8")).digest()):
        raise AttestationError("assertion rejected")
    if parsed.counter <= previous_counter:
        raise AttestationError("assertion rejected")
    return parsed.counter


def _constant_time_eq(left: bytes, right: bytes) -> bool:
    """`hmac.compare_digest` semantics without importing hmac for one call. Used
    for every comparison of a caller-supplied value against an expected one, so
    none of them leak a byte-position timing signal."""
    import hmac

    return hmac.compare_digest(left, right)
