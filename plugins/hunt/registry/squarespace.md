# Squarespace — `images.squarespace-cdn.com` / `static1.squarespace.com`

- **Engine:** `cdn_resolve_squarespace` + `Accept`-header injection across `head_info`,
  `http_status`, `verify_magic`, and the aria2c download path.

## Lever

**Format is decided purely by the request's `Accept` header** — not by `?format=` and not by the
URL path.

```
Accept: */*  or anything containing "webp"   →  lossy WebP transcode
Accept: image/avif,image/png,image/jpeg,…    →  the uploaded original
```

Every code path that fetches a Squarespace URL must carry the no-webp Accept. This is the same
lever [[wordpress-photon-pmc]] needs, which is why one shared predicate covers both.

**The failure this prevents:** the probe pipeline finds the JPEG original via Accept negotiation,
but `verify_magic` and the actual download go out with default headers and silently get WebP back
(~60% smaller, lossy). The bug is invisible unless you check the downloaded bytes.

## Trap

- **`?format=raw` returns ~30 KB — a 100w thumbnail. Never use it**, despite the name.
- A bare URL with no `?format=` returns `Content-Length: 1` (a sentinel) on HEAD.
- `?format=NNNw` for any N ≥ the upload max returns the same original.
- **Squarespace ignores Accept q-values** — it returns webp even at `q=0.5`. The header must not
  mention webp at all.
- **The two host families do not share paths.** You cannot blindly convert
  `images.squarespace-cdn.com/content/v1/{site}/{img}/…` ⇄
  `static1.squarespace.com/static/{site}/{page}/{img}/{ts}/…`.
- **Upload cap is 2500px wide** — that is the ceiling for a Squarespace-hosted original, so do not
  hunt for a larger tier.

## Enumeration surface

- `sitemap.xml` — includes `<image:loc>` entries.
- **`<page-url>?format=json-pretty`** — the richer surface. On one verified site the JSON listed
  **609 assets against the sitemap's 582**. Use both and take the union.
- `?format=original` with the no-webp Accept gives the upload; with `Accept: */*` it still returns
  a WebP transcode.

## Native video — `video.squarespace-cdn.com`

- **Engine:** `squarespace_video_urls_from_html` (pure, offline-tested) + a page-scrape tier in
  `stage_video_intercept`, downloading via `download_direct_media`'s manifest path (yt-dlp).

Squarespace's own video hosting renders **no `<video src>`, no iframe, and no manifest URL** in
the served HTML. The player block carries an HTML-escaped JSON config (`data-config-video`)
whose `alexandriaUrl` is a `{variant}` template:

```
https://video.squarespace-cdn.com/content/v1/<libraryId>/<systemDataId>/{variant}
```

so every URL-shaped extractor (Mux/Vimeo/YouTube/direct-media) misses it and the page dies in
the image pipeline (found on marzmiller.com).

**Lever:** rebuild `<base>/playlist.m3u8` from the template base — the master playlist is
**public and unsigned**, and hands out freshly signed variant playlists (`Expires`+`Signature`;
segments are AES-128 encrypted but the `/key/` endpoint is public), so plain yt-dlp takes it
end-to-end. Match the base by host+path shape alone (self-attributing): the `{variant}` template,
the poster `/thumbnail`, and an explicit playlist URL all collapse onto one base.

**Ceiling:** the top HLS rung. Variants are named `<W>:<H>` (`1998:1080` = 1998×1080; the config's
`systemDataVariants` lists the ladder). **No progressive/source/original/download variant exists**
— `mp4-<res>`, `<res>.mp4`, `original`, `source`, `download`, `file.mp4` all 404. Verified ladder
topped at h264 1080p + AAC 48 kHz.

Related: [[wordpress-photon-pmc]] (shared Accept lever), [[foliolink]] (photographer portfolios
that migrated onto Squarespace).
