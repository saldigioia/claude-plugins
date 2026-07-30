# assets.yesstud.io — yesstud.io portfolio platform

- **Signature:** `assets.yesstud.io/<tenant>/…`, used by client portfolio sites.
- **Status:** manual (not wired into the engine) — the rule needs a measurement, not a string
  transform.

## It is a raw versioned S3 bucket behind Cloudflare, NOT a transform CDN

Query params on `/image/` are **silently ignored** (byte-identical output). S3 headers
(`x-amz-meta-width/height`, `x-amz-version-id`) are present; `ListBucket` is `AccessDenied`.

## Lever — fetch both, measure, keep the larger

Two rendition families per asset id:

```
assets.yesstud.io/<tenant>/image/<tenant>_<id>.jpg                        ← stored master
assets.yesstud.io/<tenant>/cache/<tenant>-<id>-h1440-q95-rz3-b75.jpg      ← q95, capped 1440px tall
```

- `/image/` is the **full original for most assets** (seen up to 3848×2500 and 4000×1739, 3–10 MB).
- For a **minority** it is a small 1080×1350 Instagram-style export — and then the `h1440` cache key
  (≥1152×1440) is the *less* downscaled view and wins.

So: **fetch both, decode the pixel dimensions, keep the larger.** There is no way to know which
case you are in from the URL alone.

Other baked cache keys: `-h1000-q95-rz3-b75`, `-h800-…`, `-w250-h250-sm1-q95-f0` (thumb), and on
some folios a width ladder `-b75-q80-rz3-sm0-w{480..3840}`.

## Trap

- **The resizer serves ONLY pre-baked keys.** Arbitrary sizes (`w3840`, `h2000`, `q100`, …) return
  **403** — it is not on-demand. The public site 404s on cache paths, and the management host is
  unreachable.
- **Asset ids are sequential with gaps.** Gap ids (deleted or unpublished) 403 on every path — a
  403 there is absence, not a locked door.

## Enumeration surface

Manifest with ids, dimensions, and cache URLs at `https://<site>/api/folios/<slug>`.

Related: [[secondname-agency]], [[cims-camart]] (another DAM where the public tier is not the
master).
