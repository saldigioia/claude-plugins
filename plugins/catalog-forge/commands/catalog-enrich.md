---
description: Propose (never apply) enrichment candidates for a collection — missing dates, same-product duplicates sharing a citation handle, and byte-identical images spanning products. Writes a review queue for curator confirmation, one era at a time.
argument-hint: "<work-dir> [dates|dupes|identical|all]"
---

Propose-only. This command must not modify any product file.

1. Run:
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" enrich --root "$1" --what ${2:-all}`
2. Read back `<work-dir>/_pipeline/_review/queue.json`; summarize counts per type.
3. Walk the curator through entries **one era at a time** (per the standing directives). Per entry:
   - `date` — show proposed value + basis; curator accepts / sets ISO / leaves null.
   - `same_product` — show the shared citation key/value and the products; curator picks
     `merge->keeper` or `keep-separate`.
   - `identical_file` — show the products sharing the byte-identical image; curator picks
     `merge` / `cross-link` / `coincidental-press-shot` / `keep-separate`.
4. Record verdicts in the queue. Only AFTER confirmation, apply merges via the pipeline's
   Operation C (`dedup` → confirmed merge), which backs up first. Leave dates/links to finalize.
