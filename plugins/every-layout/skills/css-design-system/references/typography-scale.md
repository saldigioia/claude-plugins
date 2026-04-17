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
