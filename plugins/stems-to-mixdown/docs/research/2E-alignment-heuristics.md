---
phase: 2
item: 2E
status: policy-decided
date: 2026-05-05
---

# 2E — Stem alignment heuristics

## Question

When stems come from a session export rather than a DAW bounce, they may have different `bext.time_reference` values, indicating they were exported from different timeline positions. The current pipeline uses `amix=duration=longest` and assumes shared anchors at sample 0 (Commandment 14). When can Pass 2 detect the mismatch and recommend consolidation, and what threshold separates "different anchors" from "rounding noise"?

## Background

`bext.time_reference` is a 64-bit unsigned integer in the BWF (Broadcast Wave Format) `bext` chunk, defined in [EBU Tech 3285](https://tech.ebu.ch/docs/tech/tech3285.pdf). It records the **sample count from session time-zero** at which the file's first sample lives. Pro Tools, Logic, Cubase, and Nuendo all populate this field on bounce/consolidate. A stem exported from bar 17 of a 4/4 song at 120 BPM / 48 kHz lives at `time_reference = 17 * 4 * (60/120) * 48000 = 1,632,000` samples. Two stems exported from the same bar share that value to the sample.

`scripts/analyze.py:253` already reads `bext.time_reference` via wavinfo and stores it under `production_metadata.bwf.time_reference` per stem when the optional `wavinfo` package is installed.

## What the values look like in practice

| Workflow | Cross-stem `time_reference` variance | Interpretation |
|---|---|---|
| Pro Tools "Consolidate" or stem-bounce | All stems share the same value (typically `0` for a session-start consolidation, or the bar-anchor's sample offset) | Anchor-aligned. `duration=longest` is correct. |
| Pro Tools "Export Selected as Files" with the same selection | All stems share the value at the start of the selection | Anchor-aligned. |
| Pro Tools "Export Clip Groups" or per-clip exports without consolidating first | Stems carry **per-clip** time_reference, varying by tens of thousands to millions of samples | **Not** anchor-aligned. `amix=duration=longest` will sum at zero offset and the song will be wrong. |
| Logic / Cubase equivalent of the above | Same pattern | Same diagnosis. |
| Hand-renamed stems from disparate sources, no bext at all | All stems return `None` from wavinfo | Cannot infer anchoring; default optimistic assumption (sample 0) stands but is unverifiable. |

## Threshold

**Variance threshold: > 1 sample.** Anchor-aligned stems agree exactly (the field is a sample count, not a floating-point time, so there is no rounding budget). A single-sample disagreement is a typo or a bug in the exporter; a multi-sample disagreement is a real anchoring difference.

The pragmatic comparison:

```python
time_refs = {s.production_metadata.get("bwf", {}).get("time_reference")
             for s in stems
             if s.production_metadata.get("bwf", {}).get("time_reference") is not None}
if len(time_refs) > 1 and (max(time_refs) - min(time_refs)) > 1:
    # fire stems_unanchored
```

When all stems return None (no bext or no wavinfo), the warn does not fire — there is no signal to act on.

## Pass 2 message

```
[warn] stems_unanchored
  Stems disagree on bext.time_reference by up to {delta_samples} samples
  ({delta_ms:.1f} ms). This usually means they were exported from different
  positions on a session timeline rather than as anchor-aligned bounces.
  amix=duration=longest will sum at sample 0 and the song will be wrong.
  Fix: consolidate stems in the source DAW (Pro Tools: Edit → Consolidate;
  Logic: File → Bounce → Stems; Cubase: Audio → Render in Place) so each
  stem has the same time_reference, then re-run analyze.
  → Stems probably need to be consolidated before this skill can mix them.
  See references/format-decisions.md "Channel-count reconciliation" and
  Commandment 10 ("stems must align").
  Affected: <list of filenames with their time_reference values>
```

The flag is `severity="warn"`, not `error`, because:

1. Some operators *intentionally* sum unanchored regions to test rough timing — surface, don't block.
2. `--force` already overrides errors for `rate_mismatch`; mirroring that policy here would invite the same `--force`-by-reflex problem.
3. If the operator does want the skill to align them automatically, that's a Phase 4+ feature (`adelay` per stem from `time_reference`), not a Phase 2 decision.

The plain-English consequence appendix (Phase 4 P1-5) extends the message: `→ Stems probably need to be consolidated before this skill can mix them.`

## What this does NOT do

- **Auto-align via adelay.** Out of scope for the warn. If the operator wants this, it's a separate Phase 4 feature that takes the smallest cross-stem `time_reference` as anchor and adds `adelay=<delta_samples>S` per stem before the sum. Surface the option in the warn message; don't take the action by default.
- **Compare against session metadata in `stems.session.yaml`.** That sidecar carries Pro Tools structural context but not per-clip start times in a machine-readable form. The bext check is the only honest path that doesn't require AAF / OTIO.
- **Fire when wavinfo isn't installed.** Without wavinfo, `time_reference` is None and the warn cannot run. The existing `bit_depth_uncertain` warn already documents this gap; the operator is on notice.

## Decision triggered

**Phase 4 implements the `stems_unanchored` warn in `scripts/sanity.py`** (post-Phase-3 `analyze.py` decomposition; until then, in `analyze.py:sanity_check`). Threshold: > 1 sample variance across populated values. Message text per above.

The warn is gated on wavinfo being installed (no false negative announced when the field is unreadable; the existing wavinfo-not-installed `[info]` line covers that case).

## Sources

- [EBU Tech 3285 — Specification of the Broadcast Wave Format](https://tech.ebu.ch/docs/tech/tech3285.pdf), §2.2 (bext chunk).
- [wavinfo on PyPI](https://pypi.org/project/wavinfo/) — `bext.time_reference` accessor.
- `scripts/analyze.py:244-253` — current bext extraction in this skill.
- `references/commandments.md` §10 — "Stems must align."
- `REVIEW-2026-05.md` §6.4 — Pass 1 should detect time_reference drift.
