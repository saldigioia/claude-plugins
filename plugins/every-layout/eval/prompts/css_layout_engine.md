# Prompt: CSS Layout Engine

## Purpose

Evaluate whether a model, given a plain-language layout problem, produces
correct Every Layout primitive-based CSS: the right `ELC_*` primitive,
canonical recipe fidelity, modular-scale spacing, logical properties, and
(where a fraction-track grid is involved) ELP_033 auto-minimum safety —
without reaching for a media query.

## Calibration Exhibits

Before scoring a run, re-read these two fixtures as the score anchors:

| Fixture | Represents |
|---------|------------|
| `eval/fixtures/compliant-article.html` | 21-24/24 (A) — canonical recipes, modular scale, logical properties, no media queries |
| `eval/fixtures/anti-pattern-auto-min.html` | 10-14/24 — the ELP_033 failure mode: bare `repeat(3, 1fr)` + `aspect-ratio` children clip at narrow widths despite passing every other check |

A response that reproduces the `compliant-article.html` patterns for
Stack/Center/Box/Grid should score in the A range on this eval. A response
that reproduces the `anti-pattern-auto-min.html` mistake — bare `1fr` on a
fixed column count with aspect-ratio or wrapping-label children — must be
marked down on Test 4 specifically, per ELP_033.

## Test Scenarios

Run each scenario as an independent prompt. Do not carry context between them.

### Test 1 — Card Grid

```
Build a responsive grid of product cards. Each card has an image, a title,
and a price. I don't know how many cards there will be, and I don't want to
write breakpoints. Cards should never get narrower than about 15rem.

Give me the HTML structure and the CSS.
```

**Expected:** `ELC_GRID` — `display: grid; grid-template-columns:
repeat(auto-fit, minmax(min(var(--min, 15rem), 100%), 1fr))`. Cards composed
as `ELC_BOX` (padding/border) containing `ELC_FRAME` (image aspect ratio) and
`ELC_STACK` (title/price rhythm). No `@media` for column count. `--min`
exposed as a configurable custom property.

### Test 2 — Page Shell Spine

```
I need the overall page shell: a header, a hero heading that's vertically
centered in the viewport on first load, and a footer. The body content below
the fold is normal document flow. No JavaScript.
```

**Expected:** `ELC_COVER` as the shell (`min-block-size: 100vh`,
`.principal` class on the hero heading, `margin-block: auto` centers it,
header/footer pushed to the ends via the `:first-child:not(.principal)` /
`:last-child:not(.principal)` zero-margin rules). Likely composed with
`ELC_CENTER` around the hero text for measure, and `ELC_STACK` for the
below-the-fold content. Correct behavior: only the `.principal` element
centers; header and footer sit flush.

### Test 3 — Media Object

```
Build a comment/media object: a small avatar image on one side, and the
commenter's name plus comment text filling the rest of the row. If the
comment text is long, the text should wrap under itself, not push the
avatar off-screen. The avatar is a fixed size; the text takes remaining
space.
```

**Expected:** `ELC_SIDEBAR` (`.with-sidebar`) with the avatar as the
fixed-basis first child (`flex-basis: var(--side-width)`, small value like
`4rem` or `5rem`) and the text as the growing second child (`flex-basis: 0;
flex-grow: 999; min-inline-size: var(--content-min, 50%)`). A response using
`ELC_CLUSTER` alone (no distinct fixed vs. flexible sizing) or fixed pixel
widths on the avatar container should be marked down. `min-inline-size: 0`
required on the avatar side per ELP_033 so a long unbroken name/URL in the
text column can't force the avatar to shrink unexpectedly — note the
avatar's own image sizing is typically fixed via `ELC_FRAME`, not the
Sidebar mechanism itself.

### Test 4 — Fixed-3-Column Swatch Row (ELP_033 gate)

```
I need exactly three color swatches in a row, always three columns — never
auto-fit, never wrapping to fewer or more. Each swatch holds a color name
label that might wrap onto two lines at narrow widths. Give me the grid CSS.
```

**Expected — this is the ELP_033 compliance gate for this eval.** A correct
answer MUST use `grid-template-columns: repeat(3, minmax(0, 1fr))` (or
supply `min-inline-size: 0` on the grid children as an equivalent fix) —
**never** bare `repeat(3, 1fr)`. Explain *why*: bare `1fr` is
`minmax(auto, 1fr)`; the implicit `auto` floor lets a swatch's min-content
size (inflated further when its label wraps, via `aspect-ratio` feedback if
present) veto shrinking, and the row overflows at narrow widths — exactly
the failure documented in `eval/fixtures/anti-pattern-auto-min.html` and
principle ELP_033 (Neutralized Auto-Minimum). A response that outputs bare
`1fr` for this scenario — with or without a caveat — **fails Test 4
outright** (0/2 on ELP_033 compliance for this scenario), because the
prompt explicitly describes the wrapping-label condition that triggers the
bug. A response that adds a `@media` query to "fix" narrow-width clipping
instead of `minmax(0, 1fr)` also fails Test 4 outright.

## Scoring (0-10)

Score each of the 4 test scenarios against these criteria, then average and
round to the nearest whole point for the final `/10`. A scenario is scored
`/10` on this rubric; the reported eval score is the mean across scenarios
run.

| Dimension | Points | Criteria |
|-----------|--------|----------|
| Correct primitive choice | 0-3 | Names the expected `ELC_*` (or composition of primitives) for the scenario; explicitly rules out at least one plausible near-miss |
| Canonical recipe fidelity | 0-3 | CSS matches the primitive's actual recipe in `skills/css-layout-engine/references/primitives.md` (right properties, right selectors, right composition) — not a lookalike that happens to render similarly |
| Modular-scale values + logical properties | 0-2 | All spacing values are modular-scale tokens (`--s-5`..`--s5`) or their custom-property equivalents, never arbitrary px/rem; all directional properties are logical (`inline-size`, `margin-inline`, `inset-*`), never physical (`width`, `margin-left`) |
| ELP_033 compliance | 0-1 | Any fraction track that could contain shrink-resistant children (media, `aspect-ratio`, long labels) uses `minmax(0, 1fr)` or an equivalent `min-inline-size: 0` — bare `1fr` in a fixed-count grid with such children is an automatic 0 here regardless of other scores |
| No media queries for layout | 0-1 | Zero `@media (min-width/max-width/...)` blocks used to switch layout structure; container queries (`ELC_CONTAINER`) are acceptable only when explicitly justified as component-relative, not viewport-relative |
| **Total** | **/10** | |

**Hard fail override:** if Test 4 specifically uses bare `1fr` for the
fixed-3-column scenario (the exact case the prompt describes), cap that
scenario's total at 4/10 regardless of how well the other dimensions score
— ELP_033 is the one principle this eval exists to gate, and it cannot be
offset by good logical-properties or spacing hygiene elsewhere in the same
answer.

| Range | Grade |
|-------|-------|
| 9-10 | A |
| 7-8 | B |
| 5-6 | C |
| 3-4 | D |
| 0-2 | F |

## Output Format

For each test scenario, report:

```markdown
## Test N: [Scenario Name]

### Primitive(s) Used
[ELC_* cited, or "none" if the response invented ad-hoc CSS]

### Recipe Fidelity
[Match / Partial match / Mismatch] — [specifics, with reference to
primitives.md CSS Recipe block]

### Scale & Logical Properties
[Pass/Fail] — [list any arbitrary values or physical properties found]

### ELP_033 Check
[Pass/Fail/N/A] — [trace: is there a fraction track? does it carry a
definite minimum? do shrink-resistant children exist?]

### Media Queries
[None used / N used for: purpose]

### Score: X/10

### Notes
[Anything scenario-specific worth flagging]
```

After all scenarios, give a final summary:

```markdown
## Summary

| Test | Score |
|------|-------|
| 1. Card Grid | X/10 |
| 2. Page Shell Spine | X/10 |
| 3. Media Object | X/10 |
| 4. Fixed-3-Column Swatch Row | X/10 |

**Overall: X/10 (Grade)**
```
