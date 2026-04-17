# Every Layout Plugin

Claude Code plugin providing composable CSS layout primitives, design system tokens, Astro 5 site architecture, archival data patterns, and framework component implementations based on Every Layout methodology.

**Version:** 4.2.0 | **Author:** Rare Data Club

## The commitment

This plugin treats **simple, durable, CSS-dominant web design as a requirement, not a recommendation.** Six axioms (`skills/css-layout-engine/references/axioms.md`) distilled from Bell & Pickering's *Every Layout* govern every output. The `/strict-check` skill and `bin/css-strict.sh` + `bin/js-budget.sh` scripts exit non-zero when axioms are violated — suitable for pre-commit and CI. Adoption = contract. Exceptions live in `escapes.md` with expiry dates, not in silent drift.

## Architecture

```
skills/                  12 skills (knowledge base + task workflows)

  Knowledge skills (auto-invokable)
    css-layout-engine/       13 primitives, 29 layout principles, 16 reference files
    css-design-system/       Tokens, theming, fluid type, 6 design-system principles, 18 reference files
    framework-implementations/ Ports for Astro, React, Vue, Svelte, Tailwind, Vanilla
    astro-site-architect/    Astro 5 project structure, content layer, routing, performance
    archival-data-engine/    SQLite/libSQL/Drizzle, custom loaders, schema patterns

  Workflow skills (user-invoked — disable-model-invocation)
    audit-layout/            /audit-layout — forks to css-auditor agent to score
    choose-primitive/        /choose-primitive — decision tree for primitive selection
    refactor-to-primitives/  /refactor-to-primitives — converts non-compliant CSS
    generate-port/           /generate-port — generates framework component implementations
    plan-migration/          /plan-migration — scans codebase, produces phased adoption plan
    measure-budget/          /measure-budget — runs bin/css-budget.sh via shell injection
    diagnose-layout/         /diagnose-layout — forks to css-diagnostician agent to explain
    strict-check/            /strict-check — axiom gate (exits non-zero); CI-grade enforcement

agents/                  3 agents
  site-builder.md          Sonnet — autonomous Astro site builder, uses all 5 knowledge skills
  css-auditor.md           Haiku — read-only CSS/HTML scorer against 24-point rubric
  css-diagnostician.md     Haiku — explains why a primitive behaves unexpectedly

hooks/                   PostToolUse CSS linting
  hooks.json               Routes Write/Edit/MultiEdit to bin/css-lint-hook.sh for .css files

bin/                     Shell utilities
  css-strict.sh            AXIOM GATE — exits non-zero on any ELA_001–006 violation
  js-budget.sh             AXIOM GATE — enforces ELA_005 JS budget (15 KB route / 30 KB page)
  install-git-hooks.sh     Installs a pre-commit hook that runs both gates on every commit
  css-lint-hook.sh         PostToolUse warning hook — lighter-touch than strict mode
  css-audit.sh             Directory-wide CSS lint with colored output
  css-budget.sh            Performance budget measurement (sizes, properties, specificity)
  run-evals.sh             Eval fixture structural validation
  astro-check.sh           Wrapper for npx astro check
  db-schema.sh             SQLite schema dump

eval/                    Evaluation fixtures and prompts
  prompts/                 5 eval prompts with scoring rubrics
  fixtures/                HTML/Astro fixtures (compliant + non-compliant)
  rubric.md                24-point scoring rubric (8 dimensions x 0-3)
  expected-properties.md   Required/forbidden CSS per primitive

demos/                   Reference implementations
  archive-site/            Complete Astro + SQLite archive site
  artsheet.html            Single-page vanilla demo — modular scale + core primitives
  gallery.html             Single-page vanilla demo — all primitives rendered inline

stress-tests/            Edge-case tests (1 per primitive, 8 tests each)
```

## Skill Dependency Graph

```
css-layout-engine          (foundation — no dependencies; owns ELP_001–015, 019–021, 025–032)
  └─ css-design-system     (builds on layout primitives; owns ELP_016–018, 022–024)
  └─ framework-implementations (ports layout primitives into framework components)
astro-site-architect       (depends on both CSS skills)
archival-data-engine       (independent — data layer only)

Workflow skills reference knowledge skills by name (not by dependency):
  audit-layout → css-auditor agent → css-layout-engine + css-design-system
  diagnose-layout → css-diagnostician agent → css-layout-engine + css-design-system
  refactor-to-primitives → css-layout-engine + css-design-system
  choose-primitive → css-layout-engine
  plan-migration → css-layout-engine + css-design-system
  generate-port → css-layout-engine + framework-implementations
  measure-budget → css-design-system/references/performance-rules.md via bin/css-budget.sh
```

The site-builder agent wires all 5 knowledge skills. The css-auditor and css-diagnostician use only the two CSS skills.

## Key Conventions

### IDs Are Canonical
- Primitives: `ELC_STACK`, `ELC_BOX`, `ELC_CENTER`, etc. (13 total)
- Principles: `ELP_001` through `ELP_032`
- Every recommendation must cite IDs. Never invent new ones.

### CSS Rules
- All spacing from modular scale (`--s-5` through `--s5`, ratio 1.5)
- Logical properties only (`inline-size`, not `width`)
- No media queries for layout — use intrinsic primitives
- Layer order: `@layer global, brand, components, bespoke.*`
- Performance budget: 34 KB minified / 8.5 KB gzipped
- Motion: only composited or paint-only properties may be transitioned (`opacity`, `transform`, `color`, `background-color`, `outline-color`, `box-shadow`); always gated by `prefers-reduced-motion: no-preference`. Canonical list: `skills/css-design-system/references/motion-allowlist.md`

### Astro Patterns
- Cover > Center > Stack spine for every page shell
- Build order: data model > content layer > styles > layouts > pages > components > islands > optimize
- Zero JS by default — every island must justify its hydration
- `content.config.ts` at project root (not `src/content/`)

### Plugin File Conventions
- Skills: `skills/<name>/SKILL.md` + optional `references/` directory
- Workflow skills (user-invoked) set `disable-model-invocation: true`; knowledge skills do not
- Agents: `agents/<name>.md` with model, allowed-tools (YAML list), and skills preload
- Hooks: `hooks/hooks.json` — PostToolUse matchers that route to `bin/` scripts via stdin (jq for `tool_input.file_path`)
- Eval: `eval/prompts/<name>.md` + `eval/fixtures/<name>.html|.astro`
- Manifest: `.claude-plugin/plugin.json` (name, version, description, author, homepage, repository, license, keywords)
- Settings: `settings.json` — only `agent` key is supported by Claude Code
- Escape hatches: `escapes.md` in project root — registered intentional deviations (see `css-design-system/references/escape-hatch-registry.md`)
- The `commands/` directory is unused — all former commands live as skills in `skills/<name>/SKILL.md` per `skills.md:14-17`

## Development Workflow

### Adding a New Primitive or Principle
1. Add to `skills/css-layout-engine/references/primitives.md` or `principles.md`
2. Add eval fixture in `eval/fixtures/`
3. Update `eval/expected-properties.md`
4. Add stress test in `stress-tests/`
5. Update framework references in `skills/framework-implementations/references/`

### Running Evals
- Structural validation: `bin/run-evals.sh` — checks fixture well-formedness and cross-references
- Scoring evals: Feed fixture content into eval prompts and run against the relevant agent/command

### Measuring Budget
- `bin/css-budget.sh <directory>` — measures CSS sizes, property counts, specificity against budget thresholds

### Hooks
The PostToolUse hook in `hooks/hooks.json` runs automatically on CSS file writes via `bin/css-lint-hook.sh`. It reports violations inline — do not suppress it. Fix violations before moving on.

## What This Plugin Does NOT Do
- No runtime JavaScript in layout primitives
- No component library (no Card, Button, Modal, Toast)
- No media queries for layout switching
- No arbitrary spacing values
- No theme switcher or style marketplace
- No AI-generated design systems at runtime
- **No CSS-in-JS.** Styling lives in CSS. Framework runtimes do not style DOM.
- **No budget overages without registration.** Exceeding the JS or CSS budget requires an entry in `escapes.md` with expiry.

## ID Immutability (from v1.5.0 versioning policy)

- `ELC_*` (primitives): once assigned, never change. Format `ELC_<UPPERCASE>`. Concept change → new ID, old one deprecated.
- `ELP_###` (principles): 3-digit zero-padded. Never change. Merge → deprecate one.
- `ELA_00N` (axioms): once assigned, never change. Format `ELA_###`. New axioms may be added, but only with a MAJOR version bump.
- `EDC_*` (editorial components): once assigned, never change.
- `ESC_*` (escape hatch categories): once assigned, never change.

Deprecation process: mark `deprecated: true`, add `deprecated_reason`, add `superseded_by: ELC_NEW`. Never remove. Semver:
- **MAJOR** — ID removal, axiom removal, breaking schema change
- **MINOR** — new primitive, new principle, new axiom, new optional field
- **PATCH** — docs, typos, examples, non-breaking bug fixes
