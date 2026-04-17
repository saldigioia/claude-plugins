#!/usr/bin/env python3
"""
clean_surfaces.py — migrate a pre-4.3 project whose metadata / catalog /
products/ tree has discovery surfaces (atom feeds, oembeds, collection
landings) treated as product entities.

Before Phase 4.3, `_slug_from_html_filename` had a catch-all fallback that
turned any unrecognized filename into a slug. Atom feeds and collection
HTML pages therefore became "products" with `image_count: 0` and nav-
scraped garbage metadata. Real products with atom/oembed siblings each
produced 2-3 phantom entries.

This script walks a project and:

  1. Identifies metadata slugs that match surface patterns
     (via the same `_is_discovery_surface_filename` the fetch stage uses).
  2. Backs up metadata + catalog JSON to `.pre-4.3-migration.bak`.
  3. Removes the surface entries from both JSON files.
  4. Removes any product dirs whose name contains `.atom`, `.oembed`, or
     `_collections_`.
  5. Removes phantom ledger entities matching the surface slugs.
  6. Reports before/after counts.

Usage:
    python3 scripts/clean_surfaces.py --config <cfg>
    python3 scripts/clean_surfaces.py --config <cfg> --dry-run

Exit codes:
    0  migration applied (or nothing to do under --dry-run)
    2  config not found / unreadable
"""
from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from wayback_archiver.site_config import load_config
from wayback_archiver import ledger as ledger_mod
from run_stage import _is_discovery_surface_filename


def main():
    p = argparse.ArgumentParser(description="Clean surface-shaped phantoms from a pre-4.3 project.")
    p.add_argument("--config", required=True, help="Path to site config YAML")
    p.add_argument("--dry-run", action="store_true", help="Report what would change without touching disk")
    p.add_argument("--json", action="store_true", help="Emit only JSON to stdout")
    args = p.parse_args()

    config_path = Path(args.config)
    if not config_path.exists():
        print(json.dumps({"error": f"config not found: {config_path}"}), file=sys.stderr)
        sys.exit(2)

    cfg = load_config(config_path)
    proj = cfg.project_path

    stats = {
        "dry_run": args.dry_run,
        "project_dir": str(proj),
        "metadata_before": 0, "metadata_after": 0, "metadata_removed": 0,
        "catalog_before": 0, "catalog_after": 0, "catalog_removed": 0,
        "dirs_removed": 0,
        "ledger_entities_removed": 0,
        "surface_slugs": [],
    }

    # 1. Find surface-shaped slugs in metadata
    if cfg.metadata_file.exists():
        meta = json.loads(cfg.metadata_file.read_text())
        stats["metadata_before"] = len(meta)
        surface_slugs = sorted(
            s for s in meta
            if _is_discovery_surface_filename(s + (".html" if not s.endswith(".html") else ""))
        )
        stats["surface_slugs"] = surface_slugs
        stats["metadata_removed"] = len(surface_slugs)
    else:
        surface_slugs = []
        meta = {}

    if not surface_slugs:
        stats["message"] = "No surface-shaped entries found. Project is clean."
        _report(stats, args.json)
        return

    # 2. Back up (unless dry-run)
    if not args.dry_run:
        if cfg.metadata_file.exists():
            shutil.copyfile(cfg.metadata_file, str(cfg.metadata_file) + ".pre-4.3-migration.bak")
        if cfg.catalog_file.exists():
            shutil.copyfile(cfg.catalog_file, str(cfg.catalog_file) + ".pre-4.3-migration.bak")

    # 3. Filter metadata
    cleaned_meta = {s: v for s, v in meta.items() if s not in set(surface_slugs)}
    stats["metadata_after"] = len(cleaned_meta)
    if not args.dry_run:
        cfg.metadata_file.write_text(json.dumps(cleaned_meta, indent=2))

    # 4. Filter catalog
    if cfg.catalog_file.exists():
        cat = json.loads(cfg.catalog_file.read_text())
        stats["catalog_before"] = len(cat)
        cleaned_cat = [e for e in cat if e.get("slug") not in set(surface_slugs)]
        stats["catalog_after"] = len(cleaned_cat)
        stats["catalog_removed"] = len(cat) - len(cleaned_cat)
        if not args.dry_run:
            cfg.catalog_file.write_text(json.dumps(cleaned_cat, indent=2))

    # 5. Remove contaminated product dirs
    if cfg.products_dir.exists():
        for d in cfg.products_dir.iterdir():
            if not d.is_dir():
                continue
            lower = d.name.lower()
            if ".atom" in lower or ".oembed" in lower or "_collections_" in lower:
                if args.dry_run:
                    pass
                else:
                    shutil.rmtree(d)
                stats["dirs_removed"] += 1

    # 6. Clean phantom ledger entities
    ledger_path = proj / "ledger.db"
    if ledger_path.exists() and not args.dry_run:
        conn = sqlite3.connect(ledger_path)
        before = conn.execute("SELECT COUNT(*) FROM entities").fetchone()[0]
        for s in surface_slugs:
            conn.execute("DELETE FROM entities WHERE slug = ?", (s,))
        conn.commit()
        after = conn.execute("SELECT COUNT(*) FROM entities").fetchone()[0]
        conn.close()
        stats["ledger_entities_removed"] = before - after

    _report(stats, args.json)


def _report(stats: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(stats, indent=2))
        return
    print(f"Clean-surfaces migration {'(DRY RUN)' if stats['dry_run'] else ''}")
    print(f"  project: {stats['project_dir']}")
    if stats.get("message"):
        print(f"  {stats['message']}")
        return
    print(f"  metadata: {stats['metadata_before']} → {stats['metadata_after']} "
          f"(removed {stats['metadata_removed']})")
    print(f"  catalog:  {stats['catalog_before']} → {stats['catalog_after']} "
          f"(removed {stats['catalog_removed']})")
    print(f"  product dirs removed: {stats['dirs_removed']}")
    if stats.get("ledger_entities_removed"):
        print(f"  ledger entities removed: {stats['ledger_entities_removed']}")
    if stats["surface_slugs"]:
        print(f"  first 10 surface slugs: {stats['surface_slugs'][:10]}")


if __name__ == "__main__":
    main()
