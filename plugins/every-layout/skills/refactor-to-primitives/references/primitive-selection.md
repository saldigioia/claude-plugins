# Primitive Selection During Refactoring

Shortcut guide for the common "which primitive replaces this block" decisions. For the full decision tree, use `skills/choose-primitive` — this file only covers the high-frequency cases you hit during refactors.

## Vertical spacing
**ELC_STACK** when siblings need consistent vertical gaps. Configure `--space: var(--s1)` (or per-context).

## Horizontal layouts
- **ELC_CLUSTER** — inline items that wrap naturally (tags, buttons, chips)
- **ELC_SIDEBAR** — one fixed + one flexible (nav + content)
- **ELC_SWITCHER** — equal columns that fold to rows under a container width threshold

## Grids
**ELC_GRID** — equal-width responsive columns via `auto-fit` + `minmax(min(--min, 100%), 1fr)`. Default `--min: 15rem`.

## Centering
- **ELC_CENTER** — horizontal centering with a measure cap (`max-inline-size: var(--measure, 65ch)`)
- **ELC_COVER** — vertical centering on a full-viewport shell (header/main/footer spine)
- **ELC_IMPOSTER** — overlay / modal centering over arbitrary content

## Containment & aspect
- **ELC_BOX** — padded and/or bordered region (use for cards, callouts)
- **ELC_FRAME** — aspect-ratio for media and embeds
- **ELC_CONTAINER** — establish a container-query context for a component

## Inline
**ELC_ICON** — an icon paired with text; sizes from typography units per ELP_024.

---

## When to reach for a combination

Almost never during a refactor. If you're tempted, first check whether one primitive can do the job. See `combinations.md` in the `choose-primitive` skill for the rare pairings that earn their keep.

## Principle ID cheat-sheet

| If the before-code has... | Cite... |
|---|---|
| `width: \d+px` on a container | ELP_002 (Intrinsic Sizing) |
| `@media (min-width:...)` gating layout | ELP_009 (Algorithmic Layout) |
| numeric spacing values | ELP_005 (Modular Scale) |
| `margin-left/right`, `padding-top/bottom`, `width/height` | ELP_004 (Logical Properties) |
| `transition` or `animation` without `prefers-reduced-motion` | ELP_028 (Motion Safety) |
| `outline: none` on focusable elements | ELP_029 (Focus Visibility) |
