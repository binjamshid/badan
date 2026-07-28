"""BADAN AI-coach backend (A9 / ADR-0010 / D-22).

Stateless proxy in front of a hosted LLM. Holds no user accounts, no health
data, and no conversation history — retrieval and history stay on-device
(D-22's "on-device retrieval" half). This service exists purely so a
device that has explicitly opted in to the AI coach can send a query +
minimal caller-assembled context and get a completion back.

Hard rule (G8 gate, "zero health values in any diagnostic/telemetry path"):
this process must never log request or response bodies. Only structured,
content-free access logs (status code, latency, device-token prefix) are
permitted.

Device auth (this file's own follow-up to the placeholder shared secret):
`POST /v1/register` issues a per-install, per-device opaque token — not
tied to any account or identity (BADAN has zero accounts, ADR-0002/D-2,
and this must not become one) — persisted as a SHA-256 hash in a small
local SQLite file (stdlib `sqlite3`, no new dependency). `POST /v1/chat`
validates the caller's bearer token against that store instead of a single
shared static secret, and applies a simple in-memory per-token sliding-
window rate limit so one misbehaving or compromised token can't run up
unbounded OpenRouter cost. This is a single-process deployment (see
`infra/badan-api.service` — one `uvicorn` process, no workers), so neither
the in-memory limiter nor the per-call SQLite connections need cross-
process coordination.

Registration itself is also rate-limited (independent audit finding, 2026-07-23: the
per-token `/v1/chat` limiter above is defeated in aggregate if minting a fresh token is
free and unbounded — a script could loop `/v1/register` and fan a large OpenRouter spend
out across many individually-under-the-cap tokens). `register_rate_limiter`/
`global_register_rate_limiter` below bound that per-caller-IP and server-wide;
`infra/nginx/badan-api.conf` adds a second, independent `limit_req` layer in front of this
one. A captured/exfiltrated token also no longer lives forever: `POST /v1/revoke` lets a
caller invalidate its own token server-side, and `AICoachClient.disable()` (iOS) calls it
as a best-effort fire-and-forget alongside deleting the local Keychain copy.

App Attest (2026-07-28) is the step past rate limiting. Limiters slow an attacker
minting tokens; they do not distinguish the real app from a script, because there was
nothing to distinguish it BY — ADR-0002 leaves no account to authenticate. Apple's
attestation supplies exactly that missing thing and nothing more: proof the caller is a
genuine, unmodified BADAN install on real hardware, carrying no user identity and no
health data. `POST /v2/register` issues a token only against a valid attestation over a
server-issued single-use challenge (`POST /v1/attest/challenge`). See `appattest.py`.

`/v1/register` stays alive and unattested behind `BADAN_LEGACY_REGISTER_ENABLED`
(default on) ON PURPOSE: BADAN is live on the App Store, and installs already out there
call `/v1/register` when a user first enables the coach. Making attestation mandatory
server-side the moment this deploys would break opt-in for every one of them. The
sequence is: deploy this, ship the client build that calls `/v2/register`, wait for
adoption, then set `BADAN_LEGACY_REGISTER_ENABLED=0`. Until that flip the old hole is
still open — the flag is the whole point, so it is not "done" until it is off.
"""

import base64
import binascii
import hashlib
import logging
import os
import secrets
import sqlite3
import time
import uuid
from collections import defaultdict, deque
from pathlib import Path
from threading import Lock

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from appattest import AttestationError, verify_attestation

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("badan-api")

OPENROUTER_API_KEY = os.environ["OPENROUTER_API_KEY"]
OPENROUTER_MODEL = os.environ.get("OPENROUTER_MODEL", "openai/gpt-4o")
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

app = FastAPI(title="badan-api", version="0.1.0")


@app.middleware("http")
async def content_free_access_log(request: Request, call_next):
    start = time.monotonic()
    request_id = str(uuid.uuid4())
    response = await call_next(request)
    elapsed_ms = round((time.monotonic() - start) * 1000, 1)
    log.info(
        "request_id=%s method=%s path=%s status=%s elapsed_ms=%s",
        request_id, request.method, request.url.path, response.status_code, elapsed_ms,
    )
    response.headers["x-request-id"] = request_id
    return response


@app.get("/health")
async def health():
    return {"status": "ok", "service": "badan-api", "version": app.version}


# --- Device token store -----------------------------------------------------
#
# Replaces the placeholder shared-secret gate (`BADAN_DEVICE_AUTH_TOKEN`) that used to be
# the only thing standing between this endpoint and the public internet. Now `/v1/register`
# actually issues a token per install, and `/v1/chat` checks that a presented token was
# really issued by this server — not just that it matches one fixed string everyone with
# the app binary could in principle extract.

# `infra/badan-api.service` grants `ReadWritePaths=/srv/badan/data` under an otherwise
# read-only `ProtectSystem=strict` hardening — this is that directory. Overridable via env
# (e.g. for local runs / tests) so nothing here hard-requires a path only the VPS has.
DATA_DIR = Path(os.environ.get("BADAN_DATA_DIR", "/srv/badan/data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
TOKENS_DB_PATH = DATA_DIR / "device_tokens.db"


def _hash_token(token: str) -> str:
    """SHA-256 of a raw device token. Only ever the hash is persisted — the raw token is
    handed back to the caller exactly once, at issuance, and never stored or logged, the
    same reasoning a password store applies to a leaked row."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class DeviceTokenStore:
    """SQLite-backed store for per-install device tokens (A9's own deferred item: "a
    per-device auth/abuse-prevention scheme... the opt-in flow issues a per-install device
    token on first enable"). A row proves only "this server issued a token at some point" —
    no account, no identity, nothing else attached (ADR-0002/D-2).
    """

    def __init__(self, db_path: Path):
        self._db_path = db_path
        self._lock = Lock()
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS device_tokens (
                    token_hash TEXT PRIMARY KEY,
                    issued_at REAL NOT NULL
                );
                """
            )
            conn.commit()

    def _connect(self) -> sqlite3.Connection:
        # A fresh connection per call rather than one held open: this runs inside `async def`
        # request handlers on a single-threaded event loop, so there is no cross-request
        # concurrency to coordinate — a short-lived connection keeps each call self-contained
        # and avoids ever sharing one `sqlite3.Connection` across requests.
        return sqlite3.connect(self._db_path)

    def issue(self) -> str:
        token = secrets.token_urlsafe(32)
        token_hash = _hash_token(token)
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO device_tokens (token_hash, issued_at) VALUES (?, ?);",
                (token_hash, time.time()),
            )
            conn.commit()
        return token

    def is_valid(self, token: str) -> bool:
        if not token:
            return False
        token_hash = _hash_token(token)
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM device_tokens WHERE token_hash = ?;", (token_hash,)
            ).fetchone()
        return row is not None

    def revoke(self, token: str) -> None:
        """Delete a token's row so it can never authenticate again — the server-side half of
        "disable" actually meaning something past the caller's own device (independent audit
        finding, 2026-07-23: previously a token, once issued, stayed valid forever with no
        expiry or revocation path, so an exfiltrated copy kept working even after the
        legitimate user turned the feature off). Idempotent: revoking an unknown or
        already-revoked token is a silent no-op, matching `is_valid`'s own "unknown means not
        authenticated" semantics, so a doubled disable-tap or a retried request is harmless."""
        if not token:
            return
        token_hash = _hash_token(token)
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM device_tokens WHERE token_hash = ?;", (token_hash,))
            conn.commit()


token_store = DeviceTokenStore(TOKENS_DB_PATH)


# --- Per-token rate limiting -------------------------------------------------

class SlidingWindowRateLimiter:
    """A minimal in-memory sliding-window limiter — sufficient for this single-process
    deployment (one `uvicorn` process, no `--workers`; see `infra/badan-api.service`). Keyed
    by the device token's hash rather than the raw token, so this limiter's own in-memory
    state is never a second place a usable bearer token sits in process memory."""

    def __init__(self, max_requests: int, window_seconds: float):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._hits: dict[str, deque] = defaultdict(deque)
        self._lock = Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            hits = self._hits[key]
            while hits and now - hits[0] > self.window_seconds:
                hits.popleft()
            if len(hits) >= self.max_requests:
                return False
            hits.append(now)
            return True


CHAT_RATE_LIMIT_MAX = int(os.environ.get("BADAN_CHAT_RATE_LIMIT_MAX", "20"))
CHAT_RATE_LIMIT_WINDOW_SECONDS = float(os.environ.get("BADAN_CHAT_RATE_LIMIT_WINDOW_SECONDS", "60"))
chat_rate_limiter = SlidingWindowRateLimiter(CHAT_RATE_LIMIT_MAX, CHAT_RATE_LIMIT_WINDOW_SECONDS)

# `/v1/register` has nothing to authenticate the caller against yet (by design — ADR-0002: zero
# accounts, so there is no account to gate registration behind), which otherwise makes it a free,
# unbounded way to mint tokens and defeat `chat_rate_limiter` in aggregate (independent audit
# finding, 2026-07-23). Two layers, same `SlidingWindowRateLimiter` primitive as `/v1/chat`:
# per-caller-IP (stops one script/device from looping registration) and server-wide (bounds worst
# case even across many source IPs). `infra/nginx/badan-api.conf`'s `limit_req` is a third,
# independent layer in front of this process.
REGISTER_RATE_LIMIT_MAX = int(os.environ.get("BADAN_REGISTER_RATE_LIMIT_MAX", "5"))
REGISTER_RATE_LIMIT_WINDOW_SECONDS = float(os.environ.get("BADAN_REGISTER_RATE_LIMIT_WINDOW_SECONDS", "3600"))
register_rate_limiter = SlidingWindowRateLimiter(REGISTER_RATE_LIMIT_MAX, REGISTER_RATE_LIMIT_WINDOW_SECONDS)

GLOBAL_REGISTER_RATE_LIMIT_MAX = int(os.environ.get("BADAN_GLOBAL_REGISTER_RATE_LIMIT_MAX", "200"))
GLOBAL_REGISTER_RATE_LIMIT_WINDOW_SECONDS = float(
    os.environ.get("BADAN_GLOBAL_REGISTER_RATE_LIMIT_WINDOW_SECONDS", "3600")
)
global_register_rate_limiter = SlidingWindowRateLimiter(
    GLOBAL_REGISTER_RATE_LIMIT_MAX, GLOBAL_REGISTER_RATE_LIMIT_WINDOW_SECONDS
)
_GLOBAL_RATE_LIMIT_KEY = "*"


# --- App Attest --------------------------------------------------------------

# "<team id>.<bundle id>" — must match the app exactly, and is what stops an attestation
# from any OTHER app signed by this same team from being accepted here.
ATTEST_APP_ID = os.environ.get("BADAN_ATTEST_APP_ID", "54T3MDUR7H.net.binjamshid.badan")

# Which attestation environments to accept. Mirrors the $(APP_ATTEST_ENV) build setting in
# apps/ios/project.yml: Debug builds attest against "development", Release against
# "production". Production deployments should keep this at production only — accepting
# development attestations in production would let anyone with a development-signed build
# of the bundle id through.
ATTEST_ENVIRONMENTS = frozenset(
    value.strip()
    for value in os.environ.get("BADAN_ATTEST_ENVIRONMENTS", "production").split(",")
    if value.strip()
)

# See the module docstring: leave ON to deploy without breaking already-installed apps,
# turn OFF once the attesting client build has rolled out. This flag existing is not the
# same as the hole being closed.
LEGACY_REGISTER_ENABLED = os.environ.get("BADAN_LEGACY_REGISTER_ENABLED", "1") == "1"

# A challenge is only useful for as long as it takes a device to attest — seconds. Short
# expiry bounds how long a stolen challenge is worth anything and keeps the in-memory set
# from growing without limit.
CHALLENGE_TTL_SECONDS = float(os.environ.get("BADAN_ATTEST_CHALLENGE_TTL_SECONDS", "300"))

# One physical install produces one attestation key. Re-enabling the coach after a disable
# re-registers with the SAME key, so a small allowance is normal; an unbounded one would
# let a single genuine device mint tokens forever and undo the point of attesting.
MAX_TOKENS_PER_KEY = int(os.environ.get("BADAN_MAX_TOKENS_PER_KEY", "10"))


class ChallengeStore:
    """Single-use, expiring challenges, in memory.

    In memory is correct here rather than a shortcut: this is a single-process
    deployment (`infra/badan-api.service`, one uvicorn worker, no `--workers`), and a
    challenge is worthless after a few seconds. A restart invalidates outstanding
    challenges, which surfaces to a caller as one retryable failure at opt-in time.

    Single use is the load-bearing property. Without `consume` deleting the challenge, a
    captured attestation could be replayed against the same challenge indefinitely.
    """

    def __init__(self, ttl_seconds: float):
        self._ttl = ttl_seconds
        self._issued: dict[str, float] = {}
        self._lock = Lock()

    def issue(self) -> bytes:
        challenge = secrets.token_bytes(32)
        now = time.monotonic()
        with self._lock:
            # Opportunistic sweep — no background task needed for a dict this small.
            expired = [key for key, at in self._issued.items() if now - at > self._ttl]
            for key in expired:
                del self._issued[key]
            self._issued[challenge.hex()] = now
        return challenge

    def consume(self, challenge: bytes) -> bool:
        """True exactly once per issued, unexpired challenge."""
        key = challenge.hex()
        now = time.monotonic()
        with self._lock:
            issued_at = self._issued.pop(key, None)
        return issued_at is not None and now - issued_at <= self._ttl


class AttestedKeyStore:
    """Records which attestation keys have been seen, and how many tokens each has been
    granted. Shares the SQLite file the device tokens already live in.

    A row holds a random per-install key id and a public key — no account, no identity,
    nothing joinable to a person (ADR-0002/D-2 unchanged). The count is what bounds a
    single compromised-but-genuine device.
    """

    def __init__(self, db_path: Path):
        self._db_path = db_path
        self._lock = Lock()
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS attested_keys (
                    key_id TEXT PRIMARY KEY,
                    public_key BLOB NOT NULL,
                    environment TEXT NOT NULL,
                    first_seen REAL NOT NULL,
                    tokens_issued INTEGER NOT NULL DEFAULT 0
                );
                """
            )
            conn.commit()

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path)

    def record_issue(self, key_id: bytes, public_key_der: bytes, environment: str) -> bool:
        """Register the key (first time) and count one token against it. False when the
        key has already been granted `MAX_TOKENS_PER_KEY` tokens."""
        key_hex = key_id.hex()
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT tokens_issued FROM attested_keys WHERE key_id = ?;", (key_hex,)
            ).fetchone()
            if row is None:
                conn.execute(
                    """
                    INSERT INTO attested_keys
                        (key_id, public_key, environment, first_seen, tokens_issued)
                    VALUES (?, ?, ?, ?, 1);
                    """,
                    (key_hex, public_key_der, environment, time.time()),
                )
                conn.commit()
                return True
            if row[0] >= MAX_TOKENS_PER_KEY:
                return False
            conn.execute(
                "UPDATE attested_keys SET tokens_issued = tokens_issued + 1 WHERE key_id = ?;",
                (key_hex,),
            )
            conn.commit()
            return True


challenge_store = ChallengeStore(CHALLENGE_TTL_SECONDS)
attested_key_store = AttestedKeyStore(TOKENS_DB_PATH)


def _decode_base64(value: str, *, max_bytes: int) -> bytes:
    """Strict base64 decode with a size cap, for caller-supplied blobs. Anything
    malformed or oversized is an unauthorized request, not a 500 — this runs before any
    verification on input from an unauthenticated endpoint."""
    if len(value) > max_bytes * 2:
        raise HTTPException(status_code=401, detail="unauthorized")
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(status_code=401, detail="unauthorized") from exc


def _client_ip(request: Request) -> str:
    """Best-effort caller IP for the registration rate limiter above. This process binds to
    127.0.0.1 only (`infra/badan-api.service`'s `ExecStart`) and is reachable exclusively
    through the nginx vhost, which always sets `X-Real-IP` to `$remote_addr`
    (`infra/nginx/badan-api.conf`) — so trusting this header does not open a spoofing path from
    the public internet; only the already-trusted reverse proxy can set it. Falls back to the
    raw peer address for local/test runs that talk to this process directly, skipping nginx."""
    real_ip = request.headers.get("x-real-ip")
    if real_ip:
        return real_ip
    return request.client.host if request.client else "unknown"


@app.post("/v1/register")
async def register(request: Request):
    """Issue a fresh, anonymous per-install device token. No request body is required — this
    endpoint has nothing to authenticate the caller against yet, by design (ADR-0002: zero
    accounts). The iOS/Android client calls this exactly once, on first opt-in, and stores
    the returned token in the platform Keychain/Keystore."""
    client_ip = _client_ip(request)
    if not register_rate_limiter.allow(client_ip):
        log.warning("register_rate_limited=true scope=ip")
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    if not global_register_rate_limiter.allow(_GLOBAL_RATE_LIMIT_KEY):
        log.warning("register_rate_limited=true scope=global")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    if not LEGACY_REGISTER_ENABLED:
        # Deliberately 410 rather than 404: an old client learns the endpoint is gone, not
        # that it typed the URL wrong, and the client maps it to "update the app".
        raise HTTPException(status_code=410, detail="endpoint retired")

    token = token_store.issue()
    # Content-free per G8: confirms a token was issued, never logs the token itself.
    log.info("device_token_issued=true legacy=true")
    return {"token": token}


@app.post("/v1/attest/challenge")
async def attest_challenge(request: Request):
    """Issue a single-use challenge for `POST /v2/register`.

    Rate limited on the same per-IP/global budget as registration itself: a challenge is
    cheap to make, but handing them out without limit would let an attacker farm them and
    then spend an attestation budget in one burst.
    """
    client_ip = _client_ip(request)
    if not register_rate_limiter.allow(client_ip):
        log.warning("register_rate_limited=true scope=ip stage=challenge")
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    if not global_register_rate_limiter.allow(_GLOBAL_RATE_LIMIT_KEY):
        log.warning("register_rate_limited=true scope=global stage=challenge")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    challenge = challenge_store.issue()
    return {"challenge": base64.b64encode(challenge).decode("ascii")}


class AttestedRegisterRequest(BaseModel):
    # Sizes are bounded so a malformed or hostile body is rejected before any parsing
    # work: a key id is a SHA-256 (32 bytes), a challenge is 32 bytes, and a real
    # attestation blob is a few KB. The caps are generous multiples of those, not tight
    # fits, so a future Apple format change does not silently start failing here.
    key_id: str = Field(max_length=128)
    challenge: str = Field(max_length=128)
    attestation: str = Field(max_length=32_000)


@app.post("/v2/register")
async def register_attested(body: AttestedRegisterRequest, request: Request):
    """Issue a device token, but only to a caller that can prove it is the real app.

    Everything `/v1/register` does, plus Apple App Attest over a server-issued single-use
    challenge. The rate limiters are kept, not replaced — attestation bounds WHO can mint
    tokens, the limiters bound HOW FAST, and a genuine-but-compromised device needs both.

    Failures are a flat 401 with no detail, matching `appattest.verify_attestation`'s own
    single error message: a caller must not be able to use responses to work out which
    check it tripped.
    """
    client_ip = _client_ip(request)
    if not register_rate_limiter.allow(client_ip):
        log.warning("register_rate_limited=true scope=ip")
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    if not global_register_rate_limiter.allow(_GLOBAL_RATE_LIMIT_KEY):
        log.warning("register_rate_limited=true scope=global")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    key_id = _decode_base64(body.key_id, max_bytes=64)
    challenge = _decode_base64(body.challenge, max_bytes=64)
    attestation = _decode_base64(body.attestation, max_bytes=24_000)

    # Consume FIRST. If verification runs before the challenge is spent, a failed attempt
    # leaves the challenge outstanding and hands an attacker unlimited tries against one
    # challenge — the exact replay the single-use property exists to prevent.
    if not challenge_store.consume(challenge):
        log.warning("attest_rejected=true stage=challenge")
        raise HTTPException(status_code=401, detail="unauthorized")

    try:
        verified = verify_attestation(
            attestation=attestation,
            key_id=key_id,
            challenge=challenge,
            app_id=ATTEST_APP_ID,
            allowed_environments=ATTEST_ENVIRONMENTS,
        )
    except AttestationError:
        # G8: the blob itself is caller-supplied content and never reaches the log.
        log.warning("attest_rejected=true stage=verify")
        raise HTTPException(status_code=401, detail="unauthorized") from None

    if not attested_key_store.record_issue(
        verified.key_id, verified.public_key_der, verified.environment
    ):
        log.warning("attest_rejected=true stage=key_budget")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    token = token_store.issue()
    log.info("device_token_issued=true attested=true environment=%s", verified.environment)
    return {"token": token}


@app.post("/v1/revoke")
async def revoke(authorization: str = Header(default="")):
    """Server-side half of "turn off the AI coach": invalidate the caller's own bearer token so
    it can no longer authenticate `/v1/chat`, even if a copy of it was exfiltrated from the
    device (jailbreak, backup extraction, debugger attach) before the user disabled the
    feature. Requires the token itself as proof of ownership — matching `/v1/chat`, there is
    still no account to check against (ADR-0002/D-2). Always idempotent (see
    `DeviceTokenStore.revoke`): the caller learns nothing about whether the token was valid
    beforehand, only that it is no longer valid now."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="unauthorized")
    token = authorization.removeprefix("Bearer ")
    token_store.revoke(token)
    # Content-free per G8: confirms a revoke happened, never logs the token itself.
    log.info("device_token_revoked=true")
    return {"status": "revoked"}


class ChatMessage(BaseModel):
    role: str = Field(pattern="^(system|user|assistant)$")
    # Bounded per independent audit finding (2026-07-23): an unbounded `content` let a single
    # request within the per-token rate-limit budget carry ~1 MB of prompt text (nginx's default
    # `client_max_body_size`), multiplying cost-per-request well beyond a normal chat turn.
    # 4000 chars comfortably covers a real chat turn (the context block `AICoachContextAssembler`
    # renders is a handful of short lines) with headroom, while bounding worst case.
    content: str = Field(max_length=4000)


class ChatRequest(BaseModel):
    # Bounded alongside `content` above, same finding: caps total request size regardless of how
    # long a single device's in-memory transcript (`AICoachChatScreen`'s `turns`) has grown.
    messages: list[ChatMessage] = Field(min_length=1, max_length=40)


@app.post("/v1/chat")
async def chat(body: ChatRequest, authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="unauthorized")
    token = authorization.removeprefix("Bearer ")
    if not token_store.is_valid(token):
        raise HTTPException(status_code=401, detail="unauthorized")

    token_key = _hash_token(token)
    if not chat_rate_limiter.allow(token_key):
        log.warning("rate_limited=true")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    payload = {
        "model": OPENROUTER_MODEL,
        "messages": [m.model_dump() for m in body.messages],
    }
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://badan.binjamshid.com",
        "X-Title": "BADAN AI Coach",
    }
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            r = await client.post(OPENROUTER_URL, json=payload, headers=headers)
        except httpx.RequestError as exc:
            log.warning("upstream_request_error=%s", type(exc).__name__)
            raise HTTPException(status_code=502, detail="upstream unavailable") from exc

    if r.status_code >= 400:
        log.warning("upstream_status=%s", r.status_code)
        raise HTTPException(status_code=502, detail="upstream error")

    data = r.json()
    return JSONResponse({"reply": data["choices"][0]["message"]["content"]})
