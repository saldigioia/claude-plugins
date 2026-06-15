#!/usr/bin/env python3
"""
import_cache.py — ingest a local HTML / image directory as already-fetched.

Useful when someone hands you a scrape (or you made one yourself) for the
same target the pipeline is about to crawl. Two modes:

  HTML mode (``--cache`` / ``--html-dir``):
    Copies HTML files into the fetch stage's output directory under the
    conventional ``_safe_filename`` form, appends one record per file to
    ``fetch_results.jsonl``, and optionally updates the ledger directly.
    After importing, running the fetch stage with its standard
    ``resume=True`` behavior will skip the imported files and only fetch
    what's still missing.

    URL resolution per file (first-win):
      1. ``<link rel="canonical" href="...">`` from the first 64 KiB of body
      2. filename-reverse if the filename starts with a known config.domains
         host (replaces ``_`` with ``/`` — works for the standard Shopify
         slug shape like ``www.site.com_products_foo.html``)
      3. skip (reported in stats)

  Image mode (``--image-dir``):
    Attributes each image file in a directory to a product slug using the
    same ``resolve_image_to_slug`` cascade the match stage uses (direct
    hit → __ split → SKU prefix → substring → token-set overlap → fuzzy).
    Hardlinks (or copies, with ``--copy-images``) matched files into the
    project's ``products/<slug>/`` tree so they appear as already-
    downloaded. Unattributed images are reported but not moved — inspect
    the residual list to decide whether to hand-attribute them.

Usage:
    # HTML import
    python3 scripts/import_cache.py --config projects/<name>/config.yaml \
                                    --html-dir /path/to/local/html/dir

    # Image orphan attribution (the yeezygap use case)
    python3 scripts/import_cache.py --config projects/<name>/config.yaml \
                                    --image-dir /path/to/shopify_images

    # Preview without touching disk:
    python3 scripts/import_cache.py --config <cfg> --html-dir <dir> --dry-run

    # Also update the ledger immediately (HTML mode; otherwise deferred):
    python3 scripts/import_cache.py --config <cfg> --html-dir <dir> --update-ledger

The legacy ``--cache`` flag is kept as an alias for ``--html-dir`` so
existing scripts continue to work.
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
from wayback_archiver.match import resolve_image_to_slug, build_sku_to_slug_map

load_env()

from fetch_archive import _safe_filename  # noqa: E402

_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".tif", ".tiff", ".avif"}

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


def _load_known_slugs(config) -> tuple[set[str], dict[str, str]]:
    """Return (slug_set, sku_map) from the project's metadata file.

    The slug set seeds ``resolve_image_to_slug``; the SKU map lets it
    match filenames that lead with a style code (``GX9662_front.jpg``).
    Missing metadata isn't fatal — falls back to scanning products_dir.
    """
    slugs: set[str] = set()
    sku_map: dict[str, str] = {}
    meta_path = config.metadata_file
    if meta_path.exists():
        try:
            with meta_path.open(encoding="utf-8") as f:
                meta = json.load(f)
            if isinstance(meta, dict):
                slugs.update(meta.keys())
                sku_map = build_sku_to_slug_map(meta)
        except (OSError, json.JSONDecodeError):
            pass
    # Fallback / supplement: existing product dirs on disk.
    if config.products_dir.exists():
        for child in config.products_dir.iterdir():
            if child.is_dir():
                slugs.add(child.name)
    return slugs, sku_map


def import_images(
    image_dir: Path,
    config,
    dry_run: bool = False,
    copy: bool = False,
    strategy: str = "aggressive",
) -> dict:
    """Attribute images in ``image_dir`` to product slugs and stage them.

    Matched files are hardlinked (or copied, with ``copy=True``) into
    ``products/<slug>/`` so the download stage treats them as already
    acquired. Unattributed files are left in place and listed in the
    returned stats under ``residuals``.
    """
    slugs, sku_map = _load_known_slugs(config)
    if not slugs:
        return {
            "error": (
                "no known slugs in metadata or products/ — run the match "
                "stage at least once before attributing orphans"
            )
        }

    if not dry_run:
        config.ensure_project_dirs()

    candidates = [
        p for p in image_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in _IMAGE_EXTS
    ]

    stats: dict = {
        "total": len(candidates),
        "attributed": 0,
        "already_present": 0,
        "residual": 0,
        "by_slug": {},
        "residuals": [],
        "dry_run": dry_run,
        "strategy": strategy,
        "mode": "copy" if copy else "hardlink",
    }

    for src in candidates:
        slug = resolve_image_to_slug(
            src.name, slugs, sku_map=sku_map, strategy=strategy
        )
        if not slug:
            stats["residual"] += 1
            if len(stats["residuals"]) < 50:  # cap for readability
                stats["residuals"].append(src.name)
            continue

        dst_dir = config.products_dir / slug
        dst = dst_dir / src.name
        if dst.exists() and dst.stat().st_size == src.stat().st_size:
            stats["already_present"] += 1
            continue
        stats["attributed"] += 1
        stats["by_slug"][slug] = stats["by_slug"].get(slug, 0) + 1

        if dry_run:
            continue
        dst_dir.mkdir(parents=True, exist_ok=True)
        try:
            if copy:
                shutil.copy2(src, dst)
            else:
                # Hardlink avoids duplicating bytes; falls back to copy if
                # the source and dest are on different filesystems.
                try:
                    dst.hardlink_to(src)
                except (OSError, AttributeError):
                    shutil.copy2(src, dst)
        except OSError as e:
            stats["residual"] += 1
            stats["residuals"].append(f"{src.name} (stage error: {e})")
            stats["attributed"] -= 1
            stats["by_slug"][slug] -= 1

    return stats


def main():
    p = argparse.ArgumentParser(
        description="Ingest a local HTML or image cache into a wayback-archive project."
    )
    p.add_argument("--config", required=True, help="Path to site config YAML")
    # Legacy --cache is an alias for --html-dir.
    p.add_argument("--cache", "--html-dir", dest="html_dir", default=None,
                   help="Directory containing .html files to import (legacy alias: --cache)")
    p.add_argument("--image-dir", dest="image_dir", default=None,
                   help="Directory containing image files to attribute to slugs "
                        "and stage under products/<slug>/.")
    p.add_argument("--match-strategy", default="aggressive",
                   choices=("strict", "aggressive"),
                   help="Image-mode only: strictness of resolve_image_to_slug.")
    p.add_argument("--copy-images", action="store_true",
                   help="Image-mode only: copy instead of hardlink. Use when "
                        "the image dir is on a different filesystem.")
    p.add_argument("--dry-run", action="store_true",
                   help="Report what would be imported without touching disk.")
    p.add_argument("--update-ledger", action="store_true",
                   help="HTML mode only: also update the ledger directly.")
    p.add_argument("--json", action="store_true", help="Emit only JSON to stdout.")
    args = p.parse_args()

    if not args.html_dir and not args.image_dir:
        print(json.dumps({
            "error": "at least one of --html-dir (or --cache) / --image-dir is required"
        }), file=sys.stderr)
        sys.exit(2)

    config_path = Path(args.config)
    if not config_path.exists():
        print(json.dumps({"error": f"config not found: {config_path}"}), file=sys.stderr)
        sys.exit(2)
    config = load_config(config_path)

    combined: dict = {}

    if args.html_dir:
        cache_dir = Path(args.html_dir)
        if not cache_dir.is_dir():
            print(json.dumps({"error": f"not a directory: {cache_dir}"}), file=sys.stderr)
            sys.exit(2)
        html_stats = import_cache(cache_dir, config, args.dry_run)
        combined["html"] = html_stats

        if args.update_ledger and not args.dry_run and ledger_mod.exists(config.project_path):
            results_path = config.fetch_output_dir.parent / "fetch_results.jsonl"
            if results_path.exists():
                sys.path.insert(0, str(Path(__file__).resolve().parent))
                from run_stage import _import_fetch_results  # type: ignore[attr-defined]
                with ledger_mod.connect(config.project_path) as conn:
                    _import_fetch_results(conn, results_path)
                html_stats["ledger_synced"] = True

    if args.image_dir:
        img_dir = Path(args.image_dir)
        if not img_dir.is_dir():
            print(json.dumps({"error": f"not a directory: {img_dir}"}), file=sys.stderr)
            sys.exit(2)
        combined["images"] = import_images(
            img_dir, config,
            dry_run=args.dry_run,
            copy=args.copy_images,
            strategy=args.match_strategy,
        )

    if args.json:
        print(json.dumps(combined, indent=2))
        return

    if "html" in combined:
        stats = combined["html"]
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

    if "images" in combined:
        istats = combined["images"]
        if "error" in istats:
            print(f"Image import failed: {istats['error']}")
            sys.exit(3)
        print(
            f"Attributed {istats['attributed']} / {istats['total']} images via "
            f"{istats['strategy']} matcher ({istats['mode']}); "
            f"{istats['already_present']} already present, "
            f"{istats['residual']} residual."
        )
        if istats["by_slug"]:
            top = sorted(istats["by_slug"].items(), key=lambda x: -x[1])[:10]
            print("  Top slugs by count:")
            for slug, c in top:
                print(f"    {slug}: {c}")


if __name__ == "__main__":
    main()
