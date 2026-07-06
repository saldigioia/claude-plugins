# Prompt: Diagnose Layout

## Purpose

Evaluate diagnostic quality from the `css-diagnostician` agent (invoked via
the `/diagnose-layout` skill). Given a primitive that misbehaves, the model
must trace the actual algorithm with actual custom-property values from the
CSS — not describe generic troubleshooting steps — identify the true root
cause, and rank fixes smallest-first, never proposing a media query.

## Fixture

Run this prompt against each of the four planted symptoms in:

| Fixture | Expected Score |
|---------|----------------|
| `eval/fixtures/diagnose-broken-primitives.html` (4 symptoms) | 8-10/10 per symptom for a correct diagnosis |

The fixture's `EXPECTED AUDIT RESULT` comment at the top of the file names
all four root causes and canonical fixes — use it as the answer key when
scoring, but do not paste it into the prompt sent to the model under test;
the model must derive the root cause from reading the CSS itself.

## Prompt Template

Run once per symptom, pointing at the fixture file and quoting only the
symptom's user-facing complaint (not the answer-key comment):

```
A primitive in this file is misbehaving. Diagnose why, using the
css-diagnostician approach: trace the algorithm with the actual custom
property values, identify the root cause, and rank fix options
smallest-first. Do not modify the file.

FILE: eval/fixtures/diagnose-broken-primitives.html

USER REPORT (Symptom 1): "The nav sidebar and the article never sit side by
side, they always stack, even on my widescreen monitor."
```

Repeat with:

- **Symptom 2**: "These two panels never stack on mobile, they just get
  squeezed into two skinny columns no matter how narrow the viewport gets."
- **Symptom 3**: "On my phone the third swatch in each row is sliced in
  half — it renders fine on desktop."
- **Symptom 4**: "The hero heading is supposed to be vertically centered in
  the cover but it just sits up near the header instead."

## Answer Key (do not include in the prompt sent to the model)

| Symptom | Primitive | Root Cause | Canonical Fix |
|---------|-----------|------------|----------------|
| 1 | `ELC_SIDEBAR` | `--side-width` (24rem) + `--content-min` (60%) sum past any realistic container width — the wrap is algorithmically correct, not broken | Lower `--side-width` or `--content-min` (custom property) |
| 2 | `ELC_SWITCHER` | `--threshold` is 4rem — far below any real container width, so `calc((4rem - 100%) * 999)` is always a large negative flex-basis and the switch condition can never fire | Raise `--threshold` toward the intended stacking width, e.g. `30rem` (custom property) |
| 3 | Fixed-column grid (ELP_033) | `.swatch-row` uses bare `repeat(3, 1fr)` == `minmax(auto, 1fr)`; the hidden `auto` floor plus each swatch's `aspect-ratio: 1/1` (which grows when its label wraps) vetoes shrinking, overflowing the row until `.swatch-card`'s `overflow: hidden` clips column 3 | `repeat(3, minmax(0, 1fr))` and/or `min-inline-size: 0` on `.swatch-row > *` |
| 4 | `ELC_COVER` | `.cover > .principal { margin-block: auto }` is the only centering rule; `<main>` lacks the `.principal` class, so it falls through to the default `.cover > * { margin-block: var(--s1) }` rule instead | Add `class="principal"` to `<main>` (structural — no smaller custom-property fix exists since centering is class-gated) |

## Scoring (0-10 per symptom)

| Dimension | Points | Criteria |
|-----------|--------|----------|
| Correct root cause identified | 0-3 | Names the actual mechanism (e.g. "threshold too small," not "the CSS is wrong") and matches the answer key's cause, not merely its symptom |
| Algorithm trace with actual values | 0-3 | Shows the computation using the real custom-property values read from the file — e.g. for Symptom 2, states `--threshold: 4rem` and walks through why `calc((4rem - 100%) * 999)` stays negative at realistic container widths. A trace that only restates the CSS recipe in the abstract, without plugging in this file's actual values, scores at most 1/3 here |
| Fix ranked smallest-first | 0-2 | Presents fix options in the order: (1) custom-property value change, (2) structural change (different primitive or markup change), (3) escape-hatch registration — matching the `css-diagnostician` agent's and `/diagnose-layout` skill's own ranking convention. A single unranked fix, or fixes in the wrong order (structural before custom-property), scores at most 1/2 |
| ELC/ELP IDs cited | 0-1 | Cites the correct `ELC_*` primitive ID for the symptom, and (for Symptom 3) `ELP_033` specifically |
| **Total** | **/10** | |

**Automatic fail condition:** if a diagnosis for ANY symptom recommends
adding or adjusting an `@media` query as a fix — including "as a stopgap" or
"if the custom-property fix isn't enough" — that symptom scores **0/10**
regardless of how good the rest of the diagnosis is. `ELA_001` /
`ELP_009` forbid media queries as a layout-switching mechanism, and the
`css-diagnostician` agent and `diagnose-layout` skill both state this as a
hard MUST NOT. This is not a partial-credit deduction; it is a full zero for
that symptom.

**Correct-by-design acknowledgment:** Symptoms 1 and 2 describe behavior
that is *algorithmically correct given the current values* — the primitives
are not buggy, they are configured to produce exactly this outcome. Full
marks on "root cause identified" requires the response to say so explicitly
(e.g., "this isn't a bug — the Sidebar is wrapping because the two minimums
can never both fit"), not just supply a fix. A response that treats the
behavior as an unexplained defect and jumps straight to a fix without this
acknowledgment loses 1 point from the root-cause dimension.

| Range | Grade |
|-------|-------|
| 9-10 | A |
| 7-8 | B |
| 5-6 | C |
| 3-4 | D |
| 0-2 | F |

## Output Format

For each symptom, report:

```markdown
## Symptom N: [Primitive Name] (ELC_*)

### Reported Root Cause
[What the response under test identified]

### Matches Answer Key?
[Yes / Partial / No] — [specifics]

### Algorithm Trace Quality
[Full trace with real values / Abstract recipe only / Missing] — [quote the
key computed value, e.g. the threshold comparison, if present]

### Fix Ranking
[Correctly ordered (property > structural > escape) / Present but unordered
/ Missing] — [list the fixes given, in the order given]

### IDs Cited
[ELC_* / ELP_* found, or "none"]

### Media Query Check
[Clean / VIOLATION — media query recommended → automatic 0/10]

### Score: X/10
```

After all four symptoms, give a final summary:

```markdown
## Summary

| Symptom | Primitive | Score |
|---------|-----------|-------|
| 1. Sidebar always stacks | ELC_SIDEBAR | X/10 |
| 2. Switcher never switches | ELC_SWITCHER | X/10 |
| 3. Swatch grid clips narrow | ELP_033 | X/10 |
| 4. Cover not centering | ELC_COVER | X/10 |

**Overall: X/10 (Grade)** — mean across the four symptoms.
```
