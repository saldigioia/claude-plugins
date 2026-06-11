# Color, HDR & Caption/Subtitle Fidelity on Copy

A copy preserves the picture exactly, but signaling and text streams can be lost
or mangled in the handoff. Facts below verified on ffmpeg 6.1.1 (2026-06-03).

## Color signaling

- The `colr` (nclx) atom is written **by default** when the source is tagged —
  `+write_colr` is redundant on modern ffmpeg (harmless to keep). Range
  (full/limited) lives in the bitstream VUI and is preserved on copy.
- **Don't fabricate** color for `unknown` sources. If you have external grounds
  to assert a value (e.g. a 1080i ATSC broadcast is almost certainly BT.709), do
  it deliberately with `-color_primaries/-color_trc/-colorspace` and note it; the
  remux itself can't know.

```
# preserve real tags (colr written automatically)
ffmpeg -nostdin -i IN -map 0:v:0 -map 0:a:0 -c copy -movflags +faststart -f mov OUT.mov
```

## HDR

- **HDR10:** primaries/transfer (BT.2020/PQ) carry in the bitstream and survive
  copy. Mastering-display (`mdcv`) and content-light (`clli`) metadata are kept
  in the **HEVC SEI** — ffmpeg does **not** write container-level `mdcv`/`clli`
  boxes on a copy, and `+write_colr` does not add them. Players that read SEI
  still get HDR10; a player relying on container boxes may not.
- **Dolby Vision:** the RPU rides in the HEVC bitstream. **ffmpeg ≥5.0 preserves
  single-layer DV (Profile 5/8) on `-c copy`** into MP4/MOV (use `-tag:v hvc1`).
  The old "keep MKV" advice applied to older ffmpeg and to **dual-layer Profile
  7 (FEL)**, which still needs conversion to P8.1. Verify the profile survived
  (`ffprobe` / `dovi_tool`) rather than assuming either way.

## Embedded captions (EIA-608 / EIA-708)

CC data lives **inside the video** — MPEG-2 user data (A/53) or H.264 SEI
(SCTE-128). It is carried automatically on any video stream copy with **no
mapping**, and stays frame-aligned through trims. Nothing to do; just don't strip
it by re-encoding.

## Subtitle tracks (SubRip etc.)

MOV/MP4 has no SubRip carriage; it needs `mov_text` (tx3g):
```
ffmpeg -nostdin -i IN.mkv -map 0:v:0 -map 0:a:0 -map 0:s:0 \
  -c:v copy -c:a copy -c:s mov_text -movflags +faststart -f mov OUT.mov
```
Two failure modes:
- **Timebase overflow** — converting `mov_text` from a 1 ms-base MKV over a long
  duration triggers the QuickTime "duration too long for timebase" fatal (see
  `timeline-repair.md`). `-video_track_timescale` fixes the *video* track; if the
  subtitle is the overflowing track there's no clean per-subtitle knob.
- **Many tracks** — a full multi-language bouquet is impractical to convert and
  risks the overflow per track.

**Safer default: sidecar the subtitle(s)** — preserves them fully, sidesteps both:
```
ffmpeg -nostdin -i IN.mkv -map 0:s:0 -c:s srt subs.eng.srt
```

## Pure-copy vs conversion summary

| Element | On a copy | Note |
|---------|-----------|------|
| Color primaries/transfer/matrix | Preserved; `colr` written by default | Don't fabricate when `unknown` |
| Full/limited range | Preserved (bitstream + nclx) | Carry as-is |
| HDR10 `mdcv`/`clli` | In HEVC SEI only; no container box on copy | SEI-reading players still get HDR10 |
| Dolby Vision RPU | Preserved on ffmpeg ≥5.0 (single-layer) | Dual-layer P7 needs conversion |
| Embedded 608/708 CC | Preserved automatically | No mapping needed |
| SubRip subtitle | Needs `mov_text` conversion | Sidecar `.srt` is safer |
