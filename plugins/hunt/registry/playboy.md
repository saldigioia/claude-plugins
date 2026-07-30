# playboy.com — three layers, three different ceilings

- **Engine:** `cdn_resolve_playboy` (runs **before** the generic `cdn_resolve_wp_uploads`).

A worked example of a site where **the same photograph exists at four fidelities across four
systems**, and the filename is a walkable coordinate between them.

## Layer 1 — editorial on `www.playboy.com` (WordPress/WooCommerce, Cloudflare)

Editorial images at `/wp-content/uploads/<YYYY>/<MM>/<uuid>_WxH[-resize][-N].webp` are
**re-hosted Substack uploads** — the same brand publishes on both platforms off the same S3 backend.
`<uuid>_WxH` is the verbatim Substack S3 key, and the leading `WxH` is the **original** upload
resolution.

**The trap:** WordPress (a) re-encodes to lossy webp, (b) emits a `-WxH` srcset ladder, and (c)
**downscales even the "full" file to a ~1456px column copy.** So `_3552x5327.webp` decodes to
1456×2184 — the name is **inherited, not stored pixels.** No lossless sibling exists on-site
(`.jpg`/`.png`/`.tif` all 404). Every on-site rendition is lossy *and* downscaled.

**Master** = the same key on the public Substack bucket:
`substack-post-media.s3.amazonaws.com/public/images/<uuid>_WxH.<ext>` (`.jpeg` ~100% of editorial;
rare `.tif` CMYK scans). Verified 3552×5327 q95 4.7 MB vs the site's 1456px 228 KB webp — **2.4×
linear resolution, ~20× bytes.** See [[substack]].

**Not all imagery is Substack-rehosted.** Photo pictorials
(`Playboy_<Month>_<Photographer>_NNNN.jpg`, `miss-july_feed-*.jpg`) are **native WordPress uploads**
— no uuid, no webp, no S3 origin — and the generic wp_uploads climb reaches the bare `.jpg`
original (verified 8533×12871). A `_PNG_` token in such a name is the photographer's convention,
**not a format hint** — there is no `.png` sibling. Don't assume a playboy.com URL is the uuid path
just because the resolver exists. See [[wordpress-photon-pmc]] for the climb rules.

## Layer 2 — the digital-issue archive (`ipb-reader.playboy.com`, FlipHTML5)

`ipb-reader.playboy.com/<YYYYMMDD>/` is a **FlipHTML5** flipbook; the whole host sits behind
**CloudFront signed cookies**.

- The policy resource is `ipb-reader.playboy.com/*` with `IpAddress 0.0.0.0/0` (**not IP-locked, so
  the cookie is replayable from any IP**) and a ~30-day expiry. **One cookie grants every issue on
  the host.** Send it with `Referer: <issue>/index.html` on a ranged **GET** — HEAD stays 403.
- **Manifest:** `<issue>/javascript/config.js` → `bookConfig{totalPageCount, normalPath, largePath,
  thumbPath}` + `var fliphtml5_pages=[…]`. Pages are sequential `1..totalPageCount`, so the
  **filename is the page number**.
- **Master tier = `files/page/N.jpg`, and it is the only tier that exists.** `files/large/` is
  *declared* in config (`largePageWidth: 3169×4319`) but **does not exist** — FlipHTML5 pointed both
  the `l` and `n` slots at `files/page/`, and `largePageWidth/Height` is just the cover's dims.
- **Size params are ignored** — `?width=5000&quality=100` is byte-identical to bare. These are bare
  S3 objects; there is no size constraint to strip. The habitual "strip the size constraint" move is
  a **no-op** here.
- **Quality caveat:** pages are **q75, YCbCr 4:2:0, EXIF-stripped** — FlipHTML5's standard web
  export, a lossy delivery rendition, not an archival scan. Resolution *is* ~300 dpi (interior
  2460×3251, cover 3169×4319), so it is high-res but recompressed.

**Entitlement flow:** the member archive embeds
`<script src="https://emagsdev.ipb-reader.playboy.com/allaccess?t=<uuid-token>">`; hitting
`allaccess?t=` **sets the CloudFront signed cookies** for the whole host. Token → allaccess →
signed cookie is the entire handshake. The archive offers **no PDF/download tier** by design
(`DownloadButtonVisible: "Hide"`, no `/download` or `/pdf` route).

## Layer 3 — the upstream win: a public DigitalOcean Spaces bucket

Separate from the cookie-gated reader, member pages reference a **public** Spaces bucket
(`pb-cdn-1`, nyc3). `ListBucket` is AccessDenied but **objects are public on the CDN edge — no
cookie, no referer.**

- `iplayboy/issues/<YYYYMMDD>/cover/{extra-small…original}.jpg` — `original` = 3169×4319, **same as
  reader page 1. No gain.**
- `iplayboy/issues/<YYYYMMDD>/two-page/<N>-<N+1>-{small,medium,large}.jpg` — `large` caps at ~700×463,
  a **preview, worse than the reader.**
- **`iplayboy/centerfolds/full/<md5>.jpg` = the foldout at 7134×8995, q81, and it RETAINS
  `Software: Adobe Photoshop CS3` EXIF** (reader pages are EXIF-stripped). **~8× the pixels of the
  reader's centerfold pages**, assembled as one panorama. `full` is the ceiling (JPEG only;
  original/large/xlarge all 403). The per-issue hash is content-addressed md5 and **not derivable** —
  scrape it from the issue page.

## The layer ladder (low → high, all q75 unless noted)

```
0  article WP upload         capped ~2880px long edge
1  reader files/page/NN.jpg  BIGGER (same page measured 2350×3238)
2  Spaces centerfolds/full/  7134×8995 q81 + EXIF   (centerfolds only)
3  internal DAM (TIFF)       NOT publicly resolvable
```

So an article cracks nothing higher than the reader for published pages. Its real value is
(a) proving reader > article, (b) surfacing **outtakes / DAM-only frames with no reader equivalent**
(their ceiling is the bare ~2880 q75 WP file), and (c) acting as a discovery index of which
issue/model/photographer/page exist. Map article → archive: `YYYY_MM` → issue slug `YYYYMM01`,
`pNN` → reader page NN. Caveat: not every digitised issue exposes a centerfold hash.

## Dead ends (with disproving evidence)

- **Reader S3 origin:** bucket is not domain-named (`ipb-reader.playboy.com` → NoSuchBucket). A
  name oracle (NoSuchBucket vs AccessDenied) found two plausible buckets, but **both return
  AccessDenied on GetObject *and* ListBucket for every key/prefix** → private (OAC), no public
  surface. No hidden higher-res object exists: CloudFront would serve any `large/` key under the
  `/*` cookie policy and it 403s.
- **`archive.iplayboy.com` = an Azure App Service literally named "playboyarchive" — currently
  STOPPED** (Azure "Error 403 - This web app is stopped"), zero Wayback history, SCM/Kudu 403. It is
  the best-named DAM lead and it is offline. **Worth re-polling for revival.**
- **`images.playboy.com` is RULED OUT** — it is the old 2015 editorial stack (a Cloudinary fetch
  proxy over a Contentful origin), modern editorial, not the vintage magazine DAM.
- **Bondi DAM scheme fully recovered but 100% offline.** The archive was scanned by Bondi Digital
  Publishing (2007–2010); the original public site is dead (301s away). From a Wayback dump, the
  viewer was **Silverlight Deep Zoom** with an ASP.NET image service keyed by
  publicationId/issueId/pageName/**level**, plus `Thumbnails/<publicationId>/0X<height>/<issueId>.jpg`
  — a **dynamic resize** (0 width × any height), meaning the DAM could emit arbitrary resolutions on
  demand. **None of it survives on current hosts.** The prize (Deep-Zoom tiles + `0X<H>` dynamic
  resize = arbitrary-res masters) sits behind the stopped Azure app.

**Net public ceiling:** reader `files/page/N.jpg` for ordinary pages; `centerfolds/full/<hash>.jpg`
for centerfolds.

Related: [[substack]], [[emagazines]] (same delivery vendor, different reader stack),
[[3dissue]] and [[pugpig]] (other flipbook engines).
