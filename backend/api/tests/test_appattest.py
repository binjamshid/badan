"""Tests for `appattest.py`.

There is no real attestation blob checked in — one can only be produced by a
physical Apple device, and a captured one would expire and could not be varied to
exercise the failure paths anyway. Instead every test builds a *synthetic* chain
with a throwaway root, which is exactly why `verify_attestation` takes
`root_ca_pem` as a parameter. The pinned Apple root is asserted on separately
(`test_apple_root_is_the_expected_certificate`) so the constant cannot rot
unnoticed.

The negative tests matter more than the happy path here: a verifier that accepts
a valid attestation but also accepts a tampered one is worse than no verifier,
because it reads as protection.

Run:  python -m pytest backend/api/tests -q   (from the repo root)
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone

import cbor2
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from appattest import (
    AAGUID_DEVELOPMENT,
    AAGUID_PRODUCTION,
    APPLE_APP_ATTEST_ROOT_CA_PEM,
    NONCE_OID,
    AttestationError,
    verify_assertion,
    verify_attestation,
)

APP_ID = "54T3MDUR7H.net.binjamshid.badan"
CHALLENGE = b"a-server-issued-single-use-challenge"
NOW = datetime(2026, 7, 28, tzinfo=timezone.utc)


# --- synthetic attestation builder -------------------------------------------


def _self_signed_ca() -> tuple[ec.EllipticCurvePrivateKey, x509.Certificate]:
    key = ec.generate_private_key(ec.SECP384R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Attest Root")])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(days=1))
        .not_valid_after(NOW + timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA384())
    )
    return key, certificate


def _issue(
    subject_common_name: str,
    subject_key: ec.EllipticCurvePrivateKey,
    issuer_key: ec.EllipticCurvePrivateKey,
    issuer_certificate: x509.Certificate,
    *,
    is_ca: bool,
    nonce: bytes | None = None,
    not_valid_after: datetime | None = None,
) -> x509.Certificate:
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_common_name)]))
        .issuer_name(issuer_certificate.subject)
        .public_key(subject_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(days=1))
        .not_valid_after(not_valid_after or (NOW + timedelta(days=30)))
        .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    )
    if nonce is not None:
        # SEQUENCE { [1] { OCTET STRING nonce } } — the shape Apple uses.
        der = bytes([0x30, len(nonce) + 4, 0xA1, len(nonce) + 2, 0x04, len(nonce)]) + nonce
        builder = builder.add_extension(
            x509.UnrecognizedExtension(NONCE_OID, der), critical=False
        )
    return builder.sign(issuer_key, hashes.SHA256())


def _authenticator_data(
    *, app_id: str, aaguid: bytes, credential_id: bytes, counter: int = 0
) -> bytes:
    return (
        hashlib.sha256(app_id.encode()).digest()
        + bytes([0x40])  # flags; App Attest does not require any particular bit here
        + counter.to_bytes(4, "big")
        + aaguid
        + len(credential_id).to_bytes(2, "big")
        + credential_id
    )


def build_attestation(
    *,
    app_id: str = APP_ID,
    challenge: bytes = CHALLENGE,
    aaguid: bytes = AAGUID_PRODUCTION,
    counter: int = 0,
    break_leaf_signature: bool = False,
    leaf_not_valid_after: datetime | None = None,
    omit_nonce_extension: bool = False,
    wrong_nonce: bool = False,
    leaf_key: ec.EllipticCurvePrivateKey | None = None,
    root: tuple[ec.EllipticCurvePrivateKey, x509.Certificate] | None = None,
):
    """Return (attestation_cbor, key_id, root_pem, leaf_private_key).

    `leaf_key` and `root` let a caller build several attestations that share an
    identity — needed to exercise anything keyed on the key id (the per-key token
    budget) rather than getting a fresh key every call.
    """
    root_key, root_certificate = root if root is not None else _self_signed_ca()
    intermediate_key = ec.generate_private_key(ec.SECP256R1())
    intermediate = _issue(
        "Test Attest Intermediate", intermediate_key, root_key, root_certificate, is_ca=True
    )

    leaf_key = leaf_key or ec.generate_private_key(ec.SECP256R1())
    uncompressed = leaf_key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    key_id = hashlib.sha256(uncompressed).digest()

    auth_data = _authenticator_data(
        app_id=app_id, aaguid=aaguid, credential_id=key_id, counter=counter
    )
    nonce = hashlib.sha256(auth_data + hashlib.sha256(challenge).digest()).digest()
    if wrong_nonce:
        nonce = hashlib.sha256(b"not the nonce").digest()

    signing_key = ec.generate_private_key(ec.SECP256R1()) if break_leaf_signature else intermediate_key
    leaf = _issue(
        "Test Attest Leaf",
        leaf_key,
        signing_key,
        intermediate,
        is_ca=False,
        nonce=None if omit_nonce_extension else nonce,
        not_valid_after=leaf_not_valid_after,
    )

    attestation = cbor2.dumps(
        {
            "fmt": "apple-appattest",
            "attStmt": {
                "x5c": [
                    leaf.public_bytes(serialization.Encoding.DER),
                    intermediate.public_bytes(serialization.Encoding.DER),
                ],
                "receipt": b"",
            },
            "authData": auth_data,
        }
    )
    root_pem = root_certificate.public_bytes(serialization.Encoding.PEM)
    return attestation, key_id, root_pem, leaf_key


def _verify(attestation, key_id, root_pem, **overrides):
    kwargs = dict(
        attestation=attestation,
        key_id=key_id,
        challenge=CHALLENGE,
        app_id=APP_ID,
        allowed_environments=frozenset({"production"}),
        root_ca_pem=root_pem,
        now=NOW,
    )
    kwargs.update(overrides)
    return verify_attestation(**kwargs)


# --- the pinned root ----------------------------------------------------------


def test_apple_root_is_the_expected_certificate():
    """Guards the embedded constant: right subject, self-signed, unexpired, and the
    exact SHA-256 recorded next to it in appattest.py."""
    certificate = x509.load_pem_x509_certificate(APPLE_APP_ATTEST_ROOT_CA_PEM)
    assert "Apple App Attestation Root CA" in certificate.subject.rfc4514_string()
    assert certificate.subject == certificate.issuer
    assert certificate.fingerprint(hashes.SHA256()).hex() == (
        "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"
    )
    assert certificate.not_valid_after_utc > datetime.now(timezone.utc)


# --- happy path ---------------------------------------------------------------


def test_valid_attestation_is_accepted():
    attestation, key_id, root_pem, _ = build_attestation()
    result = _verify(attestation, key_id, root_pem)
    assert result.key_id == key_id
    assert result.counter == 0
    assert result.environment == "production"
    assert serialization.load_der_public_key(result.public_key_der)


def test_development_attestation_accepted_only_when_allowed():
    attestation, key_id, root_pem, _ = build_attestation(aaguid=AAGUID_DEVELOPMENT)
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)
    result = _verify(
        attestation, key_id, root_pem, allowed_environments=frozenset({"development"})
    )
    assert result.environment == "development"


# --- the checks that carry the weight ----------------------------------------


def test_rejects_chain_that_does_not_reach_the_pinned_root():
    """The whole point: an attacker who builds a perfectly self-consistent chain
    still fails, because the root is ours and not theirs."""
    attestation, key_id, _, _ = build_attestation()
    _, other_root = _self_signed_ca()
    with pytest.raises(AttestationError):
        _verify(
            attestation,
            key_id,
            other_root.public_bytes(serialization.Encoding.PEM),
        )


def test_rejects_attestation_for_a_different_challenge():
    """Replay guard. A blob captured from a legitimate install must not verify
    against a challenge it was not produced for."""
    attestation, key_id, root_pem, _ = build_attestation(challenge=b"some other challenge")
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_tampered_nonce():
    attestation, key_id, root_pem, _ = build_attestation(wrong_nonce=True)
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_missing_nonce_extension():
    attestation, key_id, root_pem, _ = build_attestation(omit_nonce_extension=True)
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_leaf_not_signed_by_intermediate():
    attestation, key_id, root_pem, _ = build_attestation(break_leaf_signature=True)
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_key_id_that_is_not_the_public_key_hash():
    """Stops presenting a valid attestation under a key id the caller controls."""
    attestation, _, root_pem, _ = build_attestation()
    with pytest.raises(AttestationError):
        _verify(attestation, hashlib.sha256(b"claimed key id").digest(), root_pem)


def test_rejects_attestation_for_another_app():
    attestation, key_id, root_pem, _ = build_attestation(app_id="54T3MDUR7H.net.binjamshid.other")
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_nonzero_counter():
    attestation, key_id, root_pem, _ = build_attestation(counter=1)
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_unknown_environment():
    attestation, key_id, root_pem, _ = build_attestation(aaguid=b"totallyunknown!!")
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


def test_rejects_expired_leaf_certificate():
    attestation, key_id, root_pem, _ = build_attestation(
        leaf_not_valid_after=NOW - timedelta(days=1)
    )
    with pytest.raises(AttestationError):
        _verify(attestation, key_id, root_pem)


@pytest.mark.parametrize(
    "blob",
    [
        b"",
        b"not cbor at all",
        cbor2.dumps({"fmt": "something-else"}),
        cbor2.dumps({"fmt": "apple-appattest", "attStmt": {}, "authData": b""}),
        cbor2.dumps({"fmt": "apple-appattest", "attStmt": {"x5c": []}, "authData": b"x" * 60}),
        cbor2.dumps([1, 2, 3]),
    ],
)
def test_rejects_malformed_input_without_crashing(blob):
    """Every malformed shape must come back as AttestationError, never an
    unhandled exception — an uncaught error here is a 500 and a stack trace, and
    this endpoint is reachable by anyone."""
    with pytest.raises(AttestationError):
        _verify(blob, b"\x00" * 32, APPLE_APP_ATTEST_ROOT_CA_PEM)


def test_error_message_does_not_reveal_which_check_failed():
    """A caller must not be able to use the error text to probe the verifier."""
    messages = set()
    for builder_kwargs in ({"wrong_nonce": True}, {"counter": 1}, {"app_id": "X.y"}):
        attestation, key_id, root_pem, _ = build_attestation(**builder_kwargs)
        with pytest.raises(AttestationError) as caught:
            _verify(attestation, key_id, root_pem)
        messages.add(str(caught.value))
    assert messages == {"attestation rejected"}


# --- assertions ---------------------------------------------------------------


def _build_assertion(leaf_key, *, app_id=APP_ID, counter=1, client_data=b"payload"):
    auth_data = hashlib.sha256(app_id.encode()).digest() + bytes([0x40]) + counter.to_bytes(4, "big")
    nonce = hashlib.sha256(auth_data + hashlib.sha256(client_data).digest()).digest()
    signature = leaf_key.sign(nonce, ec.ECDSA(hashes.SHA256()))
    return cbor2.dumps({"signature": signature, "authenticatorData": auth_data})


def test_valid_assertion_returns_new_counter():
    attestation, key_id, root_pem, leaf_key = build_attestation()
    verified = _verify(attestation, key_id, root_pem)
    assertion = _build_assertion(leaf_key, counter=1)
    assert (
        verify_assertion(
            assertion=assertion,
            client_data=b"payload",
            public_key_der=verified.public_key_der,
            previous_counter=0,
            app_id=APP_ID,
        )
        == 1
    )


def test_assertion_replay_is_rejected():
    """The counter must strictly increase — replaying a captured assertion at the
    same counter is exactly the attack this check exists for."""
    attestation, key_id, root_pem, leaf_key = build_attestation()
    verified = _verify(attestation, key_id, root_pem)
    assertion = _build_assertion(leaf_key, counter=5)
    with pytest.raises(AttestationError):
        verify_assertion(
            assertion=assertion,
            client_data=b"payload",
            public_key_der=verified.public_key_der,
            previous_counter=5,
            app_id=APP_ID,
        )


def test_assertion_over_different_client_data_is_rejected():
    """Binds the assertion to the request body it was generated for."""
    attestation, key_id, root_pem, leaf_key = build_attestation()
    verified = _verify(attestation, key_id, root_pem)
    assertion = _build_assertion(leaf_key, client_data=b"payload")
    with pytest.raises(AttestationError):
        verify_assertion(
            assertion=assertion,
            client_data=b"a different payload",
            public_key_der=verified.public_key_der,
            previous_counter=0,
            app_id=APP_ID,
        )
