# Ingest & Copy-Compatibility

Can this source go into MOV by stream copy, and does anything need a tag or a
bitstream conversion? Answer this before running ffmpeg.

## Source containers

| Source | Container | Notes |
|--------|-----------|-------|
| `.ts` | MPEG-TS | Off-air/cable. H.264/HEVC is **Annex-B**. May carry multiple programs, SAP audio, embedded captions, timestamp discontinuities. ffprobe may list a stream twice (program duplication) — take the first value. |
| `.mpg` / `.vob` | MPEG-PS | DVD-style. MPEG-2 + AC-3, no per-stream language tags. Often split into numbered parts. |
| `.mkv` | Matroska | Web/encode source. H.264/HEVC is **AVCC**. Millisecond timebase (relevant to the QuickTime timescale error — see `timeline-repair.md`). Strict muxer: refuses bad timestamps (useful as a validator). |
| broken `.mov` | QTFF | A prior bad remux. The video bitstream is still a lossless copy and is recoverable — re-extract and rebuild (`rebuild-paff.sh`), don't re-encode. |

## Annex-B vs AVCC (only matters when EXTRACTING to raw .h264)

- **TS / PS** → already Annex-B → **no bitstream filter**: `-c:v copy -f h264`
- **MKV / MOV** → AVCC → **add** `-bsf:v h264_mp4toannexb` (HEVC: `hevc_mp4toannexb`)

A straight `-c copy` *into* MOV needs no filter — ffmpeg converts Annex-B→avcC
automatically. The filter is only for the extraction step in the Rung-3 rebuild.

Detect: `ffprobe -v error -select_streams v:0 -show_entries stream=is_avc,nal_length_size -of default=nw=1 IN`
→ `is_avc=true / nal_length_size=4` = AVCC; `false / 0` = Annex-B. (Verified.)

## Video codec → MOV

| Codec | Copies into MOV? | Tag / note |
|-------|------------------|------------|
| H.264/AVC | Yes | `avc1` (default); Annex-B→avcC handled automatically on copy |
| HEVC/H.265 | Yes | **`-tag:v hvc1`** — default `hev1` won't play in QuickTime (verified: default mux tag is `hev1`) |
| MPEG-2 | Yes | Container OK. 4:2:0 plays in QuickTime; **4:2:2 (422@HL) generally does not** (verify on target macOS) |
| ProRes | Yes | `apcn/apch/apcs/apco/ap4h/ap4x` — editorial/master |
| DV/DVCPRO | Yes | Legacy; QuickTime yes, iOS no |
| Dolby Vision HEVC | Yes (ffmpeg ≥5.0, single-layer) | ffmpeg ≥5.0 preserves single-layer DV (P5/P8) on `-c copy` with `-tag:v hvc1`; **dual-layer P7 (FEL)** needs conversion to P8.1 or keep MKV. See `color-hdr-subs.md`. |
| AV1 | **No (ffmpeg)** | ffmpeg's mov muxer hard-rejects (`av1 only supported in MP4 and AVIF`; no `-strict` escape — verified on 8.1.1). ffmpeg policy, not a container limit — see "What ffmpeg's MOV muxer refuses" below. Remux to **MP4** (tag `av01`) or keep MKV; never re-encode the video to force MOV. |
| Legacy QT codecs (Cinepak `cvid`, Sorenson `svq3`, …) | Yes (container) | Deprecated since macOS Catalina — AVFoundation won't decode QuickTime 7-era codecs, so the file is valid but unplayable. Rung 4: transcode to ProRes/H.264 for a playable copy; keep the original as master. Detect: `ffprobe -v error -show_entries stream=codec_name -of csv=p=0 IN \| grep -E 'cinepak\|svq'` |

## Audio codec → MOV (the forced-decode matrix)

"Decode to PCM" = `-c:a pcm_s16le` (or `pcm_s24le` for genuine >16-bit lossless
sources) — a faithful one-time decode, not a recompression. `remux.sh --audio
auto` applies this table automatically.

| Codec | Muxes into MOV by copy? | QuickTime plays it? | Action |
|-------|-------------------------|---------------------|--------|
| AC-3 (Dolby Digital) | Yes (verified) | Yes on modern macOS; spotty on older | `-c:a copy` muxes & plays on current QuickTime; the plugin dual-tracks it for older targets |
| E-AC-3 / E-AC-3 JOC (DD+/Atmos) | Yes (verified) | **Yes — native** (modern QuickTime/macOS) | `-c:a copy`, single track — QuickTime plays Dolby Digital Plus natively. Atmos object metadata is in-band, preserved |
| AAC | Yes | Yes | `-c:a copy` |
| ALAC | Yes | Yes | `-c:a copy` |
| PCM (`lpcm`) | Yes | Yes | `-c:a copy` |
| **MP2 / MP1** | **Yes, but non-standard** (tag `.mp2`, verified) | Not expected | **Decode to PCM** for a playable file. The mux succeeds — the reason to decode is QuickTime playability, not container incompatibility. |
| DTS / DTS-HD MA | Yes (tag `dtsc`, verified) | **No** | Copy preserves it, but decode to PCM for a QuickTime-playable file; keep a copy-version too if archiving. DTS:X rides as an extension substream inside DTS-HD — survives copy, **lost on decode to PCM**. |
| MP3 | Yes (tag `.mp3`, verified on 8.1.1) | Yes (native) | `-c:a copy` |
| **TrueHD (incl. Atmos)** | **No** (`truehd only supported in MP4`, verified on 8.1.1) | n/a | **Forced Rung 1 by the container**: decode to PCM at native depth. A bit-exact preservation track in MOV is impossible — keep the source MKV or write the preservation copy to MP4. Blu-ray TrueHD interleaves an AC-3 compat substream, which *is* MOV-copyable. |
| FLAC | **No (ffmpeg)** (`flac only supported in MP4`; no `-strict` escape — verified on 8.1.1; ffmpeg policy, not a container limit) | n/a (QuickTime plays neither .flac nor FLAC-in-MP4) | Lossless bridge: **`-c:a alac`** (bit-exact, ~1–5% larger), or decode to PCM |
| Opus | **No (ffmpeg)** — muxer hard-rejects (`opus only supported in MP4`), even for copy (verified on 8.1.1; ffmpeg policy, not a container limit) | n/a (QT won't play Opus-in-MP4 either) | Decode to PCM, keep the source container, or copy into MP4 (lossless) if QuickTime playback isn't required |
| Vorbis | Version-dependent: refused on 6.1.1; muxes on 8.1.1 with non-standard tag `msVo` | **No** | Treat as unplayable regardless of mux success: decode to PCM, or keep the source container |

Object audio in general: Atmos (E-AC-3 JOC or TrueHD substream) and DTS:X
metadata is in-band in the compressed bitstream — preserved by `-c copy`,
**always lost on decode to PCM** (decoders render the channel bed only).

`pcm_s16le` suffices when the source is already lossy (MP2, AC-3-class). Use
`pcm_s24le` only for genuine 24-bit lossless sources.

## Subtitle & data streams (the silent `-map 0` breaker)

Broadcast TS commonly carries DVB subtitles, teletext, and SCTE-35 data; MKV
carries SubRip/ASS. None of these copy into MOV — mapping one aborts the mux at
header write: `Could not find tag for codec subrip in stream #N, codec not
currently supported in container` (verified 8.1.1 with SRT; DVB/teletext/SCTE
have no MOV mapping either). Rules:

- Map video + audio explicitly (`-map 0:v:0 -map 0:a`) instead of `-map 0`.
- Text subs: sidecar `.srt` (safest) or convert `-c:s mov_text` — both in
  `color-hdr-subs.md`. Bitmap DVB subs have no MOV path; keep the source.
- Embedded 608/708 captions are NOT affected — they live inside the video
  bitstream and survive any video copy automatically.
- Chapters DO survive `-c copy` into MOV — ffmpeg writes a QuickTime chapter
  text track from them (verified 8.1.1).

## What ffmpeg's MOV muxer refuses

Hard muxer rejections (not just unplayable — refused at header write, verified
on 8.1.1): **AV1, FLAC, Opus, TrueHD**. All four are accepted by MP4 and MKV.
FLAC alone has a bit-exact MOV bridge (`-c:a alac`).

Keep three layers distinct: **container** (can QTFF carry it), **muxer** (will
the tool write it), **player** (will QuickTime decode it). These four are
*muxer*-layer rejections — ffmpeg write-side policy, not container physics.
Verified 2026-06-10 (mediabunny 1.46.0, node 25): Mediabunny's independent MOV
muxer writes AV1 (`av01`), Opus (`Opus`), and FLAC (`fLaC`) into `qt`-brand
MOV as bit-exact stream copies (streamhash-identical), and ffmpeg 8.1.1
*demuxes those files cleanly* — its rejection is write-only. QuickTime plays
none of them, so this is a provenance-only escape hatch for when bit-exact MOV
carriage is genuinely required; the routing advice below is unchanged.
TrueHD is the exception with no path at all: Mediabunny doesn't support it, so
no known muxer puts TrueHD in MOV. Tooling details: `codec-landscape.md`.

If a stream has no MOV mapping and no lossless transcode (the four above, some
text-sub formats): keep the source container (MKV is most tolerant), remux to
MP4, or decode/convert that one stream. Never let one incompatible stream push
you into re-encoding the video. Background and full codec/container context:
`codec-landscape.md`.
