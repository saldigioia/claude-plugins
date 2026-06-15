---
description: Scaffold a new product or a whole new collection work-dir from the registry — correct folder grammar, a canonical.json stub, and an instantiated finalization checklist. Mechanical; creates new dirs only, never overwrites.
argument-hint: "product|collection <work-dir> <name> [era]"
---

Create a correct skeleton so structure is never re-derived from memory.

New collection work dir:
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" scaffold collection --root "<work-dir>" --name "<Collection>"`
(writes `CHECKLIST.md` — the playbook, instantiated for that collection).

New product:
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" scaffold product --root "<work-dir>" --name "<Name (Colour) [Tag]>" [--era "<Era>"] --collection "<Collection>"`
(writes a `canonical.json` stub with slug / folder_name / name / era filled).

After scaffolding a product: acquire master imagery (see the `canonical-collections` skill's
CDN recipes; run long fetches in the curator's own terminal), trace each source, then
`/catalog-finalize`. Register the collection when ready (`registry plan`), then `/catalog-promote`.
