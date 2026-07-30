# Dead storefronts — the live-CDN-first rule

**When a storefront origin dies, the CDN often outlives it.** Probe the *CDN* paths, not the
storefront subdomain.

## The rule

```
storefront origin (shop.<brand>.com, <brand>.com)   →  usually dead after a takedown
cdn.shopify.com/s/files/<shop-path>/…               →  frequently still serving
```

Shopify CDN objects survive the storefront's removal in many cases, so a dead product page does not
mean dead images. Verified across several defunct stores: origins dead, CDN mostly live.

**Protocol-relative URLs** (`//cdn.shopify.com/…`) are a common scraper output form — just prepend
`https:`. That single fix rescued 35 images in one pass.

## But the CDN is not guaranteed

One dedicated store's CDN path was **dead at origin AND had zero Wayback snapshots** — 24 URLs
queried, 24 returned "no snapshots". Pure loss.

**Why it matters:** the store was taken down after a partnership terminated, and the CDN path was
never covered by the archive's usual retention. So "Shopify CDN survives" is a *tendency*, not a
guarantee — confirm per store and record the negative with its evidence.

Other confirmed-dead sources worth not re-querying:

- A brand's dedicated Cloudinary CDN, decommissioned after a corporate split — only low-res archive
  thumbnails survive for a subset.
- **JavaScript-rendered SPA product pages**: Wayback captures the shell but **not** the rendered
  product page, so a headless-browser replay of archived captures finds **zero** usable HTML. Don't
  build that pipeline expecting results.

## Recovery routes when the dedicated CDN is gone

- **Cross-reference a sibling corpus by product/style code.** A partner or parent brand's own image
  corpus often holds higher-resolution copies of the same products.
- **Your own prior HTML captures** are an asset. One set of 360 saved pages yielded 542 distinct
  image URLs, of which 315 were still fetchable live.

## Trap — paginated feed URLs scraped as products

Shopify paginated feed URLs like `/products/1.xml` can get scraped **as if they were a product**,
producing a fake record with dozens of mis-attributed images. One such artifact collected 64 orphan
images. Quarantine and re-attribute by perceptual hash rather than trusting the scrape's grouping.

Related: [[pacsun-sfcc-scene7]] (the same question on a different commerce platform),
[[skims-shopify]] (a *live* headless Shopify and its Storefront GraphQL surface).
