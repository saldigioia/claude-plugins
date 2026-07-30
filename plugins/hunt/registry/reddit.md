# Reddit — `preview.redd.it` / `i.redd.it`

- **Engine:** `stage_reddit_post` (post URL → all image masters), `cdn_resolve_reddit_preview`,
  `reddit_post_id_from_url`.

## Access topology (the load-bearing fact)

Reddit 403-walls scripted clients off **all** content surfaces — `www`, `old`, `api`, `gateway`,
both `.json` and HTML, returning an ~190 KB "blocked" page regardless of UA **and regardless of TLS
impersonation**. `curl_cffi` chrome/safari/firefox are all blocked: this is a **network/IP-level
gate, not Cloudflare-style fingerprinting**. Do not waste time on impersonation here.

Three surfaces stay open to plain curl with a browser UA:

1. **Per-post RSS** — `www.reddit.com/comments/<id>/.rss`. Works id-only. Yields the canonical
   permalink (`r/<sub>/comments/<id>/<slug>`, needed because the embed host 404s id-only paths) and
   the selftext body. **First `<entry>` is the post (`t3_`), the rest are comments (`t1_`) — cut at
   the first `</entry>` or you will harvest comment images.** Listing RSS
   (`/r/<sub>/top/.rss?t=week`) is also open, i.e. a subreddit enumeration surface.
2. **`embed.reddit.com/r/<sub>/comments/<id>/<slug>`** — server-rendered post with **all gallery
   pages in the HTML** (verified 12/12), no comments, and no selftext (hence RSS as a second
   surface). Post JSON is HTML-escaped in `<shreddit-screenview-data>`; its `url` field is the
   outbound target for link posts.
3. **`i.redd.it`** — fully public, HEAD works, `vary: Origin` only (no Accept transcode), EXIF
   stripped at ingest ⇒ **it is the public ceiling.**

## Lever

`preview.redd.it` is a **signed lossy resizer**: the `s=<sig>` param covers the other params, so
stripping them 403s. **Host-swap the media id instead:**

```
preview.redd.it/[<seo-slug>-v0-]<media_id>.<ext>?…  →  i.redd.it/<media_id>.<ext>
```

Basename forms: `<seo-slug>-v0-<media_id>.<ext>` (2023+, id follows the last `-v0-`) or bare
`<media_id>.<ext>` (older posts and selftext inlines).

Even a native-width preview is a lossy re-encode: 1080w = 162 KB vs a 530 KB master of the same
photo; gallery items paint 640w previews over 3000×4000 masters.

## Trap

- **Reject subpath keys** — `award_images/…` is UI chrome with no `i.redd.it` sibling.
- **`external-preview.redd.it` is not resolvable from the URL** — the key is opaque and the origin
  is not derivable. Get the real origin from the post JSON's `url` field instead.
- NSFW embed interstitials can hide gallery items; RSS recovers only the first image in that case.

## Routing

- image / gallery / text posts → direct download in-stage (media-id filenames, magic-byte verified,
  skip-if-present).
- link posts → rewrite `url` to the outbound target and fall through the pipeline so the target's
  own resolver fires.
- `v.redd.it` video → warn and skip (images only).
- share links `/r/<sub>/s/<tok>` → resolve via `%{redirect_url}`; `www` serves redirects even while
  gating content.

Related: [[discogs]] (the same signed-resizer family, re-sourced via API rather than host swap),
[[waf-and-bot-walls]] (why impersonation is the wrong tool here).
