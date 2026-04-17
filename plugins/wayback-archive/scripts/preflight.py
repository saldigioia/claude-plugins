#!/usr/bin/env python3
"""
preflight.py — pre-flight validation for the wayback-archive pipeline.

Runs before the expensive stages (cdx_dump, fetch, download) to catch
misconfiguration that would otherwise cost 20+ minutes of wasted work.
Validates:

  - Python version (3.10+)
  - Required packages importable (requests, aiohttp, yaml, dotenv)
  - Config file loads cleanly via wayback_archiver.site_config
  - tools/wayback_cdx tool is importable
  - Oxylabs proxy creds present when cdx_dump_proxy_mode != "off"
  - archive.org CDX Server is reachable (HEAD + rough latency)
  - Project directory's filesystem has at least MIN_DISK_GB free

Usage:
    python3 scripts/preflight.py --config <cfg>
    python3 scripts/preflight.py --config <cfg> --json

Exit codes:
    0  ready (all checks pass, or only "warn" checks failed)
    1  error (at least one blocking check failed)
    2  config not found / unreadable
"""
from __future__ import annotations

import argparse
import importlib
import json
import os
import shutil
import socket
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
sys.path.insert(0, str(REPO_ROOT))

from wayback_archiver.env import load_env

load_env()  # ensure creds from tools/.env are visible before we check for them


MIN_PYTHON = (3, 10)
MIN_DISK_GB = 2.0  # Enough for a small-to-mid catalog; warn below this
REACHABILITY_HOST = "web.archive.org"
REACHABILITY_PATH = "/cdx/search/cdx?url=example.com&limit=1"
REACHABILITY_TIMEOUT = 10.0


def _check(name: str, status: str, detail: str = "", blocking: bool = False) -> dict:
    return {"name": name, "status": status, "detail": detail, "blocking": blocking}


# ── Individual checks ────────────────────────────────────────────────────────

def check_python_version() -> dict:
    v = sys.version_info
    if v >= MIN_PYTHON:
        return _check("python_version", "ok", f"Python {v.major}.{v.minor}.{v.micro}")
    return _check(
        "python_version", "error",
        f"Python {v.major}.{v.minor} < required {MIN_PYTHON[0]}.{MIN_PYTHON[1]}",
        blocking=True,
    )


def check_imports() -> dict:
    required = ["requests", "aiohttp", "yaml", "dotenv"]
    missing: list[str] = []
    for mod in required:
        try:
            importlib.import_module(mod)
        except ImportError:
            missing.append(mod)
    if not missing:
        return _check("imports", "ok", f"all required: {', '.join(required)}")
    return _check(
        "imports", "error",
        f"missing: {', '.join(missing)}. Run: pip install -r requirements.txt",
        blocking=True,
    )


def check_config(config_path: Path) -> tuple[dict, object | None]:
    if not config_path.exists():
        return _check("config", "error", f"not found: {config_path}", blocking=True), None
    try:
        from wayback_archiver.site_config import load_config
        cfg = load_config(config_path)
    except Exception as e:  # noqa: BLE001
        return _check("config", "error", f"{type(e).__name__}: {e}", blocking=True), None
    return _check("config", "ok", f"loaded: {cfg.name} ({len(cfg.domains)} domains)"), cfg


def check_cdx_tool() -> dict:
    cdx_dir = REPO_ROOT / "tools"
    cdx_mod = cdx_dir / "wayback_cdx" / "__init__.py"
    if not cdx_mod.exists():
        return _check(
            "cdx_tool", "error",
            f"wayback_cdx module not found under {cdx_dir}", blocking=True,
        )
    # Try to import it — catches syntax errors / missing transient deps.
    try:
        old_path = list(sys.path)
        sys.path.insert(0, str(cdx_dir))
        import wayback_cdx  # noqa: F401
    except Exception as e:  # noqa: BLE001
        sys.path[:] = old_path
        return _check("cdx_tool", "error", f"import failed: {type(e).__name__}: {e}", blocking=True)
    finally:
        sys.path[:] = old_path
    return _check("cdx_tool", "ok", f"importable from {cdx_dir}")


def check_proxy_creds(cfg) -> dict:
    mode = str(cfg._raw.get("cdx_dump_proxy_mode", "auto")).lower()
    if mode == "off":
        return _check("proxy_creds", "ok", "proxy disabled in config (cdx_dump_proxy_mode=off)")

    isp_set = bool(os.environ.get("OXY_ISP_USER") and os.environ.get("OXY_ISP_PASS"))
    dc_set = bool(os.environ.get("OXY_DC_USER") and os.environ.get("OXY_DC_PASS"))
    # Legacy env-var names referenced in README.md
    legacy_isp = bool(os.environ.get("OXYLABS_ISP_USER") and os.environ.get("OXYLABS_ISP_PASS"))
    any_set = isp_set or dc_set or legacy_isp

    if any_set:
        parts = []
        if isp_set: parts.append("ISP")
        if dc_set: parts.append("DC")
        if legacy_isp: parts.append("legacy-ISP")
        return _check("proxy_creds", "ok", f"found: {', '.join(parts)}")

    return _check(
        "proxy_creds", "warn",
        "no Oxylabs creds found (OXY_ISP_USER/_PASS or OXY_DC_USER/_PASS). "
        "CDX dump and proxied fetch will fall back to direct requests — works "
        "for small sites but hits Wayback rate limits quickly. Copy "
        "tools/.env.example to tools/.env and fill in.",
    )


def check_archive_reachable() -> dict:
    try:
        import requests
        from wayback_archiver.http_client import DEFAULT_HEADERS
    except ImportError:
        return _check("archive_reachable", "warn", "requests not available to test reachability")
    url = f"https://{REACHABILITY_HOST}{REACHABILITY_PATH}"
    t0 = time.time()
    try:
        r = requests.head(url, headers=DEFAULT_HEADERS, timeout=REACHABILITY_TIMEOUT, allow_redirects=True)
    except (requests.ConnectionError, socket.gaierror) as e:
        return _check(
            "archive_reachable", "error",
            f"cannot reach {REACHABILITY_HOST}: {type(e).__name__}", blocking=True,
        )
    except requests.RequestException as e:
        return _check("archive_reachable", "warn", f"{type(e).__name__}: {e}")
    elapsed_ms = int((time.time() - t0) * 1000)
    if r.status_code >= 500:
        return _check(
            "archive_reachable", "warn",
            f"{REACHABILITY_HOST} returned HTTP {r.status_code} ({elapsed_ms} ms) — "
            "may be degraded; pipeline may be slow",
        )
    return _check(
        "archive_reachable", "ok",
        f"{REACHABILITY_HOST} responded {r.status_code} in {elapsed_ms} ms",
    )


def check_disk_space(project_dir: Path) -> dict:
    # Walk up until we find an existing directory (project_dir may not exist yet).
    probe = project_dir
    while not probe.exists() and probe.parent != probe:
        probe = probe.parent
    try:
        stat = shutil.disk_usage(probe)
    except OSError as e:
        return _check("disk_space", "warn", f"could not stat filesystem: {e}")
    free_gb = stat.free / (1024 ** 3)
    if free_gb < MIN_DISK_GB:
        return _check(
            "disk_space", "error",
            f"only {free_gb:.1f} GB free on {probe} — need at least {MIN_DISK_GB:.0f} GB "
            "for a full catalog + images",
            blocking=True,
        )
    if free_gb < MIN_DISK_GB * 5:
        return _check("disk_space", "warn", f"{free_gb:.1f} GB free (tight for large catalogs)")
    return _check("disk_space", "ok", f"{free_gb:.1f} GB free on {probe}")


# ── Orchestration ───────────────────────────────────────────────────────────

def preflight(config_path: Path) -> tuple[dict, int]:
    checks: list[dict] = []

    checks.append(check_python_version())
    checks.append(check_imports())

    cfg_check, cfg = check_config(config_path)
    checks.append(cfg_check)

    checks.append(check_cdx_tool())

    if cfg is not None:
        checks.append(check_proxy_creds(cfg))
        checks.append(check_disk_space(cfg.project_path))

    checks.append(check_archive_reachable())

    errors = [c for c in checks if c["status"] == "error"]
    warns = [c for c in checks if c["status"] == "warn"]
    if errors:
        overall = "error"
    elif warns:
        overall = "warn"
    else:
        overall = "ready"

    result = {
        "status": overall,
        "checks": checks,
        "blocking_errors": sum(1 for c in errors if c["blocking"]),
        "warnings": len(warns),
        "config_path": str(config_path),
    }

    # Write to project_dir if config was loadable
    if cfg is not None:
        try:
            cfg.project_path.mkdir(parents=True, exist_ok=True)
            (cfg.project_path / "preflight.json").write_text(json.dumps(result, indent=2))
            result["preflight_path"] = str(cfg.project_path / "preflight.json")
        except OSError:
            pass

    exit_code = 1 if result["blocking_errors"] else 0
    return result, exit_code


def _render_human(r: dict) -> None:
    symbol = {"ok": "✓", "warn": "!", "error": "✗"}
    print(f"Pre-flight: {r['status'].upper()}")
    if r["status"] != "ready":
        print(f"  {r['blocking_errors']} blocking, {r['warnings']} warning(s)")
    print()
    for c in r["checks"]:
        print(f"  [{symbol.get(c['status'], '?')}] {c['name']:<20} {c['detail']}")
    if r.get("preflight_path"):
        print()
        print(f"Report written to: {r['preflight_path']}")


def main():
    p = argparse.ArgumentParser(description="Wayback-archive pre-flight validation")
    p.add_argument("--config", required=True, help="Path to site config YAML")
    p.add_argument("--json", action="store_true", help="Emit only JSON to stdout")
    args = p.parse_args()

    config_path = Path(args.config)
    result, exit_code = preflight(config_path)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        _render_human(result)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
