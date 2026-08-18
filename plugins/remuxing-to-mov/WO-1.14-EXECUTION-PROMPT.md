# 1.14 Work-Order Execution Prompt — the Reorder-DTS Round

> **How to use:** paste everything below the line into a fresh Claude Code session at the root
> of the `remuxing-to-mov` source repository (v1.13.0). This prompt consolidates and supersedes
> the discussion in `2023VMA.md`, `vma-prompt.md`, and `fixdts.py`; where they conflict, the
> resolutions in §4 are final. The full per-item spec (evidence, blast radius, adversarial
> checks) lives in **`REORDER-DTS-EDITING-PLAN.md`** at the repo root — read the referenced
> section before each phase. Do not re-open settled questions; this round is decided.
>
> **Status (2026-08-16):** Phase 1 EXECUTED, plus a ten-finding review round (F1–F10: rot-arm
> unification into `backhaul_rot_warn`, gate-(g) provenance matcher, `PF_DTS_SHORT`,
> `PF_SCAN_WINDOW=5000`, audio-census double-count fix; suite 259/0). **Resume at Phase 2.**
> Line numbers cited below are v1.13.0-era and have drifted (verify.sh is now ~1222 lines) —
> locate every evidence site by content, and STOP only on *content* mismatch, never on a
> line-number offset.

---

## 1. What this plugin is

You're working on a video archivist's tool. People capture broadcast television — awards shows,
live feeds, DVDs, Blu-rays — and end up with files QuickTime won't play: `.ts`, `.mkv`,
`.mpg`, broken `.mov`. This plugin moves those streams into a clean, QuickTime-ready `.mov`
while changing as little as possible. The mandate is absolute: **never re-encode, never touch
the source file.** Archival integrity is the product. If a repair can't be done losslessly, the
tool says so and stops; a human decides everything lossy.

Because the stakes are one-of-a-kind 50 GB captures, the tool is paranoid by design: every
build is verified against the source with demux-only proofs (packet hashes, timeline scans,
A/V parity), every risky behavior announces itself before acting, and every claim in the docs
carries the date and machine it was measured on. That paranoia recently caught a real,
invisible defect — and then couldn't fix it. That's why you're here.

## 2. The codebase, briefly

Everything lives under `skills/remuxing-to-mov/`:

- **Drivers:** `scripts/mov.sh` (the one-command entry), `auto.sh` (escalation ladder),
  `remux.sh` (bare Rung-0 copy), `batch.sh`.
- **Diagnosis:** `probe.sh` (census + advisories, `PR_*`/`PF_*` machine fields), `diagnose.sh`
  (the router — prints VERDICTs and names repair rungs), `ts-health.sh` (capture health sweep),
  `gop-probe.sh`, `doctor.sh` (dependency report).
- **Timeline repair rungs:** `pairfill-paff.sh` (half-timestamped PAFF), `rebuild-paff.sh`
  (elementary rebuild; refuses reordered sources by design), `resync.sh` (gap-collapse audio),
  `trim-to-idr.sh` (mid-GOP starts). `rung4.sh` is the operator-attested re-encode — last
  resort, human-gated.
- **Verification:** `verify.sh` (959 lines; gates (a)–(g) + `--signaling`/`--audio`/
  `--silence`/`--full`), `playable-check.sh` (AVFoundation playability + SSIM fidelity),
  `seam-check.sh`, `mp4-swap.sh` (1.13's container-swap rung).
- **Shared libs:** `lib-paff.sh` (scanners: `pf_detect`, `pf_reorder_scan`, `pf_coded_rate`,
  `disc_scan`), `lib-mux.sh` (`mux_census`), `lib-exit.sh` (exit-code contract), `lib-probe.sh`,
  `lib-attest.sh`, `waiver.sh`.
- **Docs:** `SKILL.md` (the ladder + instant-answers table), `references/*.md`
  (`timeline-repair`, `known-limits`, `qtff-claims` — a claims registry that records its own
  reversals, `verification-safety`, `ingest-compatibility`, …).
- **Tests:** `tests/regression.sh` + `tests/regression.d/NN-*.sh` + `tests/make-fixtures.sh`.
  House rule: the suite runs green after any script edit. Useful hooks already exist:
  `PF_PKT_TICKS_FILE` (inject synthetic timestamp shapes into scanners) and
  `RTM_MUX_LOG_APPEND` (inject mux-log lines).

**Conventions that are API, not style:** exit codes `0 DONE | 10 REVIEW | 1 FAIL | 2 usage |
11 REFUSED` (+ documented legacy 3 on pairfill/rebuild/playable-check); machine-readable lines
are append-only — new `KEY=VAL` fields yes, renames never; every new behavior announces itself;
every empirical claim self-dates its bench.

## 3. What's wrong, in plain terms

A 54.6 GB MKV capture of the 2023 VMAs went through `/mov`. The build ran, and the plugin's
hard stop correctly refused to bless the output — the timeline really was broken (163,859
non-monotonic DTS events; 25% of frames dragged out of position). So far, the tool at its best.

Then it fell apart. The router sent the operator to a repair rung that refuses this class of
file. The other rung refuses it too, by design. The correct repair — lossless, cheap, provable
— existed, but no rung could express it. The job was finished with a 90-line Python script
outside the plugin, and when the repaired file came back, the plugin refused to bless it
*again* — a census gate saw a harmless extra chapter track and reported a stream as *missing*.
Along the way it also told the operator that ~5,475 seconds of a 10,944-second program were
dropped (real number: 4.58 s), and failed the audio of a file whose audio was perfect.

The diagnosis behind all of it: the source is ordinary interlaced broadcast, field-coded, one
packet per *field*. ffmpeg reconstructs DTS for MKV using a *frame*-unit reorder depth applied
as a *packet* delay — short by exactly 2× on field packets. The SPS was never wrong; the
report's original root cause was a units error. Nearly every false verdict downstream reduces
to one of three sins: a number that isn't what the gate thinks it is, a measurement scoped
wider than the thing being judged, or a prediction mismatch reported as damage. The evidence
was almost never wrong. The inference and routing on top of it were.

This class — reordered H.264/HEVC in a container that carries no DTS — is essentially **every
1080i North-American HD feed muxed to MKV**. It is the plugin's primary input class.

## 4. Decisions already made — do not re-litigate

1. **Root cause:** the units correction in `vma-prompt.md` supersedes `2023VMA.md`. The SPS
   conforms (`max_num_reorder_frames=2` frames = 4 fields). Anything in the report that reads
   "frame" may mean "coded picture/field" — the corrections table in
   `REORDER-DTS-EDITING-PLAN.md §0` is the authority.
2. **Verified corrections to the report itself:** pairfill has *no* fraction gate (its exit 3
   came from the rate-map gate, starved by the PAFF detector's ratio test); R6's rate bias is
   real but off the critical path; R8 is not reproduced — verify's aggregation is sound and the
   FAIL was gate (g)'s false positive alone. Build on §0, not on the report's framing.
3. **Repair route: Route A** — PyAV rung, venv in `${CLAUDE_PLUGIN_DATA}` (the documented home
   for plugin-owned deps; never under `${CLAUDE_PLUGIN_ROOT}`), `doctor.sh`-gated,
   advisory-before-automatic. Route B (atom surgery) declined for now; **Route C (SPS
   rewrite) rejected as a default** — there is no defect to correct, and it fails
   reversibility. If ever needed: attested declared-derivative only.
4. **New rung's refusal code: 3** (family consistency with pairfill/rebuild; documented,
   suite-pinned). **Whole-file depth pass: mandatory** inside the rung (D-underestimation is
   the one unsafe direction). **SKILL.md paths:** portable `${CLAUDE_PLUGIN_ROOT}` form on
   invocation lines, bare in prose. **seam-check (DF-16):** documented, not fixed this round.
5. **The three-test checklist** (goes into `verification-safety.md`, and governs your reviews):
   (1) is the number the thing the gate says it is? (2) is its scope exactly the judged object?
   (3) does divergence from prediction prove damage, or just surprise?
6. **Never weaken the evidence.** The hard stop, gate (a), gate (d), the source-baseline
   recount, and the (c)/(e) inherited classifiers are load-bearing and untouched. Verdicts
   change only where they were false, and the underlying numbers stay visible.

## 5. Orchestration protocol

You are the **orchestrator**; you do not edit files yourself. Per phase: dispatch one
implementation subagent carrying only that phase's spec + the ground rules + the scope-lock
file list (nothing about other phases); then one independent verification subagent that sees
only the spec and gate commands, never the implementer's transcript; then run the gate commands
yourself. Three-way agreement = gate green; a phase does not begin until the previous gate is
green. **STOP conditions:** a gate fails twice; an edit would rename/remove a machine-line
field; a fix wants out-of-scope files; the tree contradicts this prompt. Keep an uncommitted
ledger (phase, files touched, gate output, verdict). After every phase:
`bash skills/remuxing-to-mov/tests/regression.sh` green against the Phase-0 baseline.

## 6. The phases

Read the matching section of `REORDER-DTS-EDITING-PLAN.md` (cited per phase) before
dispatching; it carries the full Claim/Evidence/Blast-radius/Adversarial detail. Paths below
are relative to `skills/remuxing-to-mov/`.

### Phase 0 — Recon & baseline (read-only)
Confirm source repo, version 1.13.0; run the regression baseline and record it; verify the key
evidence sites still match the plan (spot-check: `diagnose.sh:44` REPAIR selection,
`lib-mux.sh:78-99` census equality, `verify.sh:517-526` gate (g) `grep -c .`,
`lib-paff.sh:164-180` ratio test). Any mismatch → STOP, report.
**Gate 0:** baseline green; spot-checks reproduce.

### Phase 1 — Measure right *(plan §3, Phase 1; defects DF-3/4/5/7/9/11)*
Scope: `lib-paff.sh`, `verify.sh`, `diagnose.sh`, `ts-health.sh`, `probe.sh` (fields only).
1. **1.1** Extend `pf_reorder_scan` with unit-aware depth: `D = max(i − rank(pts[i]))` from the
   PTS column; additive fields `PF_DEPTH_PICS`, `PF_DECL_DEPTH`, `PF_PPF`, `PF_DEPTH_CLASS`
   (`none|match-frame|match-field|understated|unknown`), `PF_DTS_SOURCE=carried|reconstructed`
   (matroska ⇒ reconstructed). Unknown ≠ zero: unparseable SPS → `unknown`, never
   `understated`. `PF_PPF` from the bounded decode-count-vs-packet-count probe; `unknown` when
   inconclusive. Reconcile the 3000/5000 scan windows into one named constant (check pins
   first).
2. **1.2** PAFF detector: test the coded-rate ratio against *both* hypotheses (container fps as
   frame rate vs as field rate, arbitrated by `PF_PPF`); `field_order` stays corroborative;
   announce which hypothesis won. This un-starves the rate map.
3. **1.3** Annotate `PF_PTSNEDTS`/`PF_MAXOFF_TICKS` printers with "(demuxer-reconstructed — not
   a source property)" when `PF_DTS_SOURCE=reconstructed`. Numbers stay.
4. **1.4** `disc_scan`: add a sorted-PTS presentation arm (`DISC_P_COUNT/DISC_P_MISSING`,
   additive); switch the four budget/timeline consumers (diagnose step 4, verify (f)
   `gap_budget`, `--silence` budget, `backhaul_gate`) to the presentation fields; port
   ts-health's `V_NADTS` guard to all of them and to ts-health's own backhaul finding. DTS-rot
   counters stay coded-order.
5. **1.5** `pf_coded_rate`: modal sorted-PTS delta instead of `(n−1)/span` (kills the reorder-
   lead bias).
6. **1.6** Gate (g): add `-vn`, source-baseline subtraction (the (c)/(e) pattern), and an
   inherited-REVIEW path (`delta ≤ 0` → REVIEW, not `other_failed`). Net-positive delta keeps
   today's FAIL.
7. **1.7** diagnose step (1) decode census: baseline or stream-scope the count so audio probe
   errors stop reading as video damage.
**Gate 1:** ticks-file tests pin `match-field`/`match-frame`/`unknown` classification, both
ratio hypotheses, presentation-vs-coded gap counts, and the gate-(g) pair (noisy-video/clean-
audio → REVIEW with delta printed; truly-broken audio → FAIL). `bash -n` clean; machine lines
diff shows append-only; suite green.

### Phase 2 — Judge right *(plan §3, Phase 2; DF-6/10/14/15)*
Scope: `lib-mux.sh`, callers' announcements, `verify.sh --signaling`, `pairfill-paff.sh` text.
1. **2.1** `mux_census` → three verdicts: missing/mutated = FAIL (today's message, right
   direction); expected surplus (movenc-synthesized chapter `text`/`bin_data` when the input
   has chapters; `tmcd` under `-write_tmcd`) = announced PASS; unexpected surplus = REVIEW,
   named as surplus, *never* "missing". Multiset containment planned ⊆ written; additive
   `RMX_CENSUS … surplus=`. Data-class-only PASS — a surplus `h264` is REVIEW, ever.
2. **2.2** `mux_confessions`: split by ffmpeg stream tags — `vost` confessions keep the hard
   stop verbatim; audio/subtitle nudges → announced count + REVIEW.
3. **2.3** `--signaling`: gate the `hvc1` assertion on the container test gate (g) already
   computes.
4. **2.4** pairfill `PP_MAXRUN` refusal text names the derive rung (lands fully in Phase 4).
**Gate 2:** chaptered-fixture pair (v1.13.0-FAIL shape now PASSes with announced surplus; a
genuinely dropped planned track still FAILs); ms-quantized-audio MKV completes with REVIEW
while an injected `vost` confession still hard-stops (`RTM_MUX_LOG_APPEND`); MKV cross-check
output no longer DRIFTs on hvc1. Suite green.

### Phase 3 — The missing rung *(plan §3, Phase 3; DF-1/8)*
Scope: new `scripts/derive-dts.sh` + vendored `derive-dts.py`, `doctor.sh`, `tests/`.
Build Rung 3-DERIVE from `fixdts.py`'s derivation (already proven on the incident: PTS
preserved, DTS monotonic ≤ PTS, video MD5 identical): whole-file D recompute; pre-roll spaced
at the modal coded-picture duration; codec-agnostic packet copy (closes the non-H.264 orphan);
chapters re-attached by the rung itself (repair → chapters → gates); preconditions announced
(zero N/A PTS, zero duplicate PTS, `PF_DEPTH_CLASS ∈ {match-field, understated}` or announced
`--force`); output gates: PTS multiset identity, strict monotonic DTS ≤ PTS, verify gate (a)
packet-hash, `mux_census`, `mux_confessions` (0 expected). PyAV via `${CLAUDE_PLUGIN_DATA}`
venv; absent → print the one-line bootstrap + manual recipe, exit 10. Refusal code 3,
documented in SKILL.md's exceptions and pinned in `14-exit-codes.sh`.
**Pre-check (do this first):** `${CLAUDE_PLUGIN_DATA}` is currently cited only from the
work-order discussion, not verified against the live plugin runtime — confirm it resolves to a
real, persistent directory before building anything on it; if it does not exist or is empty at
runtime, fall back to `~/.claude/plugins/data/remuxing-to-mov/` explicitly and record the
measurement in the script header.
**Gate 3 (the three-layer pin):** (i) ticks-file pins detection routing; (ii) end-to-end on a
minted B-pyramid MKV with ffmetadata chapters — derivation, chapters, census, gate (a),
monotonicity all pass, and the `match-frame` guard blocks auto-routing (adversarial half);
dup-PTS and `unknown`-class inputs refuse; (iii) true-PAFF integration recorded as
operator-verified per house SYNTHESIS LIMIT style — never faked. Suite green.

### Phase 4 — Route right *(plan §3, Phase 4; DF-2/8/15)*
Scope: `diagnose.sh`, `verify.sh` text, `probe.sh`, `ts-health.sh`, `rebuild-paff.sh` text,
`trim-to-idr.sh` text, `remux.sh` text, `auto.sh`, `SKILL.md` routing rows.
Route by measured profile: `PF_NOPTS_FRAC>0 ∧ PAFF` → pairfill; `frac==0 ∧ reorder` →
derive-dts (also when container DTS is carried-but-rotten); no-reorder missing-TS → rebuild;
non-H.264 timeline rot → derive-dts. Verdicts print the measurements that drove the route.
Update every recommendation site from the DF-2 register (plan §1 lists all file:line); strike
ts-health's "lossless either way"; auto.sh ladder gains the rung between 3-PAIR and Rung 4;
`PR_REC_RUNG` gains additive `3-derive`.
**Gate 4:** extended `23-escalation.sh`: the reordered-MKV fixture through diagnose names
derive-dts and not pairfill; half-ts profile still names pairfill; `unknown`-class routes to
diagnosis, not the rung. Grep-pin every updated recommendation site. Suite green.

### Phase 5 — Write it down *(plan §3, Phase 5; DF-12/13)*
Scope: `references/known-limits.md`, `timeline-repair.md`, `qtff-claims.md`,
`verification-safety.md`, `SKILL.md`, `tests/README.md`, advice-site strings.
New known-limits entry under the corrected heading (**"Field-coded (PAFF) capture in a DTS-less
container: ffmpeg's frame-unit DTS reconstruction"**) with the full signature, the
cross-container warning, the route, and the frozen/open items (ref-frames notice; Route C
gate-(a) sub-question). Qualify the lossless-MKV-copy advice at all 8 sites; fix
`diagnose.sh:211`'s "survives honestly". Rewrite timeline-repair's pairfill-preference doctrine;
add the 3-DERIVE taxonomy row. Record the reversals in qtff-claims (root cause superseded; R6
chain; R8 premise; DF-4 budget-narrowing direction). Add the three-test checklist to
verification-safety.md.
**Gate 5:** coherence subagent (fresh eyes) reads all touched docs + SKILL.md: no document
still asserts the old root cause, the old routing doctrine, or unqualified MKV-copy safety;
every new claim dated and bench-stamped or marked `documented-not-measured`/**[frozen]**.

### Phase 6 — Packaging & release *(plan §3, Phase 6; DF-17)*
Scope: `skills/*/SKILL.md` frontmatter, `.claude-plugin/plugin.json`, `CHANGELOG.md` (new),
`.github/workflows/ci.yml`, stray files.
Comma-separate `allowed-tools` (both skills; record what the space form actually resolved to);
replace `${CLAUDE_SKILL_DIR}`; portable-path the ~46 invocation lines in the main SKILL.md;
shrink `description` to two sentences and move history to `CHANGELOG.md`; add `$schema`;
delete the `.bak` and `.DS_Store` strays; **fix the dead-lettered CI** (it never runs in the
monorepo layout) and add `claude plugin validate . --strict` plus the three blind-spot greps
(tools format, placeholder allowlist, no bare invocation paths); document all 24 `RTM_*` knobs
in a reference table (test `CLAUDE_PLUGIN_OPTION_*` visibility to skill Bash first; migrate to
`userConfig` only if visible). Decline `workflows/` and `bin/` with one-line verdicts. Bump to
**1.14.0**.
**Gate 6:** full suite green vs Phase-0 baseline (permitted deltas: the new pins only);
`plugin.json` parses; CI demonstrably triggers on a plugin-touching change; final diff ⊆ the
union of all scope locks.

## 7. Deferred to the bench (not yours — flag for the operator at the end)

The `PF_PPF` probe needs calibration on real PAFF (none mintable in a sandbox); the true-PAFF
end-to-end run awaits the next class member, with plan §0 as the checklist; the ref-frames
notice re-test **[frozen]**; the Route C gate-(a) sub-question **[frozen]**; gate-(g)-style
baseline for seam-check (design wanted, Q7).

## 8. Final report format

Per-phase table (phase, files touched, gate result, one line); the deferred-bench list above;
any STOP conditions hit and how resolved; `git diff --stat`. No prose beyond that.
