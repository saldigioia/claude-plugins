# Remuxing-to-MOV — Multi-Phase Improvement Plan

A phased, incremental plan to land the brainstormed enhancements without
re-architecting the skill. Each phase is self-contained and ends with the plugin
in a working, tested state, so the work can stop and resume across sessions.

The ordering is dependency-driven, not priority-driven: Phase 0 hardens code
already in users' hands, Phase 1 unblocks the driver, and so on. Phases 3 and 5's
sub-items are independent and can be reordered or parallelized.

> **STATUS — all phases implemented and tested (2026-06-15).** New scripts:
> `doctor.sh`, `auto.sh`, `batch.sh`, `playable-check.sh`; `probe.sh --kv/--json`;
> `verify.sh --signaling --audio` + degrade path; multi-version CI. The regression
> harness now runs **61 assertions, all green**. The macOS path of
> `playable-check.sh` and the GitHub Actions matrix can't be exercised in a Linux
> sandbox — validate those on a real Mac / on first CI run. Open decisions below
> were taken with the recommended defaults (old-ffmpeg degrade, KEY=VAL sidecars,
> macOS-gated playability, POSIX core).

## Guiding principles (apply in every phase)

- **Lossless-first stays sacred.** Any automation may select Rungs 0–3. It must
  **never** auto-select Rung 4 (re-encode) — that remains a deliberate human
  choice, surfaced as a recommendation only.
- **House conventions for every new script:** `set -euo pipefail`, `-nostdin`,
  atomic output (`.part` → `mv`), never modify or delete the source, refuse
  source-onto-itself, bash 3.2 compatible (macOS default), and `source
  lib-paff.sh` wherever PAFF-awareness is needed.
- **Ship the test with the feature.** Each item adds assertions to
  `tests/regression.sh` in the same session. Where a property can't be
  synthesized (true PAFF, real captions), document the limit in the test header —
  don't fake a green.
- **SKILL.md remains the decision hub.** New scripts/flags get a one-line pointer
  in the instant-answers table, the ladder, or the "when to read which reference"
  table. Deep detail goes in `references/`, never inline bloat.
- **Definition of done per phase:** `bash -n` clean on all scripts,
  `tests/regression.sh` passes, SKILL.md/reference pointers updated, plugin still
  usable end-to-end.

## Phase map

| Phase | Theme | Items | Depends on | Size |
|------|-------|-------|-----------|------|
| 0 | Harden what shipped | `doctor.sh`; verify.sh graceful degrade; minimal CI | — | S |
| 1 | Machine-readable probe | `probe.sh --kv/--json` | 0 | S |
| 2 | Executable ladder | `auto.sh`; `--dry-run` | 1 | M |
| 3 | Verification extensions | `verify --signaling`; captions; dual-track audio | 0 | M |
| 4 | Batch + provenance | `batch.sh`; sidecars; resume | 2 | M |
| 5 | Reach + coverage | macOS playability (optional); multi-version CI | 2–4 | M |

---

## Phase 0 — Harden what shipped (do first)

**Why first:** the VCL lossless check added in the last session depends on the
`filter_units` and `h264_mp4toannexb` bitstream filters. On an ffmpeg build that
lacks them, `vcl_hash` returns empty and `verify.sh` currently **false-FAILs every
H.264 file**. This phase closes that and locks the safeguards into CI.

**0.1 `scripts/doctor.sh`** *(new)*

- What: a one-shot environment report; nonzero exit if a hard dependency is
  missing.
- Approach (all grounded): assert `ffmpeg`/`ffprobe` on PATH; required bsfs via
  `ffmpeg -hide_banner -bsfs | grep -w filter_units` (and `h264_mp4toannexb`,
  `hevc_mp4toannexb`); required muxers via `ffmpeg -muxers | grep -w streamhash`
  (and `framemd5`, `null`, `mov`); print the ffmpeg version and the version-gated
  behaviors `probe.sh` already knows (DV ≥5.0, the 8.1.1 SRT-copy bug). Reuse the
  KEY=VAL output style from `lib-paff.sh`.
- Verify: harness asserts `doctor.sh` exits 0 in-sandbox and that every
  capability `verify.sh` relies on is reported `present`.

**0.2 Graceful degrade in `verify.sh`**

- What: when `filter_units`/`h264_mp4toannexb` are unavailable, stop false-FAILing.
- Approach: probe capability once; if the VCL path is unavailable for an H.264
  source, emit `REVIEW` with "VCL check unavailable — upgrade ffmpeg or settle
  with `--full`," and fall back to the order/count-tolerant sorted-multiset
  decoded compare rather than the positional framemd5.
- Verify: harness simulates absence (wrap `ffmpeg` with a stub that hides the bsf,
  or gate on a `PF`-style flag) and asserts the verdict is `REVIEW`, never a false
  `FAIL`.

**0.3 `.github/workflows/ci.yml`** *(new, minimal)*

- What: run `tests/regression.sh` on push/PR against one ffmpeg version.
- Approach: Ubuntu runner, `apt-get install ffmpeg`, `bash tests/regression.sh`.
  Single version now; the matrix comes in Phase 5.
- Verify: workflow goes green on a no-op commit.

**DoD:** doctor reports a clean environment, verify.sh can't false-FAIL on a
missing bsf, CI is green.

---

## Phase 1 — Machine-readable probe (enabler for the driver)

**1.1 `probe.sh --kv` (and optional `--json`)**

- What: a structured summary of everything the human-readable probe prints —
  container, video/audio codecs+tags, `is_avc`, field structure, the `PF_*` PAFF
  block, color tags, and a **recommended rung**.
- Approach: build on the `lib-paff.sh` KEY=VAL convention; `--json` can be a thin
  formatter over the same keys. Keep the default human output unchanged.
- Verify: harness asserts the structured output contains the expected keys and
  that recommended-rung matches known fixtures (clean H.264 → Rung 0; MP2 audio →
  Rung 1; forced-PAFF stub → Rung 3).

**DoD:** `auto.sh` can consume one probe call instead of re-running ffprobe a
dozen ways.

---

## Phase 2 — The executable ladder (`auto.sh` + `--dry-run`)

**Why it matters:** the original corruption was a manual routing mistake. Encoding
the ladder in code removes the step where a human/agent picks the wrong rung.

**2.1 `scripts/auto.sh INPUT OUTPUT.mov [opts]`** *(new)*

- What: probe (via 1.1) → choose the lowest viable rung → execute via the
  existing `remux.sh` / `rebuild-paff.sh` → `verify.sh` → print verdict.
- Routing: Rung 0/1 by audio codec; Rung 2 genpts only for non-PAFF missing-TS;
  **PAFF → Rung 3 at the measured field rate** (the guilty-until-proven default);
  Rung 4 is **never** auto-selected — print "re-encode required: see
  delivery-encode.md" and stop.
- Safety: never deletes the source; relies on sub-scripts' atomic output; if
  `verify.sh` returns REVIEW/FAIL, do **not** report success — surface the next
  action (e.g., rebuild, or `--full`).
- Single source of truth: the rung-decision lives in one function that mirrors
  SKILL.md's ladder; the harness checks code and prose agree on representative
  cases so they can't drift.

**2.2 `--dry-run`**

- What: print the chosen rung, the exact command(s), and the rationale; execute
  nothing. Good for agent transparency and human approval before a batch.

- Verify: harness feeds fixtures (clean H.264, MP2-audio, single-GOP,
  forced-PAFF) and asserts the rung chosen and that re-encode is never auto-picked.

**DoD:** `auto.sh in.ts out.mov` produces a verified file or a clear,
non-success verdict, with no manual rung choice.

---

## Phase 3 — Verification extensions (independent; group as one phase)

Each is an opt-in flag/step, each ships its own fixtures and assertions.

**3.1 `verify.sh --signaling`**

- What: confirm color/HDR signaling survived the copy.
- Approach: compare source vs output for `color_primaries/transfer/space/range`,
  the `hvc1` tag, the DOVI configuration record (in `ffprobe -show_streams`
  `side_data_list`), and HDR10 `mdcv`/`clli` (in `ffprobe -show_frames
  -show_entries frame=side_data_type`). Report drift as REVIEW — some normalization
  on copy is benign.
- Verify: HDR-tagged synthetic fixture; assert tags preserved; assert a
  deliberately stripped output is flagged.

**3.2 Caption / subtitle survival**

- What: verify embedded captions and text subs made it through.
- Approach: CEA-608/708 via `ffprobe -show_entries stream=closed_captions`
  (returns 1 when present) and frame-level caption side data; `mov_text`/sidecar
  presence by stream count. Assert source presence ⇒ output presence.
- Verify: synthesize what's possible; **document** that true broadcast CEA-608
  needs a real capture (synthesis limit, like the PAFF case).

**3.3 Dual-track audio verification**

- What: the default deliverable is dual-track, but verify.sh is video-centric.
- Approach: confirm the PCM "access" track is a faithful decode of the source
  audio (decode both, compare samples/hash) and the preserved original track is
  bit-exact (`streamhash`). Add to `verify.sh` or `dual-track.sh`.
- Verify: build a dual-track fixture; assert both properties; assert a corrupted
  access track fails.

**DoD:** a file can be proven lossless **and** signaling-, caption-, and
audio-preserving without a full re-decode.

---

## Phase 4 — Batch orchestration + provenance

**4.1 `scripts/batch.sh GLOB_OR_DIR [opts]`** *(new)*

- What: iterate inputs, call `auto.sh` per file, never delete sources, `-nostdin`
  throughout, and write a run report (counts of OK / REVIEW / FAIL and which files
  need attention).
- Idempotent resume: skip any input whose sidecar exists and whose source hash
  still matches.

**4.2 Provenance sidecars**

- What: a `.json` (or KEY=VAL) sidecar beside each output recording source path +
  `streamhash` + VCL hash, rung used, ffmpeg version, field structure, verify
  verdict + notes, and an ISO timestamp.
- Payoff: future re-verification without re-decoding the source; an auditable
  batch trail (directly answers "how was this made, is it verified").

- Verify: run batch over a small fixture dir; assert manifest tallies, sidecars
  are well-formed, resume skips done files, and a FAIL file is reported and **not**
  marked done.

**DoD:** a directory of captures becomes a directory of verified MOVs plus an
audit trail, re-runnable safely.

---

## Phase 5 — Reach + coverage

**5.1 `scripts/playable-check.sh` (macOS-only, optional)**

- What: close the "playable ≠ valid" gap — the one thing the ffmpeg pipeline
  can't confirm — for the AC-3/E-AC-3 "unverified" rows.
- Approach: guard on `uname`; on macOS use `qlmanage -p` / an AVFoundation probe /
  scripted QuickTime open to confirm the output actually renders; on non-macOS,
  no-op with a clear message. Keep it **off** the default verify path; invoke
  explicitly or via `auto.sh --playable`.
- Verify: harness asserts a graceful skip on Linux (confirmed: `qlmanage`/`afplay`
  are absent in the Linux CI); manual confirmation on the user's Mac.

**5.2 Multi-version CI matrix**

- What: extend the Phase-0 workflow to run `regression.sh` across several ffmpeg
  versions (e.g. 4.4, 6.1, 7.x) to validate the skill's many version-specific
  claims and every new feature.
- Verify: matrix green; any version-specific divergence surfaces as a failing cell.

**DoD:** the QuickTime-playability blind spot has an optional probe, and the
safeguards are proven across ffmpeg versions on every push.

---

## Cross-cutting testing discipline

- Every feature lands with assertions in `tests/regression.sh`; the harness must
  stay self-contained (synthesizes its own fixtures, cleans up, exits nonzero on
  any failure).
- Prefer asserting the **property**, not the happy path — the founding lesson.
  When a property isn't synthesizable, assert the mechanism and document the limit.
- Keep `bash -n` (and `shellcheck` if available) clean on every script each phase.

## Out of scope (to prevent drift)

- Re-encoding/editing features beyond the existing Rung 4.
- A GUI, a watch-folder daemon, or any long-running service.
- A Python/Go rewrite — it breaks self-contained bash and bash-3.2 portability.
- Becoming a general ffmpeg wrapper/editor — the ffmpeg MCP already covers that.
- Network/cloud features.

## Suggested execution order & parallelization

1. **Phase 0** solo, first (it protects shipped code and gates everything in CI).
2. **Phase 1 → Phase 2** in sequence (the driver consumes structured probe).
3. **Phase 3** can run in parallel with Phase 2 (independent verify flags) — a
   good candidate to split across subagents, one per check.
4. **Phase 4** after Phase 2 (batch wraps auto).
5. **Phase 5** last (CI matrix wants stable features; playability is macOS-gated).

## Open decisions to confirm before starting

- **ffmpeg version floor.** If we can require a version with `filter_units`, the
  Phase-0 fallback simplifies. What's the minimum we support?
- **Cross-platform core vs macOS-only extras.** Confirm the core stays POSIX/Linux
  while `playable-check.sh` is an explicitly optional macOS add-on.
- **Sidecar format.** JSON (tooling-friendly) vs KEY=VAL (bash-friendly, matches
  `lib-paff.sh`). Recommendation: KEY=VAL with an optional `--json` view.
- **Plan location.** This file sits at the plugin root; move to `docs/` if you
  prefer.
