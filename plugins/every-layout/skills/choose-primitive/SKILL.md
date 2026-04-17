---
name: choose-primitive
description: >
  Select the appropriate Every Layout primitive for a given layout problem.
  Walks a decision tree, recommends a primitive with rationale, lists
  alternatives considered, and provides verification steps.
disable-model-invocation: true
allowed-tools: Read Grep Glob
argument-hint: "<layout problem description>"
---

# Choose Primitive

Recommend the correct Every Layout primitive for the problem described:

$ARGUMENTS

Walk the decision tree in `references/decision-tree.md` to pick a primitive. Canonical primitive definitions live in `skills/css-layout-engine/references/primitives.md` — load that file before recommending, and cite the primitive's ID (ELC_*) and the principle IDs (ELP_*) that apply.

## Process

1. Read the context: container shape, content type, responsive behavior, constraints.
2. Walk the decision tree (`references/decision-tree.md`) until you reach a single primitive.
3. Verify the primitive fits by checking its "Applies when" and "Fails when" clauses in `primitives.md`.
4. Consider at least one alternative and explain why you rejected it.
5. Supply a minimal working example (HTML + CSS) using the primitive's canonical custom properties.

## Report shape

```markdown
## Recommendation: [Primitive Name] (ELC_*)

### Why
Short paragraph linking the problem to the primitive's "applies when".

### Key parameters
Table of custom properties and their chosen values, with reasons.

### Code
Minimal HTML + CSS.

### Alternatives considered
Table: primitive | ID | why rejected.

### Verification
Checklist pulled from the primitive's "verification_tests" in `primitives.md`.

### Related principles
ELP_* IDs that govern this choice.
```

## Constraints

- MUST cite ELC_* and ELP_* IDs
- MUST consider at least one alternative
- MUST provide working code, not prose
- MUST NOT invent primitives
- MUST NOT recommend combinations when a single primitive suffices — prefer one primitive, compose later

See `references/decision-tree.md` for the full tree and `references/combinations.md` for when a combination is warranted.
