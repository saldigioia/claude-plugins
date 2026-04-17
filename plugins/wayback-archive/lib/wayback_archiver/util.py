"""
Shared utilities for the archival pipeline.

Directory name construction, sanitization, and slug mapping.
"""
from __future__ import annotations

import re
from pathlib import Path


# Characters illegal in directory/file names
_SANITIZE_RE = re.compile(r'[/:*?"<>|]')


def sanitize_dirname(name: str) -> str:
    """Remove characters illegal in directory names."""
    return _SANITIZE_RE.sub('', name).strip()


def build_dirname(name: str, date: str | None = None) -> str:
    """Build a product directory name from name and optional date prefix."""
    if date:
        return sanitize_dirname(f"{date} {name}")
    return sanitize_dirname(name)


def build_dir_to_slug_map(metadata: dict) -> dict[str, str]:
    """
    Build a mapping from directory name -> slug.
    Used to find which slug corresponds to a given product directory.
    """
    dir_to_slug = {}
    for slug, meta in metadata.items():
        product_name = meta.get("name", slug.replace("-", " ").title())
        date_str = meta.get("date", "")
        dir_name = build_dirname(product_name, date_str if date_str else None)
        dir_to_slug[dir_name] = slug
    return dir_to_slug


def find_empty_dirs(products_dir: Path, dir_to_slug: dict[str, str]) -> set[str]:
    """Find product slugs whose directories exist but contain no images."""
    from .normalize import IMAGE_EXTENSIONS

    empty = set()
    for d in products_dir.iterdir():
        if not d.is_dir():
            continue
        images = [f for f in d.iterdir() if f.suffix.lower() in IMAGE_EXTENSIONS]
        if not images:
            slug = dir_to_slug.get(d.name)
            if slug:
                empty.add(slug)
    return empty


def find_product_dir(
    slug: str,
    metadata: dict,
    products_dir: Path,
) -> Path | None:
    """Find the product directory for a given slug."""
    meta = metadata.get(slug, {})
    name = meta.get("name", slug.replace("-", " ").title())
    date = meta.get("date", "")
    dir_name = build_dirname(name, date if date else None)
    d = products_dir / dir_name
    if d.exists():
        return d

    # Fallback: check by SKU field
    for s, m in metadata.items():
        if m.get("sku") == slug:
            name = m.get("name", s)
            date = m.get("date", "")
            dir_name = build_dirname(name, date if date else None)
            d = products_dir / dir_name
            if d.exists():
                return d

    return None
