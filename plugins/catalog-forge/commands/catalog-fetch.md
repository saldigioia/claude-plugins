---
description: Resolve a listing or image URL to its master rendition using the per-CDN recipe table (eBay s-l1600, Etsy il_fullxfull, Shopify .json, Depop P0, Mercari, Instagram, Grailed, gem.app). Advisory and read-only — it computes the master URL and prints the impersonation profile + isolation rule; it never downloads. Gallery isolation and product/colourway belonging stay curator-gated.
argument-hint: "<image-or-listing-url> [work-dir]"
---

Acquisition plumbing is mechanical; **deciding a gallery belongs to a product/colourway is a
curator verdict.** This command does the plumbing only — it never downloads and never edits.

1. Resolve the master rendition:
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" fetch --url "$1"`
   (pass `--root "$2"` only for context; fetch writes nothing.)
2. Report what it found:
   - `master_url` + `deterministic_rewrite: true` → a safe, exact rewrite to the master.
   - `deterministic_rewrite: false` → the host needs a JSON or headless step; relay the
     `master_rendition` recipe (e.g. Shopify `<product>.json → images[].src`, Instagram
     `/embed/captioned/ display_url`, Grailed `__NEXT_DATA__ photos[]`).
   - `recognized: false` → no recipe matched; trace the source by hand and record provenance.
3. Hand the curator the next steps the tool prints, and **stop**: confirm the image belongs to
   this product's own gallery (reject cross-sell), SHA-256-dedupe against what's on disk, then
   run the actual fetch in your own terminal with `curl --impersonate <profile>` as a
   resumable script. Add the row to `image_sources.json` with its provenance; route any
   unreachable-but-known source to `image_sources.unavailable_sources[]` — never drop it.

Never write `metadata.json`. Long network jobs run in the curator's terminal, not here.
