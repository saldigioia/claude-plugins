# cdn.sanity.io — Sanity CMS (all tenants)

- **Signature:** `cdn.sanity.io/images/<project>/<dataset>/<sha1>-WxH.<ext>`, sometimes proxied
  through `<tenant>.imgix.net` with the same `/images/` path.
- **Engine:** `cdn_resolve_sanity` strips to bare — correct for *optimised-upload* datasets,
  **under-serves hi-quality-source datasets**. Read the quality rule below before trusting it.

## Lever

**Master quality is SOURCE-DEPENDENT. Do not assume bare = master.** Decide per dataset:

```
compare  bare GET Content-Length   vs   ?fm=json  source Content-Length
bare == source   → bare IS the byte-exact upload (optimised dataset)
bare <  source   → bare is a lossy re-encode; the master is ?q=100
```

- **Optimised uploads** (stored at delivery quality) → bare is byte-exact. `?fm=png` / `?fm=tif`
  are lossless-wrapper bloat traps; `?q=100` only forces a needless larger re-encode.
- **Hi-quality photographic masters** → bare is a **3–7× lossy reduction**. `?q=100` at native
  res is the ceiling. `q≥101` → HTTP 400; 100 is the hard max.

## Trap

- **8192px hard long-edge delivery cap** on both `cdn.sanity.io` and imgix proxies. Sources above
  it are downscaled and the true original is **not publicly retrievable** — `?q=100` gives the
  best obtainable 8192 rendition. Say so rather than implying you got the master.
- `?dl` only sets `Content-Disposition`; the image is still processed. Only the authenticated
  Asset API returns the byte-exact upload.
- `?fm=png` on a JPEG source is a bloat re-encode. The engine's transcode guard (same-dims
  demotion) already handles this on `cdn.sanity.io`.

## Enumeration surface

Open, unauthenticated **GROQ Query API** — GET, url-encoded (POST gives a content-type error):

```
https://<project>.apicdn.sanity.io/v2021-10-21/data/query/<dataset>?query=<GROQ>
*[_type=="sanity.imageAsset" && !(_id in path("drafts.**"))]{url,originalFilename,metadata}
```

- **Exclude drafts** — apicdn returns draft copies and you get duplicate docs.
- **Sort client-side** — `order()` on nested `metadata.dimensions.*` is unreliable on apicdn.
- Asset `_ref` `image-<hash>-WxH-<ext>` maps directly to the delivery URL; no join needed if you
  only want URLs.

## Known datasets

| Site | Project | Quality rule | Notes |
|---|---|---|---|
| SKIMS marketing | `hfqi0zm0` | **bare = master** (optimised) | 21k+ imageAssets; see [[skims-shopify]] |
| phenomena.photos | `sa28ntyf` | **`?q=100`** (bare 3–7× lossy) | 1,345 assets, ~130 named project collections, 84 over-cap |
| panda-windows.com | `bqalfhqj` | **`?q=100`** (bare 2.46 vs 7.22 MB source) | 1,438 images + 267 brochure PDFs; page behind Vercel checkpoint |
| beyonce.com | `fvrrd1kn` | **`?q=100`** (bare ~54% of source) | **PRIVATE dataset** — see below |

## Dead ends (with disproving evidence)

- **beyonce.com GROQ is closed.** The tell is subtle: an anonymous query returns **HTTP 200 with
  `result: []`**, *not* 401, and a known asset `_id` lookup returns `null`. That 200-but-empty is
  the signature of a private dataset with no anonymous read grant. `/projects/<id>/datasets` → 401.
  `curl_cffi` does not help — it is an ACL, not a TLS/network gate.
  **Route around it via the Next.js RSC payload:** the server-rendered homepage HTML carries the
  full resolved document tree. Unescape `\/`→`/`, then regex `"size":(\d+),"url":"(cdn\.sanity\.io/...)"`.
  The `size` field equals the true source byte count (verified against `?fm=json`). One homepage
  referenced 752 distinct images / 4.69 GB — a HAR capture massively undercounts because the
  browser lazy-loads ~43 at a time.
- Sanity API tokens are server-side and never appear in a HAR or the browser. Drafts and
  byte-exact Asset-API originals are unreachable anonymously.

Related: [[imgix]] (same bare-vs-q100 discipline on a different resizer), [[brandfolder]]
(secondary DAM on panda-windows).
