"""Endpoint tests for the attested registration flow in `main.py`.

Uses the same synthetic-chain builder as `test_appattest.py`, with the module's
`ATTEST_APP_ID` / root pin monkeypatched to the throwaway CA — the crypto itself is
covered there; what is covered HERE is the wiring around it: challenge single-use,
ordering of consume-before-verify, the per-key token budget, the legacy switch, and
that nothing leaks into the log.

Run:  python -m pytest backend/api/tests -q   (from the repo root)
"""

from __future__ import annotations

import base64
import importlib
import os
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from test_appattest import APP_ID, NOW, _self_signed_ca, build_attestation


def monkeypatch_budget(main, limit: int) -> None:
    """`AttestedKeyStore.record_issue` reads `MAX_TOKENS_PER_KEY` from module globals at
    call time, so rebinding it on the module is enough — no need to rebuild the store."""
    main.MAX_TOKENS_PER_KEY = limit


@pytest.fixture()
def api(tmp_path, monkeypatch):
    """Import `main` with a throwaway data dir and no real OpenRouter key.

    Re-imported per test because the module reads its configuration at import time and
    holds the SQLite path, the challenge store and the rate limiters as module globals —
    a shared instance would leak counter state between tests.
    """
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")
    monkeypatch.setenv("BADAN_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("BADAN_ATTEST_ENVIRONMENTS", "production")
    monkeypatch.setenv("BADAN_REGISTER_RATE_LIMIT_MAX", "1000")
    monkeypatch.setenv("BADAN_GLOBAL_REGISTER_RATE_LIMIT_MAX", "1000")
    sys.modules.pop("main", None)
    main = importlib.import_module("main")
    return main


def _register(client, main, *, root_pem, key_id, attestation, challenge):
    monkeypatched_verify = main.verify_attestation

    def verify_with_test_root(**kwargs):
        # Use the clock that issued the synthetic certificates so their validity is deterministic.
        return monkeypatched_verify(root_ca_pem=root_pem, now=NOW, **kwargs)

    main.verify_attestation = verify_with_test_root
    try:
        return client.post(
            "/v2/register",
            json={
                "key_id": base64.b64encode(key_id).decode(),
                "challenge": base64.b64encode(challenge).decode(),
                "attestation": base64.b64encode(attestation).decode(),
            },
        )
    finally:
        main.verify_attestation = monkeypatched_verify


def _issued_challenge(client) -> bytes:
    response = client.post("/v1/attest/challenge")
    assert response.status_code == 200
    return base64.b64decode(response.json()["challenge"])


def test_attested_registration_issues_a_token(api):
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    challenge = _issued_challenge(client)
    attestation, key_id, root_pem, _ = build_attestation(challenge=challenge)

    response = _register(
        client, api, root_pem=root_pem, key_id=key_id, attestation=attestation, challenge=challenge
    )
    assert response.status_code == 200
    assert response.json()["token"]


def test_challenge_is_single_use(api):
    """The same challenge must not verify twice, even with a genuine attestation —
    otherwise a captured blob replays forever."""
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    challenge = _issued_challenge(client)
    attestation, key_id, root_pem, _ = build_attestation(challenge=challenge)

    first = _register(
        client, api, root_pem=root_pem, key_id=key_id, attestation=attestation, challenge=challenge
    )
    second = _register(
        client, api, root_pem=root_pem, key_id=key_id, attestation=attestation, challenge=challenge
    )
    assert first.status_code == 200
    assert second.status_code == 401


def test_unknown_challenge_is_rejected(api):
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    attestation, key_id, root_pem, _ = build_attestation(challenge=b"never issued by us")
    response = _register(
        client,
        api,
        root_pem=root_pem,
        key_id=key_id,
        attestation=attestation,
        challenge=b"never issued by us",
    )
    assert response.status_code == 401


def test_failed_verification_still_burns_the_challenge(api):
    """Consume-before-verify: a failed attempt must not leave the challenge outstanding
    for unlimited retries."""
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    challenge = _issued_challenge(client)
    # Attestation built for a DIFFERENT challenge — verification fails.
    attestation, key_id, root_pem, _ = build_attestation(challenge=b"wrong")

    first = _register(
        client, api, root_pem=root_pem, key_id=key_id, attestation=attestation, challenge=challenge
    )
    assert first.status_code == 401

    good_attestation, good_key_id, good_root, _ = build_attestation(challenge=challenge)
    second = _register(
        client,
        api,
        root_pem=good_root,
        key_id=good_key_id,
        attestation=good_attestation,
        challenge=challenge,
    )
    assert second.status_code == 401  # the challenge is gone, even though this blob is valid


def test_per_key_token_budget_is_enforced(api):
    """One genuine device may re-enable the coach a few times; it may not mint tokens
    without limit. Every request here is a VALID attestation from the same key — the only
    thing stopping the third is the budget."""
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    monkeypatch_budget(api, 2)

    shared_key = ec.generate_private_key(ec.SECP256R1())
    shared_root = _self_signed_ca()

    statuses = []
    for _ in range(3):
        challenge = _issued_challenge(client)
        attestation, key_id, root_pem, _ = build_attestation(
            challenge=challenge, leaf_key=shared_key, root=shared_root
        )
        statuses.append(
            _register(
                client,
                api,
                root_pem=root_pem,
                key_id=key_id,
                attestation=attestation,
                challenge=challenge,
            ).status_code
        )
    assert statuses == [200, 200, 429]


def test_distinct_keys_have_independent_budgets(api):
    """The budget must be per install, not global — otherwise a handful of legitimate
    devices would lock everyone else out."""
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    monkeypatch_budget(api, 1)

    statuses = []
    for _ in range(3):
        challenge = _issued_challenge(client)
        attestation, key_id, root_pem, _ = build_attestation(challenge=challenge)
        statuses.append(
            _register(
                client,
                api,
                root_pem=root_pem,
                key_id=key_id,
                attestation=attestation,
                challenge=challenge,
            ).status_code
        )
    assert statuses == [200, 200, 200]


def test_malformed_base64_is_unauthorized_not_a_crash(api):
    client = TestClient(api.app)
    response = client.post(
        "/v2/register",
        json={"key_id": "!!!not base64!!!", "challenge": "AAAA", "attestation": "AAAA"},
    )
    assert response.status_code == 401


def test_oversized_attestation_is_rejected_by_the_schema(api):
    client = TestClient(api.app)
    response = client.post(
        "/v2/register",
        json={"key_id": "AAAA", "challenge": "AAAA", "attestation": "A" * 40_000},
    )
    assert response.status_code == 422


def test_legacy_register_still_works_by_default(api):
    """Deploying this must not break installs already in the wild."""
    client = TestClient(api.app)
    response = client.post("/v1/register")
    assert response.status_code == 200
    assert response.json()["token"]


def test_legacy_register_can_be_retired(api, monkeypatch):
    """And the flag must actually close it — this is the step that finishes the job."""
    monkeypatch.setattr(api, "LEGACY_REGISTER_ENABLED", False)
    client = TestClient(api.app)
    assert client.post("/v1/register").status_code == 410


def test_attestation_blob_never_reaches_the_log(api, caplog):
    """G8: no request bodies in logs, and an attestation is a request body."""
    client = TestClient(api.app)
    api.ATTEST_APP_ID = APP_ID
    challenge = _issued_challenge(client)
    attestation, key_id, root_pem, _ = build_attestation(challenge=b"wrong")
    with caplog.at_level("DEBUG"):
        _register(
            client,
            api,
            root_pem=root_pem,
            key_id=key_id,
            attestation=attestation,
            challenge=challenge,
        )
    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert base64.b64encode(attestation).decode()[:32] not in logged
    assert key_id.hex() not in logged
