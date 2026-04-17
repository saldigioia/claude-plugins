# Pipeline Stages — Detailed Reference

## Stage: cdx_dump

**Purpose**: Run wayback_cdx_v2 to produce CDX dump files for each domain.

**Inputs**: Site config with `domains` list
**Outputs**: `{domain}_wayback.txt` (tab-separated: wayback_url, timestamp, original_url, status, mimetype)

Invokes `tools/wayback_cdx` as a subprocess for each domain. Skips domains whose
CDX files already exist and are fresh (configurable via `cdx_dump_max_age_days`).
Uses subprocess isolation to preserve the CDX tool's own checkpoint/resume and proxy management.

## Stage: index

**Purpose**: Parse CDX dump + CommonCrawl discovery -> product index.

**Inputs**: CDX dump files, site config (url_rules, era_rules, junk_patterns)
**Outputs**: `{name}_products_index.json`, `{name}_commoncrawl_index.json`

Discovery vectors:
1. **Wayback CDX product URLs** — paginated, all subdomains. If any query returns
   exactly `limit` results, paginate using `resumeKey`.
2. **CommonCrawl Index** — queries `index.commoncrawl.org` for product pages,
   collections, and root paths across all configured domains. Rate-limits 1 req/s.
3. **Collection/category pages** — Atom feeds, oEmbed, HTML collection pages.
4. **CDN image filenames** — reverse-discovery: image filenames reveal products even
   when pages weren't captured.

Verification gate:
- All subdomains queried
- No queries hit result cap without pagination
- All CommonCrawl crawls attempted
- Handles deduplicated (exact + fuzzy)
- Output sorted by value tier

Library: `wayback_archiver.cdx.parse_cdx()`, `wayback_archiver.cdx.find_content_pages()`

## Stage: filter

**Purpose**: 6-layer CDX filter -> clean links.txt for fetching.

**Inputs**: CDX dump files
**Outputs**: `{name}_filtered_links.txt` (one Wayback URL per line, sorted by value tier)

Expect ~90-95% reduction with zero product data loss. Structured data sorted
first (.oembed, .atom, .json), then collections, then product pages.

## Stage: fetch

**Purpose**: Fetch pages via queue-based async cascade, then extract metadata.

**Inputs**: `{name}_filtered_links.txt`, product index
**Outputs**: `html/*.html`, `{name}_metadata.json`, `links/{slug}.txt`, `{name}_fetch_stats.json`

Three-step cascade:
1. Direct Wayback `id_` (no proxy, fastest)
2. CommonCrawl WARC (HTML only — queries up to 4 crawl indices with domain-level negative caching)
3. Wayback `id_` via ISP/DC proxy (round-robin across 20 IPs)

After fetching, extracts metadata and image URLs from downloaded HTML. JSON files
get API metadata extraction; HTML files get Shopify metadata + CDN URL extraction.
Tracks per-method success/failure counts.

Options: `--proxy isp|dc`, `--workers N`, `--fallback-archives archive_today memento`

Library: `wayback_archiver.extract.*`, `wayback_archiver.metadata.*`

## Stage: cdn_discover

**Purpose**: Shopify CDN archaeology — discover all CDN image URLs including delisted products.

**Inputs**: Site config with `shopify_cdn` section, fetched HTML
**Outputs**: Augmented `links/{slug}.txt` files, `{name}_shopify_manifest.json`

Discovery layers:
1. CDN prefix from fetched HTML or live homepage
2. Storefront API access token extraction from HTML
3. GraphQL product discovery via Storefront API
4. Live store scraping (`/products.json`, `/collections.json`)
5. Wayback CDX CDN URL mining (`cdn.shopify.com/s/files/{prefix}/*`)
6. CDN liveness HEAD-check (32 concurrent workers)

Merges discovered URLs into existing `links/{slug}.txt` by matching CDN filenames
to product slugs. Unmatched URLs go to `links/_cdn_unmatched.txt`.

No-op if `shopify_cdn.enabled` not set. Shopify-specific.

## Stage: match

**Purpose**: Fuzzy-match slug products to SKU products, deduplicate.

**Inputs**: `{name}_metadata.json`, `{name}_products_index.json`
**Outputs**: Updated metadata with `matched_sku` fields

Matching strategies:
- Exact key match: normalized slug == normalized name+color
- Substring containment: either key contains the other
- Name+color compound: name matches substring, color confirms

~40% of "missing" products are noise (colorways, drafts, aliases). Always dedup
before declaring gaps.

Library: `wayback_archiver.match.match_products()`

## Stage: download

**Purpose**: Download images via multi-strategy cascade.

**Inputs**: `{name}_metadata.json`, `links/{slug}.txt` files
**Outputs**: `products/{dirname}/*.jpg`

Download cascade:
1. **Live CDN** — test with HEAD, download via `tools/cdn/app.sh` (probes PNG > JPG > WEBP)
2. **Direct fetch** — standard HTTP download
3. **Wayback CDX best** — query CDX API for largest cached variant, download with `im_` modifier
4. **Exhaustive** — try every captured snapshot
5. **Asset rescue** — parse CDX dump for asset domain captures by SKU

Post-download validation: check magic bytes (JPEG: `\xff\xd8\xff`, PNG: `\x89PNG`),
reject files <1KB, reject HTML/toolbar injection.

Library: `wayback_archiver.download.*`

## Stage: normalize

**Purpose**: Rename images to semantic names, generate metadata.txt per product.

**Inputs**: Products directory, metadata
**Outputs**: Renamed images, `products/{dirname}/metadata.txt`

## Stage: build

**Purpose**: Compile final catalog JSON + stats.

**Inputs**: Metadata, product directories
**Outputs**: `{name}_catalog.json`

## Gap Recovery (manual, after pipeline)

For pages automation can't reach (anti-bot, CAPTCHA):
- Re-run fetch with `--proxy dc` (datacenter fallback)
- Playwright + network interception for CDN URL discovery
- HAR-based recovery: give user Wayback URLs to browse, parse HAR files for CDN URLs
