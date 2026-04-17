# Multi-Platform Support

Sites migrate between commerce platforms over time. The pipeline detects and
handles multiple platforms via config-driven CDN patterns and URL rules.

## Platform Detection

| Platform | CDN | Detection Signals | Key Endpoints |
|----------|-----|-------------------|---------------|
| **Shopify** | `cdn.shopify.com` | `ShopifyAnalytics`, `/products/*.json` | `products.json?limit=1000`, `.atom`, `.oembed` |
| **Swell Commerce** | `cdn.swell.store/{store-id}/` | `__data.json`, SvelteKit markers | `__data.json` (requires `devalue` npm lib) |
| **Fourthwall** | `imgproxy.fourthwall.com` | checkout subdomains | Fourthwall API |
| **Adidas** | `assets.{store}.com` | `/api/products/` | `/api/products/{SKU}`, `/products/bloom` |

## Shopify

- `products.json?limit=1000` returns the complete catalog in one request
- CDN persists years after store closure (confirmed live in 2026 for stores closed in 2019)
- Multiple store IDs per domain — migration creates separate CDN namespaces
- `.atom` and `.oembed` endpoints exist for every collection and product
- UUID-hashed filenames on CDN prevent enumeration — discovery requires rendering pages
- Access tokens embedded in homepage HTML: `"accessToken": "..."` (32 hex chars)
- CDN prefix format: `cdn.shopify.com/s/files/1/XXXX/XXXX/products/`

### Shopify CDN Archaeology

The `cdn_discover` stage (wrapping `shopify_downloader.py`) exploits the fact that
`cdn.shopify.com` almost never deletes files. Even products removed from the store
still have their images accessible on the CDN.

Discovery layers:
1. CDN prefix extracted from any page's HTML
2. Storefront API token extracted from HTML
3. GraphQL product catalog via Storefront API
4. Live store scraping
5. Wayback CDX query for `cdn.shopify.com/s/files/{prefix}/*`
6. HEAD-check all discovered URLs for liveness

### Shopify Size Suffixes

Strip these to get original (full-size) images:
- Numeric: `_400x`, `_800x600`, `_1024x`
- Named: `_grande`, `_medium`, `_small`, `_large`, `_compact`, `_master`, `_pico`, `_icon`, `_thumb`

## Swell Commerce

- SvelteKit-based: `__data.json` endpoints contain structured product data
- **Requires `devalue` npm library** to parse (manual flat-array parsing will break on nested refs)
- CDN: `cdn.swell.store/{store-id}/...`
- Products may have `-blank` suffix variants (e.g., `ts-01-black-blank`) that need matching to canonical slugs

## Fourthwall

- CDN: `imgproxy.fourthwall.com/...`
- checkout subdomains are a detection signal
- Slugs may need matching to Shopify/Swell slugs via product name

## Era Classification

Sites often migrate between platforms over time. The `era_rules` config classifies
products by timestamp and URL pattern to choose the right extraction method:

```yaml
era_rules:
  - condition: "url_type == 'api'"
    era: adidas_api
  - condition: "timestamp_year <= 2017"
    era: early_shopify
  - condition: "default"
    era: late_shopify
```

Different eras need different techniques:
- **Server-rendered (Shopify)**: CommonCrawl WARC first — raw HTML has product data inline
- **SPA/API (Adidas/React)**: API JSON via curl — HTML is empty app shell
- **Structured endpoints**: curl with `id_` — .json/.atom/.oembed don't need JS

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| curl returns 3KB HTML | Wayback JS replay wrapper | CommonCrawl WARC or Playwright |
| Playwright times out on `networkidle` | Dead CDN resources | Use `domcontentloaded` + 8s wait |
| Playwright renders Wayback toolbar | Replay framework as top-level | Network interception for CDN URLs |
| Most pages return "Access Denied" | Anti-bot captured instead of content | CommonCrawl or structured endpoints |
| CDX returns empty for sequential queries | Rate limiting (empty body, not 429) | Batch queries + exponential backoff |
| SPA pages render empty | Data loaded via API, not in HTML | Fetch API JSON directly |
| >90% of handles fail extraction | Wrong method for this era | Triage by era, switch techniques |
| Image download gets HTML | Wayback error as HTTP 200 | Verify magic bytes |
