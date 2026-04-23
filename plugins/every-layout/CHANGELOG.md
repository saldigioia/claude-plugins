# Changelog

All notable changes to the Every Layout Skill Pack.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [4.2.1] - 2026-04-23

### Fixed

- `bin/css-strict.sh` — ELA_003 `!important` check produced false positives for the canonical WCAG 2.2 motion reset inside `@media (prefers-reduced-motion: reduce)`. The awk pattern that built the whitelist used `\s` (unsupported in POSIX awk), so the whitelist was always empty and the downstream `is_whitelisted_line` call never matched. Replaced with `[[:space:]]` so the whitelist actually populates.

### Added

- `bin/css-strict.sh` — consumes `escapes.md` at the root of the scanned directory. Registered `ESC_<CATEGORY>_<NAME>` entries matching `(axiom, file[, line])` suppress the corresponding violation while unexpired. Expired entries (past `Expiry:` date) still count as violations and emit an "Expired escape" diagnostic per offending line. Entries with `Expiry: none` are permanent. Escape consumption applies uniformly across ELA_001–006.
- Trailing summary diagnostics:
  - `ELA_003: N line(s) whitelisted via @media (prefers-reduced-motion: reduce)`
  - `Registered escapes consumed: N (from escapes.md: ESC_NAME, ...)`
  - `Expired escapes still counted as violations: N`
- `bin/css-strict.sh` — accepts a single CSS file as a positional argument in addition to a directory, for targeted fixture testing.
- `eval/fixtures/css-strict-motion-reset-intentional.css` — positive case: 2 `!important` lines inside `@media (prefers-reduced-motion: reduce)` (whitelisted), 2 outside (fail).
- `eval/fixtures/escapes-registered/{escapes.md,css-strict-escapes-registered.css}` — active `ESC_MUX_PLAYER_STYLING` entry; 2 registered lines suppressed, 2 unregistered lines still fail.
- `eval/fixtures/escapes-expired/{escapes.md,css-strict-expired-escape.css}` — `ESC_LEGACY_NAV_OVERRIDE` with `Expiry: 2025-01-01`; both lines fail with expired-escape diagnostic.

### Notes

- v4.2.0 shipped without a CHANGELOG entry; not reconstructed here to avoid inventing history. The 4.1.0 → 4.2.1 span represents the intermediate 4.2.0 plus this patch.

---

## [4.1.0] - 2026-04-15

### Added

**New Agent: `css-diagnostician`**
- Read-only Haiku agent that explains *why* a primitive behaves unexpectedly
- Traces custom property values, calculates thresholds, identifies root causes
- Common diagnostic patterns: Sidebar always stacking, Switcher not flipping, Grid single column, Cover not centering

**New Commands**
- `commands/plan-migration.md` — `/plan-migration` scans a CSS codebase and produces a phased adoption plan with violation counts, primitive mapping, and migration sequence
- `commands/measure-budget.md` — `/measure-budget` measures CSS against performance budget (sizes, properties, specificity)

**New Reference Files (css-layout-engine)**
- `references/form-patterns.md` — 7 canonical form layout compositions using existing primitives (stacked, inline, fieldset, multi-column, error, button alignment, search)
- `references/i18n-layout.md` — per-primitive RTL and vertical writing mode behavior, edge cases, testing checklist
- `references/subgrid-patterns.md` — 5 subgrid composition patterns on top of ELC_GRID (card alignment, data lists, form alignment, pseudo-tables, nested grids)
- `references/container-query-recipes.md` — when and how to use ELC_CONTAINER (decision tree, 3 recipes, naming conventions)

**New Reference Files (css-design-system)**
- `references/density-patterns.md` — compact/default/spacious density postures with modular scale mappings
- `references/motion-allowlist.md` — allowed transition properties (opacity, transform, color, background-color), durations (150-300ms), easings, and forbidden patterns
- `references/escape-hatch-registry.md` — convention for documenting intentional principle violations (ESC-NNN IDs, justification, review dates, limits)

**New Reference Files (design craft)**
- `references/typography-pairing.md` — 10 canonical font pairings mapped to postures (editorial-restraint, research-dense, warm-utility, etc.), fallback stacks, variable font loading strategy, `font-display: optional` enforcement
- `references/css-texture.md` — CSS-only visual richness: 3-tier layered shadow elevation scale, gradient backgrounds (warm paper, cool steel, accent glow), geometric patterns (dots, lines, graph paper), backdrop-filter frosted glass, `color-mix()` recipes, texture-by-posture mapping
- `references/editorial-craft.md` — 7 dramatic composition patterns using existing primitives: oversized headlines (clamp + narrow measure), full-bleed image breaks, pull quotes, sidenotes via Sidebar, data showcases, typographic section breaks, card hierarchy through type alone; includes scale contrast targets and whitespace-as-punctuation guide

**New Shell Utilities**
- `bin/css-budget.sh` — performance budget measurement (file sizes, custom property count, ID selector detection)
- `bin/run-evals.sh` — structural validation of eval fixtures (expected result comments, violation markers, score format, cross-references)

### Changed
- `skills/css-layout-engine/SKILL.md` — added 5 new reference file entries (form-patterns, i18n-layout, subgrid-patterns, container-query-recipes, editorial-craft)
- `skills/css-design-system/SKILL.md` — added 5 new reference file entries (density-patterns, motion-allowlist, escape-hatch-registry, typography-pairing, css-texture)
- `CLAUDE.md` — added skill dependency graph, new agent/commands, escape hatch convention, budget measurement workflow

---

## [4.0.4] - 2026-04-15

### Added
- `CLAUDE.md` — comprehensive project documentation for Claude Code orientation
- `bin/css-lint-hook.sh` — standalone PostToolUse CSS lint script (extracted from hooks.json inline command)
- `.gitignore` — ignore .DS_Store, .full-review/, swap files
- `eval/fixtures/compliant-article.html` — compliant baseline fixture (expected A grade)
- `eval/fixtures/anti-pattern-design-system.html` — design system violations fixture (15+ violations: no tokens, no motion safety, no focus visibility, hard-coded colors, z-index magic numbers, missing font-display)

### Changed
- `hooks/hooks.json` — replaced 1,066-char inline shell command with call to `bin/css-lint-hook.sh`; fixes dead `FOUND` variable, inert regex clause, and testability
- `agents/css-auditor.md` — changed deprecated `tools:` YAML list to `allowed-tools:` space-delimited string (matches site-builder.md convention)
- `commands/choose-primitive.md` — added `allowed-tools` and `argument-hint` frontmatter
- `commands/refactor-to-primitives.md` — added `allowed-tools` and `argument-hint` frontmatter
- `commands/generate-port.md` — added `allowed-tools: Read Write Edit Grep Glob`, normalized `argument-hint` to angle-bracket style
- `commands/audit-layout.md` — added `argument-hint` frontmatter for consistency
- `eval/prompts/audit_layout.md` — added fixture reference table with expected scores
- `eval/prompts/refactor_to_primitives.md` — added fixture reference table with expected primitives
- `eval/expected-properties.md` — fixed `--gutters` to `--gutter` (singular) for Center primitive, matching SKILL.md

### Fixed
- `eval/fixtures/anti-pattern-fixed-grid.html` — corrected expected score range from "4-6/18" to "3-6/24" (rubric is 24-point, not 18-point)
- `bin/db-schema.sh` — added table name validation (regex `^[A-Za-z_][A-Za-z0-9_]*$`) to prevent SQL injection; fixed unquoted `$TABLES` loop variable

### Removed
- Tracked `.DS_Store` files from git index

---

## [4.0.0] - 2026-04-09

### Added

**New Skill: `astro-site-architect`**
- Astro 5 site architecture: project structure, Content Layer API, routing, layout composition, island architecture, performance
- 5 reference files: project-structure.md, content-layer.md, routing.md, performance.md, astro-config-recipes.md
- Frontmatter: `allowed-tools`, `paths` for auto-triggering on Astro files

**New Skill: `archival-data-engine`**
- Archival-grade data handling: SQLite, libSQL, Astro DB, Drizzle ORM, custom content loaders, schema design
- 4 reference files: schema-patterns.md, custom-loaders.md, drizzle-recipes.md, data-integrity.md
- Canonical schemas for works, tracks, credits, timeline, media, sources, tags
- Complete SQLite content loader with readonly mode, digest-based incremental builds, connection cleanup

**New Agent: `site-builder`**
- Default autonomous agent for building Astro sites with Every Layout principles
- Wires all 5 skills: css-layout-engine, css-design-system, astro-site-architect, archival-data-engine, framework-implementations
- Enforces build order: data model → content layer → styles → layouts → pages → components → islands → optimize
- Uses Sonnet model for fast iteration

**New Agent: `css-auditor`**
- Read-only audit agent (Haiku model) for CSS/HTML compliance scoring
- Scores against 24-point rubric, cites ELP_*/ELC_* IDs
- Cannot modify files — analysis and reporting only

**Commands** (converted from `prompts/`)
- `commands/audit-layout.md` — with `disable-model-invocation`, `context: fork`, `agent: css-auditor`
- `commands/choose-primitive.md` — standard description frontmatter
- `commands/refactor-to-primitives.md` — with `disable-model-invocation`
- `commands/generate-port.md` — with `disable-model-invocation`, `argument-hint`
- All commands now use `$ARGUMENTS` instead of `[CODE]` placeholders

**Plugin Infrastructure**
- `settings.json` — activates site-builder agent by default
- `.mcp.json` — Cloudflare Developer Platform MCP server configuration
- `bin/astro-check.sh` — wrapper around `npx astro check` with colored output
- `bin/css-audit.sh` — directory-wide CSS lint (physical properties, arbitrary values, layout media queries)
- `bin/db-schema.sh` — SQLite schema dump with row counts, indexes, integrity check

**End-to-End Demo**
- `demos/archive-site/` — complete archive site scaffold exercising all 5 skills
  - SQLite schema with seed data (works, tracks, credits)
  - Custom SQLite content loader
  - Astro content.config.ts with typed Zod schemas
  - Base layout with Cover > Center > Stack spine
  - Archive index page with Grid layout
  - Dynamic work detail pages with getStaticPaths
  - Full token architecture (global.css) and primitive classes (primitives.css)
  - Critical CSS inline, skip link, motion safety, focus visibility

**Evaluation**
- `eval/prompts/astro_site_architect.md` — architecture evaluation prompt (0-10 scale)
- `eval/prompts/archival_data_engine.md` — data quality evaluation prompt (0-10 scale)
- `eval/fixtures/astro-layout-non-compliant.astro` — 14 violations for testing auditor
- `eval/fixtures/astro-layout-compliant.astro` — exemplary layout for baseline testing

### Changed

- `prompts/` directory renamed to `commands/` with proper frontmatter (official plugin spec compliance)
- `css-layout-engine` SKILL.md: added `allowed-tools: Read Grep Glob` and `paths` filter
- `css-design-system` SKILL.md: added `allowed-tools`, `paths`, and shell injection (`!`) for live project token context
- `framework-implementations` SKILL.md: added `allowed-tools: Read Write Edit Grep Glob` and `paths` for framework file types
- `plugin.json` description and keywords expanded to cover Astro, databases, archival content

### Removed

- `prompts/` directory (replaced by `commands/`)

---

## [3.0.0] - 2026-03-31

### Changed

**Modular Plugin Architecture**
- Decomposed monolithic skillpack into Claude Code plugin with 3 focused skills
- `css-layout-engine`: 13 primitives, 32 principles, chooser, constitution, modular scale, composition rules
- `css-design-system`: Token architecture, color theming, fluid typography, editorial components (EDC_*), escape hatches, accessibility, performance budget
- `framework-implementations`: Component ports for Astro, React, Vue, Svelte, Tailwind, vanilla CSS

### Added

- `ELP_032` (Font-Display Contract): Formalized as a first-class principle with full spec in cards-principles.json
- PostToolUse CSS lint hook (physical properties, arbitrary values, media query violations)
- Plugin manifest (`.claude-plugin/plugin.json`)
- Archive-specific content extraction (`archive-extract/`) for downstream project consumption

### Fixed

- ELP_030/031 ID collision: CLAUDE.md incorrectly reused IDs assigned to Text Wrap Balance and Scroll Snap Enhancement. Removed false labels; canonical assignments restored.

### Removed

- Archive-specific content (ARC_VIDEO, ARC_AUDIO, R2 URLs, Mux patterns, ye-archive technical debt) extracted to `archive-extract/` staging area
- Monolithic CLAUDE.md and SKILLPACK.md replaced by per-skill SKILL.md files

---

## [2.5.0] - 2026-02-13

### Added

**Vue.js Components (13)**
- `implementations/vue/Stack.vue`: Vertical spacing between siblings
- `implementations/vue/Box.vue`: Padded container with optional border
- `implementations/vue/Center.vue`: Horizontal centering with max-width constraint
- `implementations/vue/Cluster.vue`: Flexible wrapping horizontal layout
- `implementations/vue/Sidebar.vue`: Two-element layout with intrinsic switching
- `implementations/vue/Switcher.vue`: Equal columns that switch to stack below threshold
- `implementations/vue/Cover.vue`: Vertical centering with optional header/footer
- `implementations/vue/Grid.vue`: Responsive grid with intrinsic sizing
- `implementations/vue/Frame.vue`: Aspect ratio container for media
- `implementations/vue/Reel.vue`: Horizontal scrolling container
- `implementations/vue/Imposter.vue`: Superimposed/overlay positioning
- `implementations/vue/Icon.vue`: Inline SVG icon sizing and alignment
- `implementations/vue/Container.vue`: Container query context wrapper
- `implementations/vue/types.ts`: TypeScript prop interfaces
- `implementations/vue/index.ts`: Barrel export with type re-exports

**Svelte Components (13)**
- `implementations/svelte/Stack.svelte`: Vertical spacing between siblings
- `implementations/svelte/Box.svelte`: Padded container with optional border
- `implementations/svelte/Center.svelte`: Horizontal centering with max-width constraint
- `implementations/svelte/Cluster.svelte`: Flexible wrapping horizontal layout
- `implementations/svelte/Sidebar.svelte`: Two-element layout with intrinsic switching
- `implementations/svelte/Switcher.svelte`: Equal columns that switch to stack below threshold
- `implementations/svelte/Cover.svelte`: Vertical centering with optional header/footer
- `implementations/svelte/Grid.svelte`: Responsive grid with intrinsic sizing
- `implementations/svelte/Frame.svelte`: Aspect ratio container for media
- `implementations/svelte/Reel.svelte`: Horizontal scrolling container
- `implementations/svelte/Imposter.svelte`: Superimposed/overlay positioning
- `implementations/svelte/Icon.svelte`: Inline SVG icon sizing and alignment
- `implementations/svelte/Container.svelte`: Container query context wrapper
- `implementations/svelte/index.ts`: Barrel export

### Changed
- Implementation ports expanded from 4 to 6 (added Vue.js, Svelte)
- Vue port: Vue 3 Composition API with `<script setup>` and TypeScript
- Svelte port: Svelte 4 with TypeScript and `svelte:element` for polymorphic rendering
- Total files: 128 → 157

---

## [2.4.0] - 2026-02-13

### Added

**Cookbook Primitive Guides (12)**
- `cookbook/primitives/box.md`: Padded container recipes and combinations
- `cookbook/primitives/center.md`: Horizontal centering with measure, intrinsic and text variants
- `cookbook/primitives/cluster.md`: Horizontal wrapping, navigation, tag clouds
- `cookbook/primitives/sidebar.md`: Two-element layout with intrinsic stacking
- `cookbook/primitives/switcher.md`: Equal columns with threshold-based stacking
- `cookbook/primitives/cover.md`: Vertical centering with header/footer
- `cookbook/primitives/grid.md`: Responsive grid, card grids, galleries
- `cookbook/primitives/frame.md`: Aspect ratio containers for media
- `cookbook/primitives/reel.md`: Horizontal scrolling, carousels, snap scrolling
- `cookbook/primitives/imposter.md`: Overlay positioning, modals, badges
- `cookbook/primitives/icon.md`: Inline icon sizing, accessible patterns
- `cookbook/primitives/container.md`: Container query context, named containers

**Stress Test Fixtures (11)**
- `stress-tests/box-stress.html`: 8 tests — empty, inverted, padding, nesting, long content
- `stress-tests/center-stress.html`: 8 tests — measure, intrinsic, text, content-box, nesting
- `stress-tests/cluster-stress.html`: 8 tests — wrapping, justify, align, zero gap, variable widths
- `stress-tests/sidebar-stress.html`: 8 tests — stacking, side width, no-stretch, right sidebar
- `stress-tests/switcher-stress.html`: 8 tests — columns, stacking, limit, variable height
- `stress-tests/cover-stress.html`: 8 tests — centering, no-pad, overflow, large min-height
- `stress-tests/frame-stress.html`: 8 tests — ratios (16:9, 1:1, 9:16, 21:9), clipping, grid
- `stress-tests/reel-stress.html`: 8 tests — overflow, no-bar, snap, proximity, fixed height
- `stress-tests/imposter-stress.html`: 8 tests — centering, contain, margin, interactive, nesting
- `stress-tests/icon-stress.html`: 8 tests — scaling, color inheritance, spacing, buttons
- `stress-tests/container-stress.html`: 8 tests — queries, named, nested, grid, sidebar

### Changed
- Cookbook primitive guides now cover all 13 primitives (was 1/13)
- Stress tests now cover all 13 primitives (was 2/13)
- Cookbook entries total: 14 → 26
- Stress tests total: 2 → 13

---

## [2.3.0] - 2026-02-13

### Added

**React Components (8)**
- `implementations/react/Switcher.tsx`: Equal columns that switch to stack below threshold
- `implementations/react/Cover.tsx`: Vertical centering with optional header/footer
- `implementations/react/Grid.tsx`: Responsive grid with intrinsic sizing
- `implementations/react/Frame.tsx`: Aspect ratio container for media
- `implementations/react/Reel.tsx`: Horizontal scrolling container
- `implementations/react/Imposter.tsx`: Superimposed/overlay positioning
- `implementations/react/Icon.tsx`: Inline SVG icon sizing and alignment
- `implementations/react/Container.tsx`: Container query context wrapper

**Astro Components (8)**
- `implementations/astro/Sidebar.astro`: Two-element layout with intrinsic switching
- `implementations/astro/Switcher.astro`: Equal columns that switch to stack below threshold
- `implementations/astro/Cover.astro`: Vertical centering with optional header/footer
- `implementations/astro/Frame.astro`: Aspect ratio container for media
- `implementations/astro/Reel.astro`: Horizontal scrolling container
- `implementations/astro/Imposter.astro`: Superimposed/overlay positioning
- `implementations/astro/Icon.astro`: Inline SVG icon sizing and alignment
- `implementations/astro/Container.astro`: Container query context wrapper

**Evaluation**
- `eval/fixtures/anti-pattern-motion.html`: Motion safety violation fixture (ELP_028)
- `eval/fixtures/anti-pattern-focus.html`: Focus visibility violation fixture (ELP_029)
- `eval/prompts/refactor_to_primitives.md`: Refactoring evaluation prompt (0-12 scale)

### Changed
- React port now covers all 13 primitives (was 5/13)
- Astro port now covers all 13 primitives (was 5/13)
- React `index.ts` exports all 13 components
- Astro `index.ts` exports all 13 components

---

## [2.2.0] - 2026-02-13

### Added

**Cookbook Recipes (2)**
- `cookbook/recipes/responsive-table.md`: Horizontal scroll wrapper for semantic tables (Reel pattern)
- `cookbook/recipes/content-aware-has.md`: Layout adaptation using `:has()` relational pseudo-class

**Anti-Pattern Guides (5)**
- `cookbook/anti-patterns/scroll-jacking.md`: Custom scroll overrides and momentum hijacking
- `cookbook/anti-patterns/over-animation.md`: Excessive animation without motion preference gating
- `cookbook/anti-patterns/icon-only-buttons.md`: Icon buttons missing accessible names
- `cookbook/anti-patterns/zoom-prevention.md`: Viewport meta restrictions and fixed font sizes
- `cookbook/anti-patterns/infinite-scroll.md`: Infinite scroll without accessible escape hatch

**Implementation**
- `implementations/print.css`: Print stylesheet companion — linearises primitives, manages page breaks

**Evaluation**
- Two new rubric dimensions: Motion Safety (0-3) and Focus Visibility (0-3)
- Rubric scale expanded from 0-18 to 0-24 (8 dimensions)
- Audit prompt updated with ELP_028/ELP_029 checks and new anti-patterns

**Documentation**
- `chooser.md`: New "Editorial & Composite Recipes" section with recipe decision tree
- `chooser.md`: Expanded anti-patterns table (scroll-jacking, icon-only buttons, zoom prevention, over-animation)

---

## [2.1.0] - 2026-02-13

### Added

**Principles (2)**
- ELP_030: Text Wrap Balance
- ELP_031: Scroll Snap Enhancement

**Hooks (10)**
- ELP_030, ELP_031: Principle hooks
- ELH_067, ELH_068: Text wrap hooks
- ELH_069, ELH_070: Scroll snap hooks
- ELH_071, ELH_072: Fluid type scale hooks
- ELH_073: Article grid hook
- ELH_074: Sidenotes media query exception hook

**Implementation**
- `implementations/fluid-type.css`: Utopia-style 8-step fluid type scale (--step--2 to --step-5)
- Scroll-snap opt-in for Reel primitive (`data-snap` / `data-snap="proximity"`) in every-layout.css

**Cookbook**
- `cookbook/recipes/article-grid.md`: Named grid lines with content/breakout/full-bleed zones
- `cookbook/recipes/sidenotes.md`: Tufte-style margin notes (documented media query exception)

**Documentation**
- Three supplementary sections in SKILLPACK.md: Fluid Type Scale, Article Grid Pattern, Text Wrap & Scroll Snap

### Sources
- CSS Text Level 4 (CSSWG) — text-wrap: balance
- CSS Scroll Snap Module Level 1 (CSSWG)
- Chrome Developers: CSS text-wrap: balance (Adam Argyle, 2023)
- MDN Web Docs: CSS scroll snap
- Utopia fluid type scale methodology (utopia.fyi)

---

## [2.0.0] - 2026-02-13

### Added

**Principles (3)**
- ELP_027: Progressive Enhancement
- ELP_028: Motion Safety
- ELP_029: Focus Visibility

**Hooks (6)**
- ELH_061, ELH_062: Progressive enhancement hooks
- ELH_063, ELH_064: Motion safety hooks
- ELH_065, ELH_066: Focus visibility hooks

**Implementation**
- Motion-safety reset (`prefers-reduced-motion`) in every-layout.css
- Focus-visible styles (`:focus-visible` / `:focus:not(:focus-visible)`) in every-layout.css

**Documentation**
- Supplementary section: Progressive Enhancement & Accessibility Safety in SKILLPACK.md
- New conflict resolution entries in CONSTITUTION.md
- Expanded code review checklist in CONSTITUTION.md

### Fixed
- MANIFEST.json version (was 1.4.0, now 2.0.0)
- MANIFEST.json principle count (was 24, now 29)

### Sources
- Resilient Web Design (Jeremy Keith, 2016)
- WCAG 2.1 SC 2.3.3: Animation from Interactions (W3C)
- WCAG 2.2 SC 2.4.7/2.4.11: Focus Visible/Appearance (W3C)
- MDN Web Docs: prefers-reduced-motion, :focus-visible

---

## [1.5.0] - 2026-01-25

### Added

**Principles (2)**
- ELP_025: Fluid Sizing via Clamp
- ELP_026: Accessibility-Safe Fluid Values

**Hooks (3)**
- ELH_058: Clamp trio pattern
- ELH_059: Zoom-safe fluid values
- ELH_060: Growth rate control

**Documentation**
- Supplementary section: Fluid Typography in SKILLPACK.md

### Source
- Fluid typography with CSS clamp (Piccalilli, Andy Bell)

---

## [1.4.0] - 2026-01-25

### Added

**Principles (3)**
- ELP_022: Consistent Shadow Light Source
- ELP_023: Layered Shadow Realism
- ELP_024: Typography-Relative Icon Sizing

**Hooks (7)**
- ELH_051, ELH_052, ELH_053: Shadow design hooks
- ELH_054, ELH_055, ELH_056, ELH_057: Component architecture hooks

### Source
- Designing Beautiful Shadows (Josh W. Comeau)
- How I build a button component (Piccalilli, Andy Bell)

---

## [1.3.0] - 2026-01-25

### Added

**Principles (1)**
- ELP_021: Subgrid for Cross-Item Alignment

**Hooks (2)**
- ELH_049, ELH_050: Subgrid hooks

### Source
- A handy use of subgrid to enhance a simple layout (Piccalilli, Andy Bell)

---

## [1.2.0] - 2026-01-25

### Added

**Principles (2)**
- ELP_019: Container Query Measurement Invariance
- ELP_020: Inline-Size Containment Default

**Hooks (3)**
- ELH_046, ELH_047, ELH_048: Container query hooks

### Source
- A Friendly Introduction to Container Queries (Josh W. Comeau)

---

## [1.1.0] - 2026-01-25

### Added

**Principles (3)**
- ELP_016: Theme-Aware Color Tokens
- ELP_017: Surface Elevation via Lightness
- ELP_018: Derived Color Variants

**Implementation**
- color-theming.css

**Vocabulary**
- `theming` tag added

### Source
- A Pragmatic Guide to Modern CSS Colours (Piccalilli)

---

## [1.0.0] - 2026-01-23

### Added

**Principles (15)**
- ELP_001: Composition Over Inheritance
- ELP_002: Intrinsic Sizing Over Extrinsic Sizing
- ELP_003: Universal Border-Box
- ELP_004: Logical Properties
- ELP_005: Modular Scale Spacing
- ELP_006: Measure Constraint
- ELP_007: Global Element Styles
- ELP_008: Child-Only Layout Effects
- ELP_009: Algorithmic Self-Governing Layout
- ELP_010: Browser Delegation
- ELP_011: Custom Properties for Configuration
- ELP_012: Prefer Gap Over Margin
- ELP_013: Container Queries Over Media Queries
- ELP_014: Intrinsic Layout First
- ELP_015: Accessible Icons

**Primitives (13)**
- ELC_STACK: Vertical spacing between siblings
- ELC_BOX: Padded, bordered containers
- ELC_CENTER: Horizontal centering with measure
- ELC_CLUSTER: Horizontal wrapping with gaps
- ELC_SIDEBAR: Fixed + flexible two-element layout
- ELC_SWITCHER: Equal columns that stack below threshold
- ELC_COVER: Vertical centering with header/footer
- ELC_GRID: Responsive grid without media queries
- ELC_FRAME: Aspect ratio container for media
- ELC_REEL: Horizontal scrolling container
- ELC_IMPOSTER: Overlay centering
- ELC_ICON: Inline icons that scale with text
- ELC_CONTAINER: Container query context

**Implementation Ports**
- Vanilla CSS: Complete toolkit with modular scale
- Tailwind: Plugin with tokens and utilities
- React: TypeScript components with typed props
- Astro: Framework components

**Documentation**
- Chooser decision tree (`chooser.md`)
- Memory hooks (`hooks.md`)
- Cookbook with primitive guides, recipes, anti-patterns
- Stress test fixtures

**Evaluation Harness**
- Scoring rubric (0-18 scale)
- Expected CSS properties per primitive
- Eval prompts for testing
- Anti-pattern test fixtures

**Skill Pack Infrastructure**
- SKILLPACK.md entry point
- QUICKSTART.md 5-minute guide
- CONSTITUTION.md priority rules
- VERSIONING.md update procedures
- Operator prompts (4)
- Index and manifest files

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

---

## [Unreleased]

### Planned
- Populate archival-data-engine with real schema examples from ye-archive-rebuild databases
- Study ye-archive site for layout patterns, routing structure, CSS architecture
- Expand site-builder agent with end-to-end deployment workflow
