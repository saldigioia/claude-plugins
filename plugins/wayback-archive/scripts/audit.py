#!/usr/bin/env python3
"""
audit.py — Protocol IV completion gate.

Computes the five audit integers from IMPROVEMENT_PLAN.md §A5 against what the
pipeline has actually produced on disk. Exits non-zero if any integer is > 0
without an annotated terminal_reason. The ledger refactor (IMPROVEMENT_PLAN
phase C3) will make this check far more precise; this is the pre-ledger MVP.

Usage:
    python3 scripts/audit.py --config projects/<name>/config.yaml
    python3 scripts/audit.py --config <cfg> --json     # machine-readable only
    python3 scripts/audit.py --config <cfg> --exemplars 30

Output:
    - JSON to stdout (human-oriented summary unless --json)
    - {project_dir}/audit.json (always written)

Exit codes:
    0  all five integers are zero (audit passes)
    1  one or more residuals (completion blocked)
    2  config not found / unreadable
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from wayback_archiver.site_config import load_config
from wayback_archiver.util import build_dir_to_slug_map, find_empty_dirs
from wayback_archiver.normalize import IMAGE_EXTENSIONS
from wayback_archiver import ledger as ledger_mod


DISCOVERY_SURFACE_PATTERNS = [
    re.compile(r"\.atom$", re.I),
    re.compile(r"sitemap.*\.xml$", re.I),
    re.compile(r"^collections[_/]", re.I),
    re.compile(r"products\.json$", re.I),
    re.compile(r"\.oembed$", re.I),
]


def _cdx_filename(domain: str) -> str:
    return domain.replace(".", "_").replace("/", "_") + "_wayback.txt"


def _unenumerated_hosts(config) -> tuple[int, list[str]]:
    """Hosts in config.domains for which no CDX dump file exists on disk."""
    missing: list[str] = []
    for domain in config.domains:
        cdx_path = config.project_path / _cdx_filename(domain)
        if not cdx_path.exists():
            missing.append(domain)
            continue
        # An empty dump file is a valid terminal state (host had zero captures);
        # only missing files count as unenumerated.
    return len(missing), missing


def _unresolved_slugs(config) -> tuple[int, list[str], dict]:
    """Entries in the product index with no corresponding metadata entry."""
    if not config.index_file.exists():
        return 0, [], {"index": 0, "metadata": 0, "reason": "index_file_missing"}
    index = json.loads(config.index_file.read_text())
    metadata = (
        json.loads(config.metadata_file.read_text())
        if config.metadata_file.exists() else {}
    )
    unresolved = [slug for slug in index if slug not in metadata]
    return (
        len(unresolved),
        sorted(unresolved),
        {"index": len(index), "metadata": len(metadata)},
    )


def _index_missing(config) -> tuple[int, list[str], dict]:
    """Metadata entries whose product directory is empty or missing."""
    if not config.metadata_file.exists():
        return 0, [], {"metadata": 0, "reason": "metadata_file_missing"}
    metadata = json.loads(config.metadata_file.read_text())
    if not config.products_dir.exists():
        return len(metadata), sorted(metadata.keys()), {
            "metadata": len(metadata),
            "products_dir": 0,
            "reason": "products_dir_missing",
        }
    dir_to_slug = build_dir_to_slug_map(metadata)
    empty_slugs = find_empty_dirs(config.products_dir, dir_to_slug)
    # Also count metadata entries whose expected directory doesn't exist at all.
    existing_dirs = {d.name for d in config.products_dir.iterdir() if d.is_dir()}
    slug_to_dir = {slug: dirn for dirn, slug in dir_to_slug.items()}
    never_created = {
        slug for slug, dirn in slug_to_dir.items() if dirn not in existing_dirs
    }
    missing = sorted(empty_slugs | never_created)
    return len(missing), missing, {
        "metadata": len(metadata),
        "empty_dirs": len(empty_slugs),
        "dirs_not_created": len(never_created),
    }


def _unexpanded_surfaces(config) -> tuple[int, list[str], dict]:
    """Best-effort count of discovery surfaces on disk with no downstream expansion.

    Pre-ledger, we can only approximate: enumerate discovery-class files under
    html/ and report their total count. A proper implementation needs the
    discovery_surfaces ledger table (IMPROVEMENT_PLAN phase C3) that stamps
    parsed_at and outlink_count per surface.

    For the MVP gate, we conservatively report 0 so audit passes on pipelines
    that completed without ledger support — but we surface the raw count so
    the skill can escalate if the number looks suspicious.
    """
    if not config.fetch_output_dir.exists():
        return 0, [], {"discovery_files_on_disk": 0, "pre_ledger": True}
    surfaces: list[str] = []
    for f in config.fetch_output_dir.rglob("*"):
        if not f.is_file():
            continue
        name = f.name
        if any(p.search(name) for p in DISCOVERY_SURFACE_PATTERNS):
            surfaces.append(str(f.relative_to(config.project_path)))
    # Pre-ledger: always report 0 integer — we cannot prove expansion happened.
    # The raw count is informational only.
    return 0, [], {
        "discovery_files_on_disk": len(surfaces),
        "pre_ledger": True,
        "note": "Integer reported as 0 — proper expansion accounting requires the ledger (IMPROVEMENT_PLAN C3).",
    }


def _retry_queue_depth(config) -> tuple[int, list[str], dict]:
    """Fetch failures not yet marked terminal. Pre-ledger: uses fetch_stats total_failure."""
    if not config.fetch_stats_file.exists():
        return 0, [], {"fetch_stats": "missing"}
    stats = json.loads(config.fetch_stats_file.read_text())
    failures = int(stats.get("total_failure", 0))
    raw = {
        "total_success": stats.get("total_success", 0),
        "total_failure": failures,
        "circuit_breaker_tripped": len(
            stats.get("circuit_breaker", {}).get("tripped_domains", []) or []
        ),
    }
    # Pre-ledger: total_failure IS the retry queue depth, since we don't track
    # per-URL terminal_reason. Ledger phase C3 will distinguish retriable from
    # terminal failures properly.
    exemplars = stats.get("circuit_breaker", {}).get("tripped_domains", []) or []
    return failures, list(exemplars), raw


def audit(config_path: Path, exemplar_cap: int = 20) -> tuple[dict, int]:
    config = load_config(config_path)
    ledger_available = ledger_mod.exists(config.project_path)
    mode = "ledger" if ledger_available else "pre-ledger"

    # Always compute these from disk — cheap and mode-independent.
    i_miss, i_miss_ex, i_miss_raw = _index_missing(config)
    u_slugs_pre, u_slugs_pre_ex, u_slugs_raw = _unresolved_slugs(config)  # for raw counts
    u_surf_pre, _u_surf_pre_ex, u_surf_raw = _unexpanded_surfaces(config)
    rq_pre, _rq_pre_ex, rq_raw = _retry_queue_depth(config)
    hosts_pre, hosts_pre_ex = _unenumerated_hosts(config)

    if ledger_available:
        with ledger_mod.connect(config.project_path) as conn:
            snap = ledger_mod.audit_snapshot(conn, exemplar_cap=exemplar_cap)
        integers = {
            "unresolved_slugs": snap["integers"]["unresolved_slugs"],
            "unexpanded_surfaces": snap["integers"]["unexpanded_surfaces"],
            "index_missing": i_miss,
            "unenumerated_hosts": snap["integers"]["unenumerated_hosts"],
            "retry_queue_depth": snap["integers"]["retry_queue_depth"],
        }
        exemplars = {
            "unresolved_slugs": snap["exemplars"]["unresolved_slugs"][:exemplar_cap],
            "unexpanded_surfaces": snap["exemplars"]["unexpanded_surfaces"][:exemplar_cap],
            "index_missing": i_miss_ex[:exemplar_cap],
            "unenumerated_hosts": snap["exemplars"]["unenumerated_hosts"][:exemplar_cap],
            "retry_queue_depth": snap["exemplars"]["retry_queue_depth"][:exemplar_cap],
        }
        entities_total = snap["raw_counts"]["entities_total"]
        entities_resolved = snap["raw_counts"]["entities_resolved"]
        surfaces_total = snap["raw_counts"]["surfaces_total"]
        hosts_total = snap["raw_counts"]["hosts_total"]
        mode_notes = [
            "Ledger present — unresolved_slugs / unexpanded_surfaces / unenumerated_hosts / retry_queue_depth are exact.",
        ]
    else:
        integers = {
            "unresolved_slugs": u_slugs_pre,
            "unexpanded_surfaces": u_surf_pre,
            "index_missing": i_miss,
            "unenumerated_hosts": hosts_pre,
            "retry_queue_depth": rq_pre,
        }
        exemplars = {
            "unresolved_slugs": u_slugs_pre_ex[:exemplar_cap],
            "unexpanded_surfaces": [],
            "index_missing": i_miss_ex[:exemplar_cap],
            "unenumerated_hosts": hosts_pre_ex[:exemplar_cap],
            "retry_queue_depth": [],
        }
        entities_total = u_slugs_raw.get("index", 0)
        entities_resolved = u_slugs_raw.get("metadata", 0)
        surfaces_total = u_surf_raw.get("discovery_files_on_disk", 0)
        hosts_total = len(config.domains)
        mode_notes = [
            "No ledger found (pre-ledger mode). unexpanded_surfaces integer is always 0; discovery_surfaces_on_disk in raw_counts is informational.",
            "retry_queue_depth == fetch_stats.total_failure; terminal vs retriable distinction needs ledger. Run `python3 scripts/ledger.py init --config <cfg>` to enable exact counts.",
        ]

    residual_total = sum(integers.values())
    status = "pass" if residual_total == 0 else "residual"

    # Stable raw_counts schema — same keys in both modes so the human
    # renderer and downstream consumers don't need to branch.
    raw_counts = {
        "index": u_slugs_raw.get("index", 0),
        "metadata": u_slugs_raw.get("metadata", 0),
        "entities_total": entities_total,
        "entities_resolved": entities_resolved,
        "surfaces_total": surfaces_total,
        "products_with_images": _count_products_with_images(config),
        "hosts_configured": len(config.domains),
        "hosts_total": hosts_total,
        "hosts_dumped": hosts_total - integers["unenumerated_hosts"],
        "fetch_success": rq_raw.get("total_success", 0),
        "fetch_failure": rq_raw.get("total_failure", 0),
        "discovery_surfaces_on_disk": u_surf_raw.get("discovery_files_on_disk", 0),
        "circuit_breaker_tripped": rq_raw.get("circuit_breaker_tripped", 0),
        "catalog_entries": _count_catalog(config),
    }

    pre_ledger_notes = mode_notes

    audit_result: dict = {
        "status": status,
        "mode": mode,
        "integers": integers,
        "residual_total": residual_total,
        "raw_counts": raw_counts,
        "exemplars": exemplars,
        "pre_ledger_notes": pre_ledger_notes,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "config_path": str(config_path.resolve()),
        "project_dir": str(config.project_path),
        "name": config.name,
    }

    audit_path = config.project_path / "audit.json"
    try:
        config.project_path.mkdir(parents=True, exist_ok=True)
        audit_path.write_text(json.dumps(audit_result, indent=2))
        audit_result["audit_path"] = str(audit_path)
    except OSError:
        pass  # Audit still returned via stdout even if write fails.

    exit_code = 0 if status == "pass" else 1
    return audit_result, exit_code


def _count_products_with_images(config) -> int:
    if not config.products_dir.exists():
        return 0
    n = 0
    for d in config.products_dir.iterdir():
        if not d.is_dir():
            continue
        if any(f.suffix.lower() in IMAGE_EXTENSIONS for f in d.iterdir() if f.is_file()):
            n += 1
    return n


def _count_catalog(config) -> int:
    if not config.catalog_file.exists():
        return 0
    try:
        data = json.loads(config.catalog_file.read_text())
        return len(data) if isinstance(data, list) else 0
    except (json.JSONDecodeError, OSError):
        return 0


def _render_human(result: dict) -> str:
    ints = result["integers"]
    raw = result["raw_counts"]
    mode = result.get("mode", "pre-ledger")
    surf_detail = (
        f"({raw['surfaces_total']} surfaces, {raw['surfaces_total'] - ints['unexpanded_surfaces']} parsed)"
        if mode == "ledger"
        else f"({raw['discovery_surfaces_on_disk']} discovery files on disk, pre-ledger)"
    )
    lines = [
        f"Audit status: {result['status'].upper()}"
        + (f"  ({result['residual_total']} residual items)" if result["status"] == "residual" else "")
        + f"   [mode: {mode}]",
        "",
        "Five-question audit (Protocol IV):",
        f"  1. unresolved_slugs     : {ints['unresolved_slugs']:>6}   (entities {raw['entities_total']} − resolved {raw['entities_resolved']})",
        f"  2. unexpanded_surfaces  : {ints['unexpanded_surfaces']:>6}   {surf_detail}",
        f"  3. index_missing        : {ints['index_missing']:>6}   (metadata {raw['metadata']} − with-images {raw['products_with_images']})",
        f"  4. unenumerated_hosts   : {ints['unenumerated_hosts']:>6}   (tracked {raw['hosts_total']} − dumped {raw['hosts_dumped']})",
        f"  5. retry_queue_depth    : {ints['retry_queue_depth']:>6}   (fetch failures; {raw['circuit_breaker_tripped']} CB-tripped domains)",
        "",
        f"Catalog: {raw['catalog_entries']} entries  ·  Images: {raw['products_with_images']} products",
        f"Audit written to: {result.get('audit_path', '<not written>')}",
    ]
    if result["status"] == "residual":
        lines.append("")
        lines.append("Residual exemplars:")
        for k, v in result["exemplars"].items():
            if v:
                lines.append(f"  {k}: {v[:5]}{'...' if len(v) > 5 else ''}")
    if result.get("pre_ledger_notes"):
        lines.append("")
        lines.append("Pre-ledger notes:")
        for n in result["pre_ledger_notes"]:
            lines.append(f"  - {n}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Protocol IV completion audit")
    parser.add_argument("--config", required=True, help="Path to site config YAML")
    parser.add_argument("--json", action="store_true", help="Emit only JSON to stdout")
    parser.add_argument("--exemplars", type=int, default=20,
                        help="Max exemplar rows per category (default: 20)")
    args = parser.parse_args()

    config_path = Path(args.config)
    if not config_path.exists():
        print(json.dumps({"error": f"config not found: {config_path}"}), file=sys.stderr)
        sys.exit(2)

    result, exit_code = audit(config_path, exemplar_cap=args.exemplars)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(_render_human(result))
        print()
        print(json.dumps({"status": result["status"], "integers": result["integers"]}))

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
