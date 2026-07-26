# Interlacing, Timestamps & the Glitch-Repair Ladder

The category that breaks silently: the remux *succeeds*, the file *opens*, then
the picture glitches or scrubbing tears. The cause is almost always container
timing, not the video, and the fix never re-encodes the picture. `diagnose.sh`
and `rebuild-paff.sh` are the executable forms of this file.

## Contents
- Identify the field structure
- The `-field_order` and `fiel` facts
- Timestamp-defect taxonomy
- Diagnostic ladder (manual commands)
- Repair ladder (genpts → elementary rebuild)
- Field-rate / timescale table
- The QuickTime "duration too long for timebase" error
- MKV millisecond timebase → coarse MOV timescale (benign alternation)

## Identify the field structure

```
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,field_order -of default=nw=1 IN
```
- `progressive` → no interlacing concern.
- `tt`/`bb` + mediainfo `picture structure: Frame` → **frame-coded interlaced**;
  almost always copies cleanly.
- `tt` + mediainfo `Scan type, store method: Separated fields` → **PAFF /
  field-coded** (each frame = two field pictures). The fragile profile.

**Programmatic tell (no mediainfo required):** field-coded PAFF shows a
**coded-picture rate ≈ 2× the container frame rate** — each field picture is its
own access unit, so ~60 AU/s on 29.97p content (or ~50 on 25p) is the signature.
`probe.sh` measures this from a bounded packet window (demux only) and is what
routes PAFF to the right timeline repair instead of genpts. `field_order`
tt/bb corroborates but is not required — some captures report `unknown` while
still being field-coded, so the rate ratio is the decisive test.

**COUNT EVERY PACKET, timestamped or not** (post-mortem 2026-07-25). Real
broadcast PAFF often carries PES timestamps only on the FIRST field of each
pair — the second field of every pair has no PTS and no DTS at all (9,763 of
19,527 packets on the incident capture). A rate computed from timestamped
packets alone reads ~1× on exactly those captures and reports `paff=no`: the
false negative that routed a broken timeline to a straight copy. The numerator
must count ALL packets; only the time span comes from the timestamped ones. The
untimestamped **fraction** is itself decisive: **~0.5 = the pair signature**
(`lib-paff.sh` exports it as `PF_NOPTS_FRAC` / `PF_HALF_TS`).

```
# coded-picture rate over the first 240 packets (no decode) — n counts ALL packets
ffprobe -v error -select_streams v:0 -read_intervals "%+#240" \
  -show_entries packet=pts_time,dts_time -of csv=p=0 IN \
  | awk -F, '{t=$1; if(t=="N/A"||t==""){t=$2}; n++; if(t=="N/A"||t==""){miss++; next}
      if(!s){mn=mx=t;s=1}else{if(t<mn)mn=t;if(t>mx)mx=t}}
      END{if(s&&mx>mn)printf "%.3f AU/s  untimestamped %d/%d\n",(n-1)/(mx-mn),miss,n}'
# compare to avg_frame_rate; ratio ~2.0 = PAFF; untimestamped ~half = pair class.
```

## `-field_order` and `fiel` (verified, ffmpeg 6.1.1)

- **Do not add `-field_order tt`** to a copy mux — it's an encoder-side option
  that does nothing useful on `-c copy` (tested: ignored, not fatal).
- ffmpeg writes **no container `fiel` atom** on copy. Field order is preserved
  via the **bitstream** (VUI/SEI) and read back correctly by ffprobe. Don't rely
  on a `fiel` box being present. **And none is needed for playback**: verified
  2026-07-25 on real field-coded (tt) deliverables — AVFoundation full-screen
  motion is smooth with no combing and no field-order shimmer, so QuickTime
  deinterlaces from the bitstream alone (QTFF audit 3a/C24).

## Timestamp-defect taxonomy (symptom → cause → catch)

| Symptom | Cause | Catch |
|---------|-------|-------|
| Muxes fine but glitches throughout / tears on scrub | Missing/unset PTS the MOV muxer wrote with garbage timing | MKV strict-mux test; **N/A-PTS count + duration histogram on the output** (verify.sh d) |
| MOV mux log says `pts has no value` / `Timestamps are unset in a packet` / `Non-monotonic DTS` | **The muxer's confession**: it INVENTED timing for packets the source never timestamped. On a copy mux this is a HARD STOP, never cosmetic — the incident files logged `pts has no value` ×4,120 and shipped "verified" | remux.sh/dual-track.sh capture the mux log and refuse to bless the output |
| ~Half the video packets carry no PTS and no DTS, strictly alternating with timestamped ones | **Pair-timestamped PAFF**: PES timestamps only on the first field of each pair; the mate's true PTS is exactly +1 field | `PF_NOPTS_FRAC`≈0.5 (`PF_HALF_TS=yes`) → `pairfill-paff.sh` |
| Repaired file plays but motion is subtly shuffled / juddery; every hash gate passes | **Decode-order playback**: a constant-rate restamp (rebuild-paff) set PTS=DTS on a stream with a B-pyramid — presentation order = decode order | framemd5 presentation-SEQUENCE compare (verify.sh --full); prevention: `pf_reorder_scan` makes rebuild-paff refuse reordered streams |
| Scrub-only glitches, normal playback OK | Non-monotonic DTS (backward jumps) | DTS monotonicity scan |
| Stutter/sync drift; ffmpeg logs `dts ... X >= X` throughout | **Duplicate (equal) DTS** — field-coded stream on a non-integer timebase (e.g. 1/16000 at 59.94) collapses adjacent fields onto the same DTS | decode-to-null flood + DTS monotonicity scan (`<=`) |
| MKV mux fails: `Timestamps are unset in a packet` | Missing timestamps | MKV strict-mux test |
| Flood of `error while decoding` / `concealing errors` | Damaged capture (dropped packets) — **not** fixable by remux | decode-to-null tally |
| A few `mmco: unref short failure` only | Benign reference bookkeeping; carries through losslessly — but it explains ONLY itself: the same gates that show mmco noise also show timeline defects, and the noise MASKS them | replicate on the source with **matching counts**, then still prove the timeline independently |

## Diagnostic ladder (run in order; `diagnose.sh` automates this)

**(1) Source integrity:**
```
ffmpeg -nostdin -v error -i IN -map 0:v:0 -f null - 2>&1 | sort | uniq -c | sort -rn | head
```
Flood of decode/concealing errors scaling with length → damaged source,
re-capture. A few `mmco` lines → fine, continue.

**(2) MKV strict-mux test (decisive):**
```
ffmpeg -nostdin -i IN -map 0:v:0 -map "0:a?" -c copy mkvtest.mkv
```
Fails `Timestamps are unset` → **missing timestamps**. Succeeds but MOV still
glitches → timing/AU issue → rebuild.

**(3) DTS monotonicity (and its blind spot):**
```
ffprobe -v error -select_streams v:0 -read_intervals "%+#5000" -show_entries packet=dts -of csv=p=0 IN \
  | awk -F, 'NR>1 && $1!="N/A" && p!="N/A"{ if($1<p)bk++; else if($1==p)du++ } {p=$1} END{print "dup="du+0" back="bk+0}'
```
Count **both** backward (`<`) and **duplicate/equal** (`==`) DTS — ffmpeg treats
`X >= X` as invalid, so equal DTS is a defect, not "monotonic." **Blind spots:**
the awk skips `N/A`, so it can't see *missing* timestamps (step 2 catches those),
and it only samples a window — a whole-file duplicate-DTS problem also shows as a
flood of `non monotonically increasing dts` in step (1)'s decode-to-null output.

## Repair ladder

**Rung 2 — regenerate timestamps (`remux.sh --genpts`):**
```
ffmpeg -nostdin -fflags +genpts -i IN -map 0:v:0 -map 0:a:0 \
  -c:v copy -c:a copy \            # -c:a pcm_s16le if MP2/MP1/DTS
  -movflags +faststart -f mov OUT.mov
```
Harmless on a clean file (only fills what's absent). Play through and scrub.
**No help on the pair-timestamped class:** genpts derives PTS from DTS, and the
pair-mates carry NEITHER — they stay unset, the MOV muxer invents their timing,
and the mux log confesses (`pts has no value`). That confession is a hard stop
(remux.sh enforces it); the repair is `pairfill-paff.sh`.

**Guilty-until-proven on field-coded (PAFF) H.264.** This is the trap behind the
corrupted-file post-mortem: genpts produced a file that *passed* the strict
MKV-mux test and played start-to-finish, but **mux-valid ≠ seekable** — the
strict-mux test only proves timestamps are present and monotonic, not that the
container's seek index/edit list lands correctly. On a player scrub it tore. So
for PAFF, do **not** ship genpts output on the strength of the mux test:
- prefer Rung 3 (field-rate rebuild) directly — `probe.sh`/`diagnose.sh` route
  there automatically; or
- if you do use genpts, gate the result through `verify.sh`'s **scrub test**
  (accurate off-keyframe seeks + keyframe-spacing check) before deleting the
  source. An ffmpeg keyframe-accurate seek (`-ss` before `-i`) stayed clean on
  the broken file — it snaps to a keyframe — so it does not substitute for the
  scrub test.

**Rung 3-PAIR — pair-mate PTS fill (`pairfill-paff.sh IN OUT.mov`):**
THE repair for the pair-timestamped class (post-mortem 2026-07-25) — and the
preferred one whenever real PTS survives on a reordered stream, because it
**keeps every real PTS** (which carries the reorder pyramid) instead of
flattening it. The timing is fully derivable: the pairing is strict (verify:
zero consecutive untimestamped packets across the whole file), so every
untimestamped field is the pair-mate of the timestamped field before it and its
true PTS is exactly +1 field duration. Fill each mate, synthesize a clean
monotonic DTS ramp anchored to the first real PTS, copy the video bits
untouched. The proven command (90 kHz clock, 59.94 fields/s → 1501/1502-tick
fields, 15015-tick pyramid pre-roll; the script derives these per stream):

```
ffmpeg -nostdin -y -drc_scale 0 -i IN.ts \
  -map 0:v:0 -map 0:a:0 -map 0:a:0 \
  -c:v copy \
  -bsf:v 'setts=pts=if(lt(PTS\,-8000000000000000000)\,PREV_OUTPTS+1501\,PTS):dts=if(lt(PREV_OUTDTS\,-8000000000000000000)\,PTS-15015\,PREV_OUTDTS+1501+mod(N\,2))' \
  -c:a:0 pcm_s24le -c:a:1 copy \
  -disposition:a:0 default -disposition:a:1 0 \
  -movflags +faststart+write_colr -f mov OUT.mov
```

Preconditions (the script checks the whole file and refuses on a miss):
first video packet carries a real PTS; untimestamped packets never occur
back-to-back; timebase × field rate yields whole-tick pairs.

**setts lessons — each cost a broken build in the incident:**
- Unset timestamps reach `setts` expressions as **INT64_MIN, not NaN** — test
  `lt(PTS,-8e18)`, never `isnan()`. An `isnan()` filter matches nothing,
  silently does nothing, and writes the broken file again with exit 0.
- Timestamp expressions must be **domain-relative**: anchor the DTS ramp to the
  first real PTS (`PTS-preroll`), never to absolute source-clock values —
  ffmpeg rebases PTS near zero, discards out-of-domain DTS, and the muxer
  guesses again.
- Therefore **verify the OUTPUT's timestamps, never the command's exit code**:
  0 N/A-PTS packets, strictly monotonic DTS, a duration histogram of exactly
  the two field durations. `pairfill-paff.sh` runs these gates before blessing.

**Rung 3 — full timeline rebuild (`rebuild-paff.sh IN OUT RATE [TS]`):**
Discard container timestamps and re-derive at the true field rate. Video stays
bit-identical; the H.264 parser rebuilds proper access units on re-ingest.

**SCOPE LIMIT (post-mortem 2026-07-25): only legitimate when NO reorder pyramid
survives.** Re-stamping at a constant rate sets PTS = DTS, i.e. presentation
order = decode order. On a stream with B-fields/B-frames (PTS−DTS offsets of
{0, 3003, 6006, 9009, 15015} ticks and ~1,499 backward PTS steps per 3,000
packets on the incident capture) that plays the pictures **shuffled** — a
different way of being broken, and one that decodes clean, scrubs clean, and
passes every hash gate. Only a framemd5 presentation-ORDER compare sees it.
`rebuild-paff.sh` therefore scans the source first and **refuses** when the
surviving timestamps show reordering (use `pairfill-paff.sh`, which keeps them);
`--force` overrides only with proof that decode order == display order.
```
# 1) video -> raw Annex-B (TS/PS: no bsf; MKV/MOV: -bsf:v h264_mp4toannexb)
ffmpeg -nostdin -i IN -map 0:v:0 -c:v copy -f h264 tmp.h264
# 2) audio -> PCM/WAV (starts at sample 0, stays aligned)
ffmpeg -nostdin -i IN -map 0:a:0 -c:a pcm_s16le tmp.wav
# 3) rebuild from zero at the field rate
ffmpeg -nostdin -fflags +genpts -r 60000/1001 -i tmp.h264 -i tmp.wav \
  -map 0:0 -map 1:0 -c:v copy -c:a pcm_s16le -metadata:s:a:0 language=eng \
  -video_track_timescale 60000 -movflags +faststart -f mov OUT.mov
# verify BEFORE deleting tmp.* — never auto-rm on failure
```

Rebuild variants:

- **Multiple audio tracks** (SAP/secondary): extract each one
  (`-map 0:a:1 -c:a pcm_s16le tmp.a1.wav`, …) and map them all back in step 3
  (`-i tmp.a1.wav … -map 2:0`) — a single-track rebuild silently drops the
  rest. `rebuild-paff.sh` rebuilds every audio track automatically.
- **MOV-copyable audio (AC-3 / E-AC-3 / AAC)**: extract the raw bitstream
  instead and `-c:a copy` it in step 3 (`-map 0:a:0 -c:a copy tmp.ac3`) —
  preserves the original audio bit-exact through the rebuild instead of
  decoding it (the dual-track provenance logic applied to Rung 3).
- **Post-fix check**: if the source failed the MKV strict-mux test, confirm the
  rebuilt output now *passes* it — that closes the loop on the diagnosis.

## Field-rate / timescale table

Each field-picture is one access unit at the field rate.

| Source | `-r` (field rate) | `-video_track_timescale` |
|--------|-------------------|--------------------------|
| 1080i59.94 (NTSC) | `60000/1001` | `60000` |
| 1080i50 (PAL) | `50` | `50000` |
| 720p59.94 progressive | `60000/1001` | `60000` |
| 29.97p progressive | `30000/1001` | `30000` |
| 23.976p progressive | `24000/1001` | `24000` |

Sync: video and audio share the source `start_pts`, so rebuilding both from zero
keeps them aligned. For a genuine inter-stream offset, reapply with `-itsoffset`.

## "Duration too long for timebase" (QuickTime)

```
FATAL ... file duration too long for timebase ... Choose a different timebase
with -video_track_timescale
```
Common on MKV (millisecond timebase) sources. Set `-video_track_timescale` to a
clean value (table above). If it persists after fixing the video track, the
overflow is on another track — usually a `mov_text` subtitle inheriting the 1 ms
timebase; sidecar the subtitle instead (see `color-hdr-subs.md`).

## MKV millisecond timebase → coarse MOV timescale (benign alternation, not judder)

Matroska quantizes timestamps to **1/1000 s**. A `-c copy` MKV→MOV keeps those
ms-rounded timestamps, so the MOV muxer picks a **coarse video timescale**
(probed 2026-07-26, ffmpeg 8.1.2: `1/16000` for a 23.976p MKV) and the `stts`
shows **alternating durations** — 672/656 ticks = the source's own 42/41 ms
rounding, ±0.5 ms around the true 41.7 ms frame. The alternation is
**source-baked**: it is already in the MKV's timestamps, it is imperceptible,
and it is NOT judder introduced by the remux (C68; fixture pin lands with the
audit's 5-4g item).

Two possible responses, and only one is ever legitimate:

- **Conventionality fix (cosmetic, optional):** `remux.sh --timescale <base>`
  sets `-video_track_timescale` to the conventional base — `probe.sh`'s
  ms-timebase advisory detects the 1/1000 source and computes the hint
  (`PR_MS_TB` / `PR_TS_HINT`, e.g. 24000). Probed 2026-07-26: video packets
  bit-identical through it (streamhash match), and the same 42/41 ms durations
  simply re-expressed as 1008/984 ticks — the timescale becomes conventional,
  the source-baked alternation remains, because it lives in the timestamps,
  not the base.
- **NEVER a constant-rate restamp.** "Smoothing" the alternation means
  restamping every packet, and on a reorder-pyramid stream that sets
  presentation order = decode order — shuffled motion (Rung 3's scope limit
  above). `diagnose.sh`'s prohibition applies unchanged: cosmetic ms-rounding
  is never worth a broken presentation order.

Do not confuse this with the **duplicate-DTS collapse** in the taxonomy above
(a field-coded stream on a non-integer timebase collapsing adjacent fields onto
the *same* DTS): the benign class keeps DTS strictly monotonic with two
adjacent duration values; the defect class shows equal DTS and floods
`dts X >= X`. Likewise, scrub-harness null-muxer complaints on ms-quantized
sources that reproduce identically on the untouched source are harness
artifacts, not a torn timeline (C69) — `verify.sh` gate (e) classifies them,
and the timeline is then proven by the (d) + strict-mux + `--full` triple.

## Discontinuous source — the gap-collapse audio desync

A different failure from PAFF, and a more insidious one because *the mux
succeeds and the picture is perfect*. When a capture **drops frames**, the source
records a **forward timestamp discontinuity**: the clock jumps ahead and the next
frame's DTS is more than one frame later. The timestamps stay **present and
monotonic**, so every mux test passes — but a blind `-c copy` desyncs the audio:

- **Video survives.** It carries per-frame timestamps, so the jump is preserved
  and the video timeline still spans the true real-time duration, gaps and all.
- **Raw PCM cannot — as ffmpeg writes it.** QTFF itself *can* represent gaps
  (a track may carry multiple edits with empty edits between segments, and
  ffmpeg does write an initial empty edit for a start delay — probed
  2026-07-25). But ffmpeg's muxer writes **no mid-stream empty edit per drop**
  on a copy: it packs the surviving PCM samples end-to-end, so the audio
  timeline is **shorter** than the video by the total dropped time, and slides
  progressively earlier. The limitation is the writer, not the container.
- **Packetized tracks (AC-3/DTS/MP2) drift *less* than PCM** — a frame-based codec
  tolerates gap collapse better than a raw sample stream. A per-track duration
  spread is the fingerprint: a clean remux has identical durations on every track.

This is why "lossless stream copy" stops being safe on a discontinuous source,
and why the container that swallowed the gaps (MOV) is *less* strict than one that
would reject them. The mux succeeding is not evidence that sync survived.

### Detect it

`scripts/diagnose.sh` step 4 (and `scripts/probe.sh`) scan the video DTS for
forward jumps larger than ~1.5 frame durations (`lib-paff.sh` `disc_scan`). The
manual one-liner:

```bash
ffprobe -v error -select_streams v:0 -show_entries packet=dts_time -of csv=p=0 IN \
  | awk -v f=0.033367 'NR>1{d=$1-p; if(d>1.5*f) printf "gap @ %.3f  Δ=%.3fs\n",p,d} {p=$1}'
```

`scripts/verify.sh` then runs an always-on **A/V duration-parity gate**: for one
program every audio track should match the video length; a track that reads short
(beyond `RTM_SYNC_TOL`, default 0.25 s) is flagged REVIEW — the cheap post-remux
catch the original pipeline lacked.

### Fix it — `scripts/resync.sh IN OUT.mov`

The corrected procedure keeps the **video a bit-identical copy** and re-times the
audio to the picture by filling the gaps:

```bash
ffmpeg -fflags +genpts -i IN \
  -map 0:v:0 -c:v copy \
  -map 0:a -af aresample=async=1:first_pts=0 -c:a pcm_s24le \
  -movflags +faststart OUT.mov
# then confirm: scripts/verify.sh IN OUT.mov   (the duration-parity gate)
```

`aresample=async=1` inserts silence at each gap so the audio stays pinned. This is
an **explicit, human-invoked** tool, not a ladder rung, because it *re-times the
audio* (silence added) — video stays lossless, audio does not. If you also need
the bit-exact original audio, the only frame-accurate fix is a re-mux **from the
still-existing source** with the same gap handling; a desynced copy can recover
the gaps the picture timeline shows but a residual can remain at the tail.
