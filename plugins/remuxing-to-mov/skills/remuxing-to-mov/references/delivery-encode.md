# Delivery & Encode Recipes (Rung 4 — NOT the lossless path)

These **re-encode**. Reach for them only at Rung 4: QuickTime playback of a
codec it can't decode (4:2:2 MPEG-2, Dolby Vision), a frame-exact smart-cut, or
producing a distribution copy from a preserved master. Routine ingest/archival
should never land here — if you're about to re-encode a whole video to get it
into MOV, re-check `ingest-compatibility.md` and `timeline-repair.md` first.

Always keep the lossless original (MKV or copy-MOV) as the master and produce
these as separate derivatives.

## H.264 delivery (MP4)

```
ffmpeg -i master.mov -c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p \
  -crf 18 -preset slow -c:a aac -b:a 160k -movflags +faststart deliver_h264.mp4
```
For segmented/streaming targets needing a fixed GOP, add
`-x264-params "keyint=48:min-keyint=48:no-scenecut=1"`.

## HEVC delivery (Apple targets)

```
ffmpeg -i master.mov -c:v libx265 -tag:v hvc1 -profile:v main10 -pix_fmt yuv420p10le \
  -c:a aac -b:a 160k -movflags +faststart deliver_hevc.mp4
```
For HDR10 content add `-x265-params "hdr10_opt=0:repeat-headers=1"` (keeps
mastering/CLL SEI repeated for players that join mid-stream).

## Apple ProRes master

```
ffmpeg -i source.ext -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -timecode 01:00:00:00 -c:a alac out_master_prores_hq_alac.mov
```
Optional `-vendor ap10` writes Apple's encoder vendor fourcc (some strict QC
tools expect it). Note ProRes plays on macOS but **not on iOS** devices.
ProRes profiles: `0`=Proxy, `1`=LT, `2`=422, `3`=422 HQ, `4`=4444, `5`=4444 XQ
(stsd tags `apco/apcs/apcn/apch/ap4h/ap4x`). *Profile-number/tag mapping
verified empirically on ffmpeg 8.1.1 (2026-06-10): profiles 0–5 produce exactly
these stsd tags.*

## Footprint minimization

- Decode the **single** offending stream, not the file (e.g. MP2→PCM is audio-only).
- Prefer smart-cut over a whole-timeline re-encode for precision edits
  (`cutting-concat.md`).
- For QuickTime-playability transcodes (4:2:2 MPEG-2, DV), keep the video copy
  wherever the rest of the file allows; transcode only what blocks playback.

## Faststart / tag fixes that are NOT re-encodes (kept here for convenience)

```
# relocate moov for progressive playback (copy)
ffmpeg -i in.mov -c copy -movflags +faststart out.mov
# fix HEVC sample entry hev1 -> hvc1 (copy)
ffmpeg -i in.mov -c copy -tag:v hvc1 out.mov
```
