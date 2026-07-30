# product-images.therealreal.com — Fastly Image Optimizer with upscaling ON

- **Signature:** `product-images.therealreal.com/<STYLE>_<n>_enlarged.jpg`; an S3 bucket fronted by
  **Fastly IO** (`via: varnish`, `vary: Accept`, imgix-style `?auto=webp&width=N&dpr=N`).
- **Engine:** rule is "strip all params" — the same as generic bare-stripping, but the *reason*
  matters.

## Lever

**The bare URL with no query params.** Fastly passes through the raw S3 object directly
(`server: AmazonS3`, real `etag` / `x-amz-version-id`). For the verified style that is **1500×1980**,
~89–214 KB per image.

## Trap — the upscale mirage

**Fastly IO has upscaling enabled here.** `?width=10000` returns a **7130×9411 / 933 KB JPEG** that
looks like a high-res master and is a pure Lanczos upscale of the 1500px source.

**Proof:** a local Lanczos upscale of the bare image versus the CDN's `width=4000` output measured
**PSNR 54 dB** — i.e. identical, no real added detail.

The output saturates at a fixed **7130×9411 ceiling**, which *mimics a genuine source-dimension
clamp* but is only Fastly's upscale cap. **Do not mistake a saturation ceiling for a master.** The
way to tell them apart is to check the saturation point against what the source actually is
(`?fm=json`-style metadata, or the bare object's real dimensions) — a clamp lands on the source
dimensions, an upscale cap lands on an arbitrary round number.

The page's own `?auto=webp&width=1920` variants are strictly worse: upscaled past 1500 **and**
lossy-transcoded to webp.

## Dead ends (with disproving evidence)

**No larger variant exists.** Sibling object names `_original`, `_master`, `_large`, `_zoom`,
`_full`, `_1.jpg` (no suffix), `.png`, `.tif` all return **S3 403** (they don't exist).
`_enlarged.jpg` is the only stored object and **is** the upload ceiling.

Related: [[imgix]] (StockX — the opposite lesson, where a hidden root subdomain *does* hold a bigger
source), [[secondname-agency]] (the same upscale trap in a portfolio CMS).
