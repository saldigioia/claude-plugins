# CiMS / Camart DAM — `cims-*-public` S3

- **Signature:** `cims-<region>-public.s3.amazonaws.com`; sites on `*.cims.camart.co.uk`.
  Powers print-sales portfolio "showcase" sites for photo agencies.
- **Status:** manual. **The master is ACL-gated — this is a documented dead end, not a lever.**

## Asset model

Each asset is one md5 key with **exactly three sibling objects**:

```
<md5>_THUMBNAIL      public-read
<md5>_PREVIEW        public-read   ← the public ceiling
<md5>_download       PRIVATE ACL   ← the photographer's delivered master
```

## Lever (such as it is)

- **`ListBucket` is public** — `?list-type=2&prefix=<md5>` returns keys **and Size**. That lets you
  read the master's byte size and discover siblings **without downloading anything**.
- **`_PREVIEW` is the public ceiling.** Its `Content-Disposition` header carries the real human
  filename (e.g. `Kendrick Lamar.jpg`) — harvest it for naming.

## Dead end (with disproving evidence)

`_download` (lowercase) is 2.5–3× the PREVIEW bytes, but the **object ACL is private → anonymous
GET returns 403 AccessDenied.** There is no public proxy:

- `<site>/download|asset|image/<md5>` → 404
- `cims.camart.co.uk/image/<md5>` → 401
- no S3 website endpoint
- `?torrent` disabled (405)
- `?response-content-disposition` → 400 (needs a signature)

It is served only through the authenticated CiMS app / license-purchase flow. **Not anonymously
crackable.** Record the size from ListBucket so the loss is quantified, and stop.

## Traps

- **PREVIEW pixel size is per-collection, not a fixed system cap.** Wayback CDX on the bucket shows
  other collections' previews up to 14.5 MB and multi-thousand px, while one deliberately
  small-generated set was ~960×1200. **Do not conclude "960px is the system max" from one
  collection.**
- **The showcase HTML `<img width="1639" height="2048">` is upscaled display markup — a decoy.**
  The real PREVIEW JPEG was 960×1200. Always verify actual decoded pixels, never the markup
  attribute.
- A `/collections/<slug>` URL pattern **looks like Shopify but is not** — it's CiMS. The real
  config is in `window.pageVars` (a `domainList` of `*.cims.camart.co.uk` hosts).
- The fancybox lightbox opens the `_PREVIEW` href verbatim — there is no client-side rewrite to a
  larger image to intercept. `data-paid` refers to paid video, not images.

Related: [[yesstud]], [[dotdash-onecms-thumbor]] (another "public ceiling ≠ master, and the master
is genuinely unreachable" case).
