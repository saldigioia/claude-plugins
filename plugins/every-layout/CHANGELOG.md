# Changelog

All notable changes to the Every Layout Skill Pack.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [4.11.0] - 2026-07-11

Campaign 3 Phases C3–C4 ("eyes"): the rendered adversarial tier. The retro's
central finding — every screenshot the field deployment ever took was
light-mode, comfortable-width, motion-on — gets a mechanical answer (render
+ probe) and a judgment answer (a model-judged composition checklist),
plus the process authority that keeps findings from recurring.

### Added — the rendered tier (Phase C3)

- **`bin/render-sweep.sh` + `bin/lib/render-sweep.cjs`** — opt-in harness:
  drives a locally resolvable playwright (never bundled; `--pw-root` can
  borrow a sibling project's) across a route list at ten widths
  (320–1440), light AND dark emulated, reduced-motion emulated for stable
  captures; serves a dist dir itself when asked (`--serve-dist`, built-in
  static server). Prints a per-route probe table and writes `probes.json`:
  horizontal overflow, the ELP_035 unpainted-canvas ground (computed
  html/body transparency + a literal bottom-center pixel decoded from the
  PNG), and the ELP_034 mid-word fracture (any heading word spanning two
  line boxes). Without node/playwright it prints `SKIP` and exits 0 —
  default CI stays offline and dependency-free forever. Wired as
  `bin/ci.sh --with-render` (honors `RENDER_PW_ROOT`).
- **`/render-audit` skill (15th skill, tier 4)** — runs the sweep, then
  reviews captures against the composition checklist static gates cannot
  see: heading rank monotonic, one ink/family per tier as rendered, shared
  axes, device species (the CTA test), reserved-slot vs optical centering,
  dark-scheme ground, narrow fractures, breakpoint seams. Report mirrors
  css-auditor's finding shape, explicitly labeled MODEL-JUDGED, no /24
  score — that scale belongs to the static rubric.
- **Validation against the motivating field case** — the pre-remediation
  Window Classics tree (27a1883, disposable worktree): the 4.10.0 static
  gates + hook mechanically reproduce **6 of the retro's 7 findings**
  (body word-break at the exact line, light-dark-without-color-scheme,
  unpainted 600px-gradient canvas, near-duplicate inks, 640/641
  breakpoints — plus a 768/769 sibling the retro itself missed — and both
  perpetual hero animations); the remaining rank/species classes are
  exactly the /render-audit checklist. Two gate refinements fell out:
  scoped-`.astro` ground/color-scheme records no longer satisfy other
  files' checks (a dev page's body background never painted the real
  site's canvas; `is:global` still counts corpus-wide), and the
  infinite-animation warning now scans framework-template style blocks
  (the two hero animations lived in index.astro, not a .css file).
- **css-auditor honesty** — new "Static Composition Subset" (what IS
  source-checkable: ELP_034/035/016, heading-tier tokens, species
  candidates) and a mandatory rendered-tier referral line closing every
  whole-project audit; mirrored in `/audit-layout`.
- **`eval/fixtures/composition-page.html` + `eval/prompts/composition_audit.md`**
  — the WC seven in miniature (subordinate h1, two near-blacks, body-wide
  word-break, light-dark sans color-scheme, unpainted gradient body,
  640+641, decorative infinite animation); one artifact feeding the
  gates, the hook, the render probes, and the model-judged checklist. The
  prompt scores tier honesty: overclaiming rendered findings from source
  is penalized.
- **Scaffold discipline** — `/scaffold-system` now also emits
  `render-sweep.config.json` and `PROTECTED-COPY.md` (named prose zones,
  the copy-vs-decoration classification question, per-sentence sign-off;
  cites ELP_034/035) from new plugin-root templates, and annotates the
  ELP_035 painted-ground line it already emitted.

### Added — authority & process (Phase C4)

- **Constitution** — code-review checklist gains a Typography & Context
  block (ELP_034/016/035/infinite-motion) and a Review Process block:
  *hunt the class* (a confirmed violation triggers a sibling grep before
  the finding closes), *species rule* (a device that exists twice gets one
  owner file; a second variant costs a recorded decision), *backlog aging*
  (older than one release cycle → scheduled or wontfixed).
- **site-builder copy authority** — classify copy vs decoration before any
  text touch; never invent/reword/delete owner copy; subtraction requires
  the owner's exact surviving sentence; visible design decisions ship as
  options-with-renders. (Also fixed a stale "32 documented ELP_*".)
- **Diagnostician traces** — "site renders on black in dark mode"
  (color-scheme? reachable root ground? sized background stopping short?
  → ELP_016/035) and "word fractures mid-heading at narrow width" (walk
  the cascade for the granting selector → ELP_034), in both the agent and
  `/diagnose-layout`.
- **Tier 4 in the honesty tables** — README + CLAUDE.md enforcement tiers
  gain the rendered row and name the defect classes that live only there;
  the release checklist gains the render-sweep step.
- **Dogfood** — full `bin/ci.sh --with-render` over the archive-site demo:
  40 captures (2 routes × 10 widths × 2 schemes), probe table clean
  (painted ground verified to the pixel: #fafafa light / #1a1a1a dark).

---

## [4.10.0] - 2026-07-10

Campaign 3 Phases C1–C2 ("teeth"), from the Window Classics performance
review (`CURATION-RETRO.md`): the site passed every gate this plugin ships
and still carried seven composition/context defects — one of which violated
doctrine the plugin already publishes. This release gives that doctrine
mechanical witnesses and runs the word-break fracture through the full
field-report pipeline.

### Added — enforce what the doctrine already claims (Phase C1)

- **`light-dark()` ⇒ `color-scheme` gate (ELP_016)** — `css-strict.sh` fails
  when a corpus uses `light-dark()` but declares no `color-scheme` anywhere
  (the exact WC F7 miss: the token docs claimed it, nothing noticed it never
  shipped). `.html` documents are judged per-file (`<meta
  name="color-scheme">` satisfies the opt-in); `.css`/`.astro` fragments are
  judged as one corpus; single-file scans downgrade to a warning. Fixture
  pair `gates/gate-colorscheme-{fail,pass}.css`.
- **Painted-ground gate (new ELP_035)** — a `body`/`html`/`:root` block that
  paints a `background-image`/gradient or sets `background-size` must have a
  reachable `background-color` ground; the WC body painted a 600px gradient
  over a transparent canvas and every dark-preferring browser rendered the
  site on black below the fold. Same document/corpus/warning split. Fixture
  pair `gates/gate-painted-ground-{fail,pass}.css`.
- **ELP_035 "Painted Ground" spec** — full spec in
  `css-design-system/references/principles.md` (the canvas is not a color;
  gradients are decoration layered above the painted ground; pairs with
  ELP_016), registered in `ids.json`, hook in `hooks.md`, pointer stub in
  the layout catalog.
- **Infinite-motion rule** — `motion-allowlist.md` now takes a position on
  `animation-iteration-count: infinite`: allowed ONLY for status/progress
  indication, marked `/* motion: status */`; decorative infinite motion is a
  violation even under `prefers-reduced-motion: no-preference` (the WC hero
  ran two perpetual animations through this file unremarked). Warn-tier
  check in `css-lint-hook.sh`; rubric dimension 7 gains the check line.
  Fixture pair `gates/gate-motion-infinite-{decorative,status}.css`.

### Added — ELP_034 "Scoped Typographic Permissions", full pipeline (Phase C2)

- **ELP_034 spec** — `word-break`/`overflow-wrap`/`hyphens` are content-tier
  grants: legal on the container that holds untrusted-length content, never
  on `body`, `html`, `:root`, `*`, or heading selectors. A global grant is a
  site-wide license display type eventually cashes in ("The Manufacturer /
  s We Trust" at 390px). The existing content-tier prescriptions
  (failure-mechanics §2, print URL-breaking) stay correct — the principle
  draws the line at *where the permission is granted*.
- **ELP_034 gate** — hard in `css-strict.sh` (ELA_003; subject-compound
  analysis, `@media print`/`@page` + non-grant values whitelisted), warn in
  `css-lint-hook.sh`; shared scanner `bin/lib/typo-scope.sh` (the 2.8
  single-source pattern). Fixture pair `gates/gate-wordbreak-{global,scoped}.css`.
- **Anti-pattern #9 "Body-Wide Word-Break (The Global Permission)"** —
  cookbook entry with the "works at every width the author tested" signature
  and the reviewer heuristic ("who granted this, and to whom?"); eval
  fixture `anti-pattern-global-wordbreak.html` distilled from the WC case.
- **Failure-mechanics §2 gains the blanket-permission trap** — the defense
  belongs on the token's container; the global shortcut converts every
  narrow heading into a fracture site.
- **Heading-tier contract** — `typography-scale.md`: one ink and one family
  per tier, monotonic rank (the page title participates in the same ramp —
  WC shipped a 40px/700 h1 above 48px/500 h2s), sizes from the `--step-*`
  ramp; `typography-pairing.md` anti-patterns gain the two-inks and
  second-family-in-tier rows, citing the `#111827`-vs-`#251f1b` drift case.
- **Near-duplicate token tripwire** (warn-tier, never fails) —
  `css-strict.sh` prints pairs of distinct hex-literal tokens within a max
  per-channel delta of 16; exact-value aliases are ignored. Honest limits
  documented (bare hex only — no oklch/color-mix math; a tripwire, not
  colorimetry). `token-rules.md` gains the "near-duplicates are drift"
  section. Fixture `gates/gate-token-drift.css`.
- **Breakpoint-proximity tripwire** (warn-tier) — two distinct `@media`
  `min-width` px values ≤ 2px apart print a warning (WC shipped 640 and 641
  in one component); `max-width` deliberately ignored so the 640/641
  max/min hand-off idiom stays legal. Fixture `gates/gate-breakpoint-adjacent.css`.
- **`stress-tests/typography-stress.html`** — Manufacturers-class, URL-class,
  and all-caps headings at 320/360/390 containers, with and without
  content-scoped grants, plus a deliberately-scoped failure exhibit
  simulating the global grant (the real global form fails the gate).

### Changed

- `axioms.md` enforcement notes synced to the new checks (ELA_002 gains the
  two context checks; ELA_003 gains the reach-in-reverse rule).
- `test-gates.sh` grows from 24 to 38 assertions (C1/C2 batteries).
- Counts: 35 principles (28 layout + 7 design-system), 14 stress tests;
  `ids.json` registers ELP_034/ELP_035.

---

## [4.9.0] - 2026-07-07

### Added — gate truthfulness & new tripwires (Campaign 2 Phase H2)

- **True violation counts** — `css-strict.sh` now counts every finding while
  display-capping at 5 per (axiom, file), with an "… and N more" remainder
  line: "N violation(s)" is the real N, never a display artifact.
- **Escape-limit advisories** (warn-tier; the limits stay advisory but silent
  drift ends): `escapes.sh` warns when the registry exceeds the 10-row
  per-project cap; `css-strict.sh` warns when one file's suppressions exceed
  the per-file cap of 3.
- **Tailwind arbitrary-value tripwire (ELA_004)** — `ports-lint.sh` flags
  bracket-literal utilities (`p-[17px]`) in class attributes across
  .html/.astro/.tsx/.jsx/.vue/.svelte; the axiomatic-values regime no longer
  stops at CSS files.
- **`ports-lint.sh --docs`** — extracts fenced code blocks from Markdown and
  scans them, giving the reference-port docs standing regression protection;
  wired into `ci.sh` over react/vue/svelte/astro.md (58 blocks CLEAN).
- **`ci.sh --with-build` (opt-in)** — builds the archive-site demo and runs
  the real `js-budget.sh` against its `dist/` (expects the 4.8.1 escapes);
  default CI stays offline and dependency-free.
- **Baseline registry verified against live sources** (MDN, web.dev Baseline
  digests, web-features tracker; every row now carries `Last verified:
  2026-07-07`). Nine corrections, three consequential: `accent-color` is NOT
  Baseline (Safari control-mark contrast bug) → escape-gated;
  **cross-document View Transitions are NOT Baseline** (Firefox still flags
  the at-rule) → escape-gated, and `view-transitions.md` §3 rewritten
  accordingly; `overflow-clip-margin` → escape-gated (Safari never shipped
  it). Promotions: CSS anchor positioning reached newly-available (Jan
  2026, Firefox 147), `lh` reached widely. Date fixes: Popover's real
  Baseline is Jan 2025 (2024 announcement retracted); `<details name>` is
  Sept 2025; subgrid/`:user-valid` crossed to widely in 2026.
- **Policy sharpened in the registry**: a complete no-support fallback does
  NOT waive escape registration for a non-Baseline feature — it only makes
  the escape trivially justifiable. The tier measures engine interop
  (ELA_006); degradation quality is a separate virtue. (This supersedes the
  broader exemption rule 4.7.0's view-transitions doc had generalized.)
- **Enforcement-tiers honesty table** (README + CLAUDE.md): advice → hook
  warnings → pre-commit/CI teeth; "adoption = contract" is realized only at
  tier 3. **Release checklist** added to CLAUDE.md. Invariant comments on
  the plugin's only two skill-load shell surfaces. `js-budget.sh` labels
  renamed to what is measured (per-file route proxy / dist-total page
  proxy) with the heuristic documented in `performance-rules.md`.
- `test-gates.sh` grows to 24 assertions; eval suite to 72 checks.

---

## [4.8.1] - 2026-07-07

### Fixed — Campaign 2 Phase H1 (from the ambiguities & vulnerabilities review)

- **gallery.html loaded no primitive CSS** — its stylesheet href still
  pointed at the never-existing `implementations/vanilla/` path (only the
  stress tests had been re-pointed in 4.6.0). Now links
  `every-layout.css`; verified in a real browser (`.grid` computes
  `display: grid`, Stack owl spacing resolves, Cover honors `--min-height`).
  Also fixed the same ghost path in cookbook-antipatterns prose.
- **astro.md per-instance ID machinery removed** (Cover, Sidebar, Stack,
  Switcher + Container's conditional block): `Math.random()` ids and
  `#{id}`-keyed `<style>` blocks were wrong three ways — ID selectors
  (ELA_003), non-deterministic builds (ELA_006), and plain `<style>` blocks
  are never templated by Astro, so the variant CSS was emitted as literal
  dead selectors. All variants are now static rules keyed on class/data
  attributes (`data-side`, `data-limit`, `data-recursive`, child-side
  `data-split-after`, `.principal`/`[data-centered]`); the selector-string
  `centered` prop and numeric `splitAfter` are gone, matching the other
  ports. Container renamed to the canonical `containerName`/
  `--containerName` parameter. New porting-guide section: the `define:vars`
  trust boundary (author-controlled CSS only; plain `<style>` is static).
- **Modular-scale calc chains restored** in `demos/every-layout.css` and the
  `/scaffold-system` tokens template (resolved values kept as comments) —
  and the chain's rationale corrected everywhere: custom properties inherit
  as *computed* values, so the long-documented "override `--ratio` per
  subtree" pattern never worked in CSS. Verified in-browser: changing
  `--ratio` at `:root` recomputes the scale (24px → 20px); a subtree
  override requires re-declaring the chain (pattern added to
  token-rules.md). Re-applied the frozen-bare-names clarification that had
  been lost from token-rules.md.
- **react-port budget honesty** — new `demos/archive-site/escapes.md`
  registers the demo page's deliberate React-runtime overage
  (`ESC_JS_EXCESS`: `_astro/*.js` + `page-total`), so a real build passes
  `js-budget.sh` by registered exception instead of by never being measured;
  page header documents it.
- **js-budget.sh trailing-slash bug** — `dist/` (with slash) broke the
  dist-relative path strip and with it escape-glob matching; normalized, with
  a regression assertion in `test-gates.sh` (now 17 assertions).

---

## [4.8.0] - 2026-07-06

### Added — backlog closed (Improvement Plan Phase 7); the plan is fully executed

- **`bin/archival-audit.sh`** — ELA_006 external-dependency sweep: remote
  `url()`, remote `@import`, external `<link>`/`<script>` in CSS/HTML/Astro.
  Flag-only by default, `--strict` for CI; wired into `bin/ci.sh` over demos
  and stress-tests (verdict on the shipped corpus: SELF-CONTAINED, 26 files,
  zero external runtime dependencies).
- **`css-layout-engine/references/failure-mechanics.md`** — the spec-trap
  family reference seeded by ELP_033: automatic minimum size (+ the
  flex-column `min-block-size: auto` twin), unbreakable tokens vs
  min-content, `aspect-ratio` feedback, percentage padding, `auto` margins vs
  `justify-content` (why Cover centers the way it does), margin-collapse
  contexts (why the Stack owl is safe), and non-visible `overflow`'s
  BFC-plus-clipping bundle (sticky breakage, inset focus-ring clipping).
- **Field-report pipeline** documented in CLAUDE.md → Development Workflow:
  the incident → fixture → principle/mechanics-entry → recipes → diagnostics
  → gate template that produced ELP_033; ids.json registration added to the
  new-primitive checklist.
- `baseline-registry.md`: rows for `overflow: clip` (allowed) and
  `overflow-clip-margin` (additive/partial). `motion-allowlist.md`: watch-tier
  section for scroll-driven animations and `interpolate-size`.
  `print-rules.md`: `@page` margin-box guidance (physical units are correct
  on paper; ELP_004 governs screen flow).
- `demos/every-layout.css`: print overrides section (linearisation was in
  vanilla.md but missing from the built artifact).

### Fixed

- **Port Cover defaults no longer pin `100vh`** — `minHeight` is now optional
  with no default in the React/Vue/Svelte/Astro port docs, so the
  stylesheets' `100dvh` chain applies when unset (Astro's self-contained
  scoped Cover carries the chain inline). Passing `minHeight` pins a single
  fixed value, documented as such.
- **Focus token drift reconciled** — every recipe now uses the canonical
  `var(--br-color-focus, currentColor)` (the bare `--color-focus` name was
  never defined by any tier); `color-theming.css` now defines
  `--br-color-focus` with `light-dark()`.

### Decided

- No vnu/HTML-validity gate (external tooling conflicts with the
  zero-dependency `bin/` ethos; revisit on demand). No 15th
  "conventions" skill — everything consumer-facing already ships via skills;
  CLAUDE.md is deliberately the contributor doc.

---

## [4.7.0] - 2026-07-06

### Added — the philosophy-forward expansion wave (Improvement Plan Phase 6)

- **`css-layout-engine/references/native-interaction.md`** — the zero-JS
  interactivity catalog: `<details name>` exclusive accordions, `<dialog>`
  (with the honest one-line `showModal()` ELA_005 boundary), Popover API,
  `:user-valid`/`:user-invalid`, `<datalist>`, `accent-color`,
  watch-tier `field-sizing`/`interpolate-size` — each with markup contract,
  Baseline status, fallback obligation, and the JS pattern it replaces.
  Companion "Validation UX (zero-JS baseline)" section in `form-patterns.md`.
- **`css-layout-engine/references/baseline-registry.md`** — ELA_006's feature
  policy operationalized as a table (allowed / additive / escape-gated per
  Baseline status); `axioms.md` now points to it.
- **`astro-site-architect/references/view-transitions.md`** — cross-document
  View Transitions (`@view-transition`) as the 0 KB-JS alternative to
  `<ClientRouter />`'s ~3 KB; decision table, reduced-motion rules, worked
  archive-site example. SKILL.md now leads with the zero-JS option.
- **`/scaffold-system`** (14th skill, 9th workflow) — greenfield scaffolder:
  exact modular-scale tokens + the 9 mandatory `--br-*` brand tokens with
  `light-dark()`, contractual layer order, primitives copied verbatim from
  `demos/every-layout.css`, `escapes.md` from the template, optional
  pre-commit gate install. Never overwrites; brownfield → `/plan-migration`.
- **`ids.json`** — machine-readable registry of every canonical ID
  (ELA/ELC/ELP/EDC/ESC); `bin/run-evals.sh` now cross-checks that every ID
  cited in skills/agents/eval exists in it (all 62 cited IDs verified).
- **Eval coverage**: new prompts `css_layout_engine.md` (4 scenarios incl. an
  ELP_033 hard-fail gate) and `diagnose_layout.md`, with the
  `diagnose-broken-primitives.html` fixture (4 planted, gate-clean
  misbehaviors). Eval suite: 70 checks green.
- **Cover `dvh` upgrade** — every shipped Cover recipe now carries the
  two-declaration chain (`100vh` fallback line, then `100dvh`) for stable
  mobile viewports; port-default modernization noted in the plan backlog.
- **Container-relative units** — `cqi` fluid-type recipe (ELP_025/026-composed)
  and a nested-container performance note in `container-query-recipes.md`.
- **Archival durability ranking** in `archival-data-engine`: SQLite file >
  local libSQL > Astro DB > D1, with the plain-`.db`-in-repo invariant named.
- **Dark-mode shadows** (`css-texture.md`): lead-with-lightness recipe,
  `color-mix()` surface-hue shadows, `light-dark()` two-mode shadow tokens.
- **Mixed-direction content** (`i18n-layout.md`): `dir="auto"`, `<bdi>`,
  `unicode-bidi`, mirrored-punctuation pitfalls, RTL testing checklist items.

### Changed

- Remaining bare-`1fr` tracks in reference recipes converted to
  `minmax(0, 1fr)` per ELP_033 (subgrid patterns, container-query recipe,
  sidenotes, print rules).
- `token-rules.md` clarifies that the frozen bare-name tokens (`--ratio`,
  `--s*`, `--measure`, `--border-thin`) are never migrated to `--gl-*`.

---

## [4.6.0] - 2026-07-06

### Added — ELP_033 Neutralized Auto-Minimum (from field report `layout-edits.md`)

A real-world "works wide, clips narrow" bug — three `1fr` swatch columns with
`aspect-ratio` chips clipping at narrow card widths — is now a first-class
principle, baked through every layer:

- **ELP_033** in `css-layout-engine/references/principles.md`: every fraction
  track carries a definite minimum or 0 (bare `1fr` ≡ `minmax(auto, 1fr)` is
  the violation); inline-shrink primitives zero their children's automatic
  minimum. Exceptions documented: Reel (`flex: 0 0 auto` by design), Sidebar
  content pane (explicit `--content-min` already replaces `auto`).
- **Canonical recipes updated** (SKILL.md, primitives.md, vanilla.md,
  tailwind.md, astro.md, `demos/every-layout.css`,
  archive-site `primitives.css`): `.grid > *`, `.switcher > *`,
  `.cluster > *`, and the Sidebar pane gain `min-inline-size: 0`.
- New cookbook recipe **"Fixed-N Equal Columns (Swatch Grid)"** — the catalog
  hole that caused the original bug (`repeat(var(--columns), minmax(0, 1fr))`);
  chooser entry added.
- New anti-pattern #8 **"Bare Fraction Tracks (The Auto-Minimum Floor)"** +
  eval fixture `anti-pattern-auto-min.html` distilled from the field report.
- **css-diagnostician**: new diagnostic pattern "column/child clipped at
  narrow widths" (the symptom previously had no diagnostic path).
- Constitution code-review checklist gains the one-line reviewer heuristic;
  rubric dimension 1 and css-auditor check ELP_033; memory hook added.
- `css-lint-hook.sh`: warning-tier check for bare `1fr` in `grid-template-*`.
- **Reel keyboard access** (accessibility tier 1): `tabindex="0"` +
  `role="region"` + `aria-label` documented in primitives.md and
  `accessibility.md`.

### Added — gate hardening (Improvement Plan Phase 2)

- **`bin/css-strict.sh`**: multi-line viewport `@media` detection (block-aware
  scan); 0-2-0 specificity cap actually computed (functional pseudo-class
  wrappers and their arguments excluded by documented design, so canonical
  primitives stay legal); `--archival` completed (`@supports not (…)` check
  added, brace-depth counter fixed); **`.html`/`.astro` scanning** — `<style>`
  blocks (line numbers preserved) plus inline `style=""` attributes, closing
  the demo blind spot.
- **`bin/ports-lint.sh`** (new): CSS-in-JS detector giving ELA_005's "no
  CSS-in-JS" its first enforcement — styled-components/emotion imports,
  `css`-template literals, `React.CSSProperties` objects, runtime `<style>`
  injection, bespoke keys in style objects. Warning-tier via the PostToolUse
  hook, `--strict` for CI.
- **`bin/lib/primitive-params.sh`** (new): single source of truth for
  inline-styleable primitive parameters, shared by the hook, the strict gate,
  and ports-lint; extended with the documented `--side-width`,
  `--content-min`, `--justify`, `--align`, `--border-width`, `--n`, `--d`
  (etc.) parameters.
- **`bin/test-gates.sh`** (new): 16-assertion acceptance battery with gate
  fixtures under `eval/fixtures/gates/`; wired into `bin/ci.sh`.
- `bin/lib/escapes.sh`: malformed/impossible `Expires` dates now warn loudly
  and never suppress.
- `axioms.md` enforcement text synced to what the gates actually do (icon
  `em`/`cap` whitelist, comment stripping, reduced-motion `!important`
  whitelist, specificity approximation, gzip measurement, ports-lint).

### Changed — self-compliance (the plugin passes its own gates)

- **React/Vue/Svelte reference ports rewritten** to the compliant pattern:
  class + `--custom-property` parameters only (Svelte uses `style:--x`
  directives); no declaration objects, no runtime `<style>` injection.
  Boolean variants map to `data-*` attributes; `splitAfter` replaced by the
  child-side `data-split-after` marker everywhere.
- **Port parameter contract reconciled** across all six ports + stylesheets:
  Box `--border-width` (per-instance) falling back to `--border-thin`
  (global token); Frame dual API `--ratio` or `--n`/`--d`; Container
  `--container-name`; Cover `.principal` (canonical) with `[data-centered]`
  as the port alias; Cluster `--justify`/`--align` now consumed by the CSS.
- **`demos/every-layout.css`** (new): the canonical single-file vanilla
  stylesheet; stress tests now link it (the old
  `../implementations/vanilla/every-layout.css` href pointed at a directory
  that never existed).
- **Demo react-ports** rewritten: per-instance unscoped `<style>` injection
  removed (it duplicated rules per instance and leaked `recursive`/
  `splitAfter` selectors to every `.stack` on the page).
- **`demos/gallery.html`, `demos/artsheet.html`, all 13 stress tests** now
  pass the hardened gate with zero violations (bespoke inline styles moved to
  classes, physical properties → logical, arbitrary px → rem/tokens, a
  genuine 0-3-0 selector reduced, one out-of-whitelist `!important` removed).
- **65ch measure canonicalized** as the fallback default across cookbooks and
  ports (explicit `--measure` token overrides remain legal and documented).
- expected-properties.md: Cover marker corrected to `.principal`; ELP_033
  requirements added; bare-`1fr` forbidden for Grid.
- escape-hatch byte limits marked advisory (nothing enforced them).

---

## [4.5.1] - 2026-07-06

### Fixed — integration & documentation truth (Improvement Plan Phase 1)

- **Agent frontmatter**: renamed `allowed-tools:` → `tools:` in all three
  agents (`css-auditor`, `css-diagnostician`, `site-builder`). `allowed-tools`
  is a *skill* key; an agent using it gets the default (full) toolset, so the
  auditor/diagnostician "read-only" guarantee was prompt-only. With `tools:`
  the restriction is configuration-enforced.
- **css-auditor**: now applies the rubric's cascade rule (Motion Safety or
  Focus Visibility at 0/3 caps the total at 16/24; both at 0/3 cap at 12/24)
  and reports `Raw → After cascade` scores, matching `eval/rubric.md`.
- **site-builder**: new Traceability section — must cite ELC_*/ELP_* IDs in
  every layout recommendation; CSS/JS budget numbers inlined (34 KB min /
  8.5 KB gzip CSS; 15 KB route / 30 KB page JS).
- **strict-check**: report template now covers all six axioms — added the
  missing `ELA_006` row to the CSS gate table and labeled the JS budget gate
  as `ELA_005`.
- **physical-properties.md**: documented the previously implicit accepted
  exception — CSS `width`/`height` with `em`/`cap` units on inline icons
  (ELC_ICON, per ELP_024), matching the existing `css-strict.sh` whitelist.
- **css-layout-engine SKILL.md**: modular-scale range typo in the ELP_005
  row (`--s-2` → `--s-5`).
- **CLAUDE.md**: corrected architecture counts (26 layout principles owned by
  the layout engine, 17 reference files); settings.json note updated
  (supported keys are `agent` and `subagentStatusLine`).
- **README**: `paths:` frontmatter described accurately as an
  availability-scoping mechanism, not an on-edit auto-trigger.

### Removed

- Empty `settings.json` (was `{}`; set no supported keys).
- Inert `paths:` frontmatter from the user-invoked `refactor-to-primitives`
  and `plan-migration` skills (`disable-model-invocation: true` makes path
  scoping meaningless).

### Added

- **`bin/ci.sh`** — single CI entry point for this repo: syntax-checks every
  script in `bin/`, runs the escape acceptance tests, the eval structural
  validation, and the CSS strict gate against the demo site.
- **`IMPROVEMENT-PLAN.md`** — phased work plan (4.5.1 → 4.7.0) from the
  2026-07-06 full review + the `layout-edits.md` field report (auto-minimum
  clipping → ELP_033, scheduled for 4.6.0).

---

## [4.5.0] - 2026-06-04

### Reconciliation — merge of the two divergent lineages

This release merges the standalone lineage (4.3.0 Astro 6 + 4.4.0 escape-aware
gates + eval green-up) with the vendored marketplace lineage (4.2.1 + 4.2.2),
which had diverged after 4.1.0. Neither was a superset; this is the best-of-both.

### Added (ported from the 4.2.x lineage)

- **Inline-style detection** in `bin/css-lint-hook.sh` for framework templates
  (`.astro/.tsx/.jsx/.vue/.svelte`): bespoke declarations inside `style="..."`
  fail `ELA_002`; the primitive-parameter custom properties remain allowed. Plus
  the `inline-style-{bespoke,mixed,primitive-param}.astro` fixtures.
- **Single-file argument** for `bin/css-strict.sh` (pass one `.css` file for
  targeted fixture testing, in addition to a directory).
- `eval/fixtures/css-strict-motion-reset-intentional.css` — regression fixture
  for the prefers-reduced-motion whitelist (2 whitelisted, 2 failing).

### Changed — unified escape engine

- The two escape designs are reconciled onto **one** system: the table format
  (`bin/lib/escapes.sh`, honored by **both** `css-strict.sh` and `js-budget.sh`,
  `ESCAPES_TODAY`-pinnable) **plus** the 4.2.x lineage's **line-level precision**,
  now expressed as an optional **`Lines`** column (`-` = whole file; `9` / `9,10`
  / `9-11` = scoped). Mandatory ISO `Expires` is kept — permanent (`Expiry: none`)
  is intentionally **not** carried over, per the plugin's "every exception has an
  expiry" axiom; use a far-future review date for long-lived constraints.
- `escapes.md.template` and `escape-hatch-registry.md` document the `Lines` column.
- The bullet-format escape fixtures (`escapes-registered/`, `escapes-expired/`)
  are replaced by the table-format `eval/fixtures/escapes/` set; `test-escapes.sh`
  gains a line-level assertion (8 assertions total).

### Notes

- The `\s`→`[[:space:]]` motion-whitelist fix was made independently in both
  lineages (4.2.1 and 4.4.0); the merged tree carries it once.

---

## [4.4.0] - 2026-06-04

### Added — escape-aware axiom gates (Improvement Plan Phase 1)

The strict gates now read `escapes.md` directly, so a registered intentional
deviation passes while expired or unregistered ones still fail — removing the
incentive to `git commit --no-verify`.

- **`bin/lib/escapes.sh`** — shared parser, sourced by both gates. Parses the
  canonical **Active escapes** markdown table into an allowlist keyed on
  `(Target glob, ELA_### axiom)` with an inclusive ISO `Expires`. Written for
  bash 3.2 / onetrueawk (no associative arrays, globstar, or awk intervals).
  Target globs use shell `case` semantics (`*` spans `/`); `ESCAPES_TODAY`
  pins "today" for reproducible CI; `ESCAPES_FILE` overrides the path.
- **`bin/css-strict.sh`** and **`bin/js-budget.sh`** consult the registry: an
  unexpired match prints `… — suppressed by ESC_…` and is not counted; an
  expired match fails with `escape expired`; an unregistered violation fails as
  before. For `js-budget.sh`, the reserved target `page-total` covers a
  page-total overage. Each gate prints a suppressed-count summary line.
- **`bin/test-escapes.sh`** + `eval/fixtures/escapes/` — acceptance test proving
  all three outcomes for both gates (6 assertions, all green).

### Changed

- **`escapes.md.template`** and **`skills/css-design-system/references/escape-hatch-registry.md`**
  reconciled onto one machine-parseable table format. The previous prose layout
  and the reference's divergent `ESC-NNN` / `ELP` / "Review date / Never" scheme
  are replaced by `ESC ID | Target | Axiom | Expires | Owner | Justification`.
  `ESC_*` category ids stay immutable; the match key uses `ELA_###` axioms (not
  `ELP_###` principles) because the gates enforce axioms; expiry is mandatory.

### Fixed

- `bin/css-strict.sh` counted every violation twice (each `fail` call plus a
  redundant caller increment). `fail()` is now the sole counter, so reported
  counts are correct (e.g. the demo's pre-existing ELA_003 findings now read as
  4, not 8). No change to pass/fail outcomes.

### Repo hygiene

- Untracked `review/` (14 build-artifact files) and added it to `.gitignore`
  (`.full-review/` and `.DS_Store` were already ignored).

---

## [4.3.0] - 2026-06-04

### Changed — Astro 6 migration

All Astro guidance now targets **Astro 6** (latest: 6.4.4). Astro 6 went stable in 2026 after the v6 beta; the plugin previously documented Astro 5 throughout.

- **Version strings** updated to "Astro 6" in `plugin.json`, `marketplace.json`, `README.md`, `CLAUDE.md`, `agents/site-builder.md`, and `skills/astro-site-architect/SKILL.md`.
- **Zod imports** corrected across `astro-site-architect` and `archival-data-engine`: import `z` from `astro/zod` instead of `astro:content` (the `z` re-export from `astro:content` and the `astro:schema` alias are deprecated in Astro 6). Zod 4 format helpers updated (`z.string().url()` → `z.url()`, `z.string().date()` → `z.iso.date()`).
- **Content collections**: documented that the Content Layer API is now the *only* collections system — legacy collections, the `legacy.collections` flag, and the `src/content/config.ts` location are removed; every collection must declare a `loader`.
- **View Transitions**: `<ViewTransitions />` is removed in Astro 6; docs now show `<ClientRouter />` only.
- **Output modes**: removed the long-stale `'hybrid'` mode (dropped back in Astro 5) from `SKILL.md`, `routing.md`, and `astro-config-recipes.md`; replaced with `output: 'static'` + per-page `prerender = false`.
- **Content Loader API**: noted that the function-form `schema: () => ...` signature was removed in favor of `createSchema()`.
- **Demo (`demos/archive-site`)**: pinned `astro@^6`, `@astrojs/react@^5` (React 19), `@astrojs/check@^0.9.9`; added `engines.node >= 22.12.0` and `.nvmrc`; updated `content.config.ts` Zod import.

### Fixed

- Corrected stale counts in `CLAUDE.md`: 13 skills (was 12) and 7 eval prompts (was 5).

---

> The 4.2.1 and 4.2.2 entries below come from a parallel lineage (the vendored
> marketplace copy) that diverged after 4.1.0. They are folded in here by the
> 4.5.0 reconciliation; their escape-format details were superseded by 4.5.0's
> table format (see that entry).

## [4.2.2] - 2026-04-23

### Fixed

- `bin/css-lint-hook.sh` — the PostToolUse lint hook now scans framework template inline styles (`.astro`, `.tsx`, `.jsx`, `.vue`, `.svelte`). Previously bespoke declarations inside `style="..."` attributes bypassed the pre-commit hook because the hook only handled `.css` files — a whole `chronological.astro` page in a downstream site shipped with 20+ inline-style attributes that should have been rejected. Primitive-parameter custom properties (`--space`, `--threshold`, `--min`, `--max`, `--sidebar-min`, `--ratio`, `--measure`, `--min-height`, `--gutter`, `--with-sidebar`) remain allowed as legitimate component parameterization; all other properties fail `ELA_002`.

### Added

- `eval/fixtures/inline-style-primitive-param.astro` — positive case: four `style="..."` attributes, each carrying a single primitive-parameter custom property. 0 violations expected.
- `eval/fixtures/inline-style-bespoke.astro` — negative case: two lines with `style="color: red; margin: 10px"`. 4 `ELA_002` violations expected (per-declaration, across 2 lines).
- `eval/fixtures/inline-style-mixed.astro` — hybrid case: three `style="..."` attributes each combining one primitive-parameter custom property with one bespoke declaration. 3 `ELA_002` violations expected (bespoke half only).

---

## [4.2.1] - 2026-04-23

### Fixed

- `bin/css-strict.sh` — ELA_003 `!important` check produced false positives for the canonical WCAG 2.2 motion reset inside `@media (prefers-reduced-motion: reduce)`. The awk pattern that built the whitelist used `\s` (unsupported in POSIX awk), so the whitelist was always empty and the downstream `is_whitelisted_line` call never matched. Replaced with `[[:space:]]` so the whitelist actually populates. (The standalone lineage hit and fixed the same bug independently; see 4.4.0.)

### Added

- `bin/css-strict.sh` — consumes `escapes.md` at the root of the scanned directory, with line-level matching and permanent (`Expiry: none`) entries. **Superseded by 4.5.0**, which unified the escape engine onto the table format (mandatory ISO expiry, line scoping via a `Lines` column, both gates).
- `bin/css-strict.sh` — accepts a single CSS file as a positional argument in addition to a directory, for targeted fixture testing.
- `eval/fixtures/css-strict-motion-reset-intentional.css` — positive case: 2 `!important` lines inside `@media (prefers-reduced-motion: reduce)` (whitelisted), 2 outside (fail).
- `eval/fixtures/escapes-registered/` and `eval/fixtures/escapes-expired/` — bullet-format escape fixtures. **Replaced in 4.5.0** by the table-format `eval/fixtures/escapes/` set.

### Notes

- v4.2.0 shipped without a CHANGELOG entry; not reconstructed, to avoid inventing history.

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
