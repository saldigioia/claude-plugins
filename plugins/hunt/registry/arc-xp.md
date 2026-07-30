# Arc XP / Arc Publishing (the Washington Post CMS)

- **Detect via:** `/resizer/v2/` image URLs, and the host suffix `arc-perso.aws.arc.pub` in page
  assets. Powers many US newspapers.
- **Engine:** `cdn_resolve_arc_resizer`.

## Lever

Delivery is `/resizer/v2/<ID>.<EXT>?auth=<sig>[&width=N&height=N&smart=true]`, and **the `auth`
HMAC signs only the image path/ID — `width`/`height`/`smart` are free query params.** Three routes
to the master, all verified byte-identical:

1. **CloudFront origin (best):**
   `https://cloudfront-us-east-1.images.arcpublishing.com/<org>/<ID>.<EXT>`
   Raw S3 upload, `server: AmazonS3`, **no auth token, never expires, full EXIF/IPTC intact.**
   `<org>` is the tenant slug.
2. **Resizer with `width` ≥ source** — `?auth=<sig>&width=99999` clamps to source and returns the
   byte-exact origin (md5 matches the CloudFront object).
3. The page's own URL — **which is the trap.**

## Trap

**The resizer default (no dimensions) is what the page actually paints, and it has the SAME pixel
dimensions as the master but is a lossy re-encode** — ~21% smaller, different md5, EXIF stripped.
It looks full-res. It is not the master. This is the canonical "false full-res" shape.

## Enumeration surface

No API key needed. The article HTML embeds `Fusion.globalContent={…}` (brace-match to extract) —
the full ANS story object. Photos live in:

- `content_elements[type=="image"]`, **plus**
- `promo_items.basic` — the lead image is often a **separate photo not present in
  `content_elements`**. Dedupe by `_id`.

Each image element carries true source `width`/`height`, `additional_properties.originalUrl` (the
CloudFront URL), `originalName`, an `auth` token, and IPTC caption/byline.

## Dead ends (with disproving evidence)

**No public photo-center enumeration.** Original filenames
(`<assignment>_<photog>_<NN>_<slug>.JPG`) and the sequential `iptc_job_identifier` ingest counter
prove the photographer shot more frames than were published (one gallery: ~32 ingested, 15
published). Unpublished frames have random base32 IDs, sit in the Arc photo center behind auth, and
are **not guessable and not publicly reachable**.

- PageBuilder `/pf/api/v3/content/fetch/<source>` only resolves the site's pre-registered source
  bundles (clavis / collections / story-feed); unregistered sources → HTTP 500.
- Internal `/arc/content/v4/` → 404.

**So the published set IS the complete public collection** — worth stating explicitly rather than
leaving the impression that more is reachable.

Related: [[hdnux-hearst]], [[sanity]], [[wordpress-photon-pmc]] (the same find-the-real-master
pattern behind a lossy default).
