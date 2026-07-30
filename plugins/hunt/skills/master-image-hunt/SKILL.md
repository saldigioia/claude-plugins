---
name: master-image-hunt
description: >
  Find the true master (highest-fidelity original) of an image behind any CDN/CMS, and
  enumerate whole image collections from a site's backend API. Use whenever the user hands a
  URL, a page, an image link, or a .har file and wants the best-possible / full-resolution /
  uncropped / lossless / original master — or asks to trace an image to its source, identify
  the CMS/host, dismantle a frontend transform, or list every image in an article/collection.
  Trigger on: "master", "highest resolution", "full-res", "original", "uncropped", "lossless",
  "best quality", "trace this image", "what CDN/CMS", "find the source", "enumerate the
  collection", "all the images in this article", "HAR", ".har", "download the real file", or a
  bare image/CDN URL pasted with intent to upgrade it. This is the companion playbook to the
  vendored engine tools/cdn/app.sh (48 CDN resolvers + a generic fallback), the plugin's
  registry/ of per-host lore, and any project_*_resolver memory files present locally.
---

# Master-Image Hunt

Recover the **byte-exact highest-fidelity original** behind a CDN transform, and enumerate a
site's full image library from its backend. The accumulated per-CDN knowledge lives in the
vendored engine `${CLAUDE_PLUGIN_ROOT}/tools/cdn/app.sh` (48 resolvers + a generic fallback, run
it FIRST), in `CDN_TABLE.md` beside this file, in the plugin's `registry/`, and in any
`project_*_resolver` memory files present on this machine. This skill is the **procedure and the
trap catalog** — how to think, in what order, so a new or unknown CDN is cracked fast and a known
one is never re-derived.

## Prime directive: run the tool before thinking

`app.sh` already encodes 48 hosts. Don't hand-probe a host it knows. First move, always:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/tools/cdn/app.sh" -o ./out '<url>'
# add -c cookies.txt for paywalled/authed; PROBE_DELAY=1 to rate-limit; --no-cdn to debug raw
```

Read the log: `CDN resolved → …` tells you which resolver fired; `BEST → FMT (size)` is the
winner. If the pipeline nailed it, you're done — verify (below) and stop. Only go manual when
the host is **unknown to app.sh** or the result looks wrong (see Traps). When you crack a new
one, the endgame is to **wire a resolver into app.sh** (see "Adding a resolver").

## HAR triage (when handed a .har)

A HAR is a network capture — the master hunt starts by finding which requests fetched imagery
and what the origin really is. Don't read 12 MB of JSON into context; extract with `jq`:

```bash
# every image response, largest first — the biggest bytes are usually closest to the master
jq -r '.log.entries[] | select(.response.content.mimeType|test("image")) |
  [(.response.content.size//0), .response.status, .request.url] | @tsv' file.har \
  | sort -rn | head -40

# unique hosts serving images → identify the CDN/CMS
jq -r '.log.entries[] | select(.response.content.mimeType|test("image")) | .request.url' file.har \
  | sed -E 's#^(https?://[^/]+).*#\1#' | sort | uniq -c | sort -rn

# what Accept header the browser sent (reveals a webp-transcode CDN like Photon/Squarespace)
jq -r '.log.entries[] | select(.response.content.mimeType|test("image")) |
  (.request.headers[]|select(.name|ascii_downcase=="accept").value)' file.har | sort -u

# response headers that fingerprint the stack: x-cache, server, cf-polished, via, x-cld-error
jq -r '.log.entries[] | select(.response.content.mimeType|test("image")) | .response.url as $u |
  .response.headers[] | select(.name|ascii_downcase|test("server|x-cache|cf-|via|cld|powered")) |
  "\($u)\t\(.name): \(.value)"' file.har | sort -u | head
```

Also grep the HAR's HTML/JSON docs for the backend: `__NEXT_DATA__`, `window.playerConfig`,
`Fusion.globalContent` (Arc), `apicdn.sanity.io` / project id, `og:image`, `wp-json`,
`data-attrs` (Substack), `/api/.../graphql`. That's your enumeration surface.

## The master-hunt algorithm

For each candidate image URL, walk this ladder. Stop at the first that yields the master
(verify before trusting):

1. **Is it a proxy that wraps an origin URL?** Decode it. Many CDNs embed the real origin,
   url-encoded, in the path/query: Next.js `/_next/image?url=`, Netlify `/.netlify/images`,
   WordPress Photon `i0.wp.com/<origin>`, Substack `substackcdn.com/image/fetch/<transform>/<enc-origin>`,
   Hypebeast `image-cdn.hypb.st/<enc-s3-origin>`, Thumbor `/unsafe/<origin>`, Cloudflare
   `/cdn-cgi/image/<opts>/<origin>`. Peel to the origin — it's usually the unsigned master.
2. **Is the origin itself on a public bucket?** The proxy often fronts a world-readable S3:
   Substack→`substack-post-media.s3…/public/images/<key>`, RebelMouse→`assets.rbl.ms/<id>/origin.<ext>`,
   Hypebeast→`s3.store.hypebeast.com/media/image/…`. Go straight to the bucket object; it
   bypasses the proxy's lossy re-encode AND any WAF.
3. **Strip ALL query params.** For imgix/Fastly/Sanity/Photon-family hosts the bare URL is
   frequently the untouched upload (or the honest master). Every param (`w`, `q`, `fm`,
   `resize`, `crop`, `quality`, `strip`, `dpr`) can re-invoke the transformer. Compare bare-GET
   size vs the transformed size — bigger + same-or-better format wins. (Trap: on *high-quality*
   Sanity datasets bare is a lossy re-encode — see step 4.)
4. **Request oversize / max-quality that CLAMPS to source.** Some resizers upscale (bad), others
   clamp to the upload and re-encode losslessly (good — use it): mzstatic `…/10000x10000.png`
   (clamps, lossless PNG), StockX `?dpr=4` on `<tenant>.imgix.net`, Sanity hi-q datasets `?q=100`,
   generic imgix `?w=99999` ONLY if the host clamps. **Test clamp vs upscale first** (§Traps).
5. **Named-policy / origin-forcing knobs.** Akamai Image Manager: `?impolicy=original`
   (NBC/FWRD/Revolve). NBC also ignores `?imformat=png`. Cloudflare Polish: any unique
   `?cfbust=<rand>` forces a MISS that serves the un-recompressed origin.
6. **Non-webp Accept header.** If the browser sent `Accept: image/webp` and got a same-dims
   smaller webp, the CDN transcoded on content-negotiation (Jetpack Photon, Squarespace). Re-request
   with `Accept: image/avif,image/png,image/jpeg,image/tiff,image/bmp` (no webp) → original jpeg,
   full EXIF. app.sh does this via `wants_original_accept`.
7. **Format/extension ladder.** Swap `.webp`→`.png`/`.tif`, or add `?fm=png`/`?format=tif`.
   Higher-priority format wins — UNLESS it's a wrapper trap (§Traps: Cloudinary f_tiff, SKIMS).
8. **Sub-size folder / width-prefix / crop-segment promotion.** GOAT `/grid|medium|large/`→`/original/`,
   strip `/transform/v1/`, width prefixes `/<N>/`, named prefixes. Second Name `/media/c/i/<h>`→`/media/i/`.
9. **Path-suffix strip to the unscaled original.** Imgur `…b.jpg`→`….jpg`, Flickr `_b`→`_o`,
   WordPress `-1024x768`→bare, Etsy →`il_fullxfull`. But verify — some suffixes are the native
   size (Substack `_WxH`, stripping 403s).
10. **TLS/WAF bypass.** Cloudflare managed challenge or a WAF blocks plain `curl` on TLS
    fingerprint. Use `curl_cffi` with browser impersonation (`--impersonate chrome`/`safari17_0`
    /`firefox`). app.sh auto-detects `cf-mitigated: challenge` and retries via curl_cffi.

The winner is: **lowest format-priority number, then largest Content-Length**, with a
size-dominance override (≥4× larger wins regardless of format) — but only after ruling out the
traps, because every trap is "bigger and/or better-format but NOT more real pixels."

## Traps — the counterintuitive failures (check every time)

The whole game is distinguishing **more real information** from **more bytes / better wrapper /
fake pixels**. A candidate can win on size or format priority and still be worse. Known traps:

- **False full-res transcode (same dims, fewer/re-encoded pixels).** CDN serves a lossy webp/jpeg
  at the *source's own dimensions* — looks full-res, isn't. Substack "false TIF" (1456px lossy
  webp presented as a `.tif`, 62× smaller than the CMYK master), Photon webp, SKIMS `fm=png`
  lossless-wrapping-a-lossy-jpeg. **Detect:** compare bytes to the origin/`fm=json` source CL;
  if the "upgrade" has the same dims but the origin is far larger, the origin is the master.
- **Upscale trap (fake interpolated pixels).** imgix `fit=clip` upscales when `w=` > source;
  TheRealReal Fastly IO upscales (7130px ceiling is a mirage); SKIMS `w=` interpolates. A
  Lanczos-upscaled 4000px file is not a 4000px master. **Detect:** request a huge width; if dims
  grow past what `fm=json`/EXIF calls the source, it's upscaling — clamp instead, or take bare.
- **Wrapper trap (lossy pixels in a lossless container).** Cloudinary `f_tiff` = JPEG-in-TIFF
  (lower fidelity than its own `f_png`; PSNR PNG↔TIF 38 dB vs PNG↔JPG 68 dB). SKIMS `fm=tif` =
  TIFF-wrapped JPEG that wins on format priority but adds zero fidelity. **Rule:** skip `.tif`
  swaps on Cloudinary; suppress the format ladder when the source is a known lossy upload.
- **Bloat re-encode (more bytes, identical pixels).** RebelMouse `?quality=100` (~3× larger,
  PSNR 56 dB = visually identical), Cloudflare Polish origin, Sanity `fm=png` on a jpeg source.
  Bigger file, no new information → prefer the smaller honest source. app.sh's transcode-detector
  demotes a same-dims-same-or-worse-fmt candidate.
- **Quality-ladder trap.** fbsbx `transcode_extension=jpg` is a fresh ~30 dB re-encode (never
  use); `png` is the lossless master, `webp` the lossy default.
- **Cold-cache HEAD lie.** GOAT `image.goat.com` HEAD returns a fake `404 image/png CL=118` on a
  cold POP even though GET serves the real asset. Retry GET on any 4xx-with-tiny-body; only trust
  the failure if GET is also non-2xx. (app.sh `head_info` does this.)
- **Over-cap unreachable original.** Sanity's hard ceiling is **8192px long-edge** (both
  cdn.sanity.io and imgix proxies); sources above it are downscaled and the true original is not
  publicly retrievable — request `?q=100` for the best obtainable 8192 rendition and note the loss.

## Verify (never trust a filename or a Content-Length alone)

```bash
# magic bytes — is it actually the format it claims? (catches HTML error pages, wrong ext)
file master.jpg; xxd master.jpg | head -1
# real pixel dimensions
identify -format '%wx%h %m %b\n' master.jpg 2>/dev/null || ffprobe -v error \
  -show_entries stream=width,height -of csv=p=0 master.jpg
# EXIF survives on a true original, stripped on a transcode (Photon/Squarespace tell)
exiftool master.jpg | grep -iE 'software|copyright|create date|dimensions' 2>/dev/null
# is bare the master, or a lossy re-encode? compare vs the source Content-Length the CDN admits
curl -s '<imgix-or-sanity-url>?fm=json' | jq '.Output.Content-Length? // .PixelWidth,.PixelHeight'
# two candidates same dims? decide with PSNR — >50 dB = pixel-identical (a bloat/wrapper trap);
# <40 dB = genuinely different fidelity (real upgrade)
ffmpeg -i a.png -i b.png -lavfi psnr -f null - 2>&1 | grep -i psnr
```

Decision: identical dims + PSNR >50 → they're the same picture; keep the smaller/honest one.
Different dims → more pixels wins (unless the bigger one is an upscale — verify it's not
interpolated by checking the source dims the API reports).

## Enumerate the whole collection (backend APIs, mostly auth-free)

Most CMSs expose a public read API — walk it instead of scraping the page. **Scope discipline
(memory `feedback_scope_discipline`): build for the inputs the user gave. Enumerating a whole
site/collection beyond what was asked is scope creep — offer it, don't auto-run it.**

- **WordPress / PMC (Photon):** `/wp-json/wp/v2/posts/<id>`, then
  `/wp-json/wp/v2/media?parent=<id>&per_page=100` (native `media_details.width/height/original_image`),
  and `/wp-json/wp/v2/media?search=<photographer|subject>`. `original_image: null` = the bare
  upload IS the original (no hidden `-scaled`). Also `/wp-json/wp/v2/posts?per_page=100&page=N&search=`.
- **Sanity (general):** open GROQ at `https://<project>.apicdn.sanity.io/v2021-10-21/data/query/<dataset>?query=<url-enc GROQ>`,
  e.g. `*[_type=="sanity.imageAsset" && !(_id in path("drafts.**"))]{url,originalFilename,metadata}`.
  Exclude drafts, sort client-side. Quality is source-dependent (bare vs `?q=100` — decide via
  bare-GET vs `fm=json`). Tools: `skims_sanity.py`, `phenomena_scrape.py`.
- **Shopify (headless/Hydrogen):** Storefront GraphQL `https://<store>/api/…/graphql.json` with
  the public `X-Shopify-Storefront-Access-Token`; `product(handle){media{…image{url width height}}}`.
  Legacy `/products/<h>.json` + `/products.json` if not disabled.
- **Arc XP (WaPo CMS):** page-embedded `Fusion.globalContent` → `content_elements` +
  `promo_items` (dedup by `_id`). Master = `cloudfront-…images.arcpublishing.com/<org>/<ID>.JPG`
  (raw S3, no-auth, full EXIF) — NOT the `/resizer/v2` default.
- **Substack:** `https://<host>/api/v1/posts/<slug>` → `body_html` `data-attrs` (src/w/h/bytes/type);
  catalog via `/api/v1/archive?sort=new&offset=N&limit=50`. Tool `substack_scrape.py`. (`_WxH` in
  the S3 key is the TRUE master res; the data-attrs w/h is on-page render size.)
- **Playboy.com:** WP REST `/wp-json/wp/v2/posts` (4888 posts) or article HTML `<uuid>_WxH` tokens.
  Tool `playboy_scrape.py`. Masters live on the Substack S3 bucket.
- **Vimeo:** `app.sh --vimeo` (JWT API source → player config → yt-dlp). Embed-only clips: pass
  `?h=<hash>` from the iframe src.

Companion scrapers already exist under `~/Downloads/*_scrape/` for SKIMS, phenomena, Substack,
Playboy, Pugpig — check there before writing a new one.

## Adding a resolver to app.sh (the endgame for a new CDN)

Once you've confirmed the master rule for a new host, encode it so it's automatic next time
(this is what "wire it in" means):

1. Write `cdn_resolve_<name>()` — a **pure string transform**, `return 1` on non-match. Place it
   in the `resolvers=(…)` array (search for `local resolvers=(`) — **more-specific hosts before
   generic ones** (e.g. a brand→S3 remap must precede a same-host suffix-stripper).
2. If it needs a no-webp Accept or other header lever, extend the shared predicate
   (`wants_original_accept`) rather than adding a new injection at each of the 4 call sites.
3. Add fixtures to `tools/cdn/tests/run.sh` (input → expected bare/rewritten URL, plus skip
   cases: wrong host, non-image, already-bare). The suite is offline — it sources `app.sh` and
   exercises pure functions only. Run `bash tools/cdn/tests/run.sh` (expect all pass, currently
   128) + `shellcheck app.sh` + `bash -n app.sh`.
4. End-to-end: feed the page-painted (transformed) URL and confirm the pipeline logs
   `CDN resolved →` and downloads the verified master.
5. Record the finding where it survives the session: a `<host>.md` entry in the plugin's
   `${CLAUDE_PLUGIN_ROOT}/registry/` (portable — see that directory's README for the format),
   and/or a `project_<name>_resolver.md` memory + one-line `MEMORY.md` pointer on this machine.
   Record the trap you found, the exact winning URL form, and the enumeration surface. Add the
   host to `CDN_TABLE.md` under the lever family it belongs to.

## Fast host→trick lookup

`CDN_TABLE.md` in this skill dir is the one-line-per-CDN index (host signature → lever → memory
file). Read it when a host looks familiar but you don't recall the exact knob. It mirrors
MEMORY.md but organized by *what you do*, not by *when you learned it*.
