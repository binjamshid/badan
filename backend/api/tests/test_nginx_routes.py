"""`infra/nginx/badan-api.conf` must route every endpoint `main.py` defines.

Each server block in that vhost ends in `location / { return 404; }`, which makes the file an
ALLOWLIST rather than a passthrough. An endpoint that exists in `main.py` but has no matching
location is unreachable in production and fails at the edge — the request never reaches
uvicorn, so nothing in this service's own logs, metrics or tests records that it happened. It
is the one class of defect the rest of this suite is structurally blind to, because every
other test here talks to `app` directly.

That is not hypothetical. App Attest shipped with `POST /v2/register` as the iOS client's ONLY
registration path (`AICoachClient.swift`, no fallback to `/v1/register`) against a vhost that
matched only `= /v1/register`, so every opt-in 404'd at nginx and attestation never engaged in
production once.

This is a text check, not a check against a running nginx: the conf is parsed here rather than
loaded. It catches a route that was never added, which is the failure that happened; it cannot
catch a conf that is syntactically invalid or deployed but not reloaded.

Run:  python -m pytest tests/ -v   (from backend/api)
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
NGINX_CONF = REPO_ROOT / "infra" / "nginx" / "badan-api.conf"
MAIN_PY = REPO_ROOT / "backend" / "api" / "main.py"

# `location [modifier] pattern {`
_LOCATION_RE = re.compile(r"^[ \t]*location[ \t]+(=|~\*|~|\^~)?[ \t]*(\S+)[ \t]*\{", re.M)
_ROUTE_RE = re.compile(r"^@app\.(?:get|post|put|patch|delete)\(\"([^\"]+)\"\)", re.M)


def _block_body(text: str, brace_index: int) -> str:
    """The text between `text[brace_index]` (an opening brace) and its match."""
    depth = 0
    for i in range(brace_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace_index + 1:i]
    raise AssertionError("unbalanced braces in the vhost")


def _server_blocks(conf: str) -> list[str]:
    return [
        _block_body(conf, match.end() - 1)
        for match in re.finditer(r"^server[ \t]*\{", conf, re.M)
    ]


def _locations(block: str) -> list[tuple[str, str, str]]:
    """(modifier, pattern, body) for each location in one server block."""
    out = []
    for match in _LOCATION_RE.finditer(block):
        out.append((match.group(1) or "", match.group(2), _block_body(block, match.end() - 1)))
    return out


def _matching_location(locations, path: str):
    """The location nginx would pick for `path`, ignoring the `/` catch-all.

    Not a full implementation of nginx's matching order — it does not need to be. Exact
    matches win, then regexes, then the longest prefix, and the only question asked here is
    whether SOMETHING other than the 404 catch-all claims the path.
    """
    for modifier, pattern, body in locations:
        if modifier == "=" and pattern == path:
            return (modifier, pattern, body)
    for modifier, pattern, body in locations:
        if modifier in ("~", "~*") and re.search(pattern, path):
            return (modifier, pattern, body)
    prefixes = [
        (modifier, pattern, body)
        for modifier, pattern, body in locations
        if modifier in ("", "^~") and pattern != "/" and path.startswith(pattern)
    ]
    if prefixes:
        return max(prefixes, key=lambda item: len(item[1]))
    return None


@pytest.fixture(scope="module")
def blocks() -> list[str]:
    parsed = _server_blocks(NGINX_CONF.read_text())
    # :80 (certbot's HTTP-01 challenges) and :443 (what Cloudflare actually connects to,
    # the zone being in Full mode). A route present in only one of them is half-deployed.
    assert len(parsed) == 2, f"expected the :80 and :443 blocks, found {len(parsed)}"
    return parsed


@pytest.fixture(scope="module")
def routes() -> list[str]:
    found = sorted(set(_ROUTE_RE.findall(MAIN_PY.read_text())))
    assert "/v2/register" in found, "main.py no longer defines /v2/register — check this test"
    return found


def test_every_endpoint_is_routed_by_both_server_blocks(blocks, routes):
    for index, block in enumerate(blocks):
        locations = _locations(block)
        for route in routes:
            assert _matching_location(locations, route) is not None, (
                f"{route} is defined in main.py but no location in server block {index} "
                f"claims it, so it falls to `location / {{ return 404; }}` and 404s at the "
                f"edge. Add it to BOTH blocks."
            )


def test_the_two_server_blocks_route_the_same_set(blocks):
    """The :80 and :443 blocks are maintained by hand and must not drift: :443 is the one
    Cloudflare uses, :80 is the one certbot renews through, and a route in only one of them
    works exactly until the next thing changes."""
    assert [(m, p) for m, p, _ in _locations(blocks[0])] == \
           [(m, p) for m, p, _ in _locations(blocks[1])]


@pytest.mark.parametrize("path", ["/v1/register", "/v2/register", "/v1/attest/challenge"])
def test_the_registration_flow_uses_the_registration_budget(blocks, path):
    """Token minting is the expensive thing to leave cheap. `/v1/attest/challenge` did reach
    the service before, but through the loose `/v1/` chat prefix at 60r/m instead of the 5r/m
    register zone — which made farming challenges an order of magnitude cheaper than the
    registration they gate."""
    for index, block in enumerate(blocks):
        matched = _matching_location(_locations(block), path)
        assert matched is not None, f"{path} is unrouted in server block {index}"
        modifier, pattern, body = matched
        assert modifier == "=", (
            f"{path} is served by prefix location `{pattern}` in server block {index}; an "
            f"exact match is what keeps it out of the chat zone"
        )
        assert "zone=badan_register" in body, (
            f"{path} does not use the badan_register limit_req zone in server block {index}"
        )


def test_footprints_keeps_its_own_zone(blocks):
    """ADR-0011 / D-37: one submission per device per ~day, so it must not inherit the chat
    zone's 60r/m."""
    for block in blocks:
        matched = _matching_location(_locations(block), "/v1/footprints")
        assert matched is not None
        assert matched[0] == "="
        assert "zone=badan_footprints" in matched[2]


def test_account_sign_in_keeps_its_own_zone(blocks):
    """ADR-0014 / D-44: `/v1/account/apple` is the only route in this service that creates
    persistent per-user state, and nothing authenticates the caller before Apple's token is
    verified. Left on the loose `/v1/` prefix it would inherit the chat zone's 60r/m, which is
    the budget for someone typing questions — not for minting accounts and referral codes."""
    for index, block in enumerate(blocks):
        matched = _matching_location(_locations(block), "/v1/account/apple")
        assert matched is not None, f"/v1/account/apple is unrouted in server block {index}"
        assert matched[0] == "=", (
            f"/v1/account/apple is served by prefix location `{matched[1]}` in block {index}; "
            f"an exact match is what keeps it out of the chat zone"
        )
        assert "zone=badan_account" in matched[2]


def test_the_catch_all_is_still_a_404(blocks):
    """The reason this file is an allowlist at all. If this ever became a proxy_pass, every
    test above would pass vacuously."""
    for block in blocks:
        catch_all = [body for modifier, pattern, body in _locations(block)
                     if modifier == "" and pattern == "/"]
        assert len(catch_all) == 1
        assert "return 404" in catch_all[0]
