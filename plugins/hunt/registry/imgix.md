# imgix (generic, custom domains, and per-tenant configs)

- **Signature:** `*.imgix.net`, or any host answering with `server: imgix` / `x-imgix-id`.
  **Custom domains are the gotcha** — a tenant on `imgix.<brand>.com` never matches an
  `.imgix.net` rule and falls through to generic param-stripping, which can land on a lossy tier.
- **Engine:** `cdn_resolve_imgix` (generic strip), plus `cdn_resolve_imgix_bustle`,
  `cdn_resolve_stockx`, `cdn_resolve_skims` ordered **before** it.

## Lever

Strip params to bare, then decide bare-vs-`?q=100` **per tenant** exactly as with [[sanity]]:

```
bare GET size  vs  ?fm=json  source Content-Length
equal  → bare is byte-exact, suppress the ladder
less   → bare is a lossy re-encode, ?q=100 is the master
```

**`?fm=json` is the universal oracle here** — it reports the true upload's dimensions and
Content-Length, which is what tells an upscale from a clamp and a re-encode from a passthrough.

### Finding an unrestricted root when the consumer host is locked down

When a consumer-facing host has a restrictive custom config (params silently ignored), try
**`<source-name>.imgix.net`**. The source name is whatever sits before `.imgix.net` in any of the
tenant's *secondary* URLs — a `<brand>-assets.imgix.net` reference tells you the tenant name is
`<brand>`. The root subdomain typically carries no custom restrictions and shares the same origin
bucket, so its bare URL is the byte-exact upload.

## Known tenants

| Tenant | Rule | Notes |
|---|---|---|
| **BDG / `imgix.bustle.com`** (Nylon, Bustle, Romper, Inverse, Mic, W, Zoe Report, Elite Daily, Scary Mommy, Fatherly, Input) | **`?q=100`** | Custom domain, **not** `*.imgix.net`. Bare is a lossy ~q75 re-encode: 1.87 MB vs 6.81 MB at identical 6449×8062 dims (3.65×). |
| **StockX** | host-swap to the imgix root, **bare** | `images.stockx.com` ignores `w`/`q`/`fm`; only `?dpr=N` survives and `?dpr=4` is a **1.5× upscale + re-encode** (2400×1712 / 441 KB) over a 1600×1141 / 1.23 MB source. Bare on the root = byte-exact. `?fm=png` gives lossless PNG at native dims. |
| **SKIMS** | **bare** (already-optimised uploads) | See [[skims-shopify]]. `fm=png`/`fm=tif` are bloat/wrapper traps and `w=` upscales, so the whole ladder is suppressed. |

## Trap

- **`fit=clip` upscales when `w=` exceeds the source** — fake interpolated pixels that beat the
  honest source on the size tiebreaker. Always check requested dims against what `fm=json` calls
  the source before believing a big number.
- **8192px hard long-edge cap** on at least the BDG tenant (same ceiling as Sanity). A 7341×9177
  source is delivered at 6553×8192; the true original sits on imgix's private origin bucket.
- **Delivery strips EXIF.** `fm=json` may report `DateTimeOriginal` on the upload while the
  downloaded file has no Make/Model/DateTimeOriginal — that absence confirms you have a re-encode,
  not the byte-exact origin.
- `?fm=png` / `?fm=tif` on a lossy source are lossless wrappers. The engine's transcode guard
  demotes them on same-dims, so no per-tenant suppression is needed *unless* the tenant's page
  URLs also carry upscaling `w=` params (SKIMS does; BDG's are downscale-only and harmless).
- A bare imgix passthrough may return `Content-Type: binary/octet-stream` because imgix skips
  magic-byte detection on untransformed requests. A validator that demands an image content-type
  will reject the real master and fall back to the lossy consumer host.

## Enumeration surface

- **BDG "Circulate" CMS** — GraphQL at `graph.bustle.com` using **persisted queries**
  (`?variables={"site":"<SITE>",…}&extensions={"persistedQuery":{"version":1,"sha256Hash":"<hash>"}}`).
  Easier: the article HTML embeds the full CMS payload, and each image node carries `url` plus the
  **true source `width`/`height`** — which is how you spot over-8192 sources without probing.

## Dead ends

- Obvious BDG origin bucket names (`bustle`, `bdg`, `bustle-uploads`) return `AccessDenied` /
  `NoSuchBucket`. Over-cap originals are not publicly retrievable.

Related: [[sanity]] (identical bare-is-lossy + 8192 discipline), [[therealreal]] (Fastly IO, the
same upscale trap on a different optimizer).
