---
name: css-layout-engine
description: "CSS layout primitives and composition rules: Stack, Box, Center, Cluster, Sidebar, Switcher, Cover, Grid, Frame, Reel, Imposter, Icon, Container, modular scale, logical properties, intrinsic responsive layout, Every Layout methodology."
allowed-tools: Read Grep Glob
paths:
  - "**/*.css"
  - "**/*.scss"
  - "**/*.html"
  - "**/*.astro"
  - "**/*.vue"
  - "**/*.svelte"
  - "**/*.tsx"
  - "**/*.jsx"
  - "**/*.mdx"
---

# CSS Layout Engine

The Every Layout system provides 13 composable CSS layout primitives that replace media-query-driven responsive design with algorithmic, intrinsic layouts. This skill contains the primitives, principles, decision tools, and composition rules.

> **Axiomatic commitment.** This plugin treats simple, durable, CSS-dominant web design as a requirement, not a recommendation. The six axioms in [`references/axioms.md`](references/axioms.md) — Algorithmic Layout, Designing Without Seeing, Exception-Based Styling, Axiomatic Values, CSS-Dominant Composition, Archival Durability — govern every recommendation this skill makes. The `/strict-check` skill and `bin/css-strict.sh` + `bin/js-budget.sh` scripts enforce them at the file level. Exceptions are registered in `escapes.md` with an expiry date, not hidden.

---

## The 13 Primitives

| ID | Name | Problem Solved |
|----|------|----------------|
| ELC_STACK | Stack | Vertical spacing between siblings |
| ELC_BOX | Box | Padded, bordered containers |
| ELC_CENTER | Center | Horizontal centering with max-width (measure) |
| ELC_CLUSTER | Cluster | Horizontal wrapping with gaps |
| ELC_SIDEBAR | Sidebar | Fixed + flexible two-element layout |
| ELC_SWITCHER | Switcher | Equal columns that stack below threshold |
| ELC_COVER | Cover | Vertical centering with header/footer |
| ELC_GRID | Grid | Responsive grid without media queries |
| ELC_FRAME | Frame | Aspect ratio container for media |
| ELC_REEL | Reel | Horizontal scrolling container |
| ELC_IMPOSTER | Imposter | Overlay centering |
| ELC_ICON | Icon | Inline icons that scale with text |
| ELC_CONTAINER | Container | Container query context |

> Full specs: `references/primitives.md`

---

## Core Principles

| ID | Principle |
|----|-----------|
| ELP_001 | Composition Over Inheritance — combine simple primitives, don't build monoliths |
| ELP_002 | Intrinsic Sizing — let content determine size, avoid fixed dimensions |
| ELP_003 | Universal Border-Box — always use `box-sizing: border-box` |
| ELP_004 | Logical Properties — use `inline-*`/`block-*`, not `left`/`right` |
| ELP_005 | Modular Scale — all spacing from scale (ratio 1.5): `--s-2` to `--s5` |
| ELP_006 | Measure Constraint — limit line length to `65ch` for readability |
| ELP_007 | Global Element Styles — style elements first, add classes only when needed |
| ELP_008 | Child-Only Layout Effects — parent controls layout of direct children only |
| ELP_009 | Algorithmic Layout — design rules, not breakpoints |

**Layout-behavior principles:**

| ID | Principle |
|----|-----------|
| ELP_019 | Container Query Measurement Invariance |
| ELP_020 | Inline-Size Containment Default |
| ELP_021 | Subgrid for Cross-Item Alignment |
| ELP_025 | Fluid Sizing via Clamp |
| ELP_026 | Accessibility-Safe Fluid Values |
| ELP_027 | Progressive Enhancement |
| ELP_028 | Motion Safety — `prefers-reduced-motion` |
| ELP_029 | Focus Visibility — `:focus-visible` |
| ELP_030 | Text Wrap Balance — `text-wrap: balance` on headings |
| ELP_031 | Scroll Snap Enhancement — progressive, not mandatory |
| ELP_032 | Font-Display Contract — `font-display: optional` for `ch`-unit CLS prevention |

> Full specs for all 32 principles: `references/principles.md`

---

## Modular Scale

Ratio 1.5. All spacing values must come from this scale. Arbitrary values (`17px`, `1.3rem`) are prohibited.

```css
--s-5: 0.132rem;  --s-4: 0.198rem;  --s-3: 0.296rem;
--s-2: 0.444rem;  --s-1: 0.667rem;  --s0: 1rem;
--s1: 1.5rem;     --s2: 2.25rem;    --s3: 3.375rem;
--s4: 5.063rem;   --s5: 7.594rem;
```

Each `calc()` chain must start from `--ratio` and `--s0` — never hardcode derived values.

---

## CSS Recipes

### Stack (ELC_STACK)
```css
.stack { display: flex; flex-direction: column; justify-content: flex-start; }
.stack > * { margin-block: 0; }
.stack > * + * { margin-block-start: var(--space, 1.5rem); }
```

### Box (ELC_BOX)
```css
.box {
  padding: var(--padding, var(--s1));
  border: var(--border-thin, 1px) solid;
  outline: var(--border-thin, 1px) transparent;
  outline-offset: calc(var(--border-thin, 1px) * -1);
}
.box * { color: inherit; }
.box[data-invert] { color: var(--color-light); background-color: var(--color-dark); }
```

### Center (ELC_CENTER)
```css
.center {
  box-sizing: content-box;
  max-inline-size: var(--measure, 65ch);
  margin-inline: auto;
  padding-inline: var(--gutter, 1rem);
}
```

### Cluster (ELC_CLUSTER)
```css
.cluster {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space, 1rem);
  justify-content: flex-start;
  align-items: center;
}
```

### Sidebar (ELC_SIDEBAR)
```css
.with-sidebar { display: flex; flex-wrap: wrap; gap: var(--space, 1rem); }
.with-sidebar > :first-child { flex-basis: var(--side-width, 20rem); flex-grow: 1; }
.with-sidebar > :last-child { flex-basis: 0; flex-grow: 999; min-inline-size: var(--content-min, 50%); }
```

### Switcher (ELC_SWITCHER)
```css
.switcher { display: flex; flex-wrap: wrap; gap: var(--space, 1rem); }
.switcher > * { flex-grow: 1; flex-basis: calc((var(--threshold, 30rem) - 100%) * 999); }
```

### Cover (ELC_COVER)
```css
.cover { display: flex; flex-direction: column; min-block-size: var(--min-height, 100vh); padding: var(--padding, var(--s1)); }
.cover > * { margin-block: var(--space, var(--s1)); }
.cover > :first-child:not(.principal) { margin-block-start: 0; }
.cover > :last-child:not(.principal) { margin-block-end: 0; }
.cover > .principal { margin-block: auto; }
```

### Grid (ELC_GRID)
```css
.grid {
  display: grid;
  gap: var(--space, 1rem);
  grid-template-columns: repeat(auto-fit, minmax(min(var(--min, 15rem), 100%), 1fr));
}
.grid[data-ragged] { align-items: start; }
```

### Frame (ELC_FRAME)
```css
.frame { aspect-ratio: var(--ratio, 16/9); overflow: hidden; display: flex; justify-content: center; align-items: center; }
.frame > img, .frame > video { inline-size: 100%; block-size: 100%; object-fit: cover; }
```

### Reel (ELC_REEL)
```css
.reel { display: flex; block-size: auto; overflow-x: auto; overflow-y: hidden; gap: var(--space, var(--s1)); }
.reel > * { flex: 0 0 var(--item-width, auto); }
.reel[data-overflowing] { padding-block-end: var(--s1); }
```

### Imposter (ELC_IMPOSTER)
```css
.imposter { position: absolute; inset-block-start: 50%; inset-inline-start: 50%; transform: translate(-50%, -50%); }
.imposter[data-contain] { --margin: var(--s1); overflow: auto; max-inline-size: calc(100% - (var(--margin) * 2)); max-block-size: calc(100% - (var(--margin) * 2)); }
```

### Icon (ELC_ICON)
```css
.icon { width: 0.75em; width: 1cap; height: 0.75em; height: 1cap; }
.with-icon { display: inline-flex; align-items: baseline; gap: var(--space, 0.5em); }
```

### Container (ELC_CONTAINER)
```css
.container { container-type: inline-size; container-name: var(--container-name, layout); }
```

---

## Chooser — Which Primitive?

### Five Decision Questions

1. **What type of spacing?** Vertical → Stack | Horizontal with wrap → Cluster | Grid of items → Grid
2. **How many elements?** Two (fixed+flex) → Sidebar | Two+ equal → Switcher | Many horizontal → Reel
3. **What kind of centering?** Horizontal + max-width → Center | Vertical on page → Cover | Overlay → Imposter
4. **Containment needs?** Padded region → Box | Aspect ratio → Frame | Container queries → Container
5. **Inline elements?** Icons with text → Icon

### "Should I use a media query?"

```
Is the change based on viewport?
├─ No → Don't use media query
└─ Yes → Can intrinsic layout achieve this?
    ├─ Yes → Use Switcher/Sidebar/Grid instead
    └─ No → Can container query achieve this?
        ├─ Yes → Use Container (ELC_CONTAINER)
        └─ No → Media query is acceptable (document why)
```

### Common Composition Patterns

| Pattern | Use Case |
|---------|----------|
| Stack + Center | Centered, vertically-spaced content |
| Sidebar + Stack | Navigation + main content |
| Grid + Box | Card grid with consistent padding |
| Cover + Center | Hero section with centered principal content |
| Reel + Frame | Horizontal gallery with aspect-ratio media |

> Full chooser with editorial recipes: `references/chooser.md`

---

## Constitution — Priority Hierarchy

When principles conflict, resolve in this order:

1. **Accessibility** (highest) — ELP_015, ELP_026, ELP_028, ELP_029
2. **Content Integrity** — ELP_027, ELP_006, ELP_004
3. **Intrinsic Behavior** — ELP_002, ELP_009, ELP_025, ELP_010, ELP_019–021
4. **Composition** — ELP_001, ELP_008
5. **Consistency** — ELP_005, ELP_011

Visual-coherence principles (ELP_016–018 theme-aware color; ELP_022–023 shadows; ELP_024 icon sizing) are owned by the `css-design-system` skill. When that skill is active, layer its priorities under this hierarchy.

### Key Conflict Resolutions

- **ELP_002 vs ELP_006**: Measure wins for text — readability over intrinsic sizing
- **ELP_009 vs ELP_013**: Algorithmic first — use container queries only when intrinsic fails
- **ELP_028 vs visual design**: Motion safety always wins — `prefers-reduced-motion` is non-negotiable

### Five Non-Negotiables

1. Cite primitive/principle IDs in every recommendation
2. Never invent primitives — only the 13 documented ones
3. Never use arbitrary values — all from modular scale
4. Always explain tradeoffs when choosing between options
5. Never skip traceability — every decision references its source

> Full conflict resolution rules: `references/constitution.md`

---

## Composition Quick Rules

| Step | Rule |
|------|------|
| 1. Choose primitives | Compose from existing 13. Never invent a new layout mechanism. |
| 2. Namespace properties | Prefix with component name: `--blockquote-space`, `--table-border-color` |
| 3. Add fallback values | Every `var(--token)` must include a hardcoded fallback: `var(--br-color-text, #000)` |
| 4. Test in all primitives | Verify the component works inside every primitive context |
| 5. Budget check | Enforce per-component and total system CSS limits from `css-design-system/references/performance-rules.md` |

> Full composition rules and known hazards: `references/composition-rules.md`

---

## Physical Properties — Quick Reference

| Physical | Logical |
|----------|---------|
| `width` / `height` | `inline-size` / `block-size` |
| `min-width` / `max-width` | `min-inline-size` / `max-inline-size` |
| `margin-left` / `margin-right` | `margin-inline-start` / `margin-inline-end` |
| `border-left` | `border-inline-start` |

**Accepted exceptions:** `translate` values, SVG `width`/`height` attributes, HTML `<img width="" height="">` attributes, `transform` functions.

> Full migration table: `references/physical-properties.md`

---

## Print Rules — Quick Reference

| Primitive | Print Behavior |
|-----------|---------------|
| Stack | Preserved (vertical rhythm translates to print) |
| Box | `break-inside: avoid`. Borders kept for grouping. |
| Center | Remove gutters (`padding-inline: 0`). Page margins handle spacing. |
| Cluster, Sidebar, Switcher | Linearise to single column (`flex-direction: column`) |
| Cover | Collapse `min-block-size` to `auto` |
| Grid | Force `grid-template-columns: 1fr` |
| Frame | Collapse `aspect-ratio: auto`, `object-fit: contain`, `max-block-size: 15cm` |
| Reel | Linearise to column, `overflow: visible` |
| Imposter | Collapse to `position: static` |
| Container | Remove containment (`container-type: normal`) |

> Full print rules: `references/print-rules.md`

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| `width: 300px` | Breaks responsiveness (ELP_002) | Use `min-inline-size` or `max-inline-size` |
| `@media` for columns | Couples to viewport (ELP_009) | Use Grid/Switcher/Sidebar |
| `gap: 17px` | Arbitrary value (ELP_005) | Use `var(--s1)` from scale |
| `margin-left` | Physical property (ELP_004) | Use `margin-inline-start` |
| Scroll jacking | Breaks browser delegation (ELP_010) | Native scroll + optional snap |
| Icon-only buttons | Missing accessible name (ELP_015) | Visible text + `aria-hidden` icon |
| Zoom prevention | WCAG 1.4.4 failure | Intrinsic sizing + `rem` units |
| Animations without motion gate | WCAG 2.3.3 failure (ELP_028) | `prefers-reduced-motion` reset |

> Detailed guides: `references/cookbook-antipatterns.md`

---

## Constraints

### Always Do
1. **Cite IDs** — Every primitive/principle reference includes its ID (e.g., "Use Stack (ELC_STACK)")
2. **Use Intrinsic Sizing** — Avoid fixed pixel dimensions (ELP_002)
3. **Apply Modular Scale** — Spacing from `--s-5` to `--s5` (ELP_005)
4. **Use Logical Properties** — `inline-*` and `block-*`, not `left`/`right` (ELP_004)
5. **Compose Primitives** — Combine simple ones, don't build monoliths (ELP_001)

### Never Do
1. **Invent primitives** — Only use the 13 documented primitives
2. **Use media queries for layout** — Prefer algorithmic approaches (ELP_009)
3. **Skip traceability** — Every recommendation references source
4. **Use arbitrary values** — All values from modular scale or documented tokens

---

## Performance Budget

Canonical source: [`css-design-system` skill → `references/performance-rules.md`](../css-design-system/references/performance-rules.md). The budget governs total system CSS (minified + gzipped), custom-property count, selector specificity, `calc()` nesting, and per-file size. Do not restate the numbers here — check the reference.

---

## Reference Files

Read these when you need deeper detail beyond the quick-reference above:

- `references/primitives.md` — Full specs for all 13 primitives (props, CSS, variants, edge cases)
- `references/principles.md` — Full specs for all layout principles with rationale and examples
- `references/hooks.md` — 75 memory hooks for quick recall
- `references/chooser.md` — Full 225-line decision tree with editorial recipe extensions
- `references/constitution.md` — Full priority hierarchy, all conflict resolutions, decision trees, code review checklist
- `references/cookbook-primitives.md` — Per-primitive deep-dive guides (13 entries)
- `references/cookbook-recipes.md` — Composition recipes: article-grid, card-grid, holy-grail, responsive-table, sidenotes, content-aware-has
- `references/cookbook-antipatterns.md` — Anti-pattern guides: fixed-widths, media-query-abuse, scroll-jacking, over-animation, icon-only-buttons, zoom-prevention, infinite-scroll
- `references/composition-rules.md` — Full composition rules, known hazards, editorial component composition (EDC_* patterns)
- `references/physical-properties.md` — Complete physical-to-logical migration table with all accepted exceptions
- `references/print-rules.md` — Full print rules for all primitives
- `references/form-patterns.md` — Canonical primitive compositions for form layouts (7 patterns + decision tree)
- `references/i18n-layout.md` — Per-primitive RTL and vertical writing mode behavior, edge cases, testing checklist
- `references/subgrid-patterns.md` — Subgrid composition patterns on top of ELC_GRID (5 patterns, ELP_021)
- `references/container-query-recipes.md` — When and how to use ELC_CONTAINER for component-level responsive design
- `references/editorial-craft.md` — Dramatic compositions using existing primitives: oversized type, full-bleed, pull quotes, sidenotes, data showcases
