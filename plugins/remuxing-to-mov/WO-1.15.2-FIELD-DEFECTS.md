# 1.15.2 Work Order — the Field Defects Round

> **Status (2026-08-27, later the same day): LANDED as 1.15.2.** Phases 1–4
> are in the repo: `ffp1` + both `program=` sites (A), the true-dry-run
> `rewrap_predict` with `RW_PREDICT_IN_OPTS`/`RW_PREDICT_OUT_OPTS` mirroring
> and the layout-before-predict reorder in both callers (B), the doctrine
> qualification in `references/source-clinic.md` plus the `zero-base.sh`
> pair-timestamped-PAFF pre-flight refusal (C), and the §8.2.1.1 unwrap in
> `pf_poc_lattice` with the SPS `MaxPicOrderCntLsb` captured in the same
> trace_headers pass (D) — tests 73–76 added (76 opens the unit-test lane),
> suite green, CHANGELOG carries the round. Defect B's mechanism was also
> reproduced synthetically before fixing (overlap-concat timeline: old
> pre-pass 0, real build 50, mirrored dry run 50), so test 74 has a
> collision-bearing fixture with no field media. The **bisect question is
> answered**: git shows the unwrap never existed in-repo — the 2026-08-18
> proving figure came from the pre-extraction hand-run gate, and the
> provenance comments at `pairfill-paff.sh` now say so. From Phase 5, landed
> in this round: the UNPROVEN relabel on the not-extractable POC branch, the
> `.part` size + delete-command messages, the `--audio-keep` PAFF-path
> rejection, and the test-76 unit lane. **Still open (next round):** the
> UNPROVEN/FAILED audit across the remaining gates (5.1), unit tables for
> `rewrap_nudges`/`rewrap_hard_confessions`/census awk (5.2), the POC-gate
> capability pre-flight before the hour of muxing (5.3), reusing the census
> trace_headers pass for the POC gate (~20 of its 26 minutes) (5.4), the
> content-hash fallback in verify.sh gate (g) (5.5), and the wider
> provenance sweep (5.6).
>
> Original filing follows unedited.

> **Status (2026-08-27): FILED. Defect D's fix is PROVEN END-TO-END; A, B and C
> remain unwritten.** Three measured defects — two in `lib-rewrap.sh` (A, B), one
> in `lib-paff.sh` (D) — all found in the field during a `/clean` →
> `zero-base.sh` → `/mov` run against a single live capture, none caught by the
> 1.15.1 suite.
>
> **Defect D is closed on evidence, not argument.** Patched on a throwaway copy,
> it took the same capture from `on_slot=3179/451071` (FAIL, 55 min wasted) to
> `on_slot=451071/451071 off=0` (PASS), and a full clean rebuild then produced a
> delivered `.mov`: video VCL **bit-identical**, timeline clean, 24,838,946,221
> bytes, `mov.sh` exit 10 REVIEW with every review reason accounted for. That
> build is **not reproducible on stock 1.15.1** — the gate fails it. Landing D is
> what makes the plugin able to remux long-GOP broadcast PAFF at all. Defect A is a
> silent-abort class (the script dies with exit 1 and *no diagnostic*); Defect B
> is a correctness class in the prediction contract itself — the gate that
> 1.15.0 doctrine calls "enforced, not aspired to." Defect D false-FAILs the
> `/mov` PAFF build at its final gate by fitting a POC lattice to un-unwrapped
> `pic_order_cnt_lsb`. Item C qualifies a doctrine claim in
> `references/source-clinic.md` that the same run contradicted.
>
> **Read together, A, B and D are one story:** every gate that failed in the
> field failed *silently, spuriously, or both* — the honesty machinery is where
> the defects are, not the muxing.
>
> **Bench:** ffmpeg/ffprobe 9.0, macOS (Darwin 25.6.0), zsh, APFS on external
> SSD. **Field source:** `feed.ts` — 2022-08-28 MTV Video Music Awards satellite
> backhaul, 23.68 GB mpegts, H.264 Main 1920×1080 PAFF (`field_order=tt`),
> 25 fps / ~50.2 coded pictures per second, 4 × MP2 stereo 48 kHz, single
> program (`program_num=1`, `pmt_pid=303`, stream PIDs `0xbd6`–`0xbda`),
> 2h30m25s, 20.99 Mbit/s. Transport pristine, timeline gap-free — the source is
> *healthy*, which is what makes it a clean isolate for both defects.
>
> **Nothing here is applied anywhere.** Every finding was measured against a
> throwaway patched copy of `scripts/`; the installed plugin cache and this
> repository are both unmodified. Treat every fix below as unwritten.

---

## Working context

Everything needed to execute this document is in this repository. **The field
source is not required** — it is a 23.68 GB capture on external media, and every
fix below is verifiable without it.

- **Repo:** `saldigioia/claude-plugins`; this plugin is `plugins/remuxing-to-mov/`.
- **Path convention:** paths written `scripts/…` mean
  `plugins/remuxing-to-mov/skills/remuxing-to-mov/scripts/…`, matching the rest
  of the plugin's docs. Line numbers are 1.15.1 and may drift — every fix below
  quotes the code it replaces, so match on the text, not the number.
- **Run the suite:** `bash tests/regression.sh` from `plugins/remuxing-to-mov/`
  (needs ffmpeg + ffprobe built with libx264). Exit 0 = all assertions pass.
- **Numbered cases** live in `tests/regression.d/`; 1.15.1 ends at `72-clean.sh`,
  so this round adds **73–76**.
- **Media fixtures:** `bash tests/make-fixtures.sh` mints the corpus into
  `tests/fixtures/` (gitignored — media never ships in git). Defects A and D
  need no new media; see each test note.
- **Exit contract** is the house one: `0` DONE, `10` REVIEW, `1` FAIL, `2`
  usage/pre-flight, `11` REFUSED.

### Suggested order

Defect **A first** — it is three lines and it unblocks running `zero-base.sh` /
`surgical-cut.sh` at all, which Defect B's verification then needs. **D is
independent** of A/B and can be done in isolation by anyone who would rather
start with the `/mov` path.

---

## Defect A — `rewrap_layout` dies by SIGPIPE, silently

**Severity: high.** Kills `zero-base.sh` and `surgical-cut.sh` — both Tier-1 and
Tier-2 clinic builders — with no message the operator can act on.

### Location

`skills/remuxing-to-mov/scripts/lib-rewrap.sh`, lines 49–50:

```bash
pmt=$(ffp -v error -show_entries program=pmt_pid    -of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d ,)
svc=$(ffp -v error -show_entries program=program_num -of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d ,)
```

### Mechanism

`ffprobe -show_entries program=…` does not emit one line per *program*. It emits
one line per program **plus one blank line per `program_stream`**. On the field
source that is six lines for a single-program file:

```
1,303,
        ← program_stream ×5, blank under -of csv=p=0
```

`head -1` consumes one line and closes the read end. If ffprobe has not finished
writing the remaining five, it takes **SIGPIPE — exit 141**. Both call sites run
inside a command substitution, and both callers set `set -euo pipefail`:
`pipefail` promotes the pipeline's status to 141, the assignment inherits it, and
`set -e` aborts. The failure is not inside an `if` or a `&&` list, so nothing
traps it and nothing prints.

The observable symptom is a script that stops mid-report between the prediction
pre-pass and the layout note, exit 1, **zero diagnostic output**:

```
-- prediction pre-pass (null muxer, whole file, -copyts) --
   predicted: 0 collision sites — the mux log must stay nudge-free.
[nothing further; exit 1]
```

### Why the suite missed it: it is a race, not a constant

Measured on the bench, same source, identical six-line output from both:

| Probe window | Wrapper | Runs | Result |
| :--- | :--- | :--: | :--- |
| 200M / 200M (plugin default) | `ffp` | 5 | **rc 141, every run** |
| 5M / 5M (ffmpeg stock) | bare `ffprobe` | 5 | rc 0, every run |

Line count is **6 in both cases** — the flip is timing, not content. The
`lib-probe.sh` window floor changes when ffprobe reaches its final write relative
to `head`'s exit, and that is enough to make the race resolve one way per
configuration and stay there. A race that is stable per-bench is exactly the
class a green suite hides: the fixtures happen to land on the winning side.

> [!WARNING]
> Do not "fix" this by pinning a probe window. The window is load-bearing
> elsewhere (`lib-probe.sh` header: a 32.4 Mbit/s TS carried its first SPS past
> the 5 MB default and poisoned `paff` routing). Fix the pipeline.

### Blast radius

- `zero-base.sh:123` → `rewrap_layout "$IN"` — **confirmed dead in the field.**
- `surgical-cut.sh:145` → `rewrap_layout "$IN"` — same call, same libs, same
  `set -euo pipefail`. Untested against the field source but structurally
  identical; treat as confirmed until measured otherwise.

Any mpegts source with **more than one stream in its program** produces enough
trailing lines to arm the race. That is nearly every real broadcast capture, and
it includes the repo's own multi-audio fixtures (`make-fixtures.sh` builds TS
files with two and three audio streams).

### The wider class

An audit of `scripts/` finds roughly ninety-five `ffp … | head -1` sites across
twenty `pipefail` scripts. The overwhelming majority query
`-of default=nw=1:nk=1` against `format=…` or a single `-select_streams`
selection and therefore emit exactly one line — `head -1` consumes everything and
the race never arms. **Those are safe by arithmetic, not by design.** The two
`program=` sites are the only *measured* failures, but the pattern is one
multi-line `-show_entries` away from recurring, and the codebase already shows
partial awareness of the hazard: a scattered subset of call sites defend with
`|| true` (`mov.sh:336`, `remux.sh:112`, `pairfill-paff.sh:284–311`,
`rebuild-paff.sh:92`) while the rest do not. Inconsistent defense against a known
hazard is the argument for a systemic fix.

### Fix — the helper, then the two call sites

Add to `lib-probe.sh`, beside `ffp`:

```bash
# ffp1 — first non-empty line of an ffprobe query, SIGPIPE-safe.
# awk reads to EOF, so ffprobe always completes its write: `head -1` under
# `pipefail` cannot abort the caller (measured: lib-rewrap program= queries
# emit 1 program line + N blank program_stream lines; 1.15.2 Defect A).
ffp1 () { ffp "$@" | awk 'NF && !g { print; g=1 }'; }
```

Then `lib-rewrap.sh:49–50` become:

```bash
pmt=$(ffp1 -v error -show_entries program=pmt_pid    -of csv=p=0 "$f" 2>/dev/null | tr -d ,)
svc=$(ffp1 -v error -show_entries program=program_num -of csv=p=0 "$f" 2>/dev/null | tr -d ,)
```

**Verified on the field source** (throwaway patched copy of `scripts/`, exit 0):

```
LAYOUT:   stream PIDs preserved: 5; PMT pid 303; service id 1; transport_stream_id: muxer default
STREAMID: -streamid 0:3030 -streamid 1:3031 -streamid 2:3032 -streamid 3:3033 -streamid 4:3034
MUXOPTS:  -mpegts_pmt_start_pid 303 -mpegts_service_id 1
```

Layout preservation is intact — PMT pid 303 and service id 1 both recovered, all
five stream PIDs carried. The fix restores intended behaviour rather than
routing around it.

### Migration of the remaining sites

Mechanical `ffp … | head -1` → `ffp1 …` is safe everywhere (identical output on
single-line queries) but touches ~95 lines. Recommend: convert the two broken
sites in this round, convert opportunistically thereafter, and add the guard
below so a new multi-line query cannot reintroduce the class silently.

---

## Defect B — the prediction contract does not model the mux it predicts

**Severity: high.** The prediction contract is a *gate*. A gate that measures a
different thing than it admits is worse than no gate.

### Location

`lib-rewrap.sh:62–71` (`rewrap_predict`) versus `zero-base.sh:126–133` (the build).

### Mechanism

The pre-pass and the build do not run the same muxer under the same options:

| | Pre-pass (`rewrap_predict`) | Build (`zero-base.sh`) |
| :--- | :--- | :--- |
| Output format | `-f null -` | `-f mpegts "$PART"` |
| `-copyts` | **present** | absent |
| `-muxdelay` / `-muxpreload` | absent | **`0` / `0`** |
| `-streamid` / mux opts | absent | **present** |

`-copyts` passes timestamps through untouched; without it ffmpeg rebases the
output to zero and applies the muxdelay/muxpreload arithmetic. The
untimestamped PAFF mates get CLI-filled DTS in both passes, but the values —
and therefore the equal-DTS collision sites — are not the same, and the null
muxer does not enforce what the mpegts muxer enforces.

### Measured

On the field source:

```
   predicted: 0 collision sites — the mux log must stay nudge-free.
…
   non-monotonic nudges observed: 11
```

Eleven `+1`-tick video nudges at equal-DTS sites, against a prediction of zero.
Doctrine (`references/source-clinic.md`) states the case file measured nine
predicted and exactly nine observed; on this source the pre-pass has no
predictive value at all.

The build was refused for an unrelated reason (Item C, below), so the contract
breach never reached an operator as a verdict — but note the ordering hazard: had
the source produced zero hard confessions, `zero-base.sh:145` would have failed
the build on `OBS != PRED` and told the operator an *unexplained timeline
artifact* had appeared, when in fact the artifact was explained and the
prediction was wrong. **A false FAIL from the honesty gate is a doctrine
regression**, and the inverse — a real artifact hidden by a coincidentally
matching count — is worse.

### Fix

Make the pre-pass a true dry run: same muxer, same options, discarded sink.

```bash
rewrap_predict () {
  local f="$1" fv="${2:-}" fa="${3:-}" log args=()
  [ -n "$fv" ] && args+=(-bsf:v "$fv")
  [ -n "$fa" ] && args+=(-bsf:a "$fa")
  log="$(mktemp)"
  # Mirror the BUILD exactly (same muxer, same timestamp arithmetic, same layout
  # opts) and throw the bytes away. -f null and -copyts predicted a DIFFERENT
  # mux than the one that runs — 1.15.2 Defect B.
  ffmpeg -nostdin -v warning "${FF_INPUT_OPTS[@]}" -i "$f" -map 0 -c copy \
    -muxdelay 0 -muxpreload 0 \
    ${RW_STREAMID_OPTS[@]+"${RW_STREAMID_OPTS[@]}"} \
    ${RW_MUX_OPTS[@]+"${RW_MUX_OPTS[@]}"} \
    ${args[@]+"${args[@]}"} -f mpegts -y /dev/null 2>"$log" || true
  rewrap_nudges "$log"
  rm -f "$log"
}
```

> [!IMPORTANT]
> This reorders the callers: `rewrap_layout` must now run **before**
> `rewrap_predict`, since the prediction needs `RW_STREAMID_OPTS` /
> `RW_MUX_OPTS`. Both `zero-base.sh` and `surgical-cut.sh` currently predict
> first. Swap the two calls and move the `layout:` echo above the prediction
> block.

Cost is unchanged in passes (the pre-pass was already whole-file) but higher in
CPU, since real mpegts muxing now happens. Record that in `knobs.md` if a skip
knob is wanted; do **not** default it off — a gate that can be skipped silently
is Defect B again.

### Second-order note

`surgical-cut.sh` passes bsf filters into `rewrap_predict` so the prediction
covers the packets that actually meet the muxer. The fix preserves that; verify
it explicitly, because the filtered path is the one Tier 2 depends on.

---

## Item C — a doctrine claim the field contradicted

`references/source-clinic.md`, under **Doctrine → Re-wrap ≠ remux**, states:

> …TS→TS plain copy preserves even the pair-timestamped PAFF shape (measured in
> the case file: untimestamped mates in → timestamp-less PES out).

On the field source, a TS→TS copy through `zero-base.sh` produced:

```
[mpegts @ …] Timestamps are unset in a packet for stream 0. This is deprecated
and will stop working in the future. Fix your code to set the timestamps properly
```

That string is, by the plugin's own definition (`rewrap_hard_confessions`), the
**invented-timing hard-stop class** — so `zero-base.sh` correctly refused to
bless, exit 1, evidence retained. The refusal is right. The doctrine sentence is
what needs work: it promises a clean TS→TS PAFF passthrough that this bench did
not deliver.

Three candidate resolutions, in preference order:

1. **Qualify the claim** — scope it to the case file's shape and record the
   VMA-2022 counter-measurement beside it. Cheapest, honest, no code.
2. **Give `zero-base.sh` a PAFF-aware pre-flight** — detect `half_ts=yes` (the
   profile is already computed by `probe.sh` / `ts-health.sh`) and refuse
   *before* building 23.68 GB, naming `pairfill-paff.sh` as the route. Saves the
   operator a full build to reach a foregone refusal.
3. **Investigate whether the confession is avoidable** on a pair-timestamped
   source under `-muxdelay 0 -muxpreload 0`. Largest scope; do not block 1.15.2
   on it.

> [!NOTE]
> Option 2 has independent value regardless of how the doctrine sentence lands.
> On the field source the entire prize for zero-basing was `format.start_time`
> 0.200000s → the announced 0.160000s floor: **40 ms on a value every player
> rebases away**. Building 23.68 GB and burning a verify battery to chase that,
> only to hard-stop, is a poor trade the tool could have declined up front.

---

## Defect D — the POC-lattice gate does not unwrap `pic_order_cnt_lsb`

**Severity: high — and it is a REGRESSION, not a latent gap.** The gate
false-FAILs a correct build at the *last* gate, after a 55-minute run. Worse:
`pairfill-paff.sh:29` records the widened junction model's provenance as
**"23.7 GB PAFF 1080i25, 451,071"** and line 46 records
**"451,071/451,071 on-slot on the proving job"** — that is *this exact capture*,
and it passed on 2026-08-18. Shipped 1.15.1 scores **3,179/451,071** on the same
file. Whatever unwrapped POC at proving time is not in the shipped function.

**Proven, not inferred:** patching `pf_poc_lattice` to unwrap POC and re-running
the gate against the already-built artifact returns
`on_slot=451071/451071 off_lattice=0`, restoring the recorded proving-job figure
exactly. The build was always correct; only the gate was broken.

### Location

`skills/remuxing-to-mov/scripts/lib-paff.sh` — `pf_poc_lattice ()`.
Driven from `skills/remuxing-to-mov/scripts/pairfill-paff.sh`, the `PP_JM`
junction-model output gate (~line 440).

The function as it stands in 1.15.1 — the whole of what needs changing:

```bash
pf_poc_lattice () {
  awk -F, '
    function endseq(   i, half, dp, dt, h, lim, base) {
      if (cnt == 0) return
      seqs++
      if (cnt == 1) { total++; on++; cnt = 0; return }
      half = 0; lim = (cnt < 16 ? cnt : 16)
      for (i = 2; i <= lim && !half; i++) {
        dp = poc[i] - poc[1]; dt = pts[i] - pts[1]
        if (dp != 0) { h = dt / dp; if (h > 0 && h == int(h)) half = h }
      }
      if (half == 0) { total += cnt; off += cnt; cnt = 0; return }
      base = pts[1] - poc[1] * half
      for (i = 1; i <= cnt; i++) {
        total++
        if (pts[i] == base + poc[i] * half) on++; else off++
      }
      cnt = 0
    }
    NF >= 3 {
      if ($1 + 0 == 1) endseq()
      cnt++; poc[cnt] = $2 + 0; pts[cnt] = $3 + 0
    }
    END{
      endseq()
      printf "PL_ON=%d\nPL_TOTAL=%d\nPL_OFF=%d\nPL_SEQS=%d\n", on+0, total+0, off+0, seqs+0
    }' "${1:?pf_poc_lattice needs TABLE_FILE}"
}
```

Its input is a plain CSV table of `idr,poc,pts` rows, one per picture, built by
`paste -d, "$PP_POCA" "$PP_POCB"` in `pairfill-paff.sh`. **That matters for the
test below: the gate is unit-testable from a text file, with no media at all.**

### Mechanism

The gate extracts raw `pic_order_cnt_lsb` per picture, then **per IDR-delimited
sequence** fits a single line

```
base = pts[1] - poc[1] * half
```

and asserts `pts[i] == base + poc[i] * half` for **every** picture in that
sequence.

`pic_order_cnt_lsb` is, by definition, POC **modulo** `MaxPicOrderCntLsb`. The
shipped gate never reconstructs `PicOrderCntMsb`, so the moment a sequence
outlives one POC wrap period the fitted line is wrong for every subsequent
picture. The gate is sound only when **IDR interval < POC wrap period** — a
precondition that is nowhere stated, and that the recorded proving job did
**not** satisfy (24 IDRs, ~73 wraps per sequence). It passed then anyway, which
is the proof that the unwrap once existed.

**Bisect this before writing the fix.** The regression is between the
2026-08-18 proving run and 1.15.1; recovering the original implementation may be
cheaper and more faithful than the reconstruction below, and will explain how a
recorded-and-passing gate silently lost its unwrap.

### Measured — the field source

| Quantity | Value |
| :--- | ---: |
| `pic_order_cnt_type` | 0 |
| `log2_max_pic_order_cnt_lsb_minus4` | 5 → **MaxPicOrderCntLsb = 512** |
| POC step | 2 per field picture |
| **POC wrap period** | **256 pictures (~5.1 s at 25 fps)** |
| Pictures | 451,071 |
| **IDR sequences** | **24** (~18,795 pictures each ≈ 73 wraps per fit) |
| Keyframes (`ts-health`) | 6,843 — i.e. mostly **non-IDR open-GOP I** |

Gate result:

```
on_slot=3179/451071  off_lattice=447892  (IDR sequences=24)
>> POC-LATTICE GATE FAILED — 447892 picture(s) off their presentation slot
```

**The failure count is predicted by the wrap arithmetic, not by any timeline
defect.** Each sequence starts at an arbitrary POC phase, so on average ~128
pictures survive to its first wrap: `24 x 128 = 3072` expected on-slot against
**3179 observed**. That agreement is the diagnosis.

### Why this is a false FAIL

Every other output gate passed clean on the same artifact:

```
packets=451071  N/A-PTS=0  N/A-DTS=0  backward-DTS=0  duplicate-DTS=0
off-histogram durations=0
pair-tick (frame-picture) durations=193 (census counted 193 frame picture(s))
max PTS-DTS=21600 (derived limit 32400)
presentation-vs-decode span skew=0 ticks (limit 7200)
```

Zero missing timestamps, strictly monotonic DTS, every duration on the
1800/1800 field histogram, the 193 frame-pictures matching the independent
`trace_headers` census exactly, and zero span skew. A timeline that is genuinely
off its presentation lattice does not pass all of those.

> [!WARNING]
> This does **not** mean the artifact should be blessed. It means the strongest
> gate did not run, so the build is **unproven**, not known-good. The script's
> refusal is the correct action on the evidence available to it. `feed.part.mov`
> (24.8 GB) is retained.

### Fix

Reconstruct full POC before fitting, per ITU-T H.264 §8.2.1.1:

```
if (poc_lsb < prev_poc_lsb) and (prev_poc_lsb - poc_lsb) >= MaxPicOrderCntLsb/2:
    poc_msb = prev_poc_msb + MaxPicOrderCntLsb
elif (poc_lsb > prev_poc_lsb) and (poc_lsb - prev_poc_lsb) > MaxPicOrderCntLsb/2:
    poc_msb = prev_poc_msb - MaxPicOrderCntLsb
else:
    poc_msb = prev_poc_msb
poc = poc_msb + poc_lsb          # reset poc_msb/prev to 0 at each IDR
```

This needs `MaxPicOrderCntLsb`, so the extractor must also capture
`log2_max_pic_order_cnt_lsb_minus4` from the SPS — `trace_headers` already
prints it in the same stream the gate is parsing, so no extra pass is required.

Unwrapping monotonically within an IDR sequence is sufficient; the fit and the
assertion are otherwise unchanged.

**Interim guard (do this even if the unwrap is deferred):** compute the wrap
period and, when `IDR interval >= wrap period`, either unwrap or report the gate
as **UNPROVEN/skipped** rather than FAILED. A gate that cannot evaluate a source
must not report that source as defective — same principle as Defect B's false
FAIL, one layer up.

### Regression test

**Test it as a unit, not through a build.** `pf_poc_lattice` consumes a text
table, so the wrap case needs no fixture, no libx264 and no 55-minute remux —
which is precisely why this defect survived a media-fixture suite.

`regression.d/76-poc-lattice-wrap.sh`: synthesize a table standing in for one
IDR sequence whose POC wraps several times — `MaxPicOrderCntLsb = 512`, POC step
2, `half = 1800`, ~2000 pictures — with **correct, strictly-ramping PTS**, i.e. a
timeline that is right by construction:

```bash
# row format: idr,poc_lsb,pts    (idr=1 only on the first row of a sequence)
awk 'BEGIN{ M=512; half=1800; base=126000
            for(i=0;i<2000;i++){
              poc=(2*i)%M; pts=base+2*i*half
              printf "%d,%d,%d
", (i==0?1:0), poc, pts } }' > table.csv
```

Assert `PL_OFF == 0` and `PL_ON == PL_TOTAL`. Pin the **relationship**
(`on_slot == total`), never a literal — the 1.15.0 CI-fix round's rule.

**This recipe was run against 1.15.1 before filing.** Measured, sourcing
`lib-paff.sh` directly and calling `pf_poc_lattice TABLE`:

| Table | 1.15.1 result | Meaning |
| :--- | :--- | :--- |
| wrapping POC (above) | `PL_ON=256 PL_TOTAL=2000 PL_OFF=1744` | **bug reproduced** — must become `PL_OFF=0` |
| POC pre-unwrapped | `PL_ON=2000 PL_TOTAL=2000 PL_OFF=0` | the fix target; gate is sound once POC is whole |
| unwrapped, one row nudged `+900` | `PL_ON=1999 PL_TOTAL=2000 PL_OFF=1` | **negative control** — must still FAIL after the fix |

`PL_ON=256` is the wrap period exactly (`MaxPicOrderCntLsb / POC step`
= 512 / 2), which is the same arithmetic that explains the field failure.

Include all three tables. The third is what stops the fix degrading into
"always pass":

```bash
# control: identical timeline, POC already whole -> must pass
awk 'BEGIN{ half=1800; base=126000
            for(i=0;i<2000;i++){ printf "%d,%d,%d\n", (i==0?1:0), 2*i, base+2*i*half } }' > ok.csv

# negative control: POC whole, but one picture genuinely off-lattice -> must fail
awk 'BEGIN{ half=1800; base=126000
            for(i=0;i<2000;i++){ pts=base+2*i*half; if(i==900) pts+=900
              printf "%d,%d,%d\n", (i==0?1:0), 2*i, pts } }' > bad.csv
```


> [!NOTE]
> The source carries **6,843 keyframes but only 24 IDRs**. Long-IDR-interval
> open-GOP is the broadcast norm, so shipped 1.15.1 false-FAILs the majority of
> real captures the clinic targets. Since the recorded proving job is this very
> file, the regression also means **the 1.15.0/1.15.1 provenance note at
> `pairfill-paff.sh:29,46,318` no longer describes the shipped code** — fix the
> gate and the comment together, or the next reader inherits the same trap.

### Outcome in the field

After patching, the full ladder was re-run end to end on the same source:

| Run | Result |
| :--- | :--- |
| `mov.sh` on stock 1.15.1 | **exit 1 FAIL** at the POC gate, 55m10s |
| Patched gate, re-run standalone on the already-built artifact | **PASS** `451071/451071`, 26m16s, no rebuild |
| `mov.sh` clean rebuild, patched | **exit 10 REVIEW**, `feed.mov` written, 59m54s |

The rebuilt artifact was **byte-identical in size** to the first build
(24,838,946,221 both times), confirming the mux was deterministic and that
nothing about the *build* ever changed — only the gate's ability to judge it.

### Verified fix (measured, not proposed)

Unwrapping per §8.2.1.1 with `MaxPicOrderCntLsb` taken from the SPS
(`log2_max_pic_order_cnt_lsb_minus4 = 5` → 512 on this source), resetting at each
IDR, was applied to a throwaway copy and measured:

| Target | Shipped 1.15.1 | Patched |
| :--- | ---: | ---: |
| Wrapping synthetic table (2000 pics) | `PL_OFF=1744` | **`PL_OFF=0`** |
| Pre-unwrapped table (control) | `PL_OFF=0` | `PL_OFF=0` |
| One row nudged `+900` (negative control) | `PL_OFF=1` | **`PL_OFF=1`** |
| `feed.part.mov`, 451,071 pictures | `on_slot=3179` | **`on_slot=451071, off=0`** |

The negative control still failing is the load-bearing row: the fix restores the
gate's discrimination rather than disabling it.

Inferring `MaxPicOrderCntLsb` from the data (next power of two above the largest
observed lsb) also works and needs no SPS plumbing, but prefer the SPS value —
inference is only correct when the stream actually uses the full lsb range.

---

## Phases

### Phase 1 — Defect A

1. Add `ffp1` to `lib-probe.sh` with the rationale comment.
2. Convert `lib-rewrap.sh:49–50`.
3. Guard: extend the lint/CI step to flag any `ffp … | head -` whose
   `-show_entries` targets `program=` or omits `-select_streams` on a
   `stream=` query — the multi-line shapes. Failing that, a grep-based test
   asserting `ffp1` at the two known sites.

**Gate 1:** existing suite green; new test 73 red before, green after.

### Phase 2 — Defect B

1. Rewrite `rewrap_predict` per above.
2. Reorder `rewrap_layout` before `rewrap_predict` in `zero-base.sh` and
   `surgical-cut.sh`; move the `layout:` echo with it.
3. Re-measure the 1.15.0 case-file claim (nine predicted / nine observed) under
   the new pre-pass and update `references/source-clinic.md` with whatever the
   corrected pre-pass actually reports.

**Gate 2:** on a PAFF fixture, `predicted == observed` — and the assertion must
be *relationship-based*, not a pinned integer (the 1.15.0 CI-fix round already
learned this: "exact decoder-chatter counts re-pinned as build-measured
relationships").

### Phase 3 — Item C

1. Qualify the doctrine sentence (resolution 1) and record the
   counter-measurement.
2. Implement the `half_ts` pre-flight refusal in `zero-base.sh` (resolution 2).

**Gate 3:** `zero-base.sh` on a PAFF fixture refuses at pre-flight, exit 2,
nothing written, `pairfill-paff.sh` named in the route line.

### Phase 4 — Defect D

1. Unwrap `pic_order_cnt_lsb` into full POC inside `pf_poc_lattice` (or in the
   extractor that feeds it), resetting at each IDR.
2. Capture `log2_max_pic_order_cnt_lsb_minus4` from the SPS in the same
   `trace_headers` pass `pairfill-paff.sh` already runs — no extra decode.
3. Add the interim guard: when the gate cannot evaluate a source, report
   **UNPROVEN/skipped**, never FAILED.

**Gate 4:** `regression.d/76-poc-lattice-wrap.sh` red before, green after; the
negative table still FAILs; existing PAFF tests unchanged.

### Phase 5 — make the lessons structural

Not defect fixes; the changes that stop this class recurring. Each is
independently landable.

1. **UNPROVEN ≠ FAILED, everywhere.** Audit every gate that can exit FAIL and
   split "the artifact is bad" from "I could not judge it." At minimum: the POC
   lattice (D), the prediction contract (B), and `verify.sh` gate (g), which
   already models this correctly and is the reference implementation.
2. **A unit-test lane for pure helpers.** Text-in/text-out functions —
   `pf_poc_lattice`, `rewrap_nudges`, `rewrap_hard_confessions`, the census awk
   blocks — tested from fixture *tables*, no media. Milliseconds per case.
   Defect D would have been caught at authoring time.
3. **Pre-flight the gate's own capability.** Before an hour of muxing, read
   `log2_max_pic_order_cnt_lsb_minus4` and the IDR interval and state whether the
   POC lattice can fit this source. Generalise: any gate with a precondition
   should assert it cheaply, up front.
4. **Reuse the census `trace_headers` pass for the POC gate.** Video bits are
   copied untouched (VCL identity proven by gate (b) on every run), so source POC
   equals output POC picture-for-picture. Removes a whole-file header parse —
   ~20 of the gate's 26 minutes.
5. **Content-hash fallback in gate (g).** When declared properties leave the
   candidate set ambiguous, difference a bounded decoded-stream hash instead.
   Converts a permanent REVIEW into a proven attribution — see the worked example
   above.
6. **Provenance sweep.** Find every `measured` / `proving job` comment in
   `scripts/` asserting a figure no test pins. Pin it or date it.
7. **UX:** reject-or-honour `--audio-keep` on the PAFF path; name the byte size
   and the delete command when a `.part` is retained.

**Gate 5:** each item lands with its own test or is explicitly recorded as
untested and why.

---

## Regression tests

Next free number is **73** (`regression.d/` currently ends at `72-clean.sh`).

- **`73-rewrap-sigpipe.sh`** — mint or reuse a multi-stream mpegts fixture
  (`make-fixtures.sh` already builds two- and three-audio TS files); assert
  `rewrap_layout` exits 0 **and** that `RW_MUX_OPTS` carries a real
  `-mpegts_pmt_start_pid`. Assert the *recovered values*, not just the exit
  code — a `head -1` that silently returned empty would still exit 0 and quietly
  drop layout preservation, which is the same bug wearing a different hat.
  Because the underlying failure is a race, run the assertion in a loop
  (≥5 iterations) under `set -euo pipefail`.
- **`74-predict-contract.sh`** — on a PAFF fixture, assert
  `rewrap_predict` output equals the build's observed nudge count. Relationship,
  not pinned integer.
- **`75-zero-base-paff-refusal.sh`** — Phase 3 gate: pre-flight refusal on
  `half_ts=yes`, exit 2, no bytes written.
- **`76-poc-lattice-wrap.sh`** — Phase 4 gate: table-driven POC-wrap unit test,
  plus a negative table that must still FAIL. Full recipe in Defect D above; it
  needs no media fixture.

---

## What the field run revealed

Beyond the four items above, one capture through the whole ladder exposed
structural patterns worth acting on.

### The pattern: every defect is in the honesty machinery

Not one defect was in muxing, copying or timeline repair. The video bits came
through bit-identical on the first attempt and every attempt after. **All three
defects were in the code that judges whether the work was good.**

They split into two failure modes, and the second is the dangerous one:

| Mode | Defect | What the operator sees |
| :--- | :--- | :--- |
| **Silent** failure | A | exit 1, no message, no route, no evidence |
| **Spurious** failure | B, D | a confident, specific accusation that is false |

A silent failure wastes an hour. A spurious one is worse: it tells the operator
their *source* or their *build* is defective when the defect is in the ruler. D
did exactly that — it reported 447,892 pictures "off their presentation slot" on
a file whose timeline was provably correct. An operator without the patience to
audit the gate would have concluded the capture was damaged, or reached for
Rung 4 and re-encoded a perfectly lossless master.

> [!IMPORTANT]
> **The rule this round earns:** a gate that *cannot evaluate* a source must
> report **UNPROVEN / skipped**, never **FAILED**. FAILED is a claim about the
> artifact. Absence of evidence is a claim about the gate. Conflating them
> converts tool limitations into false accusations against the user's material —
> and in a plugin whose entire pitch is "verified, never re-encodes," that is
> the worst available failure.

This applies to B (`OBS != PRED` when the prediction modelled the wrong mux) and
D (lattice unfittable because POC was never unwrapped) identically.

### The provenance trap

D is a **regression against the plugin's own recorded proving job**, on the very
file that proving job used (`pairfill-paff.sh:29` — "23.7 GB PAFF 1080i25,
451,071"). The comments at `:29`, `:46` and `:318` still assert
`451,071/451,071 on-slot`, which the shipped code cannot produce.

**Comments that record measurements are load-bearing and can rot silently.** A
provenance note asserting a number no test pins is a claim with no guard. Either
pin it (`76-poc-lattice-wrap.sh` does this for the mechanism) or date it and mark
it historical. Recommend a sweep for other `measured`/`proving job` claims in
`scripts/` that no test currently enforces.

### The suite could not have caught D — and cheap tests would have

`pf_poc_lattice` is a pure function over a CSV table. It needs no media, no
libx264, no mux and no decode. The wrap bug reproduces in **milliseconds** from
a 2000-row text file (recipe in Defect D).

The suite is media-fixture-shaped: mint a `.ts`, run a script, assert on the
result. That design cannot cheaply cover a helper whose input is a table, so the
helper went uncovered — and the one gate the doctrine calls "the strongest
correctness evidence a field fill can carry" shipped broken.

**Recommendation: add a unit-test lane** for the pure helpers in `lib-paff.sh` /
`lib-rewrap.sh` / `lib-probe.sh` — functions that take text and emit text.
`pf_poc_lattice`, `rewrap_nudges`, `rewrap_hard_confessions` and the census awk
blocks all qualify. They are the cheapest tests in the repo and they guard the
logic that decides whether an hour of muxing gets blessed.

### Cost and gate ordering

Measured on this capture (23.68 GB, 451,071 pictures):

| Stage | Cost |
| :--- | ---: |
| `ts-health` whole-file transport + timeline | **54 s** |
| `probe.sh` | seconds |
| `lead-check.sh` (bounded decode + gop-probe) | **~37 min** |
| `zero-base.sh` pre-flight + prediction | ~2 min |
| Audio export, 4 tracks, one decode pass | **38 s** |
| POC-lattice gate alone (whole-file `trace_headers`) | **26 min** |
| `mov.sh` full ladder | **~60 min** |

Two things stand out.

**1. The most expensive gate runs last, and it can be predicted first.** D fails
after the entire build. Whether it *can* fit is knowable from the source in a
bounded probe: read `log2_max_pic_order_cnt_lsb_minus4` from the SPS, measure the
IDR interval, and if `IDR interval >= MaxPicOrderCntLsb / POC step` the gate needs
unwrapping. That is a few seconds of work that decides an hour. **Pre-flight the
gate's own capability, not just the source's shape.**

**2. The POC gate re-reads what the census already read.** `pairfill-paff.sh`
runs a whole-file `trace_headers` census on the **source**, then the POC gate runs
another whole-file `trace_headers` on the **output**. But pairfill copies video
bits untouched — VCL identity is proven by `verify.sh` gate (b) on every run — so
the per-picture POC sequence in the output *is* the source's. The gate could reuse
the census extraction and need only a cheap `ffprobe` PTS list from the output.
**That removes an entire whole-file header parse — roughly 20 of the gate's 26
minutes, a third of the total ladder runtime.**

`lead-check.sh` at ~37 minutes also deserves a look: it is the single most
expensive stage in `/clean`, and on this source it produced a finding
(`--video-drop-lt 0`) that discarded nothing.

### The attribution hole in `verify.sh` gate (g)

Gate (g) could not decide which source audio track the output track came from:

```
a:0 source-baseline AMBIGUOUS — the source has 4 audio track(s) and no property
separated them; track(s) [0 1 2 3] equally consistent with this output track
```

Four MP2 tracks, same codec, channels, rate and language tag. The gate correctly
refused to call it damage ("an unidentified baseline cannot prove damage —
REVIEW, never an unwaivable FAIL") — that restraint is right and should be kept.

But the ambiguity is **resolvable by content**, and cheaply. Decoding each
candidate to a stream hash disambiguates instantly:

```
feed.mov mp2 track      -> debe48d64d57781411ac43707b40f7be
source a:0 (PID 0xbd7)  -> debe48d64d57781411ac43707b40f7be   MATCH
source a:1 (PID 0xbd8)  -> d476d8173910f8d9f31c798085ce082a
source a:2 (PID 0xbd9)  -> 85cbe45aa5562bfc2dbbf844dbf80b1a
source a:3 (PID 0xbda)  -> 4f69196fa6b39f3ff5b2b5faeb9be7d6
```

**Recommendation:** when metadata leaves the candidate set ambiguous, fall back to
a bounded decoded-stream hash over the first N seconds of each candidate. It
turns a permanent REVIEW into a proven attribution. Gate (g) currently reasons
only over *declared properties*; on broadcast multiplexes those are routinely
identical across tracks, so this ambiguity is the norm, not the exception.

### UX traps found in passing

- **`--audio-keep` is silently inert on the PAFF path.** `mov.sh:458` prints a
  note, but the flag is accepted and ignored, and the rung picks `a:0`
  regardless. An operator who passes `--audio-keep 2` gets track 0 and a note
  mid-scroll. Either reject the flag on that path or honour it.
- **`zero-base.sh` builds 23.68 GB before refusing a PAFF source.** The
  `half_ts=yes` profile is already known at pre-flight. Refuse there (Item C,
  resolution 2).
- **`.part` artifacts accumulate at 24.8 GB each.** Two refused runs consumed
  ~48 GB. The retention is correct — evidence must survive — but the message
  should state the size and name the delete command, because the operator will
  otherwise discover it as a full disk.

---

## Operator playbook — broadcast PAFF captures

Distilled from this run. Applies to satellite/backhaul `.ts` with field-coded
H.264 and multiple audio tracks.

1. **`/clean` first, and read two fields:** `paff=` and `start_time=`. They
   determine everything downstream. PAFF means the `.mov` path is
   `pairfill-paff`, never a plain copy.
2. **Do not chase a non-zero `start_time` on a PAFF source.** The floor is the
   first frame's reorder delay, the prize is milliseconds, players rebase it
   away, and `zero-base.sh` hard-stops on pair-timestamped PAFF anyway. On this
   capture the entire payoff was **40 ms**.
3. **Treat "black lead" findings as a report, not an instruction.** Here
   `lead-check` reported 0.760 s of black, but the splice census put the program
   keyframe at packet index 0 — the cut would have discarded 40 ms of audio and
   one decoder-discarded leading-B, and the "black" was a fade-up that is
   program content. **Read the census, not the headline.**
4. **Census the audio *before* the remux.** Export every track once (single
   decode pass keeps them sample-locked), then measure loudness, null the pairs,
   and cross-correlate. On this capture that revealed the four tracks were **one
   program at three latencies plus a silent slot** — and that one of them slips
   two MP2 frames mid-show. It also pre-computed the fingerprints that later
   resolved `verify.sh` gate (g). **This is the highest-value hour in the whole
   process and it costs 38 seconds of export.**
5. **Never trust a zero-offset null between broadcast tracks.** A few
   milliseconds of path latency makes identical programs look completely
   uncorrelated — the residual comes out *louder* than either source, which reads
   as "different content." Always cross-correlate for lag before concluding
   anything. Validate the null method with a self-null control (`-inf` expected).
6. **Budget ~1 hour for a `.mov` from a 24 GB PAFF source**, and run it
   detached.
7. **Keep the `.part` on a refusal.** If the refusal turns out to be a gate
   defect, the artifact is already built and the gate can be re-run against it
   standalone — 26 minutes instead of a 60-minute rebuild.
8. **A REVIEW with negative deltas is not damage.** When gate (c)/(e) report the
   *output* has fewer decode errors than the *source* under identical windows,
   and muxer-stage counts are 0/0 on both, that is inherited capture noise. Read
   the deltas before reaching for a re-encode.
9. **`feed.ts` stays the master.** Every correction considered in this run was
   either cosmetic, content-discarding, or refused. The `.mov` is an access copy.

---

## Session log — what was actually run

Chronological, 2026-08-26 → 2026-08-27. Every command read-only with respect to
the source; the source was never modified.

| # | Action | Result |
| ---: | :--- | :--- |
| 1 | `clean.sh feed.ts` | killed mid-`lead-check` (harness), partial |
| 2 | `ts-health.sh feed.ts` | 54 s — transport pristine, PAFF `half_ts=yes` |
| 3 | `clean.sh feed.ts` (full) | 37m53s — exit 10, 3 findings |
| 4 | `probe.sh` / `clock.sh 0.760` | PAFF confirmed; black lead is a fade-up |
| 5 | `zero-base.sh` | **exit 1, silent — Defect A** |
| 6 | Diagnose A; patch `lib-rewrap.sh` on a throwaway copy | SIGPIPE confirmed 5/5 |
| 7 | `zero-base.sh` (patched) | exit 1 **HARD STOP** — mux confessed invented timing; **Defect B** surfaced (predicted 0, observed 11) |
| 8 | Export 4 audio tracks, one decode pass | 38 s — 4 × 24-bit WAV |
| 9 | Loudness / astats / L−R census | a4 silent; a1–a3 ≈ −25 LUFS, LRA 3.3 |
| 10 | Decoded-PCM MD5s | all four distinct |
| 11 | Pairwise nulls at zero offset | residual −24.5 dB — *looked* uncorrelated |
| 12 | Self-null control | `-inf` — method validated |
| 13 | FFT cross-correlation, 4 windows | **r = 0.99+** — one program, three latencies |
| 14 | Bisection on the a1↔a2 lag | two 1152-sample slips, 1h48m27.6s and 1h57m29.6s |
| 15 | `mov.sh` (stock gate) | 55m10s — **exit 1 FAIL**, POC lattice 3179/451071 |
| 16 | Diagnose D; patch `pf_poc_lattice`; 3 synthetic tables | bug reproduced and fixed in ms |
| 17 | Re-run POC gate on the existing `.part` | 26m16s — **PASS 451071/451071** |
| 18 | `mov.sh` clean rebuild (patched) | 59m54s — **exit 10 REVIEW**, `feed.mov` written |
| 19 | Decoded-hash the output MP2 track | `debe48d6…` = PID 0xbd7 — gate (g) resolved |

Roughly **3.5 hours of compute**, of which ~55 minutes was spent producing a
FAIL that the artifact never deserved.

---

## Appendix — field run, verbatim

Clinic verdict on the untouched source (`clean.sh`, exit 10):

```
transport: CC=0 corrupt=0 PES=0 scrambled=0
timeline:  napts=225439 nadts=225439 back=0 dup=0 gaps=0 wrap=0 prekey=0
video packets=451071  keyframes=6843 (max gap 1.96s)
audio streams (missing-ts/packets): 2=0/376056 3=0/376054 4=0/376057 1=0/376054
[timeline] video missing timestamps (N/A PTS=225439 DTS=225439; PAFF/half_ts=yes)
```

`napts`/`nadts` are exactly 0.500 of video packets — the pair-timestamped PAFF
signature, correctly classified. Transport is clean across all 23.68 GB.

`zero-base.sh` mux log (14 lines) after the Defect A patch:

```
hard confessions      : 1   ← [mpegts] Timestamps are unset … for stream 0
non-monotonic nudges  : 11  ← all +1 tick, video, equal-DTS sites
decoder chatter       : 2   ← reference-frame over-declaration; reorder buffer to 2
```

Head structure, for anyone building a PAFF fixture to match:

```
idx 0 : pts 0.240  dts 0.080  K__   ← the splice IDR, packet index 0
idx 1 : N/A        N/A        ___   ← its untimestamped PAFF mate
idx 2 : pts 0.200  dts 0.120  ___   ← leading B; PTS precedes the IDR
idx 3 : N/A        N/A        ___   ← its mate
a:0–3 : pts 0.200 ×4                ← all four MP2 tracks
```

Note that packet 2's PTS (0.200) preceding packet 0's (0.240) is what pins
`format.start_time` to 0.200 — the leading-B rule, behaving exactly as
documented.

---

## Appendix — the delivered artifact

Produced 2026-08-27 by `mov.sh` with Defect D patched. **Not reproducible on
stock 1.15.1** — the POC gate fails it.

```
feed.mov   24,838,946,221 bytes
  stream 0  h264       avc1    1920x1080   9025.280 s   VCL bit-identical to source
  stream 1  pcm_s24le  in24    48 kHz/2    9025.296 s   QuickTime access track
  stream 2  mp2        .mp2    48 kHz/2    9025.296 s   original, bit-exact, PID 0xbd7
```

`mov.sh` exit 10 REVIEW. Every review reason accounted for:

| Gate | Source | Output | Reading |
| :--- | ---: | ---: | :--- |
| (c) spot-window decode errors | 16 | 2 | delta −14 — output cleaner; inherited |
| (e) scrub, decoder-class | 35 | 7 | delta −28 — inherited |
| (e) scrub, muxer-stage | 0 | 0 | 0/0 — no torn timeline |
| (g) audio attribution | — | — | ambiguous on declared properties; **resolved by content hash** |

Passed outright: POC lattice `451071/451071 off=0`; gate (b) VCL payload
bit-identical (**lossless proven**); gate (d) timeline `N/A=0`, monotonic,
histogram `450878x1800 + 193x3600`; gate (f) A/V parity `Δ 0.016 s` within
`0.25 s`; census `planned=3 written=3 codecs=ok`; master-purity clean.

`verify.sh --full` (whole-file presentation order + MKV strict-mux) for archival
sign-off has **not** been run.

The companion archival record for the capture itself — source integrity, the
four-track audio census, the frame-slip locations — lives beside the media as
`feed.ts.audio-census.md`.

