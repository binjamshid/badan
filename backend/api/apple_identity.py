"""Sign in with Apple identity-token verification — pure functions, no FastAPI, no I/O.

Why this exists (ADR-0014 / D-44): BADAN acquired accounts, and an account is only
worth anything if the thing that creates it cannot be forged. The client sends the
JWT Apple issued; this module decides whether to believe it.

Deliberately the same shape as `appattest.py`: no network, no globals, and the
trust material (Apple's JWKS) arrives as a parameter so tests inject a throwaway
key pair and production passes what it fetched and cached. A module that fetched
its own keys could not be tested without either a network or a monkeypatch, and
the thing being tested here is exactly the part you cannot afford to get wrong.

Implemented against `cryptography`, not a JWT library. Not out of preference —
`backend/api/requirements.txt` already pins `cryptography` for App Attest, and the
verification below is a signature check plus five claim comparisons. Adding a
dependency to avoid writing those five comparisons would trade a reviewable 40
lines for an unreviewable transitive tree, on the one route where the whole
security argument lives.

**The checks are not optional and none of them defaults to permissive.** Every
failure path raises; there is no code path that returns an identity on a token it
could not fully verify.

Nothing here logs. A token is caller-supplied content and must never reach the log
(G8), and its `sub` claim is the one value in this service that is genuinely
identifying.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"

# How far a token's `iat` may sit in the future before it is refused. Covers ordinary
# clock skew between Apple's signer and this VPS and nothing more; a token minted
# meaningfully in the future is not a clock problem.
MAX_CLOCK_SKEW_SECONDS = 300

# Apple identity tokens are short-lived (minutes). This is an upper bound on how old
# one may be when presented, independent of `exp`: it stops a token captured from a
# device's logs months ago from being replayed if `exp` were ever generous. The nonce
# check is the primary defence; this is the belt.
MAX_TOKEN_AGE_SECONDS = 900

# A JWT is caller-supplied. Bound every segment before doing anything expensive with it.
MAX_TOKEN_BYTES = 8192


class AppleIdentityError(Exception):
    """Any reason a token was not accepted.

    One exception type, and the message is for the server's own operators — the route
    turns every instance of it into the same opaque 401. Telling a caller *which*
    check failed would let them tune a forgery against the checks one at a time.
    """


@dataclass(frozen=True)
class AppleIdentity:
    """What a verified token yields. Note how little it is.

    `subject` is Apple's `sub` claim: opaque, stable for this Apple ID against this
    app's team, and meaningless to anyone else. It is the ONLY identifying value that
    enters this service, and `accounts.py` stores a salted hash of it rather than the
    value itself — so a dump of the accounts table does not reveal which Apple IDs use
    BADAN even to someone who can enumerate Apple IDs.

    There is no name field and no email field, because the client requests neither
    scope (`AppleSignInController`). If Apple ever begins including them unrequested,
    they stop here: this dataclass is what the rest of the service sees.
    """

    subject: str
    issued_at: float
    expires_at: float


def _b64url_decode(segment: str) -> bytes:
    padding_needed = (-len(segment)) % 4
    try:
        return base64.urlsafe_b64decode(segment + "=" * padding_needed)
    except (ValueError, TypeError) as exc:
        raise AppleIdentityError("segment is not valid base64url") from exc


def _decode_json_segment(segment: str, *, what: str) -> Mapping[str, Any]:
    try:
        decoded = json.loads(_b64url_decode(segment))
    except (ValueError, UnicodeDecodeError) as exc:
        raise AppleIdentityError(f"{what} is not valid JSON") from exc
    if not isinstance(decoded, dict):
        raise AppleIdentityError(f"{what} is not a JSON object")
    return decoded


def _public_key_from_jwk(jwk: Mapping[str, Any]) -> rsa.RSAPublicKey:
    """Build an RSA public key from Apple's JWK.

    Apple publishes RSA keys only. `kty` is checked rather than assumed, so a JWKS that
    ever gains an EC key produces a clean refusal here instead of an obscure failure
    three lines later.
    """
    if jwk.get("kty") != "RSA":
        raise AppleIdentityError("unsupported key type in JWKS")
    try:
        n = int.from_bytes(_b64url_decode(jwk["n"]), "big")
        e = int.from_bytes(_b64url_decode(jwk["e"]), "big")
    except (KeyError, ValueError) as exc:
        raise AppleIdentityError("malformed JWK") from exc
    return rsa.RSAPublicNumbers(e=e, n=n).public_key()


def verify_identity_token(
    token: str,
    *,
    jwks: Sequence[Mapping[str, Any]],
    audience: str,
    expected_nonce: str,
    now: float,
) -> AppleIdentity:
    """Verify an Apple identity token and return the identity it carries.

    Args:
        token: the raw JWT, exactly as the client received it from Apple.
        jwks: Apple's current signing keys (the `keys` array from `APPLE_JWKS_URL`).
        audience: this app's bundle id. Apple sets `aud` to it, and checking it is what
            stops a token minted for a DIFFERENT app — including one an attacker owns
            and can mint tokens from at will — being presented here.
        expected_nonce: the RAW nonce the client generated. This function hashes it and
            compares against the token's `nonce` claim, which is what binds the token to
            one sign-in attempt on one device and defeats replay of a captured token.
        now: unix seconds.

    Raises:
        AppleIdentityError: on any failed check.
    """
    if not token or len(token.encode("utf-8")) > MAX_TOKEN_BYTES:
        raise AppleIdentityError("token missing or oversized")

    parts = token.split(".")
    if len(parts) != 3:
        raise AppleIdentityError("token is not a three-part JWS")
    header_segment, payload_segment, signature_segment = parts

    header = _decode_json_segment(header_segment, what="header")
    # Pinned, not read-and-trusted. Accepting the token's own `alg` is the classic JWT
    # break: `none` forges everything, and `HS256` lets an attacker sign with the public
    # key as an HMAC secret. Apple signs identity tokens with RS256 and only RS256.
    if header.get("alg") != "RS256":
        raise AppleIdentityError("unexpected signing algorithm")
    kid = header.get("kid")
    if not isinstance(kid, str) or not kid:
        raise AppleIdentityError("token header has no key id")

    matching = [k for k in jwks if k.get("kid") == kid]
    if not matching:
        # Apple rotates signing keys. A miss here usually means a stale JWKS cache, and
        # the route's job is to refetch once and retry before giving up — see
        # `_apple_jwks` in main.py.
        raise AppleIdentityError("no JWKS entry for the token's key id")
    public_key = _public_key_from_jwk(matching[0])

    signing_input = f"{header_segment}.{payload_segment}".encode("ascii")
    signature = _b64url_decode(signature_segment)
    try:
        public_key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
    except InvalidSignature as exc:
        raise AppleIdentityError("signature does not verify") from exc

    # Only now is the payload worth reading. Parsing claims before verifying the
    # signature would mean acting on attacker-controlled JSON.
    payload = _decode_json_segment(payload_segment, what="payload")

    if payload.get("iss") != APPLE_ISSUER:
        raise AppleIdentityError("unexpected issuer")

    # `aud` is a string for Apple, but the JWT spec allows an array. Both are handled so
    # a future format change is a passing test rather than a production outage.
    aud = payload.get("aud")
    audiences = aud if isinstance(aud, list) else [aud]
    if audience not in audiences:
        raise AppleIdentityError("token was not issued for this app")

    try:
        exp = float(payload["exp"])
        iat = float(payload["iat"])
    except (KeyError, TypeError, ValueError) as exc:
        raise AppleIdentityError("token has no usable exp/iat") from exc

    if exp <= now:
        raise AppleIdentityError("token has expired")
    if iat > now + MAX_CLOCK_SKEW_SECONDS:
        raise AppleIdentityError("token was issued in the future")
    if now - iat > MAX_TOKEN_AGE_SECONDS:
        raise AppleIdentityError("token is too old to present")

    # The nonce binds this token to one sign-in attempt. The client sets
    # `request.nonce` to the SHA-256 hex of a random value and sends the random value
    # here; Apple echoes the hash back unchanged in this claim.
    #
    # Compared with `compare_digest`: the comparison is over attacker-influenced input,
    # and while a timing oracle on a hex digest is a stretch, the constant-time version
    # costs nothing and removes the need to have that argument at all.
    claim_nonce = payload.get("nonce")
    if not isinstance(claim_nonce, str) or not claim_nonce:
        raise AppleIdentityError("token carries no nonce")
    computed = hashlib.sha256(expected_nonce.encode("utf-8")).hexdigest()
    if not hmac.compare_digest(claim_nonce, computed):
        raise AppleIdentityError("nonce does not match this sign-in attempt")

    subject = payload.get("sub")
    if not isinstance(subject, str) or not subject:
        raise AppleIdentityError("token carries no subject")

    return AppleIdentity(subject=subject, issued_at=iat, expires_at=exp)
