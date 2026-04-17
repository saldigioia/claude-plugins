# Prompt: CSS Design System

## Purpose

Evaluate a CSS design-system layer against the `css-design-system` skill. Focuses on token architecture, color theming, fluid typography, layer ordering, escape hatches, motion safety, focus visibility, and the canonical performance budget (see `skills/css-design-system/references/performance-rules.md`).

## Prompt Template

```
Evaluate the following design-system CSS against the css-design-system skill.

STYLES:
[Paste CSS — typically global.css, tokens.css, or theme.css]

HTML (optional):
[Paste HTML using the system]

EVALUATION REQUIREMENTS:

1. Token Architecture
   - Three tiers used (--gl-*, --br-*, component-level)
   - Brand tokens re-map globals, not invent new numbers
   - No duplicated token scales across tiers
   - No arbitrary values outside the modular scale --s-5..--s5

2. @layer ordering
   - Declared order: global, brand, components, bespoke.*
   - Bespoke sublayers documented in escapes.md if used
   - No CSS outside layers

3. Color theming
   - light-dark() used (ELP_016)
   - color-scheme declared on :root
   - Dark-mode elevation via lightness (ELP_017), not shadows
   - Derived variants use relative color (ELP_018), not hard-coded lighter/darker values

4. Fluid typography
   - --step--2 through --step-5 scale present
   - Semantic aliases (--br-type-body, etc.) map to scale
   - font-display: optional when Center uses --measure (ELP_032)

5. Motion
   - Transitions gated by @media (prefers-reduced-motion: no-preference)
   - Separate @media (prefers-reduced-motion: reduce) reset with 0.01ms durations
   - Only allowlist properties transitioned (opacity, transform, color, background-color, outline-color, box-shadow)
   - No transition: all; no transition-duration: 0s

6. Focus visibility
   - :focus-visible styled with outline + outline-offset ≥ 2px
   - :focus:not(:focus-visible) removes ring for mouse/touch only
   - Focus ring not obscured by sticky headers or overlays

7. Escape hatches
   - Declared inside @layer bespoke.*
   - data-bespoke attribute on root
   - ESC_{CATEGORY} comment with author, date, justification
   - Non-negotiables (ELP_003 border-box, ELP_004 logical props, ELP_028 reduced motion) still apply inside

8. Performance budget
   - Use eval/fixtures and bin/css-budget.sh to verify canonical limits in performance-rules.md
   - Per-file ≤ limit
   - Max selector specificity 0-2-0 (no IDs, no !important)
   - No @import; use <link> only

OUTPUT FORMAT:

## Design System Score: X/10

## Per-Dimension Breakdown
| Dimension | Score | Evidence |
|---|---:|---|
| Token architecture | /2 | |
| Layer ordering | /1 | |
| Color theming | /1 | |
| Fluid typography | /1 | |
| Motion safety | /2 | |
| Focus visibility | /1 | |
| Escape hatches | /1 | |
| Performance budget | /1 | |
| **Total** | **/10** | |

## Findings
Grouped by severity, each finding cites ELP_* and a concrete fix.

## Positive notes
What the system does well.
```

## Fixtures

Paired fixtures (drawn from `eval/fixtures/`):

- Compliant → `compliant-article.html` (token architecture, motion, focus)
- Anti-pattern → `anti-pattern-design-system.html` (arbitrary spacing, physical props, motion ungated)
- Anti-pattern (motion) → `anti-pattern-motion.html`
- Anti-pattern (focus) → `anti-pattern-focus.html`

## Scoring (0-10)

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 9-10 | A | Ships — system is a net positive for the product |
| 7-8 | B | Minor gaps; ship with a follow-up ticket |
| 5-6 | C | Several gaps; block on fixing at least motion + focus |
| 3-4 | D | Material accessibility risks; do not ship |
| 0-2 | F | System actively harms users |

## Cascade

If **Motion** scores 0/2 OR **Focus Visibility** scores 0/1, cap the total at **C (6/10)** regardless of other dimensions — same rationale as the layout rubric cascade.
