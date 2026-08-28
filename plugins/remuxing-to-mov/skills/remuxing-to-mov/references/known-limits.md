# Known Limits & Verified Non-Issues

Two lists that keep sessions honest (WO 5.4, 2026-08-14). **Named limitations**:
edge classes the plugin does not handle, written down so the limit is a stated
fact instead of a surprise mid-job. **Verified non-issues**: things that look
like problems, were measured, and are fine — recorded so nobody "fixes" them.
Every claim is dated and command-backed where the bench allowed; anything not
measured on this bench says so.

Bench for the measurements below: macOS 26.6.1, ffmpeg 9.0.1, 2026-08-14
(constructed fixtures; commands inline).

---

## Named limitations

### 33-bit PTS wraparound (~26.5 h)

MPEG-TS carries PES PTS/DTS as **33-bit** counters at 90 kHz, so the clock
wraps every 2^33 / 90000 ≈ 95443.7 s ≈ **26.5 h**. On a wrapped capture the
raw timestamps jump by ≈ −2^33 ticks mid-file.

- **One wrap is handled**: ffmpeg's demuxer unwraps a single rollover on read,
  so a 26.5–53 h capture remuxes with a monotonic timeline. The proof lives in
  the OUTPUT, never in trust: `verify.sh` gate (d) must show strictly
  monotonic DTS on the finished file.
- **≥2 wraps (~53 h+) is the named limitation**: after a second rollover the
  unwrap is ambiguous (two candidate epochs per timestamp) and the rebuilt
  timeline cannot be trusted. No route in this plugin repairs that class —
  split the capture below the wrap horizon before remuxing.
- **Detection**: `ts-health.sh` counts *observed* wraps whole-file (delta
  < −2^32 ticks classified as rollover, not rot — `TSH_WRAP`); `probe.sh`
  prints a duration advisory when the source runs past 24 h (approaching the
  horizon). Both are advisories, not gates: a ≤1-wrap file builds normally.
- Status: the one-wrap unwrap and the wrap counter are implemented and
  fixture-tested (ts-health); the ≥2-wrap break is **documented-not-measured**
  — no 53 h capture on this bench, and constructing one honestly is a
  multi-hour mux. The limit derives from the 33-bit field width, not from a
  measurement.

### Multi-program TS: which program wins (measured 2026-08-14)

A broadcast mux can carry several programs (`nb_programs > 1`), each with its
own video+audio. Measured on constructed 2-program fixtures (mpegts,
mpeg2video + AAC eng/spa, built in BOTH PAT orders), ffmpeg 9.0.1:

- **Video**: every route maps `-map 0:v:0` — the **first video stream in
  ffmpeg's demuxed stream order, which follows PMT parse order = the first
  program in the PAT**. Declared program order decides, not program number,
  bitrate, or any editorial pick (measured: reversing the PAT order flipped
  which resolution won). The other programs' **video is never mapped**; since
  the 1.11 fix round the drop is **announced at run time** on every route that
  funnels through `remux.sh` (mov.sh copy/pcm/multi/dual-plan, auto.sh rungs
  0–2, direct remux.sh): a non-audio stream census WARNs per unmapped stream
  and `RMX_PLAN` carries `unmapped=N`. The PAFF builders
  (`pairfill-paff.sh`/`rebuild-paff.sh`) and a standalone `dual-track.sh` run
  remain silent about it — the residual gap. `probe.sh` prints the program
  count when > 1 so the session knows it is choosing.
- **Audio**: the per-track manifest enumerates `-select_streams a` across the
  **whole file** (all programs, deduped by index — the TS double-listing
  quirk), so the default `--audio-keep all` keeps **every program's audio**
  with its PMT language tags (measured: eng + spa both landed in the output
  next to program 1's video).
- **Route for another program**: isolate it first, then run the normal ladder
  on the intermediate:
  ```
  ffmpeg -nostdin -i IN.ts -map 0:p:<PROGRAM_NUM> -c copy PROG.ts
  scripts/mov.sh PROG.ts
  ```
- Reproduce:
  ```
  ffmpeg -f lavfi -i "testsrc2=s=320x240:r=25:d=3" -f lavfi -i "sine=frequency=1000:d=3" \
         -f lavfi -i "testsrc2=s=640x480:r=25:d=3" -f lavfi -i "sine=frequency=500:d=3" \
         -map 0:v -map 1:a -map 2:v -map 3:a -c:v mpeg2video -b:v 1M -c:a aac \
         -program title=P1:program_num=1:st=0:st=1 -program title=P2:program_num=2:st=2:st=3 \
         -f mpegts twoprog.ts
  scripts/remux.sh twoprog.ts out.mov   # out: 320x240 video + BOTH audio tracks
  ```

### Mid-stream SPS / resolution change (broadcast splice)

A junction/splice can change the coded resolution (new SPS / MPEG-2 sequence
header) mid-capture. Measured on a constructed splice (320x240 + 640x480
MPEG-2 ES concatenated into one TS stream, 2026-08-14):

- The `-c copy` mux **succeeds with no warning**, and the MOV `stsd` declares
  the FIRST resolution for the whole track while ffmpeg's decoder follows the
  in-band headers (frames read back 49×320x240 + 50×640x480 from a track
  claiming 320x240 throughout).
- Nothing catches it today: probe, the mux, verify's gates, and
  playable-check (a thumbnail decodes the first, honest half) all pass. What
  QuickTime renders past the splice on such a file is **unverified** — a
  track whose sample description contradicts half its samples is exactly
  where players diverge.
- **Status: the DETECTION half is implemented (1.15.0)** —
  `scripts/dim-scan.sh` sweeps frame dimensions whole-file (a decode pass,
  deliberately outside demux-only ts-health; background-able), counts the
  changes, names each splice PTS, and routes source-domain: cut at the splice
  (`surgical-cut.sh` on mpegts) or keep the source and do not remux across
  the junction. Exit 0 CLEAN / 10 CHANGE(S) / additive `DIMSCAN_SUMMARY`;
  fixture-pinned in `71-dim-scan.sh` on this entry's own splice recipe. No
  route *auto-runs* it (whole-file decode is not a default cost); `clean.sh`
  names it when a junction is suspected. The mux/verify blindness measured
  above is otherwise unchanged.

### EIA-608/708 captions: preserved, not carried as a track

Two distinct forms, two distinct answers:

- **Embedded CC** (A/53 user data in MPEG-2, SCTE-128 SEI in H.264) live
  *inside the video bitstream*: any `-c copy` carries them untouched with no
  mapping, and `verify.sh --signaling` checks the `closed_captions` flag
  parity source↔output. That is **preservation**, not display: QuickTime
  Player's caption UI reads dedicated CLCP caption *tracks*, and whether it
  also renders embedded-only CC is unverified on this bench. The bits
  survive; players that read A/53/SEI (VLC, ccextractor workflows) get them.
- **Standalone `eia_608` streams** (a demuxed caption stream, e.g. from
  `.scc`): **no plugin route maps them** — every builder maps `0:v:0` +
  audio, so a separate caption stream drops. Since the 1.11 fix round the
  drop **WARNs at run time** on every route through `remux.sh` (`** WARN DROP
  stream #N (subtitle …)` + `RMX_PLAN unmapped=N`); the PAFF builders and
  standalone `dual-track.sh` still drop it silently (residual gap). The historical `Could not find tag for codec
  eia_608` failure is the **MP4** muxer (re-verified 2026-08-14: mp4 still
  refuses); the **MOV** muxer on this bench CAN carry it — measured
  round-trip:
  ```
  ffmpeg -f lavfi -i "testsrc2=s=320x240:r=25:d=4" -i captions.scc \
         -map 0:v -map 1:s -c:v mpeg2video -c:s copy out.mov   # writes a c608 CLCP track
  ffmpeg -i out.mov -map 0:s:0 back.srt                        # decodes back to text
  ```
  So carrying captions as a native QuickTime caption track is a **manual,
  operator-invoked step** today (`-map 0:s -c:s copy` into MOV), not a route
  any script takes. Candidate future work; until then the honest default is:
  embedded CC ride the copy, standalone caption streams are extracted to
  sidecar or carried by hand.

### PCM access track is 16-bit: >16-bit sources lose depth (announced)

The PCM **access** route (`remux.sh` per-track auto and forced `--audio pcm`;
`mov.sh` MODE=pcm rides it) encodes `pcm_s16le`. A source whose decoder-native
format is >16-bit integer — `pcm_bluray`/`pcm_dvd` at `s32` (24-bit HDMV LPCM
in a 32-bit fmt) — therefore ships a 16-bit access track, and in the
single-track MODE=pcm shape there is **no preserved original** to fall back
on. Measured 2026-08-14 (1.11 adversarial review):

```
ffmpeg -f lavfi -i testsrc2=s=320x240:r=25:d=4 -f lavfi -i sine=1000:d=4 \
       -c:v libx264 -pix_fmt yuv420p -c:a pcm_bluray -sample_fmt s32 -f mpegts pcm24.m2ts
scripts/mov.sh pcm24.m2ts pcm24.mov    # DONE; access track pcm_s16le/s16
```

- Since the 1.11 fix round the reduction is **announced**: the access line
  prints `** WARN audio a:N: decoder-native format 's32' exceeds 16-bit … bit
  DEPTH IS REDUCED` (house rule 5 — the loss existed before; the silence was
  the defect).
- Depth-true routes today: `dual-track.sh --pcm auto` (s32→32-bit access,
  where the class allows a preserved original — NOT pcm_bluray/pcm_dvd), or a
  manual `-c:a pcm_s24le` remux.
- **Depth-aware access encoding (s32→pcm_s24le/s32le) on the remux.sh path is
  a recorded 1.12 candidate**, deliberately not slipped into the 1.11 fix
  round (it changes shipped sample data with no work-order item behind it).

### verify.sh gate (d) FAILs matroska cross-check outputs (use ts-health.sh)

A lossless `-c copy` MKV of a clean source FAILs `verify.sh` overall via gate
(d): **matroska legitimately reports N/A DTS on B-frame head packets**
(measured 2026-08-14: `packets=125 N/A-PTS=0 N/A-DTS=2` → rc=1 on a
bit-identical copy). Pre-existing at 1.10.0, unchanged by the 1.11 gate
reform — gate (d)'s zero-N/A demand is a QTFF-shaped assertion.

- **Route**: prove an MKV cross-check/playback copy with `ts-health.sh
  OUT.mkv` (transport, timestamps, seek — container-agnostic), not
  verify.sh. This is what the backhaul routes already prescribe.
- Candidate future shape (not implemented): gate (d) exempting head-packet
  N/A DTS when the output container is matroska.

### `elst` / `use_editlist`: the untouched muxer default

The MOV muxer's `-use_editlist` option (ffmpeg-formats(1), "mov, mp4, ismv"
section) defaults to **auto**: ffmpeg writes an `elst` edit list when the
timeline needs one — nonzero track start, negative initial CTS (B-frame
reorder preroll), audio priming — and QuickTime honors it for initial-delay
and A/V-offset presentation. The confirmed mechanics live in the claims
registry (C06: TS→MOV copy writes the video elst; C12: a 0.4 s audio delay
survives as an empty edit; C04: pairfill's preroll shift lands as empty edit +
MediaTime). **Every route in this plugin leaves the default untouched** — no
script passes `-use_editlist` or `-movflags +negative_cts_offsets`, so
initial-delay behavior is whatever ffmpeg's auto decides for the source.
Candidate future knob for players that mishandle edit lists (C07 — negative
offsets vs `-avoid_negative_ts make_zero` — is UNVERIFIED in the registry);
until a measured case lands, adding the flag would be a knob without evidence.

### XDCAM retag (m2v1 → xd5*): advisory-only — auto-apply deferred

**The authoritative deferral record (maintainer decision, 2026-08-15).**
Measured 2026-08-15 (macOS 26.6.1, ffmpeg 9.0.1): two real 1080i59.94 MPEG-2
4:2:2 broadcast masters tagged `m2v1` decode as macroblock garbage through
AVFoundation while decoding pristine through FFmpeg — decoder **dispatch** by
FourCC, not damage (the third instance of the sample-entry dispatch rule,
after `hvc1`/`hev1` and `dvh1`/`dvhe`). Retagged by stream copy, AVFoundation
decodes both perfectly, frame-for-frame identical to the FFmpeg reference,
and it did NOT enforce XDCAM's nominal 50 Mb/s CBR (19.7 and 31.2 Mb/s VBR
both played):

```
ffmpeg -i IN.mov -map 0 -c copy -tag:v xd5b -movflags +faststart OUT.mov
scripts/playable-check.sh --fidelity OUT.mov   # per-file proof, every time
```

`probe.sh` detects the class (`mpeg2video` + `yuv422p*` + stsd `m2v1` — the
pix_fmt is the discriminator, a 4:2:0 MPEG-2 MOV also carries `m2v1` and gets
no advisory) and prints the retag advisory + additive `PR_TAG_ADVICE=xd5b`
(kv) / `tag_advice` (json). Tag selection: the `xd5*` table in
`ingest-compatibility.md`.

- **Status: advisory-only in 1.12 — no driver auto-applies the tag** (the
  retag asserts XDCAM identity on streams that are not literal XDCAM;
  tolerated by the decoder on two real files is evidence, not a guarantee).
  When the operator applies it, a **provenance note in the output metadata is
  required** — state that the tag was changed and from what (`metadata.sh` or
  `-metadata comment=`); no script applies the tag in 1.12.
- **Status: the auto-apply upgrade is deferred** until these bench items are
  measured (any future session picking this up: measure, then flip):
  1. `xd5c` on a real 1080i50 stream;
  2. the 720p tags `xd59`/`xd5a`;
  3. the 1080p tags `xd5d`–`xd5f`;
  4. whether H.264 High 4:2:2 has an analogous dispatch tag;
  5. confirmation that 4:2:0 MPEG-2 is refused by a geometry check, not
     tried (the probe-side pix_fmt discriminator is in place; the auto-apply
     path must prove the same negative);
  6. geometry-aware tag selection: deriving the right `xd5*` from probed
     geometry/field-rate must be implemented and benched before any
     auto-apply — today's `PR_TAG_ADVICE=xd5b` is a class marker for the
     m2v1-dispatch class, not a per-file tag pick (it says `xd5b` on any
     geometry; the operator picks from the `xd5*` table).
  Only `xd5b` 1080i59.94 is measured (2026-08-15); every other tag is
  per-spec, unmeasured.
- **NARROWED 2026-08-15, the same day it shipped (D8, 1.13):** the retag is
  **not** the remedy for the class — it is step one of two, and on some streams
  it does nothing at all. On a real 21 GB 1080i29.97 4:2:2 capture **all five**
  tags (`m2v1`/`mp2v`/`hdv3`/`xd5b`/`xd5c`) corrupted **identically**, because
  movenc has no XDCAM-specific sample-description writer: every MPEG-2 fourcc
  gets the same generic body (`glbl`(extradata) + `fiel` + optional `colr`;
  movenc.c 1926–1986, 2756–2784, 2946), so a retag changes the FourCC and the
  compressor-name string and nothing else. The advisory holds only where the
  stream matches the fourcc's profile contract (CoreMedia enumerates the
  HDV/XDCAM family as `kCMMPEG2VideoProfile_*` — chroma, raster, field rate and
  rate-control class — under one codec type, `kCMVideoCodecType_MPEG2Video`).
  When it does not: the container axis (next entry).
- **D7 fix (1.13):** the advisory used to require a readable stsd entry, which
  `mp4_atom_scan` only produces for MP4-family containers — so on a **.ts**, the
  plugin's primary input class, it could never fire, and no driver re-probed the
  built MOV. Non-MP4-family sources are now keyed on `mpeg2video` + `yuv422p*`
  alone, because the output's entry is known in advance (`m2v1`).

### The MOV/MP4 container axis for MPEG-2 4:2:2 (named limitation, 2026-08-15)

**ffmpeg cannot write the sample entry that works into a `.mov`.** The same
bitstream that AVFoundation destroys as `.mov` (`m2v1` + `glbl`) renders
correctly as `.mp4` (`mp4v` + `esds`) — measured 2026-08-15 on the 21 GB
capture: SSIM **0.9175+** on the exact timestamps that scored 0.81–0.85 in every
MOV build. `scripts/mp4-swap.sh` is that rung (lossless remux → verify →
`--fidelity` proof), and `mov.sh`/`auto.sh --mp4-swap` take it automatically on
a fidelity FAIL.

The limitation is the *deliverable extension*, not the format:

- `-tag:v mp4v` into MOV dies at header write — `Tag mp4v incompatible with
  output codec id '2' (m2v1)` — from a linear tag-table lookup in generic muxer
  init (`libavformat/mux.c` against `ff_codec_movvideo_tags`, which pairs `mp4v`
  only with MPEG-4). The MP4 muxer's own table pairs it with MPEG-2.
- The entry is **spec-legal in QTFF**: Apple's "video sample description
  extensions" table lists `esds` alongside `gama`/`fiel`/`avcC`/`pasp`/`colr`/
  `clap`. So an `mp4v`+`esds` **MOV** is a legal file ffmpeg has no path to
  write.
- **UNBENCHED route, recorded not implemented:** building that MOV by `stsd`
  surgery (MP4Box/Bento4) would keep the `.mov` deliverable promise. Nobody has
  measured whether AVFoundation then decodes it correctly. Until someone does,
  the honest deliverable for this class is a `.mp4`.
- `glbl` (what the MOV path writes instead of `esds`) is an **FFmpeg invention**:
  absent from Apple's extensions table and from MP4RA's box registry — ffmpeg's
  own demuxer comment calls out "broken files created by legacy versions of
  libavformat". CoreMedia's documented behavior for unknown `stsd` atoms is
  carry-verbatim (`kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`),
  so `glbl` is **probably inert** rather than the poison — hypothesis, not a
  measurement.
- **Upstream candidates (unfiled):** (a) the container-dependence itself — same
  MPEG-2 bitstream corrupt in MOV, clean in MP4, through AVFoundation — appears
  unreported; (b) `mov_get_mpeg2_xdcam_codec_tag` truncating `avg_frame_rate` to
  int, which makes NTSC XDCAM auto-tagging unreachable (29.97 → 29 matches
  neither 30 nor 60); (c) `esds` OTI always 0x61 for MPEG-2 where 0x65 (422P)
  exists.

### Interlaced sources sit in a lower fidelity-SSIM band (measured 2026-08-15)

`playable-check.sh --fidelity`'s 0.90 default is **progressive-tuned**. Healthy
interlaced windows measured **0.8866–0.9684** against **0.8146–0.8471** corrupt
on the field report's real 1080i59.94 capture, and a healthy synthetic
interlaced 4:2:2 clip scored **0.8669** on this bench — i.e. 0.90 false-FAILs
healthy interlaced material. Since 1.13 a declared interlaced `field_order` is
judged against `RTM_FIDELITY_SSIM_INTERLACED` (default **0.86**, inside the
measured gap).

**Residual, stated:** those bands are ~0.02 apart, so the interlaced floor
separates them with thin margin — a corrupt interlaced window at 0.855 would
pass. Two things mitigate it and neither is a proof: the per-plane split now
printed with every sample (`y=`/`u=`/`v=`), and the fact that a FAIL now routes
to a lossless container swap rather than a re-encode.

**Field normalization was tried and rejected — measured, not assumed** (same
bench, same clip, best-frame All SSIM): bwdif on the reference 0.8669 (no-op),
yadif 0.8718, bwdif both sides 0.8661, `setfield=prog` on either or both 0.8669,
`scale interl=0` both 0.8669, an 8-bit-chroma path 0.8669, nearest-neighbour
scaling 0.8612. Every candidate moved the number by ≤0.005. The deficit is not
field STRUCTURE: on the best temporally-aligned frame Y measured 0.9678 against
U 0.8441 / V 0.8461 — healthy interlaced 4:2:2 pays its SSIM in the **chroma
planes**. Do not "fix" this with a deinterlacer.

### Chaptered MOV past ~50 min: movie-timescale overflow warning; geometry-gated chapter-track drop past ~99 min

Measured 2026-08-15 (macOS 26.6.1, ffmpeg 9.0.1), `-t`-swept on constructed
chaptered masters (90 kHz video + 48 kHz audio, and a 16384/8000 control):

- **The movie timescale rides the track timescales.** On the stream-copy
  muxes measured, mvhd landed on the LCM of the output track timescales:
  90000 + 48000 → **720000** (the broadcast-common shape); 16384 + 8000 →
  **2048000**. The auto-built chapter TEXT track's own timescale IS the movie
  timescale (`bin_data` stream at 1/720000, chapter mdhd 720000).
- **Warning onset = 2^31 movie-timescale ticks** (signed-32 overflow, not
  2^32): bracketed at 2982/2983 s at 720000 (2^31/720000 = 2982.6 s ≈
  **49.7 min**) and again at 1048/1049 s at 2048000 (1048.6 s ≈ 17.5 min — a
  finer movie timescale overflows proportionally sooner). Verbatim, mid-mux:
  `FATAL error, file duration too long for timebase, this file will not be
  playable with QuickTime. Choose a different timebase with
  -video_track_timescale or a different container format`.
- **The warning is chapter-linked; the overflow is not.** A chapterless copy
  of the same 6200 s source writes the same version-1 atoms silently — no
  warning at any duration. Chapters present + duration past onset is the
  trigger pair (which is exactly what the scripts' pre-announce gates on).
- **`-video_track_timescale` does not govern it** (measured at 600, 30000,
  90000): mvhd stays 720000, the chapter track stays 1/720000, the warning
  persists. The timescale remedy in `timeline-repair.md` fixes video-track
  overflow only.
- **In-band the warning is benign as measured on this bench**: ffmpeg falls
  back to 64-bit **version-1 atoms file-wide** — mvhd and every tkhd go
  version=1, the chapter track's mdhd with them; only the video/audio mdhd
  keep version 0 (their per-track timescales stay small). At 2990 s: mvhd
  version=1 duration=2152811520, just past INT32_MAX. Whole-file decode 0
  errors, every chapter ffprobe-readable, QT chapter text track + Nero
  `chpl` atom both present. "Benign" is a property of MODERN macOS/ffmpeg as
  measured (2026-08-15) — QuickTime 7-era software reading version-1 atoms
  or the chapter menu is the expected casualty.
- **Past 2^32 total ticks the chapter track can be SILENTLY DROPPED — and
  the gate is chapter GEOMETRY, not file duration alone.** Close-out
  measurement 2026-08-15 (verifier's 8-point matrix, independently
  spot-checked on this bench's rig, same macOS/ffmpeg): movenc drops the QT
  chapter text track **iff the FIRST chapter's duration exceeds 2^31
  movie-timescale ticks AND the total duration exceeds 2^32 ticks** — both
  conjuncts required. Spot-check raw (720000 timescale): 2 equal chapters
  at 6200 s → **dropped** (3 streams → 2; chapters readable only via
  `chpl`; every later open of the file logs `Referenced QT chapter track
  not found` — the dangling tref is a detection signature); first chapter
  3000 s in a 4000 s file → kept (total < 2^32); first chapter 100 s at
  6200 s → kept (first conjunct false); 20×310 s at 6200 s → kept. Both
  earlier same-day measurements were CORRECT on their own geometries: a
  2-equal-chapter rig makes the conjuncts coincide at 5965.2 s (why the
  drop first read as a plain past-2^32 file-duration law), while 20 short
  chapters can never satisfy the first conjunct (why five sweep variants
  here couldn't reproduce it). The 2026-08-15 off-repo incident (6058.5 s,
  20 chapters: warning observed, all chapters intact) is thereby fully
  RECONCILED, not discrepant.
- **The warning is SUPPRESSED whenever ANY single chapter exceeds 2^31
  ticks** — independent of the drop (measured: all three skewed-chapter
  rigs above muxed warning-free, kept and dropped alike; only the 20
  short-chapter rig warned). Consequence: a skewed-chapter source can lose
  its chapter track with NO muxer warning at all — absence of the warning
  is not absence of the risk, which is why the post-build check below stays
  mandatory for any chaptered output past ~5965 s.

```
# sweep rig (this bench) — cheap 6200 s chaptered master:
ffmpeg -f lavfi -i color=s=64x36:r=5 -f lavfi -i anullsrc=r=48000:cl=mono -t 6200 \
       -c:v libx264 -preset ultrafast -c:a aac -video_track_timescale 90000 base.mov
ffmpeg -i base.mov -i ch.ffmeta -map_metadata 1 -map_chapters 1 -map 0 -c copy \
       -t 2982 ok.mov     # no warning; mvhd v0, duration=2147051520 (< INT32_MAX)
#      -t 2983 warn.mov   # FATAL-looking warning; v1 atoms file-wide; file fine
#      -t 6200 long.mov   # 20 short chapters: warns, track kept (first conjunct false)
# swap ch.ffmeta for 2 EQUAL chapters spanning 6200 s -> NO warning (suppressed:
# first chapter 3100 s > 2^31 ticks) and the chapter track is silently DROPPED
# post-build check for any chaptered output past ~5965 s (the drop-risk zone):
ffprobe -v error -show_entries stream=codec_type,codec_name -of csv=p=0 OUT.mov
#      expect the bin_data chapter text track still listed
ffprobe -v error -show_chapters -of csv=p=0 OUT.mov   # expect every chapter
```

- **Status: measured 2026-08-15 (macOS 26.6.1/ffmpeg 9.0.1); drop rule
  confirmed on two independent rigs. `resync.sh` and `mov.sh` pre-announce
  on a chaptered source past `RTM_CHAPTER_TS_WARN_SECS` (default 2900 s,
  just under the 720000-timescale onset; the true onset is
  2^31/movie_timescale, so a finer movie timescale needs a lower setting)
  and add the drop-risk check past `RTM_CHAPTER_TS_DROP_SECS` (default
  5965 s) — a duration gate that is a conservative SUPERSET of the drop
  condition (total > 2^32 ticks is a necessary conjunct), so it can
  over-warn on safe chapter geometries but cannot miss a drop. Announce-only
  — no route drops or rewrites chapters; `-map_chapters -1` is the
  deliberate alternative when chapters are dispensable.**

---

### Scratch cannot be redirected on macOS (`TMPDIR` is ignored)

Every script stages its working files under `mktemp` / `mktemp -d`, and on
macOS neither honours `TMPDIR` — nor does `-t`. Both land in the per-user
`/var/folders/…/T`. Re-measured on this bench (Darwin 25.6.0, 2026-08-28,
WO-1.15.17 Item 3):

```
TMPDIR=/tmp/matmp mktemp -d                        -> /var/folders/…/T/tmp.lth11t0UfV
TMPDIR=/tmp/matmp mktemp -d -t rtmtest             -> /var/folders/…/T/rtmtest.UnzkW3nJ90
TMPDIR=/tmp/matmp mktemp -d "$TMPDIR/rtm.XXXXXX"   -> /tmp/matmp/rtm.QBFLdY
```

Only an **explicit template** obeys the variable. The tree has 14 bare
`mktemp -d` sites and ~12 bare `mktemp` file sites, all affected identically.

- **Consequence**: an operator cannot move a build's scratch onto another
  volume. The boot volume must have room for whatever the rung stages there.
  `rebuild-paff.sh` is the one that matters — it writes roughly 1× the
  source's media (elementary video + one WAV per audio track) before its mux
  starts; the copy rungs stage only logs and probe output.
- **Not a defect in the disk pre-flight**: `rtm_disk_preflight` is handed the
  ACTUAL staging path (`rebuild-paff.sh` passes its own `$WORK`), so it
  measures the volume that will really be written, wherever `mktemp` put it.
  The limitation is operator control, not measurement.
- Status: named limitation. No route around it in this plugin; adding
  `-p "$TMPDIR"`-style templates tree-wide would be a behaviour change to 26
  sites for a knob nobody has asked for, so it is written down instead.

## Verified non-issues (do not "fix" these)

### ADTS AAC → MOV copy: the bitstream filter is automatic

TS/ADTS AAC must become ASC/raw AAC in an MP4-family container, and ffmpeg
does it by itself on `-c copy` — **no manual `-bsf:a aac_adtstoasc` is needed
on any route**. Measured 2026-08-14 (ffmpeg 9.0.1, `tests/fixtures/aac.ts`;
previously verified 2026-08-13 on 8.1.2):

```
ffmpeg -i tests/fixtures/aac.ts -map 0:a:0 -c copy -f data - | head -c2 | xxd
   # fff1 — the source really is ADTS-framed
ffmpeg -v verbose -i tests/fixtures/aac.ts -map 0:v:0 -map 0:a -c copy out.mov
   # "Automatically inserted bitstream filter 'aac_adtstoasc'"
ffprobe -select_streams a:0 -show_entries stream=codec_name,profile,codec_tag_string out.mov
   # aac / LC / mp4a — and the track decodes clean
```

9.x quirk worth knowing: the auto-insert message now prints at `-v verbose`
(8.x printed it at the default level) — **silence in the mux log does not mean
the filter didn't run**; the `mp4a` tag on the output is the proof.

Corollary (1.11 fix round): the reframing changes the **packet-level hash** of
a bit-identical payload, so `verify.sh --audio`'s preserved-original compare
re-hashes the source through `aac_adtstoasc` before judging a dual-track AAC
original — a raw streamhash mismatch alone no longer FAILs an intact track
(`mov.sh IN --always-dual` on a TS/AAC source verifies DONE).

### MPEG-2 4:2:0 → MOV: builds and plays

`remux.sh tests/fixtures/m2v420.ts out.mov` → clean build, and
`playable-check.sh out.mov` → **OK on macOS 26.6.1** (measured 2026-08-14;
also the clean control class in the WO 4.1 falsification bench, 2026-08-13).
Plain-copy class, nothing to route around. (4:2:2 is the separate, per-file
empirical story — SKILL.md's backhaul row and the WO 4.1 notes.)

### Multi-program audio languages survive

Side-effect of the WO 3.4 view-merge dedupe, re-measured here: on the
2-program fixture both audio tracks landed with their PMT `eng`/`spa` tags
intact. The TS double-listing quirk (each stream listed top-level AND
in-program) is already handled by index-dedupe in every manifest consumer.

