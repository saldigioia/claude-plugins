#!/usr/bin/env python3
"""
split_collided_dirs.py — migrate pre-fix product directories.

Before the `build_dirname(slug=...)` fix, variants sharing the same
`name` + `date` (e.g. per-city pablosupply reissues of the same T-shirt
or jacket) all wrote into a single product directory, cross-contaminating
each other's images — and the UUID-suffix dedup miss on `jacket_03_<uuid>.jpg`
compounded it with dozens of byte-identical duplicates per dir.

This script walks `<project>/products/` and, for each directory whose
old-style name maps to multiple metadata slugs, redistributes its
contents into the new per-slug directories by matching each image's
filename stem against the URLs in `<project>/links/<slug>.txt`
(UUID-stripped on both sides for fair comparison). Unambiguous matches
move into that slug's new dir; ambiguous or unmatched files are parked
under `_orphans/<old-dirname>/` for manual review.

Non-collided directories are renamed in place to the new slug-aware
form so subsequent pipeline passes find them via `build_dir_to_slug_map`.

Usage:
    python3 scripts/split_collided_dirs.py --config <cfg>
    python3 scripts/split_collided_dirs.py --config <cfg> --dry-run

Exit codes:
    0  migration applied (or nothing to do under --dry-run)
    2  config not found / unreadable
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from urllib.parse import urlparse, unquote

from wayback_archiver.site_config import load_config
from wayback_archiver.util import build_dirname, sanitize_dirname
from wayback_archiver.download import (
    SIZE_SUFFIX,
    NAMED_SIZE,
    UUID_SUFFIX,
)
from wayback_archiver.normalize import IMAGE_EXTENSIONS


def _old_dirname(name: str, date: str | None) -> str:
    """Reproduce the pre-fix `build_dirname(name, date)` output."""
    if date:
        return sanitize_dirname(f"{date} {name}")
    return sanitize_dirname(name)


def _url_basename(url: str) -> str:
    """Basename from a URL path, query stripped, size suffixes removed —
    but UUIDs preserved. UUIDs act as the per-city distinguisher in
    Shopify-CDN-archaeology products (each city-variant's image was
    re-uploaded with a fresh UUID), so stripping them would collapse
    14 distinct variants onto one matching key and destroy routing.
    """
    path = unquote(urlparse(url).path)
    name = path.split("/")[-1]
    name = SIZE_SUFFIX.sub("", name)
    name = NAMED_SIZE.sub("", name)
    return name.lower()


def _expected_names_for_slug(slug: str, links_dir: Path) -> tuple[set[str], set[str]]:
    """Return (raw_names, stripped_names) for this slug's link URLs.

    raw_names: UUID-preserving basenames — used for precise per-city
      routing against files that still carry their original UUIDs.
    stripped_names: UUID-stripped stems — fallback for files saved under
      a cleaned name (e.g. a re-run that saved `jacket_04-2.jpg`).
    """
    links_file = links_dir / f"{slug}.txt"
    if not links_file.exists():
        return set(), set()
    raw: set[str] = set()
    stripped: set[str] = set()
    for line in links_file.read_text().splitlines():
        url = line.strip()
        if not url:
            continue
        raw_name = _url_basename(url)
        if raw_name:
            raw.add(raw_name)
            stripped.add(UUID_SUFFIX.sub("", raw_name))
    return raw, stripped


def _file_keys(path: Path) -> tuple[str, str]:
    """Return (raw, stripped) match keys for an existing file."""
    raw = path.name.lower()
    raw = SIZE_SUFFIX.sub("", raw)
    raw = NAMED_SIZE.sub("", raw)
    stripped = UUID_SUFFIX.sub("", raw)
    return raw, stripped


def _iter_images(d: Path):
    for f in d.iterdir():
        if f.is_file() and f.suffix.lower() in IMAGE_EXTENSIONS:
            yield f


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="Path to site config YAML")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report actions without moving anything")
    args = parser.parse_args()

    config_path = Path(args.config).expanduser().resolve()
    if not config_path.exists():
        print(f"Config not found: {config_path}", file=sys.stderr)
        return 2

    config = load_config(config_path)
    products_dir = config.products_dir
    links_dir = config.links_dir
    metadata_file = config.metadata_file

    if not products_dir.exists():
        print(f"products/ directory does not exist: {products_dir}")
        return 0
    if not metadata_file.exists():
        print(f"metadata file does not exist: {metadata_file}", file=sys.stderr)
        return 2

    metadata = json.loads(metadata_file.read_text())

    # Build reverse maps:
    #   old_to_slugs: old-style dirname -> [slug, ...]       (>1 ⇒ collision)
    #   slug_to_new:  slug -> new slug-aware dirname
    old_to_slugs: dict[str, list[str]] = defaultdict(list)
    slug_to_new: dict[str, str] = {}
    for slug, meta in metadata.items():
        name = meta.get("name", slug.replace("-", " ").title())
        date = meta.get("date") or None
        old_to_slugs[_old_dirname(name, date)].append(slug)
        slug_to_new[slug] = build_dirname(name, date, slug)

    orphans_root = products_dir / "_orphans"

    stats = {
        "dirs_scanned": 0,
        "dirs_renamed": 0,
        "dirs_split": 0,
        "dirs_unknown": 0,
        "files_moved": 0,
        "files_orphaned": 0,
        "files_duplicate": 0,
    }

    for d in sorted(products_dir.iterdir()):
        if not d.is_dir():
            continue
        if d.name.startswith("_"):  # _orphans and any other bookkeeping dirs
            continue
        stats["dirs_scanned"] += 1

        slugs = old_to_slugs.get(d.name, [])

        # Case 0: unknown dir — metadata doesn't claim it under the old scheme.
        # Could be an already-migrated dir (new-style name) or genuinely stale.
        if not slugs:
            # Check if it already matches a new-style name.
            if d.name in slug_to_new.values():
                continue  # already migrated, nothing to do
            stats["dirs_unknown"] += 1
            print(f"  ? unknown dir (no metadata match): {d.name}")
            continue

        # Case 1: single owner, just rename to the new slug-aware form.
        if len(slugs) == 1:
            slug = slugs[0]
            new_name = slug_to_new[slug]
            if d.name == new_name:
                continue  # already correct
            dest = products_dir / new_name
            if dest.exists():
                print(f"  ! rename target exists, skipping: {d.name} → {new_name}")
                continue
            if args.dry_run:
                print(f"  → rename: {d.name} → {new_name}")
            else:
                d.rename(dest)
            stats["dirs_renamed"] += 1
            continue

        # Case 2: collision — split by per-slug links matching.
        stats["dirs_split"] += 1
        per_slug = {s: _expected_names_for_slug(s, links_dir) for s in slugs}
        any_links = any(raw or stripped for raw, stripped in per_slug.values())
        if not any_links:
            print(f"  ! collided dir has no links/<slug>.txt for any of its "
                  f"{len(slugs)} slugs, orphaning all: {d.name}")

        print(f"  × split ({len(slugs)}-way): {d.name}")
        for slug in slugs:
            raw, stripped = per_slug[slug]
            print(f"      → {slug_to_new[slug]}  "
                  f"(expected: {len(raw)} raw, {len(stripped)} stripped)")

        for f in _iter_images(d):
            raw_key, stripped_key = _file_keys(f)
            # Primary: raw-basename match (preserves per-city UUID routing).
            owners = [s for s, (raw, _) in per_slug.items() if raw_key in raw]
            # Fallback: UUID-stripped match, but only if the raw pass found
            # no owners — prevents collapsing distinct city-UUIDs.
            if not owners:
                owners = [s for s, (_, stripped) in per_slug.items()
                          if stripped_key in stripped]

            if len(owners) == 1:
                slug = owners[0]
                dest_dir = products_dir / slug_to_new[slug]
                dest = dest_dir / f.name
                if args.dry_run:
                    print(f"      move {f.name} → {slug_to_new[slug]}/")
                    stats["files_moved"] += 1
                else:
                    dest_dir.mkdir(parents=True, exist_ok=True)
                    if dest.exists():
                        stats["files_duplicate"] += 1
                        # Keep the first, orphan the duplicate so nothing is lost.
                        orphan_dest = orphans_root / d.name / f"dup__{f.name}"
                        orphan_dest.parent.mkdir(parents=True, exist_ok=True)
                        shutil.move(str(f), str(orphan_dest))
                    else:
                        shutil.move(str(f), str(dest))
                        stats["files_moved"] += 1
            else:
                # 0 or >1 owners → orphan for manual review.
                orphan_dest = orphans_root / d.name / f.name
                if args.dry_run:
                    reason = "ambiguous" if len(owners) > 1 else "unmatched"
                    print(f"      orphan ({reason}): {f.name}")
                else:
                    orphan_dest.parent.mkdir(parents=True, exist_ok=True)
                    if orphan_dest.exists():
                        # Already orphaned on a prior run; drop this copy.
                        f.unlink()
                    else:
                        shutil.move(str(f), str(orphan_dest))
                stats["files_orphaned"] += 1

        # Drop the now-empty collided dir (preserve metadata.txt if any).
        if not args.dry_run:
            leftover = list(d.iterdir())
            if not leftover:
                d.rmdir()
            else:
                # Non-image leftovers (metadata.txt, etc.) — sweep to orphans.
                leftover_dest = orphans_root / d.name
                leftover_dest.mkdir(parents=True, exist_ok=True)
                for f in leftover:
                    shutil.move(str(f), str(leftover_dest / f.name))
                d.rmdir()

    print()
    print("Summary:")
    for k, v in stats.items():
        print(f"  {k}: {v}")
    if args.dry_run:
        print("\n(dry run — no files moved)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
