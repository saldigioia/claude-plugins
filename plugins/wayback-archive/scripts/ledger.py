#!/usr/bin/env python3
"""
ledger.py — CLI over the archival ledger (IMPROVEMENT_PLAN.md phase C3).

Subcommands:
    init           Create/initialize the ledger DB for a project.
    status         Show row counts per table + the five audit integers.
    audit          Same as `status` but exits non-zero on any residual
                   (so CI or the --auto pipeline can gate on it).
    import-index   Backfill the entities table from a product index JSON.
    import-hosts   Backfill the hosts table from the config's `domains`.
    mark-dumped    Manually stamp `cdx_dumped_at` for a host (e.g. after
                   a CDX dump completed outside the pipeline).
    mark-resolved  Manually stamp `resolved_at` for (slug, host).

Usage:
    python3 scripts/ledger.py <subcmd> --config <cfg> [options]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from wayback_archiver.site_config import load_config
from wayback_archiver import ledger


# ── Helpers ──────────────────────────────────────────────────────────────────

def _load(config_path: Path):
    if not config_path.exists():
        print(json.dumps({"error": f"config not found: {config_path}"}), file=sys.stderr)
        sys.exit(2)
    return load_config(config_path)


def _host_of(url: str) -> str:
    """Best-effort hostname extraction for ledger keys."""
    try:
        h = urlparse(url).hostname or ""
    except ValueError:
        h = ""
    return h.lower().rstrip(".")


# ── init ─────────────────────────────────────────────────────────────────────

def cmd_init(args):
    cfg = _load(Path(args.config))
    path = ledger.init(cfg.project_path)
    print(json.dumps({"status": "ok", "ledger_path": str(path)}))


# ── status / audit ──────────────────────────────────────────────────────────

def cmd_status(args, gate: bool = False):
    cfg = _load(Path(args.config))
    if not ledger.exists(cfg.project_path):
        print(json.dumps({"status": "missing", "ledger_path": str(ledger.ledger_path(cfg.project_path))}))
        sys.exit(2 if gate else 0)

    with ledger.connect(cfg.project_path) as conn:
        snap = ledger.audit_snapshot(conn, exemplar_cap=args.exemplars)

    residual = sum(snap["integers"].values())
    status = "pass" if residual == 0 else "residual"
    result = {
        "status": status,
        "residual_total": residual,
        "ledger_path": str(ledger.ledger_path(cfg.project_path)),
        **snap,
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        _render_human(result)

    if gate:
        sys.exit(0 if status == "pass" else 1)


def _render_human(r: dict) -> None:
    ints = r["integers"]
    raw = r["raw_counts"]
    status = r["status"].upper()
    tail = f"  ({r['residual_total']} residual items)" if r["status"] == "residual" else ""
    print(f"Ledger audit: {status}{tail}")
    print()
    print("Protocol IV five-question audit:")
    print(f"  1. unresolved_slugs     : {ints['unresolved_slugs']:>6}   ({raw['entities_total']} entities total, {raw['entities_resolved']} resolved)")
    print(f"  2. unexpanded_surfaces  : {ints['unexpanded_surfaces']:>6}   ({raw['surfaces_total']} surfaces total)")
    print(f"  3. index_missing        : {ints['index_missing']:>6}   (computed against disk; see scripts/audit.py)")
    print(f"  4. unenumerated_hosts   : {ints['unenumerated_hosts']:>6}   ({raw['hosts_total']} hosts total)")
    print(f"  5. retry_queue_depth    : {ints['retry_queue_depth']:>6}   (latest-attempt-is-retriable)")
    if r["status"] == "residual":
        print()
        print("Exemplars (up to 5 shown):")
        for k, v in r["exemplars"].items():
            if v:
                more = f" (+{len(v) - 5} more)" if len(v) > 5 else ""
                shown = v[:5]
                print(f"  {k}: {shown}{more}")


# ── import-hosts ────────────────────────────────────────────────────────────

def cmd_import_hosts(args):
    cfg = _load(Path(args.config))
    if not ledger.exists(cfg.project_path):
        ledger.init(cfg.project_path)
    with ledger.connect(cfg.project_path) as conn:
        n = ledger.upsert_hosts(conn, cfg.domains)
    print(json.dumps({"status": "ok", "hosts_imported": n}))


# ── import-index ────────────────────────────────────────────────────────────

def cmd_import_index(args):
    cfg = _load(Path(args.config))
    index_path = Path(args.index) if args.index else cfg.index_file
    if not index_path.exists():
        print(json.dumps({"error": f"index not found: {index_path}"}), file=sys.stderr)
        sys.exit(2)
    if not ledger.exists(cfg.project_path):
        ledger.init(cfg.project_path)
    index = json.loads(index_path.read_text())

    rows: list[tuple[str, str, str | None, str | None]] = []
    for slug, entry in index.items():
        original_url = entry.get("original_url") or ""
        wayback_url = entry.get("wayback_url") or ""
        host = _host_of(original_url) or (cfg.domains[0] if cfg.domains else "unknown")
        canonical = original_url or wayback_url or None
        first_seen = str(index_path)
        rows.append((slug, host, canonical, first_seen))

    with ledger.connect(cfg.project_path) as conn:
        n = ledger.upsert_entities(conn, rows)

        # Also backfill hosts from index observations.
        seen_hosts = {r[1] for r in rows if r[1] and r[1] != "unknown"}
        ledger.upsert_hosts(conn, seen_hosts)

    print(json.dumps({
        "status": "ok",
        "entities_imported": n,
        "hosts_observed": len(seen_hosts),
        "index_path": str(index_path),
    }))


# ── mark-dumped / mark-resolved ─────────────────────────────────────────────

def cmd_mark_dumped(args):
    cfg = _load(Path(args.config))
    if not ledger.exists(cfg.project_path):
        print(json.dumps({"error": "ledger does not exist; run `init` first"}), file=sys.stderr)
        sys.exit(2)
    with ledger.connect(cfg.project_path) as conn:
        # Ensure the host row exists even if it wasn't in config.domains.
        ledger.upsert_hosts(conn, [args.host])
        ledger.mark_host_dumped(conn, args.host)
    print(json.dumps({"status": "ok", "host": args.host}))


def cmd_mark_resolved(args):
    cfg = _load(Path(args.config))
    if not ledger.exists(cfg.project_path):
        print(json.dumps({"error": "ledger does not exist; run `init` first"}), file=sys.stderr)
        sys.exit(2)
    with ledger.connect(cfg.project_path) as conn:
        ledger.mark_entity_resolved(conn, args.slug, args.host)
    print(json.dumps({"status": "ok", "slug": args.slug, "host": args.host}))


# ── main ────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="Wayback-archive ledger CLI")
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", required=True, help="Path to site config YAML")
    common.add_argument("--json", action="store_true", help="Emit only JSON to stdout")
    common.add_argument("--exemplars", type=int, default=20,
                        help="Max exemplar rows per audit category")

    sub.add_parser("init", parents=[common], help="Create/initialize the ledger DB")
    sub.add_parser("status", parents=[common], help="Show the five audit integers")
    sub.add_parser("audit", parents=[common],
                   help="Like status, but exits non-zero on any residual")

    imp_idx = sub.add_parser("import-index", parents=[common],
                             help="Backfill entities from a product index JSON")
    imp_idx.add_argument("--index", default=None,
                         help="Path to index JSON (default: config.index_file)")

    sub.add_parser("import-hosts", parents=[common],
                   help="Backfill hosts table from config.domains")

    md = sub.add_parser("mark-dumped", parents=[common], help="Mark a host as CDX-dumped")
    md.add_argument("--host", required=True)

    mr = sub.add_parser("mark-resolved", parents=[common], help="Mark an entity as resolved")
    mr.add_argument("--slug", required=True)
    mr.add_argument("--host", required=True)

    args = p.parse_args()

    dispatch = {
        "init": cmd_init,
        "status": lambda a: cmd_status(a, gate=False),
        "audit": lambda a: cmd_status(a, gate=True),
        "import-index": cmd_import_index,
        "import-hosts": cmd_import_hosts,
        "mark-dumped": cmd_mark_dumped,
        "mark-resolved": cmd_mark_resolved,
    }
    dispatch[args.cmd](args)


if __name__ == "__main__":
    main()
