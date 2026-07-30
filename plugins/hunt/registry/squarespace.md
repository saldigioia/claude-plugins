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

Related: [[wordpress-photon-pmc]] (shared Accept lever), [[foliolink]] (photographer portfolios
that migrated onto Squarespace).
