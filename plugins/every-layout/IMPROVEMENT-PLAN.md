# Improvement Plan — Campaign 1: 4.5.1 → 4.8.0 (executed 2026-07-06) · Campaign 2: hardening 4.8.1 → 4.9.0 (planned 2026-07-07)

Actionable sequence derived from the 2026-07-06 full plugin review plus the
field report `layout-edits.md` (swatch-grid column-clipping / automatic
minimum size). Each phase is independently shippable, maps to one release
under the plugin's semver policy, and must leave every gate green
(`bin/ci.sh`, created in Phase 1).

**Ground rules**

- Work happens in this tree (the reconciled 4.5.0 marketplace copy). Sync the
  standalone repo *after* each release lands, not during.
- Every phase ends with: run `bin/ci.sh`, update `CHANGELOG.md`, bump
  `.claude-plugin/plugin.json` version.
- Prefer fixing a violation over registering it; register only what is
  intentionally kept (`escapes.md`, mandatory expiry).
- After 4.6.0 lands, reinstall the plugin locally — the currently installed
  marketplace copy predates 4.3.0 (still says "Astro 5").

---

## Phase 1 — Integration & truth fixes — release **4.5.1 (PATCH)**

Small, zero-risk corrections. No behavior changes to gates.

- [x] **1.1 Agent tool keys** — `agents/css-auditor.md`, `agents/css-diagnostician.md`,
      `agents/site-builder.md`: rename frontmatter `allowed-tools:` → `tools:`
      (agents don't support `allowed-tools`; without `tools:` they inherit ALL
      tools, so the auditor/diagnostician "read-only" guarantee is currently
      prompt-only). Keep YAML list form.
      *Accept:* `claude plugin validate` passes; fork `/audit-layout` on a
      fixture and confirm the agent has no Write/Edit.
- [x] **1.2 settings.json** — delete the empty `{}` file (or populate with a
      real `agent` default). Update the CLAUDE.md conventions line: supported
      keys are `agent` **and** `subagentStatusLine`.
- [x] **1.3 CLAUDE.md count corrections** — line 17: layout engine owns **26**
      principles (15 + 3 + 8), **17** reference files (not 29/16).
- [x] **1.4 README `paths` wording** — `paths:` is an availability-scoping
      mechanism, not "auto-invoke when Claude edits matching files".
- [x] **1.5 Remove inert `paths:`** from `skills/refactor-to-primitives/SKILL.md`
      and `skills/plan-migration/SKILL.md` (meaningless alongside
      `disable-model-invocation: true`).
- [x] **1.6 strict-check report template** — `skills/strict-check/SKILL.md:63-66`:
      add the missing `ELA_005` and `ELA_006` rows.
- [x] **1.7 css-auditor cascade rule** — `agents/css-auditor.md`: add the
      rubric cascade (Motion Safety or Focus Visibility 0/3 → cap 16/24;
      both → cap 12/24; report raw + capped). Mirrors `eval/rubric.md:147-153`.
- [x] **1.8 site-builder constraints** — `agents/site-builder.md`: add
      "MUST cite ELC_*/ELP_* IDs in every layout recommendation; never invent
      IDs" and inline the budget numbers (34 KB min / 8.5 KB gzip CSS;
      15 KB route / 30 KB page JS).
- [x] **1.9 Scale typo** — `skills/css-layout-engine/SKILL.md:55`:
      `--s-2` → `--s-5`.
- [x] **1.10 Icon exception documented** — `skills/css-layout-engine/references/physical-properties.md`:
      add accepted exception #4: CSS `width`/`height` with `em`/`cap` units on
      inline icons (ELC_ICON, per ELP_024) — matches the existing whitelist at
      `bin/css-strict.sh:121`.
- [x] **1.11 `bin/ci.sh`** — new single entry point: `bash -n` all `bin/*.sh`,
      `bin/test-escapes.sh`, `bin/run-evals.sh`, `bin/css-strict.sh
      demos/archive-site/src/styles`. Document one-line CI wiring in README.
      (Extended in 2.9; workflow YAML belongs in the standalone repo.)

---

## Phase 2 — Gate hardening (enforce what axioms.md claims) — part of **4.6.0 (MINOR)**

Each new check ships with a fixture proving fail + pass. New checks may
expose latent violations → feeds Phase 3.

- [x] **2.1 Multi-line `@media` detection** — `bin/css-strict.sh` (ELA_001):
      replace the single-line regex with an awk block scanner (viewport-feature
      `@media` … collect until matching brace … flag layout properties inside).
      *Fixture:* `eval/fixtures/gate-media-multiline.css`.
- [x] **2.2 Specificity 0-2-0 cap** — `bin/css-strict.sh` (ELA_003): count
      class/attr/pseudo-class simple selectors per compound selector; fail >2.
      POSIX awk. Sync `axioms.md` ELA_003 enforcement text to exactly what is
      checked. *Fixture:* `eval/fixtures/gate-specificity.css`.
- [x] **2.3 `--archival` completion** — `bin/css-strict.sh` (ELA_006):
      implement the claimed-but-missing `@supports (not` check; rewrite the
      nesting-depth counter to track depth across lines, ignoring
      comments/strings. *Fixture:* `eval/fixtures/gate-archival.css`.
- [x] **2.4 CSS-in-JS detector** — new `bin/ports-lint.sh` (ELA_005, currently
      unenforced by anything): flag `React.CSSProperties`, `style={`/`:style=`
      objects containing non-`--` property keys (reuse css-lint-hook's
      primitive-parameter allowlist logic), `<style>{` in `.tsx/.jsx`,
      `styled.`/`styled(`, `` css` ``, emotion/stitches imports. Warning-tier
      in the PostToolUse hook; `--strict` flag hard-fails for CI.
      *Fixtures:* compliant + violating `.tsx` samples.
- [x] **2.5 HTML `<style>` scanning** — `bin/css-strict.sh`: accept
      `.html`/`.astro`, extract `<style>` blocks, run the same checks. Closes
      the blind spot that let `demos/gallery.html` violations survive.
- [x] **2.6 Escapes date guard** — `bin/lib/escapes.sh`: validate
      `YYYY-MM-DD` shape before the lexicographic compare; fail loudly on
      malformed `Expires`.
- [x] **2.7 Document the whitelists** — `axioms.md` enforcement notes: icon
      `em`/`cap` allowance, comment stripping before px detection, WCAG
      reduced-motion `!important` whitelist (all real, all undocumented).
- [x] **2.8 css-lint-hook param allowlist** — extract the hardcoded
      `--space --threshold …` list into `bin/lib/` (shared with 2.4) so new
      primitive parameters are added in one place.
- [x] **2.9 Extend `bin/ci.sh`** — add ports-lint, HTML-mode strict scan of
      `demos/` + `stress-tests/`, and the new gate fixtures via
      `bin/test-gates.sh` (new; modeled on test-escapes.sh).
      *Accept:* full corpus green except known Phase-3 targets.

---

## Phase 3 — Self-compliance: ports & demos — part of **4.6.0 (MINOR)**

Makes the plugin pass its own (now stronger) gates.

- [x] **3.1–3.3 Rewrite React/Vue/Svelte reference ports** —
      `skills/framework-implementations/references/{react,vue,svelte}.md`,
      all 13 components each: emit `className="stack …"` + **custom-property-only**
      style (`{'--space': space}` / `:style` / `style:--space`), consuming the
      canonical stylesheet (vanilla port). Delete every `CSSProperties`/
      `computed()` declaration object and interpolated declaration string.
      Svelte: prefer the idiomatic `style:--space={space}` directive.
- [x] **3.4 Codify the port rule** — `skills/framework-implementations/SKILL.md`
      + `references/porting-guide.md`: "Ports ship classes + custom-property
      parameters only; primitive CSS ships once as a stylesheet; bespoke
      declarations in `style` are ELA_002 violations" (same line the lint hook
      already draws).
- [x] **3.5 Fix demo react-ports** —
      `demos/archive-site/src/components/react-ports/{Stack,Sidebar,Grid}.tsx`:
      consume `src/styles/primitives.css` classes; **delete per-instance
      `<style>` injection** (currently unscoped → duplicated per instance, and
      `recursive`/`splitAfter` selectors leak to every `.stack` on the page).
      Replace `splitAfter: number` with a child-marker API:
      `.stack > [data-split-after] { margin-block-end: auto; }`.
- [x] **3.6 Fix demo violations** — `demos/gallery.html` lines 62, 158, 186,
      220 (physical properties → logical; `300px` → scale token or
      `max-inline-size` + registered escape); `demos/artsheet.html:135`
      (remove the out-of-whitelist `!important`). artsheet's `<script>` stays
      as documented intentional demo interactivity (js-budget doesn't measure
      inline HTML scripts; add an inline comment stating the exemption).
- [x] **3.7 generate-port alignment** — verify `/generate-port` emits the new
      pattern; update `eval/prompts/framework_implementations.md` if it
      references the old one.
- [x] **3.8 Gate pass** — `bin/ci.sh` fully green including ports-lint and
      HTML-mode scans.

---

## Phase 4 — Canonical value sweep — part of **4.6.0 (MINOR)**

- [x] **4.1 Measure = 65ch everywhere (as the *fallback*)** — sweep `60ch`
      fallback defaults → `65ch`: `cookbook-recipes.md` (20, 106, 133, 156),
      `framework-implementations/references/vanilla.md:34`, `tailwind.md`
      (58, 293, 355), `astro.md` (69, 680). Add the missing fallback to the
      Center recipe in `primitives.md` (`var(--measure, 65ch)`). Explicit
      *token settings* like `artsheet.html:27` (`--measure: 60ch`) are legal
      overrides — keep, with a comment noting it demonstrates the override.
- [x] **4.2 Escape byte limits** — `escape-hatches.md`: mark the per-category
      byte limits **advisory** (nothing enforces them), or add a check to
      `bin/css-budget.sh`. Pick one; stop implying enforcement.
- [x] **4.3 Relocation header** — `skills/css-design-system/references/principles.md`:
      state explicitly this file holds the relocated subset (ELP_016–018,
      022–024) and the full catalog spans both files.

---

## Phase 5 — Auto-minimum bake-in (ELP_033) — headline of **4.6.0 (MINOR)**

From `layout-edits.md`. Follows CLAUDE.md's "Adding a New Primitive or
Principle" workflow end-to-end. Rule as refined: **no track keeps the `auto`
floor** (definite minimum or 0 — bare `1fr` is the violation; the canonical
Grid's `min(var(--min),100%)` floor stays, it *is* the column algorithm), and
**inline-shrink primitives zero their children's auto minimum** (Sidebar's
content-pane `--content-min` floor is explicit and therefore already immune;
Reel/Frame exempt by design).

- [x] **5.1 ELP_033** — `skills/css-layout-engine/references/principles.md`:
      "Neutralized Auto-Minimum" in full spec format. Applies-when: fraction
      tracks / flex children that may hold aspect-ratio, media, or unbreakable
      content. Fails-when: intentional no-shrink (Reel `flex: 0 0 auto`,
      Sidebar `--content-min`). Tradeoff: content may wrap tighter than its
      min-content. Sources: field report (swatch-grid clip), CSS Grid spec
      automatic-minimum-size, *Every Layout* Grid chapter. Testable assertion:
      an `aspect-ratio: 2/1` child with a wrapping label inside
      `repeat(3, minmax(0,1fr))` must not clip at any container width.
- [x] **5.2 Recipe changes** — `skills/css-layout-engine/SKILL.md` quick
      recipes + `references/primitives.md` full specs:
      `.grid > *`, `.switcher > *`, `.cluster > *` get `min-inline-size: 0;`;
      Sidebar: zero the *sidebar pane* only (`.with-sidebar > :first-child`,
      mirror any right-sidebar variant documented in primitives.md); Grid spec
      text explains the `auto`-floor mechanism and why the definite
      `min(var(--min),100%)` floor already satisfies ELP_033.
- [x] **5.3 expected-properties.md** — add required `min-inline-size: 0`
      lines for Grid/Switcher/Cluster/Sidebar(pane); add forbidden: bare `1fr`
      tracks in Grid recipes (must be `minmax(0|definite, 1fr)`).
- [x] **5.4 Propagate to all 6 ports + demos** — astro/react/vue/svelte/
      tailwind/vanilla references (post-Phase-3 shape), 
      `demos/archive-site/src/styles/primitives.css`, `demos/gallery.html`
      inline recipes.
- [x] **5.5 Stress tests** — add to `grid-`, `switcher-`, `cluster-`,
      `sidebar-stress.html`: (a) aspect-ratio child with wrapping label at
      narrow width, (b) unbreakable-token child. Update the "8 tests each"
      claims (`README.md:90`, CLAUDE.md stress-tests line) and any count
      assertions in `bin/run-evals.sh`.
- [x] **5.6 Anti-pattern #8** — `references/cookbook-antipatterns.md`:
      "Bare fraction tracks — the auto-minimum floor" ("works wide, clips
      narrow" signature, aspect-ratio feedback mechanism, fix, the one-line
      reviewer heuristic). New fixture `eval/fixtures/anti-pattern-auto-min.html`
      distilled from the real swatch-grid case; wire into run-evals.
- [x] **5.7 Diagnostician pattern** — `agents/css-diagnostician.md` +
      `skills/diagnose-layout/SKILL.md`: "column/child clipped at narrow
      widths" → trace track definition (bare `1fr`?) → child min floor →
      aspect-ratio/unbreakable content → prescribe `minmax(0|definite, …)` or
      `min-inline-size: 0`, cite ELP_033. (Today the symptom has no
      diagnostic path at all.)
- [x] **5.8 Chooser + constitution + recipes** — add the reviewer heuristic to
      `constitution.md`'s code-review checklist; `chooser.md`: guidance for
      "fixed-N equal columns that never wrap" (the catalog hole that caused
      the original bug) → new cookbook recipe `repeat(N, minmax(0, 1fr))` in
      `cookbook-recipes.md`; add a hazards row to `composition-rules.md`.
- [x] **5.9 Lint warning** — `bin/css-lint-hook.sh`: warning-tier flag for
      bare `1fr` inside `grid-template-*` (hook-tier, not the hard gate —
      print-rules' single-column `1fr` is legitimate). Fixture pair.
- [x] **5.10 Memory hooks + counts** — `references/hooks.md`: add ELP_033
      hook(s); update the "75 memory hooks" count in SKILL.md.
- [x] **5.11 Auditor/rubric touch** — `eval/rubric.md` dimension guidance
      (Intrinsic Sizing) mentions zero-floor tracks; css-auditor prompt lists
      ELP_033 among checks.
- [x] **5.12 Reel keyboard access** (pulled forward, accessibility tier-1) —
      `primitives.md` Reel spec + `css-design-system/references/accessibility.md`:
      scrollable Reel needs `tabindex="0"` + `role="region"` + accessible
      name; add to reel-stress.
- [x] **5.13 Release** — CHANGELOG 4.6.0 (Phases 2–5), version bump, full
      `bin/ci.sh` green, sync standalone repo.

---

## Phase 6 — Expansion wave — release **4.7.0 (MINOR)**

- [x] **6.1 `references/native-interaction.md`** (css-layout-engine) — the
      zero-JS interactivity catalog: `<details name>` exclusive accordions,
      `<dialog>` + `method="dialog"`, Popover API (`popovertarget`,
      light-dismiss), `:user-valid`/`:user-invalid` (+ validation-UX section
      in `form-patterns.md`), `<datalist>`, `accent-color`; markup contracts,
      focus + reduced-motion rules, Baseline date per feature. This is the
      ELA_005 boundary-mover: it shrinks the set of things that "need" JS.
- [x] **6.2 `references/baseline-registry.md`** — operationalize ELA_006:
      table of feature | Baseline date | fallback obligation | status
      (allowed / escape-gated / watch). Seed: light-dark, logical props,
      :focus-visible, subgrid, container queries, :has, dvh/svh,
      cross-document view transitions, anchor positioning, scroll-driven
      animations, interpolate-size, cqi, text-box-trim, popover, dialog,
      details-name, :user-valid. Point `axioms.md` ELA_006 at it.
- [x] **6.3 Cover dvh upgrade** — fallback chain `min-block-size: 100vh;
      min-block-size: 100dvh;` in SKILL.md, primitives.md, all ports, demos,
      expected-properties, cover-stress.
- [x] **6.4 Cross-document View Transitions** — astro-site-architect
      (`performance.md` or new reference): `@view-transition` MPA transitions
      as the zero-JS alternative to ClientRouter's ~3 KB; reduced-motion
      gated; when each is appropriate.
- [x] **6.5 Container query units** — `container-query-recipes.md`: `cqi`
      sizing + fluid type inside ELC_CONTAINER; nested-container layout-cost
      note. Also fix the latent bare-`1fr` tracks the review found in this
      file (line 82) and `subgrid-patterns.md` (98, 141, 192) per ELP_033.
- [x] **6.6 Data durability table** — `archival-data-engine/SKILL.md`:
      SQLite vs libSQL vs Astro DB trade-offs framed by ELA_006 (framework
      coupling risk named explicitly).
- [x] **6.7 Design-system gap fills** — dark-mode shadow adaptation recipe
      (`css-texture.md`); mixed-direction content section (`i18n-layout.md`).
- [x] **6.8 Eval coverage** — new prompts: `css_layout_engine.md` (core) and
      `diagnose_layout.md` (fixture: a broken-primitive page with an
      auto-minimum clip among the faults); update run-evals counts.
- [x] **6.9 `/scaffold-system` workflow skill** — greenfield entry point:
      emits tokens file (9 mandatory `--br-*`), `@layer` declaration,
      primitives.css, `escapes.md` from template, offers pre-commit install.
      `disable-model-invocation: true`. Companion eval prompt.
- [x] **6.10 `ids.json` registry** — machine-readable ELC/ELP/ELA/EDC/ESC
      registry (with `deprecated`/`superseded_by`); `run-evals.sh` check that
      every ID cited anywhere exists. Mechanical teeth for the ID-immutability
      policy.

---

## Phase 7 — Backlog → shipped in **4.8.0** except where noted

- [x] `bin/archival-audit.sh` — ELA_006 external-dependency sweep: remote
      `url()`, `@import`, external `<link>`/`<script>`; `--strict` wired into
      `bin/ci.sh` over demos + stress-tests (link-rot probing stays future).
- [x] `references/failure-mechanics.md` — the spec-trap family: auto minimums
      (ELP_033), flex-column `min-height: auto`, unbreakable tokens,
      aspect-ratio feedback, percentage-padding, auto margins vs
      justify-content, margin-collapse contexts, overflow BFC/clipping.
- [x] Field-report pipeline — documented in CLAUDE.md → Development Workflow
      ("Field reports → principles"), with ids.json registration added to the
      new-primitive checklist.
- [x] Motion-allowlist watch-tier section (scroll-driven, interpolate-size)
      cross-referencing baseline-registry; `@page` margin boxes appended to
      print-rules.md. Anchor-positioning recipes stay WATCH (registry row
      exists; recipes when Baseline). HTML validity gate (vnu) deliberately
      NOT added — external tooling conflicts with the zero-dependency bin/
      ethos; revisit only on demand.
- [x] Ship-conventions-as-skill — RESOLVED as a decision, not a new skill:
      everything consumer-facing already ships via skills (axioms, budgets,
      token/layer contracts, ID rules). CLAUDE.md is deliberately the
      contributor doc; the validator warning is accepted.

---

## Release map

| Release | Phases | Nature |
|---|---|---|
| 4.5.1 | 1 | PATCH — doc/config truth fixes, agent `tools:` rename, ci.sh |
| 4.6.0 | 2–5 | MINOR — gate hardening, self-compliance, value sweep, **ELP_033** |
| 4.7.0 | 6 | MINOR — native-interaction catalog, baseline registry, dvh, scaffolder, ids.json |
| — | 7 | backlog |

---

## Post-4.7.0 backlog additions (discovered during Phase 6)

- [x] Port Cover defaults still pin `100vh` (react/vue/svelte/astro docs
      default the `minHeight` prop) — make the prop optional so the
      stylesheet's `dvh` chain applies when unset.
- [x] Reconcile `--br-color-focus` (token table) vs `--color-focus` (used in
      accessibility.md / SKILL focus-ring recipes) — pre-existing drift
      flagged while writing native-interaction.md (spawned task chip).
- [x] every-layout.css has no @media print section (vanilla.md's print
      overrides were not carried into the built artifact).

---
---

# Campaign 2 — Hardening (from the 2026-07-07 ambiguities & vulnerabilities review)

Source: multi-perspective re-examination after 4.8.0 (cautious back-end
engineer / Claude Code constitutionalist / Astro constitutionalist / futurist
designer). Three confirmed defects, one latent budget violation, and a set of
honesty/robustness gaps. Same ground rules as Campaign 1, plus one new one:

- **Push after every release commit.** Three release commits currently exist
  on one disk only — right now that is the plugin's single largest
  vulnerability. Pushing is user-gated; the plan marks where.

---

## Phase H1 — Confirmed defects — release **4.8.1 (PATCH)**

- [x] **H1.1 gallery.html ghost stylesheet** — [demos/gallery.html:7] still
      links `../implementations/vanilla/every-layout.css` (never existed);
      only stress tests got the href fix. Change to `every-layout.css`
      (same directory). Also grep demos/artsheet.html for the same ghost
      href (believed self-contained — verify, don't assume).
      *Accept:* `grep -rn "implementations/vanilla" demos stress-tests` → 0
      hits; open gallery.html in a browser — primitives actually render.
- [x] **H1.2 astro.md ID-machinery rewrite** (the deferred "agent G") —
      `skills/framework-implementations/references/astro.md` Cover (~217),
      Sidebar (~506), Stack (~578) + any other component using it: remove
      `Math.random()` per-instance ids and every `#{id}` styled block
      (ELA_003 ID selectors; non-deterministic builds vs ELA_006; and plain
      `<style>` blocks are NOT templated in Astro — the blocks are likely
      emitted as literal, dead selectors). Replace with the settled
      contract: static data-attribute selectors in the component's scoped
      style (`.cover > :global(.principal)`, `[data-centered]` alias;
      Sidebar side = DOM order; Stack numeric `splitAfter` REMOVED → child
      `data-split-after` marker; Switcher `limit` → `data-limit`). Drop the
      `centered` selector-string prop (selector injection surface; already
      removed from vue/svelte). Add one paragraph to porting-guide.md:
      `define:vars` values are author-controlled CSS — never route user
      content into it.
      *Accept:* `grep -nE "Math.random|#\{id\}|splitAfter" …/astro.md` → 0
      hits; every fenced ```astro block extracted and eyeballed against the
      port contract; prop tables updated.
- [x] **H1.3 Calc-chain contradiction** — restore derived-token calc chains
      (`--s1: calc(var(--s0) * var(--ratio))` …) in `demos/every-layout.css`
      `:root` and in the `/scaffold-system` tokens.css template
      (`skills/scaffold-system/SKILL.md`), keeping the resolved values as
      trailing comments (`/* = 0.132rem */`). This re-enables the
      per-subtree `--ratio` override that SKILL.md:93 / token-rules.md
      promise and my Phase-3 pinned spec broke.
      *Accept:* `bash bin/ci.sh` green (token definitions don't hit the
      value gates); a quick HTML scratch test: setting `--ratio: 1.25` on a
      subtree visibly recomputes spacing.
- [x] **H1.4 react-port budget honesty** — create
      `demos/archive-site/escapes.md`: `ESC_JS_EXCESS` rows for the React
      vendor/island chunks glob and `page-total` (far-future expiry,
      justification: deliberate React-port demo; the rest of the site ships
      0 KB). Note in `react-port/index.astro`'s header comment.
      *Accept:* row format parses (`ESCAPES_FILE=demos/archive-site/escapes.md
      bash -c '. bin/lib/escapes.sh; escapes_load; …'` sanity), documented.
- [x] **H1.5 js-budget trailing-slash bug** — normalize `DIR="${DIR%/}"`
      before the `${file#$DIR/}` strip so escape globs match dist-relative
      paths regardless of how the argument was written.
      *Accept:* new assertion in `bin/test-gates.sh` calling js-budget with
      `dist/` (trailing slash) against a temp over-budget file + escape.
- [x] **H1.6 Release** — CHANGELOG 4.8.1, bump, full `bin/ci.sh`, commit.
      → **USER: push.**

---

## Phase H2 — Gate truthfulness & new tripwires — release **4.9.0 (MINOR)**

- [x] **H2.1 True violation counts** — `bin/css-strict.sh`: keep the 5-line
      display cap per check but count ALL matches; print "… and N more" when
      truncated, so "FAIL — N violation(s)" is the real N.
      *Accept:* test-gates fixture with >5 violations of one axiom asserts
      the true count and the "more" line.
- [x] **H2.2 js-budget semantics honesty** — rename output labels to what is
      measured ("Per-file (route proxy)" / "Dist total (page proxy)") and
      document the heuristic + its code-splitting limits in the script
      header and `performance-rules.md`. No behavior change.
- [x] **H2.3 Escape-limit visibility** — the advisory limits (≤10 escapes
      per project, ≤3 per file, 15% audit threshold) become *visible*:
      `escapes.sh` warns on load when the registry exceeds 10 rows;
      `css-strict.sh` warns when one file's suppressions exceed 3. Warn-tier
      only — limits stay advisory, but silent drift ends.
      *Accept:* test-gates assertions for both warnings.
- [x] **H2.4 Tailwind arbitrary-value tripwire (ELA_004)** — extend
      `bin/ports-lint.sh` (or the lint hook) to flag arbitrary-value
      utilities (`-\[[^\]]+\]` inside class attributes) in
      .html/.astro/.tsx/.jsx/.vue/.svelte — the axiomatic-values regime is
      currently CSS-file-shaped and Tailwind moves values into markup.
      Warn-tier in hook, `--strict` in CI (demos are Tailwind-free → green).
      *Accept:* fixture pair + test-gates assertions.
- [x] **H2.5 ports-lint `--docs` mode** — extract fenced code blocks from a
      .md file to temp and scan them, giving the reference ports (react.md /
      vue.md / svelte.md) standing regression protection instead of
      one-time agent verification; wire into ci.sh for the three files.
      *Accept:* ci step green; deliberately violating scratch md fails.
- [x] **H2.6 ci `--with-build` (opt-in)** — when node+npm are present and
      the flag is passed: `npm ci && npm run build` in demos/archive-site,
      then `js-budget.sh dist` (expects H1.4's escapes to suppress the
      react-port overage). Default ci stays offline/dependency-free.
      *Accept:* documented in README; offline ci unchanged.
- [x] **H2.7 Enforcement-tiers honesty section** — README + CLAUDE.md: one
      short table separating the three tiers (skill advice → PostToolUse
      warnings → pre-commit/CI hard gates) and stating plainly that
      "adoption = contract" is realized only at tier 3; point to
      install-git-hooks.sh / ci.sh as the teeth.
- [x] **H2.8 Shell-surface invariants** — comment headers on the two
      skill-load shell surfaces (css-design-system SKILL dynamic block;
      strict-check `$1` interpolation): read-only invariant, no state
      changes, keep it that way.
- [x] **H2.9 Baseline-registry verification pass** — verify every row
      against webstatus.dev/MDN (network session), correct any drifted
      Baseline dates, add a `Last verified` column + date; add "re-verify
      rows" to the release checklist (H2.10).
- [x] **H2.10 Release checklist in CLAUDE.md** — small list run before any
      release: model aliases in agents still valid; baseline-registry
      last-verified acceptable; counts in README/CLAUDE match `find`;
      `claude plugin validate`; ci green; push.
- [x] **H2.11 Release** — CHANGELOG 4.9.0, bump, full ci, commit.
      → **USER: push.**

---

## Phase H3 — Ops (user-gated, no version)

- [x] **H3.1 Push** monorepo `main` (`ee5529e`, `024888b`, `259c2d2` + H1/H2
      commits) — until then everything lives on one disk. *(Done: origin/main
      at e1e66b6, tag every-layout--v4.9.0 pushed.)*
- [x] **H3.2 Reverse-sync standalone** — monorepo → standalone `master`
      (inverts the old vendoring direction, one time): copy the plugin tree,
      decide whether IMPROVEMENT-PLAN.md travels (old rule stripped it),
      commit, and record in memory that the repos are level again.
      *(Resolved differently: the standalone repo was RETIRED — the monorepo
      saldigioia/claude-plugins is the single canonical home; recorded in
      memory.)*
- [x] **H3.3 Reinstall the local plugin** — the installed marketplace copy
      still predates 4.3.0 ("Astro 5" descriptions in-session). *(Done:
      installed copy at 4.9.0.)*

## Explicitly accepted (no task)

- Escape registry remains trust-by-design for a cloned repo (visible
  suppressions + H2.3 warnings are the mitigation; hard limits would fight
  the "disciplined freedom" philosophy).
- ports-lint stays a tripwire, not a wall (documented evadability).
- No vnu/HTML-validity gate; no 15th conventions skill (Campaign 1
  decisions stand).

## Release map (Campaign 2)

| Release | Phase | Nature |
|---|---|---|
| 4.8.1 | H1 | PATCH — ghost stylesheet, astro.md ID machinery, calc chains, budget escapes, slash bug |
| 4.9.0 | H2 | MINOR — true counts, semantics honesty, escape-limit warnings, Tailwind tripwire, --docs mode, opt-in build gate, honesty docs, registry verification |
| — | H3 | ops: push, reverse-sync, reinstall |

---
---

# Campaign 3 — Composition & Seeing (from the Window Classics performance review)

Source: `/Users/salvatore/Downloads/CURATION-RETRO.md` — the postmortem of the
plugin's largest field deployment (`/Users/salvatore/Downloads/2025-wc-dev`,
reviewed 2026-07-09, remediated under `CURATION-PLAN.md` there). The verdict
that matters here: **the site passed every gate this plugin ships and still
carried seven composition/context defects** — an h1 outranked by its own
sections, two near-black inks in one heading system, a CTA living in two
bodies, a word fracturing mid-heading at 390px, an unpainted canvas in
dark-preference contexts, two infinite hero animations, and a breakpoint one
pixel off the grid. Worse: one of the seven violated doctrine the plugin
already publishes — ELP_016 mandates `color-scheme` alongside `light-dark()`,
and nothing enforced it. The campaign theme is the retro's closing line: the
system audited *values*; nobody audited *rank, axis, species, and context*.
Two thrusts: **teeth** for doctrine that already exists (C1–C2), and **eyes**
— a rendered, adversarial review tier that static gates cannot replace
(C3–C4).

Ground rules: Campaign 1 + 2 rules stand (ci green per phase, CHANGELOG +
version bump per release, fixture pair for every new check, prefer fixing to
escaping, **push after every release commit** — H3.1's push landed 2026-07-08;
origin/main is level as of e1e66b6). New rule from
the retro: when any check lands and fires on real code, grep for the
violation's *siblings* before closing the item — the WC word-break fix
missed the same disease in Accordion headings until a later pass (314d9f3).

---

## Phase C1 — Teeth: enforce what the doctrine already claims — part of **4.10.0 (MINOR)**

The ELP_016 class: principles with no mechanical witness. Same spirit as
Campaign 1 Phase 2 ("enforce what axioms.md claims").

- [x] **C1.1 `light-dark()` ⇒ `color-scheme` gate** — `bin/css-strict.sh`:
      when a scanned project uses `light-dark(` anywhere, require a
      `color-scheme:` declaration somewhere in the same corpus (dir-mode
      check, not per-file; a lone file scan downgrades to a warning). Cite
      ELP_016 in the failure text. This is the exact WC F7 miss: the token
      docs *claimed* `color-scheme: light` and no gate noticed it never
      shipped. *Accept:* fixture pair `eval/fixtures/gate-colorscheme-{fail,pass}.css`;
      `bin/test-gates.sh` assertions; run over `demos/` — fix or escape any hit.
- [x] **C1.2 Painted-ground check (new ELP_035)** — `bin/css-strict.sh`
      dir-mode: a `body`/`html`/`:root` block that sets `background-image`
      (or a `background:` shorthand containing `gradient(`/`url(`) and/or
      `background-size` must also carry a reachable `background-color`. The
      WC body painted a 600px gradient over a transparent canvas; every
      dark-preferring browser rendered the site on black below the fold.
      *Accept:* fixture pair; test-gates assertions.
- [x] **C1.3 ELP_035 "Painted Ground" spec** —
      `skills/css-design-system/references/principles.md`, full spec format:
      the canvas is not a color; `background-color` on the root is the
      contract, sized/gradient images are decoration layered above it; pairs
      with ELP_016 (`color-scheme` decides what an *unpainted* canvas would
      have been). Testable assertion: with `prefers-color-scheme: dark`
      emulated and no site CSS overridden, no route shows UA-canvas ground.
      Register in `ids.json`; add hook(s) to
      `skills/css-layout-engine/references/hooks.md`; update counts (SKILL.md).
- [x] **C1.4 Infinite-motion rule** —
      `skills/css-design-system/references/motion-allowlist.md` currently has
      **no position on `animation-iteration-count: infinite`** — the WC hero
      ran two perpetual animations (word-flip + bounce) through this file
      unremarked. Add the rule: infinite animation is allowed only for
      status/progress indication; decorative infinite motion is a violation
      even under `prefers-reduced-motion: no-preference`. Add a warn-tier
      check to `bin/css-lint-hook.sh` (`animation[^;]*infinite`, whitelisted
      by an adjacent `/* motion: status */` marker or escape row);
      `eval/rubric.md` dimension 7 (Motion Safety) guidance gains one line.
      *Accept:* fixture pair; hook prints the warning; rubric line present.

---

## Phase C2 — ELP_034 "Scoped Typographic Permissions" — part of **4.10.0 (MINOR)**

The word-break fracture, run through the full field-report pipeline exactly
as ELP_033 was (Campaign 1 Phase 5 is the template). Careful alignment: the
plugin already *prescribes* `overflow-wrap: break-word` for unbreakable-token
**content** (`failure-mechanics.md:47`, `cookbook-recipes.md:1033`,
antipatterns:861) and uses print-scoped `word-break: break-all` for URLs
(`vanilla.md:558`). Those stay correct — the new principle draws the line at
*where the permission is granted*, not whether it exists.

- [x] **C2.1 ELP_034 spec** — `skills/css-layout-engine/references/principles.md`:
      "Scoped Typographic Permissions" — `word-break` / `overflow-wrap` /
      `hyphens` are content-tier grants: legal on prose/data containers,
      never on `body`, `:root`, `*`, or heading selectors. A global grant is
      a site-wide license that display type eventually cashes in (WC:
      "The Manufacturer / s We Trust", single-letter orphan at 390px; same
      disease found later in Accordion headings). Testable assertion: a
      heading containing a long word at 320px wraps at word boundaries or
      overflows visibly — it never fractures mid-word. Register in
      `ids.json`; hooks.md + counts.
- [x] **C2.2 Gate** — `bin/css-strict.sh` (with the shared selector logic in
      `bin/lib/` per the 2.8 pattern): flag `word-break|overflow-wrap|hyphens`
      declarations in blocks whose selector list includes `body`, `html`,
      `:root`, bare `*`, or `h1`–`h6` compounds. Whitelist: inside
      `@media print` (the vanilla.md URL case), and `hyphens: manual`.
      Warn-tier in `bin/css-lint-hook.sh`, hard in `--strict`/ci.
      *Accept:* fixture pair incl. a print-scoped pass case; test-gates
      assertions; dogfood sweep over `demos/` + `stress-tests/` green.
- [x] **C2.3 Failure-mechanics entry** —
      `skills/css-layout-engine/references/failure-mechanics.md`
      unbreakable-tokens section: add the "blanket permission" trap —
      the fix for token overflow belongs on the token's container; granting
      it globally converts every narrow heading into a fracture site.
- [x] **C2.4 Anti-pattern #9** —
      `skills/css-layout-engine/references/cookbook-antipatterns.md`:
      "Body-wide word-break — the global permission." Signature: a
      single-letter orphan opening a line at narrow widths; works at every
      width the author tested, fractures at the one they didn't. Fix +
      reviewer heuristic ("who granted this, and to whom?"). Fixture
      `eval/fixtures/anti-pattern-global-wordbreak.html`; wire into run-evals.
- [x] **C2.5 Heading-tier contract** —
      `skills/css-design-system/references/typography-scale.md` +
      `typography-pairing.md`: one ink and one family per heading tier; the
      page title participates in the same ramp as section titles (rank must
      be monotonic — WC shipped a 40px/700 h1 above 48px/500 h2s, in a cool
      near-black no other heading used). Document near-duplicate inks as
      drift, citing the `#111827`-vs-`#251f1b` case.
- [x] **C2.6 Near-duplicate token tripwire** — `bin/css-strict.sh` dir-mode
      warn (never hard-fail): parse `#rrggbb` custom-property values; when
      two distinct tokens sit within a small channel distance (max per-channel
      delta ≤ 16), print the pair. Honest limits documented in the script
      header: hex-literal only, no oklch/color-mix math — a tripwire, not
      colorimetry. *Accept:* fixture with a near-black pair triggers the warn;
      `token-rules.md` gains a "near-duplicate = drift" line pointing at it.
- [x] **C2.7 Breakpoint-proximity tripwire** — `bin/css-strict.sh` dir-mode
      warn: collect distinct `@media` `min-width` px values; warn when two
      values differ by ≤ 2px (WC shipped 640 and 641 in one component).
      *Accept:* fixture pair; test-gates assertion.
- [x] **C2.8 Stress test** — new `stress-tests/typography-stress.html`:
      long-word headings (Manufacturers-class, URL-class, all-caps-class) at
      320/360/390 containers, with and without a content-scoped
      `overflow-wrap`, plus a deliberately-global-permission block marked as
      the failure exhibit. Update stress-test counts in `README.md` /
      CLAUDE.md and any assertions in `bin/run-evals.sh`.
- [x] **C2.9 Release** — CHANGELOG 4.10.0 (C1+C2), bump, full `bin/ci.sh`
      green, commit. → **USER: push.**

---

## Phase C3 — Eyes: the rendered adversarial tier — part of **4.11.0 (MINOR)**

The retro's central finding: every screenshot the WC build ever took was
light-mode, comfortable-width, motion-on. Composition defects (rank, axis,
species, optical centering) are invisible to file-shaped checks *by nature* —
this tier renders and looks. It stays **opt-in** (H2.6 precedent): default
`bin/ci.sh` remains offline and dependency-free.

- [x] **C3.1 `bin/render-sweep.sh`** — opt-in harness (generalized from the
      WC `tmp/curation` fullsweep): detects `node` + a resolvable local
      `playwright` (else exits "SKIP — render tier unavailable", code 0
      unless `--strict`). Given a base URL + route list (flags or
      `render-sweep.config.json`): full-page screenshots at
      320/360/390/414/640/768/834/1024/1280/1440, light **and**
      dark-emulated, reduced-motion, plus per-route probes printed as a
      table: `scrollWidth` overflow, dark-canvas ground sample (body bottom
      pixel), mid-word-fracture heuristic (any rendered text line beginning
      with a single orphan letter inside a heading). Wire as
      `bin/ci.sh --with-render` against a served `demos/archive-site` build.
      *Accept:* sweep over demos produces shots + a clean probe table;
      SKIP path proven on a playwright-less shell.
- [x] **C3.2 `/render-audit` skill** — new `skills/render-audit/SKILL.md`
      (user-invocable): runs C3.1, then reviews the captures against the
      composition checklist the static rubric cannot judge — heading rank
      monotonic (h1 ≥ its sections); one ink/family per tier as *rendered*;
      shared axis between eyebrow and title; any device rendered in two
      dressings (the CTA-species test); reserved-width animation slots vs
      optical centering; dark-scheme ground; narrow-width fractures; seams
      at adjacent breakpoints (640/641-class). Report format mirrors
      css-auditor's (findings with element + value + severity), explicitly
      labeled **model-judged** — distinct tier from the 24-point rubric.
      *Accept:* run against the WC repo reproduces ≥5 of the retro's 7
      findings from pre-remediation HEAD (`27a1883`); documented in README.
- [x] **C3.3 css-auditor honesty + static composition greps** —
      `agents/css-auditor.md`: add the static subset it *can* check (heading
      selectors' color/font tokens per tier from source; ELP_034/035/016
      citations; duplicate component species by filename/class heuristic),
      and a mandatory closing line when auditing a whole project: "static
      audit does not judge rendered composition — run `/render-audit`."
      Mirror one line in `skills/audit-layout/SKILL.md`.
- [x] **C3.4 Composition eval fixture** —
      `eval/fixtures/composition-page.html`: a single page embodying the WC
      seven in miniature (subordinate h1, two near-black tokens, body-wide
      `word-break`, `light-dark()` without `color-scheme`, unpainted gradient
      body, 640+641 pair, decorative infinite animation). New prompt
      `eval/prompts/composition_audit.md` with expected findings; wire into
      `bin/run-evals.sh` (this fixture also feeds the C1/C2 gate fixtures —
      one artifact, many teeth).
- [x] **C3.5 Scaffold the discipline into new projects** —
      `skills/scaffold-system/SKILL.md` emissions grow: (a) tokens template
      already carries `color-scheme` — verify, and add root
      `background-color` (ELP_035); (b) `render-sweep.config.json` template;
      (c) `PROTECTED-COPY.md` template — named prose zones, the
      copy-vs-decoration classification question, and the per-sentence
      sign-off rule (the WC revert lesson: pass-level approval is not
      sentence-level approval; a rotating headline's word list is *content*).
      *Accept:* scaffold run emits all three; template text cites ELP_034/035.

---

## Phase C4 — Authority & process — part of **4.11.0 (MINOR)**

- [x] **C4.1 Constitution additions** —
      `skills/css-layout-engine/references/constitution.md` code-review
      checklist: (a) *hunt the class* — any confirmed violation triggers a
      corpus grep for siblings before the finding closes; (b) *species rule*
      — a visual device that exists twice gets one owner file; a second
      variant costs a recorded decision; (c) *backlog aging* — a diagnosed
      finding older than one release cycle is either scheduled or explicitly
      wontfixed (a backlog that only accumulates is a diary, not a queue).
- [x] **C4.2 site-builder copy authority** — `agents/site-builder.md`
      constraints: classify every text touch as copy vs decoration *before*
      editing; never invent, reword, or delete owner copy — subtraction/move
      requires the owner's exact surviving sentence; visible design
      decisions ship as options-with-renders, never landed unpicked. (WC
      precedent: six "approved" copy edits reverted wholesale; the rule now
      lives in that repo's CLAUDE.md — this bakes it into the toolchain.)
- [x] **C4.3 Diagnostician symptom paths** — `agents/css-diagnostician.md`
      + `skills/diagnose-layout/SKILL.md`: two new traces — "site renders on
      black in dark mode" → `color-scheme` declared? root
      `background-color` painted? sized/no-repeat background stopping short?
      (ELP_016/035); "word fractures mid-heading at narrow width" → walk the
      cascade for the granting selector (`body`? `*`? heading?) → ELP_034.
- [x] **C4.4 Enforcement-tiers table gains the render tier** — README +
      CLAUDE.md (H2.7's table): tier 4 — rendered review (`/render-audit` +
      `render-sweep.sh`), model-judged, opt-in; states plainly which defect
      classes live *only* here. Add "render-sweep demos before release" to
      the CLAUDE.md release checklist (H2.10).
- [x] **C4.5 Dogfood sweep** — run the full C1/C2 gate set plus
      `--with-render` over `demos/` + `stress-tests/`; fix violations
      (expected: none structural; possibly gallery/artsheet heading
      permissions) or register escapes with expiry. Self-compliance is the
      Phase-3 precedent: the plugin passes its own new teeth.
- [x] **C4.6 Release** — CHANGELOG 4.11.0 (C3+C4), bump, `claude plugin
      validate`, full ci green incl. new fixtures, commit. → **USER: push
      (and clear H3.1/H3.2 while at it — two campaigns of history still
      live on one disk).**

---

## Explicitly accepted (no task) — Campaign 3

- **No Playwright dependency in default ci.** The render tier is opt-in
  forever; the zero-dependency `bin/` ethos (the vnu decision, Campaign 1
  Phase 7) stands. A machine without node/playwright still gets every
  file-shaped gate.
- **Optical judgment stays model-judged.** No pixel-math "rank checker" or
  fake-mechanized centering metric — pretending composition is grep-able is
  exactly the failure mode the retro documents. The mechanical tripwires
  (C1–C2) catch the *causes* that are textual; `/render-audit` owns the rest.
- **The 24-point rubric keeps its shape.** Composition gets its own rendered
  checklist (C3.2) rather than a ninth static dimension — a static auditor
  scoring "rendered rank" it cannot see would be dishonest scoring.
- **Copy gates ship as scaffold templates, not plugin CI.** The plugin has no
  site copy to gate; projects do. `PROTECTED-COPY.md` + the WC copy-diff
  pattern travel via `/scaffold-system` (C3.5).

## Release map (Campaign 3)

| Release | Phases | Nature |
|---|---|---|
| 4.10.0 | C1–C2 | MINOR — teeth: ELP_016 enforcement, ELP_035 painted ground, infinite-motion rule, **ELP_034** full pipeline, near-duplicate + breakpoint tripwires, typography stress |
| 4.11.0 | C3–C4 | MINOR — eyes: render-sweep + `/render-audit`, composition fixture, scaffold discipline, constitution/site-builder/diagnostician authority, dogfood |
