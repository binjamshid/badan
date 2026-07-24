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
"""

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

    token = token_store.issue()
    # Content-free per G8: confirms a token was issued, never logs the token itself.
    log.info("device_token_issued=true")
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
