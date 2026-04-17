---
name: measure-budget
description: >
  Measure CSS against the Every Layout performance budget. Reports per-file
  size, custom-property count, selector specificity, and pass/fail per budget
  line. Use after building or before shipping to verify budget compliance.
disable-model-invocation: true
allowed-tools: Read Grep Glob Bash(${CLAUDE_PLUGIN_ROOT}/bin/css-budget.sh *)
argument-hint: "<directory to measure — default: src/styles>"
---

# Measure Budget

Run the plugin's budget script against a CSS directory and report pass/fail. The canonical thresholds live in `skills/css-design-system/references/performance-rules.md`; the script reads them as constants.

## Measurement

```!
${CLAUDE_PLUGIN_ROOT}/bin/css-budget.sh ${1:-src/styles}
```

## Interpretation

The script emits one pass/fail row per metric:

- **Total CSS (minified est.)** — aggregate estimate vs canonical limit
- **Total CSS (gzipped est.)** — aggregate estimate vs canonical limit
- **Custom properties** — total `--*` declarations vs tier cap
- **Max specificity** — any selector exceeding the 0-2-0 ceiling flags an ID/`!important` violation
- **Per-file minified** — any file over the per-file cap

If the script reports `OVER BUDGET` for any line, investigate that file first. Typical causes:

- An un-split mega-stylesheet — consider the critical / async / lazy split in `performance-rules.md`
- Unused tokens left over from a prior iteration — prune
- Accidental `@import` (prohibited; use `<link>` only)
- A component-level stylesheet exceeding the per-component limit — extract shared rules to a brand layer

When the script uses estimates (60 % raw for minified, 25 % raw for gzipped), treat results as early-warning. For ship-gating measurements, run a real minifier and `gzip -c | wc -c` — see `skills/css-design-system/references/performance-rules.md` for the canonical method.

## Reporting

Summarise the script output for the user:

- Pass/fail per metric, total metric count (6), and any OVER BUDGET lines
- The highest-cost file by raw size
- One-sentence recommendation if any metric fails

Do not restate the numeric thresholds — they live in the canonical reference, which the user can consult directly.
