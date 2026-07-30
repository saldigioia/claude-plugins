# Format / format.com portfolios (legacy "ALLYOU" branding)

- **Signature:** theme paths like `structures/c`, `fullscreen_gallery`, `/ajax/<id>/<slug>`; images
  on **Cloudinary** with public-id shape `<n>/<siteid>/images/<imgid>/<stem>`.
- **Engine:** handled end-to-end by the Cloudinary path — **no new resolver needed** — because these
  accounts do not force optimised delivery, which is exactly the condition
  `cloudinary_bare_master()` detects. See [[cloudinary]].

## Lever — the page URL IS the feed API

No JSON endpoint exists. The infinite-scroll widget uses
`feedURL: document.location.href` with `index_url_param:"start_index"` and `limit_url_param:"limit"`,
so **one request server-renders an entire gallery**:

```
https://<site>/<gallery-id>/<slug>?start_index=0&limit=1000
```

**The bare page is a JS shell with ZERO images — the params are mandatory.**

**Per-image metadata is already in the markup.** Each `<img>` carries a `data-media` JSON blob with
true source `width`/`height` plus a rendition `set[]` whose **last entry has no transform segment —
that bare URL is the master.** Covers add `data-originalsrc` with the real version and true source
extension. **Zero probing needed.**

Master verified byte-exact: bare Content-Length == Cloudinary `fl_getinfo` `input.bytes`, with full
camera/Capture One EXIF surviving.

## Traps

- **Catch-all 200.** `/sitemap.xml` returns the homepage, so **never probe gallery ids** — follow
  real hrefs only. This is the SPA fake-200 trap in a different costume.
- **`.png` = a 1.6–3.3× lossless re-wrap** of a lossy JPEG.
- **`.tif` = JPEG-in-TIFF that is 1.3–3.6× SMALLER than the source yet wins top format priority** —
  the worst version of the wrapper trap, because the usual "bigger" tell is inverted.
- **A category "overview" page is not a master index.** On one indexed site it listed **60 of 264**
  galleries; the rest were reachable only through their own category container. **Seed every
  container or miss most of the site.**
- **Duplicate slugs are not duplicate galleries.** 20 slugs were published under more than one
  gallery id sharing **zero** public ids — independent re-uploads. But two *other* same-slug pairs
  shared zero base stems and were genuinely different shoots. **Never collapse by slug.**
- **Dedupe on the base stem, never the public id.** Cloudinary appends a random 6-char suffix per
  name collision and **stacks it on re-upload** (`_vxhfff` → `_vxhfff_rjmuhb`).

## Structure

Exactly two levels: a handful of category containers → leaf project galleries. The
`page_navigation_wrapper` block holds prev/next/parent links — an **independent sibling-chain
discovery surface** worth using to cross-check container seeding.

To slice feed content from chrome: the feed is discriminated by `id="content_…"` (sidebar nav lacks
it); slice at `<div id="content" class="contentContainer">` and cut at `id="page_navigation_wrapper"`.

## Scale reference

One fully indexed site: **272 galleries, 3,913 distinct masters, 3.86 GiB**, 100% JPEG, max 44.7 MP
(5792×7500) — harvested with 0 failures and 100% byte-exact against probed Content-Length.
