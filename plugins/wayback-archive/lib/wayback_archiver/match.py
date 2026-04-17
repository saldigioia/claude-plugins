"""
Fuzzy matching for resolving product identity across data sources.

Matches slug-based products (from HTML scraping) to SKU-based products
(from API/catalog data) using name+color compound matching with
multiple strategies.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field


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
