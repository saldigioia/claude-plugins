# CDN / CMS master-recovery lookup

One line per host. **Signature** = how to recognize it (in a URL or HAR). **Lever** = the exact
move that yields the master. **Trap** = the failure to avoid. **Mem** = backing memory file.
All of these are already wired into `${CLAUDE_PLUGIN_ROOT}/tools/cdn/app.sh` unless marked
*(manual)*. Grouped by the lever family from SKILL.md's algorithm so you pick by *what you do*,
not by host name.

**Mem** names a `project_*` auto-memory file. Those are per-machine and do **not** travel with
the plugin — the portable equivalent is `${CLAUDE_PLUGIN_ROOT}/registry/<host>.md`. A missing
memory file is not a missing lever: the lever is in this table and, for anything unmarked, in the
engine.

## 1. Proxy wraps an origin URL → decode & peel

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| `…/_next/image?url=` (Next.js) | url-decode `url=` param → origin | — | — |
| `…/.netlify/images?url=` | url-decode → origin | — | — |
| `i0-2.wp.com/<origin>` (Jetpack Photon) | strip Photon host → `https://<origin>` | webp transcode → also send non-webp Accept | project_pmc_photon_resolver |
| `substackcdn.com/image/fetch/<xf>/<enc>` | peel 1 transform segment, url-decode origin → bare S3 | "false TIF": signed `$s_!` + `f_auto` + `w_` + `q_auto` paints tiny lossy webp even when origin is `.tif` | project_substack_resolver |
| `image-cdn.hypb.st/<enc>` | url-decode → bare `s3.store.hypebeast.com/media/image/…` | editorial flow caps 1200px (no S3); HEAD CL=0 (Lambda) | project_hypebeast_image_cdn |
| `/cdn-cgi/image/<opts>/<origin>` (CF Images) | strip opts → origin | — | — |
| Thumbor `/unsafe/<origin>` | strip `/unsafe/` → origin | — | — |
| `i.discogs.com/<sig>/rs:fit/…/<b64url>.jpeg` (signed imgproxy) | decode b64url payload → `s3://discogs-database-images/<R\|A\|L\|M>-<id>-…` → unauth API `api.discogs.com/{releases,artists,labels,masters}/<id>` → matching `images[].uri` = full-size signed URL | sig covers whole path (tamper/`unsafe`/ext-swap → 403, can't forge); S3 private; 600px stored cap = ceiling; UA header required ~25 req/min; CF Polish on top (cfbust recovers origin bytes) | project_discogs_resolver |

## 2. Origin sits on a public bucket → go direct

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| `<tenant>.com/media-library/<f>.<ext>?id=N` (RebelMouse) | → `assets.rbl.ms/<N>/origin.<ext>` | proxy `?quality=100` is a 3× bloat re-encode (same pixels) | project_rebelmouse_resolver |
| Substack images | `substack-post-media.s3…/public/images/<key>` (unsigned, IS master, bytes==metadata) | `_WxH` suffix is native size — stripping 403s | project_substack_resolver |
| Playboy.com editorial `/wp-content/uploads/<uuid>_WxH…webp` | reconstruct key → Substack S3 `.jpeg` (2.4× res) | on-site "full" file is downscaled to 1456px; name `_3552x5327` is inherited | project_playboy_resolver |
| END Clothing `media.endclothing.com` | Cloudinary CNAME, delivery-only; bare = source ceiling (transforms 404) | — | project_endclothing_cloudinary |
| CiMS/Camart `cims-*-public` S3 | `_PREVIEW` public ceiling; `_download` master is ACL-403 | filename in `_PREVIEW` Content-Disposition | project_cims_camart_resolver |

## 3. Strip ALL params → bare = master

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| PMC/Photon: rollingstone, variety, wwd, indiewire, sheknows `/wp-content/uploads/` | strip params + non-webp Accept → full-EXIF jpeg | ANY param re-invokes Photon (smaller) | project_pmc_photon_resolver |
| PMC editorial (Photon i0.wp) | bare upload URL, non-webp Accept | — | project_pmc_photon_resolver |
| StockX `images.stockx.com`, `stockx-assets.imgix.net` | → `stockx.imgix.net` bare (byte-exact source) | `images.stockx.com?dpr=4` was a lossy upscale | project_stockx_resolver |
| SKIMS `skims.imgix.net`, `skims-sanity.imgix.net`, `cdn.sanity.io` | strip all params → bare == source | uploads are lossy JPEGs named `.webp`; `fm=png`/`fm=tif` are bloat/wrapper traps; `w=` upscales | project_skims_resolver |
| TheRealReal `product-images.therealreal.com` | bare (no params) = true S3 source | Fastly IO **upscales** — width>source = fake detail, 7130px ceiling is a mirage (PSNR 54 dB) | project_therealreal_resolver |
| Grailed `…media-assets…` | bare = master (ignores params, no cap) | — | project_reseller_image_resolvers |
| Sanity (general, hi-q datasets e.g. phenomena `sa28ntyf`) | `?q=100` (bare is 3–7× LOSSY here) | decide bare-vs-q100 by comparing bare-GET to `fm=json`; q≥101 → HTTP 400; 8192px hard cap | project_sanity_cms_general, project_phenomena_resolver |
| BDG editorial `imgix.bustle.com` (Nylon/Bustle/Inverse/Mic/W/Romper/Elite Daily…) | strip params + `?q=100` (bare is LOSSY q75 here) | CUSTOM domain, NOT `*.imgix.net` (generic imgix resolver misses it); bare 1.87MB vs q100 6.81MB same dims; 8192px cap (over-cap origin private); EXIF stripped on delivery; `fm=png/tif`=wrapper trap (transcode guard demotes). Enumerate via `graph.bustle.com` GraphQL persisted queries + article-HTML CMS payload | project_bdg_imgix_bustle_resolver |

## 4. Oversize / max-quality that clamps to source

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| mzstatic (`is{N}-ssl.mzstatic.com/image/thumb/…`) | rewrite spec → `10000x10000.png` (clamps, lossless) | legacy `a{N}.mzstatic…/source` is hard-403, unrecoverable; feed named/thumb form. basename strips synthetic spec | project_mzstatic_resolver |
| Apple Music / iTunes page (`music.apple.com`, `itunes…`) | read `og:image` → falls into mzstatic resolver | album→3000² cover, artist→5998² photo; beats Lookup API (no artist art) | project_mzstatic_resolver |
| StockX imgix root | `?dpr=N` (N≥3 saturates upload ceiling) | on `images.stockx.com` `w/q/fm` are config-disabled | project_stockx_resolver |

## 5. Named-policy / origin-forcing knobs

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| NBC `img.nbc.com` (Akamai IM) | `?impolicy=original` | `?imformat=png` is silently ignored (still serves JPEG) | project_nbc_resolver |
| FWRD `is[1-8].fwrdassets.com/images/p/fw/{p\|uv\|z}/` | normalize to `/z/` + `?impolicy=original` (2.2–2.9×) | `/z/` is largest tier; no `/orig/` path | project_fwrd_resolver |
| Revolve `is[1-8].revolveassets.com/images/p4/n/{…}/` | normalize any folder → `/z/` + `?impolicy=original` | per-color SKU suffix: `YEER-UO4W_V1` vs `YEER-UO4_V1` are different sets | project_revolve_resolver |
| Any Cloudflare host w/ `cf-polished: ok, orig_size=N` on HIT | append unique `?cfbust=<rand>` → MISS serves un-recompressed origin (verified 8.4×) | use fresh bust id per phase to dodge BGJ rewrite race | project_cloudflare_polish_bypass |

## 6. Non-webp Accept header

| Host / signature | Lever | Mem |
|---|---|---|
| Squarespace (`images.squarespace-cdn.com` / `format=…`) | inject `Accept: image/avif,png,jpeg,tiff,bmp` (no webp) | project_squarespace_resolver |
| Jetpack Photon (PMC + any i0.wp.com) | same no-webp Accept (via `wants_original_accept`) | project_pmc_photon_resolver |

## 7. Format / extension ladder (mind the wrapper traps)

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| Cloudinary (`res.cloudinary.com` + any `/image/upload/` CNAME) | strip transform → bare public-id URL. **Verify with `…/image/upload/fl_getinfo/<pubid>`** (`input.bytes`=true source): if a bare HEAD == `input.bytes`, bare IS the byte-exact master — use it. | **`.png` on a JPEG-origin asset is a bloat trap** (lossless re-wrap, ~5× bytes, 0 fidelity, wins format ladder); **skip `.tif`** — `f_tiff` is JPEG-in-TIFF < `f_png`. Both now handled by `cloudinary_bare_master` in app.sh | project_cloudinary_resolver |
| Format / format.com portfolio (cloud `allyou`, `themes/structures`, `fullscreen_gallery`, `/ajax/<id>/<slug>`) | images are Cloudinary (above); enumerate: nav `<a href="/<gid>/<name>">` + per-gallery `https://<site>/<gid>?start_index=0&limit=500` → public-id `v1/<n>/<siteid>/images/<imgid>/<stem>` | — | project_cloudinary_resolver |
| fbsbx `lookaside.fbsbx.com/elementpath/media/?…transcode_extension=` | rewrite `→png` (lossless master), download direct (pre-pipeline) | `jpg`=~30 dB re-encode trap; `webp`=lossy default; width/dpr ignored (stored res is ceiling); only match when `transcode_extension` present | project_fbsbx_resolver |

## 8. Sub-size folder / prefix / crop-segment promotion

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| GOAT `image.goat.com` | strip `/transform/v1/`, width prefix `/<N>/`, named prefix, `/grid\|medium\|large/`→`/original/` | cold-POP HEAD lies `404 png CL=118` → retry GET; some assets 3000×2000 vs 2000×1333 served | project_goat_resolver, project_goat_head_trap |
| Second Name `secondname.agency` `/media/c/i/<base>.<hash>.jpg` | strip `/c/` + hash → `/media/i/<base>.jpg` | SPA feed at `/newsquickview/<id>/`; `sld` large is often an upscale | project_secondname_resolver |
| yesstud `assets.yesstud.io` *(manual)* | fetch BOTH `/image/<id>.jpg` and `/cache/<id>-h1440-…jpg`, keep larger-pixel | raw S3 cache (not transform); arbitrary resizer params 403; manifest `/api/folios/<slug>` | project_yesstud_resolver |
| Hearst hdnux `s.hdnux.com/photos/<aa>/<bb>/<cc>/<dd>/<id>/<ver>/<rendition>` (SFGate, Chronicle, statesman.com) | swap rendition → fixed name `rawImage.jpg` (5.2× page webp, CMS-native dims) | params ignored; unknown renditions 302→v3 (no ladder above raw); EXIF-stripped + ~2048px ingest cap = ceiling; enumerate via `__NEXT_DATA__` zoneSets body images | project_hdnux_resolver |
| Future PLC `cdn.mos.cms.futurecdn.net/<id>-<w>-<q>.<ext>[.webp]` and `/v2/t:,l:,cw:,ch:,q:,w:/<id>.<ext>` (TechRadar, Tom's Guide, PC Gamer, Who What Wear, Marie Claire, Space.com…) | strip to bare `<id>.<ext>` — drop `/v2/<xf>/`, `.webp`, `-<w>-<q>`, params (unsigned; 22×–261× bytes, `/v2` also un-crops) | `-99999-100` = 2.8× bloat re-encode at PSNR 55.6 dB (NOT an upgrade); `/v2` CROPS not just resizes; ext locked to stored format (`.tif`/`.jpg` swaps 404) so no format ladder; params ignored byte-for-byte | project_futurecdn_resolver |

## 9. Path-suffix strip to unscaled original

| Host / signature | Lever | Trap / note | Mem |
|---|---|---|---|
| Etsy `i.etsystatic.com` | `il_fullxfull` = unscaled original (3000² vs page-max il_1588xN) | listing page 403s plain curl — use curl_cffi chrome (image CDN serves plain curl) | project_etsy_resolver |
| eBay `…s-l<N>…` | `s-l1600` master | needs `--impersonate safari17_0` | project_reseller_image_resolvers |
| Depop | `P0` (1280px; bucket `b0`/`b1` varies) | — | project_reseller_image_resolvers |
| Fril | `/l/` = 1080 | — | project_reseller_image_resolvers |
| Imgur `i.imgur.com` | `…b.jpg`→bare; Flickr `_b`→`_o`; WP `-WxH`→bare | verify — some suffixes are native size | (app.sh) |
| Reddit `preview.redd.it/[<slug>-v0-]<id>.<ext>?…&s=<sig>` | HOST-swap media id → `i.redd.it/<id>.<ext>` (public, EXIF-stripped ceiling); whole post → `stage_reddit_post` (per-post RSS + embed.reddit.com; content pages IP-gated, curl_cffi useless) | sig covers params — stripping 403s; `external-preview.redd.it` unresolvable from URL (origin in post JSON); `award_images/` = chrome | project_reddit_resolver |

## 10. TLS / WAF bypass (orthogonal — combine with any lever above)

| Trigger | Lever | Mem |
|---|---|---|
| `cf-mitigated: challenge` / Turnstile | `curl_cffi --impersonate firefox` (app.sh auto-retries) | (app.sh) |
| HBX / brand PDP behind AWS WAF | recover SKU + manifests via Wayback CDX `archive.org/cdx/search/cdx?url=<host>/...` | project_hypebeast_image_cdn |
| Etsy/eBay listing pages | curl_cffi chrome / safari17_0 | project_etsy_resolver, project_reseller_image_resolvers |
| Reddit "blocked" wall (www/old/api, ~190 KB HTML 403) | NOT fingerprint-based — curl_cffi does NOT help; route around it: per-post RSS `/comments/<id>/.rss`, `embed.reddit.com`, `i.redd.it` all open to plain curl | project_reddit_resolver |

## Non-image / adjacent

| Target | Lever | Mem |
|---|---|---|
| Arc XP (tampabay, WaPo-CMS) | width≥source on `/resizer/v2` = byte-exact (signs PATH only); or CloudFront `cloudfront-…images.arcpublishing.com/<org>/<ID>.JPG` raw S3; galleries via `Fusion.globalContent` | project_arc_xp_resolver |
| Vimeo (direct/embed) | `app.sh --vimeo`; embed-only → `?h=<hash>` from iframe | project_vimeo_embed_hash, project_vimeo_merge |
| Squarespace native video (`video.squarespace-cdn.com`) | player block = escaped JSON `{variant}` template only (no iframe/src); rebuild `…/content/v1/<lib>/<asset>/playlist.m3u8` (public, unsigned) → yt-dlp; top HLS rung (`<W>:<H>` names, 1080p) = ceiling, no source/progressive variant (404) | project_squarespace_native_video |
| ASA DAM (cosmictalents etc.) | public ceiling is 720p proxy `944_720_<id>.mp4`; real master = artist's own Vimeo (match duration+date+AR) | project_asa_asadts_resolver |
| Pugpig (Vogue/GQ/VF PDF editions) | sibling per-page `.pdf` holds 300dpi print master; manifest `editionfeed/<id>/pugpig_atom_contents.json` | project_pugpig_pdfpages |
| TheMaven / Arena image CDN | see memory | project_themaven_image_resolver |
