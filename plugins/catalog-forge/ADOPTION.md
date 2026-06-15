# Adoption — from proposal to practice

How `catalog-forge` realizes `WORKFLOW_AUTOMATION_PROPOSAL.md`, and the exact sequence to
finish Kanye West and keep future collections aligned.

## Proposal → implementation map

| Proposal item | Where it lives now |
|---|---|
| One contract = the truth-root verifier | `catalog verify` calls `verify_all.py`; never a local-only gate |
| One-command verify (kill the §5 symlink dance) | `catalog verify` auto-stages + tears down |
| Single source for collections (no local copy) | truth-root schema enum is the source; `schema/config.json` holds only the path; `catalog registry list/plan` |
| Two-field name model (display + official) | `official_name` replaces the `name_variants` array; `scripts/migrate_official_name.py` |
| Sidecar schemas | `schema/{metadata,image_sources,curation}.schema.json` + `catalog sidecars` |
| Enrichment proposers (dates / dupes / identical) | `catalog enrich` → `_pipeline/_review/queue.json` (propose-only) |
| Image-acquisition helper (`fetch`) | `catalog fetch` / `/catalog-fetch` — resolves the master rewrite from the CDN recipe table; advisory, never downloads (belonging stays gated) |
| Scheduled liveness + rendition-ceiling sweep | `catalog sweep` / `/catalog-sweep` — flag-only; `--online` probes URLs; schedulable over the truth root |
| New-collection scaffold | `catalog scaffold collection|product` (+ `CHECKLIST.md`) |
| The skill that keeps sessions aligned | `skills/canonical-collections/SKILL.md` |
| The "specialization" (delegated work stays on-contract) | `agents/catalog-curator.md` |
| Propose-never-assert, enforced structurally | `hooks/hooks.json` + `scripts/hook_guard.py` block any write to `metadata.json` |
| Human-in-the-loop queue | one `queue.json`, typed verdicts, consumed by finalize/merge |
| Promotion | `catalog-promote` (gated, irreversible) |

Built in v0.2.0 (the proposal's remaining "next steps"): the `catalog fetch` acquisition
helper (recipe resolver — the actual download still runs in your terminal per the directives)
and the schedulable liveness sweep. Still deferred by design: wiring `sweep` into an actual
cron/CI job is left to the operator (the command is ready; only the schedule is environment-
specific).

## Track A — finish Kanye West

1. **Adopt the two-field name model (do this first).** 75 records fail the truth verifier
   because the `names` phase wrote a top-level `name_variants` the schema forbids (see
   `FINDINGS.md`). Add `"official_name": {"type":["string","null"]}` to the truth schema's
   `properties`, then run the migration (dry-run first, then `--apply`):
   `python3 scripts/migrate_official_name.py --root "Kanye West (revised)"`.
   It sets `official_name` from POS truth and drops `name_variants` (preserved in provenance).
   Then `catalog verify --root "Kanye West (revised)" --collection "Kanye West" --enforce` → fail=0.
2. **Validate sidecars:** `catalog sidecars --root "Kanye West (revised)"` (already clean).
3. **Enrich, per era, curator-confirmed:**
   `catalog enrich --root "Kanye West (revised)" --what all` →
   work `queue.json` one era at a time: set date semantics, resolve the 32 same-product
   candidates (Operation C merges on confirm), decide the 159 identical-file groups.
4. **Promote (gated):** `/catalog-promote "Kanye West (revised)" "Kanye West"` — verifies,
   shows the `registry plan` (the 3 remaining builder edits), and on your confirmation copies
   under `/Volumes/PRO-G40/collections/Kanye West/<Era>/<Product>/`, then `make all && make verify`.
5. **Docs:** truth-root `README.md` + `docs/COLLECTIONS.md` (or `make docs`).

## Track B — keep future collections aligned

- Start every new collection with `catalog scaffold collection` → skeleton + checklist.
- The `canonical-collections` skill keeps each session on-contract automatically.
- `catalog verify` against the truth root is the definition of done, every time.
- Schedule a weekly verify + liveness sweep over the whole truth root to catch drift/link-rot.
- The state machine repeats: `scaffold → (fetch) → audit → review → enrich → finalize → verify → promote`.

## Registering a new collection

catalog-forge keeps **no copy** of the collection list — the truth root is the single source
(the schema `collection` enum + `verify_all.py`). `catalog registry list` reads it, and
`catalog registry plan --name <X> [--levels 2] [--sub-floor-ok] [--empty-images-ok]` prints the
exact five edits to register a new one (schema enum, the verifier, the three `unify`/`docs`
builders). If you ever want true single-file centralization, point those five tools at one
shared file — but until then there is no second copy to drift.
