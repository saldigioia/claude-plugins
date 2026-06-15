---
description: Verify a work-dir collection against the truth-root 4-axis verifier (citation, metadata, placement, image consistency). One command — no manual symlink staging. Read-only.
argument-hint: "<work-dir> [collection]"
---

Verify a collection against the truth root's 4-axis verifier — the single source of
acceptance. Never substitute a local-only check.

Steps:
1. Determine the work-dir root (`$1`, or ask the user) and the truth root (default:
   `truth_root_default` in `@${CLAUDE_PLUGIN_ROOT}/schema/config.json`; confirm it exists).
2. Run:
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" verify --root "<work-dir>" --enforce`
   Add `--collection "$2"` if the collection can't be sniffed, `--truth-root <path>` to override.
   This auto-builds and tears down a temporary symlink staging tree — it does not modify the tree.
3. Summarize pass/fail per collection and the per-axis failure counts. For any failures, open
   `<work-dir>/_pipeline/_review/verify/_verify_<Collection>.tsv` and group the messages by
   type so the curator sees *what* failed.
4. Fix nothing. For a schema/contract mismatch (a non-`_` field the schema doesn't list),
   name the two options — amend the truth schema's `properties`, or prefix the field `_` — and
   let the curator decide.
