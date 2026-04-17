#!/usr/bin/env python3
"""
shopify_downloader.py — Shopify CDN Archaeology Tool

Discovers and downloads ALL images from a Shopify store, including
historical/delisted products whose CDN assets are still alive.

Discovery layers (run in order, each adds to a unified URL set):
  1. Storefront API   — GraphQL with embedded access token (highest fidelity)
  2. Live storefront  — /products.json, /collections.json, /sitemap.xml
  3. Wayback CDX      — all URLs ever archived for the store domain + CDN prefix
  4. CDN liveness     — HEAD-check every discovered CDN URL against live CDN

Usage:
  # Full archaeological dig (all layers)
  python shopify_downloader.py --store mystore.myshopify.com

  # With known access token (skips auto-discovery)
  python shopify_downloader.py --store yeezygap.myshopify.com --access-token 5d51a4104fa56f5aa34f37dd503f7b11

  # Live store only (no Wayback)
  python shopify_downloader.py --store mystore.com --skip-wayback

  # Wayback-only (store is dead)
  python shopify_downloader.py --store mystore.com --wayback-only

  # Just build the manifest, don't download
  python shopify_downloader.py --store mystore.com --manifest-only

  # Resume downloads from a saved manifest
  python shopify_downloader.py --from-manifest shopify_mystore/manifest.json

  # CDX dump only (raw URL list, no download)
  python shopify_downloader.py --store mystore.com --cdx-dump
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse, quote, unquote

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/123.0 Safari/537.36"
)
CONNECT_TIMEOUT = 15
READ_TIMEOUT = 120
PAGE_LIMIT = 250          # Shopify /products.json max per page
CDX_PAGE_SIZE = 10000     # Wayback CDX results per page
CDX_DELAY = 1.0           # Seconds between CDX pages (be polite)
STOREFRONT_API_VERSION = "2024-01"  # Shopify Storefront API version

IMAGE_EXTENSIONS = frozenset({
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".bmp", ".tiff",
})

# Shopify CDN file categories we care about
CDN_ASSET_DIRS = ("products", "files", "collections", "articles", "t")


def build_session() -> requests.Session:
    retry = Retry(
        total=5,
        backoff_factor=1.0,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(["GET", "HEAD", "POST"]),
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry, pool_connections=64, pool_maxsize=64)
    s = requests.Session()
    s.headers.update({"User-Agent": USER_AGENT})
    s.mount("http://", adapter)
    s.mount("https://", adapter)
    return s


SESSION = build_session()


# ---------------------------------------------------------------------------
# Store URL helpers
# ---------------------------------------------------------------------------

def normalise_store_url(store: str) -> str:
    store = store.strip().rstrip("/")
    if not store.startswith(("http://", "https://")):
        store = f"https://{store}"
    parsed = urlparse(store)
    return f"{parsed.scheme}://{parsed.netloc}"


def store_slug(base_url: str) -> str:
    host = urlparse(base_url).netloc
    for suffix in (".myshopify.com", ".com", ".co", ".io", ".net", ".org"):
        if host.endswith(suffix):
            host = host[: -len(suffix)]
            break
    return re.sub(r"[^a-zA-Z0-9_-]", "_", host)


def store_domain(base_url: str) -> str:
    return urlparse(base_url).netloc


# ---------------------------------------------------------------------------
# CDN prefix discovery
# ---------------------------------------------------------------------------

_CDN_PREFIX_RE = re.compile(
    r"cdn\.shopify\.com/s/files/1/(\d{4}/\d{4})"
)

_CDN_PREFIX_ALT_RE = re.compile(
    r"cdn\.shopify\.com/s/files/(\d+/\d+/\d+)"
)


def discover_cdn_prefix(base_url: str) -> str | None:
    """
    Scrape the store's homepage to find the CDN file prefix.

    Shopify CDN URLs look like:
      cdn.shopify.com/s/files/1/XXXX/XXXX/products/image.jpg
      cdn.shopify.com/s/files/1/XXXX/XXXX/files/image.jpg

    Returns the prefix path like "1/0123/4567" or None.
    """
    print(f"Discovering CDN prefix from {base_url} ...")
    try:
        resp = SESSION.get(base_url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
        if resp.status_code != 200:
            print(f"  Homepage returned {resp.status_code}")
            return None

        text = resp.text

        # Try the standard 1/XXXX/XXXX pattern
        m = _CDN_PREFIX_RE.search(text)
        if m:
            prefix = f"1/{m.group(1)}"
            print(f"  Found CDN prefix: {prefix}")
            return prefix

        m = _CDN_PREFIX_ALT_RE.search(text)
        if m:
            prefix = m.group(1)
            print(f"  Found CDN prefix: {prefix}")
            return prefix

        print("  Could not find CDN prefix in homepage HTML.")
        return None

    except requests.RequestException as e:
        print(f"  Failed to fetch homepage: {e}")
        return None


# ---------------------------------------------------------------------------
# Access token discovery
# ---------------------------------------------------------------------------

_ACCESS_TOKEN_RE = re.compile(
    r'"accessToken"\s*:\s*"([a-f0-9]{32})"'
)

_CHECKOUT_TOKEN_RE = re.compile(
    r'name="shopify-checkout-api-token"\s+content="([a-f0-9]{32})"'
)


def discover_access_token(base_url: str, myshopify_url: str | None = None) -> str | None:
    """
    Extract the Storefront API access token from the store's HTML.

    Shopify embeds it in:
      - <script id="shopify-features"> JSON as "accessToken"
      - <meta name="shopify-checkout-api-token" content="...">
    """
    targets = [base_url]
    if myshopify_url and myshopify_url != base_url:
        targets.append(myshopify_url)

    for url in targets:
        print(f"  Checking {url} for access token ...")
        try:
            resp = SESSION.get(url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
            if resp.status_code != 200:
                continue

            m = _ACCESS_TOKEN_RE.search(resp.text)
            if m:
                token = m.group(1)
                print(f"  Found access token: {token[:8]}...{token[-4:]}")
                return token

            m = _CHECKOUT_TOKEN_RE.search(resp.text)
            if m:
                token = m.group(1)
                print(f"  Found checkout token: {token[:8]}...{token[-4:]}")
                return token

        except requests.RequestException as e:
            print(f"  Failed: {e}")

    # Try Wayback as last resort
    print(f"  Trying Wayback for access token ...")
    try:
        resp = SESSION.get(
            f"https://web.archive.org/web/2id_/{base_url}/",
            timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
        )
        if resp.status_code == 200:
            m = _ACCESS_TOKEN_RE.search(resp.text)
            if m:
                token = m.group(1)
                print(f"  Found access token from Wayback: {token[:8]}...{token[-4:]}")
                return token
            m = _CHECKOUT_TOKEN_RE.search(resp.text)
            if m:
                token = m.group(1)
                print(f"  Found checkout token from Wayback: {token[:8]}...{token[-4:]}")
                return token
    except requests.RequestException:
        pass

    print("  No access token found.")
    return None


# ---------------------------------------------------------------------------
# Layer 1: Storefront API (GraphQL)
# ---------------------------------------------------------------------------

_PRODUCTS_QUERY = """
query ($cursor: String) {
  products(first: 250, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    edges {
      node {
        id
        title
        handle
        vendor
        productType
        tags
        createdAt
        updatedAt
        images(first: 250) {
          edges {
            node {
              url
              altText
              width
              height
            }
          }
        }
        variants(first: 250) {
          edges {
            node {
              id
              title
              sku
              price { amount currencyCode }
              image { url }
            }
          }
        }
      }
    }
  }
}
"""

_COLLECTIONS_QUERY = """
query ($cursor: String) {
  collections(first: 250, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    edges {
      node {
        id
        title
        handle
        image { url }
        products(first: 250) {
          edges {
            node {
              id
              handle
              images(first: 250) {
                edges {
                  node { url width height }
                }
              }
            }
          }
        }
      }
    }
  }
}
"""


def storefront_graphql(
    myshopify_domain: str, access_token: str, query: str, variables: dict | None = None
) -> dict | None:
    """Execute a Storefront API GraphQL query."""
    url = f"https://{myshopify_domain}/api/{STOREFRONT_API_VERSION}/graphql.json"
    headers = {
        "X-Shopify-Storefront-Access-Token": access_token,
        "Content-Type": "application/json",
    }
    payload = {"query": query}
    if variables:
        payload["variables"] = variables

    try:
        resp = SESSION.post(
            url, json=payload, headers=headers,
            timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
        )
        if resp.status_code != 200:
            return None
        data = resp.json()
        if "errors" in data:
            print(f"    GraphQL errors: {data['errors'][:2]}")
            return None
        return data.get("data")
    except (requests.RequestException, json.JSONDecodeError) as e:
        print(f"    GraphQL request failed: {e}")
        return None


def discover_via_storefront_api(
    myshopify_domain: str, access_token: str
) -> tuple[list[dict], list[dict], set[str]]:
    """
    Query the Storefront API for all products, collections, and CDN URLs.

    Returns (products, collections, cdn_urls).
    """
    print(f"\n[Layer 1] Storefront API: {myshopify_domain}")

    products: list[dict] = []
    cdn_urls: set[str] = set()
    cursor: str | None = None

    # --- Products ---
    while True:
        variables = {"cursor": cursor} if cursor else {}
        data = storefront_graphql(myshopify_domain, access_token, _PRODUCTS_QUERY, variables)
        if not data or "products" not in data:
            if not products:
                print("  Storefront API returned no product data.")
            break

        page = data["products"]
        edges = page.get("edges", [])

        for edge in edges:
            node = edge["node"]
            product = {
                "id": node.get("id"),
                "title": node.get("title"),
                "handle": node.get("handle"),
                "vendor": node.get("vendor"),
                "product_type": node.get("productType"),
                "tags": node.get("tags", []),
                "created_at": node.get("createdAt"),
                "updated_at": node.get("updatedAt"),
                "images": [],
                "variants": [],
            }

            for img_edge in node.get("images", {}).get("edges", []):
                img = img_edge["node"]
                url = img.get("url", "")
                if url:
                    clean = url.split("?")[0]
                    cdn_urls.add(clean)
                    product["images"].append({
                        "src": clean,
                        "alt": img.get("altText"),
                        "width": img.get("width"),
                        "height": img.get("height"),
                    })

            for var_edge in node.get("variants", {}).get("edges", []):
                var = var_edge["node"]
                product["variants"].append({
                    "id": var.get("id"),
                    "title": var.get("title"),
                    "sku": var.get("sku"),
                    "price": var.get("price"),
                })
                # Variant-specific image
                var_img = var.get("image")
                if var_img and var_img.get("url"):
                    cdn_urls.add(var_img["url"].split("?")[0])

            products.append(product)

        print(f"  Products page: +{len(edges)} (total: {len(products)}, CDN URLs: {len(cdn_urls)})")

        page_info = page.get("pageInfo", {})
        if not page_info.get("hasNextPage"):
            break
        cursor = page_info.get("endCursor")
        time.sleep(0.3)

    # --- Collections ---
    collections: list[dict] = []
    cursor = None

    while True:
        variables = {"cursor": cursor} if cursor else {}
        data = storefront_graphql(myshopify_domain, access_token, _COLLECTIONS_QUERY, variables)
        if not data or "collections" not in data:
            break

        page = data["collections"]
        edges = page.get("edges", [])

        for edge in edges:
            node = edge["node"]
            coll = {
                "id": node.get("id"),
                "title": node.get("title"),
                "handle": node.get("handle"),
            }
            collections.append(coll)

            # Collection image
            coll_img = node.get("image")
            if coll_img and coll_img.get("url"):
                cdn_urls.add(coll_img["url"].split("?")[0])

            # Products within collection (may surface hidden products)
            for prod_edge in node.get("products", {}).get("edges", []):
                prod_node = prod_edge["node"]
                for img_edge in prod_node.get("images", {}).get("edges", []):
                    url = img_edge["node"].get("url", "")
                    if url:
                        cdn_urls.add(url.split("?")[0])

        print(f"  Collections page: +{len(edges)} (total: {len(collections)})")

        page_info = page.get("pageInfo", {})
        if not page_info.get("hasNextPage"):
            break
        cursor = page_info.get("endCursor")
        time.sleep(0.3)

    print(
        f"  Storefront API: {len(products)} products, "
        f"{len(collections)} collections, {len(cdn_urls)} CDN URLs"
    )

    return products, collections, cdn_urls


# ---------------------------------------------------------------------------
# Layer 2: Live storefront discovery (/products.json fallback)
# ---------------------------------------------------------------------------

def discover_products(base_url: str) -> list[dict]:
    """Paginate /products.json for all currently listed products."""
    products: list[dict] = []
    page = 1

    print(f"\n[Layer 2] Live storefront: {base_url}/products.json")

    while True:
        url = f"{base_url}/products.json?limit={PAGE_LIMIT}&page={page}"
        try:
            resp = SESSION.get(url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
        except requests.RequestException as e:
            print(f"  Request failed on page {page}: {e}")
            break

        if resp.status_code == 404:
            print("  Store does not expose /products.json (404).")
            break
        if resp.status_code != 200:
            print(f"  HTTP {resp.status_code} on page {page}: {resp.text[:200]}")
            break

        try:
            data = resp.json()
        except json.JSONDecodeError:
            print(f"  Invalid JSON on page {page}")
            break

        batch = data.get("products", [])
        if not batch:
            break

        products.extend(batch)
        print(f"  page {page}: +{len(batch)} products (total: {len(products)})")

        if len(batch) < PAGE_LIMIT:
            break

        page += 1
        time.sleep(0.5)

    print(f"  Live products: {len(products)}")
    return products


def discover_collections(base_url: str) -> list[dict]:
    """Paginate /collections.json."""
    collections: list[dict] = []
    page = 1

    print(f"  Collections: {base_url}/collections.json")

    while True:
        url = f"{base_url}/collections.json?limit={PAGE_LIMIT}&page={page}"
        try:
            resp = SESSION.get(url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
        except requests.RequestException as e:
            break

        if resp.status_code != 200:
            break

        try:
            data = resp.json()
        except json.JSONDecodeError:
            break

        batch = data.get("collections", [])
        if not batch:
            break

        collections.extend(batch)
        if len(batch) < PAGE_LIMIT:
            break

        page += 1
        time.sleep(0.5)

    print(f"  Live collections: {len(collections)}")
    return collections


def discover_sitemap_urls(base_url: str) -> set[str]:
    """Parse /sitemap.xml for product and image URLs."""
    urls: set[str] = set()
    print(f"  Sitemap: {base_url}/sitemap.xml")

    try:
        resp = SESSION.get(
            f"{base_url}/sitemap.xml", timeout=(CONNECT_TIMEOUT, READ_TIMEOUT)
        )
        if resp.status_code != 200:
            print(f"    No sitemap ({resp.status_code})")
            return urls
    except requests.RequestException:
        return urls

    # Parse sitemap index to find child sitemaps
    child_sitemaps = _parse_sitemap_index(resp.text)
    if child_sitemaps:
        print(f"    Sitemap index with {len(child_sitemaps)} child sitemaps")
        for sm_url in child_sitemaps:
            urls.update(_parse_sitemap(sm_url))
            time.sleep(0.3)
    else:
        urls.update(_extract_urls_from_sitemap_xml(resp.text))

    cdn_urls = {u for u in urls if "cdn.shopify.com" in u}
    print(f"    Sitemap: {len(urls)} URLs total, {len(cdn_urls)} CDN URLs")
    return urls


def _parse_sitemap_index(xml_text: str) -> list[str]:
    """Extract child sitemap URLs from a sitemap index."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []

    ns = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    return [
        loc.text.strip()
        for loc in root.findall(".//sm:sitemap/sm:loc", ns)
        if loc.text
    ]


def _parse_sitemap(url: str) -> set[str]:
    """Fetch and parse a single sitemap for URLs."""
    try:
        resp = SESSION.get(url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
        if resp.status_code != 200:
            return set()
    except requests.RequestException:
        return set()

    return _extract_urls_from_sitemap_xml(resp.text)


def _extract_urls_from_sitemap_xml(xml_text: str) -> set[str]:
    """Extract all <loc> and <image:loc> URLs from sitemap XML."""
    urls: set[str] = set()
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return urls

    ns = {
        "sm": "http://www.sitemaps.org/schemas/sitemap/0.9",
        "image": "http://www.google.com/schemas/sitemap-image/1.1",
    }

    # Standard <loc> URLs
    for loc in root.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc"):
        if loc.text:
            urls.add(loc.text.strip())

    # Image <image:loc> URLs
    for loc in root.findall(
        ".//{http://www.google.com/schemas/sitemap-image/1.1}loc"
    ):
        if loc.text:
            urls.add(loc.text.strip())

    return urls


def extract_cdn_urls_from_products(products: list[dict]) -> set[str]:
    """Pull every CDN URL from the product JSON."""
    urls: set[str] = set()
    for p in products:
        for img in p.get("images", []):
            src = img.get("src", "")
            if src:
                urls.add(src.split("?")[0])
        # Featured image
        fi = p.get("image", {})
        if isinstance(fi, dict) and fi.get("src"):
            urls.add(fi["src"].split("?")[0])
    return urls


# ---------------------------------------------------------------------------
# Layer 3: Wayback Machine CDX discovery
# ---------------------------------------------------------------------------

def cdx_query(
    url_pattern: str,
    match_type: str = "prefix",
    filters: list[str] | None = None,
    collapse: str | None = None,
) -> list[list[str]]:
    """
    Query the Wayback Machine CDX API.

    Returns rows of [urlkey, timestamp, original, mimetype, statuscode, digest, length].
    """
    params: dict[str, str] = {
        "url": url_pattern,
        "output": "json",
        "matchType": match_type,
        "fl": "urlkey,timestamp,original,mimetype,statuscode,digest,length",
        "pageSize": str(CDX_PAGE_SIZE),
    }
    if collapse:
        params["collapse"] = collapse
    if filters:
        params["filter"] = filters

    all_rows: list[list[str]] = []
    page = 0

    while True:
        params["page"] = str(page)
        try:
            resp = SESSION.get(
                "https://web.archive.org/cdx/search/cdx",
                params=params,
                timeout=(CONNECT_TIMEOUT, 180),
            )
        except requests.RequestException as e:
            print(f"    CDX request failed on page {page}: {e}")
            break

        if resp.status_code == 404:
            break
        if resp.status_code != 200:
            print(f"    CDX HTTP {resp.status_code} on page {page}")
            break

        try:
            data = resp.json()
        except (json.JSONDecodeError, ValueError):
            # Sometimes CDX returns empty or malformed
            break

        if not data:
            break

        # First row of first page is the header
        if page == 0 and data and isinstance(data[0], list):
            header = data[0]
            rows = data[1:]
        else:
            rows = data

        if not rows:
            break

        all_rows.extend(rows)
        print(f"    CDX page {page}: +{len(rows)} records (total: {len(all_rows)})")

        if len(rows) < CDX_PAGE_SIZE:
            break

        page += 1
        time.sleep(CDX_DELAY)

    return all_rows


def discover_wayback_cdn_urls(
    domain: str, cdn_prefix: str | None
) -> tuple[set[str], list[dict]]:
    """
    Query Wayback CDX for all historical CDN image URLs.

    Returns:
      - set of CDN image URLs
      - list of CDX record dicts for the manifest
    """
    print(f"\n[Layer 3] Wayback Machine CDX discovery")

    all_cdn_urls: set[str] = set()
    cdx_records: list[dict] = []

    # Strategy 1: Query CDN prefix directly (most productive)
    if cdn_prefix:
        cdn_pattern = f"cdn.shopify.com/s/files/{cdn_prefix}/"
        print(f"  Querying CDN prefix: {cdn_pattern}*")
        rows = cdx_query(
            cdn_pattern,
            match_type="prefix",
            collapse="urlkey",  # deduplicate by URL
        )
        for row in rows:
            url = row[2] if len(row) > 2 else ""
            mimetype = row[3] if len(row) > 3 else ""
            status = row[4] if len(row) > 4 else ""

            if not url:
                continue

            clean = url.split("?")[0]
            ext = Path(urlparse(clean).path).suffix.lower()

            if ext in IMAGE_EXTENSIONS or "image" in mimetype:
                all_cdn_urls.add(clean)
                cdx_records.append({
                    "url": clean,
                    "timestamp": row[1] if len(row) > 1 else "",
                    "mimetype": mimetype,
                    "status": status,
                    "digest": row[5] if len(row) > 5 else "",
                    "source": "cdx_cdn_prefix",
                })

        print(f"    CDN prefix: {len(all_cdn_urls)} unique image URLs")

    # Strategy 2: Query store domain for product pages (to find CDN refs)
    print(f"  Querying store domain: {domain}/products/*")
    product_rows = cdx_query(
        f"{domain}/products/",
        match_type="prefix",
        collapse="urlkey",
    )
    product_page_urls: set[str] = set()
    for row in product_rows:
        url = row[2] if len(row) > 2 else ""
        status = row[4] if len(row) > 4 else ""
        if url and status in ("200", "301", "302", ""):
            # Only product pages, not assets
            clean = url.split("?")[0]
            if not Path(urlparse(clean).path).suffix:
                product_page_urls.add(clean)
            elif clean.endswith(".json"):
                product_page_urls.add(clean)

    print(f"    Product page URLs: {len(product_page_urls)}")

    # Strategy 3: Query for archived sitemaps
    print(f"  Querying archived sitemaps: {domain}/sitemap*")
    sitemap_rows = cdx_query(
        f"{domain}/sitemap",
        match_type="prefix",
        collapse="urlkey",
    )
    archived_sitemaps: set[str] = set()
    for row in sitemap_rows:
        url = row[2] if len(row) > 2 else ""
        ts = row[1] if len(row) > 1 else ""
        if url and ts:
            # Build Wayback URL to fetch the archived sitemap
            archived_sitemaps.add(
                f"https://web.archive.org/web/{ts}id_/{url}"
            )
    print(f"    Archived sitemaps: {len(archived_sitemaps)}")

    # Strategy 4: Mine product .json endpoints from Wayback
    print(f"  Querying product JSON endpoints: {domain}/products/*.json")
    json_rows = cdx_query(
        f"{domain}/products/",
        match_type="prefix",
        filters=["mimetype:application/json"],
        collapse="urlkey",
    )
    product_json_urls: set[str] = set()
    for row in json_rows:
        url = row[2] if len(row) > 2 else ""
        ts = row[1] if len(row) > 1 else ""
        if url and ".json" in url:
            product_json_urls.add(
                f"https://web.archive.org/web/{ts}id_/{url}"
            )
    print(f"    Archived product JSONs: {len(product_json_urls)}")

    total_before = len(all_cdn_urls)

    # Fetch archived product JSONs to extract CDN URLs
    if product_json_urls:
        print(f"  Fetching {len(product_json_urls)} archived product JSONs ...")
        new_from_json = _extract_cdn_from_wayback_json(product_json_urls)
        all_cdn_urls.update(new_from_json)
        for u in new_from_json:
            cdx_records.append({
                "url": u,
                "timestamp": "",
                "mimetype": "",
                "status": "",
                "digest": "",
                "source": "wayback_product_json",
            })
        print(f"    +{len(new_from_json)} CDN URLs from archived product JSONs")

    # Fetch archived sitemaps to extract CDN URLs
    if archived_sitemaps:
        print(f"  Fetching {min(len(archived_sitemaps), 20)} archived sitemaps ...")
        new_from_sitemaps = _extract_cdn_from_wayback_sitemaps(archived_sitemaps)
        all_cdn_urls.update(new_from_sitemaps)
        for u in new_from_sitemaps:
            cdx_records.append({
                "url": u,
                "timestamp": "",
                "mimetype": "",
                "status": "",
                "digest": "",
                "source": "wayback_sitemap",
            })
        print(f"    +{len(new_from_sitemaps)} CDN URLs from archived sitemaps")

    print(
        f"\n  Wayback total: {len(all_cdn_urls)} unique CDN image URLs "
        f"({len(all_cdn_urls) - total_before} new from JSON/sitemap mining)"
    )

    return all_cdn_urls, cdx_records


def _extract_cdn_from_wayback_json(
    wayback_urls: set[str], max_fetch: int = 200
) -> set[str]:
    """Fetch archived product JSONs and extract CDN image URLs."""
    cdn_urls: set[str] = set()
    cdn_re = re.compile(r"https?://cdn\.shopify\.com/[^\s\"'<>]+\.(?:jpg|jpeg|png|gif|webp|avif)", re.I)

    fetched = 0
    for wb_url in sorted(wayback_urls):
        if fetched >= max_fetch:
            break
        try:
            resp = SESSION.get(wb_url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
            if resp.status_code != 200:
                continue
            fetched += 1

            # Try parsing as JSON first
            try:
                data = resp.json()
                product = data.get("product", data)
                for img in product.get("images", []):
                    src = img.get("src", "")
                    if src and "cdn.shopify.com" in src:
                        cdn_urls.add(src.split("?")[0])
            except (json.JSONDecodeError, ValueError, AttributeError):
                # Fallback: regex extract CDN URLs from the response text
                for match in cdn_re.findall(resp.text):
                    cdn_urls.add(match.split("?")[0])

            if fetched % 25 == 0:
                print(f"    ...fetched {fetched} JSONs, {len(cdn_urls)} CDN URLs")

        except requests.RequestException:
            continue
        time.sleep(0.3)

    return cdn_urls


def _extract_cdn_from_wayback_sitemaps(
    wayback_urls: set[str], max_fetch: int = 20
) -> set[str]:
    """Fetch archived sitemaps and extract CDN image URLs."""
    cdn_urls: set[str] = set()
    cdn_re = re.compile(r"https?://cdn\.shopify\.com/[^\s\"'<>]+\.(?:jpg|jpeg|png|gif|webp|avif)", re.I)

    fetched = 0
    for wb_url in sorted(wayback_urls):
        if fetched >= max_fetch:
            break
        try:
            resp = SESSION.get(wb_url, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
            if resp.status_code != 200:
                continue
            fetched += 1

            for match in cdn_re.findall(resp.text):
                cdn_urls.add(match.split("?")[0])

        except requests.RequestException:
            continue
        time.sleep(0.5)

    return cdn_urls


# ---------------------------------------------------------------------------
# Layer 4: CDN liveness check
# ---------------------------------------------------------------------------

def check_cdn_liveness(
    urls: set[str], max_workers: int = 32
) -> tuple[set[str], set[str]]:
    """
    HEAD-check CDN URLs to see which are still alive.

    Returns (alive_urls, dead_urls).
    """
    print(f"\n[Layer 4] CDN liveness check: {len(urls)} URLs")

    alive: set[str] = set()
    dead: set[str] = set()
    checked = 0
    total = len(urls)
    t0 = time.monotonic()

    def head_check(url: str) -> tuple[str, bool]:
        try:
            r = SESSION.head(url, timeout=(10, 30), allow_redirects=True)
            return url, r.status_code == 200
        except requests.RequestException:
            return url, False

    with cf.ThreadPoolExecutor(max_workers=max_workers) as ex:
        futures = {ex.submit(head_check, u): u for u in urls}
        for fut in cf.as_completed(futures):
            url, is_alive = fut.result()
            if is_alive:
                alive.add(url)
            else:
                dead.add(url)
            checked += 1
            if checked % 100 == 0:
                elapsed = time.monotonic() - t0
                rate = checked / elapsed if elapsed > 0 else 0
                print(
                    f"  [{checked}/{total}] "
                    f"alive: {len(alive)} | dead: {len(dead)} "
                    f"({rate:.0f} URLs/s)"
                )

    elapsed = time.monotonic() - t0
    print(
        f"  Liveness complete in {elapsed:.0f}s: "
        f"{len(alive)} alive, {len(dead)} dead"
    )
    return alive, dead


# ---------------------------------------------------------------------------
# URL → filename
# ---------------------------------------------------------------------------

def cdn_url_to_filename(url: str) -> str:
    """
    Derive a flat filename from a CDN URL, preserving the asset dir for context.

    cdn.shopify.com/s/files/1/0123/4567/products/cool-shoe_800x.jpg
    → products__cool-shoe_800x.jpg
    """
    parsed = urlparse(url)
    path_parts = parsed.path.strip("/").split("/")

    # Find the asset directory (products, files, collections, etc.)
    asset_dir = ""
    filename_parts = []
    found_asset_dir = False
    for part in path_parts:
        if part in CDN_ASSET_DIRS:
            asset_dir = part
            found_asset_dir = True
            continue
        if found_asset_dir:
            filename_parts.append(part)

    if filename_parts:
        basename = "__".join(filename_parts)
    else:
        basename = path_parts[-1] if path_parts else "unknown"

    if asset_dir:
        return f"{asset_dir}__{basename}"

    return basename


def strip_shopify_size_suffix(url: str) -> str:
    """
    Remove Shopify size suffixes to get the original full-size image.

    e.g. cool-shoe_800x.jpg → cool-shoe.jpg
         cool-shoe_800x800.jpg → cool-shoe.jpg
         cool-shoe_grande.jpg → cool-shoe.jpg
    """
    size_pattern = re.compile(
        r"_(pico|icon|thumb|small|compact|medium|large|grande"
        r"|\d+x\d*|\d*x\d+)"
        r"(\.\w+)$",
        re.I,
    )
    parsed = urlparse(url)
    path = parsed.path
    new_path = size_pattern.sub(r"\2", path)
    return f"{parsed.scheme}://{parsed.netloc}{new_path}"


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

def save_manifest(
    images: list[dict],
    products: list[dict],
    collections: list[dict],
    cdx_records: list[dict],
    base_url: str,
    cdn_prefix: str | None,
    stats: dict,
    path: Path,
) -> None:
    manifest = {
        "store_url": base_url,
        "cdn_prefix": cdn_prefix,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "stats": stats,
        "product_count": len(products),
        "collection_count": len(collections),
        "image_count": len(images),
        "cdx_record_count": len(cdx_records),
        "products": [
            {
                "id": p.get("id"),
                "title": p.get("title"),
                "handle": p.get("handle"),
                "vendor": p.get("vendor"),
                "product_type": p.get("product_type"),
                "tags": p.get("tags", []),
                "created_at": p.get("created_at"),
                "updated_at": p.get("updated_at"),
                "image_count": len(p.get("images", [])),
                "variant_count": len(p.get("variants", [])),
            }
            for p in products
        ],
        "collections": [
            {
                "id": c.get("id"),
                "title": c.get("title"),
                "handle": c.get("handle"),
            }
            for c in collections
        ],
        "images": images,
    }
    path.write_text(json.dumps(manifest, indent=2))
    print(f"\nManifest saved: {path}  ({len(images)} images)")


def load_manifest(path: Path) -> tuple[list[dict], str]:
    data = json.loads(path.read_text())
    print(
        f"Loaded manifest: {data['store_url']} "
        f"({data['image_count']} images, from {data['timestamp']})"
    )
    return data["images"], data["store_url"]


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

def download_one(
    image: dict, out_dir: Path, session: requests.Session
) -> tuple[str, bool]:
    src = image.get("src", "")
    fname = image.get("filename", cdn_url_to_filename(src))
    out = out_dir / fname

    if out.exists() and out.stat().st_size > 0:
        return f"exists: {fname}", True

    tmp = out.with_suffix(out.suffix + ".part")

    try:
        with session.get(
            src,
            stream=True,
            allow_redirects=True,
            timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
        ) as r:
            if r.status_code != 200:
                return f"http {r.status_code}: {fname}", False

            with open(tmp, "wb") as f:
                for chunk in r.iter_content(262144):
                    if chunk:
                        f.write(chunk)

        out.unlink(missing_ok=True)
        tmp.replace(out)
        size_mb = out.stat().st_size / (1024 * 1024)
        return f"downloaded: {fname} ({size_mb:.1f} MB)", True

    except Exception as e:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return f"error: {fname} :: {e}", False


def download_images(
    images: list[dict], out_dir: Path, max_workers: int = 16
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    for part in out_dir.glob("*.part"):
        part.unlink(missing_ok=True)

    total = len(images)
    downloaded = 0
    skipped = 0
    failed = 0

    print(f"\nDownloading {total} images to {out_dir}/  (workers={max_workers})")
    t0 = time.monotonic()

    with cf.ThreadPoolExecutor(max_workers=max_workers) as ex:
        futures = {
            ex.submit(download_one, img, out_dir, SESSION): img for img in images
        }

        for fut in cf.as_completed(futures):
            msg, ok = fut.result()
            if ok:
                if msg.startswith("exists"):
                    skipped += 1
                else:
                    downloaded += 1
            else:
                failed += 1
            done = downloaded + skipped + failed
            print(f"  [{done}/{total}] {msg}")

    elapsed = time.monotonic() - t0
    print(
        f"\nDone in {elapsed:.0f}s.  "
        f"Downloaded: {downloaded} | Skipped: {skipped} | Failed: {failed}"
    )


# ---------------------------------------------------------------------------
# CDX dump (raw URL export)
# ---------------------------------------------------------------------------

def cdx_dump(domain: str, cdn_prefix: str | None, out_path: Path) -> None:
    """Dump all discovered CDX URLs to a text file."""
    print(f"\n[CDX Dump] Exporting all Wayback URLs for {domain}")

    all_urls: list[str] = []

    # Domain URLs
    print(f"  Querying: {domain}/*")
    rows = cdx_query(domain + "/", match_type="prefix", collapse="urlkey")
    for row in rows:
        if len(row) > 2:
            all_urls.append(row[2])

    # CDN URLs
    if cdn_prefix:
        cdn_pattern = f"cdn.shopify.com/s/files/{cdn_prefix}/"
        print(f"  Querying: {cdn_pattern}*")
        rows = cdx_query(cdn_pattern, match_type="prefix", collapse="urlkey")
        for row in rows:
            if len(row) > 2:
                all_urls.append(row[2])

    # Deduplicate and sort
    unique = sorted(set(all_urls))
    out_path.write_text("\n".join(unique) + "\n")
    print(f"\n  CDX dump: {len(unique)} unique URLs → {out_path}")


# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Shopify CDN Archaeology: discover and download all images "
            "from a Shopify store, including historical/delisted products."
        )
    )
    parser.add_argument(
        "--store",
        help="Shopify store URL (e.g. mystore.myshopify.com or mystore.com)",
    )
    parser.add_argument("--out-dir", help="Output directory")
    parser.add_argument(
        "--workers", type=int, default=16, help="Download concurrency (default: 16)",
    )
    parser.add_argument(
        "--manifest-only", action="store_true",
        help="Build manifest without downloading",
    )
    parser.add_argument(
        "--from-manifest", type=Path,
        help="Resume downloads from a saved manifest",
    )
    parser.add_argument(
        "--skip-wayback", action="store_true",
        help="Skip Wayback Machine discovery (live store only)",
    )
    parser.add_argument(
        "--skip-liveness", action="store_true",
        help="Skip CDN liveness check (trust all discovered URLs)",
    )
    parser.add_argument(
        "--wayback-only", action="store_true",
        help="Skip live store, only use Wayback (for dead stores)",
    )
    parser.add_argument(
        "--cdx-dump", action="store_true",
        help="Export raw CDX URL list to file (no download)",
    )
    parser.add_argument(
        "--cdn-prefix",
        help="Manually specify CDN prefix (e.g. 1/0123/4567)",
    )
    parser.add_argument(
        "--full-size", action="store_true",
        help="Strip Shopify size suffixes to request original full-size images",
    )
    parser.add_argument(
        "--max-wayback-json", type=int, default=200,
        help="Max archived product JSONs to fetch (default: 200)",
    )
    parser.add_argument(
        "--access-token",
        help="Shopify Storefront API access token (auto-discovered if omitted)",
    )
    parser.add_argument(
        "--myshopify",
        help="The .myshopify.com domain (e.g. yeezygap.myshopify.com). "
             "Auto-derived from --store if it ends in .myshopify.com.",
    )
    parser.add_argument(
        "--skip-storefront-api", action="store_true",
        help="Skip Storefront API discovery",
    )

    args = parser.parse_args()

    # --- Resume from manifest ---
    if args.from_manifest:
        if not args.from_manifest.exists():
            print(f"Manifest not found: {args.from_manifest}")
            return 1
        images, _ = load_manifest(args.from_manifest)
        out_dir = Path(args.out_dir) if args.out_dir else args.from_manifest.parent
        download_images(images, out_dir, args.workers)
        return 0

    if not args.store:
        parser.error("--store is required (or use --from-manifest)")

    base_url = normalise_store_url(args.store)
    slug = store_slug(base_url)
    domain = store_domain(base_url)
    out_dir = Path(args.out_dir) if args.out_dir else Path(f"shopify_{slug}")
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- CDN prefix ---
    cdn_prefix = args.cdn_prefix
    if not cdn_prefix and not args.wayback_only:
        cdn_prefix = discover_cdn_prefix(base_url)
    if not cdn_prefix:
        # Try to discover from Wayback snapshot of homepage
        print("  Attempting CDN prefix discovery from Wayback ...")
        try:
            resp = SESSION.get(
                f"https://web.archive.org/web/2id_/{base_url}/",
                timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
            )
            if resp.status_code == 200:
                m = _CDN_PREFIX_RE.search(resp.text)
                if m:
                    cdn_prefix = f"1/{m.group(1)}"
                    print(f"  Found CDN prefix from Wayback: {cdn_prefix}")
                else:
                    m = _CDN_PREFIX_ALT_RE.search(resp.text)
                    if m:
                        cdn_prefix = m.group(1)
                        print(f"  Found CDN prefix from Wayback: {cdn_prefix}")
        except requests.RequestException:
            pass

    if not cdn_prefix:
        print("WARNING: Could not discover CDN prefix. Wayback CDN queries will be limited.")

    # --- Myshopify domain (needed for Storefront API) ---
    myshopify_domain = args.myshopify
    if not myshopify_domain:
        if domain.endswith(".myshopify.com"):
            myshopify_domain = domain
        else:
            # Try to discover from Shopify.shop JS variable in page source
            print("  Discovering .myshopify.com domain ...")
            for target in [base_url, f"https://web.archive.org/web/2id_/{base_url}/"]:
                try:
                    resp = SESSION.get(target, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
                    if resp.status_code == 200:
                        m = re.search(r'Shopify\.shop\s*=\s*"([^"]+\.myshopify\.com)"', resp.text)
                        if m:
                            myshopify_domain = m.group(1)
                            print(f"  Found myshopify domain: {myshopify_domain}")
                            break
                except requests.RequestException:
                    continue

    # --- Access token ---
    access_token = args.access_token
    if not access_token and not args.skip_storefront_api and not args.wayback_only:
        print("\n  Discovering Storefront API access token ...")
        ms_url = f"https://{myshopify_domain}" if myshopify_domain else None
        access_token = discover_access_token(base_url, ms_url)

    # --- CDX dump mode ---
    if args.cdx_dump:
        cdx_dump(domain, cdn_prefix, out_dir / f"cdx_dump_{slug}.txt")
        return 0

    # --- Collect all CDN URLs from every discovery layer ---
    all_cdn_urls: set[str] = set()
    products: list[dict] = []
    collections: list[dict] = []
    cdx_records: list[dict] = []

    # Layer 1: Storefront API (GraphQL)
    if access_token and myshopify_domain and not args.skip_storefront_api:
        api_products, api_collections, api_cdn = discover_via_storefront_api(
            myshopify_domain, access_token
        )
        if api_products:
            products = api_products
            collections = api_collections
            all_cdn_urls.update(api_cdn)
            print(f"\n  Layer 1 (Storefront API): {len(api_cdn)} CDN URLs")
    elif not args.skip_storefront_api and not args.wayback_only:
        print("\n  Storefront API: skipped (no access token or myshopify domain)")

    # Layer 2: Live storefront (/products.json fallback)
    if not args.wayback_only:
        products = discover_products(base_url)
        collections = discover_collections(base_url)
        sitemap_urls = discover_sitemap_urls(base_url)

        live_cdn = extract_cdn_urls_from_products(products)
        cdn_from_sitemap = {
            u for u in sitemap_urls if "cdn.shopify.com" in u and _is_image_url(u)
        }
        all_cdn_urls.update(live_cdn)
        all_cdn_urls.update(cdn_from_sitemap)

        print(
            f"\n  Layer 2 total: {len(all_cdn_urls)} CDN URLs "
            f"({len(live_cdn)} from products.json, "
            f"{len(cdn_from_sitemap)} from sitemaps)"
        )

    # Layer 3: Wayback Machine
    if not args.skip_wayback:
        wayback_cdn, cdx_records = discover_wayback_cdn_urls(domain, cdn_prefix)
        new_urls = wayback_cdn - all_cdn_urls
        all_cdn_urls.update(wayback_cdn)
        print(f"  Layer 3 added {len(new_urls)} new URLs (total: {len(all_cdn_urls)})")

    if not all_cdn_urls:
        print("\nNo CDN image URLs discovered from any source.")
        return 1

    # Full-size: strip Shopify size suffixes
    if args.full_size:
        original_count = len(all_cdn_urls)
        originals = {strip_shopify_size_suffix(u) for u in all_cdn_urls}
        all_cdn_urls.update(originals)
        print(
            f"\n  Full-size expansion: {original_count} → {len(all_cdn_urls)} URLs "
            f"(+{len(all_cdn_urls) - original_count} original-size variants)"
        )

    # Layer 3: CDN liveness check
    if not args.skip_liveness:
        alive, dead = check_cdn_liveness(all_cdn_urls, max_workers=32)
    else:
        alive = all_cdn_urls
        dead = set()
        print(f"\n  Skipping liveness check. Treating all {len(alive)} URLs as alive.")

    # --- Build image list ---
    images: list[dict] = []
    for url in sorted(alive):
        images.append({
            "src": url,
            "filename": cdn_url_to_filename(url),
        })

    # --- Stats ---
    stats = {
        "storefront_api": "yes" if (access_token and myshopify_domain) else "no",
        "products": len(products),
        "collections": len(collections),
        "total_cdn_urls_discovered": len(all_cdn_urls),
        "cdn_alive": len(alive),
        "cdn_dead": len(dead),
        "cdx_records": len(cdx_records),
        "downloadable_images": len(images),
    }

    print(f"\n{'='*60}")
    print(f"  DISCOVERY SUMMARY")
    print(f"{'='*60}")
    for k, v in stats.items():
        print(f"  {k:30s} {v}")
    print(f"{'='*60}")

    # --- Manifest ---
    manifest_path = out_dir / f"manifest_{slug}.json"
    save_manifest(
        images, products, collections, cdx_records,
        base_url, cdn_prefix, stats, manifest_path,
    )

    # Also save the dead URLs for reference
    if dead:
        dead_path = out_dir / f"dead_urls_{slug}.txt"
        dead_path.write_text("\n".join(sorted(dead)) + "\n")
        print(f"Dead URLs saved: {dead_path} ({len(dead)} URLs)")

    if args.manifest_only:
        return 0

    # --- Download ---
    download_images(images, out_dir, args.workers)
    return 0


def _is_image_url(url: str) -> bool:
    ext = Path(urlparse(url).path).suffix.lower()
    return ext in IMAGE_EXTENSIONS


if __name__ == "__main__":
    raise SystemExit(main())
