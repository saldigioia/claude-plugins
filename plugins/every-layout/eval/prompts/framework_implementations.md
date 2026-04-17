# Prompt: Framework Implementations

## Purpose

Evaluate a framework port (Astro / React / Vue / Svelte / Tailwind / vanilla CSS) of an Every Layout primitive against the `framework-implementations` skill. A good port threads the primitive's custom properties through the framework's idiomatic convention without adding or dropping parameters, and without changing the primitive's CSS behavior.

## Prompt Template

```
Evaluate the following framework port against the framework-implementations skill.

TARGET FRAMEWORK: [Astro | React | Vue | Svelte | Tailwind | Vanilla]
PRIMITIVE: [ELC_STACK | ELC_BOX | ELC_CENTER | ... ]

IMPLEMENTATION:
[Paste component file — .astro, .tsx, .vue, .svelte, or .css]

TYPES (if separate):
[Paste types file if shared across primitives]

USAGE EXAMPLE (optional):
[Show the port being composed with another primitive or with app data]

EVALUATION REQUIREMENTS:

1. Fidelity to the primitive spec
   - Every CSS custom property from the primitive is exposed as a configurable prop
   - No parameters invented beyond the spec
   - CSS behavior identical to skills/css-layout-engine/references/primitives.md

2. Framework idiom
   - Astro: scoped <style>, server-rendered, no unnecessary client directive
   - React: forwardRef, HTMLAttributes extension, as-prop for polymorphism
   - Vue: defineProps with TS, withDefaults, scoped style
   - Svelte: export let with defaults, scoped style
   - Tailwind: addComponents (semantic class names), NOT addUtilities
   - Vanilla: CSS custom properties settable per-instance; no JS

3. Prop API consistency
   - Matches the canonical CSS-to-prop mapping in skills/framework-implementations/SKILL.md
   - Default values match the primitive spec
   - Prop types match the CSS-value type (length, integer, enum)

4. Hydration discipline (framework-dependent)
   - Astro ports have no client:* directives
   - React/Vue/Svelte ports do not pull in runtime-only hooks unless the primitive demands them (none of the 13 do)

5. Logical-property preservation
   - Ported CSS uses the same logical properties as the canonical primitive (inline-size, block-size, etc.)
   - No physical-property substitution for convenience

6. Accessibility
   - ARIA attributes pass through props (e.g., role, aria-label)
   - Semantic HTML element exposed via an 'as' prop where the primitive allows

7. Zero-invented-features
   - No new props like 'variant', 'size', 'color' that weren't in the primitive
   - No framework-specific 'icon' slot in Stack, 'loading' state in Grid, etc.
   - Keep the primitive minimal — framework adds nothing beyond prop threading

OUTPUT FORMAT:

## Framework Port Score: X/10

## Per-Dimension Breakdown
| Dimension | Score | Evidence |
|---|---:|---|
| Fidelity to spec | /3 | |
| Framework idiom | /2 | |
| Prop API consistency | /2 | |
| Hydration discipline | /1 | |
| Logical-property preservation | /1 | |
| Accessibility pass-through | /1 | |
| **Total** | **/10** | |

## Findings
Group by severity. Each cites ELC_* (primitive) and framework-specific correction.

## Verification
- [ ] Compiled without warnings in the target framework
- [ ] Composes with at least two other primitive ports
- [ ] CSS inspector shows the same computed rules as the canonical primitive
```

## Fixtures

Ports should be drawn from the canonical templates in `skills/framework-implementations/references/<framework>.md`. A "port fixture" is a single primitive implementation for a named framework.

For integration testing at the site level, see `demos/archive-site-react-port/` (added as part of plan S19) which exercises React ports of Stack, Grid, and Sidebar in a real Astro page.

## Scoring (0-10)

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 9-10 | A | Exemplary port — ship as canonical |
| 7-8 | B | Minor tweaks needed (default values, TS types) |
| 5-6 | C | Multiple departures from spec |
| 3-4 | D | Invents features beyond the primitive |
| 0-2 | F | Not a port — a new component |
