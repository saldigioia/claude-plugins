---
name: remuxing-to-mov
description: Losslessly remux broadcast/web video (.ts, .mpg/.vob, .mkv, broken .mov) into a QuickTime-ready .mov without re-encoding. Use when converting or remuxing a capture to .mov/QuickTime (-c copy / stream copy), fixing a glitchy, stuttering, or field-coded/interlaced (PAFF) H.264 remux, losslessly cutting/trimming/concatenating, preserving color/HDR/captions/audio through a container change, or deciding whether a re-encode is unavoidable. Default is always lossless copy, never a re-encode.
allowed-tools: Bash Read Write
---

# Remuxing to MOV (lossless-first)

Move a source into a `.mov` container **without re-encoding**. Re-encoding is a
last resort, scoped as narrowly as possible (audio-only, or one GOP), never the
whole video.

**Governing rule:** stay in stream copy (`-c copy`) as long as the source and
MOV allow. Step off it only when a *named* constraint forces you to.

## Workflow

**Shortcut — the everyday path** (`/remuxing-to-mov:mov FILE`, or "convert FILE to
mov"): `scripts/mov.sh IN [OUT.mov]` does a lossless video copy + QuickTime
technique (`hvc1`/faststart) and builds the dual-track (PCM access + original
preserved) **only when** the source audio won't play in QuickTime
(AC-3/E-AC-3/DTS/MP2); else a plain copy. Verifies, never re-encodes, never touches
the source; output defaults to `<input>.mov`. Use the ladder below for control.

**One-shot ladder (hands-off):** `scripts/auto.sh IN OUT.mov` runs probe → pick the
lowest rung → remux/rebuild → verify → escalate on a bad verdict, in one call. It
routes field-coded (PAFF) straight to the rebuild, **never re-encodes** (Rung 4
stays a human decision), and never touches the source. Two escalation rules
(WO 2.3): a REVIEW whose verify note is **solely** gate (f)'s gap-collapse
signature escalates from a copy-class rung to **Rung 3-SYNC (`resync.sh`)** —
the remedy verify itself named — never to a timestamp-profile repair; and the
final verdict is the grade of the **best verified artifact at OUT** (a failed
escalation is reported separately, never condemns a prior rung —
`AUTO_SUMMARY` carries the additive `best_rung=`/`best_result=` fields beside
the retained `result=`/`rung=`). Exit 0 = verified, 10 = REVIEW, 1 = FAIL; an
11 REFUSED can only propagate from a child's own refusal (e.g. `resync.sh`'s
layout guard). Use the manual ladder below when you want control or hit a
REVIEW/FAIL. Run `scripts/doctor.sh` once on a new machine first.

0. **Health-scan a fresh capture** (optional but cheap — two demux-only passes,
   no decode): `scripts/ts-health.sh INPUT` sweeps the whole file for every
   hidden-damage class at once — transport loss (continuity/TEI/PES, permanent,
   counted honestly), missing PTS/DTS, backward/duplicate DTS rot, forward
   gaps, 33-bit PTS wraparound, mid-GOP capture start (fix implemented:
   `scripts/trim-to-idr.sh`), single-GOP
   unseekability, audio duration drift — and names the **lossless** route for
   each finding (exit 0 CLEAN / 10 FINDINGS / 1 DAMAGED; `--kv` for machine
   output).
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
   carries HDR/captions or you shipped the dual-track build. Every run also checks
   **A/V duration parity** — a discontinuous source whose PCM gaps collapsed on
   copy reads short here, the cheap catch for sync drift. Gate (f) is
   **source-aware** (WO 2.4): over the base 0.25 s tolerance it widens by the
   source's *measured* forward-gap seconds (`disc_scan`, or the caller-supplied
   `RTM_SOURCE_GAP_BUDGET` when SOURCE is an intermediate), so real transport
   loss is explained instead of re-flagged forever — never widened without a
   measurement, and the explained residual is stated, never silent. Gate (g)
   (WO 3.6) proves **audio playability** on every QTFF output track: sample-entry
   tag on a positive allowlist + a bounded head decode — the dead-HDMV-track
   class (an 18.5 GB Blu-ray `pcm_bluray` copy shipped "verified" with
   unplayable audio) FAILs here, and that FAIL is never waivable; non-QTFF
   outputs (an MKV cross-check) get the decode half only.

## The escalation ladder — stop at the first rung that works

```
Rung 0  Pure copy            scripts/remux.sh IN OUT.mov
        when: all codecs MOV-compatible AND timestamps sound.
Rung 1  Copy video, PCM audio   scripts/remux.sh IN OUT.mov --audio pcm
        forced by: MP2/MP1 (non-standard in MOV) or DTS-HD MA (QuickTime won't
        play). remux.sh --audio auto picks this automatically. Video stays
        bit-identical; only audio is decoded (faithful render, not recompress).
        AC-3/E-AC-3 decodes run at FULL dynamic range by default (--drc auto =
        -drc_scale 0, same rule as dual-track.sh; --drc on keeps broadcast
        DRC). 1.11 note: pre-1.11 remux.sh decoded at the ffmpeg default
        drc_scale=1.0, so default PCM output differs from 1.10 on DRC-carrying
        sources — that is the WO 3.7 fix, not drift.
Rung 2  Copy + rebuild timestamps   scripts/remux.sh IN OUT.mov --genpts
        forced by: missing/unset PTS. Bitstream untouched.
        GUILTY-UNTIL-PROVEN on field-coded (PAFF) H.264: genpts can pass the
        strict-mux test yet leave a timeline that tears on scrub — for PAFF use
        Rung 3-PAIR/3, or gate the output through verify.sh's scrub test first.
        NO HELP on pair-timestamped packets (PTS and DTS both absent): genpts
        has nothing to derive from — that class is Rung 3-PAIR, full stop.
Rung 3-PAIR  Pair-mate PTS fill    scripts/pairfill-paff.sh IN OUT.mov
        for PAFF whose pair-mates carry no timestamps (~half the packets, the
        post-mortem class) OR whose surviving PTS shows a reorder pyramid:
        KEEPS every real PTS, fills each mate at +1 field, synthesizes a clean
        DTS ramp. Video bits untouched; gates its own output before blessing.
Rung 3  Rebuild timeline from the elementary stream
        scripts/rebuild-paff.sh IN OUT.mov FIELD_RATE [TIMESCALE]
        for field-coded (PAFF) H.264 with NO surviving reorder pyramid — it
        re-stamps at a constant rate (PTS=DTS), which plays a reordered stream
        in DECODE order (shuffled motion), so it now REFUSES those (use 3-PAIR).
        probe.sh/diagnose.sh route between 3-PAIR and 3 by timestamp profile.
Rung 4  Re-encode (last resort)   scripts/rung4.sh IN --profile h264|hevc|prores
        only: a build whose post-build playable-check FAILs on the target
        macOS (decode support drifts by OS version — proven per file since
        1.11, never assumed per codec), Dolby Vision playback, or a
        frame-exact cut at a non-keyframe. Minimize footprint. rung4.sh is the
        ONLY sanctioned route: it refuses without the operator's verbatim
        attestation and stamps mdta provenance so the derivative can never
        masquerade as a master. Recipes: references/delivery-encode.md;
        smart-cut: references/cutting-concat.md.
```

If `remux.sh` (Rung 0/1) plays back clean, you are done. If the file glitches or
tears on scrub, it is almost always **timestamps, not the video** — run
`scripts/diagnose.sh INPUT` to find the cause and the right rung.

## Diagnose a glitchy / field-coded remux

`scripts/diagnose.sh INPUT` runs the ladder and prints a verdict:
1. decode-to-null integrity **plus transport counters** — a SOURCE DAMAGED
   verdict needs transport EVIDENCE (ts-health pass-1's continuity/TEI/PES/
   scrambled counters, computed identically here), never a decode-error tally
   alone: pre-roll decode noise on a mid-GOP join with **zero** transport
   counters is a WARN (trim at the first IDR, `trim-to-idr.sh`), not damage
   (the false-SOURCE-DAMAGED post-mortem, 2026-08-13);
2. MKV strict-mux test (Matroska refuses the bad/absent timestamps MOV silently
   swallows — this is the decisive test);
3. backward-DTS (non-monotonic timing; **blind to *missing* timestamps**, which
   only step 2 catches — a "0" here does not by itself clear the file);
4. forward-gap (discontinuity) scan — *present and monotonic* timestamps that
   **jump forward** (dropped frames). Steps 1–3 and the mux all pass these; only
   a delta scan finds them, and they are what desyncs raw PCM audio on a blind
   copy (the video keeps the gap; MOV PCM can't, so it collapses).

Verdict → action: damaged → re-capture; missing TS on the **pair signature**
(~half the packets untimestamped, strictly alternating) → **Rung 3-PAIR
(`pairfill-paff.sh`)**; other missing TS → Rung 2 then Rung 3; non-monotonic
DTS → Rung 3-PAIR when real PTS/reorder survives, Rung 3 otherwise;
**discontinuous source → `scripts/resync.sh` (video bit-identical, audio
gap-filled), then the verify parity gate**; **mpegts/MPEG-2 with gaps + rot
(non-monotonic DTS, whole-file) → BACKHAUL TIMELINE ROT: warned with routes
(keep the `.ts` / lossless MKV / `rung4.sh`), then built — the mux-confession
hard stop and verify judge the result (1.11, WO 4.2) — never resync, its
rebuild left near-zero sample durations that verify gate (d) fails**.
**Field-coded (PAFF) H.264 never
goes down the genpts path** — genpts is guilty-until-proven there, because the
strict-mux test proves timestamps are *present and monotonic*, not that the
timeline is *seekable*, and that gap is where PAFF corrupts silently. diagnose
picks between 3-PAIR and 3 from the measured timestamp profile (untimestamped
fraction + reorder scan). Detail and the manual commands live in
`references/timeline-repair.md`.

## Failure reporting & the Rung-4 protocol (doctrine — applies to the session running this skill)

**Diagnostic obligation.** Before ANY failure is reported to the operator:
`scripts/doctor.sh` and `scripts/probe.sh` have been run; every rung *below*
the current one has been **executed, not considered**; and the report is shaped
as an **evidence block** — the commands run, their actual output, the rung
reached, and a falsifiable hypothesis. "It failed — want me to try X?" is a
**forbidden shape**: it outsources the diagnosis the ladder exists to perform.
The two July 2026 production transcripts (the Super Bowl XLVI PAFF session and
the feed.mkv MPEG-2 4:2:2 session) are the canonical exemplars of the required
report shape — measured counts, source baselines, and per-gate classification,
never a bare symptom.

**Rung-4 protocol.** Proposing a re-encode requires the Rungs 1–3 evidence
blocks **in the same message** — a re-encode proposal without the lower rungs
executed is an incomplete task, not a judgment call. The attestation phrase
must originate **verbatim from the operator**: no paraphrase, no "yes"/"go
ahead" substitutes, and it is never supplied on the operator's behalf —
`scripts/rung4.sh` (the only sanctioned path) enforces the exact match and
refuses near-misses. **Explicit exemption, stated here so it cannot be
"clarified" away:** audio-only transforms are NOT Rung 4 — the existing
PCM/AAC access-track paths (and ALAC if 5-2e ever ships it) decode audio as
part of the lossless-video ladder and require no attestation; the attestation
covers the *video* essence, which every other writer hard-guarantees `-c copy`.

**Honest limit (recorded, not hidden):** the rung4.sh gate is a tripwire, not
a wall — a hand-rolled ffmpeg invocation bypasses it. The depth of the defense
is the evidence-block bar above (a session that must present Rungs 1–3
evidence cannot casually propose a re-encode) plus `verify.sh`'s
after-the-fact master-purity scan, which flags video writing-library
signatures (x264/x265/Lavc) on any file presented as copy-lineage and
recognizes properly-stamped rung4 derivatives by their mdta provenance.

## Instant answers (recurring symptom → rule)

| Situation | Rule |
|---|---|
| "Convert this to .mov" (the everyday ask) | `scripts/mov.sh IN` (or `/remuxing-to-mov:mov IN`) — copy video, dual-track audio only if QuickTime needs it, verified. `remux.sh` is the bare Rung-0 copy underneath |
| Fresh capture — "is this TS healthy? what's hiding in it?" | `scripts/ts-health.sh IN` — whole-file, demux-only sweep: transport loss (CC/TEI/PES — **permanent**, no remux restores it), missing timestamps, DTS rot, forward gaps, 33-bit PTS wrap, mid-GOP start (lossless trim at first IDR — `trim-to-idr.sh` performs it), single-GOP unseekability, audio drift. Every finding printed with its lossless route; exit 0/10/1 |
| Multi-program TS (`nb_programs` > 1 — probe prints the count) | v:0 = the **first video stream in PAT/PMT order** wins (measured 2026-08-14, both PAT orders) — the other programs' video is never mapped (since the 1.11 fix round the drop is **announced**: `remux.sh`'s non-audio census WARNs per unmapped stream + `RMX_PLAN unmapped=N`, covering every route that funnels through it; the PAFF builders and `dual-track.sh` standalone remain silent — known-limits.md), while **every program's audio** survives the keep-all default with its PMT language tags. Want another program: `ffmpeg -i IN -map 0:p:N -c copy PROG.ts`, then `mov.sh PROG.ts`. `references/known-limits.md` |
| Capture runs past ~24 h (33-bit PTS horizon) | MPEG-TS PTS wraps at 2^33/90 kHz ≈ **26.5 h**; ffmpeg unwraps ONE rollover on read — remux normally and prove the output (`verify.sh` gate (d) strict monotonicity). **≥2 wraps (~53 h) = named limitation**: ambiguous epochs, no repair route — split below the horizon first. `ts-health.sh` counts observed wraps; `probe.sh` advises >24 h. `references/known-limits.md` |
| Broadcast splice changes resolution mid-stream (new SPS / MPEG-2 sequence header) | **Named limitation — detect-and-warn candidate, not implemented** (the video parallel of resync.sh's audio layout-change refusal): the copy mux succeeds with no warning, `stsd` declares the FIRST resolution while later samples decode at the new size, and no gate catches it (measured 2026-08-14). Junction-spanning capture: check `ffprobe -show_frames -show_entries frame=width,height` around the splice and cut there first. `references/known-limits.md` |
| Capture starts mid-GOP (video packets before the first IDR — undecodable pre-roll) | `scripts/trim-to-idr.sh IN OUT.ts` — the trim ts-health prescribes, **implemented**: locates the first IDR (windowed scan, raised probe window), proves the boundary closed with `gop-probe.sh` (open-GOP boundary → refuses; that trade is the operator's), copy-cuts **both** tracks with `-ss` relative to `start_time` (the WO 1.3 origin, self-documented), blesses only after ts-health's own counter reads **0** pre-keyframe packets + the first output packet is the source IDR byte-for-byte; kept region stream-copied byte-identical. `mov.sh` auto-runs it when its pre-flight sees pre-roll — **announced, never silent**; `--no-idr-trim` keeps the old behavior (also announced). WHY the untrimmed build REVIEWs: ffmpeg streamcopy silently drops the video pre-roll (`-copyinkf` default) while the audio pre-roll lands — a phantom A/V-parity "desync" the trim removes at the source |
| HEVC file won't open in QuickTime | Retag, don't re-encode: `ffmpeg -i IN -c copy -tag:v hvc1 OUT.mov` |
| Plays locally, slow start over network | `ffmpeg -i IN -c copy -movflags +faststart OUT.mov` (moov was at EOF) |
| Video plays, audio silent in QuickTime | Audio QT can't play (AC-3/DTS/MP2) → dual-track default, or `remux.sh --audio pcm`. **E-AC-3 (Dolby Digital Plus) plays natively — just copy it** |
| Glitches/tears only on scrub | Timestamps, not the video → `scripts/diagnose.sh` |
| Audio drifts out of sync over a long capture (leads/lags the picture) | Discontinuous source: dropped frames the video keeps but raw PCM collapses on copy. `scripts/diagnose.sh` finds the forward gaps → `scripts/resync.sh IN OUT.mov` (video bit-identical, audio gap-filled) → `verify.sh` parity gate confirms. resync **refuses** (exit 11) sources whose audio changes channel layout mid-stream — the filter-graph-rebuild silence-injection class — and its verify pass adds `--silence` content parity |
| Backhaul/contribution TS (4:2:2 `yuv422p*`, **any bit depth** — MPEG-2, H.264 Hi422/AVC-Intra, HEVC Rext) | **Demoted to empirical, 1.11 (WO 4.1):** the categorical "QuickTime cannot decode 4:2:2" refusal was **falsified on macOS 26.6.1 (2026-08-13)** — both formerly-refused classes fully decode (qlmanage + `avconvert` whole-file), and the 8-bit-exact gate had let real 10-bit contribution profiles through unannounced. Now every entry point **announces** the profile (`contribution profile <codec>/<pix_fmt>`) and builds losslessly; the **driver paths** (`mov.sh`/`auto.sh`/`batch.sh`-via-auto) then **prove playability on the finished output** (`playable-check.sh` auto-run; additive machine line `MOV_PLAYABILITY os=… verdict=ok\|fail\|skip`), while a **standalone** `remux.sh`/`dual-track.sh`/`pairfill-paff.sh`/`rebuild-paff.sh` run prints the advisory telling the operator to prove it themselves (`playable-check.sh OUT.mov` — no auto-run there). Verdict `fail` → exit 10 REVIEW with Rung 4 named (the file remains a verified lossless NLE/archival master); no macOS/qlmanage → exit 10 REVIEW, `playability unverified on this platform`. `--force-backhaul`/`RTM_FORCE_BACKHAUL` stay API (no-ops for this arm — nothing refuses on pix_fmt). Separately, on MPEG-2 TS, gaps **plus** non-monotonic DTS (timeline rot, whole-file scan) now **warn + build** too (1.11, WO 4.2 — additive `MOV_ROT_WARN` machine line, the old refusal's same three routes, every entry point): the mux-confession hard stop refuses invented timing at the mux, and `verify.sh` judges the finished timeline (bench 2026-08-14: the constructed rot fixture built and drew an evidence-bearing dual-track-misalignment REVIEW, not an exit 11); gaps ALONE rebuild fine (the 2008 recovery) |
| Field-coded (PAFF) H.264 (coded-pic rate ≈ 2× frame rate — the rate counts ALL packets, untimestamped included) | genpts is guilty-until-proven → pair-timestamped/reordered: `scripts/pairfill-paff.sh` (keeps real PTS); no reorder: `scripts/rebuild-paff.sh`; confirm with `scripts/verify.sh` (timeline + scrub gates) |
| Mux log says `pts has no value` / `Timestamps are unset` / `Non-monotonic DTS` on a copy mux | **HARD STOP — the muxer invented the timeline.** Never ship it, whatever verify says about the essence. remux.sh/dual-track.sh refuse automatically; run `scripts/diagnose.sh` for the repair |
| Repair looks fine but motion is subtly shuffled | Constant-rate restamp flattened a reorder pyramid (PTS=DTS = decode order). `verify.sh --full` compares framemd5 presentation ORDER; repair with `pairfill-paff.sh`, never `rebuild-paff.sh` |
| DV / MJPEG / MPEG-4 ASP / ProRes source ("do I need to convert this?") | **No — measured QT-native** (F8 bench 2026-08-14, macOS 26.6.1/ffmpeg 9.0.1): mpeg4(`mp4v`), MJPEG **4:2:0** (`jpeg`), DV (`dvcp`), ProRes (`apcn`) each mux `-c copy` into MOV and fully decode in AVFoundation — `mov.sh` says so and copies losslessly. Non-4:2:0 MJPEG is the C63 measured-DROP class (`PR_VNATIVE=variant`): still copied, playability proven post-build. Codecs outside the matrix (`PR_VNATIVE=no`, e.g. ffv1): copy + post-build proof, never assumed |
| Blu-ray/DVD LPCM audio (`pcm_bluray`/`pcm_dvd`) | **Container-framed LPCM, NOT raw PCM** (WO 3.1): a MOV "copy" muxes into an HDMV-tagged track NO decoder claims — even ffmpeg can't decode the file it just wrote (real 18.5 GB Blu-ray case). Routed to a **PCM access track** by `mov.sh`/`remux.sh --audio auto`; verify gate (g)'s sample-entry allowlist FAILs any shipped dead track. The access track is `pcm_s16le`: a >16-bit source (s32 — 24-bit HDMV LPCM) **loses bit depth there, announced with a WARN** since the 1.11 fix round (single-track MODE=pcm has no preserved original; depth-aware access encoding is a recorded 1.12 candidate — known-limits.md) |
| Mux fails `Could not find tag for codec …` | A subtitle/data stream MOV can't carry (subrip, DVB, teletext, SCTE) — map explicitly `-map 0:v:0 -map 0:a`; text subs → sidecar or `mov_text` (verified 8.1.1: `-map 0` copy with SRT fails at header write) |
| Source carries EIA-608/708 captions | **Embedded** (A/53 user data / SCTE-128 SEI) CC ride *inside the video* — every `-c copy` preserves them, `verify.sh --signaling` proves the flag parity; QuickTime *display* of embedded-only CC is unverified (its caption UI reads CLCP tracks). A **standalone `eia_608` stream** is mapped by NO route (the drop WARNs at run time since the 1.11 fix round — `remux.sh`'s non-audio census — on every route that funnels through remux.sh) — manual carry into MOV works (`-map 0:s -c:s copy` → native `c608` CLCP track, measured 2026-08-14 ffmpeg 9.0.1; **MP4 still refuses** — that's the historical `Could not find tag for codec eia_608`). `references/known-limits.md` |
| Mux fails `… only supported in MP4` | VP9 / AV1 / FLAC / Opus / TrueHD: route to MP4 or keep MKV; FLAC → `-c:a alac` bridge. For VP9/AV1 **video** every scripted entry point refuses pre-flight since 1.11 (`mov.sh`/`auto.sh`/`remux.sh` share the gate — 1.11 fix round; `batch.sh` records the class REFUSED, rows below) — this raw error only surfaces on hand-rolled ffmpeg |
| VC-1 video (Blu-ray/HD-DVD rips) | **REFUSED pre-flight (exit 11, 1.11 / WO 5.2)** — MOV has no VC-1 sample entry, so no lossless `.mov` of the source exists (raw form: `Could not find tag for codec vc1`). The shared gate (`lib-paff.sh`, gate-at-every-entry-point since the 1.11 fix round: `mov.sh`, `auto.sh`, `remux.sh` direct; `batch.sh` records REFUSED) emits `MOV_REFUSED profile=unroutable-vcodec` + the routes: keep the source (archival master) / lossless `-c copy OUT.mkv` for playback (IINA/VLC/mpv) / `rung4.sh` attested re-encode for QuickTime-native |
| VP9 / AV1 video (WebM, web rips) | **REFUSED pre-flight (exit 11, 1.11 / WO 5.2)** — the MOV muxer rejects both (MP4-only carriage; VP9 bench-verified un-muxable, ffmpeg 9.0.1 2026-08-14). Routes: keep / lossless `-c copy OUT.mp4` for playback / `rung4.sh` for QuickTime-native. One honest message + `MOV_REFUSED profile=unroutable-vcodec`, never a raw muxer stack trace — at **every** scripted entry point (`mov.sh`/`auto.sh`/`remux.sh`; `batch.sh` REFUSED row), 1.11 fix round |
| Dolby E audio (codec `dolby_e` — broadcast mezzanine) | **REFUSED pre-flight (exit 11, 1.11 / WO 5.2)** — up to 8 programs per AES3 pair; MOV cannot carry it, and PCM-treating it yields **full-scale noise**. `mov.sh` scans the whole track manifest (honoring `--audio-keep` — an explicit index list excluding the track proceeds, drop announced); since the 1.11 fix round `auto.sh` (any Dolby E track — it has no keep flag) and `remux.sh` (any KEPT Dolby E track) refuse identically via the shared gate. All emit `MOV_REFUSED profile=dolby-e-audio` naming the routes: **specialist decode as an operator-invoked step** (ffmpeg's `dolby_e` decoder → WAV; program/channel assignment is editorial, never automatic) / exclude the track via `--audio-keep` / keep the source. **Named limitation:** Dolby E hiding *inside a PCM track* (SMPTE 337M/AES3 wrapping) is **not auto-detected** — payload sync-word sniffing is out of scope — so a broadcast "PCM" track that plays as steady full-scale noise is the signature; treat it as Dolby E and use the operator decode, never `--audio pcm` |
| `duration too long for timebase` | `-video_track_timescale` from the field-rate table in `references/timeline-repair.md` |
| Trim/cut requested | Copy cuts are keyframe-bound (`references/cutting-concat.md`); check the cut point is a **closed**-GOP keyframe first (`scripts/gop-probe.sh IN CUT_TIME`); frame-exact = smart-cut, the one edit that re-encodes |
| Garbled/"random" frame at a cut or concat **seam** | Open-GOP (partial-sync) boundary: the segment started on an open-GOP I-frame whose leading B-frames referenced the deleted GOP. `scripts/gop-probe.sh` before cutting, `scripts/seam-check.sh JOINED SEAM` after; restart on a closed-GOP keyframe. (A failed scene scan is announced — `>> seam-check: scene scan failed (ffmpeg exited N)` then exit 1 — never a silent death; ffmpeg 9 removed `-vsync`, the script uses `-fps_mode`) |
| Source has several audio tracks | **Every track survives by default** (1.11): `mov.sh` **and** `remux.sh` default to `--audio-keep all` — dropping tracks buys nothing for playability (the muxer already enables exactly one audio track, tkhd-parsed `0x0003/0x0002/0x0002` on a 3-audio build = Apple TN3177's requirement) and the old `layouts` default lost same-codec ties purely on track order (multilang's Spanish track). `--audio-keep layouts` = **opt-in curation**: distinct layout+language pairs survive; same-layout same-language duplicates curated lossless > lossy-high > lossy-low. Every KEEP/DROP prints in a pre-flight manifest with the deciding rule; every drop is a WARN. `first` = the historical a:0-only behavior; explicit indices available. The first mapped track = the QuickTime default |
| Multi-audio .mov shows no QuickTime language menu (tracks present but unselectable) | `tkhd alternate_group=0` — no declared group. ffmpeg 9.x movenc already writes `group=1` + one enabled track (fresh builds conformant, measured 2026-08-14); for 8.x-era / third-party / group-scrubbed files: `scripts/qt-groups.sh IN.mov OUT.mov` (**opt-in post-pass**, WO 5.3) — walks the box tree, patches the 2-byte field per audio tkhd, blesses only after 5 proofs (byte-diff bound, video+audio essence MD5s, independent MP4Box parse, verify.sh). Enable bits reported, never flipped. `references/alternate-group.md` for the full avenue log |
| Missing/wrong audio language tag | `-metadata:s:a:0 language=eng` (PS/`.mpg` sources carry none) |
| Chapters in the source | Survive `-c copy` into MOV — ffmpeg adds a QT chapter text track (verified 8.1.1) |
| Embed metadata into a .mov | `scripts/metadata.sh IN OUT --title … --description …` — proper QuickTime (`mdta`) keys, `-c copy`, drops the generic chapter "menu" + the encoder tag. **Opt-in only, never automatic**; also `mov.sh … --title …` |
| Asked to remux a file onto itself | Never — scripts refuse; write the output beside the source under a new name |
| Old MOVs stopped opening / thumbnails vanished after a macOS update | macOS decode-set drift (Tahoe 26.4 dropped MJPEG variants + AIC; Catalina dropped the QT7-era set). Detect: the `cinepak\|svq\|mjpeg\|icod` grep in `references/ingest-compatibility.md` §"Decode support is a moving target"; playable-check self-dates its OS. Rung 4 (`scripts/rung4.sh`) for a playable copy — the original stays master |
| New machine / CI, or "is my ffmpeg OK?" | `scripts/doctor.sh` — reports required vs degraded capabilities (muxers/bsfs), plus platform / VideoToolbox / optional tools (report-only), before you trust verify.sh |
| A whole folder of captures | `scripts/batch.sh DIR --out OUTDIR` — auto.sh per file + provenance sidecars + a report; idempotent resume, never deletes sources. **Ladder policy** (copy rungs keep every audio track since 1.11 — the PAFF repair rungs still build a:0; no dual-track pair, no signaling check) — for the dual-track deliverable run `mov.sh` per file |
| "Will QuickTime actually play it?" (macOS) | `scripts/playable-check.sh OUT.mov` — AVFoundation render probe; the playable≠valid half ffmpeg can't prove. **A floor, not a sign-off**: a thumbnail proves one frame decodes, nothing about the timeline. Bounded: the qlmanage render gets a deadline (`RTM_QL_TIMEOUT` seconds, default 60, WO 1.4 — a hang counts as no frame = FAIL, never a wedged pipeline); exit 3 = SKIP (not macOS / no qlmanage). Since 1.11 `mov.sh`/`auto.sh` (and `batch.sh` via auto) run it **automatically post-build** on 4:2:2 contribution profiles and the `PR_VNATIVE=variant/no` classes, emitting `MOV_PLAYABILITY os=… verdict=…`; standalone builder runs print the prove-it-yourself advisory instead |

## House defaults (baked into the scripts)

- Video: **always `-c copy`**. HEVC tagged **`hvc1`** (default `hev1` won't play
  in QuickTime). `-movflags +faststart` — knowing its cost: moov is still
  written last, then a second full-file pass relocates it (~2× write I/O per
  output; dominates multi-GB batches on external SSDs). The access copy is
  what needs faststart; a shelved archival master does not.
- Audio under `--audio auto` (WO 3.2, **per kept track**): QT-DECODABLE codecs
  copy bit-exact — AAC / ALAC / MP3 / **raw** PCM / E-AC-3 — and **everything
  else lands as a PCM access track, announced per track with its reason**:
  AC-3 (TN2429 — desktop QuickTime has no AC-3 decode; the dual-track route is
  the AC-3 *keep* path), DTS/MP2/MP1 (QuickTime-unplayable),
  FLAC/Opus/Vorbis/TrueHD (not MOV-copyable), and `pcm_bluray`/`pcm_dvd`
  (container-framed HDMV/DVD LPCM, **not** raw PCM — a MOV "copy" is an
  HDMV-tagged track no decoder claims, WO 3.1). MP3 copies fine (C33).
- **DRC on every AC-3/E-AC-3 → PCM decode** (WO 3.7): `remux.sh` and
  `dual-track.sh` share the audiophile default `--drc auto` = `-drc_scale 0`
  (full dynamic range — ffmpeg's own default bakes `drc_scale=1.0` broadcast
  compression into the samples, audible on a concert mix; `--drc off` = the
  same `-drc_scale 0` as auto); `--drc on` keeps
  broadcast DRC. Decoder-side only: never touches a copy or a non-AC-3
  decode, and the decision is announced in the run log. **Pre-1.11 note:**
  `remux.sh` (and everything routing through it — `mov.sh` multi shape,
  `auto.sh`, `batch.sh`) decoded at 1.0 until 1.11, so default PCM access
  audio differs from 1.10 builds on DRC-carrying sources.
- **Audio track policy** (QTFF audit 5-2; default changed in 1.11, WO 3.3):
  `mov.sh` **and** `remux.sh` default to `--audio-keep all` — every audio
  track is content, and dropping buys **no** playability: movenc enables
  exactly one audio track regardless (tkhd `0x0003/0x0002/0x0002` parsed on a
  3-audio build, bench 2026-08-13 — precisely TN3177), so track-dropping was
  archival curation wearing a compatibility costume. `--audio-keep layouts`
  is the **opt-in** curation flag: distinct layout+language pairs are distinct
  deliverables; same-layout same-language duplicates curated (lossless >
  lossy-high > lossy-low; earlier track wins ties). Every drop is announced
  with its deciding rule in the pre-flight KEEP/DROP manifest; curation
  decisions are auditable — **no silent mapping decisions anywhere**. `first`
  = historical a:0-only. The multi-track shape carries PCM access tracks and
  states plainly that non-native originals are not preserved in that file
  (single-layout original preservation = `dual-track.sh`).
- **Default deliverable is a dual-track MOV**: PCM "access" track first/default
  (always plays in QuickTime) + the original audio copied bit-exact as track 2.
  Non-destructive; never overwrite the source. Lossy sources → `pcm_s24le` with
  `-drc_scale 0`; lossless → PCM at native depth. Build with
  `scripts/dual-track.sh`; rules + QC in `references/dual-track-quicktime.md`.
- **Probe window raised on every input open** (`scripts/lib-probe.sh`): every
  `ffprobe`/`ffmpeg` input in the scripts rides `-probesize 200M
  -analyzeduration 200M` (env-tunable: `RTM_PROBESIZE` bytes /
  `RTM_ANALYZEDURATION` microseconds; both accept SI suffixes, `200M` = 200 MB
  / 200 s). ffmpeg's stock 5 MB window is sized for web MP4s — a 32.4 Mbit/s
  BBC TS carried its first SPS ~6.4 MB in, so the default probe reported no
  dimensions (`[mov] dimensions not set`), and worse, fed `paff=no` into
  routing a working probe later contradicted: a wrong probe silently poisons
  rung selection, it doesn't just block the mux. The values are ceilings, not
  read-ahead — healthy files probe exactly as fast as before. When a mux still
  fails probe-shaped (`dimensions not set` / `Could not find codec
  parameters`), the mux paths retry **once** at 1G on both axes, announced
  first (`** probe window exhausted at default; retrying with 1G — consider
  RTM_PROBESIZE`, WO 1.2); any other failure is never retried.
- `-nostdin` on every call; **atomic output** (`.part` → `mv`); temp/intermediate
  files are **never auto-deleted** and `set -e` gates every step, so a failure
  never reaches cleanup. (One deliberate exception, stated where it happens:
  `mov.sh`'s auto-trim intermediate is removed only **after a verified DONE**;
  on REVIEW/FAIL it is kept and named, because verify compared against it.)
- Color: `colr` is written automatically by modern ffmpeg; do **not** fabricate
  tags for `unknown` sources.

## Exit codes & machine lines (API — extend only, never rename/remove)

**Exit contract** (every script, enforced by `lib-exit.sh`'s ERR trap so no
stray code escapes): `0` DONE · `10` REVIEW · `1` FAIL · `2` usage · `11`
REFUSED. **Documented legacy exceptions** (pre-contract, suite-pinned, each
widening its own allowlist): `pairfill-paff.sh` and `rebuild-paff.sh` REFUSE
with exit **3** (precondition/reorder refusals), and `playable-check.sh` exits
**3** for SKIP (not macOS / no qlmanage). **`verify.sh` never emits 10**: its
verdict is its printed text — `>> OK` and `>> REVIEW` **both exit 0**,
`>> FAIL` exits 1, usage 2 — and callers map the text to the house codes
(`mov.sh`/`auto.sh`/`resync.sh`/`qt-groups.sh` map `>> REVIEW` → their own
exit 10). The accepted-legacy contract is stated in `verify.sh`'s header; a
caller coded to its exit code alone reads REVIEW as green (the qt-groups
defect the 1.11 fix round repaired).

**What still REFUSES (exit 11) in 1.11** — nothing else does: the shared
unroutable-codec pre-flight on VC-1/VP9/AV1 video and Dolby E audio (routes +
`MOV_REFUSED`; since the 1.11 fix round enforced at `mov.sh`, `auto.sh` AND
`remux.sh` — gate at every entry point), and `resync.sh`'s mid-stream
audio-layout-change guard (propagates through `auto.sh`/`mov.sh`; `batch.sh`
counts any 11 as its own `REFUSED` verdict class, never a batch failure). Related hard stops that are
**not** 11: the mux-confession HARD STOP (invented timing) is exit **1**, the
output never blessed; `dual-track.sh`'s FLAC/Opus/Vorbis/TrueHD/MLP rejection
(the preserved-original contract is impossible in MOV) is a pre-flight exit
**2**, nothing written.

**Machine lines** (stable; new fields are appended, existing ones never
renamed — Ground Rule 4):

| Line | Emitter | Fields as printed |
|---|---|---|
| `RMX_T` | `remux.sh` (per audio track, also via `--print-plan`) | kept: `ord= keep=1 codec= ch= layout= lang= disp=copy\|pcm` (disp added WO 3.2 — what this invocation does to the kept track); dropped: `ord= keep=0 codec= ch= layout= lang=` |
| `RMX_PLAN` | `remux.sh` | `policy=all\|first\|layouts\|<indices> kept=<csv\|none> dropped=<csv\|none> unmapped=<N>` (unmapped appended in the 1.11 fix round: count of non-audio streams the route does not carry — subtitle/data/attachment + any second video stream — each also WARNed per stream, house rule 5) |
| `MOV_SUMMARY` | `mov.sh` | `mode=copy\|dual\|pcm\|multi\|none out= audio_kept= audio_dropped= idr_trim=none\|<N>\|skipped\|failed` (idr_trim appended WO 2.2: N = pre-keyframe packets trimmed) |
| `AUTO_SUMMARY` | `auto.sh` | `result= best_rung= best_result= rung=` — the additive `best_*` pair (WO 2.3) sits **before** `rung=` on purpose (batch.sh's greedy `.*rung=` parse) |
| `MOV_PLAYABILITY` | driver post-build check (`lib-paff.sh`) | `os=<macOS\|na> verdict=ok\|fail\|skip` (WO 4.1; self-dating, Ground Rule 6) |
| `MOV_ROT_WARN` | `mov.sh` + shared `backhaul_gate` | `profile=timeline-rot vcodec= disc= back= dup=` (WO 4.2 — warn + build, never a refusal) |
| `MOV_REFUSED` | shared unroutable pre-flight (`lib-paff.sh`; emitted by `mov.sh`/`auto.sh`/`remux.sh` — WO 5.2, parity closed in the 1.11 fix round) | `profile=unroutable-vcodec vcodec=` / `profile=dolby-e-audio track=a:<N>`. The 1.8.0–1.10.0 backhaul values (`qt-undecodable-*`, rot) are **retired — no longer emitted, reserved, never reused** |
| `QTG_SUMMARY` | `qt-groups.sh` | `date= macos= mp4box= audio= enabled= group= patched= out=` |
| `VERIFY_SUMMARY` / `VERIFY_SIGNATURE` | `verify.sh` (waiver flow) | waiver verdict + the exact gate/signature a sidecar must match |
| `TSH_*` / `PR_*`+`PF_*` | `ts-health.sh --kv` / `probe.sh --kv` | KV blocks. Probe additions (WO 5.1/5.2): `PR_VNATIVE` (`--json`: `vnative`) = `yes\|variant\|no\|na` — the measured QT-native matrix; `PR_AUDIO_ACTION` gained `specialist` (Dolby E) beside `copy\|pcm\|none` |

## When to read which reference (load on demand)

| Need | Read |
|------|------|
| "Will this source/codec even copy into MOV?" tables; Annex-B vs AVCC | `references/ingest-compatibility.md` |
| Field-coded/PAFF diagnosis + the full repair ladder + field-rate table; discontinuity (forward-gap) desync + `resync.sh` | `references/timeline-repair.md` |
| Lossless cut / trim / concat, and the frame-exact (smart-cut) boundary | `references/cutting-concat.md` |
| Color/HDR signaling, embedded captions, subtitles (mov_text vs sidecar) | `references/color-hdr-subs.md` |
| Track selection/language tags, verification methods, safety, playable≠valid | `references/verification-safety.md` |
| Atom anatomy, MOV vs MP4, required structure, validation checks; QuickTime metadata (`mdta`) & the chapter-menu strip | `references/container-internals.md` |
| Codec/container landscape: terminology, licensing, efficiency, audio transparency numbers, Atmos/DTS:X carriage, what each container accepts, "what is X / X vs Y" questions | `references/codec-landscape.md` |
| Rung-4 delivery/encode recipes (x264/x265/ProRes) — NOT the lossless path | `references/delivery-encode.md` |
| QuickTime language menu: `alternate_group` mechanics, the measured tool-avenue log (MP4Box `-group-add` recipe, gpac hazards), the 5-proof binary patch | `references/alternate-group.md` + `scripts/qt-groups.sh` |
| **DEFAULT deliverable**: QuickTime-ready dual-track (PCM access + original preserved), alignment-safe two-pass cutting, dual-track QC | `references/dual-track-quicktime.md` + `scripts/dual-track.sh` |
| Named limitations (33-bit PTS wrap, multi-program TS winner, mid-stream SPS change, caption carriage, `use_editlist`) + verified non-issues (ADTS AAC auto-bsf, MPEG-2 4:2:0 plays) — dated, command-backed | `references/known-limits.md` |
| Worked examples from a real broadcast job (copy-cut + QC driver scripts; paths/timestamps hardcoded) | `examples/README.md` |
| Regression tests for the PAFF safeguards — run after editing any script | `tests/README.md` + `tests/regression.sh` |

## Hard-won facts (verified on ffmpeg 6.1.1 / 8.1.1 / 9.0.1 — each claim dated)

The non-obvious traps the scripts are built around — deep detail in the
referenced files.

- **Field-coded (PAFF) H.264 → repair routed by TIMESTAMP PROFILE; genpts is
  guilty-until-proven.** genpts can pass the strict MKV-mux test (timestamps
  present + monotonic) yet leave a timeline that tears on scrub: mux-valid ≠
  seekable, and that gap is where PAFF corrupts silently. `probe.sh`/
  `diagnose.sh` detect PAFF (coded-picture rate ≈ 2× frame rate, **counting
  every packet — untimestamped ones included**, else pair-timestamped captures
  false-read 1×) and route: pair-timestamped or reordered → `pairfill-paff.sh`
  (keeps every real PTS); no surviving reorder → `rebuild-paff.sh`. `verify.sh`
  adds a **scrub gate** (an ffmpeg keyframe seek alone stays clean on the broken
  file, so it is not enough). Decoded `framemd5` FALSE-FAILs field-coded
  streams, so the **Annex-B packet hash** is the lossless arbiter there.
  "Playable ≠ valid" — a real player is the final word.
  → `references/timeline-repair.md`
- **The pair-timestamped PAFF trap (post-mortem 2026-07-25).** Real broadcast
  PAFF can carry PES timestamps only on the FIRST field of each pair — the mate
  has no PTS and no DTS. Straight copy → the MOV muxer INVENTS timing (1-tick
  durations, decode-order PTS): bits perfect, unwatchable file that still
  renders a thumbnail. Three teeth now enforce this: (1) mux-log confessions
  (`pts has no value` / `Timestamps are unset` / `Non-monotonic DTS`) are a
  HARD STOP on any copy mux — remux.sh/dual-track.sh refuse to bless; (2)
  verify.sh gate (d) scans the whole output for N/A timestamps, non-strict DTS,
  and an insane duration histogram; (3) the repair is fully derivable — every
  mate's PTS is exactly +1 field after its timestamped partner
  (`pairfill-paff.sh`). The constant-rate rebuild is WRONG for this class when
  a B-pyramid rides the real PTS: PTS=DTS plays fields in decode order —
  shuffled motion that only a framemd5 presentation-ORDER compare
  (`verify.sh --full`) can see, so `rebuild-paff.sh` refuses reordered streams.
  **Acceptance doctrine:** a FAIL is a defect until every gate is individually
  explained; replicating errors on the source explains only their class (and
  needs MATCHING counts); precedent is not diagnosis.
  → `references/timeline-repair.md`, `references/verification-safety.md`
- **Not every keyframe is a safe cut (open-GOP seam glitch).** A segment starting
  on a partial-sync I-frame (`stps`, vs a full sync sample `stss`) keeps leading
  B-frames referencing the deleted GOP → one garbage frame at the seam, though
  each segment is clean alone. `gop-probe.sh` flags the boundary (a `B` before the
  first `I` in display order); `seam-check.sh` catches the flash. Fix: restart on
  a closed-GOP keyframe, or smart-cut (the one edit that re-encodes).
  → `references/cutting-concat.md`
- **4:2:2 QuickTime decodability is a PER-OS, PER-FILE fact — the categorical
  refusal was falsified and demoted to empirical proof (1.11, WO 4.1).**
  History, kept visible: two controlled pairs (2026-07-30/31, macOS 26.5.2)
  showed MPEG-2 4:2:2 distorting and H.264 High 4:2:2 stalling qlmanage
  against clean 4:2:0 controls, and 1.8.0–1.10.0 refused the class (exit 11)
  at every entry point. **Re-measured 2026-08-13 on macOS 26.6.1: both
  classes fully decode** (qlmanage thumbnail + `avconvert` whole-file, 50/50
  frames), as do 10-bit 4:2:2, 10-bit 4:4:4, and HEVC Rext 4:2:2 — and the
  exact `yuv422p` match had let the actual 10-bit contribution profiles
  (AVC-Intra class) bypass the gate unannounced: the hardcoded claim was
  over- and under-broad at once, exactly the codec-drift rot the plugin's own
  C63 documents (Tahoe 26.4 dropped MJPEG variants/AIC). So the verdict is
  now per-file and post-build: drivers announce `contribution profile
  <codec>/<pix_fmt>` (`yuv422p*`, all bit depths), build losslessly, and
  prove the output with `playable-check.sh` (self-dating its macOS,
  `MOV_PLAYABILITY` machine line); a `fail` or unverifiable platform demotes
  to REVIEW with Rung 4 named — being wrong costs an artifact plus an honest
  warning, never the deliverable. (Bench caveat: the falsifying clips were
  synthetic — they disprove "cannot decode", not every real master; that
  residual is why the check is per-file.)
  Timeline defects are the **orthogonal** axis (buildability, not decodability):
  forward gaps + non-monotonic DTS = backhaul timeline rot — since 1.11 (WO
  4.2) a pre-build **warning**, not a refusal (whole-file demux scan — the
  windowed scan missed mid-file splice defects). The old exit-11 claimed "no
  lossless MOV of this class survives verify": a prediction, while the plugin
  already owns the measured judges — the mux-confession HARD STOP on invented
  timing (kept) and verify's post-build timeline/parity gates. Measured on
  the constructed rot fixture (2026-08-14): the demuxer's own discontinuity
  fixup muxed a monotonic timeline (no confession fired) and verify flagged
  the real defect (dual-track access misalignment → REVIEW) — an artifact
  plus evidence instead of a prediction. Gaps alone rebuild fine. The warn
  (additive `MOV_ROT_WARN` line, the refusal's same three routes) holds at
  **every** `.mov`-writing entry point (shared `backhaul_gate`: `mov.sh`,
  `auto.sh`, `batch.sh`, `remux.sh`, `dual-track.sh`, the PAFF builders — the
  entry-point sharing dates to 1.10.0, closed after a direct build produced a
  doomed 2017-feed MOV the front door would have refused); routes keep the
  source TS/MKV and health-check it (`ts-health.sh`). Related: `resync.sh` refuses
  mid-stream audio-layout-change sources — each change rebuilds the filter
  graph and `aresample first_pts=0` re-pads silence from t=0 (the ~17-min
  injected-silence incident, invisible to duration parity); `verify.sh
  --silence` is the content-parity gate that catches it.
  → `references/timeline-repair.md`
- **Discontinuous source → blind PCM copy desyncs (gap-collapse trap).** When a
  capture drops frames, the video keeps the forward timestamp gap but raw PCM in
  MOV (a contiguous sample array, no gap mechanism) collapses it on `-c copy`, so
  audio slides progressively ahead of picture — and the mux still "succeeds." The
  timestamps are present + monotonic, so the mux tests pass; only a forward-DTS
  delta scan finds it (`diagnose.sh` step 4, `probe.sh`), `verify.sh`'s A/V
  duration-parity gate catches the result, and `resync.sh` fixes it (video
  bit-identical, audio gap-filled — an explicit, human-invoked re-time).
  → `references/timeline-repair.md`
- **Version- and container-gated** (all surfaced by `probe.sh` at runtime):
  Dolby Vision survives `-c copy` only on ffmpeg ≥5.0 (single-layer P5/P8 +
  `-tag:v hvc1`; Profile 7 needs conversion); MOV's muxer hard-rejects
  VP9/AV1/FLAC/Opus/TrueHD ("only supported in MP4" — FLAC has a bit-exact `-c:a alac`
  bridge, MP3 copies fine) and has no VC-1 sample entry at all — since 1.11
  the unroutable video classes (VC-1/VP9/AV1) and Dolby E audio are refused
  pre-flight with routes (exit 11, `MOV_REFUSED`, WO 5.2; shared gate at
  `mov.sh`/`auto.sh`/`remux.sh` since the 1.11 fix round) instead of
  surfacing the raw muxer error; MP2 muxes but QuickTime won't play it (decode to PCM);
  **E-AC-3 (Dolby Digital Plus) plays natively in modern QuickTime → copied
  single-track; AC-3 is dual-tracked for older targets**; `colr` is written by
  default; HDR10 `mdcv`/`clli` live in the HEVC SEI, not container boxes.
  → `references/ingest-compatibility.md`, `references/codec-landscape.md`
