# cdn.mos.cms.futurecdn.net — Future PLC CMS media CDN

- **Serves:** every Future plc title — TechRadar, Tom's Guide, PC Gamer, GamesRadar+, Who What
  Wear, Marie Claire, Woman & Home, Livingetc, Homes & Gardens, Space.com, LiveScience, T3,
  Cycling Weekly, Guitar World, MusicRadar, Digital Camera World…
- **Stack:** CloudFront → Varnish → an image service Future calls **kodiak**
  (`x-served-by: kodiak-varnish-*`, `x-ftr-backend-server: sse-prod:kodiak`) over an S3 origin.
  A bad key leaks S3's own `NoSuchKey` XML naming the bucket prefix `/proof/<key>`.
- **Engine:** `cdn_resolve_futurecdn` + `is_futurecdn_image_url` (probe suppression).

## URL anatomy — two unsigned rendition grammars over one stored object

```
<id>-<width>-<quality>.<ext>[.webp]                              # srcset ladder: downscale + re-encode
/v2/t:<top>,l:<left>,cw:<w>,ch:<h>,q:<q>,w:<w>/<id>.<ext>[.webp] # CROP + resize + quality
/flexiimages/<slug><unixts>[-<w>-<q>].<ext>[.webp]               # site chrome/logos, same grammar
```

`<id>` is a ~22-char base62 token with no dashes. `<ext>` ∈ `png | jpg | gif` (`.svg` for chrome).
The trailing `.webp` is an **explicit path suffix, not Accept negotiation** (no `vary` header) —
so no non-webp-Accept lever is needed here.

## Lever

**Strip everything back to the bare `<id>.<ext>`.** Drop the `/v2/<transform>/` prefix, the
trailing `.webp`, the `-<width>-<quality>` suffix, and any query string. Nothing is signed, so
every layer is freely strippable.

Measured gains (Who What Wear cover feature + TechRadar home):

| Page-painted | Master (bare) | Gain |
|---|---|---|
| `-2000-80.png.webp` 175,604 B / 2000×1125 | `.png` 3,855,439 B / 2000×1125 | 22× bytes, lossless |
| `-140-80.jpg` 7,561 B / 140×182 | `.jpg` 1,972,281 B / **2310×3000** | 261× bytes, 16.5× linear |
| `-450-80.jpg` 23,479 B / 450×253 (TechRadar) | `.jpg` 284,655 B / 1801×1013 | 12× bytes, 4× linear |
| `/v2/t:0,l:437,cw:1125,ch:1125,…` 1125×1125 **cropped** | `.png` 2000×1125 **uncropped** | recovers the full frame |

## Why bare is the master (and not just another rendition)

- **No upscale trap.** `-99999-100` clamps to the stored dims on every asset tested, so bare's
  dimensions *are* the source dimensions.
- **PNG sources:** bare is raw-pixel-identical to the rendition (same rgba md5) but a *distinct
  object* — different deflate bytes. kodiak re-encodes; bare is the stored file.
- **JPEG sources:** bare matches **no point** on kodiak's quality ladder — bare 388,791 B vs
  q80 324,458 / q85 351,411 / q86 364,305 / q90 461,914 / q95 555,385, all at identical dims.
  It is therefore the stored upload (measures ~q86, YCbCr 4:4:4), not a derived rendition.

## Traps

- **`-99999-100` is a bloat trap, not an upgrade.** On a JPEG asset it returns 1,101,091 B against
  bare's 388,791 B at the *same* 1900×1900 — **2.8× the bytes at PSNR 55.6 dB**, i.e. a q100
  re-encode of the bare original carrying zero additional information. Take bare.
- **The `/v2/` grammar crops.** `l:437,cw:1125` carves a 1125×1125 square out of a 2000×1125
  master, so a `/v2/` URL can be missing most of the frame — not merely downscaled.
- **The extension is locked to the stored object's format.** `.jpg`, `.tif` and `.webp` on a PNG
  asset all 404 (as does `-2000-80.tif`). There is **no transcode surface**, hence no wrapper
  trap — but also no format ladder to climb.
- **Query params are ignored outright** — `?width=4000`, `?quality=100`, `?fm=png`,
  `?impolicy=original` all return the byte-identical response. No named-policy lever exists.
- Consequence of the last two: the whole Accept/param/path probe ladder can only ever produce
  dead or duplicate candidates, so it is suppressed via `is_futurecdn_image_url`.

## Ceiling

The bare stored object is the public ceiling. It is EXIF-light (ICC profile survives; no camera
EXIF) and there is no `original/`, `source/` or higher tier — `<id>` with no extension 404s to S3.

## Sibling hosts (not media)

`vanilla.futurecdn.net` (site bundles/text), `bordeaux.` / `champagne.` / `freyr.futurecdn.net`
(JS services), `search-api.fie.futurecdn.net`. Only `cdn.mos.cms.futurecdn.net` serves imagery —
scope the resolver to it.

## Enumeration surface

Article HTML carries the full srcset ladder inline; `grep -oE 'cdn\.mos\.cms\.futurecdn\.net/[A-Za-z0-9]+(-[0-9]+-[0-9]+)?\.(png|jpg|gif)'`
then collapse to bare `<id>.<ext>` and dedupe on `<id>`. (63 renditions → 33 unique assets on the
Kylie Jenner cover feature.)
