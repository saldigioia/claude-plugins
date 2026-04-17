---
name: audit-layout
description: >
  Score CSS and HTML against the Every Layout 24-point rubric and report
  per-dimension findings with ELP citations and primitive recommendations.
  Use before any CSS refactor or pre-ship verification.
disable-model-invocation: true
context: fork
agent: css-auditor
argument-hint: "<file path or CSS/HTML code to audit>"
---

# Audit Layout

Audit the following layout code against the Every Layout 24-point rubric (8 dimensions × 0-3). Cite principle IDs (ELP_*) for every violation and primitive IDs (ELC_*) for every recommendation.

$ARGUMENTS

The canonical rubric lives in `eval/rubric.md` at the plugin root. The canonical expected-properties list lives in `eval/expected-properties.md`. Read both before scoring — this command does not restate them.

## Report shape

- **Score**: X/24 with grade (A ≥22, B 18–21, C 13–17, D 8–12, F ≤7)
- **Per-dimension breakdown** with evidence: line references and offending code
- **Violations** grouped by severity, each with ELP citation and a concrete fix
- **Primitive recommendations** where a compliant primitive would replace a violation block
- **Positive findings** — what the code does well

If the code under review is already compliant (≥20/24), report a short pass with the one or two dimensions that could be tightened.
