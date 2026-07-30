# Substack (substackcdn.com + substack-post-media S3)

- **Signature:** `substackcdn.com/image/fetch/<transform>/<url-encoded-origin>` — a Cloudinary
  fetch proxy in front of a public S3 bucket. Covers **every** Substack publication.
- **Engine:** `cdn_resolve_substack` (peels the transform, url-decodes the origin).

## Lever

**Strip the proxy.** URL-decode the embedded origin to reach the bare object on the
world-readable bucket:

```
substack-post-media.s3.amazonaws.com/public/images/<key>
```

No auth, unsigned, un-watermarked — the signed `$s_!…!` token lives only on the proxy. **That S3
object IS the master**: its byte size equals the post metadata's `bytes` field, and
`srcNoWatermark` / `fullscreen` / `resizeWidth` are all null (no higher tier exists).

Peeling detail: the transform segment contains no slash while the encoded origin's slashes are
`%2F`, so `${after#*/}` cleanly separates them.

## Trap

- **The "false TIF presentation."** The proxy transform carries a signed token + `f_auto` (serves
  webp/jpeg, *never* the source format) + `w_<N>,c_limit` + `q_auto`. So the page paints a small
  lossy derivative **even when the origin URL ends `.tif` and the post metadata says
  `image/tiff`.** Measured: a 1456×2151 CMYK master painted as a 0.40 MB JPEG — **~62× smaller**
  than the 24.6 MB origin.
- **Master dimensions live in the S3 key's `_WxH` suffix, NOT in the page's `data-attrs`
  width/height** — those are the ~1456px on-page render size. Reading data-attrs under-reports
  masters by up to ~3.6× (a 3552×5327 master shown as 1456).
- **The S3 key is opaque — never rewrite it.** Bare `<uuid>.<ext>` and `<uuid>_WxH.<ext>` are
  **distinct uploads**; `_WxH` is a native size, not a derivative, and stripping it 403s.
- Heft ≠ resolution: CMYK uncompressed TIFF scans run 5–25 MB at only ~1456–2231px long edge.
  That is uncompressed-CMYK cost. Download byte-for-byte; do **not** convert CMYK→RGB.
- The false-TIF trap is **per-upload, not per-publication** — one publication had 23 posts of
  which only two carried TIF masters. Check each.

## Enumeration surface

Public, auth-free:

- **Post:** `https://<host>/api/v1/posts/<slug>` → `body_html` embeds per-image `data-attrs` JSON
  (src / width / height / bytes / type). Paywalled posts truncate `body_html` — pass cookies.
- **Catalog:** `https://<host>/api/v1/archive?sort=new&offset=N&limit=50`.

## Dead ends (with disproving evidence)

- **The S3 bucket is not a discovery surface.** `substack-post-media` is ONE flat UUID-keyed
  bucket shared by *all* of Substack — no per-publication prefix or folder, `ListBucket` returns
  `AccessDenied` on every variant, and keys are unguessable. Enumerate via the archive API instead.

## Downstream re-hosts

Some WordPress publications re-host Substack uploads and serve a degraded copy. See
[[playboy]] for the worked case: the WP file inherits the `<uuid>_WxH` name but decodes to a
~1456px lossy webp, and the same key on the Substack bucket is 2.4× the linear resolution.

Related: [[cloudinary]] (substackcdn is Cloudinary fetch mode), [[sanity]] (same
bare-vs-re-encode discipline).
