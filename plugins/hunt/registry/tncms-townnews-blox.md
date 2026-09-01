# TownNews / BLOX Digital (TNCMS)

**Hosts:** `bloximages.<region>.vip.townnews.com/<publication>/content/tncms/assets/…`
and the publication host directly (`www.nola.com/content/tncms/assets/…`).

**Scale:** the CMS behind ~2,000 US local-news sites. Verified: nola.com,
theadvocate.com, stltoday.com, tucson.com, richmond.com, tulsaworld.com,
omaha.com, journalstar.com (7/7 tested expose the lever; ~8.3M image assets).

## The lever: a hidden `hi_res` resource, findable only via the search API

BLOX downscales **every** editorial upload to a fixed **AREA of 2,073,600 px
(= 1920×1080)**, preserving aspect ratio. Verified across a 16-photo gallery
where landscape (1915×1082) and portrait (1246×1664) frames all land on the same
2.07 MP area — spread 0.15%, pure integer rounding. That capped `.image.jpg` is
the *only* rendition referenced by the page, srcset, JSON-LD, og:image and the
image permalink page.

The photographer's full-resolution delivery is stored as a **separate resource**,
`<hash>.hires.jpg`. It is invisible: the string `hires` appears **0 times** in
both the article HTML and the image permalink HTML, and its resource hash is
**not derivable** from the `.image.jpg` hash (`…91e06` → `…9330b` share only the
leading timestamp). No pure string rewrite can reach it.

**The only discovery surface** is the site's public, auth-free BLOX search API:

```
https://<publication>/search/?f=json&t=image&l=1&q=uuid:<asset-uuid>
```

`q=uuid:<uuid>` is a Solr field query — plain `q=<uuid>` returns 0 rows, and
`id=`/`uuid=` params are ignored (they return the unfiltered corpus). The row
carries `hi_res.{resource_url,width,height,file_size}` plus `title` (the real
photo-desk filename, e.g. `NO.yefans.083026035.jpg`).

Use `-L`: several BLOX sites 301 the bare host to `www.`. Some (Lee Enterprises
titles) additionally need `curl_cffi` impersonation — a plain-curl non-JSON
response is a **bot wall, not an absent API**.

Measured gains on one gallery: 16/16 images had `hi_res`, **2.0×–20.6× the
pixels** (max 7994×5332 off a Canon R5 II), Q91 vs Q80, EXIF/IPTC intact
(camera, lens, Artist byline, caption, 300 DPI). Whole gallery 4.7 MB → 64.5 MB.

## Traps

- **The resizer UPSCALES without clamping.** `?resize=4000` on an 1905px source
  returns a real 4000×2282 image, 1.8× the bytes — pure interpolation. PSNR
  33.2 dB vs true 4000px detail; HF energy 1.34 vs the master's 4.11. Even
  `?resize=1906` on a 1905px source upscales. Oversize (`?resize=99999`) 302s
  to `?_fallback=1` with `x-imageprocstatus: 500`.
- **`?quality=100` is silently ignored** — md5-identical to bare.
- **bloximages bare is a Q63, EXIF-stripped re-encode** (238,869 B). The
  publication host serves the stored file at Q80 with EXIF (346,173 B). Neither
  is the master.
- **Cloudflare Polish on bloximages.** A cached HIT can return a q85
  RE-COMPRESSION of the master (`cf-polished: webp_bigger`, `cf-bgj: imgq:85`) —
  measured 1,557,355 B against the CMS-declared 1,694,944 B. The API's
  `hi_res.file_size` is the origin truth: on any shortfall, re-fetch with a
  unique `?cfbust=<rand>` to force a MISS. app.sh's existing Polish bypass
  already covers this; `tncms_grab.py` checks bytes and retries.
- No tier above `hi_res`: `.original`/`.source`/`.raw`/`.master`/`.hires.tif`/
  `.hires.png` all 404. Largest masters are natural crops of the 8192×5464
  sensor — no cap is applied to `hi_res`, so it IS the ceiling.

## Enumeration

- Whole article: scrape `assets/v3/editorial/<a>/<bb>/<uuid>/` tokens from the
  HTML, then one `q=uuid:` API call per uuid.
- Whole site: `?f=json&t=image&l=<n>&s=start_time&sd=desc` walks the image
  corpus; `t=article` returns full article bodies (which also bypasses the
  "hardwall" paywall flag).
- Asset shortlink: `https://<host>/tncms/asset/editorial/<uuid>` 302s to the
  image permalink, whose slug encodes the filename.

## Wired into app.sh

`is_tncms_image_url` / `tncms_asset_uuid` / `tncms_site_host` (pure) +
`tncms_hires_master` (runtime, network — like `cloudinary_bare_master`), called
from `stage_cdn_resolve_baseline`. It returns two lines (url, title) because the
caller uses `$(…)` and a global cannot cross the subshell. `TNCMS_HIRES=true`
suppresses the probe ladder (every rung is dead or a fake-pixel trap) and keeps
the CMS filename as the stem instead of the opaque `<hash>.hires`.

## Companion tool

`~/Downloads/tncms_scrape/tncms_grab.py` — article / photo-collection / single-asset
input; a collection's API record carries an authoritative `items[]` of children
(the HTML holds only the non-lazy-loaded subset). Emits manifest.json+csv with
permalink, master URL, byline, caption, timestamps and pixel gain.
