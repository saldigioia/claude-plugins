# PacSun — Salesforce Commerce Cloud + Adobe Scene7 (a legacy-endpoint case study)

Recovering decade-old campaign imagery from a live commerce site. The general lessons transfer to
**any SFCC or Scene7 tenant**.

## The split that is the whole story

Two separate image systems in the same era:

1. **Product photography** → Adobe Scene7:
   `images4.<brand>.com/is/image/<company>/<SKU>NEW_<view>_<color>` with Demandware presets.
2. **Site/campaign imagery** → Demandware static:
   `demandware.edgesuite.net/<instance>/on/demandware.static/…`

## LIVE — the content library survives on the modern site

**The live site still serves the old SFCC content library**, under the same instance id as a decade
ago (continuity proof). 50 of 63 archived static assets still return 200, including campaign banners
with EXIF intact:

```
https://www.<brand>.com/on/demandware.static/Sites-<x>-Site/Sites-<x>-Library/default/<anyversion>/<year>/<campaign>/<file>.jpg
```

**The `v<digits>` version segment is ignored** — any version string resolves the same bytes.

**Survival rule (the transferable part):**
- `Sites-<x>-Library/` and `Sites/` (content-library uploads) **persist across code deploys**
- `Sites-<x>-Site/-/default/…` (cartridge static) is **wiped by every deploy** → all 404

**TRAP — Cloudflare Polish webp transcode:** these assets return `image/webp` 28,336 B **regardless
of the Accept header** — a no-webp Accept does **not** defeat it. A unique `?cfbust=<rand>` forces a
MISS and yields the original `image/jpeg` 47,387 B. **Always cfbust here.** See
[[cloudflare-polish]].

## ALIVE BUT GATED — Scene7, the only plausible home of the product masters

The Scene7 company still exists but is **IP-restricted**.

> **Discriminator worth reusing on any Scene7 hunt:** a **nonexistent** company returns HTTP 200
> with `catalogRecord.exists=0` on `?req=exists`; a **live-but-restricted** one returns HTTP **403
> `Client IP address forbidden.`** Verified across `s7d1` / `s7d13` / `s7ondemand1.scene7.com` and
> both `/is/image/` and `/is/content/`.

That distinction turns "I got an error" into "the assets exist and I need an allowlisted IP" — which
is a documented dead end rather than an ambiguous one.

**TRAP:** `/ir/render/<company>/<anything>` returns **200 `image/jpeg` 5,855 B 400×400 — and it is
byte-identical (same md5) even for a bogus asset name.** A placeholder render: valid magic bytes,
zero product pixels. The classic "200 + real image + no information" failure.

## GONE (with evidence)

- The modern product path uses the **identical filename scheme** to the old Scene7 asset names — the
  DAM naming survived the migration — but every era-specific name 404s. Only one catalog namespace
  exists; every variant 404s even for a known-live current asset.
- Retired SKUs are purged: `Product-Show` 404, `Product-ShowQuickView` → `"product": {}`, campaign
  landing pages 307 → `/`. OCAPI is enabled (401 on a bogus client_id) **but the records are gone**.
- `demandware.edgesuite.net` still resolves and accepts TCP but **504s** — the Akamai edge config is
  alive while the origin is dead. (A 504 here means "edge alive, origin dead", not "wrong host".)
- `dev.` / `staging.` / bare apex are Cloudflare aliases of production, byte-identical — **no
  separate instance to raid.**
- A path-style S3 host exists (`AccessDenied`, not `NoSuchBucket`, so the bucket is real) but every
  key GET is 403 — opaque, no public objects.

## Enumeration surface used

**CertSpotter CT API** —
`api.certspotter.com/v1/issuances?domain=<d>&include_subdomains=true&expand=dns_names` — returned 26
subdomains on a day when **crt.sh was 502**. Keep it as the fallback answer to "what hosts did this
brand ever run".

Related: [[cloudflare-polish]], [[waf-and-bot-walls]], [[dead-shopify-storefronts]].
