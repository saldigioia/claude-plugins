# Escape Hatch Registry

Convention for recording intentional deviations from Every Layout principles. Every project accumulates exceptions — this makes them visible, justified, and suppressible.

---

## Purpose

Real projects need intentional violations:
- A fixed-width sidebar required by a brand guideline
- A media query for print layout
- An arbitrary spacing value to align with a third-party embed
- A physical property for a CSS feature without a logical equivalent

Without a registry, these violations:
1. Trigger the auditor on every run (noise)
2. Get "fixed" by contributors who don't know they're intentional (churn)
3. Accumulate silently with no accountability

The registry makes exceptions **visible, justified, and bounded**.

---

## File Convention

Create `escapes.md` in the project root (or `src/styles/escapes.md`):

```markdown
# Escape Hatch Registry

Intentional deviations from Every Layout principles, with justification.

## Active Escapes

### ESC-001: Fixed sidebar width for brand nav

- **Principle violated:** ELP_002 (Intrinsic Sizing)
- **File:** `src/styles/nav.css:12`
- **Code:** `inline-size: 280px`
- **Justification:** Brand guidelines require exactly 280px sidebar. Design team confirmed this is non-negotiable.
- **Owner:** @designer
- **Added:** 2026-03-15
- **Review date:** 2026-09-15

### ESC-002: Media query for print layout

- **Principle violated:** ELP_009 (Algorithmic Layout)
- **File:** `src/styles/print.css:5`
- **Code:** `@media print { ... }`
- **Justification:** Print is a fundamentally different medium. Linearizing Grid and collapsing Cover requires explicit print overrides.
- **Owner:** @developer
- **Added:** 2026-03-20
- **Review date:** Never (permanent)

## Retired Escapes

### ESC-003: Arbitrary spacing for Stripe embed (RETIRED)

- **Principle violated:** ELP_005 (Modular Scale)
- **File:** `src/styles/payment.css:8` (deleted)
- **Code:** `padding: 13px` (to match Stripe iframe)
- **Justification:** Stripe's embedded checkout had 13px internal padding. Alignment required matching.
- **Retired:** 2026-04-01 — Stripe updated their embed, now uses standard padding.
```

---

## Registry Fields

| Field | Required | Description |
|-------|----------|-------------|
| **ID** | Yes | Sequential `ESC-NNN` identifier |
| **Principle violated** | Yes | ELP_* ID and name |
| **File** | Yes | File path and line number |
| **Code** | Yes | The violating code |
| **Justification** | Yes | Why this deviation is necessary (one sentence minimum) |
| **Owner** | Yes | Who approved this escape |
| **Added** | Yes | Date the escape was registered |
| **Review date** | Yes | When to re-evaluate (or "Never" for permanent escapes) |

---

## Rules

1. **Every escape must have a justification.** "It was easier" is not a justification. "Brand guidelines require it" is.
2. **Every escape must have an owner.** Someone is accountable for this deviation.
3. **Every escape must have a review date.** Temporary escapes get a 6-month review. Permanent escapes must say "Never" explicitly.
4. **Retired escapes stay in the registry.** Move them to the "Retired" section with a retirement date and reason. This prevents re-introduction.
5. **The auditor respects the registry.** When running `/audit-layout`, the auditor should note registered escapes as "acknowledged" rather than "violation."

---

## Auditor Integration

When the css-auditor encounters a violation that matches a registered escape:

```markdown
### Acknowledged Escape — ESC-001
- **File**: src/styles/nav.css:12
- **Code**: `inline-size: 280px`
- **Principle**: ELP_002
- **Status**: Registered escape, review date 2026-09-15
```

This does not affect the score — the escape is acknowledged but the violation still counts against the rubric total. The distinction is in the auditor's *tone*: it reports the escape as a known exception rather than a surprise violation.

---

## Limits

To prevent escape hatch abuse:

| Metric | Limit | Rationale |
|--------|-------|-----------|
| Active escapes per project | **10 max** | More than 10 suggests the system isn't a good fit, not that the exceptions are justified |
| Escapes per file | **3 max** | A file with 3+ escapes should be refactored or excluded from auditing |
| Escapes without review date | **0** | Every escape must be re-evaluated eventually |
| Escapes older than 1 year without review | **0** | Stale escapes become invisible technical debt |

---

## Relationship to `@layer bespoke.*`

The CSS `@layer` system provides a different kind of escape: `@layer bespoke.override` can override brand or component tokens without violating the cascade hierarchy. This is the *CSS-level* escape mechanism.

The registry is the *documentation-level* escape mechanism. They complement each other:

- `@layer bespoke.override` — where the override CSS lives
- `escapes.md` — why the override exists and who owns it
