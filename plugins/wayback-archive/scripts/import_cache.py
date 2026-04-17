#!/usr/bin/env python3
"""
import_cache.py — ingest a local HTML directory as already-fetched.

Useful when someone hands you a scrape (or you made one yourself) for the
same target the pipeline is about to crawl. Copies HTML files into the
fetch stage's output directory under the conventional `_safe_filename`
form, appends one record per file to `fetch_results.jsonl`, and
optionally updates the ledger directly. After importing, running the
fetch stage with its standard `resume=True` behavior will skip the
imported files and only fetch what's still missing.

URL resolution per file (first-win):
  1. `<link rel="canonical" href="...">` from the first 64 KiB of the body
  2. filename-reverse if the filename starts with a known config.domains
     host (replaces `_` with `/` — works for the standard Shopify slug
     shape like `www.site.com_products_foo.html`)
  3. skip (reported in stats)

Usage:
    python3 scripts/import_cache.py --config projects/<name>/config.yaml \
                                    --cache /path/to/local/html/dir
    # Preview without touching disk:
    python3 scripts/import_cache.py --config <cfg> --cache <dir> --dry-run
    # Also update the ledger immediately (otherwise deferred until run_fetch):
    python3 scripts/import_cache.py --config <cfg> --cache <dir> --update-ledger
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
sys.path.insert(0, str(REPO_ROOT))

from wayback_archiver.site_config import load_config
from wayback_archiver import ledger as ledger_mod
from wayback_archiver.env import load_env

load_env()

from fetch_archive import _safe_filename  # noqa: E402

_CANONICAL_RE = re.compile(
    rb'<link[^>]*\brel\s*=\s*["\']?canonical["\']?[^>]*\bhref\s*=\s*["\']?([^"\'>\s]+)',
    re.IGNORECASE,
)


def extract_canonical(body: bytes) -> str | None:
    """Return the canonical URL from the first 64 KiB of the HTML body, if present."""
    m = _CANONICAL_RE.search(body[:65536])
    if not m:
        return None
    url = m.group(1).decode("utf-8", errors="replace")
    # Strip Wayback toolbar wrappers if someone imported via web.archive.org/web/...id_
    url = re.sub(r"^https?://web\.archive\.org/web/\d+(?:id_|im_|if_)?/", "", url)
    return url


def derive_url_from_filename(filename: str, known_domains: list[str]) -> str | None:
    """Best-effort filename → URL reverse. Works for the `_safe_filename`
    shape on unhashed names where the filename starts with a known host.
    """
    stem = filename
    if stem.endswith(".html"):
        stem = stem[: -len(".html")]

    # Try longest-domain-first so www.foo.com matches before foo.com
    for domain in sorted(known_domains, key=len, reverse=True):
        prefix = domain + "_"
        if stem.lower().startswith(prefix.lower()):
            path_part = stem[len(prefix):]
            # Filenames use `_` for `/`; Shopify slugs use `-`, so the
            # replacement is generally safe for Shopify-shape paths.
            return f"https://{domain}/{path_part.replace('_', '/')}"
    return None


def _tier_for_url(url: str) -> str:
    path = urlparse(url).path.lower()
    if path.endswith(".oembed") or path.endswith(".atom") or path.endswith(".json"):
        return "structured"
    if "/products/" in path:
        return "html"
    if "/collections/" in path:
        return "collection"
    return "homepage"


def import_cache(cache_dir: Path, config, dry_run: bool = False) -> dict:
    output_dir = config.fetch_output_dir
    if not dry_run:
        config.ensure_project_dirs()

    results_path = output_dir.parent / "fetch_results.jsonl"

    html_files = sorted(cache_dir.rglob("*.html"))
    stats: dict = {
        "total": len(html_files),
        "imported": 0,
        "skipped_no_url": 0,
        "skipped_duplicate": 0,
        "canonical_used": 0,
        "filename_used": 0,
        "bytes": 0,
        "by_tier": {},
        "dry_run": dry_run,
    }
    records: list[dict] = []

    for src in html_files:
        try:
            body = src.read_bytes()
        except OSError:
            stats["skipped_no_url"] += 1
            continue

        url = extract_canonical(body)
        if url:
            stats["canonical_used"] += 1
        else:
            url = derive_url_from_filename(src.name, config.domains)
            if url:
                stats["filename_used"] += 1
        if not url:
            stats["skipped_no_url"] += 1
            continue

        safe = _safe_filename(url)
        dst = output_dir / safe
        if dst.exists() and dst.stat().st_size >= len(body):
            stats["skipped_duplicate"] += 1
            continue

        tier = _tier_for_url(url)
        stats["by_tier"][tier] = stats["by_tier"].get(tier, 0) + 1
        records.append({
            "original_url": url,
            "wayback_url": "",
            "timestamp": "",
            "tier": tier,
            "success": True,
            "method": "local_cache",
            "size": len(body),
            "error": "",
        })

        if not dry_run:
            shutil.copyfile(src, dst)
        stats["imported"] += 1
        stats["bytes"] += len(body)

    if records and not dry_run:
        with results_path.open("a", encoding="utf-8") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
        stats["results_path"] = str(results_path)

    return stats


def main():
    p = argparse.ArgumentParser(
        description="Ingest a local HTML cache into a wayback-archive project's fetch output."
    )
    p.add_argument("--config", required=True, help="Path to site config YAML")
    p.add_argument("--cache", required=True, help="Directory containing .html files to import")
    p.add_argument("--dry-run", action="store_true",
                   help="Report what would be imported without touching disk.")
    p.add_argument("--update-ledger", action="store_true",
                   help="Also update the ledger directly (otherwise deferred until run_fetch).")
    p.add_argument("--json", action="store_true", help="Emit only JSON to stdout.")
    args = p.parse_args()

    config_path = Path(args.config)
    if not config_path.exists():
        print(json.dumps({"error": f"config not found: {config_path}"}), file=sys.stderr)
        sys.exit(2)
    cache_dir = Path(args.cache)
    if not cache_dir.is_dir():
        print(json.dumps({"error": f"not a directory: {cache_dir}"}), file=sys.stderr)
        sys.exit(2)

    config = load_config(config_path)
    stats = import_cache(cache_dir, config, args.dry_run)

    if args.update_ledger and not args.dry_run and ledger_mod.exists(config.project_path):
        results_path = config.fetch_output_dir.parent / "fetch_results.jsonl"
        if results_path.exists():
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            from run_stage import _import_fetch_results  # type: ignore[attr-defined]
            with ledger_mod.connect(config.project_path) as conn:
                _import_fetch_results(conn, results_path)
            stats["ledger_synced"] = True

    if args.json:
        print(json.dumps(stats, indent=2))
    else:
        print(f"Imported {stats['imported']} / {stats['total']} HTML files "
              f"({stats['bytes']/1e6:.1f} MB) into {config.fetch_output_dir}")
        print(f"  Canonical URL: {stats['canonical_used']}  "
              f"Filename-derived: {stats['filename_used']}  "
              f"Skipped (no URL): {stats['skipped_no_url']}  "
              f"Skipped (duplicate): {stats['skipped_duplicate']}")
        if stats["by_tier"]:
            print("  By tier:")
            for t, c in sorted(stats["by_tier"].items(), key=lambda x: -x[1]):
                print(f"    {t}: {c}")
        if stats.get("ledger_synced"):
            print("  Ledger synced.")


if __name__ == "__main__":
    main()
