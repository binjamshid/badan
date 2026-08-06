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

A route defined here is NOT a route that exists in production. `infra/nginx/badan-api.conf`
is an allowlist ending in `location / { return 404; }`, so an endpoint added here and not
there 404s at the edge and never reaches this process — which is how `/v2/register`, the iOS
client's only registration path, shipped unreachable while this file looked correct. Add
both, or neither; `tests/test_nginx_routes.py` checks the two agree.

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
import datetime
import sqlite3
import time
import uuid
from collections import OrderedDict, deque
from pathlib import Path
from threading import Lock

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from appattest import AttestationError, verify_assertion, verify_attestation
from accounts import (
    MAX_ENTITLEMENTS_PER_PUSH,
    MAX_PRODUCT_ID_LENGTH,
    PLATFORMS,
    REFERRAL_ALPHABET,
    REFERRAL_CODE_LENGTH,
    AccountRecord,
    AccountStore,
    Entitlement,
    ReferralRefused,
    load_subject_salt,
)
from apple_identity import APPLE_JWKS_URL, AppleIdentityError, verify_identity_token

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

# How many distinct keys ONE limiter will track at a time. `_hits` is process-lifetime state
# in a service deliberately run as a single long-lived uvicorn process (`infra/badan-api.service`,
# which sets no `MemoryMax=`), so before this bound every key ever seen was a permanent
# allocation: every caller IP that ever touched `/v1/register`, `/v1/attest/challenge` or
# `/v1/footprints`, and every token hash that ever touched `/v1/chat`, stayed in memory until
# the next deploy — the limiter that exists to bound abuse was itself the thing an abuser grew.
# 10k keys is orders of magnitude above this service's real concurrency and still only a few
# megabytes at worst.
RATE_LIMITER_MAX_KEYS = int(os.environ.get("BADAN_RATE_LIMITER_MAX_KEYS", "10000"))


class SlidingWindowRateLimiter:
    """A minimal in-memory sliding-window limiter — sufficient for this single-process
    deployment (one `uvicorn` process, no `--workers`; see `infra/badan-api.service`). Keyed
    by the device token's hash rather than the raw token, so this limiter's own in-memory
    state is never a second place a usable bearer token sits in process memory.

    Keys are evicted, not accumulated. A key whose window has fully expired carries no
    information — it is indistinguishable from a caller that has never been seen — so keeping
    it is pure cost, and `max_keys` is a hard ceiling for the case where callers arrive faster
    than they expire.

    Eviction is least-recently-active rather than "refuse the new key". Refusing would let
    anyone with a spread of source addresses fill the table and lock every other caller out,
    turning a cost control into a denial-of-service lever; evicting the coldest key only
    forgives the caller that was already closest to falling out of its own window.
    """

    def __init__(self, max_requests: int, window_seconds: float,
                 max_keys: int = RATE_LIMITER_MAX_KEYS):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.max_keys = max_keys
        # Ordered, so `popitem(last=False)` is the least-recently-active key. Not a
        # `defaultdict` any more: lookups must be able to MISS, because a miss is what tells
        # `allow` a key is new and room may have to be made for it.
        self._hits: OrderedDict[str, deque] = OrderedDict()
        # -inf, not 0.0: `time.monotonic()` counts from an arbitrary origin (uptime on Linux),
        # so 0.0 would mean "a sweep already happened" on a machine booted less than one
        # window ago and silently skip the first one.
        self._last_sweep = float("-inf")
        self._lock = Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            hits = self._hits.get(key)
            if hits is None:
                self._make_room_locked(now)
                hits = self._hits[key] = deque()
            else:
                self._hits.move_to_end(key)
            while hits and now - hits[0] > self.window_seconds:
                hits.popleft()
            if len(hits) >= self.max_requests:
                # An empty deque here means `max_requests` is 0 (nothing is ever allowed);
                # drop the key rather than leave a permanently empty entry behind.
                if not hits:
                    del self._hits[key]
                return False
            hits.append(now)
            return True

    def _make_room_locked(self, now: float) -> None:
        """Make space for one new key. Caller must hold `_lock`.

        Runs only on a key that is not already tracked, so a returning caller — the common
        case — pays nothing for it.
        """
        if len(self._hits) < self.max_keys:
            return
        # The full sweep is O(tracked keys), so it is itself rate limited to once per window.
        # Without that, a flood of distinct keys against a full table would walk the whole
        # table per request and make this limiter the cost it exists to prevent; between
        # sweeps the O(1) eviction below holds the bound on its own.
        if now - self._last_sweep > self.window_seconds:
            self._last_sweep = now
            for stale in [k for k, hits in self._hits.items()
                          if not hits or now - hits[-1] > self.window_seconds]:
                del self._hits[stale]
        while len(self._hits) >= self.max_keys:
            self._hits.popitem(last=False)

    def tracked_keys(self) -> int:
        """Size of the in-memory table. Exists for the test that asserts the bound holds —
        there is no other way to observe it, and an unobservable bound is a comment."""
        with self._lock:
            return len(self._hits)


# The output side of the same bound `ChatMessage.content` puts on the input side. Without it
# the model decides how long to run, so one request sitting comfortably inside the per-token
# rate-limit budget can still bill for the provider's maximum completion — the cost control
# was only ever half-installed. 800 tokens is a generous coaching reply (the chat screen
# renders a few short paragraphs) and is deliberately overridable, because the ceiling that
# suits a cheap model is not the one that suits an expensive one.
CHAT_MAX_TOKENS = int(os.environ.get("BADAN_CHAT_MAX_TOKENS", "800"))

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
            # ADR-0011 / D-37. The assertion counter for the per-request scheme
            # `/v1/footprints` uses. Added by ALTER so an existing deployment upgrades in
            # place rather than needing the table rebuilt.
            #
            # This is the only thing preventing replay of a captured assertion, per
            # `appattest.verify_assertion`'s own contract: the caller must persist the
            # returned counter and reject anything that does not strictly exceed it.
            cols = {row[1] for row in conn.execute("PRAGMA table_info(attested_keys);")}
            if "assertion_counter" not in cols:
                conn.execute(
                    "ALTER TABLE attested_keys ADD COLUMN assertion_counter INTEGER NOT NULL DEFAULT 0;"
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

    def public_key(self, key_id: bytes) -> bytes | None:
        """The registered public key for an attestation key id, or None if never attested.

        ADR-0011 states this precisely rather than overclaiming: verifying a footprint
        assertion REQUIRES this lookup, so the server does learn a key id at verification
        time. What it never does is write that key id beside the payload — the non-join is
        a code boundary with a test behind it, not a cryptographic guarantee.
        """
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT public_key FROM attested_keys WHERE key_id = ?;", (key_id.hex(),)
            ).fetchone()
            return row[0] if row else None

    def assertion_counter(self, key_id: bytes) -> int:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT assertion_counter FROM attested_keys WHERE key_id = ?;", (key_id.hex(),)
            ).fetchone()
            return int(row[0]) if row else 0

    def advance_assertion_counter(self, key_id: bytes, counter: int) -> bool:
        """Store a strictly larger counter. False when the presented counter does not
        advance — i.e. a replay — checked and written under one lock so two concurrent
        submissions cannot both pass the same value."""
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT assertion_counter FROM attested_keys WHERE key_id = ?;", (key_id.hex(),)
            ).fetchone()
            if row is None or counter <= int(row[0]):
                return False
            conn.execute(
                "UPDATE attested_keys SET assertion_counter = ? WHERE key_id = ?;",
                (counter, key_id.hex()),
            )
            conn.commit()
            return True


challenge_store = ChallengeStore(CHALLENGE_TTL_SECONDS)
attested_key_store = AttestedKeyStore(TOKENS_DB_PATH)


def _decode_base64(value: str, *, max_bytes: int) -> bytes:
    """Strict base64 decode with a size cap, for caller-supplied blobs. Never a 500 — this
    runs before any verification, on input from an unauthenticated endpoint.

    The two failure modes get DIFFERENT statuses, on purpose.

    Malformed base64 is 401, indistinguishable from every other rejection on these
    endpoints: a caller must not be able to read the status to work out which check it
    tripped (the same reasoning as `/v2/register`'s flat 401).

    Merely being too big is 413, and used to be 401 — which was actively misleading rather
    than merely conservative. Size is a fact the caller already knows (it counted the bytes
    it sent) so answering with it reveals nothing about any credential, while answering 401
    told a genuine, correctly-attested client that its identity had failed. A client's only
    sane response to 401 is to re-register; the correct response to "too big" is to send
    less. `/v1/footprints` spent its whole life giving the first answer to the second
    problem.
    """
    # base64 of N bytes is ceil(N/3)*4 characters. Bounding the ENCODED length rejects an
    # oversized blob before `b64decode` allocates a decoded copy of it.
    if len(value) > ((max_bytes + 2) // 3) * 4:
        raise HTTPException(status_code=413, detail="payload too large")
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
        "max_tokens": CHAT_MAX_TOKENS,
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

    # A 200 is not a promise of the shape we asked for. Indexing straight into the body used
    # to turn a truncated, empty-`choices` or non-JSON upstream response into a KeyError /
    # IndexError, i.e. a 500 — this service blaming itself for the provider's fault, and
    # handing the client the one status that means "retrying will not help" for a condition
    # where retrying is exactly right. 502 says what is actually true.
    #
    # G8: the body is model output and must never be logged, not even while debugging this.
    # The status line below is the whole diagnostic, and that is the intended trade.
    try:
        reply = r.json()["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError):
        log.warning("upstream_malformed_response=true")
        raise HTTPException(status_code=502, detail="upstream error") from None
    if not isinstance(reply, str):
        log.warning("upstream_malformed_response=true")
        raise HTTPException(status_code=502, detail="upstream error")
    return JSONResponse({"reply": reply})


# --- Methodology telemetry (ADR-0011 / D-37) --------------------------------
#
# Learning footprints only: which metric, which method, the direction of a user's
# disagreement, a bucketed event count, and whether a calibration was in force. No reading,
# no offset magnitude, no date or period key, no identifier, no locale or region.
#
# This narrows CLAUDE.md's "Never: send user health data off device" and the Never survives:
# no health datum arrives here. What arrives is a statement about a METHOD.

FOOTPRINTS_DB_PATH = DATA_DIR / "footprints.db"

# 400 days. Long enough to compare a constant across a year of releases plus a margin;
# short enough that a store breach cannot yield an indefinite history.
FOOTPRINT_RETENTION_DAYS = int(os.environ.get("BADAN_FOOTPRINT_RETENTION_DAYS", "400"))

FOOTPRINT_DIRECTIONS = frozenset({"matches", "over", "under"})
FOOTPRINT_BUCKETS = frozenset({"10-19", "20-49", "50+"})
FOOTPRINT_SCHEMA_VERSION = 1
MAX_FOOTPRINTS_PER_BATCH = 200

# `clientData` is the batch JSON itself, byte for byte: `FootprintClient.submit` (iOS) signs
# the exact bytes it encodes and sends those same bytes along, which is what binds the
# assertion to this batch and not another. So its size cap has to fit a FULL batch — and it
# did not. A flat 4 KB meant anything past roughly 35 footprints was refused while
# `MAX_FOOTPRINTS_PER_BATCH` advertised 200, and refused as a 401 (see `_decode_base64`),
# which a client cannot tell apart from its attestation being rejected. Two constants stating
# incompatible limits is how that survived, so this one is DERIVED from the other rather than
# written as a second independent number.
#
# Worst case for one serialised footprint: every bounded field at its schema maximum
# (metricId 64 + algorithmId 64 + algorithmSemver 16 + the closed-enum values) plus JSON key
# names, quoting and separators — under 300 bytes. The envelope is schemaVersion, appVersion
# and contractVersion, all short and bounded.
MAX_FOOTPRINT_JSON_BYTES = 300
FOOTPRINT_ENVELOPE_JSON_BYTES = 256
MAX_CLIENT_DATA_BYTES = (
    MAX_FOOTPRINTS_PER_BATCH * MAX_FOOTPRINT_JSON_BYTES + FOOTPRINT_ENVELOPE_JSON_BYTES
)
# A worst-case batch carries the footprints twice — once as the parsed array and once as
# `clientData`'s base64 of the same bytes — which lands around 130 KB total, inside the
# vhost's `client_max_body_size 256k` (`infra/nginx/badan-api.conf`). Raising either of the
# two constants above past that would need the vhost raised with it.


class FootprintStore:
    """Footprints, in their OWN SQLite file.

    Separate from `device_tokens.db` on purpose (ADR-0011): footprints and attestation keys
    must not be joinable in one query, and a compromise of one file is not a compromise of
    the other. There is no key id, no token hash and no device column in this table at all —
    the schema is where the non-join is enforced, not the query layer.

    `received_day` is a date, never a timestamp: a precise receive time is a weak identifier
    (it correlates with when a person opened their phone), and day granularity is all the
    analysis needs.
    """

    def __init__(self, db_path: Path):
        self._db_path = db_path
        self._lock = Lock()
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS footprints (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    received_day TEXT NOT NULL,
                    app_version TEXT NOT NULL,
                    contract_version TEXT NOT NULL,
                    metric_id TEXT NOT NULL,
                    algorithm_id TEXT NOT NULL,
                    algorithm_semver TEXT NOT NULL,
                    direction TEXT NOT NULL,
                    event_count_bucket TEXT NOT NULL,
                    calibration_applied INTEGER NOT NULL
                );
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_footprints_day ON footprints(received_day);"
            )
            conn.commit()

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path)

    def insert_batch(self, *, received_day: str, app_version: str, contract_version: str,
                     footprints: list[dict]) -> int:
        """Write a batch and prune anything past retention, in one transaction.

        Pruning on write rather than on a schedule keeps retention a property of the store
        instead of a cron job someone can forget to install.
        """
        cutoff = datetime.date.today() - datetime.timedelta(days=FOOTPRINT_RETENTION_DAYS)
        with self._lock, self._connect() as conn:
            conn.executemany(
                """
                INSERT INTO footprints
                    (received_day, app_version, contract_version, metric_id, algorithm_id,
                     algorithm_semver, direction, event_count_bucket, calibration_applied)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    (received_day, app_version, contract_version, f["metricId"],
                     f["algorithmId"], f["algorithmSemver"], f["direction"],
                     f["eventCountBucket"], 1 if f["calibrationApplied"] else 0)
                    for f in footprints
                ],
            )
            conn.execute("DELETE FROM footprints WHERE received_day < ?;", (cutoff.isoformat(),))
            conn.commit()
            return len(footprints)


footprint_store = FootprintStore(FOOTPRINTS_DB_PATH)

# One submission per device per ~day is the intended cadence (the client waits a randomised
# 24-72h), so this is generous by an order of magnitude and still bounds a runaway client.
footprint_rate_limiter = SlidingWindowRateLimiter(
    int(os.environ.get("BADAN_FOOTPRINT_RATE_LIMIT_MAX", "10")),
    int(os.environ.get("BADAN_FOOTPRINT_RATE_LIMIT_WINDOW_SECONDS", "3600")),
)


class FootprintItem(BaseModel):
    """One footprint. `extra="forbid"` mirrors the contract's `additionalProperties: false`
    — the schema IS the boundary, so an unknown field is a rejected request, not an ignored
    one. Without this a future client could widen the payload silently."""

    model_config = {"extra": "forbid"}

    metricId: str = Field(max_length=64, pattern=r"^[a-z0-9_.]+$")
    algorithmId: str = Field(max_length=64, pattern=r"^[a-z0-9_.]+$")
    algorithmSemver: str = Field(max_length=16, pattern=r"^[0-9]+\.[0-9]+\.[0-9]+$")
    direction: str
    eventCountBucket: str
    calibrationApplied: bool


class FootprintBatchRequest(BaseModel):
    model_config = {"extra": "forbid"}

    schemaVersion: int
    appVersion: str = Field(max_length=16, pattern=r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")
    contractVersion: str = Field(max_length=16, pattern=r"^[0-9]+\.[0-9]+\.[0-9]+$")
    footprints: list[FootprintItem] = Field(min_length=1, max_length=MAX_FOOTPRINTS_PER_BATCH)
    # The attestation proving this is a genuine app instance. Not part of the stored
    # payload and never written beside it — see `/v1/footprints`.
    #
    # `clientData` is the signed bytes of the batch above, not a nonce: it has to fit a full
    # `MAX_FOOTPRINTS_PER_BATCH` batch, and `MAX_CLIENT_DATA_BYTES` is what sizes it. The
    # size gate lives in `_decode_base64` at the handler rather than as a `Field(max_length=)`
    # here so that an over-sized blob answers 413 and not pydantic's 422 — a caller sending a
    # legitimate-but-large batch should be told it was large, and only that.
    keyId: str
    assertion: str
    clientData: str


@app.post("/v1/footprints")
async def submit_footprints(body: FootprintBatchRequest, request: Request):
    """Accept a batch of learning footprints from a genuine app instance.

    Flood control is an App Attest assertion per submission rather than a device token,
    which is what lets this endpoint carry NO identifier: a token would be one, and storing
    it beside a footprint is exactly the join ADR-0011 forbids.

    **The honest statement of what that buys.** Verifying an assertion requires looking the
    key up in `attested_keys`, so this process does learn a key id here. It never writes it
    alongside the payload, and `test_footprints_table_has_no_identifier_column` plus
    `test_footprint_row_cannot_be_joined_to_an_attestation_key` are what keep that true.
    This is a code boundary, not cryptographic unlinkability, and the ADR does not claim
    otherwise.
    """
    client_ip = _client_ip(request)
    if not footprint_rate_limiter.allow(client_ip):
        log.warning("footprint_rate_limited=true scope=ip")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    if body.schemaVersion != FOOTPRINT_SCHEMA_VERSION:
        raise HTTPException(status_code=400, detail="unsupported schema version")

    # Closed enums, checked here as well as in the contract: pydantic validates shape, this
    # validates the boundary's own vocabulary. A value outside these sets could carry more
    # than the decision authorised.
    for item in body.footprints:
        if item.direction not in FOOTPRINT_DIRECTIONS:
            raise HTTPException(status_code=400, detail="invalid direction")
        if item.eventCountBucket not in FOOTPRINT_BUCKETS:
            raise HTTPException(status_code=400, detail="invalid bucket")

    key_id = _decode_base64(body.keyId, max_bytes=64)
    assertion = _decode_base64(body.assertion, max_bytes=8_000)
    client_data = _decode_base64(body.clientData, max_bytes=MAX_CLIENT_DATA_BYTES)

    public_key = attested_key_store.public_key(key_id)
    if public_key is None:
        log.warning("footprint_rejected=true stage=unknown_key")
        raise HTTPException(status_code=401, detail="unauthorized")

    try:
        counter = verify_assertion(
            assertion=assertion,
            client_data=client_data,
            public_key_der=public_key,
            previous_counter=attested_key_store.assertion_counter(key_id),
            app_id=ATTEST_APP_ID,
        )
    except AttestationError:
        # G8: the assertion blob is caller-supplied content and never reaches the log.
        log.warning("footprint_rejected=true stage=verify")
        raise HTTPException(status_code=401, detail="unauthorized") from None

    if not attested_key_store.advance_assertion_counter(key_id, counter):
        log.warning("footprint_rejected=true stage=replay")
        raise HTTPException(status_code=401, detail="unauthorized")

    # From here on `key_id` is deliberately out of scope for what gets stored. The insert
    # below takes only the payload — there is no parameter to pass it through.
    written = footprint_store.insert_batch(
        received_day=datetime.date.today().isoformat(),
        app_version=body.appVersion,
        contract_version=body.contractVersion,
        footprints=[item.model_dump() for item in body.footprints],
    )
    log.info("footprints_accepted=%s", written)
    return JSONResponse({"accepted": written})


# --- Accounts, cross-platform entitlements and referrals (ADR-0014 / D-44) -----
#
# The reversal. Until D-44 this service held no accounts and no per-user state, and three
# separate places in the repository said so. It now holds an account id, a salted hash of
# Apple's subject claim, a referral code, and one store product id per platform — and
# nothing else. In particular it still holds NO health data, which is the Never that
# survived D-44 completely intact; `tests/test_accounts.py` pins the column list so a later
# migration cannot quietly widen it.
#
# Everything below is gated behind an Apple-signed identity token on the way in and an
# opaque bearer session thereafter. See `accounts.py` and `apple_identity.py`.

ACCOUNTS_DB_PATH = DATA_DIR / "accounts.db"

# The bundle id Apple sets as `aud` in the identity token. Checking it is what stops a token
# minted for some OTHER app — including one an attacker controls and can mint from freely —
# being presented here to create an account.
APPLE_AUDIENCE = os.environ.get("BADAN_APPLE_AUDIENCE", "net.binjamshid.badan")

# How long Apple's published signing keys are cached. Apple rotates them without notice, so
# a miss triggers exactly one forced refetch (see `_apple_jwks`) before the request is
# refused — the alternative, refetching per sign-in, would put a third-party network call on
# BADAN's authentication path and make Apple's availability our availability.
APPLE_JWKS_TTL_SECONDS = float(os.environ.get("BADAN_APPLE_JWKS_TTL_SECONDS", "3600"))
APPLE_JWKS_TIMEOUT_SECONDS = float(os.environ.get("BADAN_APPLE_JWKS_TIMEOUT_SECONDS", "10"))

# Sign-in is the expensive, account-creating route, so it is limited like `/v1/register` and
# for the same reason: nothing authenticates the caller before the token is verified, and an
# unbounded account-creation endpoint is an unbounded referral-code printer.
ACCOUNT_SIGNIN_RATE_LIMIT_MAX = int(os.environ.get("BADAN_ACCOUNT_SIGNIN_RATE_LIMIT_MAX", "10"))
ACCOUNT_SIGNIN_RATE_LIMIT_WINDOW_SECONDS = float(
    os.environ.get("BADAN_ACCOUNT_SIGNIN_RATE_LIMIT_WINDOW_SECONDS", "3600")
)
account_signin_rate_limiter = SlidingWindowRateLimiter(
    ACCOUNT_SIGNIN_RATE_LIMIT_MAX, ACCOUNT_SIGNIN_RATE_LIMIT_WINDOW_SECONDS
)

# Referral claims are limited per session, not per IP: the abuse being bounded is one account
# guessing codes, and the code space (29^8) is large enough that a low ceiling makes brute
# force pointless while never inconveniencing a user who mistypes a friend's code twice.
ACCOUNT_CLAIM_RATE_LIMIT_MAX = int(os.environ.get("BADAN_ACCOUNT_CLAIM_RATE_LIMIT_MAX", "5"))
ACCOUNT_CLAIM_RATE_LIMIT_WINDOW_SECONDS = float(
    os.environ.get("BADAN_ACCOUNT_CLAIM_RATE_LIMIT_WINDOW_SECONDS", "3600")
)
account_claim_rate_limiter = SlidingWindowRateLimiter(
    ACCOUNT_CLAIM_RATE_LIMIT_MAX, ACCOUNT_CLAIM_RATE_LIMIT_WINDOW_SECONDS
)

account_store = AccountStore(ACCOUNTS_DB_PATH, salt=load_subject_salt(DATA_DIR))

_jwks_cache: dict[str, object] = {"keys": [], "fetched_at": 0.0}
_jwks_lock = Lock()


async def _apple_jwks(*, force_refresh: bool = False) -> list[dict]:
    """Apple's current identity-token signing keys, cached.

    Not a `SlidingWindowRateLimiter`-style structure because it holds exactly one entry; a
    plain dict under a lock is the whole requirement. The lock guards the write, not the
    fetch: two concurrent sign-ins during a rotation may both fetch, and that is fine and
    cheaper than serialising every sign-in behind one HTTP call.
    """
    now = time.time()
    if not force_refresh:
        with _jwks_lock:
            keys = _jwks_cache["keys"]
            age = now - float(_jwks_cache["fetched_at"])
        if keys and age < APPLE_JWKS_TTL_SECONDS:
            return list(keys)  # type: ignore[arg-type]

    try:
        async with httpx.AsyncClient(timeout=APPLE_JWKS_TIMEOUT_SECONDS) as client:
            response = await client.get(APPLE_JWKS_URL)
            response.raise_for_status()
            keys = response.json().get("keys", [])
    except (httpx.HTTPError, ValueError):
        # Serve a stale cache rather than failing sign-in over Apple being briefly
        # unreachable. Verification itself is unaffected: a stale key either verifies the
        # signature or it does not, and a rotated-away key simply produces a kid miss.
        with _jwks_lock:
            stale = list(_jwks_cache["keys"])  # type: ignore[arg-type]
        if stale:
            log.warning("apple_jwks_fetch_failed=true served=stale")
            return stale
        log.warning("apple_jwks_fetch_failed=true served=none")
        raise HTTPException(status_code=503, detail="identity provider unavailable") from None

    if not isinstance(keys, list) or not keys:
        raise HTTPException(status_code=503, detail="identity provider unavailable")
    with _jwks_lock:
        _jwks_cache["keys"] = keys
        _jwks_cache["fetched_at"] = now
    return keys


def _bearer(authorization: str) -> str:
    scheme, _, value = authorization.partition(" ")
    return value.strip() if scheme.lower() == "bearer" else ""


def _require_account(authorization: str) -> str:
    account_id = account_store.account_for_session(_bearer(authorization))
    if account_id is None:
        raise HTTPException(status_code=401, detail="unauthorized")
    return account_id


def _iso(value: float | None) -> str | None:
    if value is None:
        return None
    return (
        datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _account_response(record: AccountRecord, *, token: str | None = None) -> dict:
    """The one response shape every account route returns.

    Deliberately assembled field by field rather than by dumping the dataclass: a new column
    on `accounts` cannot reach a client without someone adding a line here, which is the
    point of the closed-shape test on the iOS side.
    """
    body: dict = {
        "accountId": record.account_id,
        "createdAt": _iso(record.created_at),
        "referralCode": record.referral_code,
        "successfulReferrals": record.successful_referrals,
        "hasClaimedReferral": record.has_claimed_referral,
        "referralGrantExpiresAt": _iso(record.referral_grant_expires_at),
        "entitlements": [
            {
                "platform": e.platform,
                "productId": e.product_id,
                "isLifetime": e.is_lifetime,
                "expiresAt": _iso(e.expires_at),
                "observedAt": _iso(e.observed_at),
            }
            for e in record.entitlements
        ],
    }
    if token is not None:
        body["accountToken"] = token
    return body


class AppleSignInRequest(BaseModel):
    identityToken: str = Field(max_length=8192)
    nonce: str = Field(max_length=256)


@app.post("/v1/account/apple")
async def account_sign_in(body: AppleSignInRequest, request: Request):
    """Exchange an Apple identity token for a BADAN session.

    Creates the account on first sign-in and resolves to the existing one afterwards — the
    client cannot tell which happened and does not need to, because the response is the same
    shape either way.
    """
    client_ip = _client_ip(request)
    if not account_signin_rate_limiter.allow(client_ip):
        log.warning("account_signin_rate_limited=true scope=ip")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    now = time.time()
    keys = await _apple_jwks()
    try:
        identity = verify_identity_token(
            body.identityToken,
            jwks=keys,
            audience=APPLE_AUDIENCE,
            expected_nonce=body.nonce,
            now=now,
        )
    except AppleIdentityError:
        # One forced refetch, then give up. Apple rotates signing keys without warning, and
        # a stale cache is by far the most likely cause of a first failure on an otherwise
        # healthy install — but retrying forever on a genuinely bad token would turn a
        # forgery attempt into unbounded outbound requests to Apple.
        keys = await _apple_jwks(force_refresh=True)
        try:
            identity = verify_identity_token(
                body.identityToken,
                jwks=keys,
                audience=APPLE_AUDIENCE,
                expected_nonce=body.nonce,
                now=now,
            )
        except AppleIdentityError:
            # G8, and more: the token and the reason are both withheld. Telling a caller
            # WHICH check failed would let a forgery be tuned against the checks one by one.
            log.warning("account_signin_rejected=true")
            raise HTTPException(status_code=401, detail="unauthorized") from None

    token, record = account_store.sign_in(identity.subject, now=now)
    log.info("account_signin_accepted=true")
    return JSONResponse(_account_response(record, token=token))


@app.get("/v1/account")
async def account_read(authorization: str = Header(default="")):
    account_id = _require_account(authorization)
    record = account_store.read(account_id)
    if record is None:
        raise HTTPException(status_code=401, detail="unauthorized")
    return JSONResponse(_account_response(record))


class EntitlementItem(BaseModel):
    platform: str = Field(max_length=16)
    productId: str = Field(max_length=MAX_PRODUCT_ID_LENGTH)
    isLifetime: bool
    expiresAt: datetime.datetime | None = None
    observedAt: datetime.datetime


class EntitlementPushRequest(BaseModel):
    entitlements: list[EntitlementItem] = Field(max_length=MAX_ENTITLEMENTS_PER_PUSH)


@app.put("/v1/account/entitlement")
async def account_push_entitlement(
    body: EntitlementPushRequest, authorization: str = Header(default="")
):
    """Record what the calling platform's store says it owns.

    An empty list is a meaningful, expected body — "I looked and there is nothing" — and is
    what lets a cancellation on one platform stop granting on the other. It cannot be
    inferred from silence, because silence is also what an offline device produces.
    """
    account_id = _require_account(authorization)
    now = time.time()

    platforms = {item.platform for item in body.entitlements}
    if not platforms.issubset(PLATFORMS):
        raise HTTPException(status_code=400, detail="unknown platform")
    if len(platforms) > 1:
        # A device may only ever speak for its own platform. Accepting a mixed push would
        # let any signed-in client grant itself a subscription by asserting the other side.
        raise HTTPException(status_code=400, detail="a push may only describe one platform")

    if not body.entitlements:
        # With nothing in the body there is no platform to clear. The client sends the header
        # so an empty push is still unambiguous; a missing header clears nothing rather than
        # guessing, since guessing wrong would revoke the other platform's entitlement.
        raise HTTPException(status_code=400, detail="platform required for an empty push")

    entitlements = [
        Entitlement(
            platform=item.platform,
            product_id=item.productId,
            is_lifetime=item.isLifetime,
            expires_at=item.expiresAt.timestamp() if item.expiresAt else None,
            observed_at=now,
        )
        for item in body.entitlements
    ]
    record = account_store.replace_entitlements(account_id, entitlements, now=now)
    return JSONResponse(_account_response(record))


@app.delete("/v1/account/entitlement/{platform}")
async def account_clear_entitlement(platform: str, authorization: str = Header(default="")):
    """The empty push, as its own route.

    A DELETE with the platform in the path rather than a PUT with an empty body: it makes the
    platform being cleared explicit and un-guessable, which matters because the wrong guess
    here revokes the entitlement the whole feature exists to carry.
    """
    account_id = _require_account(authorization)
    if platform not in PLATFORMS:
        raise HTTPException(status_code=400, detail="unknown platform")
    record = account_store.clear_platform(account_id, platform)
    return JSONResponse(_account_response(record))


class ReferralClaimRequest(BaseModel):
    code: str = Field(max_length=32)


@app.post("/v1/account/referral/claim")
async def account_claim_referral(
    body: ReferralClaimRequest, authorization: str = Header(default="")
):
    account_id = _require_account(authorization)
    if not account_claim_rate_limiter.allow(account_id):
        log.warning("account_claim_rate_limited=true")
        raise HTTPException(status_code=429, detail="rate limit exceeded")

    code = "".join(c for c in body.code.upper() if c in REFERRAL_ALPHABET)
    if len(code) != REFERRAL_CODE_LENGTH:
        raise HTTPException(status_code=422, detail={"reason": "unknown_code"})

    try:
        record = account_store.claim_referral(account_id, code, now=time.time())
    except ReferralRefused as refusal:
        # 409, with the reason code and nothing else. No account id, no referral count, no
        # hint about whether the code exists — a claimer is not entitled to learn anything
        # about the account behind a code they do not hold.
        raise HTTPException(status_code=409, detail={"reason": refusal.reason}) from None
    except LookupError:
        raise HTTPException(status_code=401, detail="unauthorized") from None
    return JSONResponse(_account_response(record))


@app.delete("/v1/account")
async def account_delete(authorization: str = Header(default="")):
    """Delete the account and everything attached to it.

    Required by App Review guideline 5.1.1(v) for any app offering account creation, and
    required by this repository's posture regardless: ADR-0014 reversed "no accounts", and an
    account that cannot be removed would be a far larger reversal than one that can.

    Idempotent by construction — an already-deleted account presents a session that no longer
    resolves, which `_require_account` answers 401 to, and the client treats that as done.
    """
    account_id = _require_account(authorization)
    account_store.delete_account(account_id)
    log.info("account_deleted=true")
    return JSONResponse({"deleted": True})
