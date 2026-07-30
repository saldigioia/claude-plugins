# image.goat.com — GOAT product imagery

- **Signature:** `image.goat.com` (CloudFront + Envoy origin), Active-Storage/Paperclip layout.
- **Engine:** `cdn_resolve_goat` + a generic cold-cache HEAD fix in `head_info`.

## URL grammar

```
image.goat.com/[<named-prefix>/][<width-prefix>/]attachments/<root>/images/<id>/<sub-size>/<file>
```

- `<named-prefix>` — themed overlay slug (e.g. a dated promo), or absent
- `<width-prefix>` — numeric clamp (`375`, `750`, `1000`, …); clamps to source, no upscaling
- `<root>` — `product_template_pictures` (hero, square `.png.png`) or
  `product_template_additional_pictures` (gallery, `.jpg.jpeg`)
- `<sub-size>` — `original` (largest) · `large` (~1100w) · `medium` (~750w) · `grid` (~340w)
- `<file>` — Paperclip double extension = `uploaded-name.detected-format`

## Lever

Strip, in order: `/transform/v1/`, any `<named-prefix>/<width-prefix>` slot, and any
`grid|medium|large` sub-size folder (promote to `original`). **Drop the query string entirely** —
the only useful query, `action=crop`, is the lossy crop you are trying to avoid.

The bare `image.goat.com/attachments/.../original/<file>` URL serves the unmodified source.

## Trap

- **The `/transform/v1/<path>?action=crop&width=N` endpoint the GOAT site itself embeds serves a
  lossy crop at a *different aspect ratio*, capped below source.** One asset with a true 3000×2000
  source returned 2764×1865 even at `width=10000`. The site's own URLs never reveal the real
  source dimensions — only the bare path does.
- **Cold-cache HEAD lie.** The *first* HEAD to an asset on a given POP returns
  `HTTP/2 404, Content-Type: image/png, Content-Length: 118` — a fake 404 PNG — while a GET on the
  same URL returns the real image *and* warms the edge so later HEADs correctly return 200.
  `etag` and `last-modified` are stable across the divergence; only the HEAD body differs by edge
  cache state.
  **Generic fix:** on `status =~ ^4` AND `0 < Content-Length ≤ 1024`, retry with GET and only
  override the HEAD signal when the GET returns 2xx. A genuine 404 with a small body then stays
  recorded as a failure. This is not GOAT-specific — any CDN with that fingerprint benefits.
- Transform params (`w_5000`, `f_png`, …) on the transform endpoint are silently ignored / 404.
- Source dimensions vary per asset (2000×1333 and 3000×2000 both observed) — there is no single
  ceiling to assume.

## Comparison with StockX (same product, lossless mode)

| | GOAT | StockX |
|---|---|---|
| Hero | 1000×1000 PNG / 181 KB, **transparent background** | 1600×1141 PNG / 1.48 MB |
| Gallery shot | 2000×1333 JPG / 115–310 KB | 2000×1500 PNG / ~1.7 MB |
| Frames | 8 angles | 36-frame turntable |
| Total | 1.7 MB / 9 frames | 52 MB / 37 frames |

For resolution and angular coverage StockX wins; for a background-isolated hero **with an alpha
channel** GOAT is the only source. Pick by what you need, not by file size.

## Enumeration surface

The grammar above was reverse-engineered from a HAR of a product page: `__NEXT_DATA__` exposed
`pictureUrl`, `mainPictureUrl`, `gridPictureUrl`, `mainGlowPictureUrl`, which is what revealed the
prefix variants and sub-size folder names. **Generalisable method** — when a CDN looks closed,
capture a HAR of the consuming web app and grep response bodies for image-URL patterns rather than
guessing path segments.

Related: [[imgix]] (StockX), [[waf-and-bot-walls]].
