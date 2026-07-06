# Prompt: Scaffold System

## Purpose

Evaluate a `/scaffold-system` run — the greenfield entry point that generates a fresh Every Layout system (`tokens.css`, `layers.css`, `primitives.css`, `global.css`, plus `escapes.md`) into a project with no prior system. Unlike `audit_layout.md` and `css_design_system.md`, which score CSS that already exists in the wild, this prompt scores the *scaffolding process itself*: did the skill produce the exact canonical templates, in the right place, without clobbering anything.

## Prompt Template

```
Evaluate the following /scaffold-system run against the scaffold-system skill.

INVOCATION:
[The argument string passed, e.g. "src/styles Acme"]

FILES PRODUCED (paste each file's full contents):
[<target>/tokens.css]
[<target>/layers.css]
[<target>/primitives.css]
[<target>/global.css]
[escapes.md, if created]

TRANSCRIPT (what the model said/did, including any refusal or overwrite check):
[paste]

EVALUATION REQUIREMENTS:

1. Exact scale values (tokens.css)
   - --ratio: 1.5 present
   - Full scale present and byte-exact: --s-5: 0.132rem, --s-4: 0.198rem,
     --s-3: 0.296rem, --s-2: 0.444rem, --s-1: 0.667rem, --s0: 1rem,
     --s1: 1.5rem, --s2: 2.25rem, --s3: 3.375rem, --s4: 5.063rem, --s5: 7.594rem
   - --measure: 65ch present
   - --border-thin: 1px present
   - No off-scale numeric spacing value introduced anywhere in the 4 files (ELA_004)

2. All 9 brand tokens present, using light-dark()
   - --br-color-surface, --br-color-surface-raised, --br-color-text,
     --br-color-text-muted, --br-color-accent, --br-color-interactive,
     --br-color-focus, --br-font-body, --br-font-heading
   - Exactly these 9 — no invented 10th brand token, none silently dropped
   - Every --br-color-* uses light-dark(...), not a single flat value
   - color-scheme: light dark declared on :root

3. Layer order exact
   - layers.css contains exactly:
     @layer global, brand, components, bespoke.legacy, bespoke.dataviz, bespoke.editorial, bespoke.embed;
   - No reordering, no added/removed top-level layer, nothing else in the file

4. Primitives copied, not paraphrased
   - primitives.css is byte-identical (or a verbatim `cp`) to demos/every-layout.css,
     not a hand-retyped subset or summary
   - The model's process shows a `cp` from ${CLAUDE_PLUGIN_ROOT}/demos/every-layout.css,
     not a from-scratch rewrite of the 13 primitives

5. global.css skeleton correctness
   - Imports layers.css first (order note honored)
   - body font/color/background sourced from --br-font-body / --br-color-text / --br-color-surface
   - :focus-visible ring present per ELP_029, with :focus:not(:focus-visible) reset
   - prefers-reduced-motion: reduce block present per ELP_028 (0.01ms durations, !important
     scoped only inside this media block)
   - Skip-link pattern present (position, transform: translateY(-100%), :focus reveal)

6. escapes.md created correctly
   - Copied from escapes.md.template to project root (not the styles target dir)
   - If escapes.md already existed, the model left it untouched and said so
     (no silent overwrite)

7. No overwrites
   - Before writing, the model checked whether tokens.css / layers.css /
     primitives.css / global.css already existed in the target
   - If any existed, the model refused, named which file(s) collided, and
     pointed to /plan-migration instead of forcing the scaffold
   - Pre-commit hook installation (bin/install-git-hooks.sh) was offered, not
     auto-run — the model asked before installing

8. IDs cited
   - ELC_*, ELP_*, and ELA_* ids appear next to the specific choices they
     justify (e.g. ELA_004 next to the scale, ELP_028/ELP_029 next to the
     accessibility block, ELA_005 next to the performance budget) — not just
     dropped once at the top as decoration

OUTPUT FORMAT:

## Scaffold Score: X/10

## Per-Dimension Breakdown
| Dimension | Score | Evidence |
|---|---:|---|
| Exact scale values | /2 | |
| Brand tokens (9, light-dark) | /2 | |
| Layer order exact | /1 | |
| Primitives copied verbatim | /1 | |
| global.css skeleton | /1 | |
| escapes.md handling | /1 | |
| No overwrites | /1 | |
| IDs cited | /1 | |
| **Total** | **/10** | |

## Violations Found
[List each deviation from the canonical templates with the offending value/line
and the ELA_*/ELP_*/ELC_* id it breaks]

## Recommendations
[Specific corrections, referencing the canonical value or process step]
```

## Fixtures

This skill has no dedicated compliant/anti-pattern fixture pair of its own (it scores a *process*, not a static file) — instead, downstream compliance is checked against the existing layout fixture:

- Downstream style target: `eval/fixtures/compliant-article.html` — the scaffolded
  `tokens.css` scale values, motion-safety block, and focus-visible pattern should
  be able to reproduce this fixture's compliant CSS section (`:root` scale,
  `@media (prefers-reduced-motion: reduce)`, `:focus-visible` rule, skip-link)
  without introducing any value this fixture doesn't already use. If a scaffold
  run emits a token or pattern that a fresh page built from `compliant-article.html`
  could not satisfy, treat it as a violation of dimension 1, 5, or 8 above.
- Escape registry shape: `escapes.md.template` — the copied `escapes.md` must
  match this template's **Active escapes** table format (ESC ID, Target glob,
  Axiom, Lines, Expires, Owner, Justification columns) with the example rows
  either removed or clearly marked as examples, not asserted as real escapes.

## Scoring (0-10)

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 9-10 | A | Scaffold is gate-clean on arrival — ships as the project's day-one system |
| 7-8 | B | Minor drift (a cosmetic token name, a missing ID citation); fix before first commit |
| 5-6 | C | A required brand token missing or a scale value off — blocks `/strict-check` |
| 3-4 | D | Layer order wrong or primitives paraphrased instead of copied — architectural drift from day one |
| 0-2 | F | Overwrote existing files, or invented tokens outside the three tiers |

## Cascade

If **No overwrites** scores 0/1 (an existing file was silently clobbered), cap the total at **F (2/10)** regardless of other dimensions — overwriting a project's existing system is the one failure mode this skill exists specifically to prevent, so no amount of correct token math offsets it. If **Layer order exact** scores 0/1, cap the total at **D (4/10)** — a wrong `@layer` statement silently breaks every cascade decision downstream and is not a minor deviation.
