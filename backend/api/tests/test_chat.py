"""Endpoint tests for `POST /v1/chat` — the OpenRouter proxy half of A9 / ADR-0010.

No socket is opened: `httpx.AsyncClient` is replaced for the duration of each test, which is
also what lets the request BADAN sends upstream be inspected. That request is the subject of
half of these tests — what this service asks OpenRouter for is a cost decision, not an
implementation detail.

Run:  python -m pytest tests/ -v   (from backend/api)
"""

from __future__ import annotations

import importlib
import logging
import sys

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")
    monkeypatch.setenv("BADAN_DATA_DIR", str(tmp_path))
    sys.modules.pop("main", None)
    return importlib.import_module("main")


def _stub_openrouter(api, monkeypatch, *, status=200, body=None, json_raises=None):
    """Stand in for OpenRouter and record every payload this service sends it."""
    sent: list[dict] = []

    class _Response:
        status_code = status

        def json(self):
            if json_raises is not None:
                raise json_raises
            return body

    class _Client:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc_info):
            return False

        async def post(self, url, json=None, headers=None):
            sent.append(json)
            return _Response()

    monkeypatch.setattr(api.httpx, "AsyncClient", _Client)
    return sent


def _authorized(api):
    """A client plus a genuinely issued bearer token. `/v1/chat` checks the token against the
    store, so a made-up string would only ever exercise the 401 path."""
    client = TestClient(api.app, raise_server_exceptions=False)
    token = client.post("/v1/register").json()["token"]
    return client, {"Authorization": f"Bearer {token}"}


def _ask(client, headers):
    return client.post(
        "/v1/chat",
        headers=headers,
        json={"messages": [{"role": "user", "content": "how did I sleep?"}]},
    )


# --- The happy path ---------------------------------------------------------


def test_a_completion_is_returned_to_the_caller(api, monkeypatch):
    _stub_openrouter(api, monkeypatch, body={"choices": [{"message": {"content": "hello"}}]})
    client, headers = _authorized(api)

    response = _ask(client, headers)

    assert response.status_code == 200
    assert response.json() == {"reply": "hello"}


# --- The cost ceiling -------------------------------------------------------


def test_the_upstream_request_carries_a_max_tokens_ceiling(api, monkeypatch):
    """`ChatMessage.content` bounds what one request can cost on the way IN. Without
    `max_tokens` the model decided how much it cost on the way OUT, so a request sitting
    comfortably inside the per-token rate-limit budget could still bill for the provider's
    maximum completion — the cost control was only half installed."""
    sent = _stub_openrouter(api, monkeypatch, body={"choices": [{"message": {"content": "hi"}}]})
    client, headers = _authorized(api)

    assert _ask(client, headers).status_code == 200

    assert sent[0]["max_tokens"] == api.CHAT_MAX_TOKENS
    assert api.CHAT_MAX_TOKENS > 0


def test_the_ceiling_is_configurable(api, monkeypatch):
    """A ceiling that suits a cheap model is not the one that suits an expensive one, so the
    operator sets it — the handler must read the constant, not inline a literal."""
    monkeypatch.setattr(api, "CHAT_MAX_TOKENS", 123)
    sent = _stub_openrouter(api, monkeypatch, body={"choices": [{"message": {"content": "hi"}}]})
    client, headers = _authorized(api)

    assert _ask(client, headers).status_code == 200
    assert sent[0]["max_tokens"] == 123


def test_the_ceiling_default_comes_from_the_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")
    monkeypatch.setenv("BADAN_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("BADAN_CHAT_MAX_TOKENS", "1500")
    sys.modules.pop("main", None)
    assert importlib.import_module("main").CHAT_MAX_TOKENS == 1500


# --- A 200 that is not the shape we asked for -------------------------------


@pytest.mark.parametrize("body", [
    {},                                              # no choices at all
    {"choices": []},                                 # truncated / filtered response
    {"choices": [{}]},                               # a choice with no message
    {"choices": [{"message": {}}]},                  # a message with no content
    {"choices": [{"message": {"content": None}}]},   # content present but null
    {"choices": [{"message": {"content": 7}}]},      # content present but not text
    {"choices": "not a list"},                       # wrong type entirely
])
def test_a_malformed_upstream_200_is_a_bad_gateway_not_a_crash(api, monkeypatch, body):
    """Indexing straight into the body turned any of these into a KeyError / IndexError /
    TypeError, i.e. a 500 — this service blaming itself for the provider's fault, and handing
    the client the one status that means "retrying will not help" for a condition where
    retrying is exactly right."""
    _stub_openrouter(api, monkeypatch, body=body)
    client, headers = _authorized(api)

    assert _ask(client, headers).status_code == 502


def test_a_non_json_upstream_200_is_a_bad_gateway(api, monkeypatch):
    """An HTML error page from a proxy in front of OpenRouter arrives as a 200 whose body
    does not parse. Same fault, same answer."""
    _stub_openrouter(api, monkeypatch, json_raises=ValueError("not json"))
    client, headers = _authorized(api)

    assert _ask(client, headers).status_code == 502


def test_a_malformed_upstream_body_never_reaches_the_log(api, monkeypatch, caplog):
    """G8: no bodies in logs. A malformed response is exactly the moment someone reaches for
    "just log it to see what came back", so the test is here rather than in review."""
    _stub_openrouter(
        api, monkeypatch,
        body={"choices": [{"message": {"content_typo": "a private-looking completion"}}]},
    )
    client, headers = _authorized(api)

    with caplog.at_level(logging.DEBUG):
        assert _ask(client, headers).status_code == 502

    logged = " ".join(record.getMessage() for record in caplog.records)
    assert "a private-looking completion" not in logged
    assert "content_typo" not in logged


def test_an_upstream_error_status_is_still_a_bad_gateway(api, monkeypatch):
    _stub_openrouter(api, monkeypatch, status=500, body={"error": "boom"})
    client, headers = _authorized(api)

    assert _ask(client, headers).status_code == 502
