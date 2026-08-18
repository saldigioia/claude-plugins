# Reorder-DTS Editing Plan — the 2023 VMA class, generalized

**Status (2026-08-16):** Phase 1 executed via `WO-1.14-EXECUTION-PROMPT.md`, plus the F1–F10
review round (suite 259/0). Phases 2–6 pending. Line references below describe v1.13.0 and
have drifted — locate by content.

**Inputs:** `2023VMA.md` (incident report, 2026-08-15), `vma-prompt.md` (work order, incl. the
units correction that supersedes the report's root cause), `fixdts.py` (reference repair, PyAV,
~90 lines), and the v1.13.0 tree. Every code claim below was re-verified against v1.13.0 at the
line level on 2026-08-15; claims resting only on the report are marked **[frozen]** (source
`feed.mkv` deleted — testimony, not measurement). Bench caveat: line-level verification ran
against the tree itself; the two runtime probes in this pass used sandbox ffprobe **4.4.2**, not
the 9.0.1 bench — re-run flagged items on the real bench before landing.

**Method (per QTFF-AUDIT-PLAN discipline):** every item states a falsifiable claim, cites
file:line evidence, classifies per the incident taxonomy — **(a)** wrong measurement, **(b)**
right measurement/wrong inference, **(c)** right verdict/no route, **(d)** documentation drift —
and carries change, blast radius, regression pin, adversarial check, and exit-contract impact.

**Governing principle (verbatim from the work order, adopted):** *never weaken the evidence; fix
the inference and the routing that sit on top of it.* The hard stop, the source-baseline
recount, and gate (a) are load-bearing and untouched by every item below.

---

## 0. Corrections to the incident report (apply while reading it)

The report is a primary source with a wrong root cause. Verified standing of its contested
claims, per the work order's instruction to validate rather than inherit:

| Report claim | Standing after verification |
| :--- | :--- |
| "SPS understates reorder depth (declared 2, true 4); non-conforming SPS" | **Superseded (units error).** 4 coded pictures = 2 frames on a field-coded stream; `max_num_reorder_frames=2` conforms. Root cause: ffmpeg applies frame-unit `has_b_frames` as a *packet* delay on field packets — short by exactly 2×. Corroborated by the frozen numbers: DTS regressions 1.98–3.06 **field** durations; mean coded-pic duration 266.93 ticks = the 59.94 field |
| R6: "rate detection off (59.4380 vs 59.94) … missed the 60000/1001 mapping" | **PARTIAL — causal chain corrected.** The understatement is real (`pf_coded_rate`, `lib-paff.sh:49-57`: min/max span over a 240-pkt coded-order window; the pyramid's presentation lead stretches the span → ≈59.44). But the map (`pf_suggest_field_rate`, `lib-paff.sh:125-133`) accepts 58–62 → 60000/1001, so 59.438 would have mapped fine. The map was never consulted, because `pf_detect` only calls it when `pf_paff=yes` and the ratio test failed (DF-3). R6 is off the critical path; the ratio denominator is on it |
| R8: "verify.sh computes inherited (REVIEW) per gate and returns overall FAIL anyway" | **NOT REPRODUCED as stated.** Gates (c)/(e) inherited classifications set REVIEW only and never force FAIL (`verify.sh:291-294, 372-375`). The incident's `>> FAIL` came from gate (g) alone — an unwaivable `other_failed=1` false positive (`verify.sh:566,579`). Aggregation is sound; the defect is (g)'s missing scope/baseline (DF-7). R8's fix collapses into R5's |
| "pairfill refused because it repairs half-timestamped MPEG-TS — a class this source is not" | **Corrected.** pairfill has **no** fraction gate anywhere; `untimestamped fraction=0.000 (half_ts=no)` is an informational echo (`pairfill-paff.sh:80`). The exit 3 came from the *first* refusal gate, the rate map (`:83-86`), fed `PF_FIELD_RATE=unknown` by the ratio miss. R6's report framing was wrong twice, in compensating directions |
| "280 genuine dropped frames, 4,580 ms" | Seconds right; **280 dropped fields ≈ 140 frames**. Any repaired-gap metric must expect field cadence |
| "`number of reference frames (0+5) exceeds max (4)` = the non-conforming SPS speaking" | **Attribution struck.** `4 Ref Frames` is a frame-unit cap; a field-coded DPB holds 8 reference fields. Plausibly a *third* field/frame unit artifact in ffmpeg's checker, not damage — re-test on the next class member (open question Q4) **[frozen]** |
| R2 pre-roll `frame_dur` | Must be the **coded-picture** duration. `fixdts.py:59-61` already derives it as the modal sorted-PTS delta — correct by construction; the plan keeps that derivation |

The exit-3 code itself is contract-clean (`lib-exit.sh:38-52`, `pairfill-paff.sh:54`,
suite-pinned in `14-exit-codes.sh:67`) — no defect there.

---

## 1. Defect register

Verified against v1.13.0. Severity reflects operator cost on the primary input class
(broadcast captures; every 1080i North-American feed muxed to MKV is in-class).

| ID | Defect | Where | Class | Sev | Phase |
| :-- | :--- | :--- | :-: | :-: | :-: |
| DF-1 | No rung for PTS-complete, DTS-absent, reordered sources; the correct lossless repair is inexpressible in the ladder | (absence) | (c) | **critical** | 3 |
| DF-2 | Every routing surface sends "reorder present" to pairfill unguarded: `REPAIR` chosen by `HALF_TS ∨ REORDER` before any verdict | `diagnose.sh:44,216-219`; also `verify.sh:378,703`, `probe.sh:195,405-408`, `ts-health.sh:169-170,184-185`, `SKILL.md:104-108,164-165,233,235,419,436-439`, `timeline-repair.md:75,133,149-159,199` | (b) | **critical** | 4 |
| DF-3 | PAFF detector ratio test divides by the **container's** declared fps; when the container declares the field rate (mkvmerge one-block-per-field) the ratio is ~1 → `paff=no`, `PF_FIELD_RATE=unknown` → pairfill's first gate exits 3. `field_order=tt` is captured and never consulted | `lib-paff.sh:164-180` (decisive-test design admitted at `:9-11`); `pairfill-paff.sh:83-86` | (a) | **critical** | 1 |
| DF-4 | `disc_scan` forward-gap census: adjacent `dts_time` deltas in coded order; on a DTS-less container that column is ffmpeg's reconstruction — *the metric measures the bug with the bug* (1,000× overstatement **[frozen]**); N/A rows skipped so missing-DTS holes manufacture phantom gaps; inflated `DISC_MISSING` feeds four unguarded consumers **as tolerance** (verify (f) budget `verify.sh:437-441`, `--silence` budget `:624-625`, `backhaul_gate` `lib-paff.sh:440-441`, diagnose step 4) — silently *widening* acceptance | `lib-paff.sh:207-228`; consumers as cited | (a) amplified | **high** | 1 |
| DF-5 | `pf_reorder_scan` derives `PF_PTSNEDTS`/`PF_MAXOFF_TICKS` from demuxer `dts` — reconstructed on MKV, so the scanner's reorder evidence is partly the artifact under investigation (only `PF_BACKPTS` is container-real). The report's "max offset 134 ticks" is this artifact | `lib-paff.sh:69-83` | (a) | high | 1 |
| DF-6 | `mux_census` is count-equality + exact ordered per-slot identity (`if(NF!=n) exit 1`); written ⊃ planned FAILs with the inverted message "a stream the plan mapped is missing"; **any chaptered input fails** (movenc synthesizes the chapter text track the plan never counted — behavior the repo itself records at `known-limits.md:322-326`). 8 call sites | `lib-mux.sh:78-99`; call sites `remux.sh:440`, `dual-track.sh:213`, `pairfill-paff.sh:275`, `rebuild-paff.sh:155`, `resync.sh:180`, `trim-to-idr.sh:219`, `metadata.sh:72`, `rung4.sh:112` | (b) | **high** | 2 |
| DF-7 | Gate (g) counts **every stderr line of the whole invocation** per audio track (`grep -c .`, no `-vn`, no stream scoping, no source baseline, no inherited path — unlike (c)/(e)) and sets unwaivable `other_failed=1`. Deterministic open-time video notices (measured: 260 `-v error` lines opening `late-sps.ts`) are charged to each audio track. Reclassifies the work order's starting hypothesis: R5 is **(a) wrong measurement** — the number is not "audio decode errors" | `verify.sh:517-526,579-581` | (a) | **high** | 1 |
| DF-8 | Generic NON-MONOTONIC/DUPLICATE-DTS verdict routes **any codec** to H.264-only rungs: pairfill exits 3 on `PF_CODEC != h264` (`pairfill-paff.sh:78`); rebuild-paff dies raw in `-map 0:v:0 -f h264` extraction (`rebuild-paff.sh:88-92`). An mpeg2video `.mpg`/`.vob` with DTS rot — a declared primary input class — has no timeline-repair route at all. Also reached via `diagnose.sh:261-262,265` fallbacks and `ts-health.sh:184-186` ("lossless either way" — false for non-H.264) | `diagnose.sh:216-219` + cited | (c) | **high** | 3–4 |
| DF-9 | `pf_coded_rate` understated by the pyramid's presentation lead (≈59.44 for true 59.94) | `lib-paff.sh:49-57` | (a) | low | 1 |
| DF-10 | `mux_confessions` greps the whole mux log: an audio/subtitle DTS nudge (ms-quantized MKV audio — a class verify (e) itself calls harness-artifact) hard-stops the build as invented *video* timing | `lib-paff.sh:90-93`; callers `remux.sh:426`, `dual-track.sh:153`, `pairfill-paff.sh:218`; rebuild-paff's deliberate self-exemption `:128-133` confirms scope-sensitivity | (b) | medium | 2 |
| DF-11 | diagnose step (1) decode-damage census: `-map 0:v:0` decode, but `find_stream_info` under the raised probe window part-decodes **all** streams first; audio errors land in the count differenced against a video-packet pre-roll count | `diagnose.sh:90-92` | (a) | medium | 1 |
| DF-12 | Lossless-MKV-copy advice at 8+ sites with no warning that the copy itself corrupts this class (matroska muxer clamps identically — 449 duplicate PTS in 3,597 packets **[frozen]**); `diagnose.sh:211` affirmatively asserts the copy "survives honestly" | `mov.sh:267-274`, `lib-paff.sh:330-336,389-392`, `diagnose.sh:210-212`, `ts-health.sh:180`, `SKILL.md:169,240,241,511`, `timeline-repair.md:82` | (d) | medium | 5 |
| DF-13 | No `known-limits.md` entry for the class (grep-verified: only the benign B-frame-head-N/A entry at `:161-173`) | `references/known-limits.md` | (d) | medium | 5 |
| DF-14 | `--signaling` asserts `hvc1` on any output when the source is HEVC — a supported MKV cross-check output has no QTFF tag → false DRIFT | `verify.sh:743-745` | (b) | low | 2 |
| DF-15 | pairfill's whole-file precondition (`PP_MAXRUN>1`) can refuse the file its own verdict routed in, terminating in "diagnose by hand" — a loop, not a route | `pairfill-paff.sh:121-123` | (c) | low | 4 |
| DF-16 | seam-check counts unbaselined open-time stderr (same scope class as DF-7); a noisy-but-healthy source makes every seam "bad" | `seam-check.sh:57` | (a) | low | deferred → open Q7 |
| DF-17 | Packaging conformance: space-delimited `allowed-tools` in both SKILL.md files; undefined `${CLAUDE_SKILL_DIR}` (`skills/mov/SKILL.md:24`); ~46 bare `scripts/*.sh` references in the main SKILL.md; 6,394-char `plugin.json` description carrying the changelog; no `$schema`, no `CHANGELOG.md`; shipped `.bak` and `.DS_Store` strays; CI never runs `claude plugin validate` **and is dead-lettered in the monorepo layout** (workflow only executes when the plugin is repo root); 24 undocumented `RTM_*` knobs | agent sweep, Part B | (d)/(b) | medium | 6 |

**What is *not* defective (verified, recorded so nobody "fixes" it):** the hard stop; gate (a);
gate (d)'s backward-DTS-on-output (coded-order-correct); gate (e)'s keyframe metric (the one
delta metric that sorts by PTS first — `verify.sh:310`); the (c)/(e) inherited classifiers;
exit-code 3's documentation; `pf_reorder_scan`'s `PF_BACKPTS` (backward PTS in coded order is
the *detector* of reorder — correct use); diagnose's DISCONTINUOUS→resync and MID-GOP→trim
routes (refusals carry honest onward routes).

---

## 2. The organizing principle, tested (work-order decision #2)

The proposed definition — *a gate must distinguish "the output is wrong" from "the output is not
what I predicted"* — was tested against every false verdict in the register. It covers DF-6,
DF-14, and the census message inversion. It does **not** cover DF-7/DF-10/DF-11/DF-16, which
share a different shape: *the measurement's scope is wider than the judged object* (whole-open
stderr judged as one track; whole-log grep judged as video timing). Nor DF-3/DF-4/DF-5: *the
measured quantity is not the quantity the gate names* (container fps ≠ frame rate; reconstructed
DTS ≠ carried DTS).

**Adopted, amended to three tests** — every gate in this codebase must answer:
1. Is the number the thing I say it is? (measurement identity — kills DF-3/4/5/9/11)
2. Is its scope exactly the judged object? (scope discipline — kills DF-7/10/11/16)
3. Does divergence from my prediction prove damage, or just surprise? (prediction humility —
   kills DF-6/14)

These three are the review checklist for every future gate, and belong verbatim in
`verification-safety.md` (Phase 5).

---

## 3. Phased plan

Sequenced by dependency and risk: measurement fixes first (everything downstream reads them),
then inference/gates, then the rung, then routing (which needs the rung to route *to*), then
doctrine, then packaging. R-numbers map: R1→4.1, R2→3.1, R3→1.4, R4→2.1, R5→1.6, R6→1.2/1.5,
R7→5.2, R8→resolved by 1.6, R9→5.1.

### Phase 1 — Measure right (class (a) items; no routing or verdict changes)

**1.1 Unit-aware reorder-depth detection** *(the highest value-per-line change; no new
dependency)*
- **Claim.** No scan measures true reorder depth; nothing compares it to the declared depth in
  matching units; a three-hour mystery was one awk away from a printed line.
- **Evidence.** `pf_reorder_scan` (`lib-paff.sh:69-83`) emits reorder *presence* only;
  `has_b_frames` is exposed by ffprobe (bench-verified: 2 on `h264_422.ts`; **1 amid a 260-line
  error flood on `late-sps.ts`** — so "declared" can be garbage).
- **Change.** Extend `pf_reorder_scan` (never a second scanner): from the existing PTS column
  compute `D = max(i − rank(pts[i]))` (pure awk, needs zero DTS). Emit additive fields:
  `PF_DEPTH_PICS=D`, `PF_DECL_DEPTH=has_b_frames|unknown`, `PF_PPF=1|2|unknown` (coded pictures
  per frame), `PF_DEPTH_CLASS=none|match-frame|match-field|understated|unknown`, and
  `PF_DTS_SOURCE=carried|reconstructed` (keyed on container: matroska stores no DTS, ever).
  The classification is the unit-aware split from the work order: `expected = has_b_frames ×
  ppf`; `D == expected ∧ ppf=2` → **match-field, the 2023 VMA class** (SPS correct, ffmpeg's
  packet delay short by the field factor); `D > expected` → genuinely understated (rarer,
  different root cause); `D ≤ has_b_frames` → none. **Unknown ≠ zero**: an unparseable SPS
  (late-sps class) yields `PF_DEPTH_CLASS=unknown`, which must never route as understated.
- **`PF_PPF` design point (resolve on bench, Q3):** timestamps cannot distinguish 59.94p from
  59.94-fields (that ambiguity *is* DF-3), so `ppf` needs an essence probe. Candidate: bounded
  demux-count vs decode-count (PAFF: decoded frames ≈ packets/2); `field_order` stays
  corroborative only — MBAFF and frame-coded interlace also set it (work-order caveat honored).
- **Window.** Keep the 3000-packet window for the advisory tier (a sample can understate D —
  announce that); the Phase-3 rung recomputes D whole-file before repairing (cost: one PTS dump
  pass, ~minutes on 50 GB; acceptable inside a repair, not inside every probe). Reconcile the
  3000 vs 5000 windows (diagnose step 3) into one named constant while there.
- **Blast radius.** `lib-paff.sh`; consumers gain fields only (additive, Ground Rule 4):
  `probe.sh` kv/JSON (today carries only `reorder` — add depth fields), `diagnose.sh`,
  `rebuild-paff.sh` message, `auto.sh`, `mov.sh:460`.
- **Regression pin.** `PF_PKT_TICKS_FILE` injection (hook exists; `regression.sh:473-480`
  already uses it): synthesize the exact field-coded pyramid tick shape from the report's coded
  order `(0,17)(133,150)(67,83)(33,50)(100,117)` → must classify `match-field`, D=4, ppf=2;
  a progressive B-pyramid shape → `match-frame`; a late-sps shape → `unknown`.
- **Adversarial check.** The file that must NOT fire: healthy 1080i with correct SPS — but on
  field-coded streams that file *is* `match-field` by definition; firing is correct, the
  *verdict text* must say "SPS conforms; ffmpeg's reconstruction is short by the field factor."
  The constructible wrong-fire is MBAFF misread as ppf=2 → depth halved → false `understated`;
  pin with an MBAFF fixture if x264 can mint one (`--tff` MBAFF is supported; PAFF is not).
- **Exit contract.** None (fields only).

**1.2 PAFF detector denominator (DF-3)**
- **Claim.** `pf_ratio = coded_rate / container_fps` calls a field-rate-declaring container
  progressive (`paff=no` on a *Separated fields* capture) and starves pairfill's rate map.
- **Evidence.** `lib-paff.sh:164-180`; incident chain verified (§0).
- **Change.** Test the ratio against **both** hypotheses (container fps as frame rate → expect
  ≈2; container fps as field rate → expect ≈1 with `ppf=2` evidence from 1.1); when the 1.1
  essence probe says field-coded, ≈1 + fps≈59.94/50 selects PAFF with `PF_FIELD_RATE` = the
  container fps itself. `field_order` stays corroborative. Announce which hypothesis won.
- **Blast radius.** `pf_detect` consumers: `probe.sh` (`PF_PAFF`, `PR_REC_RUNG`),
  `pairfill-paff.sh` (rate gate now satisfiable for this class — though routing will send the
  class to the new rung instead), `mov.sh` pre-flight print (`paff=no` was the incident's first
  visible symptom).
- **Pin.** Ticks-file injection of both shapes; plus the existing `51-native-matrix`/PAFF tests
  must not regress.
- **Adversarial.** True 59.94p progressive sports feed: ratio ≈1 under hypothesis 2 as well —
  the discriminator must be the essence probe, never the ratio alone; if `ppf=unknown`, PAFF
  stays `no` and the announcement says why (unknown ≠ yes).
- **Exit contract.** None.

**1.3 `pf_reorder_scan` DTS provenance (DF-5)**
- **Claim.** `PF_PTSNEDTS`/`PF_MAXOFF_TICKS` on a DTS-less container measure ffmpeg's
  reconstruction and are presented as source properties.
- **Change.** Emit `PF_DTS_SOURCE=carried|reconstructed` (from 1.1); when `reconstructed`,
  every printer of these fields (diagnose `:157-158`, probe `:399`, rebuild-paff `:56`) appends
  "(demuxer-reconstructed — not a source property)". Numbers stay visible (never weaken the
  evidence); only the attribution is corrected.
- **Pin.** Ticks-file case asserting the annotation appears for matroska input.
  **Adversarial:** none constructible that should now pass — this is annotation only.
  **Exit contract:** none.

**1.4 `disc_scan` presentation-order gap census (DF-4, R3)**
- **Claim.** Forward gaps are measured on adjacent coded-order (possibly reconstructed) DTS;
  a reorder pyramid inflates dropped-time ~1,000× **[frozen]**; N/A-skips manufacture phantom
  gaps; the inflated budget silently widens verify (f) and `--silence` acceptance.
- **Change.** Add a presentation-order arm to `disc_scan`: sort PTS, then delta (the same
  `sort -n` discipline gate (e) already uses at `verify.sh:310`); emit additive
  `DISC_P_COUNT/DISC_P_MISSING` alongside the untouched coded-order fields. Consumers that use
  the number as a **timeline claim or budget** switch to the presentation fields: diagnose step
  4's "dropped ~Ns", verify (f) `gap_budget`, `--silence` budget, `backhaul_gate`. The DTS
  rot counters (`DISC_BACK/DUP`) stay coded-order (that is their correct order) but inherit the
  1.3 provenance annotation. Port ts-health's `V_NADTS` guard (`ts-health.sh:188-193`) to the
  four unguarded consumers; apply it to ts-health's own backhaul finding (`:177-182`), which
  reports raw `V_GAPS` even when N/A>0.
- **Blast radius.** `lib-paff.sh`, `diagnose.sh`, `verify.sh` (f) and `--silence`,
  `ts-health.sh`; machine lines additive.
- **Pin.** Ticks-file with a reordered window containing exactly one real 2-frame gap: coded
  arm must overcount, presentation arm must report exactly 1; budget consumers must read the
  presentation number. **Adversarial (the widening direction):** a genuinely gappy source must
  still widen (f)'s tolerance by its *real* loss — fixture `gap.ts` already pins the legitimate
  budget; assert unchanged.
- **Exit contract.** None. **Note:** this narrows tolerances (phantom budgets vanish) — a real
  desync formerly hidden inside a phantom budget will now correctly FAIL; that is the fix
  working, and `qtff-claims.md` should record the direction of the change.

**1.5 `pf_coded_rate` lead bias (DF-9, low)**
- **Change.** Compute the window rate from the modal sorted-PTS delta (already computed for
  cadence elsewhere) instead of `(n−1)/span`; the pyramid lead then cancels. Announce old vs
  new on first landing. **Pin:** ticks-file: pyramid window must read 59.94 ± ε, not 59.44.
  Low risk; the 58–62 map band already tolerated the bias (§0).

**1.6 Gate (g) scope + baseline (DF-7; absorbs R5 and R8)**
- **Claim.** One deterministic open-time video notice FAILs every audio track, unwaivably, on a
  file whose audio decodes cleanly — measured shape confirmed (260 open-time lines on a fixture
  at `-v error`).
- **Change.** Three layers, keeping the measurement visible: add `-vn` (excludes video decode
  from the run; open-time parse lines may remain); **source-baseline subtraction** exactly as
  gates (c)/(e) do — run the identical command on `$SRC`, count, difference; and an inherited
  classification path: `delta ≤ 0` → "inherited/open-time noise — REVIEW", never
  `other_failed`. A genuine audio-decode delta (>0 net lines) keeps today's FAIL + `other_failed`.
- **Blast radius.** `verify.sh` gate (g) only; the R8 concern dissolves (aggregation verified
  sound, §0). Machine line: extend, never rename.
- **Pin.** Fixture pairing `late-sps.ts`-class video noise with clean audio: v1.13.0 FAILs it,
  the fix must REVIEW it with the delta printed; plus a genuinely-broken-audio fixture
  (truncated MP2 mid-window) that must still FAIL. The pair pins both directions.
- **Adversarial.** A file whose *source* audio is as broken as the output's (delta 0 on real
  damage) now reads inherited — REVIEW, not FAIL. That is correct by this plugin's own
  inherited-damage doctrine (remux cannot fix source damage) and is exactly how (c)/(e) already
  behave; state it in the gate's comment.
- **Exit contract.** A file class moves FAIL→REVIEW (exit 1→10). Downstream: `batch.sh` verdict
  rows and `auto.sh` handle 10 today; call the change out in the changelog as a
  verdict-semantics change on false-positive shapes only.

**1.7 diagnose step (1) census scope (DF-11)**
- **Change.** Baseline the census the same way: the count that feeds "decode-damage lines"
  subtracts a `-map`-matched probe-only pass, or filters to video-decoder message classes
  (`[h264 @`, `[hevc @`, `[mpeg2video @` tags scoped to v:0). Keep raw count printed.
  **Pin:** fixture with audio-borne probe errors + clean video → census must read 0 video
  damage. **Class note:** same shape as DF-7 — scope discipline (test 2 of §2).

### Phase 2 — Judge right (class (b) gates)

**2.1 `mux_census` multiset containment + expected-surplus classes (DF-6, R4)**
- **Claim.** Count-equality + ordered identity reports a legitimate surplus as "a stream the
  plan mapped is missing"; any chaptered input exits 1 with the artifact stranded at `.part`.
- **Change.** Three verdict classes, replacing binary match: **missing/mutated** (planned slot
  absent or codec differs) → FAIL, today's message, correct direction; **expected surplus** —
  a data-class track movenc synthesizes from metadata the plan carries (chapter `text`/
  `bin_data` when the input has chapters; `tmcd` under `-write_tmcd`) → PASS, announced
  ("census: +1 chapter text track (movenc-synthesized, expected)"); **unexpected surplus** →
  REVIEW, named honestly as surplus, never as missing. Comparison becomes per-codec multiset
  containment planned ⊆ written, plus the surplus classifier. `RMX_CENSUS` gains additive
  `surplus=none|chapters|unexpected:N`.
- **Blast radius.** All 8 call sites inherit silently (plans unchanged); `metadata.sh`
  `--keep-chapters` and `rung4.sh`'s count-only census get the same classifier; the
  `45-census-partnames.sh` pin extends rather than changes.
- **Pin.** Chaptered fixture (`make-fixtures.sh` can mint MKV chapters via
  `-metadata`/ffmetadata) through `remux.sh`: v1.13.0 FAILs census; fixed build PASSes with the
  announced surplus; a build where a planned audio track is genuinely dropped must still FAIL
  (both directions pinned in one test).
- **Adversarial.** The file that must NOT pass: written ⊃ planned where the surplus is a
  *duplicated media* stream (a mapping bug, not muxer metadata) — the classifier keys on codec
  class `data`/`text` + chapter presence in the plan's input, so a surplus `h264` lands
  REVIEW, not PASS. State in the comment that PASS-surplus is data-class-only, ever.
- **Exit contract.** Chaptered-input builds move 1→0; unexpected-surplus moves 1→10. Both are
  false-verdict corrections; changelog-called.

**2.2 `mux_confessions` stream scoping (DF-10)**
- **Change.** Split the grep by ffmpeg's own stream tags (`[vost#0:0`, `[aost#`): video-stream
  confessions keep the hard stop verbatim; audio/subtitle-only nudges → announced count +
  REVIEW ("audio DTS nudges (ms-quantization class, verify (e) doctrine) — not video timing
  invention"). Zero-confession behavior unchanged.
- **Pin.** ms-quantized-audio MKV fixture (mintable: MKV's 1/1000 timebase + 48 kHz AAC):
  v1.13.0 hard-stops; fixed build completes with the announced REVIEW; injected `vost`
  confession (the `RTM_MUX_LOG_APPEND` hook exists) must still hard-stop.
  **Adversarial:** a genuinely broken *audio* timeline now passes the video hard stop — but it
  was never this gate's object; verify (f)/(g) own audio timelines, and the REVIEW says where
  to look. **Exit contract:** a class of builds moves hard-stop→complete-with-REVIEW; called
  out.

**2.3 `--signaling` non-QTFF awareness (DF-14).** Gate the `hvc1` assertion on the `g_qtff`
container test gate (g) already computes (`verify.sh:498-499` pattern). Pin with an MKV
cross-check output. Trivial; no contract impact.

**2.4 pairfill loop terminus (DF-15).** The `PP_MAXRUN>1` refusal names the Phase-3 rung and
the class signature instead of "diagnose by hand". Text-only; lands with Phase 4.

### Phase 3 — The missing rung (DF-1/DF-8, R2; work-order decision #1)

**3.1 `derive-dts.sh` — Rung 3-DERIVE: whole-stream DTS derivation for PTS-complete,
DTS-absent-or-reconstructed, reordered sources**
- **Claim.** The correct lossless repair — `DTS[i] = (i−D)-th smallest PTS` — is inexpressible
  by any rung; `setts` cannot say it (measured: no whole-stream ordering primitive) and
  `h264_metadata` has no reorder option (measured). The reference implementation exists
  (`fixdts.py`, verified on the real source: PTS preserved 3600/3600, DTS monotonic ≤ PTS,
  video MD5 identical).
- **Route decision — Route A (PyAV), recommended.** Grounds: proven on the incident; touches
  zero bitstream bytes; optional gated dependencies are an established house pattern (Bento4
  `mp4dump` via doctor.sh); and `${CLAUDE_PLUGIN_DATA}` is the *documented* home for a
  plugin-owned venv ("installed dependencies (node_modules, venv)"), persistent across updates —
  never under `${CLAUDE_PLUGIN_ROOT}`, which changes on update. **Route B** (post-hoc
  `stts`/`ctts` surgery) — declined for now: purest in principle (MOV decode timing *is*
  container metadata) but requires an edit-list-aware atom rewriter against a multi-GB `moov`
  while still needing the same whole-file PTS pass; record as the future no-Python alternative.
  **Route C** (SPS correction) — **rejected as a default**, adopting the work order's position
  with its strongest ground first: *there is no defect to correct* — the SPS conforms (§0);
  rewriting it would make a conforming stream non-conforming. The remaining grounds hold
  independently: DTS derivation is not a modification but *the remux itself* (Matroska carries
  no DTS; crossing into MOV requires synthesizing it — A/B replace a bad derivation with a good
  one and modify zero input bytes); Route C fails self-contained reversibility; no stock tool
  performs it; and its honest name is "parameter-set correction," never to be laundered as
  remux. If interop ever genuinely requires a corrected-SPS file, it is a **declared
  derivative** beside the archival master, `waiver.sh`/`lib-attest.sh`-attested, original value
  in the sidecar — never automatic, never in place.
- **Change.** New `scripts/derive-dts.sh`: bash driver + vendored `derive-dts.py` (hardened
  `fixdts.py`: same derivation, same modal-coded-pic-duration pre-roll — the near-zero-durations
  trap the report hit is already solved there — plus multi-audio/subtitle stream handling and a
  `--limit`-style bench mode). **Preconditions** (all cheap, announced): zero N/A PTS; zero
  duplicate PTS (the script's existing refusal); `PF_DEPTH_CLASS ∈ {match-field, understated}`
  or operator `--force` with announcement; whole-file D recomputed before writing (window D is
  advisory only, 1.1). **Codec-agnostic by construction** (PyAV copies packets byte-for-byte) —
  this closes DF-8's orphan for mpeg2video/HEVC too; the *unit-aware* half of detection stays
  H.264-PAFF-specific and says so. **Chapters:** PyAV cannot write them (incident deviation 3);
  the rung performs the `-map_chapters` re-attach pass itself — repair → chapters → gates, so
  the judged artifact is the deliverable. **Output gates:** PTS multiset identity vs source;
  DTS strictly monotonic, ≤ PTS everywhere; verify gate (a) packet-hash identity; `mux_census`
  (which, post-2.1, tolerates the chapter track it just re-attached); `mux_confessions` on its
  own final mux (0 expected — the derivation makes invention impossible by construction).
  **Dependency gating:** `doctor.sh` reports the `${CLAUDE_PLUGIN_DATA}` venv; absent → the
  rung prints the one-line bootstrap (`python3 -m venv … && pip install av`) and the manual
  recipe, exits 10 REVIEW (advisory-before-automatic; never auto-installs).
- **Blast radius.** New script + vendored python; `doctor.sh`; `SKILL.md` ladder (new Rung
  3-DERIVE row beside 3-PAIR/3-REBUILD); `timeline-repair.md`; `probe.sh` `PR_REC_RUNG/CMD`;
  `diagnose.sh`/`ts-health.sh` routing (Phase 4); `regression.sh` + fixtures; exit-contract
  table in SKILL.md.
- **Regression pin — the three-layer strategy** (the class cannot be fixtured by cutting: a
  `-c copy` cut is itself corrupted by the bug **[frozen]**, and libx264 cannot mint PAFF —
  `regression.sh:10-16,686-687` already records this):
  1. **Detection math** (no encoder needed): `PF_PKT_TICKS_FILE` injection of the field-coded
     pyramid shape — pins unit-aware classification (1.1) exactly.
  2. **The rung end-to-end** (encoder-real): libx264 `b-pyramid` progressive B-depth-2 →
     MKV (mintable today; `regression.sh:689-690` proves the recipe). MKV stores no DTS, so
     the fixture is genuinely PTS-only; the derivation is unit-agnostic, so the rung's whole
     pipeline — depth from data, derivation, pre-roll spacing, chapters (add ffmetadata
     chapters to the fixture), census, gate (a), monotonicity — pins on it end-to-end.
     `has_b_frames` is *correct* on this fixture, which also pins the guard: `match-frame`
     must NOT auto-route to the rung (adversarial half).
  3. **True-PAFF integration** — honestly unpinnable in a sandbox; recorded per house
     SYNTHESIS LIMIT style: operator-verified on the next class member, with the §0 unit
     corrections as the checklist.
- **Adversarial check.** Files that must not pass through the rung: duplicate-PTS source
  (refused — derivation assumes unique display timeline; pin with a dup-PTS ticks file);
  `PF_DEPTH_CLASS=unknown` (late-sps class — must refuse without `--force`, or a healthy
  file with an unparseable SPS gets restamped); a genuinely half-timestamped PAFF capture
  (belongs to pairfill; `PF_NOPTS_FRAC>0` precondition-refuses with the route named). Depth
  overestimation is safe by construction (`D ≥ actual ⇒ DTS ≤ PTS` — sorted ⇒ monotonic);
  state the proof in the header as fixdts.py does.
- **Exit contract.** New script adopts the standard contract. Signature mismatch: **decision
  Q1** — sibling rungs use documented pre-contract 3; recommend 3 for family consistency
  (suite-pinned in `14-exit-codes.sh` alongside pairfill/rebuild), documented in SKILL.md's
  exceptions list. No existing code's meaning changes.

### Phase 4 — Route right (DF-2, DF-8, DF-15; R1)

**4.1 diagnose.sh routing by measured profile**
- **Claim.** `REPAIR` is chosen at `diagnose.sh:44` by `HALF_TS ∨ REORDER` before any evidence
  is weighed; the NON-MONOTONIC verdict (`:216-219`) then routes fully-timestamped reordered
  streams into pairfill's exit 3 — with `PF_NOPTS_FRAC=0.000` *in scope and ignored*.
- **Change.** Route by the profile the measurements already establish:
  `PF_NOPTS_FRAC > 0 ∧ PAFF` → pairfill (unchanged); `PF_NOPTS_FRAC == 0 ∧ PF_REORDER=yes`
  → **derive-dts.sh** (whether the container's DTS is absent, reconstructed, or carried-but-
  rotten — the derivation discards DTS either way); no-reorder missing-TS → rebuild (unchanged);
  **non-H.264 with timeline rot** → derive-dts.sh (codec-agnostic), closing DF-8; pairfill/
  rebuild recommendations gain their own codec guard in the verdict text. The verdict block
  prints which measurements drove the route (the anti-DF-2 discipline: a route is a conclusion,
  and conclusions cite evidence).
- **Blast radius — every routing surface from the DF-2 register:** `verify.sh:378,703`,
  `probe.sh:195,405-408` (`PR_REC_RUNG/CMD` — additive value `3-derive`), `ts-health.sh:169-170,
  184-186` (and strike "lossless either way"), `rebuild-paff.sh:63-67` refusal text,
  `trim-to-idr.sh:113`, `remux.sh:433`, `auto.sh:122,215` escalation (auto.sh's ladder gains
  the rung between 3-PAIR and Rung 4), `SKILL.md` rows, `timeline-repair.md` (Phase 5 carries
  the prose).
- **Pin.** Extend `23-escalation.sh`: the layer-2 fixture through `diagnose.sh` must name
  `derive-dts.sh` and must NOT name pairfill; a synthesized half-ts ticks profile must still
  name pairfill. **Adversarial:** the misroute that must not survive — `PF_DEPTH_CLASS=unknown`
  with reorder present must route to *diagnosis* (announce the unparseable SPS), not to the
  rung. **Exit contract:** none (text/routing only).

**4.2 Verify-side routing text** (`verify.sh:378,703`): name the profile split instead of
pairfill-unconditionally. Text-only; pinned by grep in the 4.1 test.

### Phase 5 — Write it down (DF-12, DF-13; R7, R9; qtff-claims discipline)

- **5.1 `known-limits.md` entry** — corrected heading: **"Field-coded (PAFF) capture in a
  DTS-less container: ffmpeg's frame-unit DTS reconstruction"** (NOT the report's "SPS
  understates" — §0). Carries: the signature (mkvmerge + `Scan type, store method: Separated
  fields` + container fps = field rate + `Non-monotonic DTS` only, zero `pts has no value`,
  regressions clustered ≈2–3 field durations, count ≈ 25 % — the deepest picture of each
  4-field group); the unit-aware detection line that names it in seconds (1.1); the
  cross-container warning (a `-c copy` to Matroska corrupts identically **[frozen]**); the
  derive-dts route; the ref-frames-notice open question (Q4). Dated, bench-stamped,
  `documented-not-measured` where frozen.
- **5.2 Qualify the lossless-copy advice at all 8 DF-12 sites** — the copy is safe *except* for
  the DTS-less reordered class, where the matroska muxer clamps exactly as movenc does; correct
  `diagnose.sh:211`'s "survives honestly" assertion; the existing "then ts-health the copy"
  follow-up is promoted from suggestion to the stated *reason* (it is the check that catches
  this). `SKILL.md:169,240,241,511`, `timeline-repair.md:82`, `lib-paff.sh` route strings.
- **5.3 `timeline-repair.md`** — new class section (signature, detection fields, rung,
  worked incident numbers); rewrite the "pairfill is preferred whenever real PTS survives on a
  reordered stream" doctrine (`:149-159`) — that sentence is DF-2 in prose; taxonomy table
  gains the 3-DERIVE row.
- **5.4 `qtff-claims.md`** — record the reversals with dates, per the registry's own charter:
  the report's root cause superseded by the units correction; R6's causal chain corrected;
  R8's premise corrected; DF-4's budget-narrowing direction; the §2 three-test checklist
  cross-referenced into `verification-safety.md`.
- **5.5 `tests/README.md`** — the three-layer pin strategy and the honest true-PAFF residual.

### Phase 6 — Packaging conformance (DF-17; ranked below correctness, own checks per item —
"validate passes" is admissible evidence for nothing here)

| Item | Change | Check (CI-pinned) |
| :--- | :--- | :--- |
| 6.1 `allowed-tools` space-delimited in both SKILL.md files | `Bash Read Write` → `Bash, Read, Write`; first **test** what the space form actually resolved to (work-order request) and record it in the commit message | `grep -L 'allowed-tools:.*, ' skills/*/SKILL.md` empty |
| 6.2 `${CLAUDE_SKILL_DIR}` (`skills/mov/SKILL.md:24`) | Replace with `${CLAUDE_PLUGIN_ROOT}` form; the current fallback expands empty and resolves to a broken `/../` path | grep: every `${CLAUDE_*}` in shipped md ∈ {PLUGIN_ROOT, PLUGIN_DATA, PROJECT_DIR} |
| 6.3 ~46 bare `scripts/*.sh` refs in main SKILL.md | Portable `"${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/scripts/…"` on every *invocation* line; prose mentions may stay bare (policy decision Q6 if disputed) | grep: no fenced command line starts a bundled script bare |
| 6.4 6,394-char changelog-bearing `description` | One-two sentences; history → new `CHANGELOG.md` (standard layout) | `python3 - <<'EOF'` length assert < 1000; CHANGELOG.md exists |
| 6.5 Hygiene | Add `$schema`; delete `QTFF-AUDIT-PLAN.md.bak-20260726`, `.DS_Store` ×2; drop no-op `defaultEnabled` or keep with comment; decide whether plan/research md files ship (recommend: keep — they are the provenance) | `git ls-files` asserts |
| 6.6 CI | **The workflow is dead-lettered in the monorepo layout (runs only when the plugin is repo root — it currently never runs).** Fix trigger/working-directory; add `claude plugin validate . --strict` *plus* the three blind-spot greps (6.1–6.3) the validator cannot perform | CI run visible on a PR touching the plugin |
| 6.7 `workflows/` | **Decline** — no multi-step component fits; one-line verdict recorded | — |
| 6.7 `bin/` | **Decline for now** — `derive-dts.sh` stays in `scripts/` with its siblings; revisit if PATH exposure is ever wanted | — |
| 6.8 24 `RTM_*` knobs | Interim: document all in a reference table (name, default, consumer, unit). `userConfig` migration **blocked on Q5** (whether skill Bash sees `CLAUDE_PLUGIN_OPTION_*` — the reference documents the read mechanism only for hooks/monitors/MCP). If unseen: keep env knobs, documented | grep-census in CI matches the documented table |

---

## 4. Sequencing, cost, and risk

Order of landing: **1 → 2 → 3 → 4 → 5 → 6.** Phase 1 is pure measurement (safe, additive,
everything downstream reads it); Phase 2 changes verdicts only where they were false; Phase 3
adds capability without touching existing routes; Phase 4 switches routing only once the rung
exists; Phase 5 makes the docs match; Phase 6 is packaging. After every phase:
`tests/regression.sh` green against the Phase-0 baseline, per house rule. Fixture cost: three
new ticks-file profiles (cheap), one B-pyramid MKV + chapters fixture (~seconds of encode), one
ms-quantized-audio MKV, one chaptered census pair, one gate-(g) noise pair — all sandbox-
mintable; the only unmintable artifact (true PAFF) is honestly deferred to the next real
capture. Exit-contract changes: **none in meaning**; three false-verdict classes move
1→0/10 and are changelog-called (1.6, 2.1, 2.2); the new rung adopts the contract + documented
3 (pending Q1).

The operator/archivist/maintainer/adversary lenses were applied per item (adversarial checks
inline); the two lens conflicts that rose to decisions are recorded as Q1 and Q2.

---

## 5. Open questions (raised, not assumed)

- **Q1 — New rung's refusal code.** Sibling PAFF rungs use documented pre-contract 3; the
  modern contract would say 11 REFUSED. Recommend 3 for family consistency; 11 defensible.
  Maintainer's call before Phase 3 lands.
- **Q2 — Whole-file depth pass cost.** The rung recomputes D whole-file (a full PTS dump —
  minutes on 50 GB). Always mandatory, or skippable with `--trust-window` for bench runs?
  Recommend mandatory (a wrong D under-derivation is the one failure the math cannot absorb;
  D overestimation is safe, underestimation is not).
- **Q3 — The `ppf` (field-coded) essence probe.** Decode-count-vs-packet-count is the leading
  candidate; needs a bench measurement on real PAFF (none mintable locally) before 1.1's
  classifier can claim `ppf=2` with confidence. Until then `ppf=unknown` routes conservatively.
- **Q4 — The ref-frames notice as a third unit artifact [frozen].** `4 Ref Frames` on a
  field-coded stream (DPB = 8 fields) — is ffmpeg's checker also frame/field confused? Re-test
  on the next class member; it props up the report's "inherited decode damage" framing and
  gates (c)/(e)'s counts on such files.
- **Q5 — `CLAUDE_PLUGIN_OPTION_*` visibility to skill Bash.** Test before any `userConfig`
  migration (6.8).
- **Q6 — SKILL.md path-form policy.** Recommendation in 6.3 (portable on invocation lines,
  bare in prose); if the maintainer wants all-portable, say so and 6.3's grep tightens.
- **Q7 — seam-check baseline (DF-16).** Same scope-discipline class as gate (g), but its
  "source" is the joined artifact itself — the (g) fix pattern doesn't transplant directly.
  Deferred with the defect named rather than half-fixed; design wanted.
- **Q8 — Route C's gate-(a) sub-question [frozen].** Whether SPS surgery would even break
  packet-hash identity is file-dependent (out-of-band CodecPrivate vs in-band SPS). Unverifiable
  on the deleted source; check on the next member if Route C is ever attested.
- **Q9 — Scan-window reconciliation.** `pf_reorder_scan`'s 3000 vs diagnose step (3)'s 5000:
  1.1 proposes one named constant; confirm no pinned test depends on the 5000 figure.

