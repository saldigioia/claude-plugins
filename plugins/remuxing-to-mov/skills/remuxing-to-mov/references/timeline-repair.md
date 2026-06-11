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

## Identify the field structure

```
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,field_order -of default=nw=1 IN
```
- `progressive` → no interlacing concern.
- `tt`/`bb` + mediainfo `picture structure: Frame` → **frame-coded interlaced**;
  almost always copies cleanly.
- `tt` + mediainfo `Scan type, store method: Separated fields` → **PAFF /
  field-coded** (each frame = two field pictures). The fragile profile.

## `-field_order` and `fiel` (verified, ffmpeg 6.1.1)

- **Do not add `-field_order tt`** to a copy mux — it's an encoder-side option
  that does nothing useful on `-c copy` (tested: ignored, not fatal).
- ffmpeg writes **no container `fiel` atom** on copy. Field order is preserved
  via the **bitstream** (VUI/SEI) and read back correctly by ffprobe. Don't rely
  on a `fiel` box being present.

## Timestamp-defect taxonomy (symptom → cause → catch)

| Symptom | Cause | Catch |
|---------|-------|-------|
| Muxes fine but glitches throughout / tears on scrub | Missing/unset PTS the MOV muxer wrote with garbage timing | MKV strict-mux test |
| Scrub-only glitches, normal playback OK | Non-monotonic DTS (backward jumps) | DTS monotonicity scan |
| Stutter/sync drift; ffmpeg logs `dts ... X >= X` throughout | **Duplicate (equal) DTS** — field-coded stream on a non-integer timebase (e.g. 1/16000 at 59.94) collapses adjacent fields onto the same DTS | decode-to-null flood + DTS monotonicity scan (`<=`) |
| MKV mux fails: `Timestamps are unset in a packet` | Missing timestamps | MKV strict-mux test |
| Flood of `error while decoding` / `concealing errors` | Damaged capture (dropped packets) — **not** fixable by remux | decode-to-null tally |
| A few `mmco: unref short failure` only | Benign reference bookkeeping; carries through losslessly | ignore |

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

**Rung 2 — regenerate timestamps (try first; `remux.sh --genpts`):**
```
ffmpeg -nostdin -fflags +genpts -i IN -map 0:v:0 -map 0:a:0 \
  -c:v copy -c:a copy \            # -c:a pcm_s16le if MP2/MP1/DTS
  -movflags +faststart -f mov OUT.mov
```
Harmless on a clean file (only fills what's absent). Play through and scrub.

**Rung 3 — full timeline rebuild (`rebuild-paff.sh IN OUT RATE [TS]`):**
Discard container timestamps and re-derive at the true field rate. Video stays
bit-identical; the H.264 parser rebuilds proper access units on re-ingest.
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
