"""
Metadata extraction from HTML pages and API JSON responses.

Plugin system with three extractor types:
- HTMLMetadataExtractor (Shopify product pages)
- APIMetadataExtractor (Adidas /api/products/{SKU})
- CatalogMetadataExtractor (bloom/archive catalog arrays)
"""
from __future__ import annotations

import html as html_mod
import json
import re
from datetime import datetime, timezone


def extract_shopify_metadata(page: str, slug: str) -> dict:
    """Extract metadata from a Shopify-era HTML product page."""
    name = _meta(page, "title") or _analytics_field(page, "name")
    price = _meta(page, "price:amount")
    currency = _meta(page, "price:currency") or ("USD" if price else None)
    brand = _analytics_field(page, "brand")
    category = _analytics_field(page, "category")
    sku = _analytics_field(page, "sku")
    description = _meta(page, "description") or _description(page)
    color = _color(page)
    sizes = ", ".join(_sizes(page)) or None

    return {
        "name": name,
        "price": price,
        "currency": currency,
        "brand": brand,
        "category": category,
        "sku": sku,
        "description": description,
        "color": color,
        "sizes": sizes,
    }


def extract_api_metadata(data) -> dict:
    """Extract metadata from an Adidas API JSON response.

    Adidas endpoints occasionally return a single-element list instead of a
    bare object. Unwrap that shape and guard the sub-dicts — the fetch stage
    used to crash with AttributeError when any of these were unexpectedly a
    list or None.
    """
    if isinstance(data, list):
        data = data[0] if data and isinstance(data[0], dict) else {}
    if not isinstance(data, dict):
        return {}

    attrs = data.get("attribute_list") or {}
    pricing = data.get("pricing_information") or {}
    desc = data.get("product_description") or {}
    if not isinstance(attrs, dict):
        attrs = {}
    if not isinstance(pricing, dict):
        pricing = {}
    if not isinstance(desc, dict):
        desc = {}

    image_urls = []
    view_list = data.get("view_list") or []
    if isinstance(view_list, list):
        for view in view_list:
            if not isinstance(view, dict):
                continue
            url = view.get("image_url", "")
            if url:
                m = re.search(r'https?://(?:web\.archive\.org/web/\d+/)?(.+)', url)
                if m:
                    clean = m.group(1)
                    if not clean.startswith("http"):
                        clean = "https://" + clean
                    image_urls.append(clean)

    sport = attrs.get("sport")
    sport_str = ", ".join(sport) if isinstance(sport, list) and sport else None

    return {
        "name": data.get("name") or desc.get("title"),
        "sku": data.get("id"),
        "price": str(pricing.get("standard_price")) if pricing.get("standard_price") else None,
        "currency": "USD",
        "brand": attrs.get("brand"),
        "category": attrs.get("category"),
        "color": attrs.get("color") or attrs.get("search_color_raw"),
        "gender": attrs.get("gender"),
        "description": desc.get("text"),
        "sport": sport_str,
        "image_urls": image_urls,
    }


def extract_catalog_product(product) -> dict:
    """Extract metadata from a catalog API product entry (bloom/archive)."""
    if not isinstance(product, dict):
        return {}

    sku = product.get("product_id")
    name = product.get("product_name", "")
    price = product.get("price")
    color = product.get("color")

    img_url = None
    image = product.get("image", {})
    if isinstance(image, dict):
        link = image.get("link", "")
        m = re.search(r'https?://assets\.[a-zA-Z0-9.-]+\.com/[^\s"\']+', link)
        if m:
            img_url = m.group(0)

    return {
        "sku": sku,
        "name": name,
        "price": str(price) if price else None,
        "color": color,
        "image_url": img_url,
    }


def extract_publish_date(urls: list[str]) -> str | None:
    """Extract publish date from Shopify CDN URL query params (?v=timestamp)."""
    timestamps = []
    for url in urls:
        m = re.search(r'\?v=(\d+)', url)
        if m:
            timestamps.append(int(m.group(1)))
    if not timestamps:
        return None
    earliest = min(timestamps)
    dt = datetime.fromtimestamp(earliest, tz=timezone.utc)
    return dt.strftime("%Y-%m-%d")


def write_metadata_txt(path, meta: dict, credit: str = "Wayback Archive") -> None:
    """Write a metadata.txt file for a product directory."""
    lines = []
    lines.append(f"URL: {meta.get('url', 'Unknown')}")
    lines.append(f"Product: {meta.get('name', 'Unknown')}")
    lines.append(f"Credit: {credit}")
    lines.append(f"Date: {meta.get('date') or 'Unknown'}")

    if meta.get("price"):
        currency = meta.get("currency", "USD")
        lines.append(f"Price: ${meta['price']} {currency}")
    for field in ("brand", "category", "sku", "color", "gender", "sizes", "sport"):
        val = meta.get(field)
        if val:
            lines.append(f"{field.title()}: {val}")

    if meta.get("description"):
        desc = meta["description"]
        if len(desc) > 500:
            desc = desc[:497] + "..."
        lines.append("")
        lines.append("Description:")
        for desc_line in desc.splitlines():
            lines.append(f"  {desc_line.strip()}")

    path.write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _meta(page: str, prop: str) -> str | None:
    m = re.search(
        rf'<meta\s+property="og:{re.escape(prop)}"\s+content="([^"]*)"', page
    )
    return html_mod.unescape(m.group(1)).strip() if m else None


def _analytics_field(page: str, field: str) -> str | None:
    m = re.search(rf'"Viewed Product",\s*(\{{[^}}]+\}})', page)
    if not m:
        return None
    try:
        data = json.loads(m.group(1).replace("\\/", "/"))
        val = data.get(field)
        return str(val).strip() if val is not None else None
    except (json.JSONDecodeError, KeyError):
        return None


def _description(page: str) -> str | None:
    for pattern in [
        r'<div\s+class="product-single__description\s+rte">\s*(.*?)</div>',
        r'<div\s+class="product__description[^"]*"[^>]*>\s*(.*?)</div>',
        r'<div\s+class="rte"[^>]*>\s*(.*?)</div>',
    ]:
        m = re.search(pattern, page, re.DOTALL)
        if m:
            raw = m.group(1)
            text = re.sub(r'<br\s*/?>', '\n', raw)
            text = re.sub(r'<[^>]+>', '', text)
            text = html_mod.unescape(text)
            lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
            if lines:
                return "\n".join(lines)
    return None


def _color(page: str) -> str | None:
    for pattern in [
        r'Color\s+([A-Z][A-Z /\-]+)',
        r'COLOR\s+([A-Z][A-Z /\-]+)',
        r'"color"\s*:\s*"([^"]+)"',
    ]:
        m = re.search(pattern, page)
        if m:
            return m.group(1).strip()
    return None


def _sizes(page: str) -> list[str]:
    options = re.findall(
        r'<option\s[^>]*>\s*([A-Z0-9./\- ]+?)\s*</option>', page
    )
    seen: set[str] = set()
    sizes: list[str] = []
    for o in options:
        o = o.strip()
        if o and o not in seen and o != "---":
            seen.add(o)
            sizes.append(o)
    return sizes
