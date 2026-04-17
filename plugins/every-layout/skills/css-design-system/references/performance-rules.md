# Performance Rules — Canonical Budget Source

> This file is the single source of truth for the Every Layout performance budget (CSS **and** JavaScript). All other mentions in the corpus should cross-reference this file, not re-state the numbers. Update here first; update CLAUDE.md and README snapshots second.
>
> The `bin/css-strict.sh` and `bin/js-budget.sh` scripts read these numbers and exit non-zero when any limit is exceeded. Raising a limit requires a CHANGELOG entry with a product justification — budgets are contracts.

## Limits

| Rule | Limit |
|------|-------|
| Total system CSS (minified) | 34 KB |
| Total system CSS (gzipped) | 8.5 KB |
| Per-file minified | 10 KB |
| Max selector specificity | 0-2-0 (no IDs, no `!important`) |
| Max `calc()` nesting | 2 levels |
| Max `var()` references per rule block | 8 |
| `font-display` | Use `optional` (not `swap`) when `--measure` uses `ch` units (ELP_032) |
| Web fonts | Must ship `@font-face` with `size-adjust` and `ascent-override` (ELP_032) |
| `@import` | Prohibited. Use `<link>` elements only. |
| Per-element scale recalculation | Prohibited. Never `calc(var(--s1) * var(--ratio))` inside a component rule. Reference pre-computed `--s*` tokens. |

## Critical CSS Split

| Bundle | Contents | Loading |
|--------|----------|---------|
| Critical inline (~1.2 KB) | `:root` scale tokens + `.center` + `.stack` + border-box reset + base surface color | Inline in `<head>` |
| Core async | Remaining primitives + fluid-type.css | `rel="preload"` |
| Theme + print (lazy) | color-theming.css + print.css | `requestIdleCallback` or `media="print"` |

## JavaScript Budget — axiom ELA_005

Per the plugin's root commitment to CSS-dominant web design, every page has a hard JavaScript budget. **CSS is the first tool; JavaScript is the exception, and must justify itself.**

| Rule | Limit |
|------|-------|
| Per-route JS (compressed, counts client-rendered components + framework runtime) | 15 KB |
| Page total JS (all routes combined on a single page view, compressed) | 30 KB |
| `client:load` directives | Prohibited without an entry in `escapes.md` category `ESC_JS_EAGER` |
| Third-party scripts (analytics, chat, ads) | Counted against the per-route budget; no exceptions |
| Inline `<script>` tags | Counted; prefer `<script type="module">` + external file so it can cache |
| JS frameworks as styling layer (CSS-in-JS, styled-components) | Prohibited. CSS lives in CSS. |
| JS for layout (computing widths, measuring content, resize observers for layout decisions) | Prohibited. Use intrinsic CSS primitives (ELC_*). |

### Measurement

`bin/js-budget.sh <dist-dir>` measures the real compressed size of every `.js` file Astro emits into a build output, grouped by route, and reports pass/fail per route and page-total. It exits non-zero on any failure. The script is the enforcement surface — the numbers above are the contract.

### Escape hatches

Budget overages are not bugs; they are product decisions. Register them:

```markdown
## ESC_JS_EXCESS — /app/dashboard route
Author: @you
Date: 2026-05-01
Expires: 2026-08-01 (review quarterly)
Budget override: 45 KB per-route (vs 15 KB default)
Justification: Real-time chart library required for live data view. CSS-only
  alternatives evaluated (SVG static + progressive-enhancement poll): rejected
  because users need <1s update cadence. Will re-evaluate after SDK ships.
Review owner: @team-lead
```

Without an entry, `bin/js-budget.sh` fails CI and the build does not ship.
