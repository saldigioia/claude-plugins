# Reseller marketplaces — Etsy, Grailed, Depop, eBay, Fril

One pattern across all five: **the image CDN serves plain `curl`, but the listing *page* is
bot-walled.** Fetch HTML with `curl_cffi` impersonation, then download images normally.

## Etsy — `i.etsystatic.com`

- **Path:** `i.etsystatic.com/<shop_id>/r/il/<hash>/<image_id>/il_<SIZE>.<image_id>_<token>.jpg`
- **Ladder:** `il_75x75` · `il_300x300` · `il_794xN` · `il_1080xN` · `il_1140xN` · `il_1588xN` ·
  **`il_fullxfull`**
- **Lever:** rewrite any variant to **`il_fullxfull`** — the unscaled original upload. Verified: a
  page displaying max `il_1588xN` had a **3000×3000** master (~3× larger). No higher tier exists.
- **Wall:** the listing page 403s plain curl/aria2c → `curl_cffi impersonate="chrome"`.
- **Gallery vs recommendations:** the listing's own images cluster sequentially in the carousel
  markup and the first matches `og:image`; "you may also like" recs come later. Dedupe image_ids by
  first doc-order appearance and verify the first equals `og:image`.
- Strip the `?srsltid=…` Google-Shopping tracking param from listing URLs when citing.

## Grailed — `media-assets.grailed.com`

- Static object store. **Ignores imgix params** (`?w`, `?fm`, `?fit`, `?dl` all byte-identical to
  bare). **Bare object = the seller's unaltered upload = master.** No fixed cap — 823px to
  3500×4667 depending on seller.
- **Critical: the path varies and must not be reconstructed.** Draft/recent listings use
  `/prd/listing/temp/<handle>`; published listings use `/prd/listing/<listing_numeric_id>/<handle>`.
  Building a URL from the handle alone yields a 10-byte `Not Found` 404. **Use `photos[].url`
  verbatim** from the page's `__NEXT_DATA__` (walk for a dict carrying `photos[]` + `title`).
- **Wall:** listing page → `curl_cffi impersonate="chrome"`.

## Depop — `media-photos.depop.com`

- **Path:** `media-photos.depop.com/<bucket>/<seller>/<photoid>/P0.jpg`
- **Bucket is `b0` OR `b1`, varies per listing — do not hardcode it; read it from `og:image`.**
- Ladder `P0..P8`; **`P0` is the largest (1280×1280)**, `P1` is 640. Width params ignored.
- The listing's own photos use `P0`; other-product thumbnails use `P1`–`P8` — **filter to P0 only.**
- `webapi.depop.com` returns 403; parse `P0` ids out of the product-page HTML.

## eBay — `i.ebayimg.com`

- **Path:** `i.ebayimg.com/images/g/<hash>/s-l<N>.jpg`
- **`s-l1600` is the master (1600×1600).** `s-l2400` / `s-l9999` clamp to 1600.
- **Wall:** the item page bot-walls chrome impersonation with a 403 "Pardon Our Interruption";
  **`impersonate="safari17_0"` clears it.** This is the reason to keep more than one impersonation
  profile around.
- A page carries 24+ hashes because of cross-sell. Isolate the listing's own gallery by the
  **shared image-batch token suffix** (all real photos in one verified listing ended `…pjgR[NUV]`)
  plus doc-order clustering *before* the Sponsored/Similar sections.

## Fril / Rakuma (Japan) — `img.fril.jp`

- **Path:** `img.fril.jp/img/<internal_item_id>/l/<photoid>.jpg`
- Sizes `/m/` and **`/l/` = largest (1080×1080)**. `/o/` and `/xl/` return 403.
- **`internal_item_id` is NOT the URL hash** — get it and the photo ids from the page
  (`og:image` anchors it). The image host serves plain curl.

Related: [[waf-and-bot-walls]], [[discogs]] (another signed-resizer marketplace).
