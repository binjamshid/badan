"""Unit tests for `SlidingWindowRateLimiter`'s memory behaviour.

The limiting itself is exercised end to end by the endpoint tests. What is covered HERE is
the property those tests cannot see: that the table backing the limiter is bounded.

`badan-api` runs as ONE long-lived uvicorn process (`infra/badan-api.service`, no `--workers`
and no `MemoryMax=`), so every key the limiter keeps is kept until the next deploy. Keyed by
caller IP for `/v1/register` and `/v1/footprints`, and by token hash for `/v1/chat`, an
unevicted key made the abuse control into the thing an abuser could grow — a `defaultdict`
that only ever gained entries.

Run:  python -m pytest tests/ -v   (from backend/api)
"""

from __future__ import annotations

import importlib
import sys
import time

import pytest


@pytest.fixture()
def limiter_class(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")
    monkeypatch.setenv("BADAN_DATA_DIR", str(tmp_path))
    sys.modules.pop("main", None)
    return importlib.import_module("main").SlidingWindowRateLimiter


def test_the_window_still_limits(limiter_class):
    """The bound must not have cost the limiter its actual job."""
    limiter = limiter_class(3, 3600.0)
    assert [limiter.allow("caller") for _ in range(5)] == [True, True, True, False, False]


def test_distinct_keys_have_independent_budgets(limiter_class):
    limiter = limiter_class(1, 3600.0)
    assert limiter.allow("a") is True
    assert limiter.allow("b") is True
    assert limiter.allow("a") is False


def test_keys_do_not_accumulate_without_bound(limiter_class):
    """One key per distinct caller, retained for the life of the process, was the leak. A
    thousand one-shot callers must not leave a thousand entries behind."""
    limiter = limiter_class(5, 3600.0, max_keys=16)
    for i in range(1000):
        limiter.allow(f"198.51.100.{i}")
    assert limiter.tracked_keys() <= 16


def test_an_expired_window_frees_its_key(limiter_class):
    """A key whose window has fully expired carries no information — it is indistinguishable
    from a caller never seen — so retaining it is pure cost."""
    limiter = limiter_class(5, 0.01, max_keys=4)
    for i in range(4):
        assert limiter.allow(f"k{i}") is True
    time.sleep(0.05)

    assert limiter.allow("fresh") is True
    assert limiter.tracked_keys() == 1, "expired keys survived a new arrival"


def test_a_full_table_still_admits_a_new_caller(limiter_class):
    """Eviction, not refusal. Refusing once the table is full would let anyone with a spread
    of source addresses lock every other caller out — a cost control turned into a
    denial-of-service lever."""
    limiter = limiter_class(5, 3600.0, max_keys=4)
    for i in range(4):
        assert limiter.allow(f"k{i}") is True

    assert limiter.allow("newcomer") is True
    assert limiter.tracked_keys() == 4


def test_eviction_takes_the_least_recently_active_key(limiter_class):
    """The coldest key is the one closest to falling out of its own window anyway, so
    forgiving it costs the least. The key used most recently must survive."""
    limiter = limiter_class(1, 3600.0, max_keys=2)
    assert limiter.allow("old") is True
    assert limiter.allow("hot") is True
    # Touching "hot" again (rejected — its budget is spent) still marks it as active.
    assert limiter.allow("hot") is False

    assert limiter.allow("newcomer") is True
    # "old" was evicted, so its budget is forgiven; "hot" was kept, so its is not.
    assert limiter.allow("hot") is False
    assert limiter.allow("old") is True
