# gap.com — webcontent image server + Orange Logic Cortex DAM

**Two separate systems. Getting them confused costs a whole hunt** — the first pass here chased the
Cortex assets and they turned out to be UI chrome, not the campaign photography.

## System 1 — campaign/editorial PHOTOS on the webcontent server (this is the one you want)

Three fronts over one Akamai origin:

```
www.gap.com/webcontent/<PPPP>/<PPP>/<PPP>/cn<id>.<ext>        page-painted, q93
content.gapinc.com/b/<PPPP>/<PPP>/<PPP>/cn<id>.<ext>          SpeedSize front, q92
www1.assets-gap.com/webcontent/<PPPP>/<PPP>/<PPP>/cn<id>.<ext>  server: Akamai Image Manager, q85 default
```

**Path grammar:** the `cn` id is zero-padded to 10 digits and split 4/3/3 —
`cn63088238` ⇒ `/0063/088/238/cn63088238.jpg`. Each cn id has **one fixed stored format**
(`.jpg` *or* `.png`); the wrong extension 404s.

**MASTER LEVER = `?impolicy=original`** on the `www1.assets-gap.com` Akamai host → the
un-recompressed stored master: full-quality JPEG, or a **true lossless PNG** for png-native ids.
Measured: default 162 KB (q85) → `?impolicy=original` **810 KB** at the same 1040×1386 (**5×**).
Same lever as [[akamai-image-manager]].

**`?imwidth=N` only downsizes/clamps** (imwidth=5000 on a 1040px source stays 1040). Use it to
discover a cn's true stored resolution — never as an upscale lever. **A cn's ceiling is its stored
rendition; a bigger version is a different cn id.**

### Enumeration warning — cn ids are a global counter

One photo's render ladder (39×52 … 520×693 … 1040×1386 … 1500×2000 … 5000×6665) is spread across
**different, non-contiguous cn ids**, and the counter is **global across all of gap.com**, so one
upload window interleaves many campaigns and models. **A cn range is not a campaign.**

You must **visually confirm** target frames: sweep the range, HEAD for Content-Length to tier by
size, download, and build a contact sheet. In one verified sweep the 1500×2000 and 5000×6665
masters sitting in the *same batch* as the target's frames belonged to an entirely different model
and product line — the target's own ceiling was only 1042×1386. Size alone would have picked the
wrong photos.

## System 2 — Cortex `/d/` AssetLink (UI tiles, montages, video; NOT the campaign photos)

- **Painted URL** = `content.gapinc.com/d/<32-char-base36-token>.auto?TP=GAP2` — a **SpeedSize**
  AI optimizer (`x-powered-by: SpeedSize`, CloudFront→S3). `.auto` content-negotiates to a tiny
  avif/webp; `?TP=GAP2` is the lossy transform preset. Painted 40 KB webp for a frame whose master
  is a 1.5 MB JPEG at the **same** 1290×1270 dims (PSNR 40 dB = real fidelity loss, 37× smaller).
- **Origin master** = **extensionless** `https://digitalassets.gapinc.com/AssetLink/<token>` →
  the stored original in its native format (svg→svg, jpg→jpg, mp4→mp4), byte-exact, **public, no
  auth**. Verified: extensionless Content-Length == the `.json` `filesize` == the direct `.jpg`.
  (The SpeedSize `f-key` response header leaks this origin.)

**Traps:**
- `.auto` on either host → tiny content-negotiated avif/webp. Never the master.
- Any `?TP=` → SpeedSize lossy re-encode.
- **`.tif` / `.png` requests → Cortex transcodes on the fly to same-dimension lossless wrappers**
  (`.tif` is exactly W×H×3 uncompressed; `.png` ~1.4× the jpg). Bloat/wrapper trap, zero added
  fidelity over the stored JPEG. Skip them.
- These are **web-resolution** masters (largest seen 1440×1426; most 420–860px). The extensionless
  original is the public ceiling — no hi-res print file is publicly reachable.

**Useful side endpoint:** `/AssetLink/<token>.json` returns ImageMagick `identify -verbose` JSON
(geometry, compression, quality, filesize) **without downloading the binary** — a cheap way to size
a whole manifest.

### Enumeration verdict — the DAM browse is closed

- Cortex REST `digitalassets.gapinc.com/API/search/v3.0/search` → **401** (token-gated);
  `/API/authentication/v1.0/Login` → 405 (needs POST).
- `content-disposition: filename="G10XXXX.jpg"` leaks each asset's Cortex **DocID**, but the DocID
  is **not usable on the public AssetLink endpoint** (`/AssetLink/G10HOGKQ.jpg` → 404). AssetLink
  tokens are opaque per-asset public keys, **not derivable from the DocID → no brute force.**
- **Therefore the de-facto collection manifest is the set of AssetLink tokens embedded in the page
  HTML.** One campaign story surfaced 77 assets (43 jpg, 4 png, 16 svg, 14 mp4).

## Other GAP surfaces (separate systems)

- Corporate newsroom `www.gapinc.com` = Optimizely/EPiServer on Azure Front Door; images at
  `gapinc-prod-*.z03.azurefd.net/gapmedia/…` — real filenames, corporate-res tiles, not the
  campaign DAM.
- gap.com home is behind Akamai Bot Manager (`/o_*/` sensor). See [[waf-and-bot-walls]].
- Amplience (`gapprod.a.bigcontent.io`, `cdn.c1.amplience.net`) serves only UI SVGs and a couple of
  JS snippets — not the campaign store.
