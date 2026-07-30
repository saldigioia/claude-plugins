# Hypebeast — `image-cdn.hypb.st` (editorial) and `s3.store.hypebeast.com` (HBX shop)

**Two unrelated backends. The editorial ceiling does not generalise to the shop.**

## Editorial — `image-cdn.hypb.st`

Master URL form:

```
https://image-cdn.hypb.st/<url-encoded https://hypebeast.com/image/<YYYY>/<MM>/<slug>.jpg>?q=100&w=1200&fit=max
```

- It is a **Lambda@Edge JPEG transformer fronted by CloudFront**.
- **The backend's source uploads are 1200×800** — hardcoded `[1200, 500]` / `[1200, 520]` arrays in
  the gallery JS bundle. Any `w=` ≥ 1200 saturates and returns byte-identical output. The site's own
  srcset peaks at `?q=90&w=1400` and still receives 1200×800, which confirms the ceiling.
- `q=100` (vs the site's 90) roughly doubles file size with a measurable fidelity gain.
- `fm=png`, `fm=tiff`, `fm=webp`, `dpr=` are **silently ignored** — JPEG only.
- **HEAD returns `Content-Length: 0`** (Lambda). Use GET.
- The redirectors `hypebeast.com/image/…` and `static.hypebeast.com/image/…` both 302 to the proxy
  with `?w=800` — never use them directly.
- **No direct S3 backend is exposed; the Lambda proxy IS the storage authority.** Don't chase width
  ladders.

## HBX shop — `s3.store.hypebeast.com`

Different backend, and **direct S3 access works with no auth, no WAF, and no proxy**:

```
s3.store.hypebeast.com/media/image/{2hex}/{2hex}/{filename}.jpg
```

Verified: `Server: AmazonS3`, 1400×1820 JPEGs with EXIF/TIFF metadata intact, 260–391 KB per view.
The proxy at `?q=100&w=10000` returns the *same* pixel dimensions (so the proxy ceiling equals the
source ceiling here, not a fixed cap) but **strips metadata and re-encodes** — occasionally larger
in bytes, always a generation-loss copy. **Prefer S3.**

Worth wiring: decode any `image-cdn.hypb.st/<url-encoded s3.store.hypebeast.com/media/image/…>` back
to the bare S3 URL. That bypasses the proxy re-encode *and* the HBX-side WAF, because S3 has no WAF.

## Trap / walls

- Live `hbx.com` PDPs sit behind **AWS WAF Captcha** (`gokuProps` token). `curl_cffi`
  impersonation alone (chrome120 / firefox133 / safari17_0) returns the 202 challenge — the TLS
  fingerprint is not enough, the WAF wants a JS-solved cookie token.
- **Recovery path:** Wayback CDX wildcard —
  `web.archive.org/cdx/search/cdx?url=hbx.com/women/brands/<brand>/*` returns archived PDPs with
  full JSON-LD (SKU + S3 image paths) intact. Old snapshots are gold when the live page is locked.

## Dead ends (with disproving evidence)

- Bucket alternative-prefix probes (`media/master/`, `media/original/`, `media/image/raw/`, …) all
  403 — `media/image/{2hex}/{2hex}/` is the canonical source path.
- Pre-2018 gallery URLs on the old Photon/netdna CDN and direct buckets
  (`hypebeast.s3.amazonaws.com`, etc.) are all dead.
- **Wayback never archived the editorial asset bytes — only the HTML.**

Related: [[waf-and-bot-walls]], [[themaven-arena]] (another Lambda image service with `CL: 0` HEAD).
