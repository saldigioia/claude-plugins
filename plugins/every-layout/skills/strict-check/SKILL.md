---
name: strict-check
description: "Enforce the Every Layout axioms as a hard gate: scan CSS for physical properties, layout media queries, !important, ID selectors, arbitrary values; measure JS budget. Exits non-zero on any violation. Use before commit or in CI."
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/css-strict.sh *) Bash(${CLAUDE_PLUGIN_ROOT}/bin/js-budget.sh *) Read Grep Glob
argument-hint: "<css-dir> [dist-dir]    — e.g., 'src/styles dist' or '.' for current project"
---

# Strict Check — Axiom Gate

Run the plugin's strict-mode validators against a project and report pass/fail. This is not a scorer — it's a contract-enforcement gate suitable for pre-commit or CI. The exit codes matter: non-zero means axioms violated.

$ARGUMENTS

## Inputs

The skill accepts two positional arguments:

- `$1` — CSS directory to scan (defaults to `src/styles/` if unset)
- `$2` — build output directory for JS budget check (optional; skipped if unset)

If the user passed `.` or a project root, infer common conventions: `src/styles/` for CSS, `dist/` for Astro output, `build/` for other frameworks.

## Process

### 1. Canonical axioms

Load `skills/css-layout-engine/references/axioms.md` first. Cite ELA_* IDs throughout the report.

### 2. CSS strict gate

```!
${CLAUDE_PLUGIN_ROOT}/bin/css-strict.sh ${1:-src/styles}
```

The script reports violations per-file with line numbers and ELA_* IDs. It exits 0 on pass, 1 on fail.

### 3. JavaScript budget gate (if build output supplied)

```!
if [ -n "${2:-}" ] && [ -d "${2:-}" ]; then ${CLAUDE_PLUGIN_ROOT}/bin/js-budget.sh "$2"; fi
```

The script measures real gzipped sizes and fails on per-route or page-total overage.

### 4. Verdict

Combine the two exit codes:

- Both pass (exit 0) → **STRICT PASS** — code ships
- Either fails (exit 1) → **STRICT FAIL** — identify which axiom(s), propose fixes

## Report shape

```markdown
## Strict Check Report

### CSS axiom gate: [PASS | FAIL]
Canonical source: skills/css-layout-engine/references/axioms.md

| Axiom | Violations | Worst offender |
|---|---:|---|
| ELA_001 Algorithmic Layout | N | file:line |
| ELA_002 Designing Without Seeing | N | file:line |
| ELA_003 Exception-Based Styling | N | file:line |
| ELA_004 Axiomatic Values | N | file:line |

### JavaScript budget gate: [PASS | FAIL | SKIPPED]
Canonical source: skills/css-design-system/references/performance-rules.md

| Route | Gzipped | Budget | Status |
|---|---:|---:|---|
| ... | ... | 15 KB | OK/OVER |

**Page total:** X KB / 30 KB

### Verdict
One-sentence summary + one of:
- PASS → ship
- FAIL → list the top-3 highest-leverage fixes (by violation count)
- Register escape hatches in `escapes.md` if the violation is intentional (category `ESC_JS_EXCESS` or domain-specific)
```

## Escape-hatch protocol

If a violation is intentional (product decision, third-party constraint, legacy migration), do NOT edit the validator — register the exception in the project root's `escapes.md`:

```markdown
## ESC_<CATEGORY> — short label
Author: @you
Date: YYYY-MM-DD
Expires: YYYY-MM-DD (review quarterly)
Violation: file:line — axiom ELA_###
Justification: [why the CSS/JS alternative was rejected]
Owner: @team-or-person
```

Escape hatches are first-class — the plugin's philosophy is disciplined freedom, not rigid purity. But every entry has an expiry, and the validator's output makes each one a deliberate choice.

## Constraints

- MUST cite ELA_* axiom IDs in every finding
- MUST preserve per-file violation counts from the script output
- MUST report the exit codes of both scripts
- MUST NOT recommend removing the validator to make CI green — that defeats the contract
- MUST propose the smallest code change that fixes the highest-leverage axiom violation first
