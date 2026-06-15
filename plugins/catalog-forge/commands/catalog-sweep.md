---
description: Sweep a collection (or the whole truth root) for citation link-rot and below-master image renditions. Flag-only — it never edits a record. Offline by default (rendition-ceiling audit from the CDN recipes); add --online to probe each URL with a light ranged GET. Writes a report under _pipeline/_review/sweep.json. Schedulable as a weekly liveness check.
argument-hint: "[work-dir-or-truth-root] [--online]"
---

Flag, never fix. URLs rot whether or not anyone is curating — this surfaces the drift; the
curator decides what to do with it.

1. Run the sweep (defaults to the truth root if no root is given):
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" sweep --root "${1:-}"`
   Add `--online` to also probe each `download_url` (non-2xx / unreachable → `dead_or_unreachable`).
   Add `--truth-root <path>` to override the default.
2. Summarize the report's `counts`:
   - `non_master` — images served below the master ceiling (e.g. an eBay `s-l500`, a Depop
     `P3`). These still pass the verifier but should be re-fetched at master via `/catalog-fetch`.
   - `dead_or_unreachable` (online only) — 4xx/5xx or timeouts. Re-trace the source, or record
     it under `image_sources.unavailable_sources[]`.
3. Group findings by collection/era and hand them back as a worklist. **Apply nothing here** —
   re-fetching at master and any record change go through `/catalog-fetch` → `/catalog-finalize`,
   curator-confirmed. For scheduling, wire this command (or the engine call) into a weekly job.
