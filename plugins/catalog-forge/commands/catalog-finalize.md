---
description: Finalize products in a work-dir collection — runs the gate (blocks on any Phase 0-3 error), contiguously renumbers images to NN.ext, and regenerates canonical.json from authoritative on-disk measurements. Mechanical, but it WRITES; backs up first.
argument-hint: "<work-dir> [product dir]"
disable-model-invocation: true
---

Finalize is mechanical but it writes. Confirm scope with the curator before applying.

1. Pre-check: run `/catalog-audit` over the scope. If the gate would block (any error), STOP
   and report — finalize must never run over errors.
2. Dry-run first (default — no `--apply`):
   `python3 "<work-dir>/_pipeline/collection_pipeline.py" finalize --root "<work-dir>" [--product "<dir>"]`
   Show the planned renumbering and the canonical regen.
3. Only on explicit curator confirmation, re-run with `--apply` (writes a timestamped backup
   bundle first). Never pass `--apply` without confirmation.
4. Re-verify: `/catalog-audit` should be green for the finalized scope.
