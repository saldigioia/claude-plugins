# Ingest & Copy-Compatibility

Can this source go into MOV by stream copy, and does anything need a tag or a
bitstream conversion? Answer this before running ffmpeg.

## Source containers

| Source | Container | Notes |
|--------|-----------|-------|
| `.ts` | MPEG-TS | Off-air/cable. H.264/HEVC is **Annex-B**. May carry multiple programs, SAP audio, embedded captions, timestamp discontinuities. ffprobe may list a stream twice (program duplication) — take the first value. |
| `.mpg` / `.vob` | MPEG-PS | DVD-style. MPEG-2 + AC-3, no per-stream language tags. Often split into numbered parts. |
| `.mkv` | Matroska | Web/encode source. H.264/HEVC is **AVCC**. Millisecond timebase (relevant to the QuickTime timescale error — see `timeline-repair.md`). Strict muxer: refuses bad timestamps (useful as a validator). |
| broken `.mov` | QTFF | A prior bad remux. The video bitstream is still a lossless copy and is recoverable — re-extract and rebuild (`rebuild-paff.sh`), don't re-encode. **Second route — already-collapsed PCM** (gapped video timeline + contiguous audio short by a sizable fraction of (up to ≈) the summed gaps): `resync.sh` repairs post-hoc — measured 2026-08-15, macOS 26.6.1/ffmpeg 9.0.1 (`--all-audio --pcm 32`; full gate battery incl. `--silence` passed; `diagnose.sh`'s DISCONTINUOUS SOURCE verdict fires on the collapsed MOV unchanged); dated record in `timeline-repair.md`, "Post-hoc gap-collapse repair". |

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
| H.264/AVC | Yes | `avc1` (default); Annex-B→avcC handled automatically on copy. 4:2:0 profiles play. **High 4:2:2 (`yuv422p*`, any bit depth) is a per-OS empirical fact, not a refusal (1.11, WO 4.1)**: it stalled qlmanage on macOS 26.5.2 (2026-07-31); on 26.6.1 the synthetic bench clip **renders** (re-measured 2026-08-13) — a *renders* result, not a *renders-correctly* one (the MPEG-2 row's 2026-08-15 false-green shows the gap on the same OS). Decode support drifts by macOS and correctness is per-file, so `mov.sh` announces the contribution profile, builds losslessly, and proves the finished output with `playable-check.sh --fidelity` (fail/unverified → REVIEW with `rung4.sh` named) |
| HEVC/H.265 | Yes | **`-tag:v hvc1`** — default `hev1` won't play in QuickTime (verified: default mux tag is `hev1`) |
| MPEG-2 | Yes | Container OK. 4:2:0 plays in QuickTime. **4:2:2 (422@HL): same demoted-to-empirical verdict as H.264 Hi422 (1.11, WO 4.1)** — it distorted on macOS 26.5.2 (2026-07-30 controlled pair); on 26.6.1 the synthetic bench clip *rendered* (2026-08-13) — but **renders ≠ renders correctly**: two real 1080i59.94 broadcast masters rendered destroyed (macroblock garbage) on the same 26.6.1 (2026-08-15) while the thumbnail check said OK. Correctness is per-file: announced + built + proven post-build with `playable-check.sh --fidelity` (SSIM vs the ffmpeg reference), never refused pre-flight. **Sample-entry dispatch (measured 2026-08-15, macOS 26.6.1)** — same rule shape as the HEVC row's `hvc1`/`hev1`: `m2v1` = the generic MPEG-2 FourCC → AVFoundation's **consumer** decoder → corrupted macroblocks on 4:2:2; `xd5*` = the XDCAM HD422 tags → the **professional** decoder → both real masters decoded frame-for-frame identical to the ffmpeg reference after a stream-copy retag (`-c copy -tag:v xd5b` — 4 bytes in the sample entry, bitstream bit-identical). Tag pick + warnings: the `xd5*` selection table below. **NARROWED THE SAME DAY (2026-08-15, D8/1.13): the tag axis is not the only axis, and on some streams it is not the axis at all.** On a real 21 GB 1080i29.97 4:2:2 capture **all five** tags (`m2v1`/`mp2v`/`hdv3`/`xd5b`/`xd5c`) corrupted **identically** — movenc has no XDCAM-specific sample-description writer, so every MPEG-2 fourcc gets the same generic body (`glbl`(extradata) + `fiel` + optional `colr`, movenc.c 1926–1986/2756–2784/2946); the tag changes the FourCC and the compressor-name string and nothing else. The retag therefore works only when the stream matches the fourcc's **profile contract** (CoreMedia enumerates the HDV/XDCAM family as `kCMMPEG2VideoProfile_*` constants — chroma, raster, field rate AND rate-control class — under the single codec type `kCMVideoCodecType_MPEG2Video = 'mp2v'`). **The CONTAINER is the other axis:** the same bitstream in an `.mp4` (sample entry `mp4v` + `esds`) rendered correctly — SSIM 0.9175+ on the very timestamps that failed as `.mov`. Route: `scripts/mp4-swap.sh SOURCE`. See "The container axis" below |
| ProRes | Yes | `apcn/apch/apcs/apco/ap4h/ap4x` — editorial/master |
| DV/DVCPRO | Yes | Legacy; QuickTime yes, iOS no |
| Dolby Vision HEVC | Yes (ffmpeg ≥5.0, single-layer) | ffmpeg ≥5.0 preserves single-layer DV (P5/P8) on `-c copy` with `-tag:v hvc1`; **dual-layer P7 (FEL)** needs conversion to P8.1 or keep MKV. Sample-entry family (5-5e/C61): `dvh1`/`dvhe` (DV-dedicated) and cross-compat `hvc2`/`hev2`/`hvc3`/`hev3` — the testable split is **`dvh1` plays where the `hev1`-family fails** (same hvc1-vs-hev1 rule extended to DV entries; still blocked on real DV artifacts). `probe.sh` reports the stsd entry (e.g. `hevc (dvh1)`). See `color-hdr-subs.md`. |
| AV1 | **No (ffmpeg)** | ffmpeg's mov muxer hard-rejects (`av1 only supported in MP4 and AVIF`; no `-strict` escape — verified on 8.1.1). ffmpeg policy, not a container limit — see "What ffmpeg's MOV muxer refuses" below. Remux to **MP4** (tag `av01`) or keep MKV; never re-encode the video to force MOV. |
| Legacy QT codecs (Cinepak `cvid`, Sorenson `svq3`, …) | Yes (container) | Deprecated since macOS Catalina — AVFoundation won't decode QuickTime 7-era codecs, so the file is valid but unplayable. Rung 4: transcode to ProRes/H.264 for a playable copy; keep the original as master. Detect: `ffprobe -v error -show_entries stream=codec_name -of csv=p=0 IN \| grep -E 'cinepak\|svq\|mjpeg\|icod'` (mjpeg/icod: version-drift risks, see below) |

### `xd5*` selection table — the MPEG-2 4:2:2 retag route (m2v1 → XDCAM HD422)

**Scope, stated first (1.13):** this table is STEP ONE of a two-step remedy,
not the remedy. It works when the stream matches the fourcc's profile contract
(measured working: the 2026-08-15 VMA 1080i59.94 pair). When it does not, no
`xd5*` value helps — every MOV retag writes the identical sample-description
body — and the next rung is the container swap in "The container axis" below.

The retag route for the MPEG-2 row above: pick the XDCAM HD422 FourCC matching
the stream's geometry and field rate, then

```
ffmpeg -i IN -map 0 -c copy -tag:v xd5b -movflags +faststart OUT.mov
```

(swap `xd5b` for the row that matches). Stream copy only — the tag is 4 bytes
in the `stsd` sample entry and the bitstream stays bit-identical. `probe.sh`
detects the class (`codec=mpeg2video` + `pix_fmt=yuv422p*` + stsd `m2v1`) and
prints this advisory with the additive `PR_TAG_ADVICE=xd5b` machine field.
`PR_TAG_ADVICE` is a **class marker** (the m2v1-dispatch class), not a
per-file tag pick — it says `xd5b` regardless of geometry; the operator
selects the actual tag from the table below by geometry/field-rate.

| Tag | Geometry / field rate | Bench status |
|-----|----------------------|--------------|
| `xd51` | 720p30 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd54` | 720p24 (50 Mb class) | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd55` | 720p25 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd59` | 720p60 (59.94) | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd5a` | 720p50 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd5b` | 1080i60 (1080i59.94) | **measured 2026-08-15** (macOS 26.6.1, ffmpeg 9.0.1): two real broadcast masters decode perfectly via AVFoundation after the retag, frame-for-frame identical to the ffmpeg reference |
| `xd5c` | 1080i50 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd5d` | 1080p24 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd5e` | 1080p25 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |
| `xd5f` | 1080p30 | **unbenched** — route exists, tag choice per spec, verify per-file with `playable-check.sh --fidelity` |

**CBR is not enforced (measured 2026-08-15, macOS 26.6.1):** XDCAM HD422's
nominal 50 Mb/s CBR is not a decode precondition — 19.7 and 31.2 Mb/s **VBR**
streams both played perfectly under the `xd5b` entry.

### The container axis — when no retag works (measured 2026-08-15)

The 21 GB field-report capture (MPEG-2 4:2:2 1080i29.97 mpegts, MP2 audio) built
a verified-lossless `.mov` that QuickTime rendered as macroblock garbage, and
**all five** sample-entry retags corrupted identically. The same bitstream in an
`.mp4` decoded correctly:

| Build | Sample entry | AVFoundation render (macOS 26.6.1) |
|---|---|---|
| `.mov` (default) | `m2v1` + `glbl` | destroyed — SSIM 0.81–0.85 vs the ffmpeg reference |
| `.mov` retagged (`mp2v`/`hdv3`/`xd5b`/`xd5c`) | same generic body, new fourcc | destroyed, **identically** |
| `.mp4` (`scripts/mp4-swap.sh`) | `mp4v` + `esds` | correct — SSIM **0.9175+** on the same timestamps |

Why the MP4 path differs: the ISO ingest path configures the MPEG-2 decoder
from the parsed elementary stream, not from the container's profile claim — the
working file declares OTI **0x61 (Main Profile)** in its `esds` and still
decodes 4:2:2 correctly (ffmpeg's `ff_mp4_obj_type` lists MPEG-2 OTIs Main-first
and `mov_write_esds_tag` takes the first match, so *every* MPEG-2 stream ffmpeg
writes claims Main, never 0x65/422P — and it does not matter). Best-supported
hypothesis for the MOV side: the bridge configures the decoder from the
fourcc/profile contract instead, so a generic tag yields a 4:2:0-geometry
context — intra frames near-clean, then drift and chroma garbage. `--fidelity`'s
per-plane split (`y=`/`u=`/`v=`) is the discriminating measurement and now
prints on every run.

**Why the entry cannot simply be written into a `.mov`:** ffmpeg refuses —
`Tag mp4v incompatible with output codec id '2' (m2v1)` — and that refusal is a
**muxer tag-table artifact**, not a spec rule. It comes from generic muxer init
(`libavformat/mux.c`, a linear lookup against `ff_codec_movvideo_tags`, which
pairs `mp4v` only with MPEG-4), while the MP4 muxer's `codec_mp4_tags` pairs it
with MPEG-2. Apple's QTFF "video sample description extensions" table lists
exactly `gama`, `fiel`, `mjqt`, `mjht`, **`esds`**, `avcC`, `pasp`, `colr`,
`clap` — `esds` is a first-class QuickTime extension, so `mp4v`+`esds` is
**spec-legal inside a `.mov`**; ffmpeg simply has no path that writes it. Only
`stsd` surgery (MP4Box/Bento4) could produce that file — **unbenched**, recorded
in `known-limits.md`. Until then the honest deliverable for this class is a
`.mp4`, losslessly.

(Also from the same source read: ffmpeg can never auto-select `xd5b` for NTSC —
`mov_get_mpeg2_xdcam_codec_tag` truncates `avg_frame_rate` to int, so 29.97 → 29
matches neither 30 nor 60 and the fallback is always `m2v1`. That is why
`probe.sh` can predict the output's sample entry from a `.ts` source, D7/1.13.)

**WARNING — the retag asserts XDCAM identity on streams that are not literal
XDCAM.** A generic broadcast MPEG-2 4:2:2 stream retagged `xd5*` claims to be
an XDCAM HD422 recording; the decoder **tolerated** that assertion on the two
real files measured (2026-08-15), which is evidence, not a guarantee. Rules:

- **Advisory-only in 1.12 — no script applies the tag.** `probe.sh` names the
  command; the operator runs it. Auto-apply is deferred pending the bench
  items in the authoritative deferral record:
  `references/known-limits.md` § "XDCAM retag (m2v1 → xd5*)" (grep
  `deferred`) — in short: `xd5c` on 1080i50, the 720p tags (`xd59`/`xd5a`),
  the 1080p tags (`xd5d`–`xd5f`), an analogous dispatch tag for H.264 High
  4:2:2, proof that 4:2:0 MPEG-2 is refused by geometry check (not tried),
  and geometry-aware tag selection (deriving the right `xd5*` from probed
  geometry/field-rate).
- **Provenance note required in the output metadata** whenever the operator
  applies the retag: the output must state that the video sample entry tag
  was changed and from what — e.g. via `scripts/metadata.sh` or
  `-metadata comment="video stsd retagged m2v1 -> xd5b (stream copy;
  bitstream unchanged)"`. This is a documented requirement of the route; no
  tooling applies it in 1.12.
- Prove every retagged output per-file: `playable-check.sh --fidelity` (SSIM
  vs the ffmpeg reference decode) — decode support drifts by macOS.

### Decode support is a moving target — macOS version drift

A playable-check verdict is a property of the **OS it ran on**, not of the file
(C63) — `playable-check.sh` stamps its result line with `sw_vers` for exactly
this reason. macOS updates can revoke playability of previously-passing files;
the lossless original stays master and playable copies are re-derivable
(Rung 4 via `scripts/rung4.sh`). Known drift:

| Codec | Drift | Evidence |
|-------|-------|----------|
| Motion JPEG (`jpeg` in MOV) | Certain MOV variants dropped in Tahoe 26.4 (July 2026 sweep, forum-corroborated) | Probed 2026-07-26 on macOS 26.5.2 (post-drop): ffmpeg's **4:2:0** mjpeg-in-MOV still renders via AVFoundation (playable-check OK); the **4:2:2** variant renders **no frame — and hangs qlmanage** (no thumbnail after 2+ min), so on dropped variants playable-check may STALL rather than fail fast. Variant-scoped, exactly as reported. QuickTime-Player GUI confirmation pending. |
| Apple Intermediate Codec (`icod`) | Dropped in Tahoe 26.4 | Restorable by installing Apple's Pro Video Formats (ProApps legacy codecs) package: <https://support.apple.com/en-us/106396>. No ffmpeg encoder exists, so a synthesized probe is blocked-on-artifact (recorded in C63). |

## Audio codec → MOV (the forced-decode matrix)

"Decode to PCM" = `-c:a pcm_s16le` (or `pcm_s24le` for genuine >16-bit lossless
sources) — a faithful one-time decode, not a recompression. `remux.sh --audio
auto` applies this table automatically.

| Codec | Muxes into MOV by copy? | QuickTime plays it? | Action |
|-------|-------------------------|---------------------|--------|
| AC-3 (Dolby Digital) | Yes (verified) | **No — TN2429**: desktop QuickTime has no AC-3 decoder (a modern macOS does not fix this; AVFoundation apps vary) | Copy muxes but is not the playback route: `remux.sh --audio auto` decodes AC-3 to a PCM access track (announced per track, `-drc_scale 0` under `--drc auto`); the dual-track route (`mov.sh` auto-dual / `dual-track.sh`) preserves the original bit-exact alongside the access track |
| E-AC-3 / E-AC-3 JOC (DD+/Atmos) | Yes (verified) | **Yes — native** (modern QuickTime/macOS) | `-c:a copy`, single track — QuickTime plays Dolby Digital Plus natively. Atmos object metadata is in-band, preserved |
| AAC | Yes | Yes | `-c:a copy` |
| ALAC | Yes | Yes | `-c:a copy` |
| PCM in MP4 (`ipcm`) | n/a (MP4 only) | **Yes, measured 2026-08-15** (macOS 26.6.1) | The ISO-registered PCM entry — ISO/IEC 23003-5 with the `pcmC` config box, MP4RA-registered; ffmpeg writes it since `d4ee177a` (6.1), VLC and GPAC read it (GPAC actively **normalizes** QTFF `twos` → `ipcm` on MP4 remux), Sony XAVC has shipped it in broadcast delivery since 2021. It is what `-c:a pcm_s16le -f mp4` produces, i.e. the container-swap rung's access track. Known holes: **Android MediaExtractor cannot play it** (2025 report), Windows Media Foundation does not document it, Apple ships **zero documentation** (this bench is the only Apple datapoint), and Premiere/Resolve support for *ffmpeg-authored* `ipcm` is unverified. In a `.mov`, QTFF PCM (`sowt`/`in24`+`enda`) remains the compatibility king — which is exactly what `dual-track.sh` mints. |
| PCM (`lpcm`) | Yes | Yes | `-c:a copy` — **except `pcm_bluray`/`pcm_dvd`** (HDMV/DVD **container-framed** LPCM, not raw samples): the "copy" muxes but yields an HDMV-tagged track no decoder claims — a dead track (WO 3.1), so since 1.11 the auto policy routes them to the PCM access decode (s32 sources trip the depth WARN; depth-true route: `dual-track.sh --pcm auto`) |
| **MP2 / MP1** | **Yes, but non-standard** (tag `.mp2`, verified) | **Per-OS empirical — prove it on your target** (playing here 2026-08-29; silent on the D3 bench 2026-08-15) | **Decode to PCM is the works-everywhere option (not a mandatory rebuild).** The mux succeeds; the reason to decode is playability. ffmpeg's `mov_write_esds_tag` special-cases MP2/MP3 above 24 kHz to OTI **`0x6B` (MPEG-1 Part 3)** — the *formally correct* declaration for 48 kHz Layer II — so there is nothing to fix on the write side; the `mp3` label ffprobe shows back is a demux-side artifact (`ff_mp4_read_dec_config_descr` maps both `0x69` and `0x6B` to `AV_CODEC_ID_MP3`, first match; 14496-3 carries no DecoderSpecificInfo for the layer). Playability is PER-OS EMPIRICAL, both measurements standing: measured PLAYING in QuickTime on this machine 2026-08-29 (plugin-doctor/README.md), measured SILENT on the D3 bench 2026-08-15 (1.13). Decode support drifts by OS in both directions (C63) — prove it on your target machine. Note `.mp2` is ffmpeg's convention, not an Apple-documented sample entry (the spec lists no framed Layer II format) — worth a line in any sidecar. `verify.sh` gate (g) REVIEWs an MP2 track with **no** PCM access track. |
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

**The same write-side policy also refuses SAMPLE ENTRIES, not just codecs**
(1.13): `-tag:v mp4v` on MPEG-2 into MOV dies at header write with `Tag mp4v
incompatible with output codec id '2' (m2v1)` — a linear lookup in the MOV
muxer's tag table (`ff_codec_movvideo_tags`), even though `esds` is a documented
QTFF video sample-description extension and the MP4 muxer pairs `mp4v` with
MPEG-2 happily. Container-legal, muxer-refused. This failure class appears
**unreported** on trac/ffmpeg-devel; so does the container-dependence itself
(same bits: MOV corrupt, MP4 clean).

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
