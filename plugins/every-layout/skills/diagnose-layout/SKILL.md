---
name: diagnose-layout
description: >
  Diagnose unexpected behavior in an Every Layout primitive. Traces custom
  property values, calculates thresholds, and explains the root cause.
  Read-only — never modifies files. Use when a primitive misbehaves.
disable-model-invocation: true
context: fork
agent: css-diagnostician
argument-hint: "<description of the misbehavior, plus file path or code>"
---

# Diagnose Layout

Diagnose the unexpected primitive behavior described below. Explain *why* it is happening by tracing the algorithm — do not modify files.

$ARGUMENTS

Canonical inputs before diagnosing:

- Primitive definition: `skills/css-layout-engine/references/primitives.md` — the `applies_when`, `fails_when`, and custom-property defaults for the primitive in question.
- Hooks: `skills/css-layout-engine/references/hooks.md` — how each primitive responds to its custom properties.

## Report shape

```markdown
## Diagnosis: [Primitive Name] (ELC_*)

### Symptom
One-sentence restatement of what the user observes.

### Algorithm trace
Walk through the primitive's decision logic:
- Which custom properties are in play, with their resolved values
- Which threshold or ratio is decisive
- Where the observed computed value lands relative to that threshold

### Root cause
A single clear statement of WHY the primitive is behaving as reported.

### Fix options
1. [Smallest change — adjust a custom property]
2. [Structural change — use a different primitive]
3. [Escape hatch — register in `escapes.md` if intentional]

Rank by preference. Do not apply any fix — this is explanation only.
```

## Constraints

- MUST cite the primitive ID (ELC_*)
- MUST trace the algorithm, not just describe the outcome
- MUST NOT modify files
- MUST NOT suggest media queries as the fix (that would violate ELP_009)
- MUST acknowledge when the reported behavior is actually correct-by-design (e.g., Sidebar stacking because viewport narrower than `--side-width`)
