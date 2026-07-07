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

One deliberate sharp edge: a complete no-support fallback does **not** by
itself waive registration for a non-Baseline feature — it only makes the
escape trivially justifiable (one line, zero risk). The tier measures engine
interop (ELA_006's concern); degradation quality is a separate virtue. This
resolves the 2026-07-07 question for cross-document View Transitions:
escape-gated despite its perfect fallback, until Firefox ships unflagged.

## Registry

| Feature | Baseline | Status | Fallback obligation / notes | Last verified |
|---|---|---|---|---|
| Logical properties (`inline-size` …) | widely (2021+) | allowed | — (ELP_004 mandates them) | 2026-07-07 |
| `aspect-ratio` | widely (2021) | allowed | — | 2026-07-07 |
| Flexbox `gap` | widely (2023) | allowed | — | 2026-07-07 |
| `:focus-visible` | widely (2024) | allowed | — (ELP_029) | 2026-07-07 |
| `<dialog>` | widely (2024) | allowed | `showModal()` one-liner is the documented ELA_005 JS boundary | 2026-07-07 |
| `accent-color` | **not Baseline** | **escape-gated / watch** | Safari has never fully shipped contrast-adjustment on control marks (WebKit bug tracked since 2022; still blocking Baseline as of the most recent web-features tracker discussion) — form controls remain legible without it, so gate production use via `escapes.md` | 2026-07-07 |
| `dvh` / `svh` viewport units | widely (2025) | allowed | Ship the two-declaration chain anyway (`100vh` line first, `100dvh` line second) — costs nothing, protects archival engines | 2026-07-07 |
| Container queries + `cqi`/`cqw` units | widely (2025) | allowed | ELC_CONTAINER context required (ELP_020) | 2026-07-07 |
| Subgrid | widely (2026) | allowed | ELP_021 patterns | 2026-07-07 |
| `color-mix()` | widely (2025) | allowed | — | 2026-07-07 |
| `:user-valid` / `:user-invalid` | widely (2026) | allowed | see `native-interaction.md` | 2026-07-07 |
| `:has()` | widely (2026) | allowed | content-aware recipes in `cookbook-recipes.md` | 2026-07-07 |
| `overflow: clip` | widely (2025) | allowed | Clips without creating a scroll container — see `failure-mechanics.md` trap 7 | 2026-07-07 |
| `overflow-clip-margin` | **not Baseline** | **escape-gated / watch** | Safari has not shipped this property at all — the inset-focus-ring escape only works where support exists; prefer non-inset rings and gate the enhancement via `escapes.md`, not as an unconditional additive layer | 2026-07-07 |
| `light-dark()` + `color-scheme` | newly (2024) | additive | Falls back per `color-theming.css` `@supports` blocks — keep those. Projected widely-available ~Nov 2026 | 2026-07-07 |
| `text-wrap: balance` | newly (2024) | additive | Unbalanced headings are fully functional (ELP_030) | 2026-07-07 |
| `cap` unit | newly (2023) | additive | Always the two-declaration pair: `em` line first, `cap` line second (the shipped Icon recipe) | 2026-07-07 |
| `<details name>` exclusive accordions | newly (2025) | additive | Without support: independent disclosures — still fully usable | 2026-07-07 |
| Popover API (`popover`/`popovertarget`) | newly (2025) | additive | Newly-available date is January 2025, not 2024 — an earlier April 2024 announcement was retracted over a Safari/iOS light-dismiss bug. Without support: invoker button needs a `<details>`/link fallback for must-work UI; decorative popovers may simply not appear | 2026-07-07 |
| Cross-document View Transitions (`@view-transition`) | **not Baseline** | **escape-gated / watch** | Firefox still ships this behind a flag and ignores the `@view-transition` at-rule; only Chromium and Safari animate it today. No support = instant normal navigation, so the enhancement is safe to ship, but it does not yet meet the 3-engine bar for "additive" — register it in `escapes.md` (see `astro-site-architect/references/view-transitions.md`) | 2026-07-07 |
| `lh` unit | widely (2026) | allowed | Provide an `em`-based first declaration when used for rhythm — the fallback chain remains good practice even after promotion to "allowed" | 2026-07-07 |
| Scroll-driven animations (`animation-timeline`) | partial | escape-gated / watch | Also gated by `prefers-reduced-motion` (ELP_028); no layout may depend on it. Still blocked on Firefox, which ships it only behind a flag | 2026-07-07 |
| CSS anchor positioning | newly (2026) | additive | Completed 3-engine support in January 2026 (Firefox 147); still rough at the edges (fixed-position + Safari `@position-try` quirks) — treat as an enhancement only. Imposter (ELC_IMPOSTER) remains the fallback for popovers until the edge cases settle | 2026-07-07 |
| `interpolate-size` / `calc-size()` | partial | escape-gated / watch | `@supports`-gated enhancement only (see `native-interaction.md` accordion note); still Chromium-only | 2026-07-07 |
| `field-sizing: content` | partial | escape-gated / watch | `@supports`-gated; textareas remain resizable without it. Firefox support is only landing in 2026; widely-available not projected until 2028 | 2026-07-07 |
| CSS masonry / item flow | experimental | watch | Do not use; Grid (ELC_GRID) + `[data-ragged]` covers most cases. Spec is converging on an `item-flow`-based approach but engines diverge (Safari shipped, Chrome/Firefox still behind flags) | 2026-07-07 |

Re-verify rows at every release (see CLAUDE.md release checklist).

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
