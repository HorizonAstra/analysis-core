"""
Unit tests for GEOSearcher cache layer (geo_search.py).

All tests run fully offline — no network access.
"""

import os
from datetime import datetime, timedelta

import pytest


# ---------------------------------------------------------------------------
# Basic write / read
# ---------------------------------------------------------------------------

def test_cache_write_then_read(geo_searcher):
    data = [{"geo_id": "GSE123456", "title": "Test Dataset", "organism": "Homo sapiens"}]
    geo_searcher._save_to_cache("test_key", data)
    loaded = geo_searcher._load_from_cache("test_key")
    assert loaded == data


def test_cache_miss_for_nonexistent_key(geo_searcher):
    assert geo_searcher._load_from_cache("nonexistent_key_xyz") is None


def test_cache_overwrites_on_resave(geo_searcher):
    geo_searcher._save_to_cache("overwrite_key", [{"v": 1}])
    geo_searcher._save_to_cache("overwrite_key", [{"v": 2}])
    loaded = geo_searcher._load_from_cache("overwrite_key")
    assert loaded == [{"v": 2}]


# ---------------------------------------------------------------------------
# Expiry
# ---------------------------------------------------------------------------

def test_cache_expired_returns_none(geo_searcher):
    """An entry whose mtime is beyond expiry_days must be treated as a cache miss."""
    data = [{"geo_id": "GSE999999", "title": "Old Dataset"}]
    geo_searcher._save_to_cache("old_key", data)

    # Back-date the file's mtime past the expiry window
    cache_file = geo_searcher.cache_dir / "old_key.json"
    expired_ts = (
        datetime.now() - timedelta(days=geo_searcher.cache_expiry_days + 1)
    ).timestamp()
    os.utime(cache_file, (expired_ts, expired_ts))

    assert geo_searcher._load_from_cache("old_key") is None


def test_cache_valid_within_expiry(geo_searcher):
    """A freshly written entry should still be returned before it expires."""
    data = [{"geo_id": "GSE111111", "title": "Fresh Dataset"}]
    geo_searcher._save_to_cache("fresh_key", data)
    assert geo_searcher._load_from_cache("fresh_key") == data


def test_cache_boundary_expires_at_exactly_expiry_plus_one(geo_searcher):
    """Entry exactly at expiry_days old: still returned; one day over: evicted."""
    data = [{"geo_id": "GSE777777", "title": "Boundary Dataset"}]
    geo_searcher._save_to_cache("boundary_key", data)
    cache_file = geo_searcher.cache_dir / "boundary_key.json"

    # Set mtime to one minute LESS than expiry_days — should still be valid
    # (cache uses strict ">", so "exactly at expiry" is evicted due to execution latency)
    nearly_expired_ts = (
        datetime.now() - timedelta(days=geo_searcher.cache_expiry_days) + timedelta(minutes=1)
    ).timestamp()
    os.utime(cache_file, (nearly_expired_ts, nearly_expired_ts))
    assert geo_searcher._load_from_cache("boundary_key") == data

    # Set mtime to expiry_days + 1 second past — now evicted
    just_over_ts = (
        datetime.now() - timedelta(days=geo_searcher.cache_expiry_days, seconds=1)
    ).timestamp()
    os.utime(cache_file, (just_over_ts, just_over_ts))
    assert geo_searcher._load_from_cache("boundary_key") is None


# ---------------------------------------------------------------------------
# Cache key generation
# ---------------------------------------------------------------------------

def test_cache_key_sanitises_special_chars(geo_searcher):
    """Special characters in the query should not create invalid filenames."""
    key = geo_searcher._get_cache_key("melanoma & visium (human)", "Homo sapiens")
    # Must be a valid POSIX filename component (no slashes, no spaces)
    assert "/" not in key
    assert " " not in key
    assert len(key) > 0


def test_separate_queries_produce_different_keys(geo_searcher):
    k1 = geo_searcher._get_cache_key("breast cancer", None)
    k2 = geo_searcher._get_cache_key("melanoma", None)
    assert k1 != k2


def test_organism_filter_changes_key(geo_searcher):
    k_human = geo_searcher._get_cache_key("visium", "Homo sapiens")
    k_mouse = geo_searcher._get_cache_key("visium", "Mus musculus")
    k_none = geo_searcher._get_cache_key("visium", None)
    assert k_human != k_mouse
    assert k_human != k_none
