---
name: remuxing-to-mov
description: Losslessly remux broadcast/web video (.ts, .mpg/.vob, .mkv, broken .mov) into a QuickTime-ready .mov without re-encoding. Use when converting or remuxing a capture to .mov/QuickTime (-c copy / stream copy), fixing a glitchy, stuttering, or field-coded/interlaced (PAFF) H.264 remux, losslessly cutting/trimming/concatenating, preserving color/HDR/captions/audio through a container change, or deciding whether a re-encode is unavoidable. Default is always lossless copy, never a re-encode.
allowed-tools: Bash, Read, Write
---

# Remuxing to MOV (lossless-first)

Move a source into a `.mov` container **without re-encoding**. Re-encoding is a
last resort, scoped as narrowly as possible (audio-only, or one GOP), never the
whole video.

**Path convention:** every `scripts/…` and `references/…` path in this document
is relative to this skill's directory — invoke as
`bash "${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/scripts/<name>.sh" …`
(fallback when unset: the in-repo path `skills/remuxing-to-mov/scripts/…`).
The short form is kept in prose for readability, not as a working directory
assumption.

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

-1. **The SOURCE CLINIC** (1.15 — when the deliverable should STAY a `.ts`,
   or before any remux of a suspect capture): `scripts/clean.sh INPUT
   [--deep]` runs the integrity battery in the source's own container and
   routes every finding to a same-container fix — `zero-base.sh` (timeline
   rebase, Tier 1), `trim-to-idr.sh` (pre-roll, Tier 1), `surgical-cut.sh`
   (black-lead cut, Tier 2 — refuses without the operator's
   `--discard-content`), with `verify-source.sh` as the identity prover for
   every same-container output and `clock.sh` translating "starts at X"
   player-clock reports into container addresses first. Report-only; doctrine
   in `references/source-clinic.md`.
0. **Health-scan a fresh capture** (optional but cheap — two demux-only passes,
   no decode): `scripts/ts-health.sh INPUT` sweeps the whole file for every
   hidden-damage class at once — transport loss (continuity/TEI/PES, permanent,
   counted honestly), missing PTS/DTS, backward/duplicate DTS rot, forward
   gaps, 33-bit PTS wraparound, mid-GOP capture start (fix implemented:
   `scripts/trim-to-idr.sh`), single-GOP
   unseekability, audio duration drift — and names the **lossless** route for
   each finding (exit 0 CLEAN / 10 FINDINGS / 1 DAMAGED / 2 usage or
   pre-flight — an input ffprobe cannot read says so and exits 2, never a
   silent 1: "could not read" is not "proven damaged", WO-1.15.4 C4; `--kv`
   for machine output).
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
   tag as a *prior* + a bounded head decode — the dead-HDMV-track
   class (an 18.5 GB Blu-ray `pcm_bluray` copy shipped "verified" with
   unplayable audio) FAILs here, and that FAIL is never waivable; non-QTFF
   outputs (an MKV cross-check) get the decode half only. Since 1.13 (D3) the
   allowlist no longer decides alone: an **off-list tag still gets the decode
   probe** (it used to be skipped there) and a clean decode is an advisory
   REVIEW, not a FAIL — `ipcm` was condemned unwaivably on evidence never
   gathered — while **MP2 with no PCM access track** is now the REVIEW it always
   should have been (AVFoundation has no Layer II path; the gate passed the
   configuration that fails and failed the one that works).

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
        Rung 3-PAIR/3-DERIVE/3 by measured profile, or gate the output through
        verify.sh's scrub test first.
        NO HELP on pair-timestamped packets (PTS and DTS both absent): genpts
        has nothing to derive from — that class is Rung 3-PAIR, full stop.
Rung 3-PAIR  Pair-mate PTS fill    scripts/pairfill-paff.sh IN OUT.mov
        for H.264 PAFF whose pair-mates carry no timestamps (~half the packets,
        strictly alternating — the post-mortem class): KEEPS every real PTS,
        fills each mate at +1 field, synthesizes a clean DTS ramp. Video bits
        untouched; gates its own output before blessing. H.264-only (exit 3 on
        any other codec). A max run of exactly TWO untimestamped packets is the
        displaced-timestamp JUNCTION class (measured 2026-08-18: the PES
        timestamp rides the second field of a pair) — widened fill model,
        announced, gated by a trace_headers cadence census + setts NEXT_PTS
        feature-detect on the way in and a POC-lattice gate on the way out;
        runs > 2 still refuse (exit 3, attested override recordable). A
        FULLY-timestamped reordered stream is NOT this
        class — that is Rung 3-DERIVE (the old doctrine routed it here, into
        this rung's exit 3).
Rung 3-POC   Field-pair + POC timing     scripts/poc-remux.sh IN OUT.mov
        for FIELD-CODED H.264 whose fields are CODED-ADJACENT and share
        frame_num — so the structure IS paired — while their timestamps are
        NOT one field duration apart, so every timestamp-delta rule above
        reads "no pairing here" and refuses. Measured 2026-08-29: 0 of 424,596
        adjacent pairs one field apart on a capture whose fields pair 208,014
        of 208,022 times; the source stamps each bottom field a constant
        offset BELOW its own top. This rung reads the two facts the others
        infer: pairing from field_pic_flag/bottom_field_flag/frame_num (ISO/IEC
        14496-15 — both fields of a pair in ONE sample), timing from
        pic_order_cnt (k = POC + C, C per IDR-epoch AND field parity, >=99.9%
        unanimous over >=100 votes). Fills a hole only from its own POC and
        adjudicates a duplicate display slot only from POC — otherwise it
        refuses the WHOLE file (exit 3). Anchors on the earliest DISPLAYED
        frame. Needs the PyAV venv (absent -> printed bootstrap, exit 10).
        Gates its own output through the full verify suite, (h)-(m) included,
        before blessing. Background: references/paff-poc.md.
Rung 3-DERIVE  Whole-file DTS derivation   scripts/derive-dts.sh IN OUT.mov
        for a PTS-COMPLETE (PF_NOPTS_FRAC=0) reordered stream whose container
        DTS is absent, demuxer-reconstructed (MKV/raw ES) or carried-but-rotten
        — the derivation discards DTS either way and re-derives it from the
        sorted PTS column (DTS[i] = (i-D)-th smallest PTS). Codec-agnostic
        (mpeg2video/HEVC ride the same rung — packets copied byte-for-byte);
        needs the PyAV venv (absent -> printed bootstrap, exit 10 REVIEW).
        REFUSES (exit 3) outside its signature: missing PTS -> 3-PAIR;
        duplicate PTS or depth class unknown (unparseable SPS) -> diagnosis,
        with --force as the announced operator override.
Rung 3  Rebuild timeline from the elementary stream
        scripts/rebuild-paff.sh IN OUT.mov FIELD_RATE [TIMESCALE]
        for field-coded (PAFF) H.264 with NO surviving reorder pyramid — it
        re-stamps at a constant rate (PTS=DTS), which plays a reordered stream
        in DECODE order (shuffled motion), so it REFUSES those (H.264-only;
        the refusal names 3-DERIVE for the PTS-complete reordered class).
        probe.sh/diagnose.sh route between 3-PAIR, 3-DERIVE and 3 by measured
        timestamp profile.
Rung 3-SWAP  Lossless container swap   scripts/mp4-swap.sh IN [OUT.mp4]
        when: the build verifies lossless but its post-build FIDELITY proof
        FAILs — QuickTime opens it and renders the wrong pixels. Same bitstream,
        MP4 container, sample entry mp4v+esds instead of the MOV's m2v1+glbl.
        Measured 2026-08-15 (21 GB MPEG-2 4:2:2 1080i29.97): SSIM 0.9175+ on the
        exact timestamps that failed as .mov, where all five MOV retags scored
        0.81-0.85. It builds, verifies AND re-runs the fidelity gate on the .mp4.
        The deliverable is a .mp4 by necessity: ffmpeg's MOV tag table refuses to
        write that entry into a .mov (spec-legal there, per Apple's QTFF video
        sample-description extensions list — only stsd surgery could, unbenched).
        mov.sh/auto.sh --mp4-swap take this rung automatically on a fidelity FAIL;
        without the flag they NAME it (no unrequested second deliverable).
Rung 4  Re-encode (last resort)   scripts/rung4.sh IN --profile h264|hevc|prores
        only: a build whose post-build playable-check FAILs on the target
        macOS (decode support drifts by OS version — proven per file since
        1.11, never assumed per codec) AND whose container swap (Rung 3-SWAP)
        also failed — since 1.13 a fidelity FAIL is never routed straight
        here — plus Dolby Vision playback, or a
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
(`pairfill-paff.sh`)**; other missing TS → Rung 2 then Rung 3; non-monotonic /
rotten DTS routed by **measured profile**: `PF_NOPTS_FRAC≈0` ∧ reorder →
**Rung 3-DERIVE (`derive-dts.sh`)** — DTS absent, reconstructed or
carried-but-rotten alike, **any codec** (non-H.264 timeline rot goes here too:
pairfill/rebuild are H.264-only); **PTS-complete EXCEPT isolated unstamped
packets** (`0 < nopts_frac ≤ RTM_SPARSE_NOPTS_MAX`, 1.15.20) → the same rung: a
bounded **pre-pass stamps each hole from its PAFF pair-mate** and the
derivation then runs unchanged, refusing the WHOLE file (exit 3, nothing
written) if any hole has no timestamped mate — the class between the two rungs,
which used to have no route at all; half-timestamped → Rung 3-PAIR; **field-coded, reordered, structurally paired
but not +1-field stamped** (the slice headers show complementary field pairs and
pic_order_cnt is readable) → **Rung 3-POC (`poc-remux.sh`)**; no surviving
reorder → Rung 3; depth class `unknown` (unparseable SPS) ∧ reorder → **no
automatic rung** — announced, with `derive-dts.sh --force` named as the
operator's call;
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
picks between 3-PAIR, 3-DERIVE and 3 from the measured timestamp profile
(untimestamped fraction + reorder scan + depth class), and every verdict prints
the measurements that drove the route. Detail and the manual commands live in
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
| "Check/clean/fix this capture but KEEP it a .ts" (no remux wanted) | **The source clinic** (1.15): `scripts/clean.sh IN [--deep]` — probe + ts-health + black-lead check (+ dim-scan/full decode on `--deep`), every route same-container: `zero-base.sh` / `trim-to-idr.sh` (Tier 1, structural) or `surgical-cut.sh` (Tier 2 — **content-discarding, refuses without the operator's `--discard-content`**; never supply that flag on your own). Outputs are siblings proven by `verify-source.sh`; the original is never touched. `references/source-clinic.md` |
| "Video starts at X" / "the glitch is at X" (any player-time report) | **Translate the clock FIRST**: players report player-clock, ffprobe reports container time; they differ by `format.start_time`. `scripts/clock.sh IN X` prints the container address, bracketing keyframes, and per-frame luma around it — then diagnose at the RAW address (the feed.ts lesson: player 1.360 = container 1.560 on a 0.200 start) |
| Capture opens on black (player shows black at 0:00, picture cuts in later) | The **black-lead signature** (black IDR GOP → program at the next keyframe, audio already hot): `scripts/lead-check.sh IN` measures it (luma sweep + keyframe census + gop-probe boundary + audio level) and emits the exact `surgical-cut.sh` command — a Tier-2 cut that discards real audio under the black, stated to the second, operator-gated |
| Timeline starts at nonzero (format.start_time > 0) and the deliverable stays TS | `scripts/zero-base.sh IN OUT.ts` — lossless re-wrap to the floor (`-muxdelay 0 -muxpreload 0`, PID/program layout preserved), the floor stated up front (first frame's reorder delay; exact 0.000000 is impossible with B-frames without inventing DTS — refused on doctrine), prediction-contract gated (a true dry run of the same mpegts mux, count == mux-log nudges; 1.15.2 Defect B). Refuses rotten timelines toward `diagnose.sh`, and refuses pair-timestamped PAFF at pre-flight toward `pairfill-paff.sh` (1.15.2 Item C: the copy invents timing there, and the prize is a start_time every player rebases away) |
| Precision cut needed on TS at a non-IDR boundary (the -ss forms overshoot) | Both `-ss` forms are **measured-unreliable** on TS (keyframe-hunting + index-less seek). The sanctioned recipe: census → `scripts/surgical-cut.sh` (packet-index/PTS `noise=drop` selection, `-copyts` + `-output_ts_offset`, leading-B rule applied) → filtered-reference verification. `references/source-clinic.md` |
| Multi-program TS (`nb_programs` > 1 — probe prints the count) | v:0 = the **first video stream in PAT/PMT order** wins (measured 2026-08-14, both PAT orders) — the other programs' video is never mapped (since the 1.11 fix round the drop is **announced**: `remux.sh`'s non-audio census WARNs per unmapped stream + `RMX_PLAN unmapped=N`, covering every route that funnels through it; the PAFF builders and `dual-track.sh` standalone remain silent — known-limits.md), while **every program's audio** survives the keep-all default with its PMT language tags. Want another program: `ffmpeg -i IN -map 0:p:N -c copy PROG.ts`, then `mov.sh PROG.ts`. `references/known-limits.md` |
| Capture runs past ~24 h (33-bit PTS horizon) | MPEG-TS PTS wraps at 2^33/90 kHz ≈ **26.5 h**; ffmpeg unwraps ONE rollover on read — remux normally and prove the output (`verify.sh` gate (d) strict monotonicity). **≥2 wraps (~53 h) = named limitation**: ambiguous epochs, no repair route — split below the horizon first. `ts-health.sh` counts observed wraps; `probe.sh` advises >24 h. `references/known-limits.md` |
| Broadcast splice changes resolution mid-stream (new SPS / MPEG-2 sequence header) | **Detector implemented (1.15)**: `scripts/dim-scan.sh IN` — whole-file frame-dimension sweep (a decode pass, background-able; `clean.sh --deep` runs it) counts the changes and names each splice PTS. The downstream blindness is unchanged and measured (2026-08-14): the copy mux succeeds with no warning, `stsd` declares the FIRST resolution while later samples decode at the new size, and no mux/verify gate catches it — so the routes are source-domain: cut at the splice (`surgical-cut.sh` on TS) or do NOT remux across the junction. `references/known-limits.md` |
| Capture starts mid-GOP (video packets before the first IDR — undecodable pre-roll) | `scripts/trim-to-idr.sh IN OUT.ts` — the trim ts-health prescribes, **implemented**: locates the first IDR (windowed scan, raised probe window), proves the boundary closed with `gop-probe.sh` (open-GOP boundary → refuses; that trade is the operator's), copy-cuts **both** tracks with `-ss` relative to `start_time` (the WO 1.3 origin, self-documented), blesses only after ts-health's own counter reads **0** pre-keyframe packets + the first output packet is the source IDR byte-for-byte; kept region stream-copied byte-identical. `--preflight-only` answers "would you trim?" without writing (exit 0 eligible / 2 would refuse, reasons on stderr) — `clean.sh` asks it instead of printing the route off the ts-health counter (1.15.18, the zero-base convention). `mov.sh` auto-runs it when its pre-flight sees pre-roll — **announced, never silent**; `--no-idr-trim` keeps the old behavior (also announced). WHY the untrimmed build REVIEWs: ffmpeg streamcopy silently drops the video pre-roll (`-copyinkf` default) while the audio pre-roll lands — a phantom A/V-parity "desync" the trim removes at the source |
| HEVC file won't open in QuickTime | Retag, don't re-encode: `ffmpeg -i IN -c copy -tag:v hvc1 OUT.mov` |
| MPEG-2 4:2:2 glitches/smears in QuickTime but plays clean in IINA/VLC (the built `.mov` carries stsd `m2v1`) | Decoder **dispatch**, not damage — and a **two-step**, narrowed 2026-08-15 (D8, 1.13; the 1.12 row claimed the retag WAS the remedy). **1. Retag** (free, 4 bytes, bitstream bit-identical): `ffmpeg -i IN -map 0 -c copy -tag:v xd5b -movflags +faststart OUT.mov` — works when the stream matches the fourcc's profile contract (measured 2026-08-15 on the VMA 1080i59.94 pair: garbage as `m2v1`, frame-for-frame identical to the ffmpeg reference as `xd5b`; CBR not enforced). **2. If the retag does not fix it, swap the container:** `scripts/mp4-swap.sh IN` — same bitstream, `.mp4`, sample entry `mp4v`+`esds` (measured the same day on a 21 GB 1080i29.97 capture where **all five** tags — `m2v1`/`mp2v`/`hdv3`/`xd5b`/`xd5c` — corrupted **identically**, because movenc gives every MPEG-2 fourcc the same generic sample-description body: `glbl`+`fiel`+`colr`. The swap scored SSIM 0.9175+ on the very timestamps that failed). ffmpeg cannot write `mp4v` into a `.mov` (`Tag mp4v incompatible with output codec id '2'`) — that is a **muxer tag-table artifact**, not QTFF: Apple lists `esds` among the legal video sample-description extensions, so the entry is spec-legal in MOV and only `stsd` surgery (MP4Box/Bento4, unbenched) could put it there. Rung 4 is step 3, not step 1. `probe.sh` fires the advisory on **.ts sources too** since 1.13 (D7 — it was dead on every TS before). |
| A stream you mapped is missing from the output (or came out as another codec) | **Post-mux census** (D5, 1.13): every builder now reconciles its own plan against the finished file BEFORE blessing it — `RMX_CENSUS stage=… planned=N written=M codecs=ok\|mismatch\|na match=ok\|MISMATCH`, run on the `.part` file, and a mismatch is a loud exit 1 with nothing under the real name. Motive: `ffmpeg -c copy -f mov` was measured dropping 1 of 3 streams at `-v warning` — silently — and every downstream gate passed, because they only ever examined the streams that survived. `RMX_PLAN … unmapped=N` is still a plan *printed before the mux*; the census is the half that looks at the file |
| Output has MP2 audio and no PCM access track | **No audio in QuickTime** — AVFoundation has no MPEG Layer II path for `mp4a`/`.mp2` tracks (no positive report of Layer II decode in QuickTime X/AVFoundation exists in any container; ffmpeg's `mov_write_esds_tag` already declares the formally-correct OTI `0x6B`, so there is nothing to fix on the write side). `verify.sh` gate (g) REVIEWs this configuration since 1.13 (D3) — before that it *passed* it while FAILing configurations that work. Rebuild: `scripts/mov.sh` (routes MP2 to dual-track automatically) or `remux.sh --audio pcm`. The `.mp2` allowlist entry is legal only as dual-track's **preserved original**, where the PCM access track is what plays |
| Verify FAILs an audio sample entry it doesn't recognize (e.g. `ipcm`) | The allowlist is a **prior, not a verdict** since 1.13 (D3): an off-list tag now runs the bounded decode probe (pre-1.13 the probe was deliberately *skipped* there — the one measurement that could falsify the claim), and a clean decode downgrades the FAIL to an advisory REVIEW. `ipcm` is explicitly allowlisted: it is the ISO-registered PCM entry (ISO/IEC 23003-5 + `pcmC`, MP4RA-registered, written by ffmpeg since 6.1, read by VLC/GPAC, shipped by Sony XAVC since 2021) and it is exactly what `-c:a pcm_s16le -f mp4` produces — i.e. what the container-swap rung's access track is. The old text ("a sample entry no decoder claims") was factually false about it |
| Plays locally, slow start over network | `ffmpeg -i IN -c copy -movflags +faststart OUT.mov` (moov was at EOF) |
| Video plays, audio silent in QuickTime | Audio QT can't play (AC-3/DTS/MP2) → dual-track default, or `remux.sh --audio pcm`. **E-AC-3 (Dolby Digital Plus) plays natively — just copy it** |
| Glitches/tears only on scrub | Timestamps, not the video → `scripts/diagnose.sh` |
| Audio drifts out of sync over a long capture (leads/lags the picture) | Discontinuous source: dropped frames the video keeps but raw PCM collapses on copy. `scripts/diagnose.sh` finds the forward gaps → `scripts/resync.sh IN OUT.mov` (video bit-identical, audio gap-filled) → `verify.sh` parity gate confirms. resync **refuses** (exit 11) sources whose audio changes channel layout mid-stream — the filter-graph-rebuild silence-injection class — and its verify pass adds `--silence` content parity |
| Backhaul/contribution TS (4:2:2 `yuv422p*`, **any bit depth** — MPEG-2, H.264 Hi422/AVC-Intra, HEVC Rext) | **Demoted to empirical, 1.11 (WO 4.1):** the categorical "QuickTime cannot decode 4:2:2" refusal was **falsified on macOS 26.6.1 (2026-08-13)** — both formerly-refused classes fully decoded the synthetic bench clips (qlmanage + `avconvert` whole-file; renders — correctness is per-file, see the 2026-08-15 narrowing later in this row), and the 8-bit-exact gate had let real 10-bit contribution profiles through unannounced. Now every entry point **announces** the profile (`contribution profile <codec>/<pix_fmt>`) and builds losslessly; the **driver paths** (`mov.sh`/`auto.sh`/`batch.sh`-via-auto) then **prove playability on the finished output** (`playable-check.sh` auto-run — since 1.12 with `--fidelity`, the SSIM proof it rendered *correctly*, after two real 4:2:2 masters false-greened the thumbnail-only check on 26.6.1, 2026-08-15; additive machine line `MOV_PLAYABILITY os=… verdict=ok\|fail\|skip fidelity=ok\|fail\|skip`), while a **standalone** `remux.sh`/`dual-track.sh`/`pairfill-paff.sh`/`rebuild-paff.sh` run prints the advisory telling the operator to prove it themselves (`playable-check.sh OUT.mov` — no auto-run there). Verdict `fail` → exit 10 REVIEW routed to the **container-swap rung first** (1.13 D2: `scripts/mp4-swap.sh`, or `--mp4-swap` on `mov.sh`/`auto.sh` to have it built and proven automatically), with Rung 4 named LAST (the file remains a verified lossless NLE/archival master); no macOS/qlmanage → exit 10 REVIEW, `playability unverified on this platform`. The fidelity threshold is **scan-keyed** since 1.13 (D1): 0.90 is progressive-tuned and false-FAILs healthy interlaced material — measured 0.8866–0.9684 healthy vs 0.8146–0.8471 corrupt on the field report's real 1080i59.94 capture, and 0.8669 on a healthy synthetic interlaced 4:2:2 clip on this bench — so a declared interlaced `field_order` is judged against `RTM_FIDELITY_SSIM_INTERLACED` (0.86, in the measured gap; the ~0.02 margin is a stated residual). Field normalization was tried and REJECTED, measured not assumed (bwdif/yadif on either or both sides, `setfield=prog`, `scale interl=0`, an 8-bit chroma path, neighbour scaling: every candidate moved the score ≤0.005) — the deficit is chroma-plane, not field-structure, which is why the gate now reports the **Y/U/V split** (`y=`/`u=`/`v=` on `PLAYCHECK_FIDELITY`) and NAMES a luma-survives-chroma-collapses failure instead of returning one opaque scalar. `--force-backhaul`/`RTM_FORCE_BACKHAUL` stay API and nothing refuses on pix_fmt anywhere — but they are **not** no-ops for this arm, and the claim that they were is **corrected (P1c, measured 2026-08-16)**: both short-circuit the whole shared `backhaul_gate`, the contribution advisory included, so a **standalone** `remux.sh <4:2:2 source>` prints **1** advisory line plain and **0** with `RTM_FORCE_BACKHAUL=1` (same 1 → 0 on `dual-track.sh`). What *is* true is the narrower statement about **`mov.sh`'s front door**: `mov.sh` prints the advisory itself, before and independently of that gate, so `mov.sh IN OUT` and `mov.sh IN OUT --force-backhaul` both print it (2 lines each) — on `/mov` the flag really does leave the pix_fmt arm untouched. The flags change what is **announced** at the child entry points, never what is built. Separately, on MPEG-2 TS, gaps **plus** non-monotonic DTS (timeline rot, whole-file scan) now **warn + build** too (1.11, WO 4.2 — additive `MOV_ROT_WARN` machine line, the old refusal's same three routes, every entry point): the mux-confession hard stop refuses invented timing at the mux, and `verify.sh` judges the finished timeline (bench 2026-08-14: the constructed rot fixture built and drew an evidence-bearing dual-track-misalignment REVIEW, not an exit 11); gaps ALONE rebuild fine (the 2008 recovery) |
| Field-coded (PAFF) H.264 (coded-pic rate ≈ 2× frame rate — the rate counts ALL packets, untimestamped included) | genpts is guilty-until-proven → pair-timestamped (~half untimestamped): `scripts/pairfill-paff.sh` (keeps real PTS); reordered + structurally paired but not +1-field stamped: `scripts/poc-remux.sh` (Rung 3-POC — pairs per 14496-15, times from pic_order_cnt); PTS-complete + reordered: `scripts/derive-dts.sh` (Rung 3-DERIVE); no reorder: `scripts/rebuild-paff.sh`; confirm with `scripts/verify.sh` (timeline + scrub + the container gates (h)-(n)) |
| A remux is bit-identical to its source and still wrong | An essence hash is necessary and NOT sufficient — it cannot see what the container DECLARES. `verify.sh` gates: (h) declared sample count vs the ISO/IEC 14496-15 structure (one sample per coded FIELD = ~2× the real rate, and it stutters); (i) sample entry vs payload (a `.mp3` entry over Layer II decodes fine and is still a mislabel); (j) duplicate display slots; (k) presentation order vs pic_order_cnt; (l) the first-displayed-frame anchor. Measured 2026-08-29 — both defects passed every gate the plugin had. `references/paff-poc.md` |
| "Would this even mux?" — before refusing to try | Never predict it. `scripts/attempt-battery.sh IN` runs nine plain `-c copy` variants and reports what actually happened. A pre-flight refusal is legal only when that measurement says every variant fails (a CACHED DETERMINISTIC ATTEMPT) — see `TIERS.md`. |
| Mux log says `pts has no value` / `Timestamps are unset` / `Non-monotonic DTS` on a copy mux | **HARD STOP — the muxer invented the timeline.** Never ship it, whatever verify says about the essence. remux.sh/dual-track.sh refuse automatically; run `scripts/diagnose.sh` for the repair |
| The junction POC gate kept a `.part` (UNPROVEN or FAILED), or you want the lattice verdict on any built artifact without rebuilding | `scripts/poc-gate.sh ARTIFACT [--maxlsb N]` — the same gate standalone (direct-output extraction + the §8.2.1.1 unwrap); `--table CSV` judges a prepared `idr,poc,pts` table (the unit lane's entry point). Exit 10 = UNPROVEN there — REVIEW semantics, no bless decision standalone (WO-1.15.3 / 1.15.5; inside `pairfill-paff.sh` the same verdict stays exit 1 + retention) |
| Repair looks fine but motion is subtly shuffled | Constant-rate restamp flattened a reorder pyramid (PTS=DTS = decode order). `verify.sh --full` compares framemd5 presentation ORDER; repair by measured profile — `derive-dts.sh` when every packet still carries PTS (any codec), `pairfill-paff.sh` for the half-timestamped PAFF class — never `rebuild-paff.sh` |
| DV / MJPEG / MPEG-4 ASP / ProRes source ("do I need to convert this?") | **No — measured QT-native** (F8 bench 2026-08-14, macOS 26.6.1/ffmpeg 9.0.1): mpeg4(`mp4v`), MJPEG **4:2:0** (`jpeg`), DV (`dvcp`), ProRes (`apcn`) each mux `-c copy` into MOV and fully decode in AVFoundation — `mov.sh` says so and copies losslessly. Non-4:2:0 MJPEG is the C63 measured-DROP class (`PR_VNATIVE=variant`): still copied, playability proven post-build. Codecs outside the matrix (`PR_VNATIVE=no`, e.g. ffv1): copy + post-build proof, never assumed |
| Blu-ray/DVD LPCM audio (`pcm_bluray`/`pcm_dvd`) | **Container-framed LPCM, NOT raw PCM** (WO 3.1): a MOV "copy" muxes into an HDMV-tagged track NO decoder claims — even ffmpeg can't decode the file it just wrote (real 18.5 GB Blu-ray case). Routed to a **PCM access track** by `mov.sh`/`remux.sh --audio auto`; verify gate (g)'s sample-entry allowlist FAILs any shipped dead track. The access track is `pcm_s16le`: a >16-bit source (s32 — 24-bit HDMV LPCM) **loses bit depth there, announced with a WARN** since the 1.11 fix round (single-track MODE=pcm has no preserved original; depth-aware access encoding is a recorded 1.12 candidate — known-limits.md) |
| Mux fails `Could not find tag for codec …` | A subtitle/data stream MOV can't carry (subrip, DVB, teletext, SCTE) — map explicitly `-map 0:v:0 -map 0:a`; text subs → sidecar or `mov_text` (verified 8.1.1: `-map 0` copy with SRT fails at header write) |
| Source carries EIA-608/708 captions | **Embedded** (A/53 user data / SCTE-128 SEI) CC ride *inside the video* — every `-c copy` preserves them, `verify.sh --signaling` proves the flag parity; QuickTime *display* of embedded-only CC is unverified (its caption UI reads CLCP tracks). A **standalone `eia_608` stream** is mapped by NO route (the drop WARNs at run time since the 1.11 fix round — `remux.sh`'s non-audio census — on every route that funnels through remux.sh) — manual carry into MOV works (`-map 0:s -c:s copy` → native `c608` CLCP track, measured 2026-08-14 ffmpeg 9.0.1; **MP4 still refuses** — that's the historical `Could not find tag for codec eia_608`). `references/known-limits.md` |
| Mux fails `… only supported in MP4` | VP9 / AV1 / FLAC / Opus / TrueHD: route to MP4 or keep MKV; FLAC → `-c:a alac` bridge. For VP9/AV1 **video** every scripted entry point refuses pre-flight since 1.11 (`mov.sh`/`auto.sh`/`remux.sh` share the gate — 1.11 fix round; `batch.sh` records the class REFUSED, rows below) — this raw error only surfaces on hand-rolled ffmpeg |
| VC-1 video (Blu-ray/HD-DVD rips) | **REFUSED pre-flight (exit 11, 1.11 / WO 5.2)** — MOV has no VC-1 sample entry, so no lossless `.mov` of the source exists (raw form: `Could not find tag for codec vc1`). The shared gate (`lib-paff.sh`, gate-at-every-entry-point since the 1.11 fix round: `mov.sh`, `auto.sh`, `remux.sh` direct; `batch.sh` records REFUSED) emits `MOV_REFUSED profile=unroutable-vcodec` + the routes: keep the source (archival master) / lossless `-c copy OUT.mkv` for playback (IINA/VLC/mpv) / `rung4.sh` attested re-encode for QuickTime-native |
| VP9 / AV1 video (WebM, web rips) | **REFUSED pre-flight (exit 11, 1.11 / WO 5.2)** — the MOV muxer rejects both (MP4-only carriage; VP9 bench-verified un-muxable, ffmpeg 9.0.1 2026-08-14). Routes: keep / lossless `-c copy OUT.mp4` for playback / `rung4.sh` for QuickTime-native. One honest message + `MOV_REFUSED profile=unroutable-vcodec`, never a raw muxer stack trace — at **every** scripted entry point (`mov.sh`/`auto.sh`/`remux.sh`; `batch.sh` REFUSED row), 1.11 fix round |
| Dolby E audio (codec `dolby_e` — broadcast mezzanine) | **REFUSED pre-flight (exit 11, 1.11 / WO 5.2)** — up to 8 programs per AES3 pair; MOV cannot carry it, and PCM-treating it yields **full-scale noise**. `mov.sh` scans the whole track manifest (honoring `--audio-keep` — an explicit index list excluding the track proceeds, drop announced); since the 1.11 fix round `auto.sh` (any Dolby E track — it has no keep flag) and `remux.sh` (any KEPT Dolby E track) refuse identically via the shared gate. All emit `MOV_REFUSED profile=dolby-e-audio` naming the routes: **specialist decode as an operator-invoked step** (ffmpeg's `dolby_e` decoder → WAV; program/channel assignment is editorial, never automatic) / exclude the track via `--audio-keep` / keep the source. **Named limitation:** Dolby E hiding *inside a PCM track* (SMPTE 337M/AES3 wrapping) is **not auto-detected** — payload sync-word sniffing is out of scope — so a broadcast "PCM" track that plays as steady full-scale noise is the signature; treat it as Dolby E and use the operator decode, never `--audio pcm` |
| `duration too long for timebase` | `-video_track_timescale` from the field-rate table in `references/timeline-repair.md`. If it persists on a **chaptered** source it is the movie/chapter-track timescale — which `-video_track_timescale` does NOT govern (measured 2026-08-15) — see the chaptered-overflow section in `references/timeline-repair.md` |
| Trim/cut requested | Copy cuts are keyframe-bound (`references/cutting-concat.md`); check the cut point is a **closed**-GOP keyframe first (`scripts/gop-probe.sh IN CUT_TIME`); frame-exact = smart-cut, the one edit that re-encodes |
| Garbled/"random" frame at a cut or concat **seam** | Open-GOP (partial-sync) boundary: the segment started on an open-GOP I-frame whose leading B-frames referenced the deleted GOP. `scripts/gop-probe.sh` before cutting, `scripts/seam-check.sh JOINED SEAM` after; restart on a closed-GOP keyframe. (A failed scene scan is announced — `>> seam-check: scene scan failed (ffmpeg exited N)` then exit 1 — never a silent death; ffmpeg 9 removed `-vsync`, the script uses `-fps_mode`) |
| Source has several audio tracks | **Every track survives by default** (1.11): `mov.sh` **and** `remux.sh` default to `--audio-keep all` — dropping tracks buys nothing for playability (the muxer already enables exactly one audio track, tkhd-parsed `0x0003/0x0002/0x0002` on a 3-audio build = Apple TN3177's requirement) and the old `layouts` default lost same-codec ties purely on track order (multilang's Spanish track). `--audio-keep layouts` = **opt-in curation**: distinct layout+language pairs survive; same-layout same-language duplicates curated lossless > lossy-high > lossy-low. Every KEEP/DROP prints in a pre-flight manifest with the deciding rule; every drop is a WARN. `first` = the historical a:0-only behavior; explicit indices available. The first mapped track = the QuickTime default |
| Multi-audio .mov shows no QuickTime language menu (tracks present but unselectable) | `tkhd alternate_group=0` — no declared group. ffmpeg 9.x movenc already writes `group=1` + one enabled track (fresh builds conformant, measured 2026-08-14); for 8.x-era / third-party / group-scrubbed files: `scripts/qt-groups.sh IN.mov OUT.mov` (**opt-in post-pass**, WO 5.3) — walks the box tree, patches the 2-byte field per audio tkhd, blesses only after 5 proofs (byte-diff bound, video+audio essence MD5s, independent MP4Box parse, verify.sh). Enable bits reported, never flipped. `references/alternate-group.md` for the full avenue log |
| Missing/wrong audio language tag | `-metadata:s:a:0 language=eng` (PS/`.mpg` sources carry none) |
| Chapters in the source | Survive `-c copy` into MOV by default — ffmpeg adds a QT chapter text track (verified 8.1.1). **Qualified 1.12 (measured 2026-08-15, macOS 26.6.1):** past 2^31 movie-timescale ticks (~49.7 min at the broadcast-common 720000) the FATAL-looking `duration too long for timebase` warning fires — benign in-band as measured (64-bit version-1 atoms; decode/scrub/chapter menu verified) — and the chapter track can be **SILENTLY DROPPED** when the FIRST chapter spans >2^31 ticks AND the total passes 2^32 (~99.4 min), the warning suppressed on exactly those geometries. `mov.sh`/`resync.sh` pre-announce both tiers (+ additive `MOV_CHAPTER_TS_WARN`); `-map_chapters -1` drops the chapters deliberately; `references/known-limits.md` |
| Embed metadata into a .mov | `scripts/metadata.sh IN OUT --title … --description …` — proper QuickTime (`mdta`) keys, `-c copy`, drops the generic chapter "menu" + the encoder tag. **Opt-in only, never automatic**; also `mov.sh … --title …` |
| Asked to remux a file onto itself | Never — scripts refuse; write the output beside the source under a new name |
| Old MOVs stopped opening / thumbnails vanished after a macOS update | macOS decode-set drift (Tahoe 26.4 dropped MJPEG variants + AIC; Catalina dropped the QT7-era set). Detect: the `cinepak\|svq\|mjpeg\|icod` grep in `references/ingest-compatibility.md` §"Decode support is a moving target"; playable-check self-dates its OS. Rung 4 (`scripts/rung4.sh`) for a playable copy — the original stays master |
| New machine / CI, or "is my ffmpeg OK?" | `scripts/doctor.sh` — reports required vs degraded capabilities (muxers/bsfs), plus platform / VideoToolbox / optional tools (report-only), before you trust verify.sh |
| A whole folder of captures | `scripts/batch.sh DIR --out OUTDIR` — auto.sh per file + provenance sidecars + a report; idempotent resume, never deletes sources. **Ladder policy** (copy rungs keep every audio track since 1.11 — the PAFF repair rungs still build a:0; no dual-track pair, no signaling check) — for the dual-track deliverable run `mov.sh` per file |
| "Will QuickTime actually play it?" (macOS) | `scripts/playable-check.sh [--fidelity] OUT.mov` — AVFoundation render probe; the playable≠valid half ffmpeg can't prove. **A floor, not a sign-off**: a frame rendering proves neither the timeline nor the pixels — renders ≠ renders correctly (2026-08-15, macOS 26.6.1: two real broadcast MPEG-2 4:2:2 masters returned `verdict=ok` while QuickTime rendered macroblock garbage). `--fidelity` proves the pixel half: bounded `avconvert` ProRes trims of the same moments vs the ffmpeg reference decode, SSIM after yuv444p normalization, threshold `RTM_FIDELITY_SSIM` (default 0.90) — below it `verdict=fail reason=fidelity` + exit 1; no avconvert/ffmpeg → announced SKIP exit 3 (additive `PLAYCHECK_FIDELITY` machine line either way). Bounded: the qlmanage render gets a deadline (`RTM_QL_TIMEOUT` seconds, default 60, WO 1.4 — a hang counts as no frame = FAIL, never a wedged pipeline) and each avconvert window gets `RTM_AVC_TIMEOUT` (default 120 — a hang is a fidelity verdict); exit 3 = SKIP (not macOS / no qlmanage). Since 1.11 `mov.sh`/`auto.sh` (and `batch.sh` via auto) run it **automatically post-build** on 4:2:2 contribution profiles (with `--fidelity` since 1.12) and the `PR_VNATIVE=variant/no` classes (thumbnail-only), emitting `MOV_PLAYABILITY os=… verdict=… fidelity=…`; standalone builder runs print the prove-it-yourself advisory instead |

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
- `-nostdin` on every call; **atomic output** — and since 1.13 the part file
  **keeps the real extension** (`x.part.mov`, never `x.mov.part`; `lib-mux.sh`'s
  `rtm_part`/`rtm_sidecar`, applied to every builder plus `mov.sh`'s `.premeta`
  and `auto.sh`'s parked `.autobest`). WHY (D6): `qlmanage`/`avconvert` are
  **extension-keyed**, so an operator diagnosing a kept part file got "the decode
  stack cannot handle this input" — a decode verdict for a filename problem — on
  exactly the artifacts the builders deliberately keep on failure.
  `playable-check.sh` additionally probes any non-QuickTime-extensioned argument
  through a temporary **hardlink** (measured 2026-08-15: Quick Look does NOT
  follow symlinks — the symlinked `.mov` hit the deadline, the hardlink
  thumbnailed instantly), announced, never silent. Temp/intermediate
  files are **never auto-deleted** and `set -e` gates every step, so a failure
  never reaches cleanup. (One deliberate exception, stated where it happens:
  `mov.sh`'s auto-trim intermediate is removed only **after a verified DONE**;
  on REVIEW/FAIL it is kept and named, because verify compared against it.)
- **Post-mux census before any blessing** (D5, 1.13): every builder reconciles
  the stream count *and* per-stream codec identity of the finished `.part`
  against the plan it just printed, then moves it into place — `RMX_CENSUS`,
  exit 1 on MISMATCH with the part file kept. A silently dropped stream used to
  ship green (measured: `-c copy -f mov` losing 1 of 3 streams at `-v warning`).
- Color: `colr` is written automatically by modern ffmpeg; do **not** fabricate
  tags for `unknown` sources.

## Exit codes & machine lines (API — extend only, never rename/remove)

**Exit contract** (every script, enforced by `lib-exit.sh`'s ERR trap so no
stray code escapes): `0` DONE · `10` REVIEW · `1` FAIL · `2` usage · `11`
REFUSED. **Documented legacy exceptions** (pre-contract, suite-pinned, each
widening its own allowlist): `pairfill-paff.sh`, `rebuild-paff.sh` and
`derive-dts.sh` REFUSE
with exit **3** (precondition/reorder/signature refusals — derive-dts adopts
the family's documented 3, suite-pinned in `14-exit-codes.sh`), and `playable-check.sh` exits
**3** for SKIP (not macOS / no qlmanage; in `--fidelity` mode also when
avconvert/ffmpeg are missing — each cause announced). **`verify.sh` never emits 10**: its
verdict is its printed text — `>> OK` and `>> REVIEW` **both exit 0**,
`>> FAIL` exits 1, usage 2 — and callers map the text to the house codes
(`mov.sh`/`auto.sh`/`resync.sh`/`qt-groups.sh` map `>> REVIEW` → their own
exit 10). The accepted-legacy contract is stated in `verify.sh`'s header; a
caller coded to its exit code alone reads REVIEW as green (the qt-groups
defect the 1.11 fix round repaired).

**What still REFUSES (exit 11)** — nothing else does: the shared
unroutable-codec pre-flight on VC-1/VP9/AV1 video and Dolby E audio (routes +
`MOV_REFUSED`; since the 1.11 fix round enforced at `mov.sh`, `auto.sh` AND
`remux.sh` — gate at every entry point). **Scoped in 1.13:** "unroutable" was
always a MOV fact, so `remux.sh --container mp4` (the container-swap rung)
refuses only VC-1 there — VP9/AV1 into MP4 is the refusal's own named route and
is no longer refused by it. Also: `resync.sh`'s mid-stream
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
| `MOV_PLAYABILITY` | driver post-build check (`lib-paff.sh`) | `os=<macOS\|na> verdict=ok\|fail\|skip fidelity=ok\|fail\|skip` (WO 4.1; self-dating, Ground Rule 6; `fidelity=` appended 1.12 WO-B — `skip` when the mode wasn't requested or couldn't measure) |
| `PLAYCHECK_FIDELITY` | `playable-check.sh --fidelity` (1.12 WO-B) | `verdict=ok\|fail\|skip reason=none\|fidelity\|convert-hang\|convert-fail\|compare-fail\|<skip-cause> ssim=<worst\|na> os=<macOS\|na> y= u= v= scan=interlaced\|progressive\|unknown thresh= mp4_swap=untried` — the five trailing fields appended 1.13 (D1/D2, Ground Rule 4): the per-plane split of the worst sample, the scan the threshold was keyed off, the threshold in force, and `mp4_swap=untried` (this script sees only the OUTPUT, never the source, so it can name the container-swap rung but not run it). SSIM below the in-force threshold → `verdict=fail reason=fidelity` + exit 1 |
| `MOV_ROT_WARN` | shared `backhaul_rot_warn` (`lib-paff.sh`; called by `mov.sh` + `backhaul_gate` — one implementation, F1 2026-08-16) | `profile=timeline-rot vcodec= disc= back= dup= disc_p= disc_p_na=` (WO 4.2 — warn + build, never a refusal; `disc_p=`/`disc_p_na=` appended P1.4, Ground Rule 4 — the presentation-order forward-gap count (`DISC_P_COUNT`, the field that carries the dropped-time claim on reordered sources) and the no-PTS packet count that guards it (`DISC_P_NA`)) |
| `MOV_CHAPTER_TS_WARN` | `mov.sh` + `resync.sh` | `chapters= dur_s= limit_s= [drop_s=]` (1.12 WO-C — announce-only chaptered movie-timescale-overflow pre-announce, never a refusal; `drop_s=` appended only when the tier-2 silent-drop arm fires; thresholds `RTM_CHAPTER_TS_WARN_SECS` (2900) / `RTM_CHAPTER_TS_DROP_SECS` (5965)) |
| `MOV_REFUSED` | shared unroutable pre-flight (`lib-paff.sh`; emitted by `mov.sh`/`auto.sh`/`remux.sh` — WO 5.2, parity closed in the 1.11 fix round) | `profile=unroutable-vcodec vcodec=` / `profile=dolby-e-audio track=a:<N>`. The 1.8.0–1.10.0 backhaul values (`qt-undecodable-*`, rot) are **retired — no longer emitted, reserved, never reused** |
| `RMX_CENSUS` | every builder, post-mux, pre-bless (`lib-mux.sh`) | `stage=remux\|dual-track\|resync\|rebuild-paff\|pairfill-paff\|derive-dts\|trim-to-idr\|metadata\|rung4\|zero-base\|surgical-cut planned=<N> written=<M> codecs=ok\|mismatch\|na match=ok\|MISMATCH` (D5, 1.13 — the plan-vs-file reconciliation; MISMATCH is exit 1 with the artifact kept as `.part`; the two clinic stage values appended 1.15; `derive-dts` emitted since 1.14, missing from this enum until CHECKUP-2026-08-27 F4) |
| `RTM_LOCK` | every writer's pre-flight (`rtm_lock`, `lib-mux.sh` — WO-1.15.6 / CHECKUP A2) | `verdict=refused holder=<pid> dir=<lockdir>` — a second concurrent writer on the same OUT refuses pre-flight exit 2, nothing written (one writer per OUT; the measured A2 corruption: the census and the mv are not atomic against another `-y`). A dead same-host holder is stolen with an announced line, never a machine row |
| `RTM_DISK` | every builder's pre-flight (`rtm_disk_preflight`, `lib-mux.sh` — WO-1.15.6 / CHECKUP F11) | `verdict=refused free=<bytes> need=<bytes> vol=<dir>` — free space below the SOURCE size refuses pre-flight exit 2 before a build can burn an hour to ENOSPC; `RTM_DISK_CHECK=0` (operator knob) skips announced for the genuinely-smaller-output classes |
| `PP_CENSUS` | `pairfill-paff.sh` (junction model, 2026-08-18) | `pics= fields= frames= pic_struct_bad= [attested=]` — the whole-file trace_headers census the widened fill requires (tabled here 1.15.5; emitted since 1.15.0-era 2026-08-18, previously documented only in code) |
| `PP_POC_CAPABILITY` | `pairfill-paff.sh` (junction pre-flight, WO-1.15.3 / 1.15.5) | `ok=yes\|no why=poc_type\|t2_derived\|no_pictures\|no_sps\|- poc_type= maxlsb= lsb_rows= pics=` — the head-probe capability verdict, and it answers what `h264poc.Parser.capability()` would (test 114). `ok=no why=poc_type` is the exit-3 pre-flight refusal, and since 1.16.4 it means `pic_order_cnt_type 1` alone — the one type neither reader can state a display position for. Type 2 reads `ok=yes why=t2_derived` (display order equals decode order by spec) and is built |
| `PP_POC_LATTICE` | `pairfill-paff.sh` (junction gate) + `poc-gate.sh` (standalone, WO-1.15.3 / 1.15.5) | evaluated: `on_slot= total= off=` (since 2026-08-18); UNPROVEN (appended 1.15.5 — the branch previously printed no machine row): `unproven=1 why=poc_type\|count\|probe_failed rows= packets=` |
| `DERIVE_DTS` | `derive-dts.sh` (Rung 3-DERIVE; tabled 1.15.19) | `depth= shift_ms= packets= census= stamped=<N> verdict=ok|unproven [why=packet_hash] [attested=]` — `stamped=` (1.15.20) is how many of the output's PTS are RECONSTRUCTIONS from a pair-mate rather than carried timestamps, `0` on an ordinary derive; each one is also announced as its own `DERIVE_STAMP idx= pts= mate= rule=` provenance row. — printed once, after the four output gates. `verdict=ok` is the blessed build (`mv` done); `verdict=unproven why=packet_hash` (appended 1.15.19, WO-1.15.4's leftover ledger) is the EMPTY != ABSENT arm: gates 1/2/4 passed but the streamhash pass produced NO evidence, so losslessness is UNPROVEN — exit 10 REVIEW, nothing blessed, the `.part` kept with a two-command re-judge recipe. A REAL hash mismatch is unchanged: exit 1, no machine row. |
| `SRCV_SUMMARY` | `verify-source.sh` (1.15) | `verdict=ok\|review\|fail hash=match\|mismatch v_src= v_out= v_drop= a_drop=<csv\|none> dur_delta= gaps_src= gaps_out= trim= notes=` — the same-container identity battery (filtered-reference streamhash + measured census arithmetic + nothing-unexplained) |
| `ZB_SUMMARY` | `zero-base.sh` (1.15) | `out= start_src= start_out= floor= predicted_nudges= observed_nudges= verdict=` — prediction contract: predicted != observed never ships |
| `ZB_PREFLIGHT` | `zero-base.sh --preflight-only` (1.15.13) | `verdict=eligible container= programs= paff= half_ts= back= dup= prekey=` — printed on the ELIGIBLE arm only (exit 0, nothing written); a refusal is exit 2 with its reasons on stderr and no row. `clean.sh` asks this instead of re-deriving zero-base's conditions (`--src-tsh` hands over the ts-health scan it already took). `prekey=` appended in the 1.15.18 review round with the mid-GOP refusal. |
| `TTI_PREFLIGHT` | `trim-to-idr.sh --preflight-only` (1.15.18) | `verdict=eligible prekey= idr_pts=` — printed on the ELIGIBLE arm only (exit 0, nothing written: steps 1-2 ran — IDR found in the window, boundary proven closed by `gop-probe.sh`); a refusal (no keyframe in the window, missing timestamps, open-GOP boundary, nothing to trim) is exit 2 with its reasons on stderr and no row; any other rc = the pre-flight could not RUN (unproven, not refused). `clean.sh` asks this instead of printing the trim route off the ts-health counter — the same ask as `ZB_PREFLIGHT`, so the clinic never offers a Tier-1 command its tool refuses. |
| `SCUT_SUMMARY` | `surgical-cut.sh` (1.15) | `out= vdrop_lt= vdrop_between= adrop_lt_pts= offset= predicted_nudges= observed_nudges= verdict=` — the declared selection, verbatim |
| `LEADCHECK_SUMMARY` | `lead-check.sh` (1.15) | `verdict=clean\|lead black_frames= black_secs= splice_idx= splice_pts_t= gop=closed\|open\|unknown leadb=none\|A-B audio_hot=yes\|no\|na audio_discard_s=` |
| `DIMSCAN_SUMMARY` | `dim-scan.sh` (1.15) | `changes= dims= first_change_pts= frames=` |
| `CLOCK_SUMMARY` | `clock.sh` (1.15) | `player= start_time= raw= key_before= key_after= frames= luma_min= luma_max=` |
| `CLEAN_SUMMARY` | `clean.sh` (1.15) | `verdict=clean\|findings\|damaged findings= routes=<csv\|none> deep=yes\|no` |
| `MP4_SWAP` | `mp4-swap.sh` | `out= verdict=ok\|review\|fail stage=build\|verify fidelity=ok\|fail\|skip\|na` (D2, 1.13 — the container-swap rung's own verdict) |
| `QTG_SUMMARY` | `qt-groups.sh` | `date= macos= mp4box= audio= enabled= group= patched= out=` |
| `VERIFY_SUMMARY` / `VERIFY_SIGNATURE` | `verify.sh` (waiver flow) | waiver verdict + the exact gate/signature a sidecar must match |
| `TSH_*` / `PR_*`+`PF_*` | `ts-health.sh --kv` / `probe.sh --kv` | KV blocks. WO-1.15.7 (jurisdiction, all additive): `TSH_VIDEO=yes\|none` (no video stream = the video-timeline half has no jurisdiction — never an unscoped CLEAN), `TSH_SCOPE=mpegts\|demux-only` (non-mpegts containers carry no transport-counter vocabulary), `TSH_START` (negative start_time = the demuxer already unwrapped a mid-capture 33-bit crossing), `PR_NPROG` (+ `"nprog"` in `--json` — multi-program topology now reaches machine consumers; since 1.15.13 clean.sh no longer models this or any other zero-base refusal axis — it ASKS `zero-base.sh --preflight-only`, see `ZB_PREFLIGHT`). Probe additions (WO 5.1/5.2): `PR_VNATIVE` (`--json`: `vnative`) = `yes\|variant\|no\|na` — the measured QT-native matrix; `PR_AUDIO_ACTION` gained `specialist` (Dolby E) beside `copy\|pcm\|none`; `PR_TAG_ADVICE` (1.12 WO-A) = the lossless `-tag:v xd5*` retag advice for `m2v1` MPEG-2 4:2:2 decoder dispatch — `references/ingest-compatibility.md` |

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
| The container axis: a build that verifies lossless but renders WRONG in QuickTime — the retag vs the lossless `.mp4` swap, why ffmpeg cannot write the working entry into a `.mov`, and what is still unbenched | `references/ingest-compatibility.md` ("The container axis") + `references/known-limits.md` + `scripts/mp4-swap.sh` |
| PAFF field pairing, pic_order_cnt timing, and the traps around both | `references/paff-poc.md` |
| Which refusals are legitimate, and which gate an attempt on a prediction | `TIERS.md` (plugin root) |
| Rung-4 delivery/encode recipes (x264/x265/ProRes) — NOT the lossless path | `references/delivery-encode.md` |
| QuickTime language menu: `alternate_group` mechanics, the measured tool-avenue log (MP4Box `-group-add` recipe, gpac hazards), the 5-proof binary patch | `references/alternate-group.md` + `scripts/qt-groups.sh` |
| **DEFAULT deliverable**: QuickTime-ready dual-track (PCM access + original preserved), alignment-safe two-pass cutting, dual-track QC | `references/dual-track-quicktime.md` + `scripts/dual-track.sh` |
| **The SOURCE CLINIC**: checks + corrections in the source's own container (re-wrap ≠ remux, the two-tier consent model, the prediction contract, the deterministic-cut and leading-B rules, the player-clock rule, the zero-base floor, recorded candidates) | `references/source-clinic.md` + `scripts/clean.sh` |
| Every `RTM_*`/`TSH_*`/`DISC_*` env knob and test hook, with defaults, in one table | `references/knobs.md` |
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
  false-read 1×) and route by MEASURED profile (the 1.14 doctrine; F2 fixed
  1.15.9 — "reordered → pairfill" was the retired pre-1.14 route preserved as
  instructions): half-timestamped → `pairfill-paff.sh` (keeps every real
  PTS); PTS-complete reordered (any codec — DTS absent/reconstructed/rotten
  alike) → `derive-dts.sh` Rung 3-DERIVE; no surviving reorder →
  `rebuild-paff.sh`. `verify.sh`
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
  classes rendered the synthetic bench clips fully** (qlmanage thumbnail +
  `avconvert` whole-file, 50/50 frames), as do 10-bit 4:2:2, 10-bit 4:4:4,
  and HEVC Rext 4:2:2 — and the
  exact `yuv422p` match had let the actual 10-bit contribution profiles
  (AVC-Intra class) bypass the gate unannounced: the hardcoded claim was
  over- and under-broad at once, exactly the codec-drift rot the plugin's own
  C63 documents (Tahoe 26.4 dropped MJPEG variants/AIC). So the verdict is
  now per-file and post-build: drivers announce `contribution profile
  <codec>/<pix_fmt>` (`yuv422p*`, all bit depths), build losslessly, and
  prove the output with `playable-check.sh` (self-dating its macOS,
  `MOV_PLAYABILITY` machine line — since 1.12 with `--fidelity`, because on
  2026-08-15 the residual materialized: two real 1080i59.94 broadcast 4:2:2
  masters returned `verdict=ok` on the same 26.6.1 while QuickTime rendered
  macroblock garbage — renders ≠ renders correctly, so the driver now SSIMs
  the AVFoundation render against the ffmpeg reference); a `fail` or
  unverifiable platform demotes
  to REVIEW with Rung 4 named — being wrong costs an artifact plus an honest
  warning, never the deliverable. (Bench caveat: the falsifying clips were
  synthetic — they disprove "cannot decode", not every real master; that
  residual is why the check is per-file, and why it now checks pixels, not
  just the open.)
  **And the CONTAINER is a third axis (1.13, D2).** The 1.12 answer to a bad
  4:2:2 render was "retag" — narrowed the same day: on a real 21 GB 1080i29.97
  capture all five MOV tags (`m2v1`/`mp2v`/`hdv3`/`xd5b`/`xd5c`) corrupted
  IDENTICALLY, because movenc writes one generic sample-description body for
  every MPEG-2 fourcc (`glbl`+`fiel`+`colr`) — a retag changes the FourCC and
  the compressor name, nothing else, so it can only work where the stream
  matches the fourcc's profile contract. The same bitstream in an `.mp4`
  (`mp4v`+`esds`) rendered correctly, SSIM 0.9175+ on the failing timestamps.
  That is now a rung (`scripts/mp4-swap.sh`, Rung 3-SWAP) named at every
  fidelity-FAIL route, and Rung 4 comes after it. ffmpeg refuses to write
  `mp4v` into a `.mov` — a muxer TAG-TABLE artifact, not QTFF: Apple lists
  `esds` as a legal video sample-description extension, so only `stsd` surgery
  (unbenched) could keep the `.mov` extension. Also 1.13: the fidelity
  threshold is scan-keyed (0.90 progressive / 0.86 interlaced — 0.90
  false-FAILed healthy interlaced material) and every sample reports its Y/U/V
  split, because the interlaced deficit is chroma-plane, not field-structure
  (normalization sweep measured and rejected — `known-limits.md`).
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
