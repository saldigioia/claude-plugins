"""Regression tests for the CDN quality-probe wiring.

The probe (tools/cdn/app.sh, 48 host resolvers) was vendored and gated at
publish time by bin/sync-engine.sh, but nothing ever invoked it: no config
template set `cdn_tool`, and the download stage's live-CDN test was the
hardcoded substring "cdn.shopify.com". These tests fail if either half of
that wiring is removed again.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import bootstrap  # noqa: E402
from wayback_archiver.download import has_live_cdn_url  # noqa: E402
from wayback_archiver.site_config import load_config  # noqa: E402

PLATFORMS = ["shopify", "swell", "fourthwall", "adidas", "unknown"]


def test_engine_is_vendored():
    assert bootstrap.CDN_TOOL.exists(), f"vendored engine missing: {bootstrap.CDN_TOOL}"


@pytest.mark.parametrize("platform", PLATFORMS)
def test_template_wires_cdn_tool(platform):
    """Every rendered config points at an engine that exists on disk.

    The path must be absolute: configs live under <projects-root>/<name>/,
    outside the plugin tree, so load_config would resolve a relative path
    against the project dir and miss.
    """
    body = bootstrap.render_config(platform, "t", "T", "t.com", ["t.com"])
    assert "{CDN_TOOL}" not in body, "placeholder left unsubstituted"

    with tempfile.TemporaryDirectory() as d:
        config_path = Path(d) / "config.yaml"
        config_path.write_text(body)
        cfg = load_config(config_path)

    assert cfg.cdn_tool_path is not None, f"{platform}: cdn_tool unset"
    assert cfg.cdn_tool_path.is_absolute()
    assert cfg.cdn_tool_path.exists(), f"{platform}: {cfg.cdn_tool_path} does not exist"


@pytest.mark.parametrize(
    "urls,patterns,expected,reason",
    [
        (["https://cdn.shopify.com/s/files/1/0/products/x.jpg"], None, True, "live shopify"),
        (["https://shop.example.com/cdn/shop/products/x.jpg"], None, True, "shopify custom domain"),
        # These three regressed under the old substring test — a non-Shopify
        # store never reached the probe at all.
        (["https://cdn.swell.store/a/b.jpg"], None, True, "live swell"),
        (["https://imgproxy.fourthwall.com/abc"], None, True, "live fourthwall"),
        (["https://assets.adidas.com/images/x.jpg"], None, True, "live adidas"),
        (
            ["https://web.archive.org/web/2020id_/https://cdn.shopify.com/s/files/1/0/products/x.jpg"],
            None, False, "wayback replay is frozen bytes — nothing to negotiate",
        ),
        (["https://example.com/img.jpg"], None, False, "host has no resolver"),
        ([], None, False, "no urls"),
        (
            ["https://cdn.acme.io/x.jpg"],
            [{"name": "acme", "regex": r"https?://cdn\.acme\.io/"}],
            True, "config-declared CDN pattern",
        ),
    ],
)
def test_has_live_cdn_url(urls, patterns, expected, reason):
    assert has_live_cdn_url(urls, patterns) is expected, reason


def test_empty_config_patterns_fall_back_to_builtins():
    """The generic template ships `cdn_patterns: []`.

    An empty list must not mean "no CDN ever" — otherwise every
    unrecognized-platform store silently skips the probe.
    """
    assert has_live_cdn_url(["https://cdn.shopify.com/s/files/1/0/products/x.jpg"], []) is True


def test_uncompilable_pattern_does_not_raise():
    assert has_live_cdn_url(["https://x.com/a.jpg"], [{"name": "bad", "regex": "([unclosed"}]) is False
