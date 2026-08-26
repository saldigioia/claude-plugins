# 1.15 Work Order — the Source-Clinic Round

> **Status (2026-08-26): EXECUTED, all phases.** Phase 0 (packaging debt) —
> CHANGELOG.md, manifest shrink, strays removed, comma allowed-tools, CI
> resurrected at the monorepo root (plugin-level file is a pointer), knobs.md,
> path-convention note; `$schema` declined (no verified URL on this bench —
> recorded in CHANGELOG). Phases 1–5 — verify-source.sh, clock.sh,
> lib-rewrap.sh, zero-base.sh, lead-check.sh, surgical-cut.sh, dim-scan.sh,
> clean.sh, skills/clean/SKILL.md, references/source-clinic.md, SKILL.md
> rows + machine-lines table, README, tests/README §32, regression tests
> 66–72. Baseline suite 263/0 green before the round; final suite result on
> the closing report. Deviations from the plan text: none of substance —
> lead-check reuses gop-probe.sh for the boundary class instead of a raw NAL
> census (the tested classifier existed); clean.sh is report-only
> (`--apply-tier1` recorded as a candidate in source-clinic.md).
>
> Working reference for the 1.15.0 round, transcribed before execution (2026-08-26).
> Origin: the feed.ts case file (`~/Downloads/broadcast-cleanup.md`, 2019-VMA backhaul
> cleanup, 2026-08-26) — a hand-navigated, fully-verified **source-domain** repair the
> plugin could not yet perform — plus the architectural audit of the same date.
> Doctrine base: v1.14.0 (reorder-DTS round complete; its Phase 6 packaging items
> shipped **here**, in Phase 0, because they never landed in 1.14.0).

## The mandate extension

The existing ladder answers "how do I get this capture INTO a QuickTime-ready
`.mov`". This round adds the storey **below** it: run integrity checks and, where
necessary, corrections **to the source file in its own container** (`.ts`, `.mkv`)
— no re-encode, no container change, never in place.

**Terminology (doctrine):** a **re-wrap** is a same-container-family rewrite whose
essence is byte-identical and whose structure (mpegts PID/program layout, PAFF
pair-timestamp shape) is preserved — distinct from a **remux** (container change,
the existing ladder). "Corrections without remuxing" = re-wrap territory: the
deliverable is a sibling in the source's own container; the original is never
touched (house law, unchanged).

**Consent model (doctrine, two tiers):**
- **Tier 1 — structural**: corrections that discard nothing any player could ever
  present (zero-base, timestamp repair, pre-roll trim). Runnable by drivers,
  always announced.
- **Tier 2 — content-discarding**: any cut that drops decodable media (black-lead
  removal discards real program audio under black video; any editorial trim).
  NEVER automatic: requires the explicit `--discard-content` flag AND prints a
  loss statement (exact seconds/frames of decodable media discarded, with the
  reminder that the untouched original retains it). Precedent: trim-to-idr's
  open-GOP refusal ("that trade is the operator's") and the Rung-4 philosophy,
  lighter because nothing is re-encoded.

**Provenance:** every correction writes a JSON sidecar (`<out>.clinic.json`):
recipe, drop expressions, predicted artifacts, per-stream hashes. The healed
sibling is the new master *candidate* and becomes the ladder's SOURCE downstream
(trim-to-idr's existing "verify against THIS file" rule, generalized).

## Phases

### Phase 0 — Ship the orphaned 1.14 Phase 6 (packaging debt)
1. `CHANGELOG.md` (new): version history moved out of `plugin.json`;
   `description` shrunk to two sentences.
2. Delete strays: `QTFF-AUDIT-PLAN.md.bak-20260726`, `.DS_Store` ×2 (+ gitignore).
3. `allowed-tools` comma-separated in both SKILL.md frontmatters; `$schema` in
   plugin.json.
4. CI resurrected: monorepo-root workflow (`.github/workflows/` at the repo root,
   paths prefixed `plugins/remuxing-to-mov/`, path-filtered); plugin-level copy
   becomes a pointer note. Matrix documented against the 9.0.1 bench.
5. Portable-path convention: one prominent note in SKILL.md defining
   `scripts/…` = `${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/scripts/…`
   (lighter than rewriting ~46 invocation lines; decision recorded).
6. `references/knobs.md`: every `RTM_*`/`TSH_*`/`DISC_*` env knob, greped from the
   scripts, one table.
**Gate 0:** baseline suite green before AND after; `plugin.json` parses.

### Phase 1 — Measurement first: the source-domain prover + the clock
1. **`scripts/verify-source.sh SOURCE OUTPUT [--filter-v EXPR] [--filter-a EXPR]
   [--trim-head SECS]`** — the case file's verification battery as a unit, and the
   fix for the "no identity prover for non-MOV outputs" hole:
   (a) **filtered-reference streamhash**: per-stream MD5 of OUTPUT vs SOURCE
       demuxed through the *identical* bsf filters (empty filters = full
       per-stream identity — stronger than the .mov path can claim);
   (b) **census arithmetic**: ts-health `--kv` of both; with no plan the censuses
       must match; with filters/trim the deltas must equal the plan exactly;
   (c) head decode (first output frame: PTS + luma reported), tail monotonicity,
       duration arithmetic (source − trim = output ± tol);
   (d) **nothing-unexplained**: every source↔output census difference is either
       matched-inherited or a stated consequence of the plan; anything else
       downgrades. Machine line `SRCV_SUMMARY`; house exit contract.
2. **`scripts/clock.sh INPUT PLAYER_TIME`** — the player-clock translator: users
   report player-clock, ffprobe reports container clock, they differ by
   `format.start_time`. Prints the raw timestamp, bracketing keyframes (packet
   scan), and per-frame luma means (windowed `signalstats` decode) around the
   address. Machine line `CLOCK_*` KV.
**Gate 1:** new tests `66-verify-source.sh`, `67-clock.sh` (constructed
fixtures); full suite green.

### Phase 2 — Zero-base re-wrap + the prediction contract
1. **`scripts/zero-base.sh IN OUT.ts`** (mpegts-family only; others refused with
   routes): `-muxdelay 0 -muxpreload 0` copy re-wrap, PID/program layout
   preserved (`-streamid` from probed ids, `-mpegts_pmt_start_pid`/
   `transport_stream_id`/`service_id` from `-show_programs`).
   **Prediction contract:** a null-muxer pre-pass counts the equal-DTS collision
   sites first and the script announces the expected artifact set (N +1-tick
   mate-DTS nudges) BEFORE building; verify-source afterwards confirms exactly
   that and nothing more. **Floor stated up front**: minimum achievable start =
   first-frame reorder delay; exact 0.000000 is impossible with B-frames without
   inventing timing — printed, never discovered.
2. Shared re-wrap plumbing (PID preservation + prediction pre-pass) lands in a
   lib (`lib-rewrap.sh`) so Phase 3 reuses it.
**Gate 2:** test `68-zero-base.sh` (minted shifted-start fixture; hash identity;
prediction == observation); suite green.

### Phase 3 — The lead-in detector + the deterministic surgical cut (Tier 2)
1. **`scripts/lead-check.sh IN`**: luma-mean sweep of the first N seconds
   (windowed decode, `signalstats`), keyframe map (demux), H.264 NAL-type census
   (IDR type-5 vs open-GOP type-1; mpeg2video gets keyframe+luma only,
   announced), audio RMS across the candidate splice. Names the black-lead
   signature and the exact cut address (packet index + PTS + audio PTS
   threshold) — and states what a cut would discard. `LEADCHECK_*` KV.
2. **`scripts/surgical-cut.sh IN OUT --video-drop … --audio-drop-lt-pts … 
   --offset … --discard-content`**: the sanctioned non-IDR cut on TS —
   census-driven `noise=drop=` bsf by packet index (video: NOPTS mates make PTS
   expressions impossible; index selection requires the no-seek whole-file pass —
   constraint-as-feature) and by PTS (audio), `-copyts` +
   `-output_ts_offset`, PID layout preserved, leading-B rule applied (drop
   leading Bs + mates by index — they poison `format.start_time`). Both `-ss`
   forms refused on TS by doctrine (measured-unreliable, case file Phase 4).
   Tier 2: refuses without `--discard-content`; prints the loss statement.
   Verified by verify-source with the cut filters as the reference definition.
**Gate 3:** tests `69-lead-check.sh`, `70-surgical-cut.sh` (minted black-lead
fixture: black lead + program splice; filtered-reference identity; census
arithmetic exact). Open-GOP leading-B and true-PAFF integration recorded as
SYNTHESIS LIMIT (operator-verified on the next real class member, per house
style). Suite green.

### Phase 4 — The SPS/dimension-change scan + recorded candidates
1. **`scripts/dim-scan.sh IN`**: whole-file frame dimension sweep (decode pass,
   background-able) that closes the "mid-stream SPS / resolution change" named
   limitation's detection half; a change names its splice PTS and routes to
   surgical-cut / keep. known-limits entry updated from
   "detect-and-warn candidate, not implemented" to implemented-detector.
2. Recorded candidates (named, not built): `wrap-split.sh` (≥2-wrap horizon
   split); `derive-dts.sh --container mkv` (same-container MKV lane for the
   2023-VMA class); bars-and-tone lead detection.
**Gate 4:** test `71-dim-scan.sh` (the known-limits two-resolution fixture
recipe); suite green.

### Phase 5 — The clinic driver, the skill surface, the release
1. **`scripts/clean.sh IN`** — orchestrates the case-file sequence with its cost
   ordering (demux before decode; cheap probes first; full-file passes
   grouped): probe → head/tail census → ts-health → lead-check → findings
   report where **every route stays in the source container**; Tier-1 offered,
   Tier-2 named for the operator. `CLEAN_SUMMARY` machine line.
2. Skill surface: new `skills/clean/SKILL.md` (command `/remuxing-to-mov:clean`),
   `references/source-clinic.md` (doctrine, recipes, floors, the leading-B rule,
   player-clock lesson), SKILL.md gains only trigger rows ("starts at X",
   "black at the head", "clean it but keep it a .ts").
3. CHANGELOG entry; version → **1.15.0**; full suite green vs Phase-0 baseline.

## Ground rules (inherited, binding)
Machine lines additive-only; exit contract 0/10/1/2/11 (+documented legacy 3);
every empirical claim dated; announce before acting; atomic `.part` with real
extension; never touch the source; suite green after every phase.
