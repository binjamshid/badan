"""Accounts, cross-platform entitlements and referrals (ADR-0014 / D-44).

Real crypto for the identity token — a throwaway RSA key pair stands in for Apple's, and the
tokens below are genuinely signed and genuinely verified by `apple_identity.verify_identity_token`.
A stub would hide the two properties that matter most here: that a token minted for a
different `aud` is refused, and that a captured token cannot be replayed against a fresh nonce.

The load-bearing test is `test_the_accounts_schema_holds_no_health_column`. D-44 reversed
"no accounts"; it did not reverse "send no health data off device", and that test is what
keeps the second Never true when the first one stopped being.

Run:  python -m pytest backend/api/tests -q   (from the repo root)
"""

from __future__ import annotations

import base64
import hashlib
import importlib
import json
import sqlite3
import sys
import time

import accounts

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi.testclient import TestClient

AUDIENCE = "net.binjamshid.badan"
ISSUER = "https://appleid.apple.com"


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


@pytest.fixture(scope="module")
def apple_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="module")
def jwks(apple_key):
    numbers = apple_key.public_key().public_numbers()
    return [
        {
            "kty": "RSA",
            "kid": "test-key-1",
            "use": "sig",
            "alg": "RS256",
            "n": _b64url(numbers.n.to_bytes((numbers.n.bit_length() + 7) // 8, "big")),
            "e": _b64url(numbers.e.to_bytes((numbers.e.bit_length() + 7) // 8, "big")),
        }
    ]


def mint_token(
    apple_key,
    *,
    subject="000123.abcdef.0001",
    nonce="raw-nonce",
    audience=AUDIENCE,
    issuer=ISSUER,
    now=None,
    lifetime=600.0,
    alg="RS256",
    kid="test-key-1",
    hash_nonce=True,
) -> str:
    """Mint a token the way Apple would.

    `nonce` here is the RAW value the client generated; Apple echoes back the SHA-256 hex of
    what the client set on the request, which is what `hash_nonce` reproduces.
    """
    now = time.time() if now is None else now
    header = {"alg": alg, "kid": kid}
    claim_nonce = hashlib.sha256(nonce.encode()).hexdigest() if hash_nonce else nonce
    payload = {
        "iss": issuer,
        "aud": audience,
        "sub": subject,
        "iat": now,
        "exp": now + lifetime,
        "nonce": claim_nonce,
    }
    segments = [
        _b64url(json.dumps(header, separators=(",", ":")).encode()),
        _b64url(json.dumps(payload, separators=(",", ":")).encode()),
    ]
    signing_input = ".".join(segments).encode("ascii")
    signature = apple_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return ".".join(segments + [_b64url(signature)])


@pytest.fixture()
def api(tmp_path, monkeypatch, jwks):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")
    monkeypatch.setenv("BADAN_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("BADAN_ACCOUNT_HASH_SALT", "test-salt-not-production")
    monkeypatch.setenv("BADAN_ACCOUNT_SIGNIN_RATE_LIMIT_MAX", "1000")
    monkeypatch.setenv("BADAN_ACCOUNT_CLAIM_RATE_LIMIT_MAX", "1000")
    sys.modules.pop("main", None)
    main = importlib.import_module("main")

    async def _fake_jwks(*, force_refresh=False):
        return jwks

    # The only thing stubbed. Fetching Apple's real keys in a unit test would make the suite
    # depend on Apple's uptime to assert things that have nothing to do with it.
    monkeypatch.setattr(main, "_apple_jwks", _fake_jwks)
    return main


@pytest.fixture()
def client(api):
    return TestClient(api.app)


def _sign_in(client, apple_key, *, subject="000123.abcdef.0001", nonce="raw-nonce"):
    response = client.post(
        "/v1/account/apple",
        json={
            "identityToken": mint_token(apple_key, subject=subject, nonce=nonce),
            "nonce": nonce,
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


# --- sign-in ----------------------------------------------------------------


def test_a_first_sign_in_creates_an_account_with_a_referral_code(client, apple_key, api):
    body = _sign_in(client, apple_key)
    assert body["accountToken"]
    assert len(body["referralCode"]) == accounts.REFERRAL_CODE_LENGTH
    assert set(body["referralCode"]) <= set(accounts.REFERRAL_ALPHABET)
    assert body["entitlements"] == []
    assert body["hasClaimedReferral"] is False


def test_the_same_apple_subject_resolves_to_the_same_account(client, apple_key):
    first = _sign_in(client, apple_key, nonce="n1")
    second = _sign_in(client, apple_key, nonce="n2")
    assert first["accountId"] == second["accountId"]
    assert first["referralCode"] == second["referralCode"]
    # A new session each time, though — a token is issued once and never reused.
    assert first["accountToken"] != second["accountToken"]


def test_a_different_subject_gets_a_different_account(client, apple_key):
    first = _sign_in(client, apple_key, subject="000123.aaa.1", nonce="n1")
    second = _sign_in(client, apple_key, subject="000999.bbb.2", nonce="n2")
    assert first["accountId"] != second["accountId"]


def test_the_raw_apple_subject_is_never_stored(client, apple_key, tmp_path):
    subject = "000123.unmistakable-subject.0001"
    _sign_in(client, apple_key, subject=subject)
    blob = (tmp_path / "accounts.db").read_bytes()
    assert subject.encode() not in blob


@pytest.mark.parametrize(
    "kwargs",
    [
        {"audience": "com.someone.else"},
        {"issuer": "https://evil.example"},
        {"lifetime": -60.0},
        {"alg": "none"},
        {"kid": "not-a-key-we-know"},
        {"hash_nonce": False},
    ],
    ids=["wrong-aud", "wrong-iss", "expired", "alg-none", "unknown-kid", "raw-nonce-claim"],
)
def test_a_token_failing_any_check_is_refused(client, apple_key, kwargs):
    response = client.post(
        "/v1/account/apple",
        json={"identityToken": mint_token(apple_key, **kwargs), "nonce": "raw-nonce"},
    )
    assert response.status_code == 401


def test_a_captured_token_cannot_be_replayed_with_a_different_nonce(client, apple_key):
    token = mint_token(apple_key, nonce="the-original-nonce")
    response = client.post(
        "/v1/account/apple", json={"identityToken": token, "nonce": "a-different-nonce"}
    )
    assert response.status_code == 401


def test_the_refusal_reason_is_never_disclosed(client, apple_key):
    """Every failed check answers the same opaque 401. A caller who could tell WHICH check
    failed could tune a forgery against them one at a time."""
    bodies = set()
    for kwargs in ({"audience": "com.other"}, {"alg": "none"}, {"lifetime": -1.0}):
        response = client.post(
            "/v1/account/apple",
            json={"identityToken": mint_token(apple_key, **kwargs), "nonce": "raw-nonce"},
        )
        bodies.add(response.text)
    assert len(bodies) == 1


# --- entitlements -----------------------------------------------------------


def _entitlement(platform="ios", product="net.binjamshid.badan.pro.yearly", lifetime=False):
    return {
        "platform": platform,
        "productId": product,
        "isLifetime": lifetime,
        "expiresAt": None if lifetime else "2027-01-01T00:00:00Z",
        "observedAt": "2026-08-07T00:00:00Z",
    }


def test_an_entitlement_pushed_from_one_platform_is_readable_by_the_other(client, apple_key):
    token = _sign_in(client, apple_key)["accountToken"]
    pushed = client.put(
        "/v1/account/entitlement",
        json={"entitlements": [_entitlement(platform="android", product="badan_pro")]},
        headers=_auth(token),
    )
    assert pushed.status_code == 200, pushed.text

    read = client.get("/v1/account", headers=_auth(token)).json()
    assert len(read["entitlements"]) == 1
    assert read["entitlements"][0]["platform"] == "android"
    assert read["entitlements"][0]["productId"] == "badan_pro"


def test_a_push_may_not_describe_more_than_one_platform(client, apple_key):
    token = _sign_in(client, apple_key)["accountToken"]
    response = client.put(
        "/v1/account/entitlement",
        json={"entitlements": [_entitlement("ios"), _entitlement("android")]},
        headers=_auth(token),
    )
    assert response.status_code == 400


def test_clearing_a_platform_removes_only_that_platform(client, apple_key):
    token = _sign_in(client, apple_key)["accountToken"]
    client.put(
        "/v1/account/entitlement",
        json={"entitlements": [_entitlement("ios")]},
        headers=_auth(token),
    )
    client.put(
        "/v1/account/entitlement",
        json={"entitlements": [_entitlement("android", product="badan_pro")]},
        headers=_auth(token),
    )
    cleared = client.delete("/v1/account/entitlement/ios", headers=_auth(token)).json()
    assert [e["platform"] for e in cleared["entitlements"]] == ["android"]


def test_a_platform_reporting_again_replaces_rather_than_accumulates(client, apple_key):
    token = _sign_in(client, apple_key)["accountToken"]
    for product in ("net.binjamshid.badan.pro.monthly", "net.binjamshid.badan.pro.yearly"):
        client.put(
            "/v1/account/entitlement",
            json={"entitlements": [_entitlement(product=product)]},
            headers=_auth(token),
        )
    read = client.get("/v1/account", headers=_auth(token)).json()
    assert len(read["entitlements"]) == 1
    assert read["entitlements"][0]["productId"] == "net.binjamshid.badan.pro.yearly"


def test_an_unknown_platform_is_refused(client, apple_key):
    token = _sign_in(client, apple_key)["accountToken"]
    response = client.put(
        "/v1/account/entitlement",
        json={"entitlements": [_entitlement(platform="windows")]},
        headers=_auth(token),
    )
    assert response.status_code == 400


def test_every_account_route_requires_a_session(client):
    assert client.get("/v1/account").status_code == 401
    assert client.put("/v1/account/entitlement", json={"entitlements": []}).status_code == 401
    assert client.post("/v1/account/referral/claim", json={"code": "AAAAAAAA"}).status_code == 401
    assert client.delete("/v1/account").status_code == 401


# --- referrals --------------------------------------------------------------


def test_a_claim_grants_premium_time_to_both_sides(client, apple_key, api):
    referrer = _sign_in(client, apple_key, subject="ref.1", nonce="n1")
    referee = _sign_in(client, apple_key, subject="ref.2", nonce="n2")

    claimed = client.post(
        "/v1/account/referral/claim",
        json={"code": referrer["referralCode"]},
        headers=_auth(referee["accountToken"]),
    )
    assert claimed.status_code == 200, claimed.text
    assert claimed.json()["hasClaimedReferral"] is True
    assert claimed.json()["referralGrantExpiresAt"] is not None

    back = client.get("/v1/account", headers=_auth(referrer["accountToken"])).json()
    assert back["successfulReferrals"] == 1
    assert back["referralGrantExpiresAt"] is not None


def test_a_code_cannot_be_claimed_twice_by_the_same_account(client, apple_key):
    a = _sign_in(client, apple_key, subject="ref.a", nonce="n1")
    b = _sign_in(client, apple_key, subject="ref.b", nonce="n2")
    c = _sign_in(client, apple_key, subject="ref.c", nonce="n3")

    first = client.post(
        "/v1/account/referral/claim",
        json={"code": a["referralCode"]},
        headers=_auth(c["accountToken"]),
    )
    assert first.status_code == 200
    second = client.post(
        "/v1/account/referral/claim",
        json={"code": b["referralCode"]},
        headers=_auth(c["accountToken"]),
    )
    assert second.status_code == 409
    assert second.json()["detail"]["reason"] == "already_claimed"


def test_an_account_cannot_claim_its_own_code(client, apple_key):
    me = _sign_in(client, apple_key)
    response = client.post(
        "/v1/account/referral/claim",
        json={"code": me["referralCode"]},
        headers=_auth(me["accountToken"]),
    )
    assert response.status_code == 409
    assert response.json()["detail"]["reason"] == "own_code"


def test_an_unknown_code_reveals_nothing_about_whether_it_exists(client, apple_key):
    me = _sign_in(client, apple_key)
    response = client.post(
        "/v1/account/referral/claim",
        json={"code": "22222222"},
        headers=_auth(me["accountToken"]),
    )
    assert response.status_code == 409
    assert response.json()["detail"] == {"reason": "unknown_code"}


def test_the_claim_window_closes(client, apple_key, api, tmp_path):
    referrer = _sign_in(client, apple_key, subject="ref.old.1", nonce="n1")
    referee = _sign_in(client, apple_key, subject="ref.old.2", nonce="n2")

    # Age the referee's account past the window by editing the row directly — the alternative
    # is threading a clock through the whole store for one assertion.
    old = time.time() - (accounts.REFERRAL_CLAIM_WINDOW_DAYS + 1) * 86_400
    with sqlite3.connect(tmp_path / "accounts.db") as conn:
        conn.execute(
            "UPDATE accounts SET created_at = ? WHERE account_id = ?;",
            (old, referee["accountId"]),
        )
        conn.commit()

    response = client.post(
        "/v1/account/referral/claim",
        json={"code": referrer["referralCode"]},
        headers=_auth(referee["accountToken"]),
    )
    assert response.status_code == 409
    assert response.json()["detail"]["reason"] == "window_closed"


def test_the_referrer_reward_is_capped_but_the_claim_still_lands(client, apple_key, api, tmp_path):
    referrer = _sign_in(client, apple_key, subject="ref.cap", nonce="n0")
    with sqlite3.connect(tmp_path / "accounts.db") as conn:
        conn.execute(
            "UPDATE accounts SET rewarded_referrals = ? WHERE account_id = ?;",
            (accounts.REFERRAL_MAX_REWARDED, referrer["accountId"]),
        )
        conn.commit()

    newcomer = _sign_in(client, apple_key, subject="ref.new", nonce="n1")
    claimed = client.post(
        "/v1/account/referral/claim",
        json={"code": referrer["referralCode"]},
        headers=_auth(newcomer["accountToken"]),
    )
    # The newcomer is not punished for the popularity of whoever invited them.
    assert claimed.status_code == 200
    assert claimed.json()["referralGrantExpiresAt"] is not None

    back = client.get("/v1/account", headers=_auth(referrer["accountToken"])).json()
    assert back["successfulReferrals"] == accounts.REFERRAL_MAX_REWARDED


def test_a_claim_is_case_and_punctuation_insensitive(client, apple_key):
    referrer = _sign_in(client, apple_key, subject="ref.fmt.1", nonce="n1")
    referee = _sign_in(client, apple_key, subject="ref.fmt.2", nonce="n2")
    code = referrer["referralCode"]
    messy = f"{code[:4].lower()}-{code[4:].lower()}"
    response = client.post(
        "/v1/account/referral/claim",
        json={"code": messy},
        headers=_auth(referee["accountToken"]),
    )
    assert response.status_code == 200


# --- deletion ---------------------------------------------------------------


def test_deleting_an_account_removes_every_trace_of_it(client, apple_key, tmp_path):
    account = _sign_in(client, apple_key)
    client.put(
        "/v1/account/entitlement",
        json={"entitlements": [_entitlement()]},
        headers=_auth(account["accountToken"]),
    )
    assert client.delete("/v1/account", headers=_auth(account["accountToken"])).status_code == 200

    with sqlite3.connect(tmp_path / "accounts.db") as conn:
        for table in ("accounts", "account_sessions", "account_entitlements"):
            rows = conn.execute(
                f"SELECT COUNT(*) FROM {table} WHERE account_id = ?;",
                (account["accountId"],),
            ).fetchone()[0]
            assert rows == 0, table

    # The session is dead immediately, not at some later expiry.
    assert client.get("/v1/account", headers=_auth(account["accountToken"])).status_code == 401


def test_deleting_an_account_does_not_revoke_a_grant_it_gave_someone_else(client, apple_key):
    referrer = _sign_in(client, apple_key, subject="del.1", nonce="n1")
    referee = _sign_in(client, apple_key, subject="del.2", nonce="n2")
    client.post(
        "/v1/account/referral/claim",
        json={"code": referrer["referralCode"]},
        headers=_auth(referee["accountToken"]),
    )
    client.delete("/v1/account", headers=_auth(referrer["accountToken"]))

    still_there = client.get("/v1/account", headers=_auth(referee["accountToken"])).json()
    assert still_there["referralGrantExpiresAt"] is not None


def test_signing_in_again_after_deletion_creates_a_fresh_account(client, apple_key):
    first = _sign_in(client, apple_key, nonce="n1")
    client.delete("/v1/account", headers=_auth(first["accountToken"]))
    second = _sign_in(client, apple_key, nonce="n2")
    assert second["accountId"] != first["accountId"]


# --- the boundary that survived D-44 ----------------------------------------


def test_the_accounts_schema_holds_no_health_column(client, apple_key, tmp_path):
    """D-44 reversed "no accounts". It did NOT reverse "send no health data off device".

    This pins every column in every account table. A migration that adds a reading, a score,
    a metric id, a date that says something about a body, or anything else health-shaped
    fails here — which is the point: the second Never has to be enforced by something now
    that the first one is gone.
    """
    _sign_in(client, apple_key)
    expected = {
        "accounts": {
            "account_id",
            "subject_hash",
            "created_at",
            "referral_code",
            "referred_by",
            "claimed_at",
            "rewarded_referrals",
            "referral_grant_expires_at",
        },
        "account_sessions": {"token_hash", "account_id", "issued_at"},
        "account_entitlements": {
            "account_id",
            "platform",
            "product_id",
            "is_lifetime",
            "expires_at",
            "observed_at",
        },
    }
    with sqlite3.connect(tmp_path / "accounts.db") as conn:
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name NOT LIKE 'sqlite_%';"
            )
        }
        assert tables == set(expected), tables
        for table, columns in expected.items():
            actual = {row[1] for row in conn.execute(f"PRAGMA table_info({table});")}
            assert actual == columns, f"{table}: {actual ^ columns}"


def test_the_response_body_holds_no_health_field(client, apple_key):
    """The wire shape, pinned from the other end. `_account_response` builds this field by
    field precisely so a new column cannot reach a client without someone editing it."""
    body = _sign_in(client, apple_key)
    assert set(body) == {
        "accountId",
        "createdAt",
        "referralCode",
        "successfulReferrals",
        "hasClaimedReferral",
        "referralGrantExpiresAt",
        "entitlements",
        "accountToken",
    }


def test_no_account_route_logs_a_body(client, apple_key, caplog):
    """G8 holds on the account routes too, and matters more here than anywhere else: these
    are the only bodies in this service that carry an identifier."""
    import logging

    with caplog.at_level(logging.INFO):
        account = _sign_in(client, apple_key, subject="log.probe.subject")
        client.put(
            "/v1/account/entitlement",
            json={"entitlements": [_entitlement()]},
            headers=_auth(account["accountToken"]),
        )
    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert "log.probe.subject" not in logged
    assert account["accountToken"] not in logged
    assert account["accountId"] not in logged
    assert account["referralCode"] not in logged
