# Cloudinary (res.cloudinary.com + every custom CNAME)

- **Signature:** any URL containing `/image/upload/` — including custom CNAMEs
  (`images.complex.com`, `images.gq.com`, `images.mashable.com`, …). `Server: Cloudinary` or an
  `X-Cld-Error` header on a 404 confirms it and often leaks the cloud name.
- **Engine:** `cdn_resolve_cloudinary` (matches the path signature, not just the host) +
  the runtime helper `cloudinary_bare_master`.

## Lever

Strip the transform segment to the bare public-id URL, then **verify with `fl_getinfo` before
climbing any format ladder**:

```
https://<host>/image/upload/fl_getinfo/<public_id>     → JSON: input.{width,height,bytes}
```

`input.bytes` is the true stored original. If a bare HEAD equals `input.bytes`, **bare IS the
byte-exact master — stop, and suppress the format ladder entirely.** Only when bare is smaller
than `input.bytes` (the account forces optimised delivery) is the format ladder a real fallback.

This is account-dependent, not universal. "Bare serves Cloudinary's lossy `q_auto` default" is
true on some accounts and false on others; `fl_getinfo` is what settles it.

## Trap

Two wrapper/bloat traps that both **win on format priority and size while adding zero fidelity**:

- **`.tif` / `f_tiff` is JPEG-in-TIFF** — a TIFF wrapper around lossy JPEG, *lower* fidelity than
  the same asset's `f_png`. Measured PSNR PNG↔TIF 38 dB vs PNG↔JPG 68 dB, i.e. the "TIF" is worse
  than the bare JPG. The engine skips `.tif` swaps on `/image/upload/` for this reason.
  Generalisable check: `file out.tif | grep 'compression=JPEG'` → lossy, do not prefer over PNG.
- **`.png` on a JPEG-origin asset is a bloat trap** — a lossless re-wrap of already-lossy pixels.
  Same dimensions, ~5× the bytes (6.6 MB PNG vs 1.33 MB JPEG), zero added information, yet it
  beats JPG on the format ladder. One portfolio account served `.tif` at **1.3–3.6× SMALLER** than
  the source while still winning top format priority — the worst version of this trap.

## Sub-case: delivery-only CNAMEs with transforms disabled

Some tenants bind a cloud to a CNAME and **root-map it**, so `/image/upload/` is not in the path
and the transformation API is off:

- `<host>/<public_id>.jpg` is the only form that works; `<host>/image/upload/<id>.jpg` → 404 with
  the error echoing the path as part of the public_id.
- Every transform (`w_3000`, `f_png`, `q_100`, `dpr_4`, `c_limit`, `fl_attachment`, …) → 404.
  `fl_immutable_cache` returns 200 byte-identical (cache hint, no pixel change).
- Query params (`?w=`, `?q=`, `?fm=`, `?dl=`) return 200 **byte-identical** — silently dropped.
- URL extension is cosmetic: `.jpg` and `.png` serve identical bytes; `.tif`/`.webp`/none → 404.
- **The bare URL is the source upload ceiling.** Do not spend probe budget on transform paths.
- Only meaningful negotiation is `Accept: image/webp` → a *lossless* WebP transcode ~5% larger
  than the JPEG. JPG wins format priority anyway, so the pipeline handles it correctly.

## Enumeration surface

- **`image/sprite/<tag>.css`** is often the only Cloudinary API surface that answers on a locked
  cloud — 400 with `X-Cld-Error: No images found for sprite <tag>` proves reachability, but it
  only lists assets carrying public tags (usually none). `image/list/<tag>.json` 404s instead.
- **Format / format.com portfolios** (legacy "ALLYOU" branding) sit on Cloudinary with public-id
  shape `<n>/<siteid>/images/<imgid>/<stem>`. **The page URL *is* the feed API**: append
  `?start_index=0&limit=1000` to a gallery URL and it server-renders the whole gallery. The bare
  page is a JS shell with **zero images** — the params are mandatory. Each `<img>` carries a
  `data-media` JSON blob with true source dimensions and a rendition `set[]` whose **last
  (transform-free) entry is the master** — no probing needed.
  - These sites are **catch-all 200** (`/sitemap.xml` returns the homepage), so **never probe
    gallery ids** — follow real hrefs only.
  - A category "overview" page is not a master index; one indexed site listed 60 of 264 galleries
    there, the rest reachable only via their category. **Seed every container or miss most of it.**
  - **Dedupe on the base stem, never the public id or the slug.** Cloudinary appends a random
    6-char suffix per name collision and *stacks* it on re-upload (`_vxhfff` → `_vxhfff_rjmuhb`).
    Conversely, two galleries can share a slug and zero base stems — genuinely different shoots.

## Dead ends

- On a root-mapped delivery CNAME, an exhaustive ~1,800-probe sweep of one product's public_ids
  confirmed exactly 11 exist (hero landscape ×5, portrait ×5, thumbnail) — no `_master`,
  `_source`, `_original`, `_full`, `_print`, `_HD`, `_2x`, numeric-id or hash variants. The brand
  uploaded cropped delivery JPEGs directly; masters live in an internal DAM, not on Cloudinary.

Related: [[substack]] (substackcdn is Cloudinary fetch mode), [[sanity]] (same wrapper-trap family).
