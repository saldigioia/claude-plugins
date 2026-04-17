# Every Layout Plugin

Composable CSS layout primitives, Astro 5 site architecture, archival data engine, and design system tokens for Claude Code. Built on the [Every Layout](https://every-layout.dev) methodology by Andy Bell and Heydon Pickering.

**Version:** 4.2.0 &middot; **Author:** Rare Data Club &middot; **License:** MIT

## The commitment

This plugin treats **simple, durable, CSS-dominant web design as a requirement, not a recommendation.** Six axioms govern every output. The `bin/css-strict.sh` and `bin/js-budget.sh` gates exit non-zero when axioms are violated — suitable for pre-commit and CI.

| Axiom | Requirement |
|---|---|
| ELA_001 Algorithmic Layout | Media queries are manual overrides, not the first tool |
| ELA_002 Designing Without Seeing | No physical properties; no arbitrary pixel values |
| ELA_003 Exception-Based Styling | No `!important`, no ID selectors, 0-2-0 specificity cap |
| ELA_004 Axiomatic Values | Every value derives from a named scale |
| ELA_005 CSS-Dominant Composition | 15 KB per-route / 30 KB page-total JS budget; no CSS-in-JS |
| ELA_006 Archival Durability | Must work in five years with no maintenance |

Adoption = contract. Exceptions live in `escapes.md` with expiry dates, not in silent drift. Full text: [`skills/css-layout-engine/references/axioms.md`](skills/css-layout-engine/references/axioms.md).

## What this plugin gives you

When Claude Code edits CSS, HTML, or Astro files with this plugin enabled, it applies 13 composable layout primitives (Stack, Box, Center, Cluster, Sidebar, Switcher, Cover, Grid, Frame, Reel, Imposter, Icon, Container) and 32 numbered design principles — no media queries, logical properties only, modular-scale spacing, zero-JS by default.

It also provides:

- **Astro 5 project architecture** — content collections, layouts, routing, performance budgets
- **Archival data patterns** — SQLite/libSQL/Drizzle/Astro DB schemas and custom loaders
- **Framework component ports** — Astro, React, Vue, Svelte, Tailwind, and vanilla CSS
- **Design system tokens** — color theming with `light-dark()`, fluid type, escape hatch registry, accessibility patterns

## Install

```bash
# Test locally during development
claude --plugin-dir ./every-layout-plugin

# From a marketplace
/plugin install every-layout@rare-data-club
```

## Enable strict mode in your project

For real enforcement (not just advice), install the pre-commit hook:

```bash
cd /path/to/your/project
bash /path/to/every-layout-plugin/bin/install-git-hooks.sh
```

Every `git commit` now runs `bin/css-strict.sh` and `bin/js-budget.sh` against your project. A commit that violates any axiom is blocked. To bypass (emergency only): `git commit --no-verify`. To register an intentional exception: add an entry to `escapes.md` with an expiry date.

For CI (GitHub Actions, GitLab CI, etc.), run the gates directly:

```bash
bash /path/to/every-layout-plugin/bin/css-strict.sh src/styles
bash /path/to/every-layout-plugin/bin/js-budget.sh dist
```

Both exit non-zero on violation. Wire them as required status checks.

## Contents

| Directory | What's inside |
|---|---|
| `skills/` | 13 skills — **5 knowledge** (`css-layout-engine`, `css-design-system`, `framework-implementations`, `astro-site-architect`, `archival-data-engine`) auto-invoke when Claude edits matching files; **8 workflow** (`/strict-check`, `/audit-layout`, `/diagnose-layout`, `/choose-primitive`, `/refactor-to-primitives`, `/generate-port`, `/plan-migration`, `/measure-budget`) are user-invoked |
| `agents/` | 3 subagents: `site-builder` (Sonnet, autonomous Astro builder), `css-auditor` (Haiku, read-only scorer), `css-diagnostician` (Haiku, primitive behavior explainer) |
| `hooks/` | PostToolUse CSS linter that flags physical properties, arbitrary px, and media queries on every CSS write |
| `bin/` | Axiom gates (`css-strict.sh`, `js-budget.sh`), git-hook installer, CSS lint/audit/budget scripts, Astro typecheck, eval runner, SQLite schema dump |
| `demos/archive-site/` | Reference implementation: Astro + SQLite archive site using all 5 knowledge skills, plus React-port examples |
| `eval/` | 24-point scoring rubric, 15 fixtures (compliant, anti-pattern, archival-schema, astro-layout), 7 scoring prompts |
| `stress-tests/` | 13 HTML files, one per primitive, 8 test cases each |
| `escapes.md.template` | Template for the intentional-exception registry (axiom waivers with expiry dates) |

## Quick usage

**Axiom enforcement (CI-grade):**
- `/strict-check [css-dir] [dist-dir]` — hard gate; exits non-zero on any ELA_001–006 violation

**Scoring & analysis:**
- `/audit-layout [path]` — score CSS/HTML against the 24-point rubric (forks to `css-auditor`)
- `/diagnose-layout [symptom]` — explain why a primitive is misbehaving (forks to `css-diagnostician`)
- `/measure-budget [dir]` — per-file CSS budget check with pass/fail per metric

**Migration & authoring:**
- `/plan-migration [dir]` — scans codebase; produces phased adoption plan with violation counts
- `/refactor-to-primitives [path]` — converts non-compliant CSS into primitive composition
- `/choose-primitive "<problem>"` — decision tree picks the right primitive with ELP citations
- `/generate-port <framework> <primitive>` — emits the canonical component port (Astro/React/Vue/Svelte/Tailwind/vanilla)

**Automatic (no slash):**
- Ask Claude "how should I lay out X?" — the layout-engine skill auto-invokes
- Edit any `.css` / `.astro` / `.tsx` file — the matching knowledge skill loads via `paths` globs

## Architecture & conventions

See [`CLAUDE.md`](./CLAUDE.md) for the full architecture, skill dependency graph, budget thresholds, and file conventions.

## Philosophy

- No runtime JavaScript in layout primitives
- No media queries for layout switching (intrinsic responsive design only)
- No arbitrary spacing values (modular scale `--s-5` through `--s5`, ratio 1.5)
- No CSS-in-JS. CSS lives in CSS.
- Performance budget: 34 KB minified / 8.5 KB gzipped CSS; **15 KB per-route / 30 KB page-total compressed JS**
- Logical properties only (`inline-size`, not `width`)
- Every exception registered in `escapes.md` with an expiry date

## Contributing & issues

Report issues or propose changes at [github.com/saldigioia/every-layout-plugin](https://github.com/saldigioia/every-layout-plugin).
