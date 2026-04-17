"""
Unified CDX dump parsing.

Reads a tab-delimited CDX file and produces a product index — a manifest
of every fetchable product with its era, URL type, and best Wayback URL.

Merges 3 CDX parsing variants into one configurable function driven by
URLClassifier rules from the site config.
"""
from __future__ import annotations

import re
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse, unquote


# Default junk pattern for filtering garbage URLs
DEFAULT_JUNK = re.compile(r'%22|%3[CcEe]|%7[Bb]|%5[Bb]|\[insert|:productId')


def classify_url(
    path: str,
    url_rules: list[dict],
) -> tuple[str | None, str | None]:
    """
    Classify a URL path according to the site's url_rules.
    Returns (slug, url_type) or (None, None) if no rule matches.
    """
    for rule in url_rules:
        prefix = rule.get("path_prefix")
        contains = rule.get("path_contains")

        if prefix and path.startswith(prefix):
            slug = path.removeprefix(prefix).rstrip("/")
            return slug, rule["url_type"]

        if contains and contains.replace("*", "") in path:
            # Collection-embedded: slug is after the last /products/
            if "/products/" in path:
                slug = path.split("/products/")[-1].rstrip("/")
                return slug, rule["url_type"]

    return None, None


def classify_era(
    url_type: str,
    timestamp: str,
    era_rules: list[dict],
) -> str:
    """Determine platform era from url_type, timestamp, and era_rules."""
    year = int(timestamp[:4]) if len(timestamp) >= 4 else 2020

    for rule in era_rules:
        cond = rule["condition"]
        if cond == "default":
            return rule["era"]
        if "url_type ==" in cond:
            expected = cond.split("==")[1].strip().strip("'\"")
            if url_type == expected:
                return rule["era"]
        if "timestamp_year <=" in cond:
            threshold = int(cond.split("<=")[1].strip())
            if year <= threshold:
                return rule["era"]
        if "timestamp_year >=" in cond:
            threshold = int(cond.split(">=")[1].strip())
            if year >= threshold:
                return rule["era"]

    return "unknown"


def parse_cdx(
    cdx_path: Path,
    url_rules: list[dict],
    era_rules: list[dict],
    junk_pattern: re.Pattern = DEFAULT_JUNK,
    type_priority: list[str] | None = None,
) -> dict[str, dict]:
    """
    Parse a CDX dump file and return a deduplicated product index.

    Args:
        cdx_path: Path to the tab-delimited CDX file
        url_rules: List of URL classification rules from site config
        era_rules: List of era detection rules from site config
        junk_pattern: Regex for filtering garbage URLs
        type_priority: URL type priority for dedup (first = highest)

    Returns:
        Dict of {slug: product_entry}
    """
    if type_priority is None:
        type_priority = ["api", "slug", "collection", "sku"]

    priority_map = {t: i for i, t in enumerate(type_priority)}
    candidates: dict[str, list[dict]] = defaultdict(list)

    with open(cdx_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue

            wb_url, timestamp, orig_url, status, ctype = parts[:5]

            if junk_pattern.search(orig_url):
                continue

            parsed = urlparse(orig_url)
            path = unquote(parsed.path).rstrip("/")

            slug, url_type = classify_url(path, url_rules)
            if not slug or not url_type:
                continue

            # Validate slug
            if "." in slug or "/" in slug or not slug.strip():
                continue
            slug = slug.strip()
            if junk_pattern.search(slug):
                continue

            # Check status/ctype requirements from the matching rule
            matching_rule = None
            for rule in url_rules:
                if rule["url_type"] == url_type:
                    matching_rule = rule
                    break

            if matching_rule:
                req_status = matching_rule.get("require_status")
                if req_status and status != req_status:
                    continue
                req_ctype = matching_rule.get("require_ctype")
                if req_ctype:
                    if isinstance(req_ctype, list):
                        if ctype not in req_ctype:
                            continue
                    elif ctype != req_ctype:
                        continue

            candidates[slug].append({
                "timestamp": timestamp,
                "wayback_url": wb_url,
                "original_url": orig_url,
                "status": status,
                "content_type": ctype,
                "url_type": url_type,
            })

    # Deduplicate: pick one best snapshot per product
    products = {}
    for slug, snaps in candidates.items():
        snaps.sort(key=lambda s: (
            priority_map.get(s["url_type"], 99),
            s["timestamp"],
        ))

        best = snaps[0]
        era = classify_era(best["url_type"], best["timestamp"], era_rules)

        # Build canonical original URL
        orig = re.sub(r"\?.*", "", best["original_url"]).rstrip("/")
        if not orig.startswith("https://"):
            orig = re.sub(r"^https?://", "https://", orig)
        orig = re.sub(r":80(/|$)", r"\1", orig)

        products[slug] = {
            "slug": slug,
            "url_type": best["url_type"],
            "era": era,
            "wayback_url": best["wayback_url"],
            "original_url": orig,
            "timestamp": best["timestamp"],
            "content_type": best["content_type"],
            "all_types": sorted(set(s["url_type"] for s in snaps)),
            "snapshot_count": len(snaps),
        }

    return products


def find_all_snapshots(
    cdx_path: Path,
    slugs: set[str],
    url_types: set[str] | None = None,
) -> dict[str, list[tuple[str, str]]]:
    """
    Find ALL snapshots in the CDX dump for a set of slugs.
    Returns {slug: [(wayback_url, timestamp), ...]} sorted oldest-first.
    """
    if url_types is None:
        url_types = {"text/html"}

    snapshots: dict[str, list[tuple[str, str]]] = defaultdict(list)

    with open(cdx_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue
            wb_url, ts, orig, status, ctype = parts[:5]

            if status != "200" or ctype not in url_types:
                continue

            parsed = urlparse(orig)
            path = unquote(parsed.path).rstrip("/")

            slug = None
            if path.startswith("/products/"):
                slug = path.removeprefix("/products/")
            elif path.startswith("/product/"):
                slug = path.removeprefix("/product/")
            elif "/collections/" in path and "/products/" in path:
                slug = path.split("/products/")[-1]

            if not slug or "." in slug or "/" in slug:
                continue
            slug = slug.strip()

            if slug in slugs:
                snapshots[slug].append((wb_url, ts))

    for slug in snapshots:
        snapshots[slug].sort(key=lambda x: x[1])

    return dict(snapshots)


def find_content_pages(
    cdx_path: Path,
    domains: list[str] | None = None,
) -> dict[str, list[tuple[str, str]]]:
    """
    Find non-product HTML pages that may contain product data.

    Returns {page_key: [(wayback_url, timestamp), ...]} for:
    - Homepages (``/``) across all domains and eras
    - Collection pages (``/collections/*``)
    - Special content pages (``/live``, ``/rave``, ``/shop``, etc.)
    - Data endpoints (``__data.json``, ``products.json``)

    IMPORTANT: E-commerce homepages often function AS product pages,
    especially in earlier eras. A site's homepage in 2020 might show a
    completely different product lineup than in 2024. Always sample
    homepage captures across multiple years to catch era-specific products.
    """
    CONTENT_PATHS = {'/', '/live', '/rave', '/shop', '/us'}
    pages: dict[str, list[tuple[str, str]]] = defaultdict(list)

    with open(cdx_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue
            wb_url, ts, orig, status, ctype = parts[:5]
            if status != "200":
                continue
            if "html" not in ctype and "json" not in ctype:
                continue

            parsed = urlparse(orig)
            domain = parsed.hostname
            if domain:
                domain = domain.lower().replace(":80", "")
            if domains and domain not in domains:
                continue

            path = unquote(parsed.path).rstrip("/") or "/"

            # Skip product pages (handled by parse_cdx)
            if "/products/" in path and "products.json" not in path:
                continue
            # Skip junk paths
            if any(x in path for x in ("wpm@", "cdn-cgi", ".well-known/shopify/monorail")):
                continue

            # Capture homepages
            if path in CONTENT_PATHS:
                pages[f"{domain}{path}"].append((wb_url, ts))

            # Capture collection pages
            elif "/collections/" in path:
                # Strip query params from key
                clean_path = path.split("?")[0]
                pages[f"{domain}{clean_path}"].append((wb_url, ts))

            # Capture data endpoints
            elif path.endswith("__data.json") or path.endswith("products.json"):
                pages[f"{domain}{path}"].append((wb_url, ts))

    # Sort by timestamp within each page
    for key in pages:
        pages[key].sort(key=lambda x: x[1])

    return dict(pages)


def find_catalog_api_urls(
    cdx_path: Path,
    api_patterns: list[str],
) -> list[tuple[str, str, str]]:
    """
    Find all catalog API snapshots (bloom/archive/products) in CDX dump.
    Returns [(wayback_url, timestamp, api_type), ...] sorted by timestamp.
    """
    urls = []
    with open(cdx_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue
            wb_url, ts, orig, status, ctype = parts[:5]
            if status != "200":
                continue

            for pattern in api_patterns:
                label = pattern.rstrip("/").split("/")[-1]
                if pattern in orig:
                    urls.append((wb_url, ts, label))
                    break

    urls.sort(key=lambda x: x[1])
    return urls
