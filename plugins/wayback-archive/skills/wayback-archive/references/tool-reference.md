# Tool Reference

## fetch_archive.py — Multi-Strategy Archived Page Fetcher

Reads a filtered `links.txt` (one Wayback URL per line) and fetches each page
using a tiered cascade with proxy rotation and CommonCrawl WARC lookups:

```
All tiers:  Direct Wayback id_ first (no proxy, fastest)
  | if rate-limited or fails
Tier 1: oEmbed / Atom / JSON  ->  proxy fallback
Tier 2: HTML product pages    ->  CommonCrawl WARC lookup, then proxy fallback
Tier 3: Collection / homepage ->  CommonCrawl WARC lookup, then proxy fallback
```

Queue-based worker model with bounded concurrency. Three separate semaphores
(direct: 10, proxy: workers, CC: 4). Content validated post-fetch: anti-bot
signature detection, Wayback wrapper rejection, size gating. 503/429 handling
with exponential backoff.

```bash
python fetch_archive.py links.txt                # Standard run
python fetch_archive.py links.txt --resume       # Resume after interruption
python fetch_archive.py links.txt --proxy dc     # Datacenter proxies
python fetch_archive.py links.txt --dry-run      # Show plan without downloading
python fetch_archive.py links.txt --workers 3    # Limit concurrency
```

## filter_cdx.py — CDX Dump URL Filter

Transforms a raw CDX dump into a clean URL list. Six filter layers:

1. **Status whitelist**: Keep only HTTP 200
2. **MIME blacklist**: Drop JS, CSS, fonts, images, video, `warc/revisit`
3. **Junk path patterns**: Drop robots.txt, favicon, checkout, tracking, analytics
4. **Static asset extensions**: Drop .js, .css, .map, .woff, .ico
5. **Variant noise**: Drop Shopify `/variants/?section_id=store-availability`
6. **Deduplication**: One URL per unique path, latest 200-status preferred

Output sorted by value tier: structured data first (.oembed, .atom, .json),
then collection pages, then product pages.

```bash
python filter_cdx.py mystore_com_wayback.txt > links.txt
```

## shopify_downloader.py — Shopify CDN Archaeology

4-layer discovery system for Shopify stores:

1. **Storefront API** (GraphQL) — query official API with access token
2. **Live storefront** — `/products.json`, `/collections.json`, `/sitemap.xml`
3. **Wayback CDX** — historical CDN URL mining via `cdn.shopify.com/s/files/{prefix}/*`
4. **CDN liveness** — HEAD-check all discovered URLs

```bash
python shopify_downloader.py --store mystore.com                    # Full discovery
python shopify_downloader.py --store mystore.com --wayback-only     # Dead store
python shopify_downloader.py --store mystore.com --manifest-only    # Discovery only
python shopify_downloader.py --store mystore.com --full-size        # Original images
python shopify_downloader.py --from-manifest manifest.json          # Resume downloads
```

## tools/wayback_cdx — CDX Domain Dump

Dumps every Wayback Machine snapshot URL for a domain. Proxy support,
checkpointing, resume, rate limiting.

```bash
cd tools/
python -m wayback_cdx --domain mystore.com --output dump.txt --resume
python -m wayback_cdx --domain mystore.com --proxy-mode auto --from 2018 --to 2024
python -m wayback_cdx --domain mystore.com --dry-run  # Page count only
```

Output: tab-separated file (wayback_url, timestamp, original_url, status, mimetype).

## tools/cdn/app.sh — CDN Quality Probe

Downloads images from live CDNs, probing for best quality format.

```bash
PROBE_DELAY=1 tools/cdn/app.sh -o output_dir urls.txt
```

## Wayback URL Modifiers

| Modifier | Use | Example |
|----------|-----|---------|
| *(none)* | Full replay with toolbar + JS | `web.archive.org/web/{ts}/url` |
| `id_` | Raw content, no wrapper | `web.archive.org/web/{ts}id_/url` |
| `im_` | Raw image bytes | `web.archive.org/web/{ts}im_/url` |

Without `id_`, Wayback injects toolbar HTML, corrupting JSON and binary files.
For HTML pages, `id_` alone is NOT enough — Wayback still serves a JS replay
wrapper. Prefer CommonCrawl WARCs for HTML.

## Tool Selection Quick Reference

| Task | Use This | Not This | Why |
|------|----------|----------|-----|
| Full page fetch | `fetch_archive.py` | Manual curl | Handles entire cascade |
| HTML page content | CommonCrawl WARC | Wayback HTML | Raw HTML; no JS wrapper |
| JSON API endpoints | Wayback `id_` via proxy | Playwright | No JS rendering needed |
| CDN image downloads | curl (live CDN) | Wayback | Higher quality, no rate limits |
| Dead CDN images | Wayback `im_` | Playwright | Raw bytes without toolbar |
| Handle discovery | CDX API + CC index | Manual browsing | Automated, exhaustive |
| CDX dump filtering | `filter_cdx.py` | Manual grep | 6-layer filter (94%+ reduction) |
