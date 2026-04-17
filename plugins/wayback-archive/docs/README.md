# Wayback-Archive Docs

Operational and strategic documentation for the pipeline. For stage-level reference material (extraction strategy, config schema, lessons learned), see [`../skills/wayback-archive/references/`](../skills/wayback-archive/references/).

## Contents

- [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) — Multi-phase analysis → brainstorm → edit workflow that hardens the pipeline against reactive/file-centric behavior. Defines the five standing protocols, the ledger schema, and the definition of done.

## Standing Protocols (summary)

The skill and the pipeline are bound by five invariants. Full text lives in [IMPROVEMENT_PLAN.md § I](IMPROVEMENT_PLAN.md#i-standing-protocols-apply-during-every-phase) and in [`../skills/wayback-archive/SKILL.md`](../skills/wayback-archive/SKILL.md):

1. Entity-first (not file-first)
2. Discovery surfaces are recursive, never terminal
3. New host → immediate CDX-dump + enumeration
4. No "done" without the five-question audit
5. Validate (normalize → classify → reject → dedupe) before counting

If any of these feels negotiable in the moment, read the plan — there is a prior incident behind each one.
