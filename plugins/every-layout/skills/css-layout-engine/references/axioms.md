# Axioms — The Requirements

> These are not recommendations. They are the requirements any codebase adopting this plugin commits to. Every skill, agent, command, and eval in this plugin treats them as load-bearing. The `/strict-check` skill and `bin/css-strict.sh` script exit non-zero when any axiom is violated.

The axioms are distilled from Andy Bell and Heydon Pickering's *Every Layout*, with chapter citations. They express a single commitment: **simple, durable, CSS-dominant web design**.

---

## ELA_001 — Algorithmic Layout

**Every layout must wrap and reconfigure intrinsically. Media queries are manual overrides, not the first tool.**

> "Each layout in Every Layout is intrinsically responsive. That is, it will wrap and reconfigure internally to make sure the content is visible (and well-spaced) to fit any context/screen. You may feel compelled to add @media query breakpoints, but these are considered 'manual overrides' and Every Layout primitives do not depend on them."
> — *Every Layout*, Composition (ch. 5)

**Enforcement:** `bin/css-strict.sh` fails when `@media` queries target layout properties (`grid-template-*`, `flex-direction`, `width`, `display`). Intrinsic primitives (ELC_GRID auto-fit, ELC_SIDEBAR flex-basis, ELC_SWITCHER threshold) cover 95 % of cases. The rest lives in `escapes.md` with a justification.

**Violates:** ELP_009

---

## ELA_002 — Designing Without Seeing

**Write programs that generate layouts; do not design fixed artefacts. Surrender to the browser's algorithms.**

> "Fundamentally, designing for the web is designing without seeing. You simply can't anticipate all of the visual combinations produced by the modular placement of your layout components and the circumstances and settings of each end user's setup. Instead of thinking of designing for the web as creating visual artefacts, think of it as writing programs for generating visual artefacts."
> — *Every Layout*, Axioms (ch. 9)

**Enforcement:** `bin/css-strict.sh` fails on physical properties (`width`, `height`, `margin-left/right/top/bottom`, `padding-left/right/top/bottom`). Fixed pixel values (`[0-9]+px`) outside the accepted list (`1px|2px|3px` for borders) are failures, not warnings.

**Violates:** ELP_002, ELP_004

---

## ELA_003 — Exception-Based Styling

**Global rules reach far; classes reach narrowly. Specificity is inversely proportional to the number of elements a rule should affect.**

> "An exception-based approach to CSS lets us do most of our styling with the least of our code. [...] In Harry Roberts' ITCSS (Inverted Triangle CSS) thesis, specificity (how specific selectors are) is inversely proportional to reach (how many elements they should affect)."
> — *Every Layout*, Axioms (ch. 9)

**Enforcement:** `bin/css-strict.sh` fails when a file contains `!important`, ID selectors, or any selector exceeding the 0-2-0 specificity cap. Class-based styling is permitted only when a global rule (element or `:root` custom property) cannot express the intent.

**Violates:** ELP_011, budget rule "Max selector specificity 0-2-0"

---

## ELA_004 — Axiomatic Values

**Every value in the system derives from a named axiom. Arbitrary numbers are forbidden.**

> "Instead of thinking of designing for the web as creating visual artefacts, think of it as writing programs for generating visual artefacts. Axioms are the rules that influence how those artefacts are created by the browser, and the better thought out they are the better the browser can accommodate the user."
> — *Every Layout*, Axioms (ch. 9)

**Enforcement:** `bin/css-strict.sh` fails on numeric values outside the modular scale (`--s-5`..`--s5`), the type scale (`--step--2`..`--step-5`), or the accepted-border set (`1px`, `2px`, `3px`). The `ch` and `cap` units are permitted because they are algorithmic (derived from the font, not the designer).

**Violates:** ELP_005

---

## ELA_005 — CSS-Dominant Composition

**Layout is a CSS problem. JavaScript participates only as progressive enhancement, and only when CSS cannot express the intent.**

This axiom is the plugin's defining commitment. Plugins exist that promote utility classes, that promote framework-specific styling primitives, that promote CSS-in-JS. This one does not. If a layout can be done with CSS and semantic HTML alone, it must be.

**Enforcement:** `bin/js-budget.sh` fails when the page-level JavaScript budget is exceeded. Default budget is **15 KB compressed per route, 30 KB page-total** (framework runtime + islands combined). Exceeding the budget requires either:

1. Removing JavaScript until under budget
2. Adding an entry to `escapes.md` with category `ESC_JS_EXCESS`, a justification, and an expiry date
3. Raising the budget in `performance-rules.md` with a CHANGELOG note explaining the product decision

Every island must justify its hydration directive. `client:load` requires registry in `escapes.md`.

**Violates:** ELP_028 (if animation requires JS) and the plugin's root commitment

---

## ELA_006 — Archival Durability

**Code written under this plugin must still render, animate, and navigate in five years with a 2026-era browser update cadence and no maintenance.**

**Enforcement:** Three derived rules:

1. **No breaking dependencies at runtime.** Layout does not depend on a JS framework version. Upgrading React from 18 to 20 must not change the rendered layout.
2. **Progressive enhancement for every interaction.** Every link, form, and navigation works with JS disabled or failed. `<a href>` before `onClick`; `<form method="post">` before `fetch`.
3. **CSS features only from stable browser baselines.** `light-dark()`, logical properties, `:focus-visible`, subgrid, container queries are permitted (Baseline 2024+). Proposed / unflag-only features require an escape-hatch entry with expiry.

**Verification:** `bin/css-strict.sh --archival` additionally flags `content-visibility: auto` on primary content, CSS nesting deeper than 2, and any `@supports (not` wrapper used to gate "must work" features.

---

## Axiom hierarchy

When axioms conflict:

1. **ELA_006 (Archival Durability)** wins — the code must still work.
2. **ELA_005 (CSS-Dominant)** wins next — JavaScript participates only where necessary.
3. **ELA_001 (Algorithmic)** wins next — intrinsic layout beats breakpoints.
4. **ELA_002 (Designing Without Seeing)** and **ELA_004 (Axiomatic Values)** govern the specifics.
5. **ELA_003 (Exception-Based Styling)** governs where rules live.

## The plugin's stance

Every skill in this plugin presumes the axioms. Every agent enforces them. The `/strict-check` skill and `bin/css-strict.sh` script convert the presumption into a machine-verifiable gate. A project that adopts this plugin adopts the axioms — not as style, but as contract.
