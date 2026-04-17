---
name: plan-migration
description: >
  Scan a CSS codebase and produce a phased migration plan to Every Layout
  primitives. Read-only — reports violation counts grouped by severity and
  locality, and recommends a migration sequence by impact.
disable-model-invocation: true
allowed-tools: Read Grep Glob
paths:
  - "**/*.css"
  - "**/*.scss"
  - "**/*.astro"
  - "**/*.html"
argument-hint: "<directory or file path to scan>"
---

# Plan Migration

Scan the CSS codebase at the supplied path and produce a phased adoption plan for Every Layout primitives.

$ARGUMENTS

This is read-only analysis — never modify files. For the canonical definitions of primitives and principles referenced below, load `skills/css-layout-engine/references/primitives.md` and `principles.md`.

## Process

### Phase 1 — Inventory
Glob every CSS/SCSS/Astro/HTML file in the target. Count violations per category, attributing each to a principle ID:

| Category | Principle | Signal |
|---|---|---|
| Fixed widths/heights on containers | ELP_002 | `width: \d+px`, `height: \d+px` not on media/Frame |
| Media queries for layout | ELP_009 | `@media.*(min-width\|max-width)` wrapping layout declarations |
| Arbitrary spacing | ELP_005 | numeric values not mapped to `--s-5`..`--s5` |
| Physical properties | ELP_004 | `margin-left/right/top/bottom`, `padding-left/right/top/bottom`, `width/height` |
| Missing motion safety | ELP_028 | any `transition` or `animation` not gated by `prefers-reduced-motion` |
| Missing focus visibility | ELP_029 | `outline: none` without a `:focus-visible` replacement |

Group by file and severity (High = accessibility + layout; Medium = spacing + logical-props; Low = cosmetic).

### Phase 2 — Primitive mapping
Map each violation cluster to a replacement primitive:

- Flex/grid with media queries → ELC_GRID, ELC_SWITCHER, ELC_SIDEBAR (pick by content shape)
- Fixed-width containers → ELC_CENTER
- Vertical spacing patterns → ELC_STACK
- Card/box patterns → ELC_BOX
- Aspect-ratio containers → ELC_FRAME
- Horizontal overflow scrollers → ELC_REEL
- Modals and overlays → ELC_IMPOSTER

### Phase 3 — Sequence by impact
Order the phases by violations-resolved-per-change (highest impact first). Group related refactors in a single phase (all card layouts, all nav sidebars). End with a dedicated accessibility pass: reduced-motion reset, `:focus-visible`, skip link.

## Output

```markdown
## Migration Report

### Inventory Summary
- Files scanned: N
- Total violations: N (by category table)

### Violation Heatmap
Top 10 files by violation count.

### Migration Phases
Phase 1: [name] — resolves ~X % — primitive: ELC_*, files: [list], effort: [small/medium/large]
Phase 2: ...
Phase 3: Accessibility pass.

### Estimated Total
- Phases, primitives needed, violations resolved (X/Y), intentional exceptions (register in `escapes.md`).
```

## Constraints

- MUST NOT modify any files
- MUST cite ELP_* for each category and ELC_* for each recommendation
- MUST sequence by impact
- MUST name the accessibility pass as its own phase
- MUST surface intentional violations that should be registered in `escapes.md` rather than refactored

Stop after the report — do not begin implementation from within this skill.
