# Typography Scale Extensions

Source: `decisions.md` §9

## The "Small Text" Gap

The modular scale (ratio 1.5) jumps from `--s0` (1rem) to `--s-1` (0.667rem). Many UI elements need an intermediate size (~0.875rem). This is NOT in the scale.

| Token | Value | Use |
|-------|-------|-----|
| `--text-small` | `calc(var(--s0) * 0.875)` | UI metadata, captions, dates, bylines |
| `--text-label` | `calc(var(--s0) * 0.75)` | Uppercase labels, badges, source tags |

### Rules

- Use `--text-small` instead of repeating `calc(var(--s0) * 0.875)` inline.
- Use `--text-label` instead of repeating `calc(var(--s0) * 0.75)` inline.
- These are Tier 2 tokens (`--br-text-small`, `--br-text-label`) -- brands may override them.
- The raw `calc()` expressions are prohibited outside `:root`. Reference the token.

## Measure Variants

| Token | Value | Use |
|-------|-------|-----|
| `--measure` | `65ch` | Standard article body (frozen API) |
| `--measure-narrow` | `45ch` | Sidebar content, tight columns |
| `--measure-wide` | `80ch` | Full-width content areas, dashboards |

## The Heading-Tier Contract

A heading tier is a *rank*, and rank must be legible from the type alone. Three rules, all violated in one shipped field case (a 40px/700 h1 sitting above 48px/500 h2s, set in a cool near-black no other heading used):

1. **One ink and one family per tier.** Every h2 on the site shares one color token and one font family; so does every h3. A second near-identical ink inside one tier (`#111827` here, `#251f1b` there) is not a design decision — it is drift, and the near-duplicate token tripwire in `bin/css-strict.sh` prints exactly these pairs. One token per role; variants derive via `light-dark()`/relative color (ELP_018), never by hand-picking a second hex.

2. **Rank is monotonic.** The page title participates in the *same ramp* as its section titles: h1 ≥ h2 ≥ h3 in visual weight (the size × weight product, judged rendered). An h1 outranked by its own sections reads as a caption for the page. If the design wants a quiet page title, lower the whole ramp — do not invert it.

3. **The ramp is the scale.** Heading sizes come from the type-scale steps (`--step-*`), so the ratio between tiers is the system's ratio, not per-page taste. A tier that needs "just a bit bigger" than its step is asking for a new posture decision, not a one-off value.

The static gates can verify tokens and steps; whether the *rendered* rank actually reads monotonic is composition, judged by `/render-audit` (tier 4), not grep.
