# Lessons Learned

Hard-won knowledge from three completed archival projects (Yeezy Supply, Yeezy Gap,
yeezy.com). These are anti-patterns and best practices that should inform every
future pipeline run.

---

## Anti-Pattern: Using curl for Wayback HTML Pages

**What happened**: curl with the `id_` suffix was used to fetch HTML pages from
the Wayback Machine. The response was always ~3KB — Wayback's JavaScript replay
wrapper, not the actual archived content. Hours were wasted downloading thousands
of empty shell pages before the pattern was recognized.

**Why it fails**: Wayback serves HTML pages through a JavaScript replay system.
The `id_` suffix strips the toolbar but doesn't bypass the replay wrapper. The
actual page content is loaded dynamically by JavaScript that curl cannot execute.

**Fix**: Use **CommonCrawl WARCs** as the primary HTML extraction method. WARCs
contain the raw HTTP response — no JS wrapper, no anti-bot redirect. In testing,
CommonCrawl yielded 76% success vs Wayback HTML's 2.4%. For pages CommonCrawl
doesn't have, fall back to Wayback `id_` through the Oxylabs ISP proxy (IP
rotation avoids rate limits). Playwright is the **last resort** — use only when
both CommonCrawl and proxy fallback fail, and primarily for CDN URL discovery
via network interception.

`curl` is correct for: JSON/Atom/oEmbed endpoints (via `id_`), CommonCrawl
WARC records (via HTTP Range), and direct CDN image downloads.

## Anti-Pattern: Downloading Site Chrome as Product Images

**What happened**: The CDN tool (app.sh) was invoked on every image URL found in
product pages, including favicons, apple-touch-icons, logos, and tracking pixels.
Each icon was probed for "best quality" across TIF/PNG/JPG/WEBP formats — wasting
minutes per product on 16x16 pixel files.

**Fix**: Always filter URLs through `is_product_image()` before downloading.
The `extract_image_urls()` function now also filters at extraction time.

## Anti-Pattern: Downloading Every Size Variant

**What happened**: Shopify CDN serves the same image at multiple sizes
(`image_400x.jpg`, `image_800x.jpg`, `image_1200x.jpg`). Without canonicalization,
every size variant was treated as a unique image. One product (`hd-01-04-blank`)
accumulated 229 images — all size variants of ~6 originals.

**Fix**: Use `canonicalize_image_url()` to strip size suffixes before deduplication.
The `download_product_images()` function now deduplicates automatically.

## Anti-Pattern: Missing Wayback `id_` Suffix

**What happened**: Wayback Machine URLs without the `id_` suffix cause the
Wayback toolbar HTML to be injected into responses. For image downloads, this
means receiving HTML instead of image bytes. For JSON endpoints, it means
getting HTML-wrapped JSON.

**Fix**: Always use the `id_` suffix in Wayback URLs:
```
GOOD: https://web.archive.org/web/20240101id_/https://example.com/image.jpg
BAD:  https://web.archive.org/web/20240101/https://example.com/image.jpg
```

## Anti-Pattern: Ignoring Non-Product Paths

**What happened**: The pipeline only indexed `/products/` paths from the CDX dump.
But many e-commerce sites use the homepage as the product page, especially in
earlier eras. Collection pages, data endpoints, and API captures contain product
data that `/products/` paths miss.

**Fix**: Use `find_content_pages()` to discover homepages, collections, and data
endpoints. Sample homepage captures across multiple years to catch era-specific
products. Check for `__data.json` (SvelteKit), `products.json` (Shopify),
`/api/unstable/graphql.json` (Shopify Storefront API), `.atom` feeds, and
`.oembed` endpoints.

## Anti-Pattern: Regex-Parsing Structured Data

**What happened**: SvelteKit's `__data.json` uses the `devalue` library for
serialization. Manually parsing the flat array with index arithmetic
(`start_idx + offset - 2`) worked for simple fields but broke on nested
references, producing dicts-as-strings and other garbage.

**Fix**: Use the `devalue` npm library with Node.js:
```javascript
const devalue = require('devalue');
const parsed = devalue.unflatten(node.data);
```
This properly resolves all references, cycles, and special types.

## Anti-Pattern: Not Deduplicating Across Sources

**What happened**: Products appeared under different slugs from different sources
(Wayback slug `jc-05-black` vs Swell SKU `jc-05-black-blank` vs Fourthwall
`bully-ts-o7-box-b`). Images existed under one slug while the other showed as
empty. Object-ID entries (hex strings from Swell API) cluttered the catalog
with ghost entries that had no name or data.

**Fix**: After fetching from all sources, run cross-source deduplication:
1. Match `-blank` suffix variants to canonical slugs
2. Match object-ID entries to slug-based entries via SKU
3. Cross-copy images between matched directories
4. Remove ghost entries (no name, no images, no useful data)

## Anti-Pattern: Gap-Chasing Before Deduplication

**What happened**: After initial recovery, 180 products appeared "missing". A
significant effort was spent trying to scrape pages for these missing products.
After proper deduplication, only 101 were truly missing — 40% of the gap was
noise (cross-source duplicates, colorways already covered by a base product,
draft/test entries like `copy-of-*`, and alias handles).

**Fix**: Always audit and deduplicate before counting "missing":

| Pattern | Example | Action |
|---------|---------|--------|
| Cross-source duplicates | Same product in API + catalog | Keep the richer entry |
| Colorways | "MENS SWEATPANTS" in 4 colors, have 2 | Mark covered by base product |
| Draft/test entries | `copy-of-`, `-soon` handles | Remove from inventory |
| Alias handles | `crew-neck-dress-trench` / `crewneck-dress-trench` | Merge |

---

## Best Practice: CommonCrawl WARCs for HTML, Proxy for Structured Data

This bears repeating because it's the single most impactful lesson:
- **HTML pages** → CommonCrawl WARC first (76% success), then Wayback `id_` via proxy fallback
- **JSON endpoints from Wayback** → curl with `id_` via ISP proxy (IP rotation)
- **Atom/XML feeds from Wayback** → curl with `id_` via ISP proxy
- **CDN image downloads** → curl (direct, not through Wayback if CDN is live)
- **Playwright** → Last resort only, for CDN URL discovery via network interception

Use `fetch_archive.py` to handle the full cascade automatically.

## Best Practice: JSON APIs First

`products.json?limit=1000` is the holy grail of Shopify recovery. A single fetch
returns the complete product catalog with all variants, prices, descriptions,
tags, and image URLs. Always check for this before spending hours scraping
individual pages.

Also check for Atom feeds (`.atom`) and oEmbed endpoints (`.oembed`) — these
provide structured data without requiring browser rendering.

## Best Practice: Test Live CDN Before Wayback

Shopify CDNs persist years after store closure (confirmed live in 2026 for stores
closed in 2019). Before routing anything through Wayback:

```bash
curl -sI "https://cdn.shopify.com/s/files/1/{store_id}/products/{filename}" | head -1
```

If HTTP/2 200, download directly — faster, more reliable, no rate limits.

## Best Practice: Multiple Store IDs Per Domain

A single domain may use multiple Shopify store IDs across different eras:
```
cdn.shopify.com/s/files/1/0904/6694/products/...  ← Store A
cdn.shopify.com/s/files/1/1324/7915/products/...  ← Store B
cdn.shopify.com/s/files/1/1765/5971/products/...  ← Store C
```
Extract the store ID from each image URL. Never hardcode a single ID.

## Best Practice: HAR Fallback for Rate-Limited Pages

When Playwright fails due to Wayback rate limiting or CAPTCHAs, fall back to
human-assisted HAR capture. Provide the user a list of Wayback URLs, have them
browse manually and save HAR files, then parse the HAR files for CDN URLs.
This hybrid approach (human browsing + automated extraction) consistently
outperforms either approach alone.

## Best Practice: Commerce Platform Detection

Sites migrate between platforms over time. yeezy.com went through:
- Static/CMS (2011-2021)
- Shopify (2022-2024)
- Swell Commerce + SvelteKit (2025)
- Fourthwall (2026, checkout subdomain)

Each platform stores product data differently. The indexer should detect all
platforms present in the CDX and the fetcher should use platform-appropriate
extraction methods.

| Platform | CDN | API | Detection |
|----------|-----|-----|-----------|
| Shopify | `cdn.shopify.com` | `/products/*.json`, GraphQL | `ShopifyAnalytics` in HTML |
| Swell | `cdn.swell.store/{store-id}/` | `swell-js` SDK | `__data.json`, store ID in CDN URLs |
| Fourthwall | `imgproxy.fourthwall.com` | Fourthwall API | checkout subdomain, imgproxy URLs |
| Adidas | `assets.yeezysupply.com` | `/api/products/` | API path patterns |

## Best Practice: CDX Cross-Reference at Every Phase Boundary

Before fetching anything, check which target URLs exist in the CDX. This
prevents wasted requests on URLs that were never archived. Do this before
every fetch batch, not just at the start.

## Best Practice: Shopify CDN Persistence

Shopify CDN URLs (`cdn.shopify.com/s/files/1/...`) often outlive the stores that
used them. Before going to Wayback, test if the original CDN URL is still live.
If so, you can request the maximum resolution with `?width=5760`.

## Best Practice: Swell Commerce Store ID

The Swell store ID is embedded in CDN URLs: `cdn.swell.store/{store-id}/...`.
The public API key (`pk_...`) may be in archived JavaScript bundles. With both,
you can use the Swell frontend API to list all products:
```javascript
const swell = require('swell-js');
swell.init(storeId, publicKey);
const products = await swell.products.list({ limit: 100 });
```

## Best Practice: Wayback CDX API for Discovery

The local CDX dump may be incomplete. The live CDX API supports:
- `collapse=digest` — deduplicate by content hash
- `filter=statuscode:200` — only successful captures
- `filter=mimetype:image/*` — only images
- `matchType=prefix` — wildcard suffix matching

```
https://web.archive.org/cdx/search/cdx?url=cdn.shopify.com/s/files/1/STORE/*&collapse=digest&filter=statuscode:200&output=json
```

## Best Practice: Image Integrity Validation

After downloading, validate every image by checking magic bytes:
- PNG: `\x89PNG`
- JPEG: `\xff\xd8\xff`
- GIF: `GIF8`
- WEBP: `RIFF`
- TIFF: `II\x2a\x00` or `MM\x00\x2a`
- AVIF: `ftyp` in first 12 bytes

Also check for Wayback toolbar injection: reject files starting with
`<!DOCTYPE` or containing `_wm.wombat` in the first 1000 bytes.

## Best Practice: Batching and Rate Limit Protection

When scraping with Playwright:
- Batch pages in groups of 30
- Restart browser context between batches (memory management)
- Use 2-second delays between page loads
- Expect 30-50% failure rate on first pass
- Always plan retry passes — second pass with fresh contexts recovers most failures

## Best Practice: Filter CDX Dumps Before Fetching

Raw CDX dumps are 90%+ junk — redirects, JavaScript files, favicons, tracking
endpoints, robots.txt, checkout pages, Shopify variant checkers, size charts,
sitemaps, and query-param noise (Google Ads gclid/gbraid parameters).

Always run `filter_cdx.py` before feeding URLs to the fetcher. It applies six
filter layers (status whitelist, MIME blacklist, junk path regex, static asset
extensions, variant noise, dedup) and outputs clean Wayback URLs sorted by
value tier. The yeezygap.com CDX dump went from 4,246 to 231 URLs (94.6%
reduction) with zero product data lost.

Key gotchas discovered during filter development:
- Shopify generates numbered sitemaps (`sitemap_blogs_1.xml`, `sitemap_collections_1.xml`);
  match `/sitemap[_.]` not just `/sitemap.xml`
- `/search` needs pattern `/search(\?|$)` not `/search$` (query params)
- Non-product Shopify pages leak through: `/pages/stores`, `/pages/track`,
  `/pages/contact`, `/payments/config`, `/password`, size chart pages
  (`/pages/*-in`, `/pages/*-cm`)
- Always reconstruct clean Wayback URLs after stripping query params —
  the original CDX URLs have tracking params baked in

## Best Practice: ISP Proxy Rotation for Wayback Rate Limits

Wayback Machine rate-limits at 60 requests/minute per IP, with 1-hour IP blocks
that double on each subsequent violation. Oxylabs ISP proxy ports 8001-8020 each
map to a distinct residential IP, giving 20 IPs for round-robin rotation.

This effectively raises the rate limit to 1,200 req/min (20 IPs × 60 req/min
each). In practice, use 5 async workers with port rotation — fast enough for
most recoveries without triggering blocks.

Password URL-encoding matters: Oxylabs credentials may contain `=`, `~`, `+`
which must be percent-encoded in proxy URLs. Use `urllib.parse.quote(password, safe='')`.

## Best Practice: CommonCrawl WARC Fetching

CommonCrawl stores raw HTTP responses in WARC format on S3. Fetch individual
records using HTTP Range headers — no proxy needed, no rate limiting:

```bash
curl -s -H "Range: bytes={offset}-{offset+length-1}" \
  "https://data.commoncrawl.org/{warc_file}" | gunzip
```

Query 24 crawl indices (2022-2026, ~6 per year) for each URL. Cache results to
avoid re-querying. The WARC record contains HTTP headers + body; parse the body
as HTML. If `gunzip` fails or the output lacks `<html`, the record is corrupt —
skip it.

As of March 2025 (CC-MAIN-2025-13), the WARC record truncation threshold
increased from 1 MiB to 5 MiB, meaning more complete page captures are
available.

## Anti-Pattern: Fetcher Agent Contradicting SKILL.md

**What happened**: The fetcher agent (`agents/fetcher.md`) said "Never use curl
to fetch HTML pages" and "Use Playwright for ALL HTML pages." But the SKILL.md
said "Prefer CommonCrawl WARCs over Wayback HTML." The agent that actually did
the fetching was using the method the pipeline's own data showed had an ~80%
failure rate, while skipping the method with 76% success.

**Why it happened**: The fetcher was written before CommonCrawl WARC fetching
was implemented. It was updated for Playwright patterns but never updated when
the SKILL.md added the CommonCrawl hierarchy.

**Fix**: Rewrote `agents/fetcher.md` to align with SKILL.md. CommonCrawl WARCs
are now the primary HTML extraction method. Playwright is last resort. The
`fetch_archive.py` script implements the full cascade automatically.
