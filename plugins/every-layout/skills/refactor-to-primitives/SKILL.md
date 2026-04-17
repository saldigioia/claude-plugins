---
name: refactor-to-primitives
description: >
  Transform non-compliant CSS layout code into Every Layout primitive-based
  implementations with working output. Maps current patterns to primitives,
  produces step-by-step diffs, and verifies the result against principles.
disable-model-invocation: true
allowed-tools: Read Write Edit Grep Glob
paths:
  - "**/*.css"
  - "**/*.scss"
  - "**/*.astro"
  - "**/*.html"
argument-hint: "<file path or code block to refactor>"
---

# Refactor to Primitives

Refactor the supplied layout code to use Every Layout primitives:

$ARGUMENTS

Before editing, load:
- `skills/css-layout-engine/references/primitives.md` for primitive definitions
- `skills/css-layout-engine/references/principles.md` for violation analysis
- `references/refactoring-patterns.md` — common before/after transformations
- `references/primitive-selection.md` — which primitive to reach for

## Process

1. **Analyze** — Identify the current pattern, the violations (cite ELP_*), and what the refactor must preserve (HTML structure? class names? behavior?).
2. **Map** — For each violation cluster, choose a replacement primitive (cite ELC_*). When unclear, invoke `choose-primitive` first.
3. **Rewrite** — Produce complete working HTML + CSS (not fragments). Use logical properties, modular-scale spacing, and primitive custom properties.
4. **Verify** — Run the checklist in the Report shape below against the refactored output.

## Report shape

```markdown
## Refactoring Plan

### Current state
- Pattern: [name]
- Violations (with ELP_*): [list]
- Preserves: [HTML structure / class names / etc.]

### Primitive mapping
Table: current-code | replacement-primitive | ID | rationale.

### Step-by-step refactor
Each step: a WHY (ELP_*) line + before/after code block.

### Complete output
Full HTML + full CSS (not a diff).

### Verification checklist
- [ ] No fixed widths on containers (ELP_002)
- [ ] No layout media queries (ELP_009)
- [ ] All spacing from modular scale (ELP_005)
- [ ] Logical properties only (ELP_004)
- [ ] Primitives compose correctly (ELP_001)
- [ ] Motion gated by `prefers-reduced-motion: no-preference` (ELP_028)
- [ ] `:focus-visible` styled, not `outline: none` (ELP_029)

### Tradeoffs
Gained / lost / complexity.
```

## Constraints

- MUST use only documented primitives (ELC_*)
- MUST cite primitive and principle IDs in every step
- MUST provide complete, runnable code — no fragments
- MUST NOT invent primitives or use arbitrary spacing
- MUST NOT remove accessible focus styles as part of refactor

Stop after presenting the complete refactored code and verification checklist.
