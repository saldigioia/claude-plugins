---
description: Build the visual review artifacts (contact sheets, phash outliers) and the single propose-only judgment queue for a collection, so the curator can confirm belonging / merge / name / colour decisions. Read-only to product records.
argument-hint: "<work-dir> [era or product]"
---

Produce the evidence the curator needs to make judgment calls — never decide for them.

1. Visual belonging evidence (per product or era), via the existing pipeline:
   `python3 "<work-dir>/_pipeline/collection_pipeline.py" visual --root "<work-dir>" [--product "<dir>"]`
   → contact sheet + phash clusters + outliers + a `belonging_review` template.
2. Refresh the review UI if present: `python3 "<work-dir>/_build_index.py"`, then open `index.html`.
3. Build the consolidated judgment queue (propose-only):
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" enrich --root "<work-dir>" --what all`
   → `<work-dir>/_pipeline/_review/queue.json`.
4. Present the queue grouped by type with counts and evidence. Collect the curator's verdicts.
   Apply nothing here — verdicts feed `/catalog-enrich` (merges) and `/catalog-finalize`.
