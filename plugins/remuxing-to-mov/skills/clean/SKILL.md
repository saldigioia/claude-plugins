---
name: clean
description: Source-clinic pass over a broadcast capture (.ts/.mkv) — integrity checks and, where wanted, lossless corrections TO the source file in its own container, without recoding or remuxing. Use when the user asks to check, clean, repair, or fix a capture while keeping it a .ts/.mkv (not converting to .mov), reports "video starts at X"/black at the head/a timeline that doesn't start at zero, or wants to know what is hiding in a fresh capture before archiving it. Report-first; corrections are separate, gated commands and the source file is never touched.
argument-hint: [input-file] [--deep]
allowed-tools: Bash, Read
---

# /clean — the source clinic

Run the integrity battery on the file in `$ARGUMENTS` (or the file the user
just referenced) **in its own container** — no remux, no re-encode, source
never touched. Run the bundled driver — do **not** hand-roll ffmpeg:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/scripts/clean.sh" <INPUT> [--deep]
```

(Fallback when `${CLAUDE_PLUGIN_ROOT}` is unset: the in-repo path
`skills/remuxing-to-mov/scripts/clean.sh`.)

## What it does

Report-only, cheapest passes first: `probe.sh` (identity + timestamp
profile), `ts-health.sh` (whole-file transport + timeline, demux-only),
`lead-check.sh` (black-lead signature at the head — a bounded decode).
`--deep` adds `dim-scan.sh` (mid-stream resolution changes) and a full
decode-to-null — both whole-file decodes, so only when asked or when a
junction is suspected. Every finding prints its exact route, and every route
stays in the source container.

## The consent model — relay it exactly

- **Tier 1 (structural, discards nothing presentable):** `zero-base.sh`
  (timeline rebase to the stated floor) and `trim-to-idr.sh` (undecodable
  pre-roll). The report prints these commands ready to run. Run one when the
  user asks for the fix; each is self-gating (prediction contract, post-mux
  census, the verify-source battery) and writes an atomic sibling.
- **Tier 2 (content-discarding):** `surgical-cut.sh` — the black-lead cut
  discards decodable media (black video and, typically, HOT program audio
  under it: the report states exactly how much). It refuses without
  `--discard-content`. **That flag is the operator's call: relay the loss
  statement and the command verbatim, and never add the flag on your own** —
  the same rule as rung4's attestation, one tier lighter.
- Timeline defects (missing timestamps, DTS rot) are NOT clinic business:
  the report routes them to `diagnose.sh` — relay that, don't improvise a
  repair.

## Related single-purpose tools (same directory)

- "video starts at X" / "the glitch is at X": `clock.sh INPUT X` — players
  report player-clock, ffprobe reports container time; this prints the
  translation, the bracketing keyframes, and per-frame luma around the
  address. Run it FIRST on any timestamp complaint.
- Prove any same-container output: `verify-source.sh SOURCE OUTPUT [...]`
  (a cut re-declares its filters there — the builders do this themselves).

## Report back

Exit codes: `0` CLEAN, `10` FINDINGS (each with its route — relay them),
`1` DAMAGED (permanent transport loss; re-capture is the only true fix),
`2` usage. A clinic output, once built, is the new master candidate: run the
remux ladder (`/remuxing-to-mov:mov`) on IT and verify downstream builds
against IT — the untouched original keeps everything a Tier-2 cut discarded.
Doctrine and recipes: `skills/remuxing-to-mov/references/source-clinic.md`.
