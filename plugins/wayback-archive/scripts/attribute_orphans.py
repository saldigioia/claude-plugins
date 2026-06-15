#!/usr/bin/env python3
"""
attribute_orphans.py — stand-alone slug attribution for a directory of images.

Solves the yeezygap-style problem: you have a pile of product images that
were saved without a slug mapping, and you want to bucket them into
``products/<slug>/`` before running the rest of the pipeline.

The attribution cascade is ``lib/wayback_archiver/match.resolve_image_to_slug``
with the ``aggressive`` strategy by default:

  1. Canonical stem direct hit against the slug set
  2. ``slug__tail`` / ``products__slug__tail`` split-convention
  3. SKU prefix extraction (``KW5M5001_front.jpg`` → sku_map lookup)
  4. Substring containment
  5. Token-set overlap (numeric product codes, shared long words)
  6. Difflib fuzzy match with a 0.85 ratio floor

The script is deliberately stand-alone — it does NOT require a ledger or
a pipeline run history. It reads the project's ``<name>_metadata.json``
(if present) and any existing ``products/<slug>/`` dirs for the slug
universe, then classifies every image in the input directory.

Typical usage:
    python3 scripts/attribute_orphans.py \\
        --config projects/<name>/config.yaml \\
        --source /path/to/orphan/images \\
        --apply

Without ``--apply`` the script is a dry-run: it reports what would be
attributed but doesn't touch disk. Use ``--report out.json`` to persist
the full attribution decision log.

This is the reusable version of the ad-hoc ``/tmp/yeezygap_attribute_orphans.py``
script that recovered 1123/1813 orphan images during the 2026-04-18
reprocessing run — see ``docs/POSTMORTEM_2026-04-18.md``.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from wayback_archiver.site_config import load_config
from wayback_archiver.match import (
    build_sku_to_slug_map,
    resolve_image_to_slug,
)

_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".tif", ".tiff", ".avif"}


def load_known_slugs(config) -> tuple[set[str], dict[str, str]]:
    """Build the slug universe + SKU→slug map from metadata + on-disk products/."""
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
    if config.products_dir.exists():
        for child in config.products_dir.iterdir():
            if child.is_dir():
                slugs.add(child.name)
    return slugs, sku_map


def classify(
    source: Path,
    slugs: set[str],
    sku_map: dict[str, str],
    strategy: str,
) -> dict:
    """Classify every image under ``source`` into attributed / residual buckets."""
    attributed: dict[str, list[str]] = {}
    residual: list[str] = []

    files = [p for p in source.rglob("*")
             if p.is_file() and p.suffix.lower() in _IMAGE_EXTS]

    for src in files:
        slug = resolve_image_to_slug(
            src.name, slugs, sku_map=sku_map, strategy=strategy,
        )
        if slug:
            attributed.setdefault(slug, []).append(str(src))
        else:
            residual.append(str(src))

    return {
        "total": len(files),
        "attributed_count": sum(len(v) for v in attributed.values()),
        "residual_count": len(residual),
        "by_slug": {k: len(v) for k, v in sorted(attributed.items(),
                                                  key=lambda kv: -len(kv[1]))},
        "attributed": attributed,
        "residual": residual,
        "strategy": strategy,
    }


def stage(
    classification: dict,
    products_dir: Path,
    copy: bool = False,
) -> dict:
    """Materialize the classification: hardlink (default) or copy into products/."""
    staged = 0
    already = 0
    errors: list[str] = []
    for slug, srcs in classification["attributed"].items():
        dst_dir = products_dir / slug
        dst_dir.mkdir(parents=True, exist_ok=True)
        for src_str in srcs:
            src = Path(src_str)
            dst = dst_dir / src.name
            if dst.exists() and dst.stat().st_size == src.stat().st_size:
                already += 1
                continue
            try:
                if copy:
                    shutil.copy2(src, dst)
                else:
                    try:
                        dst.hardlink_to(src)
                    except (OSError, AttributeError):
                        shutil.copy2(src, dst)
                staged += 1
            except OSError as e:
                errors.append(f"{src}: {e}")
    return {"staged": staged, "already_present": already, "errors": errors}


def main() -> int:
    p = argparse.ArgumentParser(
        description="Attribute orphan images to product slugs and stage them.",
    )
    p.add_argument("--config", required=True, help="Path to site config YAML")
    p.add_argument("--source", required=True,
                   help="Directory of orphan images (scanned recursively)")
    p.add_argument("--strategy", default="aggressive",
                   choices=("strict", "aggressive"),
                   help="resolve_image_to_slug strictness (default: aggressive)")
    p.add_argument("--apply", action="store_true",
                   help="Actually hardlink matched images into products/. Without "
                        "this flag the script is a dry run.")
    p.add_argument("--copy", action="store_true",
                   help="Use copy instead of hardlink (needed across filesystems)")
    p.add_argument("--report", default=None,
                   help="Write the full classification JSON to this path.")
    args = p.parse_args()

    config_path = Path(args.config)
    source = Path(args.source)
    if not config_path.exists():
        print(f"config not found: {config_path}", file=sys.stderr)
        return 2
    if not source.is_dir():
        print(f"source not a directory: {source}", file=sys.stderr)
        return 2

    config = load_config(config_path)
    slugs, sku_map = load_known_slugs(config)
    if not slugs:
        print("No known slugs found (no metadata.json and empty products/). "
              "Run the match stage at least once before attributing orphans.",
              file=sys.stderr)
        return 3

    classification = classify(source, slugs, sku_map, args.strategy)

    print(f"Orphan attribution report ({classification['strategy']} strategy):")
    print(f"  Total images:       {classification['total']}")
    print(f"  Attributed:         {classification['attributed_count']} "
          f"({100 * classification['attributed_count'] / max(classification['total'], 1):.1f}%)")
    print(f"  Residual:           {classification['residual_count']}")
    print(f"  Distinct slugs hit: {len(classification['by_slug'])}")
    if classification["by_slug"]:
        print("  Top slugs by count:")
        for slug, c in list(classification["by_slug"].items())[:10]:
            print(f"    {slug}: {c}")

    if args.report:
        Path(args.report).write_text(json.dumps(classification, indent=2))
        print(f"  Full report: {args.report}")

    if args.apply:
        result = stage(classification, config.products_dir, copy=args.copy)
        print(f"Staged {result['staged']} new files "
              f"({result['already_present']} already present).")
        if result["errors"]:
            print(f"  {len(result['errors'])} errors (first 5 shown):")
            for e in result["errors"][:5]:
                print(f"    {e}")
    else:
        print("(dry run — rerun with --apply to materialize links)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
