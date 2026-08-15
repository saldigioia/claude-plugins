---
title: "Container-Axis Research & Code Defect Register"
deck: "Sourced research answering plugin-help.md §7, plus the exact 1.12.0 code sites producing the wrong conclusions"
type: "research report + defect register"
date: 2026-08-15
target:
  plugin: "rare-data-club/remuxing-to-mov"
  version_audited: "1.12.0"
  version_proposed: "1.13 work-order inputs"
inputs:
  - "plugin-help.md — 2026-08-15 field report (21 GB MPEG-2 4:2:2 1080i29.97 mpegts, MP2 audio)"
sources_policy: "FFmpeg source @ master 6fa1295f (2026-08-15), Apple QTFF docs & SDK headers, MP4RA, ffmpeg trac/devel/user archives, GPAC, vendor docs (AWS MediaConvert), Doom9/VideoHelp expert threads. No content farms."
status: "EXECUTED 2026-08-15 in plugin 1.13.0 — every defect D1-D8 remedied, suite green.
  Remedies: D1 scan-keyed fidelity threshold + Y/U/V plane split (field normalization tried and
  REJECTED on the bench - the deficit is chroma-plane, numbers in known-limits.md); D2 the
  container-swap rung (scripts/mp4-swap.sh, remux.sh --container mp4, mov.sh/auto.sh --mp4-swap,
  named at every fidelity-FAIL route); D3 ipcm allowlisted + allowlist demoted to a prior + the MP2
  no-access-track REVIEW; D4 dual-track alignment measured (start_pts, common window, measured
  shift); D5 mux_census at every mux site (lib-mux.sh, RMX_CENSUS); D6 extension-keeping part names
  everywhere + a hardlink extension guard in playable-check.sh (Quick Look does not follow symlinks
  - measured); D7 the retag advisory keyed on codec+pix_fmt for non-MP4-family sources; D8 the docs,
  including qtff-claims C99-C105 and the dated known-limits entries.
  Regression pins: tests/regression.d/{44-container-axis,45-census-partnames,46-scan-align}.sh plus
  the new tests/fixtures/m2v422i.mov. Open items from Part III that remain OPEN and are recorded as
  such in known-limits.md: the stsd-surgery MOV (mp4v+esds via MP4Box/Bento4) is unbenched; the
  {MOV,MP4}x{profile} matrix, ipcm in Premiere/Resolve/Avid, and macOS 14/15 reproduction are
  unmeasured; the three upstream reports are unfiled."
---

Research was run as three source-restricted threads (ffmpeg muxer internals; QTFF/AVFoundation
dispatch; audio sample entries) plus a line-level audit of the 1.12.0 tree. Part I answers the
field report's §7 research list with citations. Part II is the defect register: where the actual
code produces each wrong conclusion, with file:line. Part III maps both onto remedies.

Legend: **[M]** = measured in primary source (code read, spec text fetched); **[R]** = reported
by a credible secondary source; **[H]** = best-supported hypothesis, not proven; **[NF]** = not
found after named searches.

---

## Part I — Research findings

### I.1 The MOV/MP4 split is an ffmpeg *table artifact*, and the fix is spec-legal (§7.6, §7.1)

- **The `Tag mp4v incompatible with output codec id '2' (m2v1)` error is not muxer logic.** It
  comes from generic muxer init — `libavformat/mux.c` (~line 318): a linear lookup of the user
  tag against the MOV muxer's tag table (`ff_codec_movvideo_tags`, isom_tags.c 163–192), which
  pairs `mp4v` only with `AV_CODEC_ID_MPEG4`. The MP4 muxer's table (`codec_mp4_tags`,
  movenc.c ~9270) pairs `mp4v` with MPEG2VIDEO. Nothing consults QTFF or ISO semantics — the
  restriction is conservative table membership, not spec-driven. **[M]**
- **`mp4v`+`esds` in a MOV is spec-legal QTFF.** Apple's QTFF "Video sample description
  extensions" table defines exactly: `gama`, `fiel`, `mjqt`, `mjht`, **`esds`**, `avcC`, `pasp`,
  `colr`, `clap` — `esds` is a first-class QT video sample-description extension. **[M]**
  (developer.apple.com/documentation/quicktime-file-format/video_sample_description_extensions)
  So the working MP4 entry could legally live in a `.mov`; ffmpeg simply has no path that writes
  it (would need a patched table or post-hoc stsd surgery via MP4Box/Bento4). Upstream question
  worth filing: this failure class appears **unreported** on trac/ffmpeg-devel. **[NF]**
- **`glbl` is an FFmpeg invention, not Apple/ISO.** Absent from the QTFF extensions table and
  from MP4RA's box registry; ffmpeg's own demuxer comment ("Broken files created by legacy
  versions of libavformat will wrap a whole fiel atom inside of a glbl atom") confirms the
  lineage. CoreMedia's documented behavior for unknown stsd atoms is carry-verbatim
  (`kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`), not reject — so `glbl` is
  **probably inert**, not the poison. **[M]**, inertness **[H]**
- **Retagging inside MOV can never change what AVFoundation is fed.** movenc has no
  XDCAM-specific sample-description writer: every MPEG-2 fourcc (`m2v1`, `mp2v`, `hdv3`,
  `xd5*`…) gets the **identical generic body** — `glbl`(extradata) + `fiel` + optional `colr`;
  the tag changes only the fourcc and the compressor-name string (movenc.c 1926–1986,
  2756–2784, 2946). This is exactly why the field report's five retags corrupted identically.
  **[M]**
- **ffmpeg can never auto-select `xd5b` for NTSC.** `mov_get_mpeg2_xdcam_codec_tag` truncates
  `avg_frame_rate` to int — 29.97 → 29, matching neither 30 nor 60 — so 1080i59.94 4:2:2
  silently falls back to `m2v1`. **[M]** (Relevant to why every ffmpeg-made NTSC XDCAM-class
  MOV starts life mistagged.)
- **ffmpeg writes the wrong esds OTI for 4:2:2 — and it doesn't matter on macOS.**
  `ff_mp4_obj_type` (isom.c 42–47) lists MPEG-2 OTIs Main-first; `mov_write_esds_tag` takes the
  first match, so every MPEG-2 stream gets OTI **0x61 (Main Profile)**, never 0x65 (422
  Profile). The field report's MP4 decodes cleanly *despite* declaring Main — which is the key
  mechanism clue (next section). **[M]**

### I.2 Why m2v1-MOV corrupts while mp4v-MP4 decodes — and why xd5b fixed one file pair and not this one (§7.1, §7.2, §7.3)

- **CoreMedia treats the MPEG-2 fourccs as *profiles*, not codecs.** In `CMFormatDescription.h`:
  `kCMVideoCodecType_MPEG2Video = 'mp2v'` is the canonical codec type, and the entire HDV/XDCAM
  family is enumerated as `kCMMPEG2VideoProfile_*` constants — e.g.
  `kCMMPEG2VideoProfile_XDCAM_HD422_1080i60_CBR50 = 'xd5b'`. The names encode chroma, raster,
  field rate **and rate-control class (CBR50)**. **[M]**
- **The MP4/esds ingest path configures the decoder from the parsed elementary stream.** Proof:
  the working MP4 declares OTI 0x61 = Main/4:2:0, yet 4:2:2 decodes correctly — so the ISO path
  cannot be trusting the container's profile claim. **[M-derived]**
- **Best-supported causal hypothesis [H]:** the MOV bridge configures the MPEG-2 decoder from
  the fourcc/profile contract rather than the sequence_extension. A generic tag (`m2v1`/`mp2v`)
  yields a legacy MP@ML-style 4:2:0 frame-decode context: intra frames look near-clean, then
  field-predicted macroblocks drift and chroma is read on 4:2:0 geometry — green/magenta
  garbage that never heals, exactly as measured. `xd5b` worked for the earlier VMA masters
  because those streams sat close enough to the fourcc's profile contract; the current capture
  violates it, so the profile path misconfigures/falls back. The Y-only vs U/V-plane SSIM split
  proposed in plugin-help §7.1 remains the cheap discriminating experiment and is still worth
  running.
- **Prior art confirming the tag axis (not the container axis):** ffmpeg's default `m2v1` MOV
  reported unplayable in QuickTime since 2016 with `mp2v` retag as the then-fix (4:2:0
  material) [R: ffmpeg-user Jan 2016]; AWS Elemental MediaConvert ships a
  `MovMpeg2FourCcControl=XDCAM` option documented as "increases compatibility with Apple
  editors and players" [R: AWS docs]; a broadcast recipient rejected an `M2V1` rewrap as "not
  xdcamhd422" [R: VideoHelp #385312]; trac #6099 (XDCAM HD422 MOV) exists but is unreadable
  (anti-bot wall) [NF-body]. The **container-dependence** (same bits: MOV corrupt, MP4 clean)
  appears novel and unreported upstream. **[NF]**
- **Version/hardware scope (§7.2): unresolved.** No Apple documentation states where the MPEG-2
  decoder derives chroma; no WWDC material on MPEG-2 decode exists; macOS 14.x Sonoma shipped
  (and partially fixed) an unrelated MPEG-1/2 playback regression, evidence the legacy path is
  actively fragile across versions [R: MacRumors thread]. The {MOV,MP4}×{codec-profile} matrix
  of §7.3 remains unmeasured — bench work, not literature.

### I.3 Audio: `ipcm` is real, registered, and increasingly the standard; MP2 is undecodable by AVFoundation (§7.4, §7.5)

- **`ipcm` is the ISO-registered PCM entry for MP4** (ISO/IEC 23003-5, with the `pcmC` config
  box; MP4RA-registered). ffmpeg writes it since commit `d4ee177a` (2023-03-15, first release
  6.1); VLC (master and 3.0.x source) and GPAC read it — GPAC actively *normalizes* QTFF `twos`
  to `ipcm` on MP4 remux; Sony XAVC cameras have shipped it in broadcast delivery since 2021.
  Known holes: Android MediaExtractor cannot play it (2025 report); Windows Media Foundation
  does not document it; Apple ships **zero documentation** — the field report's macOS 26.6.1
  measurement is the only Apple datapoint; Premiere/Resolve support is likely-via-Sony-XAVC but
  unverified for ffmpeg-authored files. **[M/R]** The allowlist's claim that `ipcm` is "a
  sample entry no decoder claims" is **factually false**.
- **QTFF PCM in MOV stays the compatibility king:** `sowt` (16-bit) / `in24`+`enda` (24-bit) —
  exactly what `dual-track.sh` already mints via movenc defaults. `lpcm` is QT-registered only,
  with historical endianness confusion in third-party demuxers. `sowt` is not MP4RA-registered
  at all; `twos` sneaks into the ISO family via MJ2 — the gray-zone Sony exploits. **[M/R]**
- **MP2-in-`mp4a`:** ffmpeg's `mov_write_esds_tag` special-cases MP2/MP3 at >24 kHz to OTI
  **0x6B (MPEG-1 Part 3)** — the *formally correct* declaration for 48 kHz Layer II; the
  ffprobe `mp3` label is a demux-side artifact (`ff_mp4_read_dec_config_descr` maps OTI 0x69
  and 0x6B to `AV_CODEC_ID_MP3`, first-match; per 14496-3 there is no DecoderSpecificInfo to
  carry the layer). So the field report's §7.5 hope is closed: **the OTI is already correct,
  and AVFoundation simply has no Layer II path for `mp4a` tracks** — no positive report of
  Layer II decode in QuickTime X/AVFoundation exists in any container. Treat MP2 as
  undecodable by AVFoundation until a counterexample appears; the PCM access track is not
  optional for this source class. **[M]**, AVFoundation-negative **[R + measured, one bench]**

---

## Part II — Defect register (1.12.0, exact locations)

Paths relative to `skills/remuxing-to-mov/`. Each entry: location — what the code does — why it
is wrong given Part I and the field report — minimal correct behavior.

### D1 — `scripts/playable-check.sh:200-203, 157` · fidelity SSIM has no field normalization; threshold is progressive-tuned

The comparison chain is `scale=…:flags=bicubic,format=yuv444p` on both sides — chroma siting is
normalized, field structure is not (zero hits for `yadif|bwdif|il=|setfield` in the file). The
reference (line 168) is ffmpeg's woven interlaced decode; the avconvert side (line 175) probes
as progressive/deinterlaced. Healthy interlaced windows measured 0.8866–0.9684 against
`RTM_FIDELITY_SSIM:-0.90` (line 157); corrupt windows measured 0.8146–0.8471. The bands nearly
touch: the gate has both false-negative and false-positive risk on interlaced sources, and one
healthy window (0.8866) already fails it.
**Fix:** when the source is interlaced (ffprobe `field_order`), normalize both sides through the
same field handling (e.g. `bwdif` the reference to match avconvert's deinterlace, or compare
field-wise via `il`) and/or apply an interlace-aware threshold; document 0.90 as
progressive-tuned. Y-only + U/V-plane SSIM split as separate diagnostics would also let the gate
*name* chroma-geometry corruption instead of reporting one opaque scalar.

### D2 — `scripts/playable-check.sh:120-123, 228-234` + `scripts/mov.sh:586-592` + `scripts/auto.sh:297-303` + `mov.sh:252-263` · every fidelity FAIL routes to Rung 4; the lossless container swap exists nowhere

All FAIL paths name exactly one deliverable route: "needs Rung 4 (scripts/rung4.sh,
operator-attested re-encode)". `backhaul_routes()` offers keep / MKV-playback / rung4. An
exhaustive case-insensitive sweep of `mp4` across scripts/, SKILL.md, and references/ finds
tool names, unroutable-codec routes (VP9/AV1→MP4), rung4's own .mp4 outputs, and audio
provenance asides — never "same bitstream, MP4 container" as the remedy for a MOV fidelity
FAIL. The field report proves that route passes the plugin's own gate at SSIM 0.9175+ on the
same three timestamps that failed. Part I.1 shows why it works and that it is even spec-legal
inside MOV — ffmpeg just can't write it there.
**Fix:** insert a container-swap rung between retag and rung4 everywhere a fidelity FAIL is
routed: build (or at minimum recommend) `-f mp4 -tag:v mp4v` from the same source, re-run the
fidelity gate on it, and record the result in the machine line (e.g. additive
`PLAYCHECK_FIDELITY … mp4_swap=ok|fail|untried`). Rung 4 becomes the *last* named route.

### D3 — `scripts/verify.sh:519-531, 498-499, 803` · the QTFF audio allowlist makes an untested decoder claim — and is wrong in both directions

The allowlist (`sowt|twos|lpcm|in24|in32|fl32|mp4a|alac|.mp3|ec-3|EC-3|ac-3|AC-3|dtsc|.mp2`)
omits `ipcm`; the rejection text asserts "a sample entry no decoder claims (the dead-HDMV-track
class)" while the comment at 532-533 shows the bounded decode probe is *deliberately skipped*
for off-list tags — the one measurement that would have falsified the claim. `other_failed=1`
makes it unwaivable → exit 1. Container detection (`case ",$g_ofmt," in *,mov,*|*,mp4,*`)
means MP4 builds do reach this gate. Inverse error: `mp4a`/`.mp2` are allowlisted on the
rationale that the PCM access track guarantees playback — but an MP2-only file produces **no
audio** in AVFoundation (Part I.3), so the gate passes the configuration that fails and fails
the configuration that works.
**Fix:** add `ipcm` (measured working, ISO-registered); demote the allowlist from verdict to
prior — an off-list tag triggers the bounded decode probe instead of skipping it, and a clean
decode downgrades FAIL to advisory. Separately: when `mp4a` carries mp2/mp3 (not AAC) and no
PCM access track exists, that is the un-playable configuration and should be the REVIEW.

### D4 — `scripts/verify.sh:744-749` · dual-track "misaligned" is a whole-track md5 over unequal lengths

Both tracks are decoded whole and md5-compared; any length delta flips the hash. The field
report's 1040-sample delta (= both tracks' declared `start_pts`, cross-correlation 1.000000 at
offset 0, zero differing samples where they overlap) reads as "Dual-track audio misaligned" —
a timing claim the test cannot support, and one that invites a "fix" that would introduce real
desync. `start_pts` appears nowhere in verify.sh; no length tolerance or offset estimation
exists in the gate (702-751).
**Fix:** probe both tracks' `start_pts`; if decoded-length delta == start_pts delta, trim to
the common window (or cross-correlate a bounded window) before hashing; report "length delta
N samples = declared start_pts; content aligned at offset 0" and reserve "misaligned" for a
measured nonzero offset.

### D5 — all mux sites · no post-mux stream-count / codec-identity assertion

Mux sites: `remux.sh:360-369`, `dual-track.sh:130-136,172-174`, `resync.sh:161-164`,
`rebuild-paff.sh:~115`, `pairfill-paff.sh:~186`, `trim-to-idr.sh` cut, `metadata.sh:52`. What
exists after a mux is timeline-only (`mux_confessions`) or input-side (`RMX_PLAN … unmapped=N`
at remux.sh:273 is a **plan printed before the mux**; nothing reconciles it against the
output). The field report measured `ffmpeg -c copy -f mov` dropping 1 of 3 streams silently at
`-v warning`. Under the current gates that loss ships green.
**Fix:** after every `mv -f "$PART" "$OUT"`, assert output stream count == planned kept count
and per-stream `codec_name` matches the plan (the RMX_T rows already carry it); loud FAIL on
mismatch. Additive machine line, e.g. `RMX_CENSUS planned=N written=N match=ok`.

### D6 — `scripts/playable-check.sh:57-58, 99, 106-107` + part-file naming · extension-keyed tools trusted without an extension check

Only existence is checked before `qlmanage`/`avconvert` run; qlmanage keys off the extension,
so a `*.mov.part`/`*.mov.premeta`/`*.mov.tmp` name FAILs the floor and the hang text asserts
"the decode stack cannot handle this input" — a decode verdict for a filename problem.
Aggravating: the builders' failure paths deliberately keep artifacts under non-`.mov` names
(`PART="${OUT}.part"` in remux.sh:359, dual-track.sh:118, resync.sh:159, metadata.sh:52,
rebuild-paff.sh:115, pairfill-paff.sh:186; `mov.sh:149-151` keeps `OUT.mov.premeta`) — the
exact artifacts an operator will diagnose. The codebase already learned this lesson elsewhere
(`trim-to-idr.sh:141-144` "real extension kept ('x.part.ts', not 'x.ts.part')";
`qt-groups.sh:240` cites it) and never applied it to the MOV builders or to playable-check.
**Fix:** extension-keeping part names (`x.part.mov`) at every builder; in playable-check, if
the argument lacks a QTFF extension, announce and probe via a symlinked `.mov` name (or refuse
with a filename-not-decode message); soften the hang text to name the extension possibility.

### D7 — `scripts/probe.sh:70, 143-144, 193-195` · the retag advisory is dead on exactly the inputs that need it

`PR_TAG_ADVICE=xd5b` requires `STSD_ENTRY=m2v1`, but `STSD_ENTRY` comes from `mp4_atom_scan`,
which early-returns on non-MP4-family containers (`case "$1" in *mov*|*mp4*|*m4a*) ;; *)
… return 0;; esac`). A **.ts capture** — the field report's input, and the plugin's primary
input class — never fires the advisory pre-build, and no driver re-probes the built MOV. The
advisory only triggers when an operator hand-probes an already-broken MOV.
**Fix:** for mpegts/mpegps sources, key the advisory on `codec=mpeg2video + pix_fmt=yuv422p*`
alone (the stsd entry the *output* will get is known: movenc falls back to `m2v1` for NTSC —
Part I.1's 29.97→29 truncation guarantees it), and/or have `mov.sh` re-probe its own output.

### D8 — `SKILL.md:204` + `references/ingest-compatibility.md:39-91` · the xd5b advisory overclaims; the container axis is unrecorded

The instant-answers row presents retag-to-`xd5b` as *the* remedy for the class ("Decoder
dispatch, not damage. Retag, don't re-encode"). Part I.1 shows every MOV retag ships the same
sample-description body, and the field report measured all five tags corrupting identically on
a real capture — the advisory's premise holds only when the stream matches the fourcc's
profile contract (Part I.2 [H]). No document records the MOV-vs-MP4 split, the measurement, or
the swap route; `known-limits.md` has no entry.
**Fix:** rewrite the row as a two-step: try retag (cheap, works when the profile contract
holds — 2026-08-15 VMA pair), else container-swap to MP4 (`mp4v`+esds — 2026-08-15 21 GB
capture, SSIM 0.9175+ on previously failing timestamps); add the dated known-limits entry and
extend the ingest MPEG-2 row with the container column. Record in `qtff-claims.md` that the
1.12 claim "retag fixes the class" was narrowed the same day it shipped.

---

## Part III — Consequences and open items

**Remedy ladder for the MPEG-2 4:2:2 class, as the evidence now stands:** (1) retag within MOV
— free, works when the stream matches an Apple profile contract; (2) container swap to MP4
with `mp4v` — lossless, measured working, one bench; (3) stsd surgery to build an
`mp4v`+`esds` **MOV** (spec-legal per QTFF; needs MP4Box/Bento4, no ffmpeg path) — would keep
the `.mov` deliverable promise, unbenched; (4) Rung 4 re-encode — last resort only.

**Open bench items (not literature-resolvable):** the Y/U/V-plane SSIM split to confirm the
4:2:0-geometry hypothesis; the {MOV,MP4} × {MPEG-2 4:2:0/4:2:2, AVC-Intra, H.264 Hi422, HEVC
RExt} matrix (§7.3); `ipcm` in Premiere/Resolve/Avid with ffmpeg-authored files; macOS 14/15
reproduction; QuickTime Player GUI vs avconvert equivalence.

**Upstream candidates:** (a) trac report — same MPEG-2 bitstream corrupt in MOV (`m2v1`+`glbl`)
and clean in MP4 (`mp4v`+`esds`) through AVFoundation, apparently unreported; (b) the
29.97→29 fps truncation in `mov_get_mpeg2_xdcam_codec_tag` that makes NTSC XDCAM auto-tagging
unreachable; (c) OTI 0x61-always for MPEG-2 esds where 0x65 (422P) exists.

**Source appendix (primary):** FFmpeg master @ `6fa1295f` — libavformat/{mux.c, movenc.c,
isom.c, isom_tags.c, mov.c}; Apple QTFF video sample description + extensions pages; Apple
`CMFormatDescription.h` (kCMVideoCodecType_MPEG2Video, kCMMPEG2VideoProfile_*); mp4ra.org
codecs/object-types/boxes registries; ffmpeg commits `e4d45673` (XDCAM tags, 2013),
`d4ee177a` (ipcm write, 2023), `cbe216d3` (pcmC read, 2022); trac #6099/#9219/#10185;
ffmpeg-user Jan 2016 (m2v1 unplayable); ffmpeg-devel Feb 2023 (ipcm patch series + the
sowt-vs-ipcm compatibility debate); GPAC issue #3227 (twos/ipcm normalization); AWS
MediaConvert `MovMpeg2FourCcControl` documentation; Apple HT201597 (MPEG-2 component history);
MacRumors Sonoma MPEG regression thread; VideoHelp #385312.
