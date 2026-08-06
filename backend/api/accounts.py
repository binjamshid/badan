"""Accounts, cross-platform entitlements and referrals (ADR-0014 / D-44).

This module is the server-side half of the reversal ADR-0014 records. Until D-44,
`backend/api` held no accounts and no per-user state at all, and said so in three
places. It now holds exactly this much per user:

    account id · salted hash of Apple's subject · created-at · referral code ·
    who referred them · a per-platform store product id and its expiry · a
    referral-grant expiry · a rewarded-referral count

and nothing else. No name, no email, no Apple identifier in the clear, no device
list, no IP, no request history, and — the one that matters most — **no health
data of any kind**. That Never survives D-44 completely: the account carries a
statement about a *purchase*, never about a body. `test_accounts.py` pins the
column list so a future migration that adds a health-shaped column fails loudly
rather than quietly.

Written in the style of `DeviceTokenStore` above it: SQLite, a lock, a fresh
connection per call, and no ORM.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import sqlite3
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from threading import Lock
from typing import Optional, Sequence

# Mirrors `ReferralPolicy` on the clients exactly. Any change here is a change in three
# places (Swift, Kotlin, Python) and `test_accounts.py` states the constants explicitly so
# a drift shows up as a failing assertion rather than as a code that one platform rejects.
REFERRAL_ALPHABET = "23456789ABCDEFGHJKMNPQRSTWXYZ"
REFERRAL_CODE_LENGTH = 8
REFERRAL_GRANT_DAYS = 30
REFERRAL_MAX_REWARDED = 10
REFERRAL_CLAIM_WINDOW_DAYS = 30

PLATFORMS = frozenset({"ios", "android"})

# Bounds on caller-supplied strings. A product id is a reverse-DNS identifier from a store;
# nothing legitimate approaches these.
MAX_PRODUCT_ID_LENGTH = 128
MAX_ENTITLEMENTS_PER_PUSH = 8

_DAY = 86_400.0


class ReferralRefused(Exception):
    """A claim that failed a rule. `reason` is from a closed set the clients map onto their
    own `ClaimRefusal` cases — never free text, and never anything derived from the other
    account, which the claimer is not entitled to learn about."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class Entitlement:
    platform: str
    product_id: str
    is_lifetime: bool
    expires_at: Optional[float]
    observed_at: float


@dataclass(frozen=True)
class AccountRecord:
    account_id: str
    created_at: float
    referral_code: str
    successful_referrals: int
    has_claimed_referral: bool
    referral_grant_expires_at: Optional[float]
    entitlements: Sequence[Entitlement] = field(default_factory=tuple)


def _hash_token(token: str) -> str:
    """SHA-256 of a raw session token. Same rule as `DeviceTokenStore._hash_token`: only the
    hash is persisted, the raw value is returned to the caller once and never stored."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def load_subject_salt(data_dir: Path) -> bytes:
    """The salt for hashing Apple's subject claim.

    Read from `BADAN_ACCOUNT_HASH_SALT` when set, otherwise from a file in the data dir,
    which is created on first use.

    It MUST be durable, and that is the whole reason this function exists rather than a
    `secrets.token_bytes(32)` at import time: the subject hash is the only way a returning
    user resolves to their existing account. A salt regenerated on restart would silently
    orphan every account in the database on the next deploy — every user would sign in and
    be handed a brand new account, losing the subscription link and the referral code the
    feature exists to provide, with no error anywhere to explain it.
    """
    from_env = os.environ.get("BADAN_ACCOUNT_HASH_SALT")
    if from_env:
        return from_env.encode("utf-8")
    salt_path = data_dir / "account_subject_salt"
    if salt_path.exists():
        return salt_path.read_bytes()
    salt = secrets.token_bytes(32)
    salt_path.write_bytes(salt)
    # Readable only by the service user. `infra/badan-api.service` already runs unprivileged
    # with its own data dir, but a salt is the one file here whose disclosure would let
    # someone test a guessed Apple subject against the accounts table.
    salt_path.chmod(0o600)
    return salt


def hash_subject(subject: str, salt: bytes) -> str:
    """Salted hash of Apple's `sub`.

    HMAC rather than a bare `sha256(salt + subject)`: subjects are attacker-guessable in
    principle (they are opaque, but they are not secret from Apple or from the user's other
    apps on the same team), and HMAC is the construction that is actually designed for
    keyed hashing. The salt never leaves the server, so the accounts table on its own
    cannot be tested against a list of candidate subjects.
    """
    return hmac.new(salt, subject.encode("utf-8"), hashlib.sha256).hexdigest()


def _generate_referral_code() -> str:
    return "".join(secrets.choice(REFERRAL_ALPHABET) for _ in range(REFERRAL_CODE_LENGTH))


class AccountStore:
    """SQLite-backed accounts, sessions, entitlements and referrals."""

    def __init__(self, db_path: Path, *, salt: bytes):
        self._db_path = db_path
        self._salt = salt
        self._lock = Lock()
        with self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS accounts (
                    account_id TEXT PRIMARY KEY,
                    subject_hash TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL,
                    referral_code TEXT NOT NULL UNIQUE,
                    referred_by TEXT,
                    claimed_at REAL,
                    rewarded_referrals INTEGER NOT NULL DEFAULT 0,
                    referral_grant_expires_at REAL
                );

                CREATE TABLE IF NOT EXISTS account_sessions (
                    token_hash TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL,
                    issued_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_sessions_account
                    ON account_sessions (account_id);

                -- One row per (account, platform). A device reports the WHOLE state of its
                -- own platform, so the newest report for a platform replaces the previous
                -- one rather than accumulating. That is what lets a cancellation propagate:
                -- an empty report deletes the row instead of leaving a stale grant standing.
                CREATE TABLE IF NOT EXISTS account_entitlements (
                    account_id TEXT NOT NULL,
                    platform TEXT NOT NULL,
                    product_id TEXT NOT NULL,
                    is_lifetime INTEGER NOT NULL,
                    expires_at REAL,
                    observed_at REAL NOT NULL,
                    PRIMARY KEY (account_id, platform)
                );
                """
            )
            conn.commit()

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path)

    # --- sign-in ------------------------------------------------------------

    def sign_in(self, subject: str, *, now: float) -> tuple[str, AccountRecord]:
        """Resolve an Apple subject to an account, creating one if this is the first time.

        Returns `(raw_session_token, record)`. The token is returned exactly once.
        """
        subject_hash = hash_subject(subject, self._salt)
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT account_id FROM accounts WHERE subject_hash = ?;", (subject_hash,)
            ).fetchone()
            if row:
                account_id = row[0]
            else:
                account_id = uuid.uuid4().hex
                # Retry on the (astronomically unlikely) code collision rather than letting
                # the UNIQUE constraint 500 a user's very first sign-in.
                for _ in range(8):
                    code = _generate_referral_code()
                    try:
                        conn.execute(
                            "INSERT INTO accounts (account_id, subject_hash, created_at, "
                            "referral_code) VALUES (?, ?, ?, ?);",
                            (account_id, subject_hash, now, code),
                        )
                        break
                    except sqlite3.IntegrityError:
                        continue
                else:
                    raise RuntimeError("could not allocate a referral code")

            token = secrets.token_urlsafe(32)
            conn.execute(
                "INSERT INTO account_sessions (token_hash, account_id, issued_at) "
                "VALUES (?, ?, ?);",
                (_hash_token(token), account_id, now),
            )
            conn.commit()
            record = self._read(conn, account_id)
        return token, record

    def account_for_session(self, token: str) -> Optional[str]:
        if not token:
            return None
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT account_id FROM account_sessions WHERE token_hash = ?;",
                (_hash_token(token),),
            ).fetchone()
        return row[0] if row else None

    def read(self, account_id: str) -> Optional[AccountRecord]:
        with self._lock, self._connect() as conn:
            try:
                return self._read(conn, account_id)
            except LookupError:
                return None

    def delete_account(self, account_id: str) -> None:
        """Remove the account and everything attached to it (App Review 5.1.1(v)).

        Three deletes, one transaction. The account row goes LAST so a crash mid-way leaves
        an account with no sessions — recoverable by signing in again — rather than orphaned
        entitlement rows pointing at an account id that no longer exists.
        """
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM account_sessions WHERE account_id = ?;", (account_id,))
            conn.execute(
                "DELETE FROM account_entitlements WHERE account_id = ?;", (account_id,)
            )
            # Anyone this account referred keeps their grant. Revoking premium from a third
            # party because someone else deleted their account would be punishing a user for
            # a stranger's decision. `referred_by` is nulled so no dangling id remains.
            conn.execute(
                "UPDATE accounts SET referred_by = NULL WHERE referred_by = ?;", (account_id,)
            )
            conn.execute("DELETE FROM accounts WHERE account_id = ?;", (account_id,))
            conn.commit()

    # --- entitlements -------------------------------------------------------

    def replace_entitlements(
        self, account_id: str, entitlements: Sequence[Entitlement], *, now: float
    ) -> AccountRecord:
        """Record what one platform reports it owns.

        Every entitlement in a single push must come from the same platform — a client may
        only ever speak for itself, and accepting a push that claims the OTHER platform's
        state would let any signed-in device grant itself a subscription by asserting one.
        """
        platforms = {e.platform for e in entitlements}
        if len(platforms) > 1:
            raise ValueError("a push may only describe one platform")
        with self._lock, self._connect() as conn:
            if platforms:
                platform = next(iter(platforms))
                conn.execute(
                    "DELETE FROM account_entitlements WHERE account_id = ? AND platform = ?;",
                    (account_id, platform),
                )
                # Only the strongest entitlement per platform is kept — the store may report
                # several during an upgrade (an old monthly and a new yearly briefly overlap),
                # and the account only needs to know that the platform is entitled and until
                # when.
                best = max(
                    entitlements,
                    key=lambda e: (e.is_lifetime, e.expires_at or 0.0),
                )
                conn.execute(
                    "INSERT INTO account_entitlements (account_id, platform, product_id, "
                    "is_lifetime, expires_at, observed_at) VALUES (?, ?, ?, ?, ?, ?);",
                    (
                        account_id,
                        best.platform,
                        best.product_id,
                        1 if best.is_lifetime else 0,
                        best.expires_at,
                        now,
                    ),
                )
            record = self._read(conn, account_id)
            conn.commit()
        return record

    def clear_platform(self, account_id: str, platform: str) -> AccountRecord:
        """An empty push: this platform looked and owns nothing."""
        with self._lock, self._connect() as conn:
            conn.execute(
                "DELETE FROM account_entitlements WHERE account_id = ? AND platform = ?;",
                (account_id, platform),
            )
            record = self._read(conn, account_id)
            conn.commit()
        return record

    # --- referrals ----------------------------------------------------------

    def claim_referral(self, account_id: str, code: str, *, now: float) -> AccountRecord:
        """Redeem someone else's code.

        Every rule the clients pre-check is re-checked here, because a client's answer about
        its own eligibility is worth nothing. Both grants are applied in one transaction: a
        claim that rewarded the referee but not the referrer (or the reverse) would be a
        silent, unauditable inconsistency that no later request could detect.
        """
        with self._lock, self._connect() as conn:
            me = conn.execute(
                "SELECT referral_code, created_at, referred_by, referral_grant_expires_at "
                "FROM accounts WHERE account_id = ?;",
                (account_id,),
            ).fetchone()
            if me is None:
                raise LookupError(account_id)
            my_code, created_at, referred_by, my_grant = me

            if referred_by is not None:
                raise ReferralRefused("already_claimed")
            if hmac.compare_digest(code, my_code):
                raise ReferralRefused("own_code")
            if (now - created_at) >= REFERRAL_CLAIM_WINDOW_DAYS * _DAY:
                raise ReferralRefused("window_closed")

            referrer = conn.execute(
                "SELECT account_id, rewarded_referrals, referral_grant_expires_at "
                "FROM accounts WHERE referral_code = ?;",
                (code,),
            ).fetchone()
            if referrer is None:
                # Deliberately the same reason an own-code claim would NOT produce: an
                # unknown code is indistinguishable from a malformed one to the caller, so
                # a code cannot be probed for existence by watching which error comes back.
                raise ReferralRefused("unknown_code")
            referrer_id, rewarded, referrer_grant = referrer

            conn.execute(
                "UPDATE accounts SET referred_by = ?, claimed_at = ?, "
                "referral_grant_expires_at = ? WHERE account_id = ?;",
                (referrer_id, now, _extend(my_grant, now), account_id),
            )
            # The referrer's reward stops accruing past the cap, but the claim still lands
            # and the referee still gets their side. Refusing the claim outright would
            # punish the new user for the popularity of whoever invited them.
            if rewarded < REFERRAL_MAX_REWARDED:
                conn.execute(
                    "UPDATE accounts SET rewarded_referrals = rewarded_referrals + 1, "
                    "referral_grant_expires_at = ? WHERE account_id = ?;",
                    (_extend(referrer_grant, now), referrer_id),
                )
            record = self._read(conn, account_id)
            conn.commit()
        return record

    # --- reads --------------------------------------------------------------

    def _read(self, conn: sqlite3.Connection, account_id: str) -> AccountRecord:
        row = conn.execute(
            "SELECT account_id, created_at, referral_code, rewarded_referrals, "
            "referred_by, referral_grant_expires_at FROM accounts WHERE account_id = ?;",
            (account_id,),
        ).fetchone()
        if row is None:
            raise LookupError(account_id)
        entitlements = tuple(
            Entitlement(
                platform=r[0],
                product_id=r[1],
                is_lifetime=bool(r[2]),
                expires_at=r[3],
                observed_at=r[4],
            )
            for r in conn.execute(
                "SELECT platform, product_id, is_lifetime, expires_at, observed_at "
                "FROM account_entitlements WHERE account_id = ?;",
                (account_id,),
            ).fetchall()
        )
        return AccountRecord(
            account_id=row[0],
            created_at=row[1],
            referral_code=row[2],
            successful_referrals=row[3],
            has_claimed_referral=row[4] is not None,
            referral_grant_expires_at=row[5],
            entitlements=entitlements,
        )


def _extend(current: Optional[float], now: float) -> float:
    """Add one grant period, stacking from whichever is later — now, or an unexpired grant.

    Stacking from `max(now, current)` rather than from `now` is what makes a second referral
    worth as much as the first. Stacking from `current` alone would let a long-lapsed grant
    resume mid-past and expire immediately.
    """
    base = max(now, current or 0.0)
    return base + REFERRAL_GRANT_DAYS * _DAY
