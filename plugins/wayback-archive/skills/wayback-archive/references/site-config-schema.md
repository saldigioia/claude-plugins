# Site Configuration Schema

To add a new target site, create a YAML file in `configs/`. No Python code needed.

## Required Fields

```yaml
name: sitename              # Used for output file naming (no spaces)
display_name: "Site Name"   # Human-readable name
credit_line: "Site Name"    # Credit in metadata.txt
project_dir: /path/to/project  # Working directory for this site
cdx_files:                  # CDX dump files to process (or let cdx_dump stage create them)
  - /path/to/cdx_dump.txt
domains:                    # All domains to scan (including subdomains)
  - example.com
  - www.example.com
  - shop.example.com
```

## URL Classification Rules

Define how to extract product slugs from CDX URLs:

```yaml
url_rules:
  - path_prefix: "/products/"     # Shopify product pages
    url_type: slug
    require_status: "200"
    require_ctype: "text/html"

  - path_prefix: "/api/products/" # API endpoints
    url_type: api
    require_status: "200"
    require_ctype:
      - "application/json"
      - "text/html"

  - path_contains: "/collections/*/products/"  # Collection-embedded
    url_type: collection
    require_status: "200"
    require_ctype: "text/html"

  - path_suffix: ".atom"            # Atom feeds (XML, fetchable with curl)
    url_type: atom
    require_status: "200"
    require_ctype:
      - "application/atom+xml"
      - "text/xml"
      - "application/xml"

  - path_suffix: ".oembed"          # oEmbed endpoints (JSON, fetchable with curl)
    url_type: oembed
    require_status: "200"
    require_ctype:
      - "application/json+oembed"
      - "application/json"

  - path_prefix: "/products.json"   # Shopify catalog API (the holy grail)
    url_type: api
    require_status: "200"
    require_ctype: "application/json"
```

## Era Detection Rules

Classify products by platform era (evaluated in order, first match wins):

```yaml
era_rules:
  - condition: "url_type == 'api'"
    era: adidas_api
  - condition: "timestamp_year <= 2017"
    era: early_shopify
  - condition: "default"
    era: late_shopify
```

## CDN Patterns (for image extraction)

Define patterns for each CDN the site uses. The pipeline now supports multiple
commerce platforms — add patterns for each platform detected:

```yaml
cdn_patterns:
  # Shopify CDN (standard)
  - name: shopify
    regex: 'https?://cdn\.shopify\.com/s/files/[^\s"''\\]+/products/[^\s"''\\]+'
    size_strip: '_(?:\d+|\{width\})x(?:@\dx)?(?=\.\w+)'
    named_size_strip: '_(?:grande|medium|small|large|compact|master|pico|icon|thumb)(?=\.\w+)'

  # Shopify domain-hosted CDN (e.g., mystore.com/cdn/shop/files/)
  - name: shopify_files
    regex: 'https?://(?:example\.com)/cdn/shop/(?:files|products)/[^\s"''\\]+\.(?:png|jpg|jpeg|webp|gif|avif)'
    size_strip: '_(?:\d+|\{width\})x(?:@\dx)?(?=\.\w+)'
    named_size_strip: '_(?:grande|medium|small|large|compact|master|pico|icon|thumb)(?=\.\w+)'

  # Swell Commerce CDN
  - name: swell
    regex: 'https?://cdn\.swell\.store/[^\s"''\\]+\.(?:png|jpg|jpeg|webp|gif|avif)'

  # Fourthwall CDN
  - name: fourthwall
    regex: 'https?://imgproxy\.fourthwall\.com/[^\s"''\\]+'
```

## Download Cascade

```yaml
download_cascade:
  - live_cdn         # app.sh for live Shopify CDN
  - direct_fetch     # Direct HTTP
  - wayback_cdx_best # CDX API for largest variant
  - exhaustive       # Try every snapshot
  - asset_rescue     # CDX asset domain rescue
```

## Optional Fields

```yaml
cdn_tool: /path/to/app.sh  # CDN quality probe tool
junk_patterns:              # Regex patterns to filter garbage URLs
  - '%22|%3[CcEe]'
type_priority:              # Dedup priority (first = preferred)
  - api
  - slug
  - collection
  - sku
catalog_api_patterns:       # For catalog API endpoints
  - "/products.json"
  - "/products.json?limit=1000"
min_image_bytes: 500        # Minimum valid image size

# Commerce platform hints (auto-detected, but can be specified)
platforms:
  - shopify
  - swell
  - fourthwall
```

## CDX Dump Stage (Stage 0)

Wraps `wayback_cdx_v2` via subprocess to automatically produce CDX dump files.
All fields are optional — the stage is a no-op if `cdx_tool` is not set.

```yaml
cdx_tool: /path/to/wayback_cdx_v2    # Path to wayback_cdx_v2 package directory
cdx_dump_max_age_days: 7              # Skip re-dump if file is newer than N days
cdx_dump_proxy_mode: auto             # Proxy mode: auto | dc | isp | off
cdx_dump_from: "2015"                 # Start timestamp filter (1-14 digits)
cdx_dump_to: ""                       # End timestamp filter (1-14 digits)
```

The CDX tool runs as a subprocess to preserve its own checkpoint/resume,
proxy management (TokenBucket + CircuitBreaker), and metrics reporting.
Output files are written to `project_dir/{domain}_wayback.txt` and
automatically registered in the config's `cdx_files` list for downstream stages.

## Shopify CDN Discovery (cdn_discover stage)

Wraps `shopify_downloader.py` to discover all CDN image URLs including from
delisted/removed products. Shopify-specific — no-op for non-Shopify stores.

```yaml
shopify_cdn:
  enabled: true                         # Enable CDN discovery stage
  downloader_path: /path/to/shopify_downloader.py  # Path to the script
  myshopify_domain: "store.myshopify.com"  # .myshopify.com domain (auto-discovered if omitted)
  access_token: ""                      # Storefront API token (auto-discovered if omitted)
  cdn_prefix: ""                        # CDN prefix like "1/0123/4567" (auto-discovered if omitted)
  full_size: true                       # Strip size suffixes to get original images
  skip_liveness: false                  # Skip HEAD-check for CDN URL liveness
  max_wayback_json: 200                 # Max archived product JSONs to fetch
```

Discovery layers (run in order):
1. CDN prefix from fetched HTML or live homepage
2. Storefront API access token extraction from HTML
3. GraphQL product discovery via Storefront API
4. Live store scraping (`/products.json`, `/collections.json`)
5. Wayback CDX CDN URL mining (`cdn.shopify.com/s/files/{prefix}/*`)
6. CDN liveness HEAD-check (32 concurrent workers)

Output: discovered URLs merged into `links/{slug}.txt` files, unmatched URLs
written to `links/_cdn_unmatched.txt`, full manifest saved to
`{name}_shopify_manifest.json`.

## Alternative Archives

Configure fallback archive sources for URLs that fail the primary
Wayback + CommonCrawl cascade. These are tried after the main fetch
cascade is exhausted (Step 4, after proxy, before giving up).

```yaml
alternative_archives:
  enabled: true
  sources:
    - archive_today    # archive.ph / archive.today — on-demand captures
    - memento          # timetravel.mementoweb.org — cross-archive aggregator
```

Can also be enabled per-run via CLI:
```bash
python3 run_stage.py fetch --config configs/site.yaml --fallback-archives archive_today memento
```

When enabled, after the primary cascade completes, the pipeline:
1. Identifies URLs that failed (no output file or file < 500 bytes)
2. Queries archive.today's timemap for available captures
3. Queries Memento Time Travel for cross-archive captures
4. Fetches from the most recent snapshot found
5. Records successes as `alt_archive` method in fetch_stats.json

## Junk Patterns

The junk pattern filter rejects URLs matching these patterns. Common junk:

```yaml
junk_patterns:
  # URL-encoded characters in paths (malformed URLs)
  - '%22|%3[CcEe]|%7[Bb]|%5[Bb]|%0A'
  # Template/placeholder strings
  - 'undefined|:productId|\[insert'
  # Shopify web pixels and tracking
  - 'wpm@|sandbox/modern'
  # Image optimization query params leaked into paths
  - '=center|=fast|=pad|=100|=80|=16|=375|=560'
  # JavaScript files in product paths
  - '\.js$'
```

## Example: Multi-Platform Site

```yaml
name: mystore
display_name: "My Store"
credit_line: "My Store"

domains:
  - mystore.com
  - www.mystore.com
  - shop.mystore.com

cdx_files: []                         # Populated by cdx_dump stage
project_dir: ./projects/mystore

url_rules:
  - path_prefix: "/products/"
    url_type: slug
    require_status: "200"
    require_ctype:
      - "text/html"
      - "application/json"

era_rules:
  - condition: "timestamp_year <= 2022"
    era: pre_shopify
  - condition: "default"
    era: shopify

cdn_patterns:
  - name: shopify
    regex: 'https?://cdn\.shopify\.com/s/files/[^\s"''\\]+/products/[^\s"''\\]+'
    size_strip: '_(?:\d+|\{width\})x(?:@\dx)?(?=\.\w+)'
  - name: shopify_domain
    regex: 'https?://mystore\.com/cdn/shop/(?:files|products)/[^\s"''\\]+\.(?:png|jpg|jpeg|webp|gif|avif)'
  - name: swell
    regex: 'https?://cdn\.swell\.store/[^\s"''\\]+\.(?:png|jpg|jpeg|webp|gif|avif)'

shopify_cdn:
  enabled: true
  full_size: true

catalog_api_patterns:
  - "/products.json"

download_cascade:
  - live_cdn
  - direct_fetch
  - wayback_cdx_best
  - exhaustive
```
