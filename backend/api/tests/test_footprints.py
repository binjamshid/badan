"""Endpoint tests for `POST /v1/footprints` (ADR-0011 / D-37).

Real crypto throughout — `_build_assertion` from `test_appattest` produces a genuine
assertion over the throwaway CA — because the interesting properties here are exactly the
ones a stub would hide: that a replayed assertion is rejected, and that a key which
verified successfully still leaves no trace beside the payload.

The two load-bearing tests are `test_footprints_table_has_no_identifier_column` and
`test_a_verified_key_id_is_never_written_beside_the_payload`. ADR-0011 is explicit that the
non-join is a CODE boundary, not cryptographic unlinkability — the server does learn a key
id at verification time. These are what make that boundary real.

Run:  python -m pytest backend/api/tests -q   (from the repo root)
"""

from __future__ import annotations

import base64
import importlib
import logging
import sqlite3
import sys

import pytest
from fastapi.testclient import TestClient

from test_appattest import APP_ID, _build_assertion, build_attestation
from test_register_attested import _issued_challenge, _register


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")
    monkeypatch.setenv("BADAN_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("BADAN_ATTEST_ENVIRONMENTS", "production")
    monkeypatch.setenv("BADAN_REGISTER_RATE_LIMIT_MAX", "1000")
    monkeypatch.setenv("BADAN_GLOBAL_REGISTER_RATE_LIMIT_MAX", "1000")
    monkeypatch.setenv("BADAN_FOOTPRINT_RATE_LIMIT_MAX", "1000")
    sys.modules.pop("main", None)
    main = importlib.import_module("main")
    main.ATTEST_APP_ID = APP_ID
    return main


def _attested_key(api, client):
    """Register a key so it exists in `attested_keys`, and return it with its signing key."""
    challenge = _issued_challenge(client)
    attestation, key_id, root_pem, leaf_key = build_attestation(challenge=challenge)
    response = _register(client, api, root_pem=root_pem, key_id=key_id,
                         attestation=attestation, challenge=challenge)
    assert response.status_code == 200
    return key_id, leaf_key


def _payload(key_id, leaf_key, *, counter=1, footprints=None, client_data=b"batch", **overrides):
    body = {
        "schemaVersion": 1,
        "appVersion": "1.1",
        "contractVersion": "0.2.0",
        "footprints": footprints if footprints is not None else [
            {
                "metricId": "readiness.score",
                "algorithmId": "composite.readiness_score",
                "algorithmSemver": "2.0.0",
                "direction": "over",
                "eventCountBucket": "10-19",
                "calibrationApplied": True,
            }
        ],
        "keyId": base64.b64encode(key_id).decode(),
        "assertion": base64.b64encode(
            _build_assertion(leaf_key, counter=counter, client_data=client_data)
        ).decode(),
        "clientData": base64.b64encode(client_data).decode(),
    }
    body.update(overrides)
    return body


def _rows(api):
    conn = sqlite3.connect(api.FOOTPRINTS_DB_PATH)
    try:
        return conn.execute("SELECT * FROM footprints;").fetchall()
    finally:
        conn.close()


# --- The happy path ---------------------------------------------------------


def test_a_genuine_app_instance_can_submit_footprints(api):
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)

    response = client.post("/v1/footprints", json=_payload(key_id, leaf_key))

    assert response.status_code == 200
    assert response.json()["accepted"] == 1
    assert len(_rows(api)) == 1


# --- The boundary -----------------------------------------------------------


def test_footprints_table_has_no_identifier_column(api):
    """The non-join, enforced by the SCHEMA rather than by the query layer.

    ADR-0011 carries no install or device identifier. Adding one here would be the join the
    decision exists to prevent, so the absence is asserted against the column list rather
    than trusted to whoever writes the next INSERT.
    """
    conn = sqlite3.connect(api.FOOTPRINTS_DB_PATH)
    try:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(footprints);")}
    finally:
        conn.close()

    for forbidden in ("key_id", "token_hash", "device_id", "install_id", "ip", "user_id",
                      "received_at", "locale", "region", "timezone"):
        assert forbidden not in columns, (
            f"{forbidden} is a column on footprints. ADR-0011 carries no identifier, and "
            f"received_at specifically is excluded because a precise receive time is itself "
            f"a weak identifier — received_day is a date."
        )


def test_a_verified_key_id_is_never_written_beside_the_payload(api):
    """The key id IS learned at verification time — that is stated in ADR-0011 rather than
    denied. This asserts the boundary that follows from it: none of the stored values is
    the key, in any encoding."""
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    assert client.post("/v1/footprints", json=_payload(key_id, leaf_key)).status_code == 200

    stored = " ".join(str(value) for row in _rows(api) for value in row)
    for encoding in (key_id.hex(), base64.b64encode(key_id).decode(), str(key_id)):
        assert encoding not in stored, "the attestation key reached the footprint row"


def test_footprints_live_in_their_own_database_file(api):
    """Separate SQLite file so footprints and device tokens are not joinable in one query,
    and a compromise of one is not a compromise of the other."""
    assert api.FOOTPRINTS_DB_PATH != api.TOKENS_DB_PATH

    conn = sqlite3.connect(api.FOOTPRINTS_DB_PATH)
    try:
        tables = {row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table';")}
    finally:
        conn.close()
    assert "device_tokens" not in tables
    assert "attested_keys" not in tables


def test_received_day_is_a_date_not_a_timestamp(api):
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    client.post("/v1/footprints", json=_payload(key_id, leaf_key))

    conn = sqlite3.connect(api.FOOTPRINTS_DB_PATH)
    try:
        day = conn.execute("SELECT received_day FROM footprints;").fetchone()[0]
    finally:
        conn.close()
    assert len(day) == 10 and day.count("-") == 2, (
        f"received_day={day!r} — a precise receive time is a weak identifier, so this is "
        f"stored at day granularity only"
    )


# --- The closed schema ------------------------------------------------------


def test_footprint_payload_rejects_unknown_fields(api):
    """`additionalProperties: false` on the contract, `extra="forbid"` here. An unknown
    field must be a rejected request, not an ignored one — otherwise a future client could
    widen the payload silently, which is the whole failure mode the closed schema prevents."""
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)

    body = _payload(key_id, leaf_key)
    body["footprints"][0]["readingValue"] = 72
    assert client.post("/v1/footprints", json=body).status_code == 422

    body = _payload(key_id, leaf_key, counter=2)
    body["periodKey"] = "day:2026-07-14"
    assert client.post("/v1/footprints", json=body).status_code == 422


@pytest.mark.parametrize("field,value", [
    ("direction", "felt_terrible"),
    ("eventCountBucket", "1-9"),
    ("eventCountBucket", "3"),
])
def test_closed_enums_reject_values_outside_the_decision(api, field, value):
    """A bucket of "3" is the case worth naming: below 10 nothing may be sent at all,
    because a count of 1 would re-identify a single tap."""
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    body = _payload(key_id, leaf_key)
    body["footprints"][0][field] = value

    assert client.post("/v1/footprints", json=body).status_code in (400, 422)


def test_an_unsupported_schema_version_is_rejected(api):
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    assert client.post(
        "/v1/footprints", json=_payload(key_id, leaf_key, schemaVersion=99)
    ).status_code == 400


# --- Attestation ------------------------------------------------------------


def test_an_unknown_key_is_rejected(api):
    client = TestClient(api.app)
    _, leaf_key = _attested_key(api, client)
    assert client.post(
        "/v1/footprints", json=_payload(b"\x01" * 32, leaf_key)
    ).status_code == 401


def test_a_replayed_assertion_is_rejected(api):
    """The counter must strictly increase. Without this, one captured submission could be
    replayed indefinitely — which for an endpoint carrying no identifier would be
    indistinguishable from many real users."""
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)

    assert client.post("/v1/footprints", json=_payload(key_id, leaf_key, counter=1)).status_code == 200
    assert client.post("/v1/footprints", json=_payload(key_id, leaf_key, counter=1)).status_code == 401
    # A genuinely advancing counter still works.
    assert client.post("/v1/footprints", json=_payload(key_id, leaf_key, counter=2)).status_code == 200


def test_an_assertion_over_different_client_data_is_rejected(api):
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    body = _payload(key_id, leaf_key, client_data=b"batch")
    body["clientData"] = base64.b64encode(b"a different batch").decode()

    assert client.post("/v1/footprints", json=body).status_code == 401


# --- Retention and G8 -------------------------------------------------------


def test_retention_prunes_on_write(api):
    """Pruning on write rather than on a schedule keeps retention a property of the store
    instead of a cron job someone can forget to install."""
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    assert client.post("/v1/footprints", json=_payload(key_id, leaf_key, counter=1)).status_code == 200

    # Backdate the stored row past the retention horizon.
    conn = sqlite3.connect(api.FOOTPRINTS_DB_PATH)
    try:
        conn.execute("UPDATE footprints SET received_day = '2000-01-01';")
        conn.commit()
    finally:
        conn.close()

    assert client.post("/v1/footprints", json=_payload(key_id, leaf_key, counter=2)).status_code == 200
    days = {row[1] for row in _rows(api)}
    assert "2000-01-01" not in days, "a row past retention survived a write"


def test_footprint_payload_never_reaches_the_log(api, caplog):
    """G8: no request bodies in logs, and a footprint batch is a request body.

    The assertion blob and the metric/method identifiers must both stay out — the first
    because it is caller-supplied content, the second because a log line naming which
    method a user disagreed with, next to a request id, is a richer record than the store.
    """
    client = TestClient(api.app)
    key_id, leaf_key = _attested_key(api, client)
    body = _payload(key_id, leaf_key)

    with caplog.at_level(logging.DEBUG):
        assert client.post("/v1/footprints", json=body).status_code == 200

    logged = " ".join(record.getMessage() for record in caplog.records)
    for forbidden in (body["assertion"], body["clientData"], body["keyId"],
                      "readiness.score", "composite.readiness_score"):
        assert forbidden not in logged, f"{forbidden[:32]!r} reached the log"
