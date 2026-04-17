"""
Image URL extraction from HTML — 10 methods unified.

Handles Shopify CDN, Swell Commerce CDN, Fourthwall CDN, Adidas CDN,
data-src/srcset attributes, JS image arrays, featured_image, og:image,
inline JSON, and SvelteKit __data.json references.

IMPORTANT: When extracting image URLs, always filter out site chrome
(favicons, logos, icons, tracking pixels) to avoid polluting product
image directories. Use is_product_image() from download.py or the
SKIP_FILENAMES set below.
"""
from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass
class CDNPattern:
    """Configuration for a CDN image pattern."""
    name: str
    regex: str
    size_strip: str | None = None
    named_size_strip: str | None = None

    def compiled_regex(self) -> re.Pattern:
        return re.compile(self.regex)

    def compiled_size_strip(self) -> re.Pattern | None:
        return re.compile(self.size_strip) if self.size_strip else None

    def compiled_named_strip(self) -> re.Pattern | None:
        return re.compile(self.named_size_strip) if self.named_size_strip else None


# Filenames to always skip — site chrome, not product images
SKIP_FILENAMES = frozenset({
    'favicon.ico', 'favicon.png', 'apple-touch-icon.png',
    'logo.png', 'logo.svg', 'logo.jpg',
})

# Default CDN patterns
SHOPIFY_CDN = CDNPattern(
    name="shopify",
    regex=r'https?://cdn\.shopify\.com/s/files/[^\s"\'\\]+/products/[^\s"\'\\]+',
    size_strip=r'_(?:\d+|\{width\})x(?:@\dx)?(?=\.\w+)',
    named_size_strip=r'_(?:grande|medium|small|large|compact|master|pico|icon|thumb)(?=\.\w+)',
)

# Shopify domain-hosted CDN (e.g., store.com/cdn/shop/files/)
SHOPIFY_DOMAIN_CDN = CDNPattern(
    name="shopify_domain",
    regex=r'https?://[a-zA-Z0-9.-]+/cdn/shop/(?:files|products)/[^\s"\'\\]+\.(?:png|jpg|jpeg|webp|gif|avif)',
    size_strip=r'_(?:\d+|\{width\})x(?:@\dx)?(?=\.\w+)',
    named_size_strip=r'_(?:grande|medium|small|large|compact|master|pico|icon|thumb)(?=\.\w+)',
)

# Swell Commerce CDN (e.g., cdn.swell.store/yzy-prod/)
SWELL_CDN = CDNPattern(
    name="swell",
    regex=r'https?://cdn\.swell\.store/[^\s"\'\\]+\.(?:png|jpg|jpeg|webp|gif|avif)',
)

# Fourthwall CDN (e.g., imgproxy.fourthwall.com/)
FOURTHWALL_CDN = CDNPattern(
    name="fourthwall",
    regex=r'https?://imgproxy\.fourthwall\.com/[^\s"\'\\]+',
)

ADIDAS_CDN = CDNPattern(
    name="adidas",
    regex=r'https?://assets\.[a-zA-Z0-9.-]+\.com/images/[^\s"\'\\)]+\.(png|jpg|jpeg|webp)',
)

# Extraction helper patterns
_JS_IMAGES = re.compile(r'"images"\s*:\s*\[([^\]]+)\]')
_JS_FEATURED = re.compile(r'featured_image\s*:\s*"([^"]+)"')
_DATA_SRC = re.compile(r'data-(?:src|srcset|zoom-src|zoom|image|original)\s*=\s*"([^"]+)"')
_SRCSET = re.compile(r'srcset\s*=\s*"([^"]+)"')
_SCRIPT_JSON = re.compile(r'<script[^>]*type="application/json"[^>]*>(.*?)</script>', re.DOTALL)


def _strip_sizes(url: str, size_re: re.Pattern | None, named_re: re.Pattern | None) -> str:
    """Strip size suffixes from a URL."""
    if size_re:
        url = size_re.sub("", url)
    if named_re:
        url = named_re.sub("", url)
    return url


def _extract_shopify_url(raw: str, size_re: re.Pattern | None, named_re: re.Pattern | None) -> str | None:
    """Extract and clean a Shopify CDN URL."""
    cleaned = raw.replace("\\/", "/")
    m = re.search(r'https?://cdn\.shopify\.com/[^\s"\']+/products/[^\s"\']+', cleaned)
    if m:
        return _strip_sizes(m.group(0), size_re, named_re)
    return None


def extract_image_urls(
    html: str,
    cdn_patterns: list[CDNPattern] | None = None,
) -> list[str]:
    """
    Extract product image URLs from HTML using all 10 methods:
    1. CDN regex patterns (Shopify, Swell, Fourthwall, Adidas, custom)
    2. data-src/data-srcset/data-zoom-src attributes
    3. srcset attributes
    4. JS image arrays ("images": [...])
    5. featured_image references
    6. og:image meta tags
    7. Inline JSON script tags
    8. Additional CDN patterns
    9. Swell Commerce CDN URLs (cdn.swell.store)
    10. Fourthwall CDN URLs (imgproxy.fourthwall.com)

    Results are filtered to exclude site chrome (favicons, logos, icons).
    """
    if cdn_patterns is None:
        cdn_patterns = [SHOPIFY_CDN, SHOPIFY_DOMAIN_CDN, SWELL_CDN,
                        FOURTHWALL_CDN, ADIDAS_CDN]

    urls: set[str] = set()

    # Build compiled patterns
    shopify_patterns = [p for p in cdn_patterns if p.name == "shopify"]
    other_patterns = [p for p in cdn_patterns if p.name != "shopify"]

    shopify_re = shopify_patterns[0].compiled_regex() if shopify_patterns else None
    size_re = shopify_patterns[0].compiled_size_strip() if shopify_patterns else None
    named_re = shopify_patterns[0].compiled_named_strip() if shopify_patterns else None

    # 1. Main CDN pattern (Shopify)
    if shopify_re:
        for match in shopify_re.findall(html):
            cleaned = _strip_sizes(match, size_re, named_re)
            m = re.search(r'https?://cdn\.shopify\.com/.+', cleaned)
            if m:
                urls.add(m.group(0))

    # 2. data-* attributes
    for match in _DATA_SRC.findall(html):
        url = _extract_shopify_url(match, size_re, named_re)
        if url:
            urls.add(url)

    # 3. srcset attributes
    for match in _SRCSET.findall(html):
        for part in match.split(","):
            url = _extract_shopify_url(part.strip().split(" ")[0], size_re, named_re)
            if url:
                urls.add(url)

    # 4. JS image arrays
    for match in _JS_IMAGES.findall(html):
        for img_url in re.findall(r'"([^"]+)"', match):
            cleaned = img_url.replace("\\/", "/")
            if "cdn.shopify.com" in cleaned and "/products/" in cleaned:
                if cleaned.startswith("//"):
                    cleaned = "https:" + cleaned
                m = re.search(r'https?://cdn\.shopify\.com/.+', cleaned)
                if m:
                    urls.add(_strip_sizes(m.group(0), size_re, named_re))

    # 5. featured_image
    for match in _JS_FEATURED.findall(html):
        cleaned = match.replace("\\/", "/")
        if "cdn.shopify.com" in cleaned and "/products/" in cleaned:
            if cleaned.startswith("//"):
                cleaned = "https:" + cleaned
            m = re.search(r'https?://cdn\.shopify\.com/.+', cleaned)
            if m:
                urls.add(_strip_sizes(m.group(0), size_re, named_re))

    # 6. og:image
    og_match = re.search(r'og:image["\s]+content="([^"]+)"', html)
    if og_match:
        url = _extract_shopify_url(og_match.group(1), size_re, named_re)
        if url:
            urls.add(url)

    # 7. Inline JSON script tags
    for json_match in _SCRIPT_JSON.findall(html):
        for img_url in re.findall(r'cdn\.shopify\.com/[^"\\]+/products/[^"\\]+', json_match):
            raw = "https://" + img_url.replace("\\/", "/")
            urls.add(_strip_sizes(raw, size_re, named_re))

    # 8. Other CDN patterns (Adidas, etc.)
    for pattern in other_patterns:
        compiled = pattern.compiled_regex()
        for full_match in compiled.finditer(html):
            url = full_match.group(0)
            m = re.search(r'https?://[^\s"\']+', url)
            if m:
                urls.add(m.group(0))

    # Normalize: ensure https, strip wayback prefix
    cleaned_urls = set()
    for url in urls:
        url = re.sub(r'^https?://web\.archive\.org/web/\d+(?:(?:id|im|if)_)?/', '', url)
        if url.startswith("//"):
            url = "https:" + url
        if not url.startswith("http"):
            url = "https://" + url
        if url.startswith("http://"):
            url = "https://" + url[7:]
        cleaned_urls.add(url)

    # Filter out site chrome (favicons, logos, icons, tracking pixels)
    filtered = set()
    for url in cleaned_urls:
        fname = url.split('/')[-1].split('?')[0].lower()
        if fname in SKIP_FILENAMES:
            continue
        lower_url = url.lower()
        if any(skip in lower_url for skip in (
            'favicon', 'apple-touch', 'browser-bar', 'cdn-cgi',
            'consent-tracking', 'wpm@', 'shopify_pay', 'load_feature',
            'challenge-platform', 'shop_events',
        )):
            continue
        filtered.add(url)

    return sorted(filtered)
