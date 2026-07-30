# 3D Issue — self-hosted HTML5 flipbook

- **Signature:** flip engine loads from `code.3dissue.com/v9.5/…`, but **every page image is a plain
  static file on the publisher's own domain** — no signed CDN, no opaque ids, no content negotiation.
- **Status:** this is a **whole-collection enumeration** pattern, not a URL-rewrite resolver. There
  is nothing to rewrite.

## Enumeration surface

Issue folder: `https://<host>/digital/<YYYY-MM>/`

Config at `<issue>/files/data/bookinfo.json`, everything nested under `v000`:

| key | meaning |
|---|---|
| `v000.v030.v040` | **page count** |
| `v311` | title |
| `v503` | folder id |
| `v505/optimumDPI` | DPI |
| `v004.level[]` | zoom tile grid |

Pages are numbered `1..N` sequentially, so **the filename IS the page number** — no manifest scrape
needed. Back issues: swap `/digital/<YYYY-MM>/`.

## Resolution ladder

`files/pages/<tier>/<N>.jpg`:

```
thumbs 78×95  →  smartphone 639×787  →  tablet 974×1200  →  large 2058×2532  ← flipbook ceiling
```

Companions: `svg/N.svg` (crisp **text-only** vector overlay, zero embedded rasters — not a master),
`tiles/` (deep zoom), `words/` (OCR), `interactive/N.json` (hotspots).

**`tiles/` is worth one probe:** it 404s when the issue uses SVG-zoom, but if `v004.level[]` has a
grid **and** `tiles/` returns 200, stitched tiles can **beat** `large`.

## Traps

- Every higher-name guess above `large` — `xlarge`, `original`, `print`, `hd`, `web`, `zoom`,
  `full`, `source`, `master` — **404s**.
- **`download.pdf` / `printPages.pdf` are client-side jsPDF re-wraps of the `large` JPGs** — a trap,
  not a server-side master.
- ~1px width jitter (2057 vs 2058) across pages is normal export rounding.
- **All-identical byte sizes across pages is a placeholder red flag.**
- Serves plain curl with a browser UA and an issue-root `Referer`.

## The critical correction — the flipbook is a DERIVATIVE

**When a publication is ALSO distributed as a downloadable print PDF, the flipbook's top tier is a
downscaled/compressed web derivative — not the master.**

Measured on one title: the print PDF ran ~1.27 MB/page against the flipbook's ~0.4 MB/page (**~3×**),
with embedded images at ~300 DPI versus the flipbook's 211. The `large` tier is genuinely the
*flipbook's* ceiling (tiles unreferenced, zoom is vector-text-over-`large`, the source PDF was
stripped from the CMS — all download paths 404, directory listings 403). But the flipbook is not the
publication's ceiling.

**Right workflow:** get the print PDF, then `pdfimages -all` to extract native-resolution page
images byte-exact. Those are the master pages.

> **LESSON, general:** whenever the target is a flipbook or web reader — 3D Issue, Issuu, Pugpig,
> FlippingBook, FlipHTML5 — **check whether the title is also sold or distributed as a PDF before
> declaring the reader's top tier the master.**

Aggregators that carry such PDFs **lag** (a days-old issue will not be up yet), so "not there today"
is not "never".

Related: [[pugpig]] (where the sibling PDF is served alongside and the lever is easy), [[playboy]],
[[emagazines]].
