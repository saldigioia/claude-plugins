# Composition Rules

Source: `decisions.md` §3

## Adding a New Component

| Step | Rule |
|------|------|
| 1. Choose primitives | Compose from existing 13. Never invent a new layout mechanism. |
| 2. Namespace properties | Prefix with component name: `--blockquote-space`, `--table-border-color` |
| 3. Add fallback values | Every `var(--token)` must include a hardcoded fallback: `var(--br-color-text, #000)` |
| 4. Test 13 compositions | Verify the component works inside every primitive (Stack, Box, Center, Cluster, Sidebar, Switcher, Cover, Grid, Frame, Reel, Imposter, Container) |
| 5. Test print | Verify it degrades under `print.css` linearisation |
| 6. Test accessibility | Verify semantic HTML, ARIA, keyboard, screen reader order |
| 7. Assign an ID | Pattern: `EDC_[NAME]` for editorial components |
| 8. Budget check | Enforce per-component and total system CSS limits from `css-design-system/references/performance-rules.md` |

## Known Composition Hazards

| Combination | Hazard | Rule |
|-------------|--------|------|
| Anything inside Frame | `overflow: hidden` clips content not sized to aspect ratio | Never place text-only components or Reel inside Frame |
| Reel inside Sidebar (narrow side) | Table/content will overflow | This is correct — Reel provides scroll. Required, not a bug. |
| Nested Centers | Inner Center's `--measure` cannot exceed outer | By design. `max-inline-size` is a ceiling. |
| Box wrapping Box | Borders and padding are additive | Intentional. Reduce inner `--padding`/`--border-width` if excessive. |
| `.box *` color inheritance | `color: inherit` forces color from Box, not from grandparent | Set color tokens on the `.box` element itself, not its wrapper |
| Grid[data-ragged] + Frame children | Frame forces equal height via aspect-ratio, defeating ragged intent | Never wrap Frame inside Grid[data-ragged]. Use bare `<img>` with `max-inline-size: 100%; block-size: auto`. |
| Grid with 100+ items | Browser lays out all items eagerly, blocking render | Add `content-visibility: auto` + `contain-intrinsic-size` on items |

## System Variants vs. Escape Hatches

Data-attribute modifiers on primitives (`data-ragged`, `data-invert`, `data-snap`, `data-no-stretch`, etc.) are **system variants**, not escape hatches. No `@escape` comment required. They follow the primitive's own logic with a single-property behavioral change.
