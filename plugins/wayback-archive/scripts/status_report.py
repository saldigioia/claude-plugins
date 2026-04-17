#!/usr/bin/env python3
"""
Pipeline progress dashboard — shows current state of an archival project.

Usage:
    python3 status_report.py --config configs/example.yaml
    python3 status_report.py --config configs/example.yaml --final
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

from wayback_archiver.site_config import load_config
from wayback_archiver.normalize import list_images, IMAGE_EXTENSIONS
from wayback_archiver.util import build_dir_to_slug_map


def main():
    parser = argparse.ArgumentParser(description="Pipeline Status Report")
    parser.add_argument("--config", required=True)
    parser.add_argument("--final", action="store_true")
    args = parser.parse_args()

    config = load_config(Path(args.config))

    print(f"\n{'=' * 60}")
    print(f"  {config.display_name} — Pipeline Status")
    print(f"{'=' * 60}\n")

    # Index
    if config.index_file.exists():
        index = json.loads(config.index_file.read_text())
        print(f"Product Index: {len(index)} products")
        by_type = {}
        for p in index.values():
            by_type[p["url_type"]] = by_type.get(p["url_type"], 0) + 1
        for t, c in sorted(by_type.items(), key=lambda x: -x[1]):
            print(f"  {t}: {c}")
    else:
        print("Product Index: NOT CREATED (run 'index' stage)")

    # Metadata
    if config.metadata_file.exists():
        metadata = json.loads(config.metadata_file.read_text())
        print(f"\nMetadata: {len(metadata)} entries")
        fields = ["name", "price", "sku", "color", "description"]
        for f in fields:
            count = sum(1 for m in metadata.values() if m.get(f))
            print(f"  {f}: {count}/{len(metadata)}")
    else:
        print("\nMetadata: NOT CREATED (run 'fetch' stage)")
        metadata = {}

    # Links
    if config.links_dir.exists():
        links_files = list(config.links_dir.glob("*.txt"))
        non_empty = sum(1 for f in links_files if f.read_text().strip())
        total_urls = sum(
            len([l for l in f.read_text().splitlines() if l.strip()])
            for f in links_files
        )
        print(f"\nImage Links: {len(links_files)} files ({non_empty} with URLs, {total_urls} total URLs)")

    # Products
    if config.products_dir.exists():
        dirs = [d for d in config.products_dir.iterdir() if d.is_dir()]
        with_images = 0
        total_images = 0
        empty_dirs = []
        for d in dirs:
            images = list_images(d)
            if images:
                with_images += 1
                total_images += len(images)
            else:
                empty_dirs.append(d.name)

        print(f"\nProducts Directory: {len(dirs)} directories")
        print(f"  With images: {with_images} ({total_images} files)")
        print(f"  Empty: {len(empty_dirs)}")

        if args.final and empty_dirs:
            print(f"\n  Empty directories:")
            for name in sorted(empty_dirs)[:20]:
                print(f"    {name}")
            if len(empty_dirs) > 20:
                print(f"    ... and {len(empty_dirs) - 20} more")

    # Catalog
    if config.catalog_file.exists():
        catalog = json.loads(config.catalog_file.read_text())
        print(f"\nCatalog: {len(catalog)} entries")

    # Fetch stats
    if config.fetch_stats_file.exists():
        stats = json.loads(config.fetch_stats_file.read_text())
        print(f"\nFetch Stats:")
        print(f"  Wall time: {stats.get('wall_time_seconds', 0):.1f}s "
              f"(fetch: {stats.get('fetch_wall_time_seconds', 0):.1f}s, "
              f"extraction: {stats.get('extraction_wall_time_seconds', 0):.1f}s)")
        print(f"  Total: {stats.get('total_success', 0)} success, "
              f"{stats.get('total_failure', 0)} failure")

        by_method = stats.get("by_method", {})
        if by_method.get("success"):
            print(f"  By method (success):")
            for method, count in by_method["success"].items():
                print(f"    {method}: {count}")
        if by_method.get("failure"):
            print(f"  By method (failure):")
            for method, count in by_method["failure"].items():
                print(f"    {method}: {count}")

        cb = stats.get("circuit_breaker", {})
        if cb.get("domains_tripped"):
            print(f"  Circuit breaker: {cb['domains_tripped']} domains tripped")
            for d in cb.get("tripped_domains", []):
                print(f"    {d}")

    # Checkpoints
    print(f"\nCheckpoints:")
    for stage in ["index", "fetch", "match", "download", "normalize"]:
        ckpt_path = config.checkpoint_path(stage)
        if ckpt_path.exists():
            data = json.loads(ckpt_path.read_text())
            completed = len(data.get("completed", []))
            exhausted = len(data.get("exhausted", []))
            print(f"  {stage}: {completed} completed, {exhausted} exhausted")

    print(f"\n{'=' * 60}\n")


if __name__ == "__main__":
    main()
