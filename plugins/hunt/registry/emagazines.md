# emagazines.com — white-label digital-magazine platform

- **Signature:** `library.emagazines.com/library?plid=<N>` (Blazor Server library) →
  `digital.emagazines.com/<pub>/<YYYYMMDD>/index.html?t=<token>` (Swiper reader) →
  page images on `assets.emagazines.com`.
- Same **vendor** as the Playboy `ipb-reader` flipbook, but a **different product** (that one is
  FlipHTML5; this is the vendor's own Blazor+Swiper reader). See [[playboy]].

## The access model — the token gates only the MANIFEST

**Page images, covers, and per-issue JS are fully public** (`assets.emagazines.com` = S3+CloudFront,
CORS `*`, no cookie or token). Covers are date-addressed at
`cdn.emags.com/digital/<pub>/<YYYYMMDD>/cover.jpg`. Bucket `ListBucket` is 403.

So once you know the image ids, you need no auth at all.

## Two tiers, both public, params IGNORED (bare S3), no PDF/PNG/TIF (all 403)

| tier | how to build it |
|---|---|
| display ~1200px | the `one-page-image` src (a 26-char base32 id) |
| **hires ~2438px (the master)** | **`base32(md5-of-the-page's-thumbnail)`** |

The image is **content-addressed by its own md5**, and the thumbnail is `<same-md5>_thumb.jpg`.
Verified 132/132 pages resolve. So **a thumbnail list reconstructs every hires URL** — get it from
the public per-issue JS (`cdn.emagazines.com/digital/<pub>/<date>/<md5>.js`, exposing
`window.articleMetaData[]` with `{pageNumber, thumbnailUrl, articleId, searchText, searchWords[]}`)
or from the `_thumb` references in the reader HTML.

Still a lossy delivery JPEG (q60 on recent issues, q96 on older, 4:2:0, EXIF-stripped). The true
archival master sits in the publisher's own DAM, not web-exposed.

## Old issues behave differently

Pre-~2010 issues use an older spread reader with **no thumbnails**, so there is no
`base32(md5(thumb))` hires tier. The display id **is** `base32(content-md5)`, and ~1200px **q90 is
the ceiling** — note that is *higher quality* than the modern q60 tier, just lower resolution.
Fall back to the display tier automatically when no thumbs exist.

## Enumeration surface

The catalog is painted by a Blazor **websocket** (`wss /_blazor` SignalR) and then PWA-service-worker
cached, so a live GET of `/library` returns an empty shell — **the DOM must come from a browser
capture.**

**Best surface = the full-archive library viewer** (a different `plid`): it renders **every** issue
into one HTML document, and each card embeds a **durable per-issue token**
(`link.emagazines.com/?cs=library&t=<GUID>`). One capture yielded **614 issues spanning 1973→2026**.

**`cs=library` tokens are durable** — hours-old ones still redeem, unlike the short-lived per-view
tokens minted by `ViewIssue`. Per-publication `plid` cards instead carry a GUID `issueId` +
`s3Url=<pub>/<date>` and no token.

## The reader gate — a CloudFront signed-cookie handshake

This is why a bare `index.html?t=` is 403:

```
GET link.emagazines.com/?cs=library&t=<token>
  → Set-Cookie: CloudFront-{Policy,Signature,Key-Pair-Id}
    (domain .emagazines.com, path /<pub>, policy resource digital.emagazines.com/<pub>/<date>/*, ~5h)
  → 302 to the reader
```

**The token is durable; the cookie is short-lived.** Redeem fresh per session.

## Other endpoints

`/Library/FetchIssueAssets?issueId=` (offline manifest; a bad id gives 400 not 401, so it's
reachable unauthenticated) · `/Library/ViewIssue?issueId=` (302 → token) · `/InThisIssue?id=` (TOC) ·
`api.emagazines.com/Issues/<pub>` **requires a partner key** ("Invalid Partner Key").

White-label: swap the `plid` and the `<pub>` slug for any other publisher on the platform.
