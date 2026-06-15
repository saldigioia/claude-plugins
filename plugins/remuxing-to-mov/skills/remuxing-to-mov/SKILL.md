---
name: remuxing-to-mov
description: Losslessly remux broadcast and web video (.ts, .mpg/.vob, .mkv, broken .mov) into a .mov container without re-encoding. Use this skill whenever the user wants to put a capture into MOV, mentions remuxing / -c copy / stream copy to MOV or QuickTime, is dealing with a glitchy, stuttering, or field-coded/interlaced (PAFF) H.264 remux, needs to cut/trim/concatenate video without re-encoding, is preserving color/HDR/captions/audio through a container change, or is deciding whether a re-encode is truly unavoidable. Prefer this skill over ad-hoc ffmpeg even when the user only says "convert to .mov" — the default is always lossless copy, never a re-encode.
allowed-tools: Bash, Read, Write
---

# Remuxing to MOV (lossless-first)

Move a source into a `.mov` container **without re-encoding**. Re-encoding is a
last resort, scoped as narrowly as possible (audio-only, or one GOP), never the
whole video.

**Governing rule:** stay in stream copy (`-c copy`) as long as the source and
MOV allow. Step off it only when a *named* constraint forces you to.

## Workflow

**One-shot (hands-off):** `scripts/auto.sh IN OUT.mov` runs probe → pick the
lowest rung → remux/rebuild → verify → escalate on a bad verdict, in one call. It
routes field-coded (PAFF) straight to the rebuild, **never re-encodes** (Rung 4
stays a human decision), and never touches the source. Exit 0 = verified, 10 =
REVIEW, 1 = FAIL. Use the manual ladder below when you want control or hit a
REVIEW/FAIL. Run `scripts/doctor.sh` once on a new machine first.

1. **Probe** the source first — never guess:
   `scripts/probe.sh INPUT`
   It prints codecs+tags, field structure, Annex-B vs AVCC, color, and
   ffmpeg-version warnings (DV/colr/MP2 behavior differs by version). It also
   flags **field-coded (PAFF) H.264** — coded-picture rate ≈ 2× the frame rate —
   and prints the exact field-rate rebuild command, because that case must not
   go down the genpts path.
2. **Pick the lowest rung that produces a clean, verified file** (ladder below).
3. **Verify** every output before trusting it: `scripts/verify.sh SOURCE OUTPUT`.
   The default tier is cheap (demux-only packet hash + sampled decode — seconds,
   not runtime); add `--full` for whole-file decoded-pixel identity only for
   archival sign-off, to settle a REVIEW verdict, or once per new
   pipeline/source type. Never default to a full double decode. Add `--signaling`
   (color/HDR tags + captions) or `--audio` (dual-track fidelity) when the source
   carries HDR/captions or you shipped the dual-track build.

## The escalation ladder — stop at the first rung that works

```
Rung 0  Pure copy            scripts/remux.sh IN OUT.mov
        when: all codecs MOV-compatible AND timestamps sound.
Rung 1  Copy video, PCM audio   scripts/remux.sh IN OUT.mov --audio pcm
        forced by: MP2/MP1 (non-standard in MOV) or DTS-HD MA (QuickTime won't
        play). remux.sh --audio auto picks this automatically. Video stays
        bit-identical; only audio is decoded (faithful render, not recompress).
Rung 2  Copy + rebuild timestamps   scripts/remux.sh IN OUT.mov --genpts
        forced by: missing/unset PTS. Bitstream untouched.
        GUILTY-UNTIL-PROVEN on field-coded (PAFF) H.264: genpts can pass the
        strict-mux test yet leave a timeline that tears on scrub — for PAFF skip
        to Rung 3, or gate the output through verify.sh's scrub test first.
Rung 3  Rebuild timeline from the elementary stream
        scripts/rebuild-paff.sh IN OUT.mov FIELD_RATE [TIMESCALE]
        the DEFAULT for field-coded (PAFF) H.264 — probe.sh/diagnose.sh route
        here directly, NOT via genpts. Video stays bit-identical; access units +
        timestamps are re-derived at the field rate.
Rung 4  Re-encode (last resort)
        only: QuickTime PLAYBACK of 4:2:2 MPEG-2 or Dolby Vision, or a
        frame-exact cut at a non-keyframe. Minimize footprint. See
        references/delivery-encode.md and references/cutting-concat.md.
```

If `remux.sh` (Rung 0/1) plays back clean, you are done. If the file glitches or
tears on scrub, it is almost always **timestamps, not the video** — run
`scripts/diagnose.sh INPUT` to find the cause and the right rung.

## Diagnose a glitchy / field-coded remux

`scripts/diagnose.sh INPUT` runs the ladder and prints a verdict:
1. decode-to-null integrity (a flood of decode errors = damaged source, not
   fixable by remux — re-capture);
2. MKV strict-mux test (Matroska refuses the bad/absent timestamps MOV silently
   swallows — this is the decisive test);
3. backward-DTS (non-monotonic timing; **blind to *missing* timestamps**, which
   only step 2 catches — a "0" here does not by itself clear the file).

Verdict → action: damaged → re-capture; missing TS → Rung 2 then Rung 3;
non-monotonic DTS → Rung 3. **Field-coded (PAFF) H.264 is routed straight to
Rung 3 regardless of the timing verdict** — genpts is guilty-until-proven there,
because the strict-mux test proves timestamps are *present and monotonic*, not
that the timeline is *seekable*, and that gap is where PAFF corrupts silently.
Detail and the manual commands live in `references/timeline-repair.md`.

## Instant answers (recurring symptom → rule)

| Situation | Rule |
|---|---|
| "Convert this to .mov" | `scripts/remux.sh IN OUT.mov` — lossless copy, never a re-encode |
| HEVC file won't open in QuickTime | Retag, don't re-encode: `ffmpeg -i IN -c copy -tag:v hvc1 OUT.mov` |
| Plays locally, slow start over network | `ffmpeg -i IN -c copy -movflags +faststart OUT.mov` (moov was at EOF) |
| Video plays, audio silent in QuickTime | Audio QT can't decode (AC-3/E-AC-3/DTS/MP2) → dual-track default, or `remux.sh --audio pcm` |
| Glitches/tears only on scrub | Timestamps, not the video → `scripts/diagnose.sh` |
| Field-coded (PAFF) H.264 (coded-pic rate ≈ 2× frame rate) | genpts is guilty-until-proven → rebuild at the field rate (`scripts/rebuild-paff.sh`); confirm with `scripts/verify.sh` (its scrub gate fails a glitchy timeline) |
| Mux fails `Could not find tag for codec …` | A subtitle/data stream MOV can't carry (subrip, DVB, teletext, SCTE) — map explicitly `-map 0:v:0 -map 0:a`; text subs → sidecar or `mov_text` (verified 8.1.1: `-map 0` copy with SRT fails at header write) |
| Mux fails `… only supported in MP4` | AV1 / FLAC / Opus / TrueHD: route to MP4 or keep MKV; FLAC → `-c:a alac` bridge |
| `duration too long for timebase` | `-video_track_timescale` from the field-rate table in `references/timeline-repair.md` |
| Trim/cut requested | Copy cuts are keyframe-bound (`references/cutting-concat.md`); frame-exact = smart-cut, the one edit that re-encodes |
| Source has several audio tracks | `remux.sh` keeps `a:0` only — add `--all-audio`; first mapped track = the QuickTime default |
| Missing/wrong audio language tag | `-metadata:s:a:0 language=eng` (PS/`.mpg` sources carry none) |
| Chapters in the source | Survive `-c copy` into MOV — ffmpeg adds a QT chapter text track (verified 8.1.1) |
| Asked to remux a file onto itself | Never — scripts refuse; write the output beside the source under a new name |
| New machine / CI, or "is my ffmpeg OK?" | `scripts/doctor.sh` — reports required vs degraded capabilities (muxers/bsfs) before you trust verify.sh |
| A whole folder of captures | `scripts/batch.sh DIR --out OUTDIR` — auto.sh per file + provenance sidecars + a report; idempotent resume, never deletes sources |
| "Will QuickTime actually play it?" (macOS) | `scripts/playable-check.sh OUT.mov` — AVFoundation render probe; the playable≠valid half ffmpeg can't prove |

## House defaults (baked into the scripts)

- Video: **always `-c copy`**. HEVC tagged **`hvc1`** (default `hev1` won't play
  in QuickTime). `-movflags +faststart`.
- Audio: copy AC-3 / E-AC-3 / AAC / ALAC / PCM; decode MP2/MP1/DTS to
  `pcm_s16le`.
- **Default deliverable is a dual-track MOV**: PCM "access" track first/default
  (always plays in QuickTime) + the original audio copied bit-exact as track 2.
  Non-destructive; never overwrite the source. Lossy sources → `pcm_s24le` with
  `-drc_scale 0`; lossless → PCM at native depth. Build with
  `scripts/dual-track.sh`; rules + QC in `references/dual-track-quicktime.md`.
- `-nostdin` on every call; **atomic output** (`.part` → `mv`); temp/intermediate
  files are **never auto-deleted** and `set -e` gates every step, so a failure
  never reaches cleanup.
- Color: `colr` is written automatically by modern ffmpeg; do **not** fabricate
  tags for `unknown` sources.

## When to read which reference (load on demand)

| Need | Read |
|------|------|
| "Will this source/codec even copy into MOV?" tables; Annex-B vs AVCC | `references/ingest-compatibility.md` |
| Field-coded/PAFF diagnosis + the full repair ladder + field-rate table | `references/timeline-repair.md` |
| Lossless cut / trim / concat, and the frame-exact (smart-cut) boundary | `references/cutting-concat.md` |
| Color/HDR signaling, embedded captions, subtitles (mov_text vs sidecar) | `references/color-hdr-subs.md` |
| Track selection/language tags, verification methods, safety, playable≠valid | `references/verification-safety.md` |
| Atom anatomy, MOV vs MP4, required structure, validation checks | `references/container-internals.md` |
| Codec/container landscape: terminology, licensing, efficiency, audio transparency numbers, Atmos/DTS:X carriage, what each container accepts, "what is X / X vs Y" questions | `references/codec-landscape.md` |
| Rung-4 delivery/encode recipes (x264/x265/ProRes) — NOT the lossless path | `references/delivery-encode.md` |
| **DEFAULT deliverable**: QuickTime-ready dual-track (PCM access + original preserved), alignment-safe two-pass cutting, dual-track QC | `references/dual-track-quicktime.md` + `scripts/dual-track.sh` |
| Worked examples from a real broadcast job (copy-cut + QC driver scripts; paths/timestamps hardcoded) | `examples/README.md` |
| Regression tests for the PAFF safeguards — run after editing any script | `tests/README.md` + `tests/regression.sh` |

## Hard-won facts (verified on ffmpeg 6.1.1, 2026-06-03)

- **Field-coded (PAFF) H.264 routes straight to the field-rate rebuild; genpts
  is guilty-until-proven.** genpts can pass the strict MKV-mux test (timestamps
  present + monotonic) yet leave a timeline that is not *seekable* — it tears
  when a player scrubs. Mux-valid and seekable are different properties, and the
  gap between them is where PAFF corrupts silently. So: (a) `probe.sh`/
  `diagnose.sh` detect PAFF by the coded-picture rate (≈ 2× the frame rate) and
  bias to `rebuild-paff.sh`; (b) `verify.sh` includes a **scrub gate** —
  accurate seeks to deliberately off-keyframe timestamps + a keyframe-spacing
  sanity check — which fails a glitchy timeline *before* the source is deleted
  (an ffmpeg-style keyframe seek stays clean on the broken file, so it is not
  enough); (c) decoded `framemd5` FALSE-FAILs field-coded streams (field vs
  frame packaging), so the **Annex-B packet hash** is the lossless arbiter
  there, not a decoded-pixel compare. A real player remains the final word —
  "playable ≠ valid" — but these automated proxies catch the case unaided.
- **MP2 *does* mux into MOV** (tag `.mp2`) — but it is non-standard and QuickTime
  is not expected to play it, so decode to PCM for a playable file. The reason
  is playability, not container incompatibility.
- ffmpeg writes **no `fiel` atom** on copy; field order survives via the
  bitstream. `-field_order tt` is ignored on copy (does not hard-fail).
- `colr` is written **by default**; `+write_colr` is redundant (harmless).
- HDR10 `mdcv`/`clli` live **only in the HEVC SEI**, not as container boxes.
- **Dolby Vision survives `-c copy` on ffmpeg ≥5.0** for single-layer profiles
  (P5/P8) with `-tag:v hvc1`; dual-layer Profile 7 still needs conversion.
- **QuickTime AC-3/E-AC-3 native playback is unverified** — confirm on the
  target macOS before relying on copy for a *playable* file.
- **ffmpeg's MOV muxer hard-rejects AV1, FLAC, Opus, and TrueHD** ("only
  supported in MP4", verified ffmpeg 8.1.1, 2026-06-10) — no `-strict` escape.
  Write-side ffmpeg policy, not a container limit — but QuickTime won't play
  them either, so route to MP4 or keep MKV. FLAC alone has a bit-exact MOV
  bridge (`-c:a alac`); TrueHD has no escape hatch. MP3 *does* copy into MOV
  and QuickTime plays it. Details: `references/ingest-compatibility.md` +
  `references/codec-landscape.md`.

`scripts/probe.sh` surfaces the version-dependent items at runtime.
