# SKIMS — headless Shopify + Sanity (two separate image layers)

- **Hosts:** `skims.imgix.net` (Shopify file-store origin), `skims-sanity.imgix.net` and
  `cdn.sanity.io` (marketing/campaign).
- **Engine:** `cdn_resolve_skims` + `is_skims_imgix_url` (suppresses the probe ladder).

## Lever

**Bare URL, no params** — both imgix hosts are passthroughs and the bare URL returns the upload
byte-for-byte (verified: `?fm=json` source Content-Length == bare GET size).

## Why this needs its own rule, not just generic imgix

The generic imgix resolver already strips to the same bare URL. **The real work is
trap-suppression**, because SKIMS uploads are **lossy JPEGs stored with a `.webp` extension**
(magic-byte and `fm=json` Content-Type both confirm JPEG):

| candidate | size | reality |
|---|---|---|
| **bare** | 150 KB `image/jpeg` | **the honest master** |
| `?fm=png` | 922 KB | lossless wrapper, **6×**, zero added fidelity |
| `?fm=tif` | 164 KB | TIFF-wrapped JPEG that **wins TOP format priority** |

Both re-encodes are pixel-identical to the JPEG. So the format ladder here is pure bloat and must
be short-circuited.

Additionally, imgix's default `fit=clip` **upscales** when the requested `w=` exceeds the source
(786px source + `w=2619` → a fake 2619×3759, ~10× interpolated bytes). Because the param-laden
page URL would then beat the bare source on the size tiebreaker, the pipeline must also **skip the
"original URL" probe** for these hosts and probe only the resolved bare source.

Both hosts clamp to source on downscale-or-equal requests, so the bare upload is the ceiling
(product masters are 2000×2000).

**Contrast:** on a lossless-PNG-source tenant, `?fm=png` recovers a genuine master — see
[[imgix]] (StockX). The lever is the same; the correct answer is the opposite. Decide per tenant.

## Enumeration — two independent layers

**1. Products — headless Shopify (Hydrogen).** The CDN has no listing and filenames are unguessable
UUID + `?v=`. Legacy `/products/<h>.json` and `/products.json` are 404. Use the **Storefront GraphQL
API** at `https://skims.com/api/unstable/graphql.json` with the public
`X-Shopify-Storefront-Access-Token` header.

> The token is a **client-exposed** Storefront key — read it out of the site's own client JS rather
> than relying on a copy written down here, since these rotate.

```graphql
product(handle:"…"){ media{ ...on MediaImage{ image{ url width height } } } }
collection(handle:"…"){ products(first:N){ nodes{ handle images{ nodes{ url width height } } } } }
```

The returned `image.url` is a `cdn.shopify.com/s/files/…?v=` origin that feeds the pipeline.

**2. Marketing / hero / campaign — Sanity, project `hfqi0zm0`, dataset `production`.** Served from
`cdn.sanity.io` and `skims-sanity.imgix.net`. Per-page sets arrive via the Remix loader
(`/_root.data`, `<path>.data`). The whole library is enumerable through the **open unauthenticated
GROQ API** — 21k+ imageAssets (504 ≥4000px, 50 ≥8000px) and 266 fileAssets including UHD mp4.
See [[sanity]] for the GROQ recipe and caveats.

## Ceiling

**8192px is Sanity's hard long-edge cap** (verified on both hosts).

- source ≤ 8192 → the bare URL is the byte-exact upload
- source > 8192 (e.g. an 18100×12067 / 93 MB asset) → downscaled to 8192, **true original not
  publicly retrievable**; bare serves it at low default quality, so emit `?q=100` for the
  full-fidelity 8192 (~8× larger). JPEG sources only — a PNG is lossless at 8192 either way.

Note the two layers need **opposite** treatment: bare for the Shopify/imgix product layer, and the
per-dataset decision for `cdn.sanity.io` marketing JPEGs (where `fm=png` is an 18.5 MB wrapper of a
698 KB jpg, already demoted by the transcode guard).
