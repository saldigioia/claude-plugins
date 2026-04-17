# Every Layout Evaluation Rubric

## Overview

This rubric provides structured criteria for evaluating CSS layouts against Every Layout principles.

## Scoring Dimensions

### 1. Intrinsic Sizing (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | All dimensions are fixed (px, fixed % widths) |
| 1 | Some intrinsic sizing used but mixed with fixed |
| 2 | Mostly intrinsic, few exceptions for valid reasons |
| 3 | Fully intrinsic, content determines dimensions |

**Checks:**
- [ ] Uses `max-width` instead of `width`
- [ ] Uses `min-width` appropriately
- [ ] Avoids fixed heights on content
- [ ] Uses `ch` for measure constraints

### 2. Responsive Without Breakpoints (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Multiple `@media` queries for layout changes |
| 1 | Reduced breakpoints, some intrinsic layout |
| 2 | Minimal breakpoints, mostly intrinsic |
| 3 | No layout breakpoints, fully intrinsic |

**Checks:**
- [ ] Grid uses `auto-fit`/`auto-fill` with `minmax`
- [ ] Sidebar uses flex-grow + min-width threshold
- [ ] Switcher pattern used where appropriate
- [ ] No magic viewport numbers (768px, etc.)

### 3. Composition (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Monolithic components, styles tightly coupled |
| 1 | Some reusable patterns, inconsistent |
| 2 | Uses primitives but with customization issues |
| 3 | Clean composition, primitives are independent |

**Checks:**
- [ ] Layout primitives are context-independent
- [ ] Nesting primitives works correctly
- [ ] No style leakage to grandchildren
- [ ] Uses child combinator (>) appropriately

### 4. Spacing System (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Arbitrary spacing values throughout |
| 1 | Some consistent values, many exceptions |
| 2 | Uses scale but with manual overrides |
| 3 | Consistent modular scale throughout |

**Checks:**
- [ ] Uses CSS custom properties for spacing
- [ ] Values derived from modular scale
- [ ] Consistent vertical rhythm (Stack)
- [ ] Gap over margin where appropriate

### 5. Logical Properties (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | All physical properties (left, right, top, bottom) |
| 1 | Mix of logical and physical |
| 2 | Mostly logical, physical for valid reasons |
| 3 | Fully logical, internationalization-ready |

**Checks:**
- [ ] Uses `inline-size`/`block-size`
- [ ] Uses `margin-inline`/`margin-block`
- [ ] Uses `padding-inline`/`padding-block`
- [ ] Uses `inset-*` properties

### 6. Accessibility (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Layout causes accessibility issues |
| 1 | Some considerations, issues remain |
| 2 | Good accessibility, minor issues |
| 3 | Excellent, all WCAG layout criteria pass |

**Checks:**
- [ ] Reflow works at 400% zoom (WCAG 1.4.10)
- [ ] No bidirectional scrolling on elements
- [ ] Reading order matches visual order
- [ ] Focus visible and not obscured

### 7. Motion Safety (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Animations play unconditionally; no `prefers-reduced-motion` handling |
| 1 | Some animations gated by `prefers-reduced-motion`, others not |
| 2 | Most animations respect preference; minor oversights (e.g., loading spinners) |
| 3 | All animation and transition gated; reduced-motion users see zero motion |

**Checks:**
- [ ] `@media (prefers-reduced-motion: reduce)` reset present globally
- [ ] No `transition: all` declarations
- [ ] Scroll-driven animations wrapped in `prefers-reduced-motion: no-preference`
- [ ] `animation-duration` and `transition-duration` set to `0.01ms` (not `0s`) in reduced-motion context
- [ ] No JavaScript scroll-jacking or custom momentum

**Reference:** ELP_028, WCAG 2.1 SC 2.3.3

### 8. Focus Visibility (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Focus rings removed (`outline: none`) with no replacement |
| 1 | Default browser focus rings preserved but not styled |
| 2 | `:focus-visible` used; keyboard-only focus rings present |
| 3 | Custom `:focus-visible` styles with adequate contrast, offset, and no obstruction |

**Checks:**
- [ ] `:focus-visible` styled with `outline` (not `box-shadow` alone)
- [ ] `outline-offset` provides spacing from element edge (≥ 2px)
- [ ] `:focus:not(:focus-visible)` removes ring for mouse/touch only
- [ ] Focus ring not obscured by sticky headers, overlays, or adjacent elements
- [ ] All interactive elements (links, buttons, inputs, custom controls) receive visible focus

**Reference:** ELP_029, WCAG 2.2 SC 2.4.7 / 2.4.11

## Total Score

Sum per-dimension scores, then apply the cascade rule below, then grade.

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 22-24 | A | Exemplary Every Layout implementation |
| 18-21 | B | Good, minor improvements possible |
| 13-17 | C | Adequate, several areas need work |
| 8-12 | D | Below standard, significant issues |
| 0-7 | F | Does not follow Every Layout principles |

### Cascade Rule — Accessibility floors the total

If either **Motion Safety** or **Focus Visibility** scores **0/3**, the total is capped at **16/24 (grade C)** regardless of other dimension scores. Rationale: accessibility failures that leave users unable to perceive focus or opt out of motion cannot be offset by strong logical-properties or spacing scores. Record the uncapped sum, then apply the cap to produce the final grade.

If both access dimensions score 0/3, cap at **12/24 (grade D)**.

The cascade does not change per-dimension scores — it only clamps the total used for grading. The report should show both numbers: "Raw: X/24 → After cascade: Y/24 (grade)."

## Quick Checklist

For rapid assessment, check these critical items:

- [ ] No fixed widths on content containers
- [ ] Uses Grid or Flexbox appropriately
- [ ] Stack pattern for vertical spacing
- [ ] Measure constraint on text
- [ ] No layout-related `@media` queries
- [ ] Custom properties for configuration
- [ ] Box-sizing: border-box globally
- [ ] `prefers-reduced-motion` reset present
- [ ] `:focus-visible` styled for keyboard users
