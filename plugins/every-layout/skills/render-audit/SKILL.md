---
name: render-audit
description: >
  Rendered, adversarial composition review — the tier static gates cannot
  replace. Runs bin/render-sweep.sh (screenshots at ten widths, light and
  dark, plus overflow/ground/fracture probes), then reviews the captures
  against the composition checklist: heading rank, ink/family per tier,
  shared axes, device species, dark-scheme ground, narrow fractures,
  breakpoint seams. Findings are model-judged — a distinct tier from the
  24-point static rubric. Use before release and after any visual redesign.
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/render-sweep.sh *) Read Glob Grep
argument-hint: "<base URL or dist dir> [routes]   — e.g. 'http://localhost:4321 /,/about' or 'dist /'"
---

# Render Audit — the eyes tier

Static gates audit *values*; nobody audits *rank, axis, species, and context*
from source alone. The largest field deployment of this plugin passed every
static gate and still shipped seven composition defects — every screenshot it
ever took was light-mode, comfortable-width, motion-on. This skill renders
and looks.

$ARGUMENTS

## 1. Sweep

Run the harness against the served site (or a dist directory it can serve
itself). It requires a locally resolvable playwright; if unavailable it
prints `SKIP` — report that honestly and stop (the static tiers still stand,
but say plainly which defect classes went unexamined).

```
${CLAUDE_PLUGIN_ROOT}/bin/render-sweep.sh --serve-dist <dist>   [--routes "/,/about"]
${CLAUDE_PLUGIN_ROOT}/bin/render-sweep.sh --base <url>          [--routes "/,/about"]
```

Optional: `--pw-root <dir>` resolves playwright from a sibling project;
`--config render-sweep.config.json` reads the scaffolded config. The sweep
writes full-page PNGs per route × width × scheme plus `probes.json`, and
prints a probe table (overflow / fracture / ground). The probe table is
mechanical evidence — carry any failure row directly into the findings.

## 2. Review the captures

Read the screenshots — at minimum, for each route: the narrowest width
(320), one mid width (768), and the widest (1280+), in BOTH light and dark.
Judge each item below by looking, not by re-reading the CSS:

| # | Check | What failing looks like |
|---|-------|--------------------------|
| 1 | **Heading rank monotonic** | The h1 rendered smaller/lighter than the h2s beneath it — a page captioned by its own sections |
| 2 | **One ink, one family per tier** | Two h2s on one route (or across routes) in visibly different near-blacks or typefaces |
| 3 | **Shared axis** | An eyebrow/kicker and its title starting at different x-positions with no grid rationale; centered title over left-set eyebrow |
| 4 | **Device species** (the CTA test) | The same device — CTA, card, badge — rendered in two dressings (solid here, ghost-caps there) with no recorded decision |
| 5 | **Reserved slots vs optical centering** | A rotating/animated word slot reserving max-width space, leaving the visible text optically off-center |
| 6 | **Dark-scheme ground** | Any region riding the UA canvas in the dark captures — gradient stops, transparent panels going black; cross-check the probe table's `ground` column |
| 7 | **Narrow-width fractures** | A heading line opening with an orphan letter or breaking mid-word at 320–414; cross-check the `fracture` probe |
| 8 | **Breakpoint seams** | Compare adjacent captured widths (640 vs 641-class): elements jumping dressing or alignment across a 1px boundary |

Checks 6 and 7 have mechanical pre-screens in the probe table; the rest are
judgment. Look at every route's dark captures — the field failure shipped
because nobody ever did.

## 3. Report

Mirror the css-auditor finding shape, but label the tier honestly:

```markdown
## Render Audit — MODEL-JUDGED (tier 4)

Sweep: N routes × M widths × 2 schemes (out dir, probe failures: K)
This is the rendered composition tier — distinct from the 24-point static
rubric; no /24 score is produced here.

### Findings

#### [Severity: high|medium|low] — [check #N name]
- **Route/capture**: /route @ 390px dark (path/to/png)
- **Element**: the h1 "Window Classics of Pensacola"
- **Observed**: 28px/500 in #111827 above 42px/700 h2s in #1d232b
- **Why it fails**: rank inversion — the page title is outranked by its sections
- **Fix**: one ramp: h1 takes --step-4/700; sections keep --step-3; one ink token per tier
- **Cite**: [heading-tier contract | ELP_034 | ELP_035 | ELP_016 | motion-allowlist] as applicable

### Clean checks
List the checklist items that passed, with the captures that show it.
```

Severity: **high** = a user-visible failure in a shipped context (fracture,
dark ground, rank inversion); **medium** = coherence defects (species drift,
axis breaks, seams); **low** = polish (optical centering).

## Constraints

- MUST run the sweep before judging — no findings from CSS source alone
- MUST look at dark captures for every route reviewed
- MUST carry every probe-table failure row into the findings (mechanical
  evidence outranks impressions)
- MUST label the report MODEL-JUDGED and produce no /24 score — that scale
  belongs to the static rubric; pretending composition is grep-able (or
  rubric-able) is the failure mode this tier exists to correct
- MUST NOT modify files — this is a review tier
- When the sweep SKIPs, say which defect classes (1–8) went unexamined
