# Findings from the live test runs

The engine was run read-only against the real `Kanye West (revised)` work dir and the
`/Volumes/PRO-G40/collections` truth root. Nothing was modified in either tree. Artifacts are
under `_artifacts/`.

> Note: the truth-root external drive (`PRO-G40`) disconnected partway through the session, so
> the full-collection verify numbers below are from the run earlier in the session while it was
> mounted; the `name_variants` count is independently corroborated by the migration dry-run
> (below), which reads only the work dir. The single-symlink staging used by `verify` is proven
> by a glob test (286 product hits through one symlink).

## 1. The headline: 75 records fail the truth-root verifier

`catalog verify` (full collection, 286 products, ~6 s) reported **211 pass / 75 fail**, all on
the **metadata axis**, all the same error:

```
schema::'name_variants' does not match any of the regexes: '^_'
```

Root cause (confirmed, not a tool bug):
- The truth schema `canonical-3.1.schema.json` is `additionalProperties:false` and only allows
  unknown keys starting with `_`. It does **not** list `name_variants` in `properties`.
- `collection_pipeline.py`'s `names` phase writes a top-level `name_variants`
  (line ~524: `c["name_variants"] = variants`), stamped `2026-06-14` — i.e. **after** the
  6-13 "passes clean" snapshot in `_ONBOARDING.md`. The tree drifted out of compliance after
  the last clean verify; the one-command verify surfaced it in seconds.

**Fix — adopt the two-field name model** (the cleaner resolution, decided with the curator):
`name` (display) + `official_name` (the POS title, present only when an official source exists).
Superseded names are history → preserved in `provenance`, not an array. Concretely:

1. Add one line to the truth schema's `properties`: `"official_name": { "type": ["string", "null"] }`.
2. Run `scripts/migrate_official_name.py --root "Kanye West (revised)"` (dry-run), then `--apply`.

The migration dry-run reports: **77 products to change — set `official_name` on 50, drop
`name_variants` from 75** (the 75 dropped match the 75 verify failures exactly). It preserves
each dropped array under `provenance._former_name_variants` (no silent disposal) and backs up
before writing. After it, `catalog verify --enforce` should return fail=0.

## 2. Enrichment backlog quantified (propose-only queue)

`catalog enrich --what all` produced `_artifacts/kanye_review_queue.json`, **241 entries**, none
applied. The verdict options live once in the queue header (`verdict_options`), not on every
entry; each entry carries only what varies plus `verdict: null`.

| Type | Count | What it is |
|---|---:|---|
| `date` | 50 | undated products with a **high-confidence** date from `metadata.first_seen` (POS). Era-year guesses were dropped as noise — undated reseller products wait for your date-semantics decision. |
| `same_product` | 32 | products sharing a citation handle (incl. the 31 known `parisaint_handle` pairs) — candidate dupes/mis-citations |
| `identical_file` | 159 | byte-identical images appearing under more than one product |

## 3. Sidecars are clean

`catalog sidecars` validated **137 sidecars** (50 `metadata.json`, 37 `image_sources.json`,
50 `curation.json`) against the (trimmed) JSON Schemas: **0 problems**. The schemas now assert
only what matters — required ids/keys and that every reseller image has a filename — and the
store-reconstruction layer passes cleanly.

## 4. The registry is the truth root, not a copy

The earlier draft shipped a `collections.json` that duplicated the truth root's collection
facts plus a `registry check` to police the copy. That was removed. `catalog registry list` now
reads the truth root's schema enum directly (the single source); `registry plan` prints the
exact five edits to register a new collection from flags. `config.json` holds only the
truth-root path. There is no second copy to drift.

## What was deliberately NOT done

No data was changed; the truth root was not written to; no merges, renames, dates, promotions,
or the name migration were applied. Every judgment item is in the queue awaiting a verdict, and
`migrate_official_name.py` was run dry-run only.
