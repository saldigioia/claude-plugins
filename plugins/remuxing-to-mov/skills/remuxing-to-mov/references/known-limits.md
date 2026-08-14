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
- **Status: detect-and-warn candidate, not implemented** — the parallel of
  `resync.sh`'s mid-stream audio-layout-change refusal (also a mid-stream
  parameter change that rebuilds invisibly). A future probe/ts-health scan
  would compare coded dimensions across the file (e.g. per-packet SPS/sequence
  header sweep) and warn with a split-at-the-splice route. Until then: if a
  broadcast capture is known to span a junction, check
  `ffprobe -show_frames -show_entries frame=width,height` on a suspect region
  and cut at the splice before remuxing.

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

---

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
