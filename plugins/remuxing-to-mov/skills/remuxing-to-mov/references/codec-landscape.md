# Codec & Container Landscape (reference)

Background the rest of the skill assumes: what each codec/container is, its
licensing, and whether it can enter MOV. The *action* tables in
`ingest-compatibility.md` remain canonical for the remux decision; consult this
file for context, codec choice, or when a user asks "what is X / X vs Y".
Items marked **(8.1.1)** were verified empirically on ffmpeg 8.1.1
(2026-06-10). Muxer acceptance is version-dependent — see the last section.

## Terminology

- **Codec** — encode/decode method for one elementary stream (H.264, AAC, PCM).
  Need not compress (PCM). Determines quality; says nothing about the file.
- **Container** — wraps streams *plus the timing, index, and metadata needed to
  play them* (MOV, MP4, MKV, TS). The container owns timestamps and sample
  tables — which is why a remux can glitch while the bitstream is bit-identical.
- **Extension** — at best names the container, never the codecs. Identify with
  `ffprobe`, never the suffix; ffmpeg parses the whole QTFF/ISO-BMFF family with
  one demuxer (`mov,mp4,m4a,3gp,3g2,mj2`) (8.1.1) — the extension is cosmetic.
- **Mux / demux / remux** — interleave streams into a container / extract them /
  demux + mux into a new container with payloads copied bit-for-bit (`-c copy`).
- **Transcode vs encode** — transcode = decode a *previously compressed* stream
  and re-encode; PCM→MP3 is plain encoding. Any lossy re-encode discards
  information permanently (quantization is the irreversible step); damage
  compounds per generation. The codec pair alone doesn't decide loss — x265 has
  a lossless mode; "H.264→H.265 loses quality" is about lossy settings.
- **Stream copy is deterministic, not "usually" lossless** — a correct `-c copy`
  is bit-identical for the copied stream (verified by round-trip bitstream MD5)
  (8.1.1). All caveats live in container compatibility and timing, never in
  stream quality.
- **Up-conversion fallacy** — lossy→lossless/PCM (MP3→FLAC, AC-3→PCM) restores
  nothing: a faithful render of the already-degraded signal. This is why the
  skill's decode-to-PCM rungs are acceptable and why they add no fidelity.
- **Bitrate** — bits (not bytes) per second. Quality *lever* for lossy codecs;
  an *outcome* of content complexity for lossless (CD-res FLAC lands ~700–1000
  kbps from fixed 1411 kbps PCM). Equal bitrate ≠ equal quality across codecs.
- **CBR / VBR / ABR** — bitrate modes, orthogonal to codec. CBR: fixed spend,
  predictable, wasteful/starved. VBR: quality-targeted, best per byte. ABR:
  converges on a target average — for size-budgeted offline encodes.
- **Sample rate / bit depth** — 44.1 kHz = music/CD standard, **48 kHz =
  video/broadcast standard**; Nyquist puts 44.1 kHz past human bandwidth.
  Depth ≈ 6 dB dynamic range per bit: 16-bit ≈ 96 dB; 24-bit's "144 dB" is
  theoretical (~120–125 dB in real converters) — headroom, not audibility.
  Never resample or re-depth in a remux pipeline; copy and decode both preserve
  the source values.
- **GOP / keyframe** — one independently decodable I/IDR frame plus the P/B
  frames depending on it. Lossless cuts land only on keyframe boundaries;
  frame-exact elsewhere forces the Rung-4 smart-cut.

## Video codecs

| Codec | Efficiency vs H.264 | Licensing | Into MOV (copy)? | QuickTime plays? | ffmpeg encoders (8.1.1) |
|---|---|---|---|---|---|
| H.264/AVC | 1× baseline | Via-LA pool; free-internet-video exemption; patents sunsetting ~2027–30 | Yes `avc1` | Yes (8-bit 4:2:0; Hi10P unreliable) | `libx264`, `h264_videotoolbox` |
| HEVC/H.265 | ~25–40% savings (50% is design target, not typical HD result) | Fragmented: Access Advance + Via-LA + Velos + unpooled | Yes, **`-tag:v hvc1`** | Yes with `hvc1` (macOS 10.13+, incl. 10-bit/HDR) | `libx265`, `hevc_videotoolbox` |
| AV1 | ~30–50% vs H.264, ~20–30% vs HEVC | AOMedia royalty-free by design; contested by Sisvel pool | **No** — movenc rejects: `av1 only supported in MP4 and AVIF`; no `-strict` escape (8.1.1) | No (hw decode only M3+/A17 Pro) | `libsvtav1` (fast), `libaom-av1` (slow ref), `librav1e` |
| ProRes | n/a — intra-frame mezzanine (~220 Mb/s 422 HQ @1080p30); 10-bit 4:2:2 / 12-bit 4:4:4(+16-bit alpha). Intra coding is why it scrubs well | Apple proprietary; bitstream public as SMPTE RDD 36; ffmpeg encoders are uncertified independent implementations | Yes — native (tags in `delivery-encode.md`) | Yes — native (macOS; **no iOS playback**) | `prores_ks` (best SW), `prores_videotoolbox` (Apple hw) |
| MPEG-2 | needs ~2× H.264's bitrate | Patents **expired** (US, 2018) | Yes | 4:2:0 yes; 4:2:2 generally no | `mpeg2video` |

AV1 sources: remux to **MP4** (tag `av01`) or keep MKV — never re-encode the
video to force MOV. iPhone 13 Pro+ can record ProRes (camera-original MOVs).
SVT-AV1 has closed the encode-speed gap with x265; "AV1 is slow" = libaom only.

## Audio codecs

Transparent bitrates are stereo planning numbers (good encoder, typical
material), not guarantees. Action verdicts live in `ingest-compatibility.md`.

| Codec | Class | Transparent / typical | Licensing | Into MOV (copy)? | QT plays? |
|---|---|---|---|---|---|
| PCM (WAV/AIFF) | uncompressed | 1411 kbps CD-rate | free | Yes (`sowt`/`twos`/`in24` — both endiannesses legal) | Yes |
| ALAC | lossless ~50–70% of PCM | n/a | Apache-2.0 (open since 2011) | Yes | Yes |
| FLAC | lossless, ~1–5% smaller than ALAC | n/a | free (Xiph) | **No** — `flac only supported in MP4`, no `-strict` escape (8.1.1). Bridge: `-c:a alac` (bit-exact) or PCM | No (not even FLAC-in-MP4) |
| AAC-LC | lossy | ~128–192 kbps VBR; 256 = safe | Via-LA implementation patents; LC core largely expired; **no content fees** | Yes `mp4a` | Yes |
| HE-AAC v1/v2 | lossy (SBR/PS), never transparent | 24–96 kbps design range | patent-active | Yes `mp4a` | Yes |
| xHE-AAC (USAC) | lossy (+ mandatory loudness/DRC metadata) | 12–64 kbps design range | patent-active | Yes `mp4a` — ffmpeg ≥7.1 decodes, **no ffmpeg encoder** (use `exhale`) | Yes (iOS 13+/macOS 10.15+) |
| MP3 | lossy | ~190–245 kbps LAME VBR (`-V2`–`-V0`); 320 CBR = ceiling | patents expired 2017 | **Yes** — copies, tag `.mp3` (8.1.1) | Yes (native, incl. in MOV) |
| MP2 | lossy | ~256 kbps broadcast figure | expired | Yes, non-standard `.mp2` | Not expected |
| Opus | lossy, best-in-class <96 kbps | royalty-free (RFC 6716) | **No** — `opus only supported in MP4`, even for copy (8.1.1). Copies into MP4 (tag `Opus`) | No (not even in MP4) |
| Vorbis | lossy | ~160–192 kbps | royalty-free (Xiph) | version-dependent, non-standard — see below | No |
| AC-3 | lossy | 640 kbps format max (DVD ≤448) | Dolby; decoder patents expired | Yes | Modern macOS: yes (older: spotty) |
| E-AC-3 (+JOC/Atmos) | lossy | typ. 192–768 kbps streaming | Dolby | Yes | **Yes — native** (modern QuickTime) |
| DTS core | lossy | 754.5 / 1509.75 kbps (the "768/1536" are rounded marketing) | DTS/Xperi | Yes `dtsc` | No |
| DTS-HD MA (+DTS:X) | **lossless** (core+XLL) | VBR to 24.5 Mbps | DTS/Xperi | Yes `dtsc` | No |
| TrueHD (+Atmos) | **lossless** (MLP), ≤18 Mbps/8ch | Dolby | **No** — `truehd only supported in MP4` (8.1.1) | n/a |

Encoder picks on macOS builds: **`aac_at`** (AudioToolbox) beats native `aac`
and is the only HE-AAC-capable encoder when `libfdk_aac` is absent (it usually
is — non-free). Always `libopus`/`libvorbis`/`libmp3lame`; the native
`opus`/`vorbis` encoders are experimental — avoid. DTS-HD High Resolution
exists as a middle *lossy* tier (≤6 Mbps, same `dtsc` handling) — `s24le`
decode is fine, no native-depth requirement.

## Object audio (Atmos / DTS:X) carriage

- Atmos is dual-path: **streaming = E-AC-3 JOC** (in-band with the DD+
  bitstream); **disc = TrueHD Atmos extension substream**. DTS:X is an
  extension substream inside DTS-HD (usually on an MA base).
- Consequence: streaming-sourced Atmos survives a MOV remux by `-c copy`;
  Blu-ray TrueHD Atmos **cannot enter MOV at all** (no muxer writes it —
  ffmpeg refuses and no known alternative supports TrueHD) — keep the MKV, or
  write the bit-exact preservation copy to MP4.
- **Object metadata never survives decode-to-PCM** — the decoders render the
  channel bed only (JOC, TrueHD-Atmos, and DTS:X alike). Only `-c copy`
  preserves immersive audio; this is the codec-level justification for the
  dual-track default. Blu-ray TrueHD always interleaves an AC-3 compatibility
  substream — that AC-3 *is* MOV-copyable.

## Containers

| Container | Lineage | Accepts (8.1.1) | Role here |
|---|---|---|---|
| MOV | Apple QTFF 1991, brand `qt  ` — *ancestor* of ISO BMFF | see `ingest-compatibility.md` | the target; archival/editorial |
| MP4 | ISO 14496-14 (2003) on ISO BMFF, QTFF-derived — same box anatomy | **wider audio than MOV**: + Opus, FLAC, TrueHD, AV1; but **rejects ProRes** | standards-track landing zone when MOV refuses a stream |
| M4A | same file, `ipod` muxer convention | **strict**: AAC/ALAC only — MP3 and FLAC refused | audio-only Apple wrapper |
| MKV | Matroska, EBML 2002, RFC 9559 — unrelated lineage | effectively everything | tolerant fallback; strict-mux timestamp validator (Rung 2/3 diagnosis) |
| WebM | restricted Matroska profile | **only** VP8/VP9/AV1 + Vorbis/Opus + WebVTT — enforced at header-write | web delivery only; never a remux target for broadcast sources |
| MPEG-TS | MPEG-2 Systems 13818-1, 188-byte packets, no global index | broadcast set; Annex-B bitstreams | source container (see ingest table) |

MKV attachments (fonts, cover art) have no MOV/MP4 mapping — silently lost on
remux out of Matroska; matters only for ASS subs rendered with attached fonts.

### Second-opinion muxer: Mediabunny

[Mediabunny](https://mediabunny.dev) (npm `mediabunny`, TS/Node) is an
independent QTFF/ISOBMFF/Matroska/TS demuxer+muxer sharing no code with
ffmpeg — useful as a cross-check when ffmpeg's MOV output is suspect, and as
the escape hatch for codecs ffmpeg refuses to write into MOV. Verified
2026-06-10 (v1.46.0): its `MovOutputFormat` writes bit-exact AV1/Opus/FLAC
into `qt`-brand MOV (provenance-only — QuickTime won't play them); ffmpeg
reads the result. Limits that keep it out of the main ladder: no MPEG-2
video, no MP2/MP1, no DTS, no TrueHD — i.e. blind to most broadcast captures.
Passthrough remux needs no codecs; `@mediabunny/server` adds decode/encode in
Node via the FFmpeg C API.

## Oddball inputs

- **HEIC** = HEIF (ISO-BMFF derivative) carrying HEVC intra-coded stills —
  same codec lineage as `hvc1` video, but not a remux-to-MOV input.
- **DSD** (.dsf/.dff/SACD .iso): MOV has no DSD sample format; only path is
  decode to PCM at high depth (`pcm_s24le`+) — faithful render of a lossless
  source, never via a lossy intermediate. ffmpeg demuxes/decodes DSF/DFF.
- **DXD** is ordinary 24-bit/352.8 kHz LPCM — copies into MOV like any PCM,
  subject only to player sample-rate support.

## Version sensitivity (6.1.1 → 8.1.1 deltas observed)

- **Vorbis→MOV**: refused on 6.1.1 ("No in practice"), muxes on 8.1.1 with
  non-standard tag `msVo`. Treat as unplayable either way → decode to PCM.
- **FLAC→MP4**: needed `-strict -2` on older builds; clean on 8.x.
- Opus→MOV, FLAC→MOV, TrueHD→MOV, AV1→MOV: hard-rejected on both — the stable
  rule *for ffmpeg* is "those four live in MP4/MKV, never MOV". Write-side
  policy, not container physics: an independent muxer will carry three of the
  four (see "Second-opinion muxer" above; TrueHD has no path anywhere).
