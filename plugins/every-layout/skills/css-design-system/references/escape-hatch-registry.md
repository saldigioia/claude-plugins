# Escape Hatch Registry

Convention for recording intentional deviations from Every Layout axioms. Every
project accumulates exceptions — this makes them visible, justified, bounded, and
**machine-suppressible**: the axiom gates read the registry directly.

---

## Purpose

Real projects need intentional violations:
- A fixed-width sidebar required by a brand guideline
- A media query for print layout
- An arbitrary spacing value to align with a third-party embed
- A physical property for a CSS feature without a logical equivalent
- A JavaScript island that exceeds the ELA_005 budget

Without a registry, these violations:
1. Fail the gate on every run (noise, or `--no-verify` habit)
2. Get "fixed" by contributors who don't know they're intentional (churn)
3. Accumulate silently with no accountability

The registry makes exceptions **visible, justified, and bounded** — and lets
`bin/css-strict.sh` and `bin/js-budget.sh` pass a registered, unexpired
deviation while still failing on expired or unregistered ones.

---

## File convention

Create `escapes.md` in the project root by copying `escapes.md.template`. The
canonical, gate-parsed format is a single **Active escapes** table:

```markdown
## Active escapes

| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_EMBED | `src/styles/checkout.css` | ELA_002 | 12 | 2026-12-31 | @owner | Stripe iframe needs a 13px match on this rule until they ship logical props. |
| ESC_LEGACY | `legacy/*` | ELA_003 | - | 2026-09-15 | @owner | Pre-migration page; !important removal tracked in #214. |
```

The match key is **(Target, Axiom, Lines)**. `Target` is a shell glob where `*`
matches any characters including `/`. `Axiom` is the exact `ELA_###` the gate
emits. `Lines` is `-` for the whole file or `9` / `9,10` / `9-11` to scope the
escape to specific lines (so an accidental same-axiom violation elsewhere still
fails). `Expires` is an inclusive ISO date — there is no "never". One
(Target, Axiom, Lines) entry per row. See `escapes.md.template` for the full
field rules, the line-scope semantics, and the `js-budget.sh` `page-total` target.

---

## Registry fields

| Field | Required | Role | Description |
|-------|----------|------|-------------|
| **ESC ID** | Yes | label | Canonical category (`ESC_EDITORIAL`, `ESC_EMBED`, `ESC_DATAVIZ`, `ESC_LEGACY`, `ESC_JS_EAGER`, `ESC_JS_EXCESS`) or a project-specific `ESC_<CATEGORY>`. |
| **Target (glob)** | Yes | **match key** | File path / glob the violation occurs in. |
| **Axiom** | Yes | **match key** | The `ELA_###` axiom suppressed for this target. |
| **Lines** | Yes | **match key** | `-` for the whole file, or `9` / `9,10` / `9-11` to scope to line numbers. |
| **Expires** | Yes | **expiry check** | Inclusive ISO date. Expired rows fail the gate. |
| **Owner** | Yes | label | @handle accountable for the exception. |
| **Justification** | Yes | label | Why the canonical alternative was rejected (one sentence minimum). |

> **Note on IDs.** The `ESC_*` ids are **categories**, not sequential `ESC-NNN`
> counters, and the categories are immutable (see `CLAUDE.md` → ID Immutability).
> Multiple rows may share a category. The axiom column uses `ELA_###` axiom ids,
> not `ELP_###` principle ids, because the gates enforce axioms.

---

## Rules

1. **Every escape must have a justification.** "It was easier" is not a justification. "Brand guidelines require it" is.
2. **Every escape must have an owner.** Someone is accountable for this deviation.
3. **Every escape must have an expiry.** Temporary escapes get a quarterly review; there is no permanent escape — re-register if still needed.
4. **The gate honors the registry by construction.** An unexpired, matching escape is suppressed; an expired one fails with "escape expired"; an unregistered violation fails normally.
5. **Retire, don't bury.** When the deviation is fixed, delete the row (and note the fix in your CHANGELOG) rather than letting it expire silently.

---

## Gate and auditor integration

When `css-strict.sh` / `js-budget.sh` hit a violation that matches an unexpired
escape, they print a suppression line instead of counting it:

```text
[ELA_002] src/styles/checkout.css:12 — suppressed by ESC_EMBED
...
2 violation(s) suppressed by registered escapes.
```

An expired match is reported and still fails:

```text
[ELA_002] legacy/old.css:5
    inline-size: 280px
    escape expired (ESC_LEGACY 2025-01-01) — renew the escapes.md entry or fix the violation
```

The css-auditor mirrors this in prose: it reports a registered escape as an
**acknowledged exception** rather than a surprise violation. Acknowledgement does
not change the rubric score — the escape is noted, but the underlying deviation
still counts against the rubric total. The distinction is in tone.

---

## Limits

To prevent escape-hatch abuse:

| Metric | Limit | Rationale |
|--------|-------|-----------|
| Active escapes per project | **10 max** | More than 10 suggests the system isn't a good fit, not that the exceptions are justified |
| Escapes per file | **3 max** | A file with 3+ escapes should be refactored or excluded from auditing |
| Escapes without an expiry | **0** | Forbidden by format — a row without a valid ISO `Expires` is not parsed |
| Escapes older than their expiry | **0** | Expired escapes fail the gate by design |

---

## Relationship to `@layer bespoke.*`

The CSS `@layer` system provides a different kind of escape: `@layer bespoke.override`
can override brand or component tokens without violating the cascade hierarchy.
This is the *CSS-level* escape mechanism.

The registry is the *contract-level* escape mechanism. They complement each other:

- `@layer bespoke.override` — where the override CSS lives
- `escapes.md` — why the override exists, who owns it, and when it expires
