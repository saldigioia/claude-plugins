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

## Calc Chain Rule

The modular scale calc chain (`--s1: calc(var(--s0) * var(--ratio))`) MUST use `var(--ratio)`, never `var(--gl-ratio)`. This preserves the override-per-subtree pattern where setting `--ratio` on a container recalculates all `--s*` values for that subtree.

## Budget

| Metric | Limit |
|--------|-------|
| Custom properties across all files | 120 max |
| New tokens per feature addition | Must fit within 120 cap or justify raising it |
