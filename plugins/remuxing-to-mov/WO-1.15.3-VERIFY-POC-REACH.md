# 1.15.3 Work Order — Verify the POC Gate's Reach

> **Status (2026-08-27): FILED. Nothing here is applied.** This round is the
> POC-shaped remainder of the 1.15.2 filing's Phase 5 — item 5.3 (the gate's
> capability pre-flight) and item 5.4 (reusing the census `trace_headers` pass)
> — plus two gaps the 1.15.2 record names but never numbered: the operator
> playbook's step 7 ("re-run the gate against the `.part` standalone")
> describes a capability **no script provides** — the field run did it by
> hand-sourcing `lib-paff.sh` — and the UNPROVEN branch emits **no
> machine-readable line** (the `PP_POC_LATTICE` row prints only on the
> evaluated path).
>
> Every claim below was measured on this bench against the shipped 1.15.2
> code, read-only, using scratch fixtures minted for the purpose; the repo and
> the installed plugin are unmodified. The headline measurements: a
> `pic_order_cnt_type` 2 stream hands the gate **zero** extractable POC rows
> and its verdict is knowable from a 40-frame head probe in seconds — while
> today the discovery costs the entire build (field-recorded: ~55 minutes of
> mux plus a 26-minute output parse to reach a foregone UNPROVEN, exit 1,
> 24.8 GB `.part` retained). And the census-reuse soundness claim is now
> mechanical, not argued: the gate's own extraction awk, run against a source
> `.ts` and its `-c copy` `.mov`, produced **byte-identical** 50-row
> `idr,poc` tables and agreeing SPS captures.
>
> **Not this round** (still open from 1.15.2 Phase 5): the UNPROVEN/FAILED
> audit across the remaining gates (5.1) beyond the local application here,
> unit tables for `rewrap_nudges` / `rewrap_hard_confessions` (5.2), the
> content-hash fallback in `verify.sh` gate (g) (5.5), and the wider
> provenance sweep (5.6). Listed again at the end so the next filing inherits
> them explicitly.

**Bench:** ffmpeg/ffprobe 9.0.1 (libx264 present), macOS (Darwin 25.6.0),
zsh, APFS. Fixtures: `testsrc2`, 25 fps, 50 frames, H.264 mpegts —
`-bf 3` mints `pic_order_cnt_type` **0**, `-bf 0` mints type **2** (x264
selects type 2 when B-frames are off; it never emits type 1). Full mint and
measurement transcript in the appendix.

---

## Working context

Everything needed to execute this document is in this repository. No field
media is required — every fix below is verifiable from scratch fixtures and
canned text tables.

- **Repo:** `saldigioia/claude-plugins`; this plugin is `plugins/remuxing-to-mov/`.
- **Path convention:** paths written `scripts/…` mean
  `plugins/remuxing-to-mov/skills/remuxing-to-mov/scripts/…`. Line numbers
  are 1.15.2 and may drift — every fix quotes the code it targets; match on
  the text, not the number.
- **Run the suite:** `bash tests/regression.sh` from `plugins/remuxing-to-mov/`
  (needs ffmpeg + ffprobe with libx264). 1.15.2 shipped green at 274/274.
- **Numbered cases** live in `tests/regression.d/`; 1.15.2 ends at
  `76-poc-lattice-wrap.sh`, so this round adds **77–79**.
- **Exit contract:** house-wide `0` DONE, `10` REVIEW, `1` FAIL, `2`
  usage/pre-flight, `11` REFUSED — plus `pairfill-paff.sh`'s own `3` for a
  junction-model precondition refusal ("nothing built, source untouched").
  **Driver routing is NOT settled by that exit** (corrected 2026-08-27, same
  day as filing — the original text here mis-cited `auto.sh:222`, which
  settles *derive-dts*'s exit 3, and over-claimed "never falls back"): in
  `auto.sh`, any pairfill failure lands as generic `RESULT=FAIL` in
  `attempt()` (`auto.sh:189`), and on the `half_ts=yes` route the
  no-fallback-to-rebuild rule is **conditioned on a reorder pyramid**
  (`auto.sh:245–246`, `:300–302`): with `PF_REORDER=no` the driver proceeds
  to the flattening rebuild (`attempt 3` — doctrine-legal for a no-pyramid
  stream), and with `PF_REORDER=yes` + the derive signature it escalates to
  Rung 3-DERIVE, **which has no POC gate at all**. Item 1 therefore has to
  state the intended driver behavior per profile, not assume the refusal
  ends the run.
- **The test lanes:** test 76 opened the unit lane (pure text tables, no
  media); test 65 §3 established the canned-`trace_headers`-log pattern via
  the `PF_TRACE_FILE` hook (`lib-paff.sh:1054`). Both patterns are load-bearing
  below.

---

## The reach map — what the gate can and cannot judge (measured)

The POC-lattice gate has exactly one burial point: inside `pairfill-paff.sh`,
junction model only (`PP_JM=1`), **after** the build. Its reach today:

| Source shape | Extraction yields | Gate verdict today | Knowable when |
| :--- | :--- | :--- | :--- |
| `pic_order_cnt_type` 0 (field source; every x264-with-B stream) | one `pic_order_cnt_lsb` row per picture + SPS `log2_max…` | **evaluated** (unwrapped per §8.2.1.1 since 1.15.2 D) | — |
| `pic_order_cnt_type` 2 (x264 `-bf 0`; measured) | **zero** lsb rows; **no** `log2_max…` (the SPS field is spec-conditional on type 0 — measured absent) | UNPROVEN, exit 1, `.part` kept — **after the whole build** | **head probe, seconds** — `pic_order_cnt_type` prints in the SPS at 40 frames |
| `pic_order_cnt_type` 1 | unmeasured — no fixture source on this bench (x264 emits only 0 and 2) | same UNPROVEN arm by construction (no lsb syntax element) | same head probe |
| picture/packet count mismatch (`pp_na != pp_nb`) | rows ≠ output packets | UNPROVEN, same branch | **census time, pre-mux** — see below |

Measured head probes (40 frames, the same shape as the existing junction
feature-probe at `pairfill-paff.sh:219–228`):

```
poc0.ts (libx264 -bf 3):  poc_type=0  log2max=2       lsb_rows=40  idr_nals=2
poc2.ts (libx264 -bf 0):  poc_type=2  log2max=absent  lsb_rows=0   idr_nals=2
```

The count-mismatch arm is *also* pre-mux-knowable, and the code already
half-says so: the census note at `pairfill-paff.sh:247–248` prints
`census pictures (PC_PICS) != demux packets (PP_N)` on the source. After the
fill, the output has zero N/A PTS (gated before POC) and `-c copy` preserves
packet count, so `pp_nb = PP_N` and `pp_na` is the output's picture count —
the gate's count guard trips **iff** `PC_PICS != PP_N`, which the census knew
before the mux started. Nothing about the gate's reach genuinely requires
building first.

---

## Item 1 — the gate's capability is knowable at pre-flight, and the build never asks

**Severity: medium (cost/honesty, not correctness).** The 1.15.2 Item C
precedent applies verbatim: `zero-base.sh` used to build 23.68 GB to reach a
foregone hard-stop, and the fix was a pre-flight refusal. The junction path
has the same shape today: on a `pic_order_cnt_type != 0` source it runs the
entire mux plus a whole-file output parse to reach a foregone UNPROVEN
(exit 1, `.part` retained at full size). Head-probe cost to know the outcome
in advance: seconds.

### Location

`pairfill-paff.sh:219–228` (the head feature-probe — currently counts
`first_mb_in_slice==0` pictures and nothing else) versus `:470–479` (the
UNPROVEN branch, reached post-build).

### Fix

1. **One probe, one awk, eval-able output.** Extend the head probe into a
   `lib-paff.sh` helper in the `pf_trace_census` mold:

   ```
   pf_poc_capability HEAD_TRACE_LOG   ->
     PCAP_POC_TYPE=n  PCAP_MAXLSB=n|0  PCAP_LSB_ROWS=n  PCAP_PICS=n
     PCAP_OK=yes|no   PCAP_WHY=poc_type|no_pictures|-
   ```

   Text-in/text-out over a head `trace_headers` log — unit-testable from
   canned logs (test 65 §3 pattern), and the probe's existing
   "parsed no coded picture" refusal folds into `PCAP_OK=no/no_pictures`.
   Capture the probe's ffmpeg output to a temp file once; feed both consumers
   from it.

2. **Refuse at pre-flight on `PCAP_LSB_ROWS == 0`**, junction path only, in
   the established precondition voice, exit 3:

   > JUNCTION MODEL REFUSED: pic_order_cnt_type=2 — this stream carries no
   > pic_order_cnt_lsb, so the POC-lattice output gate (the junction model's
   > strongest correctness evidence) cannot evaluate any build from it. The
   > build would end UNPROVEN at its final gate and could never be blessed.
   > Nothing was built; the source is untouched.

   Name the manual route (the mux commands in
   `references/timeline-repair.md`) for an operator who wants the artifact
   anyway, unproven, by hand — the same convention every other junction
   refusal follows. **Do not** add a bypass flag: a gate that can be waived
   into UNPROVEN-by-default is 1.15.2's Defect-B lesson again.

3. **Fold the count arm in.** After the census, when `PC_PICS != PP_N`, the
   existing note line should also state the consequence: the POC gate's count
   guard will trip and the build cannot end better than UNPROVEN. Whether
   that is a refusal or an announced-and-continue is an executor decision —
   the multi-slice/non-VCL framing case is real and the duration gate still
   judges those builds; recommend **announce, do not refuse**, since unlike
   the `poc_type` arm this one has a legitimate population.

4. **Carry `PCAP_MAXLSB` forward** to the gate invocation. The output-pass
   SPS capture stays as corroboration; if the two disagree, refuse loudly —
   an SPS that changed across a `-c copy` is evidence of something much worse
   than a gate problem.

5. *(Optional, decide in-round)* surface one capability line in `/clean`'s
   PAFF finding (`clean.sh` report tier): "junction POC gate: can evaluate
   (poc_type 0, MaxPicOrderCntLsb 512)" — the operator learns the strongest
   gate's reach before choosing a route. Head-probe cost. If skipped, record
   why in the CHANGELOG entry.

6. **State the driver behavior per profile — the refusal does not end the
   run.** Measured routing (`auto.sh:296–308`): after a pairfill non-OK on
   the `half_ts` route, `PF_REORDER=no` falls through to the flattening
   rebuild (legal for a no-pyramid stream — but then the deliverable carries
   NO POC-gate evidence; the rebuild's own gates judge it), and
   `PF_REORDER=yes` + derive signature escalates to Rung 3-DERIVE (also
   POC-gate-free). Decide and document both: recommend letting the
   established fallbacks stand, with the pre-flight refusal message naming
   where the run will go next under `auto.sh` and that the POC lattice will
   not judge that artifact. What the refusal must guarantee is only:
   pairfill itself writes nothing.

**Verified on this bench:** the head probe carries everything the verdict
needs on both fixture shapes (table above). The routing consequence of the
refusal is per-profile (step 6) — the original filing's "cannot silently
downgrade the route" claim was measured false the same day and corrected.

---

## Item 2 — the POC gate re-reads what the census already read (1.15.2 item 5.4)

**Severity: medium (cost).** Field-recorded: the POC gate alone took
**26m16s** on the 23.68 GB artifact, ~20 minutes of it the whole-file output
`trace_headers` parse — roughly a third of the total ladder runtime — while
`pf_trace_census` had **already paid** a whole-file `trace_headers` pass over
the same coded pictures on the source.

### Location

`lib-paff.sh:1055` — `pf_trace_census`'s awk keeps only
`first_mb_in_slice` / `field_pic_flag` / `pic_struct` and discards the POC
tokens flowing through the same pipe. `pairfill-paff.sh:456–466` — the gate
then runs a second whole-file pass on `$PART` to recover them.

### Soundness — measured, not argued

The reuse claim is: pairfill copies video bits untouched (`-c copy` by
construction), so the output's per-picture `idr,poc` sequence **is** the
source's, picture for picture. Measured with the gate's own extraction awk,
verbatim, on `poc0.ts` and its `-c copy` `.mov`:

```
tbl.src: 50 rows      tbl.mov: 50 rows      diff: TABLES IDENTICAL
sps.src=2  sps.mov=2  (log2_max_pic_order_cnt_lsb_minus4 -> MaxPicOrderCntLsb 64)
output ffprobe non-N/A PTS rows: 50  (= table rows)
```

The license is **copy-by-construction within the same run**, corroborated at
sign-off by `verify.sh` gate (b) VCL identity. State that in the code: a
future non-copy path must not inherit the reuse.

### Fix

1. `pf_trace_census` additionally emits the per-picture `idr,poc` table and
   the SPS `log2_max…` value to side files when the caller provides paths
   (env or args, mirroring the extraction's existing `spsf` pattern). Same
   pass, zero extra reads; the awk grows four token matches.
2. The gate then builds its table as census-`idr,poc` ⨯ output-ffprobe-PTS
   (`paste -d,` as today). The count-equality guard stays — it is now
   literally the census-vs-output-packets identity that gate (b) proves.
3. **Keep the direct-output extraction as a fallback arm** — the standalone
   entry point (Item 3) runs against bare artifacts with no census in scope,
   and the A/B between the two arms is itself the regression pin (test 78).
4. Record the cost model in `knobs.md`: reuse leaves the gate paying only
   the output ffprobe PTS list (~minutes on 24 GB, I/O-bound) instead of a
   ~20-minute header parse; the fallback arm keeps the old cost and says so.

---

## Item 3 — playbook step 7 names a capability that does not exist

**Severity: low-medium (honesty/UX).** The operator playbook (1.15.2 filing)
says: *"If the refusal turns out to be a gate defect, the artifact is already
built and the gate can be re-run against it standalone — 26 minutes instead
of a 60-minute rebuild."* That is exactly what the field run did — by
hand-sourcing `lib-paff.sh` and calling `pf_poc_lattice` with a hand-built
table. No script exposes it. Both retention messages name the byte size and
the `rm` command (1.15.2 UX fix) but neither names a re-judge route, because
there is none to name.

### Fix

`scripts/poc-gate.sh ARTIFACT [--table CSV] [--maxlsb N]` — a thin standalone
driver over the existing pieces:

- default: direct-output extraction (the gate's current awk) + `pf_poc_lattice`,
  printing the same `on_slot=…` human line and `PP_POC_LATTICE …` machine row;
- `--table` skips extraction and judges a prepared CSV — which makes the
  script the unit lane's entry point too (test 76's tables drive it as-is);
- exit contract: `0` on-lattice, `1` off-lattice, **`10` UNPROVEN**, `2` usage.

The `10` is deliberate and is the 5.1 principle applied locally: **the same
verdict honestly carries different exits in different contexts.** Inside
`pairfill-paff.sh` an UNPROVEN build must not be blessed, so the branch keeps
exit 1 and the `.part` retention — unchanged. Standalone, the script makes no
bless decision; it reports what it could judge, and "could not evaluate" is
REVIEW semantics (`verify.sh` is the house reference for exactly this split).
Say both halves in the script header.

Two companion one-liners land with it:

- the UNPROVEN branch gains its machine row (today `PP_POC_LATTICE` prints
  only on the evaluated path, `pairfill-paff.sh:493`):
  `PP_POC_LATTICE unproven=1 why=<poc_type|count> rows=$pp_na packets=$pp_nb`;
- both retention messages (`:478`, `:497`) append the re-judge route:
  `re-judge: scripts/poc-gate.sh "$PART"`.

**Considered and recommended against:** a `verify.sh --poc` flag instead of a
standalone script. `verify.sh`'s contract is "the lowest cost that is actually
conclusive" and its gates are route-agnostic; the POC lattice is
junction-model-specific and whole-file-parse expensive. A flag there invites
running it where it proves nothing. Record this decision in the CHANGELOG so
it isn't re-litigated.

---

## Item 4 — `pic_order_cnt_type` 2: which flavor of honest? (decision, mostly not code)

For type 2 the spec pins decode order = display order (no stored reordering),
so the presentation lattice degenerates to a uniform ramp — which the
existing output gates (zero N/A, strictly monotonic DTS, the pair-tick
duration histogram, span skew) already constrain tightly. Three candidate
positions:

1. **Pre-flight-announced UNPROVEN** (what Item 1 delivers): the gate says
   *up front* that it cannot evaluate this shape, and no build burns an hour
   to learn it. **Recommended floor — ship this regardless.**
2. **A doctrine sentence, not a code path:** record in
   `references/timeline-repair.md` (junction section) that for type 2 the
   lattice degenerates and the duration-histogram gate is the operative
   evidence — an *argument*, clearly labeled as one, not a measurement.
   Recommended alongside 1.
3. **Reconstruct POC from `frame_num`** (`FrameNumOffset`, non-reference
   pictures, `gaps_in_frame_num_value_allowed_flag` — H.264 §8.2.1.3):
   spec-heavy code with **no measured demand** — no field case has ever hit
   this arm, and UNPROVEN ≠ FAILED already keeps the verdict honest.
   **Declined until a field case demands it.** Record the decline.

`pic_order_cnt_type` 1 has no fixture source on this bench (x264 emits only
0 and 2 — measured) and stays UNPROVEN, honestly labeled by the same
pre-flight.

---

## Phases

### Phase 1 — capability pre-flight (Item 1)

1. `pf_poc_capability` in `lib-paff.sh`, canned-log-testable.
2. Rewire the head feature-probe: one ffmpeg run, output to temp file, both
   consumers read it; junction path refuses on `PCAP_WHY=poc_type`, exit 3.
3. Census count-arm consequence line; `PCAP_MAXLSB` carried to the gate with
   the disagree-loudly corroboration check.
4. Decide (and record) the optional `/clean` capability line.

**Gate 1:** test 77 red-parts before, green after; existing junction tests
(65, and the PAFF set) unchanged; on the type-2 fixture a **direct**
`pairfill-paff.sh` invocation exits 3 with **nothing written by pairfill**,
and the driver-route consequence (Item 1 step 6: `auto.sh` may legally
continue to rebuild/derive per profile) is asserted, not assumed.

### Phase 2 — census-pass reuse (Item 2)

1. Extend `pf_trace_census` (side-file emission).
2. Rewire the gate to census-table ⨯ output-PTS with the direct-extraction
   fallback arm intact.
3. `knobs.md` cost model entry.

**Gate 2:** test 78's A/B — census-emitted table byte-equal to
direct-output-extraction table on a copy-remuxed fixture, and
`pf_poc_lattice` verdicts identical through both arms. Relationship pins
only.

### Phase 3 — standalone entry + UNPROVEN machine row (Item 3)

1. `scripts/poc-gate.sh` with the exit contract above.
2. `PP_POC_LATTICE unproven=1 …` row on the UNPROVEN branch.
3. Retention messages gain the re-judge route.

**Gate 3:** test 79 green; the CHANGELOG records the `verify.sh --poc`
decline.

### Phase 4 — the reach map becomes doctrine

1. The reach table (above) lands in the `pairfill-paff.sh` header beside the
   junction-gate paragraph, and the type-2 degeneracy sentence lands in
   `references/timeline-repair.md`, labeled argument-not-measurement.
2. Provenance comments touched by Phases 1–3 name this round
   (the 1.15.2 rule: a measured comment names its measurement).

**Gate 4:** `claude plugin validate --strict` green on plugin and
marketplace; suite green end-to-end.

---

## Regression tests

Next free number is **77**.

- **`77-poc-capability.sh`** — unit lane first: canned head-trace logs
  (synthesize trace-shaped text in-test, the test-65 §3 pattern — the parser
  only needs the token and value columns) for type-0 and type-2 shapes →
  `PCAP_*` verdicts; then the integration arm: mint `poc0.ts` (`-bf 3`) and
  `poc2.ts` (`-bf 0`) per the appendix recipe, assert the junction path
  refuses the type-2 source at pre-flight, exit 3, no bytes written, route
  named. Pins are relationships (`PCAP_MAXLSB == 1 << (l2+4)`;
  `capable=no ⇒ why` nonempty), never bench literals.
- **`78-poc-census-reuse.sh`** — the A/B: on a B-frame fixture copied
  ts→mov, census-emitted `idr,poc` table `cmp`-equal to the direct-output
  extraction; `pf_poc_lattice` verdict equal through both arms; SPS value
  equal from both captures. This is the measured appendix result, pinned.
- **`79-poc-gate-standalone.sh`** — `poc-gate.sh` on a clean artifact → 0;
  on test 76's negative table via `--table` → 1; on the type-2 artifact →
  10; and grep-pins: the UNPROVEN branch's machine row exists, both
  retention messages name the re-judge route.

All three lean unit-lane: media minting only where a real demux is the thing
under test.

---

## What stays open after this round

Inherited by the next filing, deliberately untouched here:

- **5.1** — the UNPROVEN/FAILED audit across every remaining gate that can
  exit FAIL (this round applies the principle only to the POC gate's two
  contexts).
- **5.2** — unit tables for `rewrap_nudges` / `rewrap_hard_confessions`
  (the census awk is already pinned by test 65 §3).
- **5.5** — the content-hash fallback in `verify.sh` gate (g).
- **5.6** — the wider provenance sweep (`measured` / `proving job` comments
  no test pins).
- **Field follow-up, not repo work:** `verify.sh --full` archival sign-off on
  the delivered 2022-VMA `feed.mov` has still not been run; `lead-check.sh`'s
  ~37-minute cost on that class remains unexamined.

---

## Appendix — bench transcript (2026-08-27, read-only, scratch dir)

Mint:

```bash
ffmpeg -y -v error -f lavfi -i testsrc2=r=25:s=320x240:d=2 \
  -c:v libx264 -bf 3 -g 25 -pix_fmt yuv420p -f mpegts poc0.ts   # poc_type 0
ffmpeg -y -v error -f lavfi -i testsrc2=r=25:s=320x240:d=2 \
  -c:v libx264 -bf 0 -g 25 -pix_fmt yuv420p -f mpegts poc2.ts   # poc_type 2
```

Whole-file `trace_headers` (the gate's own invocation shape):

```
poc0: pic_order_cnt_lsb lines = 53 (50 slices + repeated SPS headers)
      SPS: pic_order_cnt_type = 0, log2_max_pic_order_cnt_lsb_minus4 = 2
poc2: pic_order_cnt_lsb lines = 0
      SPS: pic_order_cnt_type = 2, log2_max_pic_order_cnt_lsb_minus4 ABSENT
      frame_num present in slice headers (both)
```

Head probe (40 frames, junction feature-probe shape):

```
poc0: poc_type=0 log2max=2      lsb_rows=40 idr_nals=2
poc2: poc_type=2 log2max=absent lsb_rows=0  idr_nals=2
```

Reuse soundness (gate's extraction awk, verbatim, source vs `-c copy` mov):

```
ffmpeg -y -v error -i poc0.ts -map 0:v:0 -c copy poc0.mov
tbl.src 50 rows == tbl.mov 50 rows, diff clean -> TABLES IDENTICAL
sps.src=2 sps.mov=2 ; ffprobe non-N/A PTS rows on poc0.mov = 50
```

Routing fact (corrected 2026-08-27, same day as filing — the original
paragraph mis-cited `auto.sh:222`, which settles *derive-dts*'s exit 3, and
over-claimed "cannot change the route"): in `auto.sh`, a pairfill failure of
any code lands as generic `RESULT=FAIL` (`attempt()`, `auto.sh:189`); the
no-fallback-to-rebuild rule (`:245–246`) is conditioned on a reorder
pyramid, so on `PF_REORDER=no` the driver proceeds to the flattening
rebuild (`:300–302`) and on `PF_REORDER=yes` + derive signature it
escalates to Rung 3-DERIVE — neither of which carries a POC gate. The
pre-flight refusal guarantees only that pairfill itself writes nothing;
Item 1 step 6 owns the per-profile driver behavior.
