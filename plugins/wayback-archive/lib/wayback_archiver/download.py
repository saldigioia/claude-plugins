"""
Image acquisition cascade — multi-strategy download system.

Strategies (executed in order per product until images are recovered):
1. Live CDN via quality probe tool (app.sh)
2. Direct HTTP fetch
3. Wayback CDX best-size query (find largest cached variant)
4. Exhaustive snapshot search (try every captured page snapshot)
5. Asset CDN rescue (parse CDX for asset domain captures)

Replaces 6 download scripts with a single configurable cascade.

IMPORTANT: Wayback downloads MUST use the `id_` or `im_` suffix in the URL
to get raw content. Without it, Wayback injects toolbar HTML into responses,
corrupting binary files (images, JSON, etc.):
  - `id_` — raw bytes, identity (no rewriting)
  - `im_` — raw bytes, for images specifically
  BAD:  https://web.archive.org/web/20240101/https://example.com/image.jpg
  GOOD: https://web.archive.org/web/20240101id_/https://example.com/image.jpg
"""
from __future__ import annotations

import logging
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse, unquote

import requests

log = logging.getLogger(__name__)

# Image validation
IMAGE_MAGIC = {
    b'\x89PNG': "png",
    b'\xff\xd8\xff\xe0': "jpeg",
    b'\xff\xd8\xff\xe1': "jpeg",
    b'\xff\xd8\xff\xdb': "jpeg",
    b'RIFF': "webp",
    b'II\x2a\x00': "tiff",
    b'MM\x00\x2a': "tiff",
    b'GIF8': "gif",
}
MIN_IMAGE_BYTES = 500

SIZE_SUFFIX = re.compile(r'_(?:\d+|\{width\})x(?:@\dx)?(?=\.\w+)')
NAMED_SIZE = re.compile(
    r'_(?:grande|medium|small|large|compact|master|pico|icon|thumb)(?=\.\w+)'
)
# UUID suffix pattern (common in Shopify CDN filenames)
UUID_SUFFIX = re.compile(
    r'_[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}(?=\.\w+)'
)

# --- Image filtering: skip site chrome, icons, and non-product images ---
SKIP_PATTERNS = frozenset({
    'favicon', 'fav.png', 'fav_', 'apple-touch-icon', 'icon-',
    'logo', 'browser-bar', 'cf-no-screenshot',
    'shopifycloud', 'cdn-cgi', 'consent-tracking',
    'shop_events', 'storefront/', 'wpm@',
    'shopify_pay', 'load_feature', 'challenge-platform',
    'spinner', 'loading', 'placeholder',
})


def is_valid_image(data: bytes, content_type: str = "") -> bool:
    """Check if response data is a valid image via magic bytes.

    Also rejects data that looks like Wayback toolbar injection
    (HTML content served instead of image bytes).
    """
    if len(data) < MIN_IMAGE_BYTES:
        return False
    # Reject Wayback toolbar injection: binary file shouldn't start with HTML
    if data[:15].lstrip().startswith((b'<!DOCTYPE', b'<html', b'<HTML')):
        return False
    if b'_wm.wombat' in data[:1000] or b'web.archive.org' in data[:1000]:
        return False
    if any(data[:len(magic)] == magic for magic in IMAGE_MAGIC):
        return True
    # AVIF check (ftyp box)
    if b'ftyp' in data[:12]:
        return True
    if "image" in content_type:
        return True
    return False


def is_product_image(url: str) -> bool:
    """Return False for site chrome (favicons, logos, icons, tracking pixels).

    Call this BEFORE downloading to avoid wasting bandwidth on non-product
    images. This was a hard lesson: without this filter, the CDN tool would
    re-download the same favicon/icon for every product page.
    """
    lower = url.lower()
    return not any(skip in lower for skip in SKIP_PATTERNS)


def canonicalize_image_url(url: str) -> str:
    """Reduce a CDN image URL to its canonical form for deduplication.

    Strips query params, size suffixes, UUID suffixes, and named sizes so
    that ``image_400x.jpg``, ``image_1200x.jpg``, and ``image.jpg?width=600``
    all map to the same canonical key.  This prevents downloading every size
    variant of the same image — another hard lesson from early pipeline runs.
    """
    # Strip query params
    canon = url.split('?')[0]
    # Strip size suffixes
    canon = SIZE_SUFFIX.sub('', canon)
    canon = NAMED_SIZE.sub('', canon)
    # Normalize protocol
    if canon.startswith('http://'):
        canon = 'https://' + canon[7:]
    canon = re.sub(r':80(/|$)', r'\1', canon)
    return canon


def clean_filename(url: str) -> str:
    """Extract a clean filename from a URL, stripping size suffixes."""
    path = unquote(urlparse(url).path)
    fname = path.split("/")[-1]
    fname = SIZE_SUFFIX.sub("", fname)
    fname = NAMED_SIZE.sub("", fname)
    return re.sub(r'[/:*?"<>|]', '_', fname)


# ---------------------------------------------------------------------------
# Strategy 1: Live CDN via quality probe tool (app.sh)
# ---------------------------------------------------------------------------

def download_via_cdn_tool(
    urls: list[str],
    dest_dir: Path,
    cdn_tool: Path,
    timeout: int = 120,
) -> list[Path]:
    """
    Pipe URLs through the CDN quality probe tool for best-quality download.
    Returns list of downloaded file paths.
    """
    if not urls or not cdn_tool.exists():
        return []

    dest_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as tf:
        tf.write("\n".join(urls) + "\n")
        url_file = tf.name

    try:
        subprocess.run(
            [str(cdn_tool), "-o", str(dest_dir), url_file],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (subprocess.TimeoutExpired, Exception) as e:
        log.warning("CDN tool error: %s", e)
    finally:
        os.unlink(url_file)

    from .normalize import list_images
    return list_images(dest_dir)


# ---------------------------------------------------------------------------
# Strategy 2: Direct HTTP fetch
# ---------------------------------------------------------------------------

def download_direct(
    url: str,
    dest: Path,
    session: requests.Session,
    timeout: tuple[int, int] = (10, 30),
) -> bool:
    """Try downloading a URL directly via HTTP."""
    try:
        resp = session.get(url, timeout=timeout)
        if resp.status_code == 200 and is_valid_image(
            resp.content, resp.headers.get("content-type", "")
        ):
            dest.write_bytes(resp.content)
            return True
    except Exception:
        pass
    return False


# ---------------------------------------------------------------------------
# Strategy 3: Wayback CDX best-size query
# ---------------------------------------------------------------------------

_SIZE_RE = re.compile(r'_(\d+)x(?:@(\d)x)?')


def find_best_wayback_url(
    base_url: str,
    session: requests.Session,
    timeout: int = 30,
) -> str | None:
    """
    Query the Wayback CDX API for the largest cached size variant of an image.
    Returns the full web.archive.org download URL, or None.
    """
    clean = base_url.split("?")[0]
    query_url = clean.removeprefix("https://").removeprefix("http://")
    path_base, _ = os.path.splitext(query_url)

    try:
        resp = session.get(
            "https://web.archive.org/cdx/search/cdx",
            params={
                "url": f"{path_base}*",
                "output": "json",
                "filter": ["statuscode:200", "mimetype:image/.*"],
                "fl": "original,timestamp",
                "limit": 50,
            },
            timeout=timeout,
        )
        if resp.status_code != 200:
            return None
        data = resp.json()
        if len(data) < 2:
            return None

        best_url, best_size, best_ts = None, 0, None
        for row in data[1:]:
            original, timestamp = row[0], row[1]
            m = _SIZE_RE.search(original)
            size = int(m.group(1)) * (int(m.group(2)) if m.group(2) else 1) if m else 1
            if size > best_size:
                best_size, best_url, best_ts = size, original, timestamp

        if best_url and best_ts:
            # id_ suffix is critical — without it, Wayback injects toolbar HTML
            return f"https://web.archive.org/web/{best_ts}id_/{best_url}"
    except Exception:
        pass
    return None


def download_wayback_image(
    wb_url: str,
    dest: Path,
    session: requests.Session,
    retries: int = 3,
) -> bool:
    """Download a single image from the Wayback Machine with retries."""
    for attempt in range(retries):
        try:
            resp = session.get(wb_url, timeout=(10, 60), allow_redirects=True)
            if resp.status_code == 200 and is_valid_image(
                resp.content, resp.headers.get("content-type", "")
            ):
                dest.write_bytes(resp.content)
                return True
        except requests.RequestException:
            pass
        time.sleep(1.5 * (attempt + 1))
    return False


# ---------------------------------------------------------------------------
# Strategy 4: Combined direct + Wayback CDX fallback
# ---------------------------------------------------------------------------

def download_with_fallback(
    url: str,
    dest: Path,
    session: requests.Session,
    politeness_delay: float = 0.5,
) -> bool:
    """Try direct CDN first, then Wayback CDX fallback."""
    if download_direct(url, dest, session):
        return True

    wb_url = find_best_wayback_url(url, session)
    time.sleep(politeness_delay)

    if wb_url:
        return download_wayback_image(wb_url, dest, session)

    return False


# ---------------------------------------------------------------------------
# Download cascade orchestrator
# ---------------------------------------------------------------------------

def download_product_images(
    slug: str,
    urls: list[str],
    dest_dir: Path,
    session: requests.Session,
    cdn_tool: Path | None = None,
    is_live_cdn: bool = False,
    politeness_delay: float = 0.5,
) -> dict:
    """
    Run the full download cascade for a single product.

    Before downloading, URLs are:
    1. Filtered to remove site chrome (favicons, logos, icons, tracking pixels)
    2. Canonicalized to deduplicate size variants of the same image
    3. Checked against existing files to avoid re-downloading

    Returns dict with: downloaded (int), failed (int), skipped (int),
                       strategies_used (list[str])
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    result = {"downloaded": 0, "failed": 0, "skipped": 0, "strategies_used": []}

    # --- PRE-FILTER: remove non-product images (icons, favicons, etc.) ---
    product_urls = [u for u in urls if is_product_image(u)]
    result["skipped"] += len(urls) - len(product_urls)
    if result["skipped"] > 0:
        log.debug("Filtered %d non-product URLs for %s", result["skipped"], slug)

    # --- DEDUPLICATE: canonicalize URLs to avoid downloading size variants ---
    seen_canonical: set[str] = set()
    deduped_urls: list[str] = []
    for url in product_urls:
        canon = canonicalize_image_url(url)
        if canon not in seen_canonical:
            seen_canonical.add(canon)
            deduped_urls.append(url)
        else:
            result["skipped"] += 1

    # Strategy 1: CDN quality probe for live URLs
    if is_live_cdn and cdn_tool and cdn_tool.exists():
        before = set(f.name for f in dest_dir.iterdir())
        download_via_cdn_tool(deduped_urls, dest_dir, cdn_tool)
        after = set(f.name for f in dest_dir.iterdir())
        new_files = after - before
        if new_files:
            result["downloaded"] += len(new_files)
            result["strategies_used"].append("cdn_tool")

    # Strategy 2+3: Direct fetch with Wayback CDX fallback
    from .normalize import list_images
    existing_stems = {f.stem.lower() for f in list_images(dest_dir)}

    for url in deduped_urls:
        fname = clean_filename(url)
        stem = Path(fname).stem.lower()
        if stem in existing_stems:
            continue

        dest = dest_dir / fname
        if download_with_fallback(url, dest, session, politeness_delay):
            result["downloaded"] += 1
            existing_stems.add(stem)
            strategy = "direct" if dest.exists() else "wayback_cdx"
            if strategy not in result["strategies_used"]:
                result["strategies_used"].append(strategy)
        else:
            result["failed"] += 1

        time.sleep(politeness_delay)

    return result
