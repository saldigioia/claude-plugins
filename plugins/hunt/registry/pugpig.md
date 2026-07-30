# Pugpig (Bolt) — the sibling PDF holds the print master

- **Signature:** `<host>/wp-content/uploads/sites/<n>/YYYY/MM/pugpig_pdfpages/<issue>_page<NNN>_<hash>.{jpg,pdf}`
  Powers publisher app editions (`app.<brand>.com`).

## Lever

**Every reader JPG has a sibling PDF, and the PDF embeds a 300 dpi print-resolution JPEG.**

Quality ladder for one verified page:

| tier | result |
|---|---|
| WP-resized JPGs (`-300x300`, `-402x546`) | thumbnails |
| bare JPG (what the reader displays) | 1536×2088, ~600 KB, ~141 dpi |
| sibling PDF | 2.15 MB, MediaBox 576×783 pt (8" × 10.875" trim) |
| **embedded master inside the PDF** | **2400×3263 JPEG at 300 dpi, ~2.2 MB** |

Extract with `pdfimages -all`. The embedded JPEG is **byte-identical to the publisher's upload** —
recoverable losslessly. Cover pages sometimes embed much larger rasters (one cover was 5091×5846).

Pugpig rasterises a 1536-wide JPG for the reader UI but ships the source PDF with vector text plus
the original 300 dpi photo embedded as JPEG.

## Trap

**The JPG hash and the PDF hash are DIFFERENT for the same page.** Swapping `.jpg` → `.pdf` on the
reader's URL will not work. You must go through the manifest.

**Master-mode caveat:** the embedded JPEGs are the photo background only — the PDF's text is a
vector overlay and is **lost** if you extract just the raster. If text matters, keep the PDF
(or bind the pages with `pdfunite`) rather than only harvesting images.

## Enumeration surface

Both endpoints are public, no auth:

```
<host>/timelines.json                                   → every edition, with its manifest URL
                                                          embedded as a relative `feed` field
<host>/editionfeed/<id>/pugpig_atom_contents.json       → authoritative per-page map; each story
                                                          carries its own pdf_url
```

## HAR pitfall

Chrome and Safari record **`304 Not Modified` responses with status 304 but a populated body.** Any
HAR walker must accept 304 or it will silently skip real assets.

Related: [[3dissue]] (a different flipbook engine — and the reason to check for a distributed print
PDF before declaring any reader tier the master), [[emagazines]], [[playboy]].
