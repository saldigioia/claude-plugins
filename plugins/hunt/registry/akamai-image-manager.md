# Akamai Image Manager tenants (`?impolicy=original`)

- **Signature:** `Server: Akamai Image Manager` on the response. Known tenants: `img.nbc.com`,
  `is[0-9]*.fwrdassets.com`, `is[1-8].revolveassets.com`, `www1.assets-gap.com`.
- **Engine:** `cdn_resolve_nbc`, `cdn_resolve_fwrd`, `cdn_resolve_revolve`, plus a generic
  `cdn_resolve_akamai`.

## Lever

**Append `?impolicy=original`.** It is a *named policy* configured tenant-wide that bypasses every
transformation and returns the un-recompressed stored master, straight from the origin
(`server: nginx/1.20.1` instead of `Akamai Image Manager`).

Gains measured across tenants: **2.2–2.9×** (FWRD), **1.9–2.5×** (Revolve), **5–10×** (NBC), **5×**
(GAP). Dimensions are usually identical — only JPEG quantisation differs (PSNR bare 38.5 dB,
cache-buster 41.0 dB, both clearly lossy against origin).

Aliases that reach the same origin: `?impolicy=bypass`, `?imbypass=true`. On a new Akamai IM
tenant, probe in this order: `original` → `bypass` → `passthrough` → `source`.

## Trap

- **`?imformat=png` is NOT a portable substitute.** It is a *transformation directive* the
  per-asset policy may or may not honour. When ignored, `Content-Type` still says `image/jpeg` and
  you silently get the lossy default. Measured on one tenant:

  | asset | `?imformat=png` | `?impolicy=original` |
  |---|---|---|
  | A | 1.62 MB PNG ✓ | 1.62 MB PNG ✓ |
  | B | 231 KB **JPEG** (ignored) | 1.78 MB PNG ✓ |
  | C | 405 KB **JPEG** (ignored) | 2.26 MB PNG ✓ |
  | D | 276 KB **JPEG** (ignored) | 2.51 MB PNG ✓ |

  Reconnaissance on a single asset makes the two look interchangeable. They are not — sample
  several before concluding.
- **A cache-buster (`?cb=1`) is unreliable.** It returns `server: Akamai Image Server` (the cached
  origin proxy) and only works on a cache miss; on a warm cache it is identical to bare.
- **`?imwidth=N` only downsizes/clamps** — never upscales. Useful to discover a source's true
  resolution, useless as a master lever.

## Per-tenant path grammar

- **FWRD** — `is*.fwrdassets.com/images/p/fw/{p|uv|z}/<SKU>_V<N>.jpg`. `/p/`≈384×580 thumb,
  `/uv/` medium, **`/z/` = largest (953×1440)**. No higher path exists: `/h/`, `/orig/`,
  `/original/`, `/full/`, `/max/`, `/master/` all 404.
- **Revolve** — sister site, same stack. `is[1-8].revolveassets.com/images/p4/n/{c|ct|d|dt|ps|z}/<base>_V<n>.jpg`.
  Normalise any of the six folders to `/z/` **before** appending the policy.
  **Filename gotcha:** a per-colour single-letter suffix is appended to the SKU (`YEER-UO4` stores
  as `YEER-UO4W_V1.jpg`). Both forms can exist and reference *different photo sets* (no-suffix =
  a 2018 re-upload at 519 KB; W-suffix = the 2017 original at 220 KB). A max-completeness scrape
  probes `<SKU>{,W}_V<n>.jpg` pairs.
- **GAP webcontent** — `www1.assets-gap.com/webcontent/<PPPP>/<PPP>/<PPP>/cn<id>.<ext>`. See
  [[gap]] for the id grammar and the enumeration warning.

## Enumeration surface

FWRD and Revolve PDPs share the `window.rcProps.pdp` schema and a JSON-LD `Product` block, so one
parser handles both. Deltas: Revolve has no separate `price` key (only `retailPrice`); Revolve PDPs
carry no `data-zoom-img`, so image URLs must come from inline `<img src>` / `<source srcset>` and
be normalised to `/z/`; the `pdp-details` div is Ajax-loaded from a separate endpoint.
URL patterns differ — FWRD `/product-<slug>/<SKU>/`, Revolve `/<slug>/dp/<SKU>/` — and **the
trailing slash is required** on both (hard 404 otherwise).

Related: [[gap]], [[rebelmouse]] (the *opposite* asymmetry — proxy default larger than source),
[[waf-and-bot-walls]] (Akamai Bot Manager is a different product on the same edge).
