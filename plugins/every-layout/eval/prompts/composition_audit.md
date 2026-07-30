# Prompt: Composition Audit

## Purpose

Evaluate the two-tier audit split on a page that passes almost nothing:
the static tier (css-auditor / `/audit-layout`, plus the `bin/css-strict.sh`
gate) must catch the mechanically detectable defects AND refuse to claim the
rendered ones; the rendered tier (`/render-audit`) must catch the
composition defects from captures. The fixture embodies the Window Classics
seven in miniature — the field case where a site passed every static gate
and still shipped seven composition/context defects.

## Fixture

| Fixture | Expected Score |
|---------|----------------|
| `eval/fixtures/composition-page.html` | Static audit: 6-10/24; this eval scores the *auditor*, 0-10 below |

The fixture's `EXPECTED AUDIT RESULT` comment is the answer key — do not
paste it into the prompt sent to the model under test.

## Prompt Template (static tier)

```
Audit this page against the Every Layout rubric and principles. Report
violations with ELP citations, score /24, and state explicitly which defect
classes your audit method cannot see.

FILE: eval/fixtures/composition-page.html
```

## Answer Key (do not include in the prompt sent to the model)

| # | Defect | Tier that must catch it | Cite |
|---|--------|--------------------------|------|
| F4 | body-wide `word-break: break-word` | static, hard (ELA_003) | ELP_034 |
| F5 | sized gradient on body, no `background-color` ground | static, hard (ELA_002) | ELP_035 |
| F7a | `light-dark()` accent with no `color-scheme` | static, hard (ELA_002) | ELP_016 |
| F2 | `--ink-page #111827` vs `--ink-section #1d232b` | static, warn (near-duplicate tripwire) | token-rules.md |
| F6 | `@media (min-width: 640px)` + `(min-width: 641px)` | static, warn (breakpoint tripwire) | — |
| F7b | decorative infinite `.hero-badge` animation | static, warn (hook) / Motion Safety ≤1/3 | motion-allowlist.md |
| F1 | h1 (1.75rem/500, `--ink-page`) outranked by h2s (2.625rem/700, `--ink-section`) | **render tier** — static may flag the *tokens* as candidates, must not score "rendered rank" | heading-tier contract |
| F3 | `.cta-solid` vs `.cta-ghost-caps`, same device two dressings | **render tier** — static may flag as species *candidate* only | species rule |

The static report must END with the rendered-tier referral line
("run `/render-audit`") because this is a whole-page audit.

## Scoring (0-10)

| Dimension | Points | Criteria |
|-----------|--------|----------|
| Hard statics found (F4, F5, F7a) | 0-3 | 1 point each, with correct ELP citation (ELP_034 / ELP_035 / ELP_016) |
| Warn-tier statics found (F2, F6, F7b) | 0-3 | 1 point each; F7b must NOT be excused by the reduced-motion gate being present |
| Tier honesty | 0-3 | 2 points for the verbatim rendered-tier referral ending; 1 point for flagging F1/F3 as render-tier *candidates* (heading-token drift, species heuristic) rather than asserting rendered findings from source. A response that confidently "scores" rendered rank or species from CSS alone gets at most 1/3 here |
| Score plausibility | 0-1 | Static score lands in 6-10/24 with Motion Safety ≤ 1/3 and no accessibility 0-cap misapplied |
| **Total** | **/10** | |

**Automatic fail condition:** recommending a media query to fix any of the
seven, or recommending the body-level `word-break` be *kept* with headings
opted out via `h1-h6 { word-break: normal }` — the grant belongs on the
content container (ELP_034); un-granting per-heading inverts the principle.
Either scores the response 0/10.

| Range | Grade |
|-------|-------|
| 9-10 | A |
| 7-8 | B |
| 5-6 | C |
| 3-4 | D |
| 0-2 | F |

## Output Format

```markdown
## Composition Audit Eval

### Hard statics
| Defect | Found? | ELP cited? |
|--------|--------|------------|
| F4 body word-break | Yes/No | ELP_034 Yes/No |
| F5 unpainted ground | Yes/No | ELP_035 Yes/No |
| F7a light-dark/color-scheme | Yes/No | ELP_016 Yes/No |

### Warn-tier statics
| Defect | Found? |
|--------|--------|
| F2 near-duplicate inks | Yes/No |
| F6 adjacent breakpoints | Yes/No |
| F7b decorative infinite animation | Yes/No |

### Tier honesty
- Referral line present: [Yes/No]
- F1/F3 handled as render-tier candidates: [Yes / overclaimed / missed]

### Media-query / inverted-fix check
[Clean / VIOLATION → automatic 0/10]

### Score: X/10 (Grade)
```
