"""Tests for the hunt→wayback-archive handoff (`bootstrap.py --from-recon`).

The contract is `recon.json` schema 1, written by hunt's `scripts/recon.sh`.
What matters here is not that fields copy across, but that the dossier's
*evidence* is respected: wildcard-only hosts dropped, speculation suppressed
when the census is complete, warnings surfaced, and — above all — the weak
built-in enumeration never runs when the stronger census is available.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import bootstrap  # noqa: E402


def make_recon(**over) -> dict:
    d = {
        "schema": 1,
        "tool": "hunt/recon.sh",
        "domain": "mystore.example",
        "run": "2026-07-30T00:00:00Z",
        "front_door": {"class": "DEAD", "detail": "front door 404"},
        "branches": ["C"],
        "storefront": {
            "detected": True,
            "platform": "shopify",
            "evidence_source": "cdx",
            "myshopify_alias": None,
        },
        "warnings": {
            "spa_catch_all": False,
            "wildcard_dns": False,
            "cdx_census_complete": True,
        },
        "archive": {"cdx_rows": 400, "cdx_image_rows": 120, "cdx_pages_reported": "1"},
        "probe_host": "mystore.example",
        "hosts": [
            {"host": "mystore.example", "evidence": ["cdx", "dns"]},
            {"host": "shop.mystore.example", "evidence": ["cdx"]},
            {"host": "old.mystore.example", "evidence": ["ct"]},
        ],
    }
    d.update(over)
    return d


def run(recon, **kw):
    """bootstrap() with every network path blocked."""
    with patch.object(bootstrap, "probe_platform", return_value=bootstrap.PlatformProbe()), \
         patch.object(bootstrap, "enumerate_hosts_via_wayback",
                      side_effect=AssertionError(
                          "the weak limit=5000 sample must not run when a dossier is supplied")):
        return bootstrap.bootstrap(kw.pop("raw_input", ""), dry_run=True, recon=recon, **kw)


# ── schema validation ────────────────────────────────────────────────────────

def test_missing_file(tmp_path):
    with pytest.raises(bootstrap.ReconError, match="no recon dossier"):
        bootstrap.load_recon(tmp_path / "nope.json")


def test_unparseable(tmp_path):
    p = tmp_path / "recon.json"
    p.write_text("{not json")
    with pytest.raises(bootstrap.ReconError, match="cannot parse"):
        bootstrap.load_recon(p)


def test_unsupported_schema_names_the_fix(tmp_path):
    p = tmp_path / "recon.json"
    p.write_text(json.dumps({"schema": 99, "domain": "x.com"}))
    with pytest.raises(bootstrap.ReconError, match="Upgrade whichever"):
        bootstrap.load_recon(p)


def test_roundtrip(tmp_path):
    p = tmp_path / "recon.json"
    p.write_text(json.dumps(make_recon()))
    assert bootstrap.load_recon(p)["domain"] == "mystore.example"


# ── evidence handling ────────────────────────────────────────────────────────

def test_wildcard_only_hosts_are_dropped():
    """Under a wildcard zone every name resolves — that attests to nothing."""
    recon = make_recon()
    recon["hosts"].append({"host": "ghost.mystore.example", "evidence": ["dns-wildcard"]})
    trusted, rejected = bootstrap.hosts_from_recon(recon)
    assert "ghost.mystore.example" not in trusted
    assert rejected == ["ghost.mystore.example"]


def test_rejected_hosts_are_reported_not_silently_dropped():
    recon = make_recon(warnings={"wildcard_dns": True, "spa_catch_all": False,
                                 "cdx_census_complete": True})
    recon["hosts"].append({"host": "ghost.mystore.example", "evidence": ["dns-wildcard"]})
    plan = run(recon)
    assert plan["recon"]["hosts_rejected_no_evidence"] == ["ghost.mystore.example"]
    assert any("Dropped 1 host" in n for n in plan["notes"])
    assert any("WILDCARD DNS" in n for n in plan["notes"])


def test_complete_census_suppresses_speculation():
    """A complete census already lists every archived subdomain.

    Guessed hosts would dump empty and sit in the ledger inflating
    `unenumerated_hosts` for the rest of the run.
    """
    plan = run(make_recon())
    assert plan["hosts_speculative"] == []
    assert not any(h.startswith("checkout.") for h in plan["hosts"])
    assert any("COMPLETE" in n for n in plan["notes"])


def test_incomplete_census_keeps_speculation():
    recon = make_recon(warnings={"spa_catch_all": False, "wildcard_dns": False,
                                 "cdx_census_complete": False})
    plan = run(recon)
    assert "checkout.mystore.example" in plan["hosts"]
    assert any("truncated or absent" in n for n in plan["notes"])


def test_myshopify_alias_is_carried_over():
    recon = make_recon()
    recon["storefront"]["myshopify_alias"] = "mystore-shop.myshopify.com"
    plan = run(recon)
    assert "mystore-shop.myshopify.com" in plan["hosts"]


def test_spa_catch_all_warning_propagates():
    recon = make_recon(warnings={"spa_catch_all": True, "wildcard_dns": False,
                                 "cdx_census_complete": True})
    plan = run(recon)
    assert plan["recon"]["spa_catch_all"] is True
    assert any("CATCH-ALL" in n for n in plan["notes"])


# ── platform resolution ──────────────────────────────────────────────────────

def test_recon_platform_used_when_probe_finds_nothing():
    plan = run(make_recon())
    assert plan["platform"] == "shopify"
    assert plan["template_used"] == "_template_shopify.yaml"


def test_live_probe_beats_recon_verdict():
    """A store can migrate platforms before it dies.

    Recon's strongest signal is the archived record, which may name the
    platform of an earlier era. A probe that actually matched is closer to
    the truth and must win.
    """
    probe = bootstrap.PlatformProbe(platform="swell", confidence=0.9,
                                    sample_host="mystore.example", sample_source="wayback")
    with patch.object(bootstrap, "probe_platform", return_value=probe), \
         patch.object(bootstrap, "enumerate_hosts_via_wayback",
                      side_effect=AssertionError("must not run")):
        plan = bootstrap.bootstrap("", dry_run=True, recon=make_recon())
    assert plan["platform"] == "swell", "recon verdict must not override a real probe hit"


def test_generic_storefront_verdict_does_not_pick_a_template():
    """`generic` means "a store, platform unknown" — not a template name."""
    recon = make_recon()
    recon["storefront"]["platform"] = "generic"
    plan = run(recon)
    assert plan["platform"] == "unknown"
    assert plan["template_used"] == "_template_generic.yaml"


# ── target derivation ────────────────────────────────────────────────────────

def test_dossier_alone_is_a_complete_invocation():
    plan = run(make_recon())
    assert plan["apex"] == "mystore.example"


def test_extra_input_seeds_merge_with_dossier():
    plan = run(make_recon(), raw_input="extra.mystore.example")
    assert "extra.mystore.example" in plan["hosts"]
