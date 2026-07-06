# Baseline Registry — ELA_006 Feature Policy

Axiom **ELA_006** permits "CSS features only from stable browser baselines" —
this file is the operational form of that sentence, the way `escapes.md` is
the operational form of "exceptions are registered." Every non-universal
feature the plugin recommends appears here with its Baseline status and the
obligation that status carries. Statuses recorded **as of 2026-07**; when in
doubt, verify against MDN/webstatus.dev rather than trusting this table.

## The three statuses

| Status | Meaning | Obligation |
|---|---|---|
| **allowed** | Baseline *widely available* (~2+ years of full interop) | Use freely; no fallback required beyond good practice |
| **additive** | Baseline *newly available*, **and** the no-support experience is the full baseline experience | Use without an escape entry — but ONLY as an enhancement layered on working content (ELP_027). Never gate a must-work feature on it, and never wrap it in `@supports not (…)` (the archival gate flags that) |
| **escape-gated / watch** | Not Baseline (or availability is partial) | Production use requires an `escapes.md` entry with expiry; otherwise document-only ("watch") |

The governance rule: **a feature moves DOWN this table only via a MAJOR
version discussion; it moves UP whenever reality does** (update the row,
note it in the CHANGELOG — a PATCH).

## Registry

| Feature | Baseline | Status | Fallback obligation / notes |
|---|---|---|---|
| Logical properties (`inline-size` …) | widely (2021+) | allowed | — (ELP_004 mandates them) |
| `aspect-ratio` | widely (2023) | allowed | — |
| Flexbox `gap` | widely (2023) | allowed | — |
| `:focus-visible` | widely (2024) | allowed | — (ELP_029) |
| `<dialog>` | widely (2024) | allowed | `showModal()` one-liner is the documented ELA_005 JS boundary |
| `accent-color` | widely (2024) | allowed | — |
| `dvh` / `svh` viewport units | widely (2025) | allowed | Ship the two-declaration chain anyway (`100vh` line first, `100dvh` line second) — costs nothing, protects archival engines |
| Container queries + `cqi`/`cqw` units | widely (2025) | allowed | ELC_CONTAINER context required (ELP_020) |
| Subgrid | widely (2025) | allowed | ELP_021 patterns |
| `color-mix()` | widely (2025) | allowed | — |
| `:user-valid` / `:user-invalid` | widely (2025) | allowed | see `native-interaction.md` |
| `:has()` | widely (2026) | allowed | content-aware recipes in `cookbook-recipes.md` |
| `light-dark()` + `color-scheme` | newly (2024) | additive | Falls back per `color-theming.css` `@supports` blocks — keep those |
| `text-wrap: balance` | newly (2024) | additive | Unbalanced headings are fully functional (ELP_030) |
| `cap` unit | newly (2024) | additive | Always the two-declaration pair: `em` line first, `cap` line second (the shipped Icon recipe) |
| `<details name>` exclusive accordions | newly (2024) | additive | Without support: independent disclosures — still fully usable |
| Popover API (`popover`/`popovertarget`) | newly (2024) | additive | Without support: invoker button needs a `<details>`/link fallback for must-work UI; decorative popovers may simply not appear |
| Cross-document View Transitions (`@view-transition`) | newly (2024–2025) | additive | No support = instant normal navigation — the fallback IS the baseline (see `astro-site-architect/references/view-transitions.md`) |
| `lh` unit | newly (2024) | additive | Provide an `em`-based first declaration when used for rhythm |
| Scroll-driven animations (`animation-timeline`) | partial | escape-gated / watch | Also gated by `prefers-reduced-motion` (ELP_028); no layout may depend on it |
| CSS anchor positioning | partial | escape-gated / watch | The zero-JS replacement for floating-UI libraries — adopt the moment it reaches Baseline; until then Imposter (ELC_IMPOSTER) positions popovers |
| `interpolate-size` / `calc-size()` | partial | escape-gated / watch | `@supports`-gated enhancement only (see `native-interaction.md` accordion note) |
| `field-sizing: content` | partial | escape-gated / watch | `@supports`-gated; textareas remain resizable without it |
| CSS masonry / item flow | experimental | watch | Do not use; Grid (ELC_GRID) + `[data-ragged]` covers most cases |

## How this interacts with the gates

- `bin/css-strict.sh --archival` flags `@supports not (…)` — the registry's
  "additive" rule is why: enhancements are layered *on top of* the working
  baseline, never carved out of it.
- An **escape-gated** feature in production without an `escapes.md` row is an
  ELA_006 violation in review, even though no automated check exists yet for
  feature detection (see IMPROVEMENT-PLAN backlog).
- When a row is promoted to **allowed**, sweep the codebase for now-redundant
  `@supports` wrappers — but keep two-declaration fallback chains (they are
  free and archival-friendly).
