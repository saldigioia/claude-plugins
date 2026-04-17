---
name: generate-port
description: >
  Generate a framework-specific component implementation of an Every Layout
  primitive. Targets Astro, React, Vue, Svelte, Web Components, Tailwind, and
  vanilla CSS, using the canonical port templates from the framework-implementations skill.
disable-model-invocation: true
allowed-tools: Read Write Edit Grep Glob
argument-hint: "<framework> <primitive>   (e.g. 'react Sidebar' or 'astro Grid')"
---

# Generate Component Port

Generate a framework-specific port of an Every Layout primitive.

$ARGUMENTS

Canonical inputs before generating:

- Primitive definition: `skills/css-layout-engine/references/primitives.md` (section for the named primitive — read its params, custom properties, `applies_when`, `fails_when`, and `verification_tests`)
- Framework template: `skills/framework-implementations/references/<framework>.md` (contains the canonical port for each of the 13 primitives in that framework)

Do NOT generate a template from first principles — use the ones already in `framework-implementations/references/`. This skill's job is to thread the primitive's custom properties through the chosen framework's convention.

## Process

1. Parse `$ARGUMENTS` into `<framework>` and `<primitive>`.
2. Validate the primitive name against the 13 canonical IDs (ELC_STACK, ELC_BOX, ELC_CENTER, ELC_CLUSTER, ELC_SIDEBAR, ELC_SWITCHER, ELC_COVER, ELC_GRID, ELC_FRAME, ELC_REEL, ELC_IMPOSTER, ELC_ICON, ELC_CONTAINER). Reject unknown names.
3. Load `framework-implementations/references/<framework>.md` and copy the canonical port for that primitive.
4. Verify the port exposes every custom property listed in the primitive card as a component prop, mapped via the common prop API (see `framework-implementations/SKILL.md` for the CSS-to-prop mapping table).
5. Produce a complete file (or set of files if the framework needs shared types/barrel exports).

## Report shape

```markdown
## Port: [Primitive Name] (ELC_*)

### Framework: [name]

### Files to create
- `<path>` — [purpose]
- `<path>` — [purpose]

### Component implementation
Complete file contents for each path above.

### Props reference
One row per custom property, with type, default, and CSS mapping.

### Usage examples
- Basic
- With configuration
- Composed with another primitive

### Verification
Checklist lifted from the primitive's `verification_tests` in `primitives.md`.

### Accessibility notes
Any ARIA / focus / keyboard considerations from the primitive card.
```

## Constraints

- MUST use the canonical template from `framework-implementations/references/<framework>.md`
- MUST expose every primitive custom property as a component prop
- MUST cite the primitive ID (ELC_*)
- MUST provide working, complete code — no placeholders
- MUST NOT invent props or add features beyond the primitive spec
- MUST NOT use arbitrary spacing values — all from modular scale
