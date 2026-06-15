---
description: Promote a finished work-dir collection into the truth root — stage, verify, copy under <truth>/<Collection>/, register the collection in the schema + tools, then run make all + make verify. GATED and IRREVERSIBLE; requires explicit curator confirmation at each write.
argument-hint: "<work-dir> <collection>"
disable-model-invocation: true
---

This is the ONLY irreversible step — it writes into the truth root. Do not run any part
without explicit, specific curator confirmation, and never while `/catalog-audit` is not green.

1. Gate: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" verify --root "$1" --collection "$2" --enforce`.
   If fail≠0, STOP.
2. Registration plan (read-only):
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" registry plan --name "$2" --levels 2 --sub-floor-ok --empty-images-ok`
   (drop the flags for a flat collection), plus `... registry list` to see what's already
   registered. Show the curator the exact five edits (schema enum, `verify_all.py`, the three
   `unify`/`docs` builders).
3. On confirmation: back up the affected truth-root paths, apply the registration edits, then
   copy the tree to `<truth>/<Collection>/<Era>/<Product>/` (move `_quarantine_undersized/`
   under it).
4. Rebuild + verify: `cd <truth> && make all && make verify`. Expect the new products present
   and fail=0. If verify is not green, roll back the copy and report.
5. Docs: update `<truth>/README.md` and `docs/COLLECTIONS.md` (or `make docs`).
