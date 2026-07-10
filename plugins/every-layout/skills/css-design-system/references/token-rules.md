# Token Rules

Source: `decisions.md` §1

## Naming

| Rule | Example |
|------|---------|
| Tier 1 (global, invariant): `--gl-[category]-[property]` | `--gl-ratio`, `--gl-measure`, `--gl-border-thin` |
| Tier 2 (brand, overridable): `--br-[category]-[property]-[variant]` | `--br-color-surface`, `--br-type-heading-1` |
| Tier 3 (component instance): no prefix | `--space`, `--side-width`, `--threshold` |
| Categories: `color`, `type`, `space`, `border`, `font`, `focus`, `feedback` | |
| Variants: descriptive suffixes, not numbers | `--br-color-surface-raised` not `--br-color-surface-2` |
| States: append the state | `--br-color-interactive-hover` |

## Tier Assignment

| If the value is... | It belongs in... |
|---------------------|-----------------|
| A mathematical constant (ratio, measure, border width) | Tier 1 (`--gl-*`) |
| A semantic mapping that a brand would override (color, type role, font stack) | Tier 2 (`--br-*`) |
| A per-instance override set via inline `style` attribute | Tier 3 (no prefix) |

## Frozen API (never rename)

All Tier 3 properties. All `--s-5` through `--s5`. All `--step--2` through `--step-5`. Also `--border-thin`, `--border-thick`, `--color-dark`, `--color-light` (kept as aliases until removal in a future major version).

> **Naming clarification:** the Tier-1 table describes the `--gl-*` prefix as the *convention for new global tokens*, but the frozen API above predates it — the scale, measure, and border tokens are bare names (`--ratio`, `--s0`, `--measure`, `--border-thin`) and stay bare forever. The gates, the canonical stylesheet (`demos/every-layout.css`), and every fixture use the bare names. Do not "migrate" them to `--gl-*`.

## Calc Chain Rule

The modular scale calc chain (`--s1: calc(var(--s0) * var(--ratio))`) MUST use `var(--ratio)`, never `var(--gl-ratio)`. Change `--ratio` (or `--s0`) **at `:root`** and the entire scale recomputes — one knob, verified in-browser (2026-07-07).

**What the chain does NOT do:** custom properties inherit as their *computed* values, so `--s1` reaches descendants with the ratio already baked in — setting `--ratio` alone on a container changes nothing (this was previously misdocumented here as an "override-per-subtree pattern"). To rescale a subtree, re-declare the chain on it:

```css
.rescale {
  /* --ratio set inline or here; the chain re-derives from it locally */
  --s-1: calc(var(--s0) / var(--ratio));
  --s1: calc(var(--s0) * var(--ratio));
  --s2: calc(var(--s1) * var(--ratio));
  /* …extend to the stops the subtree actually uses */
}
```

## Near-Duplicate Tokens Are Drift

Two distinct tokens holding *almost* the same color (`--ink-heading: #111827` here, `--ink-display: #251f1b` there) are not two decisions — they are one decision made twice, slightly differently, usually months apart. The reader sees one muddy near-black that never quite matches itself; the maintainer sees two tokens with no rule for which applies. One token per role; derive variants with `light-dark()`/relative color (ELP_018), and if two roles genuinely share an ink, alias one token to the other (identical values are fine — the tripwire ignores exact aliases).

`bin/css-strict.sh` prints a warn-tier pair report when two distinct hex-literal tokens sit within a max per-channel delta of 16 (documented limits: bare `#rrggbb`/`#rgb` values only — `light-dark()`/`oklch()`-wrapped tokens are not compared; a tripwire, not colorimetry). A warned pair is either merged, aliased, or consciously kept — silently shipping it is the drift.

## Budget

| Metric | Limit |
|--------|-------|
| Custom properties across all files | 120 max |
| New tokens per feature addition | Must fit within 120 cap or justify raising it |
