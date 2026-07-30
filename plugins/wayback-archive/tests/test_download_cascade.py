"""Tests for `download_cascade` — the config field that used to do nothing.

It was parsed into SiteConfig and read by no consumer, while templates and
download.py's docstring advertised five strategies over a three-strategy
implementation (`exhaustive` and `asset_rescue` were never written). These
tests pin the field to reality: only implemented names survive load, and the
surviving names genuinely select behaviour.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import bootstrap  # noqa: E402
from wayback_archiver import download as dl  # noqa: E402
from wayback_archiver.site_config import (  # noqa: E402
    DEFAULT_DOWNLOAD_CASCADE, IMPLEMENTED_DOWNLOAD_STRATEGIES,
    _validate_cascade, load_config,
)

PLATFORMS = ["shopify", "swell", "fourthwall", "adidas", "unknown"]


# ── validation ───────────────────────────────────────────────────────────────

def test_phantom_strategies_are_dropped():
    """`exhaustive` and `asset_rescue` shipped for a long time without existing."""
    got = _validate_cascade(
        ["live_cdn", "exhaustive", "direct_fetch", "asset_rescue"], "test")
    assert got == ["live_cdn", "direct_fetch"]


def test_dropping_is_warned_not_silent(caplog):
    with caplog.at_level("WARNING"):
        _validate_cascade(["direct_fetch", "asset_rescue"], "cfg.yaml")
    assert "asset_rescue" in caplog.text
    assert "unimplemented" in caplog.text


def test_all_unknown_falls_back_to_default(caplog):
    with caplog.at_level("WARNING"):
        got = _validate_cascade(["exhaustive", "asset_rescue"], "cfg.yaml")
    assert got == DEFAULT_DOWNLOAD_CASCADE
    assert "no implemented strategies" in caplog.text


def test_order_is_preserved():
    assert _validate_cascade(["wayback_cdx_best", "live_cdn"], "t") == \
        ["wayback_cdx_best", "live_cdn"]


# ── templates match reality ──────────────────────────────────────────────────

@pytest.mark.parametrize("platform", PLATFORMS)
def test_template_cascade_survives_validation_unchanged(platform):
    """A shipped template must not name anything that gets dropped at load."""
    body = bootstrap.render_config(platform, "t", "T", "t.com", ["t.com"])
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "config.yaml"
        p.write_text(body)
        cfg = load_config(p)
    assert cfg.download_cascade, f"{platform}: empty cascade"
    assert all(s in IMPLEMENTED_DOWNLOAD_STRATEGIES for s in cfg.download_cascade)


@pytest.mark.parametrize("platform", PLATFORMS)
def test_every_template_enables_the_quality_probe(platform):
    """Regression: only the shopify template used to declare live_cdn.

    Once the cascade actually gated behaviour, that would have disabled the
    48-resolver probe for every non-Shopify store — silently undoing the
    wiring fix. The runtime `has_live_cdn_url()` check is what decides whether
    the probe fires; the cascade must not pre-empt it.
    """
    body = bootstrap.render_config(platform, "t", "T", "t.com", ["t.com"])
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "config.yaml"
        p.write_text(body)
        cfg = load_config(p)
    assert "live_cdn" in cfg.download_cascade, f"{platform} would skip the CDN probe"


# ── the cascade selects behaviour ────────────────────────────────────────────

def _run(cascade, *, direct_ok=True, wayback_ok=True, tmp=None):
    """Drive download_product_images with every network call stubbed."""
    calls = {"cdn_tool": 0, "direct": 0, "wayback": 0}

    def fake_cdn(urls, dest_dir, cdn_tool, timeout=120):
        calls["cdn_tool"] += 1
        (dest_dir / "probe.jpg").write_bytes(b"x" * 900)
        return []

    def fake_direct(url, dest, session):
        calls["direct"] += 1
        if direct_ok:
            dest.write_bytes(b"x" * 900)
        return direct_ok

    def fake_find(url, session):
        return "https://web.archive.org/web/1id_/" + url

    def fake_wb(url, dest, session):
        calls["wayback"] += 1
        if wayback_ok:
            dest.write_bytes(b"x" * 900)
        return wayback_ok

    tool = tmp / "app.sh"
    tool.write_text("#!/bin/sh\n")

    with patch.object(dl, "download_via_cdn_tool", fake_cdn), \
         patch.object(dl, "download_direct", fake_direct), \
         patch.object(dl, "find_best_wayback_url", fake_find), \
         patch.object(dl, "download_wayback_image", fake_wb), \
         patch.object(dl.time, "sleep", lambda *_: None):
        res = dl.download_product_images(
            "slug", ["https://cdn.shopify.com/s/files/1/0/products/a.jpg"],
            tmp / "out", MagicMock(), cdn_tool=tool, is_live_cdn=True,
            cascade=cascade,
        )
    return res, calls


def test_dropping_live_cdn_skips_the_probe(tmp_path):
    _, calls = _run(["direct_fetch", "wayback_cdx_best"], tmp=tmp_path)
    assert calls["cdn_tool"] == 0
    assert calls["direct"] == 1


def test_including_live_cdn_runs_the_probe(tmp_path):
    _, calls = _run(["live_cdn", "direct_fetch"], tmp=tmp_path)
    assert calls["cdn_tool"] == 1


def test_dropping_wayback_makes_a_failed_fetch_terminal(tmp_path):
    res, calls = _run(["direct_fetch"], direct_ok=False, tmp=tmp_path)
    assert calls["wayback"] == 0, "wayback ran despite being excluded"
    assert res["failed"] == 1


def test_wayback_fallback_runs_when_direct_fails(tmp_path):
    res, calls = _run(["direct_fetch", "wayback_cdx_best"], direct_ok=False, tmp=tmp_path)
    assert calls["wayback"] == 1
    assert res["downloaded"] == 1


def test_wayback_win_is_reported(tmp_path):
    """The old code inferred strategy from dest.exists(), always true after a
    success — so `wayback_cdx_best` could never appear in strategies_used."""
    res, _ = _run(["direct_fetch", "wayback_cdx_best"], direct_ok=False, tmp=tmp_path)
    assert "wayback_cdx_best" in res["strategies_used"]
    assert "direct_fetch" not in res["strategies_used"]


def test_direct_win_is_reported(tmp_path):
    res, _ = _run(["direct_fetch", "wayback_cdx_best"], tmp=tmp_path)
    assert res["strategies_used"] == ["direct_fetch"]


def test_none_cascade_means_everything(tmp_path):
    _, calls = _run(None, tmp=tmp_path)
    assert calls["cdn_tool"] == 1 and calls["direct"] == 1
