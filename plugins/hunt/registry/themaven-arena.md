# TheMaven / Arena Group image service — `vault.si.com/.image/`

- **Signature:** `vault.si.com/.image/<base64id>/<name>.jpg` and other Arena Group properties
  (TheStreet, Parade). Response header **`x-mm-im: B`** (Maven-Media-IMage); CloudFront → S3.
- **Status:** manual. **Bare is the ceiling** — there is no lever above it.

## It mimics Cloudinary but is not Cloudinary

The path-transform syntax looks familiar (`.image/ar_16:9,c_fill,w_1536/<id>/<name>.jpg`) but there
is **no matching `res.cloudinary.com/<cloud>`**. It is TheMaven's own AWS-Lambda image service.
Don't route it to the Cloudinary resolver.

## Lever

**The bare URL with no transform segment = the raw stored S3 original = the ceiling.**

- **Query params are silently ignored** — `?w=`, `?quality=`, `?fit=` all return byte-identical
  output. Don't be fooled by a 200 that is the same bytes; transforms live in the **path** segment
  only.
- **Strict-transformation mode:** arbitrary path transforms 404 (`w_1536` alone, `c_scale,w_4000`,
  `c_limit,w_10000`, `f_png`, `fl_attachment` — all 404 with a 9-byte `text/html` body). Only
  pre-registered full transform chains succeed. **No upscale, format, or raw-original lever exists.**
- `q_auto:best` returns a **smaller** re-encode than bare — worse. Bare is the least-compressed.
- **HEAD returns `content-length: 0`** (Lambda) — you must GET to learn the real size. Same
  behaviour as [[hypebeast]].

## Proof that bare is the true per-page original (not a live `w_2048` cap)

Across a 67-page magazine scan, every page was 2048 wide at ~q80, but **heights varied**
(2729 vs 2732 px) and file sizes ranged **156 KB–960 KB**.

A uniform default transform would produce deterministic heights. Independent variation ⇒ each file
is its own ingested original. 2048-wide/q80 is simply the resolution the publisher ingested the
vault at; **no larger version exists on this infrastructure.**

That reasoning — *variance in a dimension that a transform would have fixed* — is a generally useful
way to tell a stored original from a live-generated rendition.

## Dead ends

The base64 id decodes to an 18-digit numeric asset ID with **no resolution encoding in it**, so
there is no lever there. Wayback shares the same S3 origin and is no help.
