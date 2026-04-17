---
name: css-design-system
description: "CSS design system: tokens (--gl-*, --br-*), light-dark() theming, @layer ordering, fluid typography, motion allowlist, focus rings, escape hatches, editorial components, performance budget, skip links, reduced motion, brand contracts."
allowed-tools: Read Grep Glob Write Edit
paths:
  - "**/tokens/**"
  - "**/design-tokens/**"
  - "**/styles/global.*"
  - "**/styles/tokens.*"
  - "**/styles/brand.*"
  - "**/styles/theme.*"
  - "**/*.css"
---

# CSS Design System

The CSS Design System extends the Every Layout primitives with a visual and behavioral layer: design tokens, color theming, fluid typography, editorial components, and accessibility patterns. It references the Layout Engine's primitives by name and ID but does not redefine their CSS.

> **Axiomatic commitment.** Every recommendation in this skill presumes the axioms in `skills/css-layout-engine/references/axioms.md`. Specifically: axiom **ELA_004** (Axiomatic Values) governs every token value here; **ELA_005** (CSS-Dominant Composition) forbids CSS-in-JS and styling via framework runtime. Budget overages require an entry in `escapes.md`, not a CHANGELOG apology.

---

## Layout Primitive Quick Reference

| ID | Primitive |
|----|-----------|
| ELC_STACK | Stack |
| ELC_BOX | Box |
| ELC_CENTER | Center |
| ELC_CLUSTER | Cluster |
| ELC_SIDEBAR | Sidebar |
| ELC_SWITCHER | Switcher |
| ELC_COVER | Cover |
| ELC_GRID | Grid |
| ELC_FRAME | Frame |
| ELC_REEL | Reel |
| ELC_IMPOSTER | Imposter |
| ELC_ICON | Icon |
| ELC_CONTAINER | Container |

> For primitive CSS and layout rules, see the **css-layout-engine** skill.

---

## Current Project Tokens

```!
find . -name "*.css" -path "*/tokens/*" -o -name "*.css" -path "*/global/*" | head -5 | xargs grep -h "^  --" 2>/dev/null | head -20
```

---

## Three-Tier Token Architecture

All custom properties belong to one of three tiers:

| Prefix | Tier | Purpose |
|--------|------|---------|
| `--gl-*` | 1 -- Global | Mathematical constants (ratio, measure, border widths). Invariant across brands. |
| `--br-*` | 2 -- Brand | Semantic mappings (color, type, spacing aliases). Overridden per brand via `[data-brand]`. |
| (none) | 3 -- Component | Instance API (`--space`, `--padding`, etc.). Frozen; never renamed. |

**Brand token interface** -- every brand file MUST define these 9 tokens:
`--br-color-surface`, `--br-color-surface-raised`, `--br-color-text`, `--br-color-text-muted`, `--br-color-accent`, `--br-color-interactive`, `--br-color-focus`, `--br-font-body`, `--br-font-heading`.

**Budget:** 120 custom properties max across all files.

> Full token rules: `references/token-rules.md`

---

## Layer Ordering

```css
@layer global, brand, components, bespoke.legacy, bespoke.dataviz, bespoke.editorial, bespoke.embed;
```

Consumer CSS remains **unlayered** (highest priority by design).

> Full layer rules: `references/layer-rules.md`

---

## Color Theming

Uses `light-dark()` for automatic dark-mode support. Surface elevation derived from `--gl-elevation-step`.

### Key Principles

| ID | Principle |
|----|-----------|
| ELP_016 | Theme-Aware Color Tokens — `light-dark()` + `color-scheme` |
| ELP_017 | Surface Elevation via Lightness — lightness increment in dark mode |
| ELP_018 | Derived Color Variants — relative colors with `calc()` |

### Token Groups

- **Surface**: `--br-color-surface`, `--br-color-surface-raised`, `--br-color-surface-overlay`
- **Text**: `--br-color-text`, `--br-color-text-heading`, `--br-color-text-muted`
- **Border**: `--br-color-border`, `--br-color-border-strong`
- **Interactive**: `--br-color-interactive` (+ `-hover`, `-active`, `-visited`), `--br-color-focus`
- **Feedback**: `--br-color-success`, `--br-color-warning`, `--br-color-error`, `--br-color-info`

> Implementation note: The `--br-color-*` names are the target architecture. The current `color-theming.css` still uses original names as aliases during transition. See `references/token-rules.md` for migration rules.

> Reference CSS: `references/color-theming.css`

---

## Shadow Design System

| ID | Principle |
|----|-----------|
| ELP_022 | Consistent Shadow Light Source — same offset ratio for all shadows |
| ELP_023 | Layered Shadow Realism — multiple shadows with progressive blur |

Layer multiple shadows with progressively increasing values. As elevation increases: offset larger, blur larger, opacity lower. Color-match shadows to background hue rather than transparent black.

---

## Fluid Typography

**Step scale** (viewport-responsive via `clamp()`): `--step--2` through `--step-5` (8 steps total, frozen API).

Use `font-display: optional` to prevent `ch`-unit CLS when Center uses `--measure` (ELP_032). If brand fonts required on first paint, ship `@font-face` with `size-adjust` and `ascent-override`.

**Semantic aliases** (Tier 2, brand-overridable):

| Token | Maps To | Role |
|-------|---------|------|
| `--br-type-display` | `--step-5` | Hero / display headings |
| `--br-type-heading-1` | `--step-4` | H1 |
| `--br-type-heading-2` | `--step-3` | H2 |
| `--br-type-heading-3` | `--step-2` | H3 |
| `--br-type-body` | `--step-0` | Body text |
| `--br-type-caption` | `--step--1` | Small / metadata |

```css
h1 { font-size: var(--br-type-heading-1); }
```

**Small text gap** (fills the scale gap between `--s0` and `--s-1`):

| Token | Value | Use |
|-------|-------|-----|
| `--text-small` / `--br-text-small` | `calc(var(--s0) * 0.875)` | UI metadata, captions, dates |
| `--text-label` / `--br-text-label` | `calc(var(--s0) * 0.75)` | Uppercase labels, badges |

> Full typography extensions: `references/typography-scale.md`
> Reference CSS: `references/fluid-type.css`
> Font pairings (10 canonical pairs, loading strategy): `references/typography-pairing.md`

---

## Component Architecture

| ID | Principle |
|----|-----------|
| ELP_024 | Typography-Relative Icon Sizing — `height: 1.2cap` or `1em` |

**Configuration block pattern:** Group all variant-configurable custom properties at component start. Use `data-*` attributes (not classes) for state variants.

---

## Editorial Components (EDC_*)

Four compositions built entirely from existing primitives. No new primitives.

| ID | Component | Primitives Used | Key Markup |
|----|-----------|-----------------|------------|
| EDC_BLOCKQUOTE | Blockquote | Stack + Box | `<blockquote cite="..." lang="...">` with `<footer>` / `<cite>` |
| EDC_PULLQUOTE | Pull-quote | Center + Box + Stack | `<aside aria-hidden="true">` -- ONLY when text already in article body |
| EDC_FIGURE | Figure + Caption | Stack + Frame | `<figure>` with `<figcaption><small>` |
| EDC_DATATABLE | Data Table | Reel + optional Icon | `<div class="reel">` wrapping `<table>` with `<caption>`, `scope` on all `<th>` |

> Full semantic HTML rules: `references/semantic-html.md`
> Universal image/media rules (CLS, lazy loading, aspect): `references/image-media.md`
> Visual texture (layered shadows, gradients, blend modes, backdrop filters): `references/css-texture.md`
> Density postures (compact / default / spacious scale mappings): `references/density-patterns.md`

---

## Escape Hatch Protocol

Deviations from the system are permitted only through escape hatches.

### Four Categories

| Code | Use Case | Containment Layer |
|------|----------|-------------------|
| `ESC_EDITORIAL` | Campaign pages, art-directed longforms | `@layer bespoke.editorial` |
| `ESC_EMBED` | Third-party iframes, widgets, ad units | `@layer bespoke.embed` |
| `ESC_DATAVIZ` | Charts, maps, coordinate-based layouts | `@layer bespoke.dataviz` |
| `ESC_LEGACY` | Pre-migration subsystems (requires migration ticket) | `@layer bespoke.legacy` |

### Required Markers

1. **HTML**: `data-bespoke="{category}"` attribute on root element
2. **CSS**: All selectors inside `@layer bespoke.*`, descending from `[data-bespoke]`
3. **Comment**: `/* @escape ESC_{CATEGORY} ... */` with author, date, justification

### Non-Negotiable Rules (enforced even inside escape hatches)

- **ELP_003** -- Universal border-box
- **ELP_028** -- Reduced motion
- **ELP_029** -- Focus visibility

### Conditional Exceptions

- ELP_004 (Logical Properties): physical properties OK inside `[data-bespoke="dataviz"]` for coordinate axes
- ELP_005 (Modular Scale): arbitrary values OK inside bespoke boundary; modular scale required for outer spacing

### Audit Threshold

If escape-hatch instances exceed **15%** of component count, trigger governance review.

> Full escape hatch rules: `references/escape-hatches.md`
> Registry convention for documenting intentional deviations: `references/escape-hatch-registry.md`

---

## Accessibility Patterns

### Required on Every Page
- Skip link (`<a href="#main">` with `clip-path: inset(50%)` until focus)
- Main landmark (`<main id="main">`)
- Language attribute (`<html lang="en">`)
- Color scheme (`color-scheme: light dark` on `:root`)

### Interactive Elements
- Focus ring: `:focus-visible { outline: 3px solid var(--color-focus); outline-offset: 2px; }`
- Hover reveal: both `:hover` AND `:focus-visible` required
- Active press: `translate: 0 1px` on `:active`
- Disabled: `opacity: 0.5; pointer-events: none;` with `aria-disabled="true"`

### SVG Icons
- Decorative: `aria-hidden="true" focusable="false"`
- Meaningful: `role="img" aria-labelledby="title-id"` with `<title>` + `<desc>`

> Full accessibility patterns: `references/accessibility.md`

---

## Performance Budget

This skill owns the canonical performance budget. Do not duplicate the numbers here — the single source of truth is [`references/performance-rules.md`](references/performance-rules.md), which covers total system CSS (minified + gzipped), custom-property count, selector specificity, `calc()` nesting, per-file and per-component limits, `@import` prohibition, `font-display` policy, and the critical-CSS split (inline + async + lazy).

When reviewing or reporting budget compliance, read and cite that file. Do not hard-code thresholds in SKILL bodies, commands, or agents — link to the canonical source.

> Full performance rules: `references/performance-rules.md`

---

## z-index Stacking Context

| Layer | Token | Value |
|-------|-------|-------|
| Base content | `--z-base` | `0` |
| Sticky header | `--z-sticky` | `10` |
| Dropdown/popover | `--z-dropdown` | `20` |
| Overlay | `--z-overlay` | `30` |
| Modal | `--z-modal` | `40` |
| Toast | `--z-toast` | `50` |
| Skip link | `--z-skip` | `60` |

Never use arbitrary z-index values. Pick from the scale.

> Full z-index rules: `references/z-index.md`

---

## Transitions and Animations

| Token | Value | Use |
|-------|-------|-----|
| `--transition-fast` | `0.1s` | Hover color/opacity |
| `--transition-normal` | `0.2s` | Expand/collapse, toast |
| `--transition-slow` | `0.4s` | Page transitions, skeleton fade |

Gate every transition with `@media (prefers-reduced-motion: no-preference)` so motion applies only to users who have not requested reduced motion. Separately, provide a `@media (prefers-reduced-motion: reduce)` reset that zeros animation durations when users opt out.

> Full transition/animation rules: `references/transitions.md`
> Allowed transition properties (opacity, transform, color, background-color, outline-color, box-shadow) and forbidden-property list: `references/motion-allowlist.md`

---

## Reference Files

| File | Content |
|------|---------|
| `references/token-rules.md` | Full token naming, tiers, frozen API, calc chain rules |
| `references/layer-rules.md` | Layer ordering, brand nesting, consumer sizing |
| `references/escape-hatches.md` | Full escape hatch rules with byte limits |
| `references/performance-rules.md` | Full performance spec with critical CSS split |
| `references/semantic-html.md` | Editorial component semantic HTML (EDC_* only) |
| `references/z-index.md` | z-index stacking context scale |
| `references/typography-scale.md` | Small text gap, measure variants |
| `references/transitions.md` | Duration scale, micro-interactions, motion safety |
| `references/accessibility.md` | Full accessibility patterns |
| `references/image-media.md` | Universal image/media rules (CLS, lazy loading) |
| `references/color-theming.css` | Reference CSS implementation |
| `references/fluid-type.css` | Reference CSS implementation |
| `references/density-patterns.md` | Compact/default/spacious density postures with scale mappings |
| `references/motion-allowlist.md` | Allowed transition properties, durations, easings, and forbidden patterns |
| `references/escape-hatch-registry.md` | Convention for documenting intentional principle violations |
| `references/typography-pairing.md` | 10 canonical font pairings mapped to postures, fallback stacks, loading strategy |
| `references/css-texture.md` | CSS-only visual richness: layered shadows, gradients, patterns, blend modes, backdrop filters |

---

*For layout primitives, modular scale, and composition patterns, see the **css-layout-engine** skill.*
