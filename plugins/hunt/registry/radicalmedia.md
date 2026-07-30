# radicalmedia.com — Groowm CMS + "Vault" DAM (presigned-URL video)

- **Signature:** `x-controller: Groowm\Controllers\Page`, `server: nginx` behind CloudFront; an
  Ikelos player (`data-ikelosuioptions` JSON, `data-plugins="ui"`).

## Lever — the page mints the credentials

Each `/work/<slug>` page **server-side embeds the video's full ABR ladder** directly in the
`<video>`/`<source>` tags as **12-hour STS-presigned SigV4 URLs**. There is no XHR — the tokens are
minted at page render, so:

**Re-fetch the page immediately before downloading.** Credentials are temporary role sessions
(`ASIA…` access key, `X-Amz-Security-Token=IQoJ…`, `X-Amz-Expires=43140`).

Origin bucket key layout: `<bucket>/<assetId>/transcode/<md5>.mp4`.

## Rendition ladder and the download-button trap

Five renditions (`data-group`): `1080p HQ` > `1080p` > `720p HQ` > `720p` > `480p`.

**`1080p HQ` is the public ceiling** (verified: H.264 1920×1080 23.976 fps 8.76 Mbps + AAC 320,
107 MB).

> **Trap:** the in-player "Download video" button (`data-ikelosuioptions.downloads`) hands out only
> **720p HQ**. The `<source>` list carries the higher `1080p HQ`. The obvious affordance is not the
> best asset — read the markup, don't click the button.

## Images

Same pages use the Vault resizer:
`<dist>.cloudfront.net/Vault/Thumb?VaultID=<id>&Mode=<R|D>&ResX=<w>&Quality=&OutputFormat=webp&IsPublic=1`
(Mode `R` = resize, `D` = download-resized — **always** a resize).

## Dead ends

- The origin bucket is **private**: `ListBucket` and unsigned GET both 403. **It is not a discovery
  surface.**
- The true edit master (ProRes / original upload) would live in the same bucket under a
  non-`transcode/` prefix (`<assetId>/source*`) but is **not publicly retrievable** — no signature.

## Enumeration surface

Because the bucket is private, **the work pages are the only surface.** `sitemap.xml` lists ~850
`/work/` slugs; scrape each page for its presigned ladder. Asset ids are per-video integers.

**Scope note:** ~850 videos at ~100 MB each is not something to auto-run. Offer the bulk pull;
don't perform it because you can.
