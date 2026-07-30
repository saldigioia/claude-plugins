# lookaside.fbsbx.com — Meta on-demand media transcoder

- **Signature:**
  `lookaside.fbsbx.com/elementpath/media/?media_id=<id>&version=<v>&transcode_extension=<ext>`
- **Engine:** `fbsbx_png_url()` + `stage_fbsbx_media` (the **first** stage in `process_url`).

## Lever

**Rewrite `transcode_extension=*` → `png`.** That is the lossless master at native resolution.

Verified format ladder:

| ext | result |
|---|---|
| **`png`** | **lossless master at native res** — served as `application/octet-stream`, no path extension |
| `webp` | lossy, ~75 dB vs png (visually identical, ¼–⅓ the bytes) — what the page requests |
| `jpg` | **~30 dB aggressive recompress — a TRAP, never use.** A fresh low-quality re-encode, not the source |
| `tif` / unknown | silently falls back to webp |

The endpoint is **fully public** — no cookie, UA, or Referer needed.

## Trap

- **`width` / `w` / `dpr` are silently ignored**, so the stored resolution is a hard ceiling
  (observed 1808×976 up to 2880×1800). Don't chase a bigger rendition.
- A bare `media_id` with no `version` → 404. A bare `media_id`+`version` with no
  `transcode_extension` → SVG icons/glyphs, not the photo.
- The PNG comes back as `application/octet-stream` with **no extension in the path**, so a
  content-type-driven pipeline cannot classify it — and a transcode detector would wrongly demote it
  as bloat (same dims, better format). This is why it needs a dedicated pre-pipeline intercept
  rather than a resolver.
- Match **only** URLs that already carry `transcode_extension`, so SVG icon requests fall through
  untouched.

Stem downloads as `fbsbx_<media_id>`.
