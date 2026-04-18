"""
Fuzzy matching for resolving product identity across data sources.

Matches slug-based products (from HTML scraping) to SKU-based products
(from API/catalog data) using name+color compound matching with
multiple strategies.
"""
from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field
from pathlib import PurePosixPath
from urllib.parse import urlparse, unquote

# Shopify-style UUID suffix (e.g. ``_a1b2c3d4-e5f6-...`` just before ``.jpg``).
# Shared with download.canonicalize_image_url; duplicated here so match.py
# stays importable without pulling download.py's requests dependency.
_UUID_SUFFIX_RE = re.compile(
    r'_[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}(?=\.\w+)?'
)
# Generic size suffixes: _800x, _800x800, _800x@2x.
_SIZE_SUFFIX_RE = re.compile(r'_(?:\d+|\{width\})x\d*(?:@\dx)?(?=\.\w+|$)')
_NAMED_SIZE_RE = re.compile(
    r'_(?:grande|medium|small|large|compact|master|pico|icon|thumb)(?=\.\w+|$)'
)
# First alphanumeric token as a SKU candidate.  Matches Adidas-style style
# codes (``GX9662``), Yeezy-style (``YZ6U1055``), and Kanye merch
# (``KW5M5001``) — 6-to-12 chars of uppercase letters and digits.
_SKU_PREFIX_RE = re.compile(r'^([A-Z0-9]{6,12})[_\-.]')

# Minimum difflib ratio for the fuzzy fallback to accept a slug match.
# Below this the risk of cross-attribution is too high to justify the match.
_FUZZY_SLUG_THRESHOLD = 0.85


def normalize_for_match(text: str) -> str:
    """Normalize a string for fuzzy matching."""
    text = text.lower().strip()
    text = re.sub(r'[^a-z0-9]+', '-', text)
    text = text.strip("-")
    text = re.sub(r'^adidas-', '', text)
    return text


def build_slug_match_key(slug: str) -> str:
    """Build a match key from a product slug."""
    key = slug.lower()
    key = re.sub(r'^adidas-', '', key)
    key = re.sub(r'-\d{4}$', '', key)  # trailing date-like patterns
    key = re.sub(r'-\d$', '', key)     # trailing -1, -2 suffixes
    return key


def build_api_match_key(name: str, color: str | None) -> str:
    """Build a match key from API product name + color."""
    parts = [name.lower()]
    if color:
        parts.append(color.lower())
    text = " ".join(parts)
    text = re.sub(r'[^a-z0-9]+', '-', text).strip("-")
    text = re.sub(r'^adidas-', '', text)
    text = re.sub(r'-adults?$', '', text)
    text = re.sub(r'-infants?$', '', text)
    text = re.sub(r'-kids?$', '', text)
    return text


@dataclass
class MatchResult:
    """Result of matching products across data sources."""
    matched: dict[str, str] = field(default_factory=dict)      # slug -> sku
    unmatched_slugs: list[str] = field(default_factory=list)
    unmatched_skus: list[str] = field(default_factory=list)
    new_products: list[dict] = field(default_factory=list)


def match_products(
    slug_products: dict[str, dict],
    sku_products: dict[str, dict],
) -> MatchResult:
    """
    Match slug-based products to SKU-based products using 3 strategies:
    1. Exact match key
    2. Substring containment (either direction)
    3. Name-only + color compound match

    Args:
        slug_products: {slug: metadata} for products needing matches
        sku_products: {sku: {name, color, ...}} from API/catalog data

    Returns:
        MatchResult with matched pairs, unmatched from both sides, and new products
    """
    result = MatchResult()

    # Build slug match index
    slug_keys: dict[str, str] = {}  # match_key -> slug
    for slug in slug_products:
        key = build_slug_match_key(slug)
        slug_keys[key] = slug

    matched_slugs = set()

    for sku, data in sorted(sku_products.items()):
        name = data.get("name", "")
        color = data.get("color", "")
        api_key = build_api_match_key(name, color)

        matched_slug = None

        # Strategy 1: exact key match
        if api_key in slug_keys:
            matched_slug = slug_keys[api_key]

        # Strategy 2: substring containment
        if not matched_slug:
            for skey, slug in slug_keys.items():
                if slug in matched_slugs:
                    continue
                if api_key and skey and (api_key in skey or skey in api_key):
                    matched_slug = slug
                    break

        # Strategy 3: name-only + color compound
        if not matched_slug and name:
            name_only = normalize_for_match(name)
            for skey, slug in slug_keys.items():
                if slug in matched_slugs:
                    continue
                if name_only and name_only in skey:
                    if color and normalize_for_match(color) in skey:
                        matched_slug = slug
                        break

        if matched_slug:
            result.matched[matched_slug] = sku
            matched_slugs.add(matched_slug)
        else:
            result.unmatched_skus.append(sku)

    # Find unmatched slugs
    result.unmatched_slugs = [
        slug for slug in slug_products if slug not in matched_slugs
    ]

    return result


def build_sku_to_slug_map(metadata: dict) -> dict[str, str]:
    """Return {SKU (upper) -> slug} for every metadata entry with a SKU.

    Entries that share a SKU collapse to a single slug (the first seen); that's
    the correct behavior for CDN attribution, where two slugs + one SKU means
    either a duplicate handle or a re-issue of the same physical product.
    """
    out: dict[str, str] = {}
    for slug, meta in metadata.items():
        sku = meta.get("sku") or meta.get("matched_sku")
        if not sku:
            continue
        key = str(sku).strip().upper()
        if key and key not in out:
            out[key] = slug
    return out


def _image_basename(url_or_filename: str) -> str:
    """Extract just the bare filename from a URL or path, lowercased."""
    s = url_or_filename.strip()
    if "://" in s:
        try:
            s = unquote(urlparse(s).path)
        except ValueError:
            pass
    return PurePosixPath(s).name.lower()


def _canonical_image_stem(url_or_filename: str) -> str:
    """Strip size/named/UUID suffixes and the extension from an image filename."""
    name = _image_basename(url_or_filename)
    name = _UUID_SUFFIX_RE.sub("", name)
    name = _SIZE_SUFFIX_RE.sub("", name)
    name = _NAMED_SIZE_RE.sub("", name)
    name = re.sub(r"\.\w+$", "", name)
    return name


def resolve_image_to_slug(
    url_or_filename: str,
    slug_set: set[str] | list[str],
    sku_map: dict[str, str] | None = None,
    strategy: str = "aggressive",
) -> str | None:
    """Best-effort attribution of a CDN image URL/filename to a product slug.

    Cascade:
      1. Strip UUID / size / named-size suffixes, lowercase, drop extension.
      2. Exact slug hit against ``slug_set``.
      3. ``{slug}__…`` prefix split — the existing pipeline convention.
      4. SKU prefix extraction → ``sku_map`` lookup (e.g. ``KW5M5001``).
      5. ``strategy == "aggressive"`` only: difflib fuzzy match with a 0.85
         floor against the full slug set. Strict mode returns None here.

    ``strategy`` values:
      - ``"strict"``: exact + prefix + SKU map only. No fuzzy fallback.
      - ``"aggressive"``: adds the difflib fallback. Higher recall, ~3–5%
        false-attribution risk in practice on noisy Shopify catalogs.
    """
    if not url_or_filename:
        return None

    slugs = slug_set if isinstance(slug_set, set) else set(slug_set)
    canon = _canonical_image_stem(url_or_filename)
    if not canon:
        return None

    # 1. Direct hit.
    if canon in slugs:
        return canon

    # 2. products__<slug>__<tail> or slug__tail split convention.
    parts = canon.split("__")
    if len(parts) >= 2:
        for cand in (parts[-1], parts[-2]):
            if cand in slugs:
                return cand

    # 3. SKU prefix extraction.
    if sku_map:
        raw = _image_basename(url_or_filename)
        m = _SKU_PREFIX_RE.match(raw.upper())
        if m:
            hit = sku_map.get(m.group(1))
            if hit:
                return hit

    # 4. Substring containment — narrow but cheap.
    candidate = parts[-1] if parts else canon
    for slug in slugs:
        if candidate and (slug.startswith(candidate) or candidate in slug):
            return slug

    # 5. Fuzzy fallback (aggressive only).
    if strategy == "aggressive":
        best = difflib.get_close_matches(
            candidate, slugs, n=1, cutoff=_FUZZY_SLUG_THRESHOLD
        )
        if best:
            return best[0]

    return None
