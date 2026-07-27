# QTFF Spec Audit Plan — hunting lingering bugs & bad engineering choices

**Reference:** `/Users/salvatore/quicktime-docs` — a complete local archive of
Apple's QuickTime File Format spec (1,152 pages, fetched 2026-06-19).
Query it, don't browse it:

```bash
DB=/Users/salvatore/quicktime-docs/quicktime-file-format.sqlite
sqlite3 "$DB" "SELECT path,title FROM pages_fts WHERE pages_fts MATCH '<term>' LIMIT 10"
sqlite3 "$DB" "SELECT DISTINCT page_path FROM symbols WHERE atom_code='<fourcc>'"
# page bodies: /Users/salvatore/quicktime-docs/markdown/<section>/<page>.md
```

**Method (every item follows the post-mortem discipline):**
1. State the plugin's claim or behavior as a falsifiable sentence.
2. Resolve it against the spec page (cited per item below).
3. Probe a REAL artifact — `mp4dump`/`ffprobe` on an output the scripts built —
   never reason from the command that made it.
4. Classify: **BUG** (fix + regression pin) / **DOC-DRIFT** (fix the reference)
   / **CONFIRMED** (record the verification date). A divergence is a defect
   until every probe is individually explained.

Tooling: `ffprobe`, Bento4 `mp4dump` (doctor.sh already reports it), the
sqlite FTS above. Synthesized fixtures via `tests/regression.sh` recipes; real
PAFF probes against the T9 captures (read-only — never commit media).

---

## Phase 0 — Claim inventory

Grep `references/*.md`, `SKILL.md`, and script headers for every
container-level assertion ("verified 8.1.1", "chapters survive -c copy",
"no fiel atom on copy", "E-AC-3 plays natively", "QuickTime won't play X").
Emit a checklist table (claim → spec anchor → probe → status) as
`references/qtff-claims.md`. Everything below feeds off this list; anything
the list surfaces that this plan missed gets appended as a Phase-item.

## Phase 1 — Timeline semantics vs sample tables (highest risk)

The post-mortem lived entirely in `stts`/`ctts` territory; these are the
claims we now depend on but have never checked against the atoms actually
written.

- **1a. `ctts` signedness / `cslg`.** Pairfill and rebuild outputs put
  pts>dts everywhere; QTFF `ctts` offsets are unsigned in the classic form,
  with `cslg` covering the shifted/negative composition case. Probe: `mp4dump`
  a pairfill output — are offsets non-negative, is `cslg` present, and does
  QuickTime Player honor whichever ffmpeg wrote?
  Spec: `sample_atoms/composition_offset_atom`,
  `composition_shift_least_greatest_atom`, `time-to-sample_atom`.
- **1b. Pairfill offset bound is derived, not gated.** `PREROLL` is measured
  from packets carrying BOTH timestamps; filled mates get `pts=prev+A` against
  a constant DTS ramp. Prove (or gate) that max(pts−dts) over ALL output
  packets ≤ PREROLL — add a max-offset line to pairfill's output gates instead
  of trusting the derivation.
- **1c. Timescale assumption in the histogram gate.** Pairfill's duration gate
  assumes the MOV muxer keeps the source 90 kHz timescale (durations 1501/1502).
  If any ffmpeg version rescales the track timescale on TS→MOV, the gate
  false-fails or worse, false-passes. Probe `mdhd`/`stts` per CI ffmpeg
  version; pin with a fixture. Spec: `media_atom/media_header_atom`.
- **1d. Edit lists.** ffmpeg writes `elst` for nonzero starts and negative
  initial DTS. Are verify.sh's duration-parity (stream durations) and scrub
  gate (seek targets) edit-list-aware, or do they measure media duration while
  QuickTime plays track duration? Probe a capture starting at pts≈1.4 s.
  Spec: `edit_list_atom`, `playing_with_edit_lists`.
- **1e. Encoder delay / priming on audio.** The spec has a whole article
  chain on representing encoder delay via track structures — directly relevant
  to the dual-track build (decoded PCM vs copied AAC/AC-3 alignment) and the
  0.25 s A/V parity tolerance. Verify the alignment QC against these pages
  rather than our own folklore.
  Spec: `historical_solution_implicit_encoder_delay`,
  `using_track_structures_to_represent_encode_delay_explictly`.

## Phase 2 — Seekability atoms

- **2a. `stss` vs `stps` claims in gop-probe.** The open-GOP doctrine maps
  partial-sync frames to `stps`. Confirm ffmpeg actually writes `stps` on copy
  of open-GOP H.264 (vs marking everything sync in `stss`), because
  `seam-check`'s premise depends on it. Spec: `sample_atoms` (sync sample +
  partial sync sample atoms).
- **2b. `sdtp` sample dependencies.** Does its absence on our copies degrade
  QuickTime scrubbing (the exact user-facing symptom we gate on)? If ffmpeg
  writes it only sometimes, the scrub gate may be testing different file
  shapes per source. Spec: `sample_atoms` (sample dependency flags).

## Phase 3 — Sample descriptions (media-specific)

- **3a. Interlaced signaling: `fiel`.** Plugin doctrine: "no `fiel` atom on
  copy; bitstream VUI carries field order — fine." The spec lists `fiel` as
  the video sample description extension QuickTime uses for field handling.
  Probe: does AVFoundation deinterlace a PAFF deliverable correctly without
  `fiel`? If not, decide: inject it (new, small tool) or document the player
  matrix. Spec: `video_sample_description_extensions`.
- **3b. Multichannel PCM needs `chan`.** ⚠ suspected live bug. Dual-track,
  pairfill, and resync decode AC-3 5.1 → 6-ch `pcm_s24le`. QTFF maps >2-ch
  PCM through the sound description v2 + `audio_channel_layout_atom`. Probe a
  5.1 fixture: is `chan` written, and does QuickTime map L/R/C/LFE/Ls/Rs
  correctly — or play scrambled channels? All current fixtures are mono/stereo,
  so this path is untested. Spec: `sound_sample_descriptions`,
  `sound_sample_description_extensions`, `audio_channel_layout_atom`.
- **3c. Closed captions.** `--signaling` checks CC *presence* via ffprobe, but
  QuickTime renders captions from a `clcp`/c608 TRACK, not from H.264 SEI.
  Verify whether "captions preserved" as we report it means "QuickTime shows
  captions" — if not, the check over-promises. Spec: `closed_captioning_media`.
- **3d. `pasp`/`clap`/`gama` drift.** `--signaling` compares color
  primaries/transfer/space/range but not pixel aspect (`pasp`) or clean
  aperture (`clap`) — broadcast anamorphic SAR loss would ship undetected.
  Also confirm no deprecated `gama` is ever written alongside `colr` (the spec
  says they conflict). Spec: `clean_aperture`, `color_parameter_atom`.

## Phase 4 — Track & metadata structure

- **4a. Dual-track: do BOTH audio tracks play?** ⚠ suspected live bug.
  QuickTime plays every *enabled* track; "default" is an ISO-BMFF disposition,
  while QT semantics are `tkhd` enabled flags + alternate groups. If ffmpeg
  maps `-disposition:a:1 0` to anything other than disabled/alternate-grouped,
  QuickTime Player may mix the PCM access track WITH the AC-3 original.
  Probe `tkhd` flags + `alternate_group` on a dual-track output; listen once
  on a real Mac. Spec: `track_header_atom`, `chapter_lists` sibling pages on
  alternate groups.
- **4b. Chapter machinery.** QT chapters = text track + `chap` track
  reference. metadata.sh strips *data* tracks; confirm the generic "menu" is
  always a data track (not text), that stripping never leaves a dangling
  `chap` tref, and that `--keep-chapters` keeps both halves. Spec:
  `chapter_lists`, `track_reference_type_atom`, `text_media`.
- **4c. Track language codes.** `language=eng` → `mdhd` packed ISO-639-2/T vs
  legacy Mac codes; confirm what ffmpeg writes and what Finder/QuickTime
  display for our rebuilt tracks. Spec: `basic_data_types/language_code_values`.
- **4d. mdta structure conformance.** metadata.sh round-trips via ffprobe;
  additionally `mp4dump` the `meta`/`keys`/`ilst` tree once against the spec
  layout so "proper QuickTime format" is verified structurally, not just
  read-back. Spec: `metadata_atoms_and_types/*`.

## Phase 5 — Engineering-choice sweep (no spec needed)

- **5a. pairfill maps `a:0` only.** rebuild-paff carries every audio track;
  pairfill silently drops SAP/secondary audio. Add `--all-audio` (or a loud
  warning when more tracks exist). Known gap — fix, don't debate.
- **5b. Whole-file scan cost.** verify.sh (d) + `disc_scan` are now two
  whole-file demux passes; measure on a multi-GB capture and merge into one
  pass if material.
- **5c. Histogram-gate false positives on VFR.** The tiny-duration FAIL
  assumes CFR broadcast; the skill also claims web video (VFR is legitimate
  there). Decide: scope the FAIL to CFR-detected outputs, or downgrade to
  REVIEW with an explanation.
- **5d. Confession regexes vs ffmpeg wording drift.** The three patterns are
  tied to current English log text; CI matrix (4.4/6.1/7.1) should assert the
  wording per version, and the matrix needs an 8.x leg (facts were verified on
  8.1.x but CI never runs it).
- **5e. auto.sh vs mov.sh audio-policy divergence.** auto's rungs 0/1 build
  single-track (PCM) while mov.sh builds dual-track for the same codecs; the
  PAFF full-TS branch of auto therefore ships a different deliverable than
  /mov would. Unify or document the intent.
- **5f. bash 3.2 sweep.** The metadata.sh crash class (`"${arr[@]}"` under
  `set -u`) — grep every script for unguarded array expansions and run the
  whole suite once under `/bin/bash` (3.2), not just the dev shell.
- **5g. shellcheck all scripts**; fix or annotate every finding.
- **5h. Real-PAFF fixture.** libx264 can't mint field-coded streams, so the
  pair class is only injection-tested. Keep a tiny (<10 s) cut of a real T9
  capture OUTSIDE the repo as a local manual-validation fixture, and document
  the path in a gitignored note — never commit media.

---

## Findings log (running)

**2026-07-25 — Phases 0, 1, 2a, 3b/3d, 4a/4b executed** (ffmpeg 8.1.2, macOS;
probe artifacts under the session scratchpad `qtff-audit/`; claim verdicts
recorded in `references/qtff-claims.md`):

- **Phase 0 DONE** — 62 claims (C01–C62) inventoried in
  `references/qtff-claims.md`, all spec-anchored; 11 gaps listed there await
  triage into phase items.
- **1a CONFIRMED** (C04) — ffmpeg represents pts>dts as unsigned v0 `ctts`
  shifted by the preroll plus a two-entry edit list (empty edit + media time =
  preroll); no `cslg`. Spec-compliant.
- **1b BUG FOUND + FIXED** (C05) — a wrong-cadence DTS ramp (field-rate ramp on
  frame-per-packet input) passed every point gate while writing linearly
  growing `ctts` (max 192192 vs preroll 12012) and `mdhd` ≠ Σ`stts`. pairfill
  now gates max(PTS−DTS) ≤ preroll+pair and decode-vs-presentation span skew
  ≤ 2 pairs; regression pins both the pass and the refusal. The E2E fixture's
  rate was itself corrected (frame-per-packet ⇒ `--rate 30000/1001`).
- **1c CONFIRMED** (C02) — 90 kHz mdhd timescale kept on TS→MOV; 1501/1502
  stts durations as assumed. Per-CI-version pin still owed (5d).
- **1d CONFIRMED** (C06) — elst empty-edit for the start offset; ffprobe
  stream durations are media durations, so the parity gate measures the right
  thing. 1e (priming articles vs the 0.25 s tolerance) still open.
- **2a REFUTED → doctrine corrected** (C18) — ffmpeg marks open-GOP non-IDR
  I-frames as FULL sync in `stss`, writes no `stps`/`sdtp`: the container
  overclaims seekability. `cutting-concat.md` now says so explicitly; gop-probe
  already decides from display order and needed no change. This also answers
  half of 2b: no `sdtp` is written on copies at all.
- **3b SUSPICION REFUTED on 8.1.2** (C31) — 6-ch PCM gets QTFF v1 `in24` +
  `chan` (MPEG_5_1_A, positionally 1:1 with 5.1(side)); AC-3 keeps its own
  `chan`. Older-ffmpeg pin + speaker-ident listen remain.
- **3d HALF-CONFIRMED + FIXED** — `pasp` survives `-c copy` (40:33 preserved),
  but `--signaling` never checked it; `sample_aspect_ratio` drift is now
  compared (undefined-SAR sources skipped to avoid false drift).
- **4a SUSPICION REFUTED on 8.1.2** (C41) — dual-track tkhd flags are 3/3/2:
  the preserved original is written NOT-enabled, so QuickTime plays only the
  PCM access track. No mixing.
- **4b CONFIRMED** (C37/C39) — chapters produce a `text`-handler track +
  `chap` trefs on both A/V traks; metadata.sh's strip removes track AND trefs
  (nothing dangles); `--keep-chapters` keeps all three pieces.
- **5a FIXED** — pairfill now warns loudly when the source has >1 audio track
  (only a:0 is carried). **5f partially** — a live bash-3.2 parse bug in
  pairfill's sign-off line (`$(case …)` inside double quotes) was found by
  probe and fixed; the full unguarded-array sweep is still owed.
- Still open after round 1: 1e, 2b (`sdtp` seek-impact half), 3a (`fiel`
  playback evidence), 3c (captions-render reality), 4c/4d, 5b–5e, 5g/5h, and
  the 11 Phase-0 gaps.

**2026-07-25 round 2 — 1e, 4c/4d, 5b/5c/5d/5f/5g + 13 structural claim
verdicts** (ffmpeg 8.1.2; verdicts in `references/qtff-claims.md`):

- **1e CONFIRMED (spec-bound, C11)** — QTFF Appendix G pins implicit AAC
  priming at 2112 samples ≈ 44 ms @48 kHz, an order of magnitude under the
  0.25 s parity tolerance; rationale recorded in verification-safety.md.
  Bonus (C12): a 0.4 s TS audio delay survives copy as a QTFF **empty edit** —
  which also REFINED C08: the container has a gap mechanism and ffmpeg uses it
  for *initial* offsets; it writes none *mid-stream*, which is where collapse
  happens (timeline-repair.md wording corrected: the limitation is the writer,
  not the container).
- **4c CONFIRMED (C42)** — `language=eng` lands as mdhd language 0x0000 =
  legacy Mac code English (spec-valid), ffprobe round-trips `eng`.
- **4d CONFIRMED (C43/C44)** — metadata.sh writes the spec-exact
  `meta→hdlr(mdta)+keys+ilst` tree; naive `-metadata` writes legacy `udta/©nam`.
- **C34 REFINED** — in a `qt`-brand MOV, mov_text is classic QT TEXT media
  (`text` entry/handler), not tx3g (that's the MP4 form); color-hdr-subs.md
  corrected. Also CONFIRMED structurally: C15 (header consistency), C22/C23
  (colr nclc nested in avc1; written by default only for FULLY tagged sources —
  partial tags get none, matching the don't-fabricate doctrine), C29 (avcC),
  C30/C32/C33 (sowt/.mp2/.mp3 fourccs), C45 (faststart atom order), C52 (tmcd
  track + tref).
- **5b MEASURED — non-issue** — gate (d)'s whole-file scan on the real 955 MB
  incident capture (19,527 packets): 1.1 s cold / 0.23 s warm. No merge with
  disc_scan warranted.
- **5c FIXED** — the tiny-duration FAIL now escalates lazily to a SOURCE
  duration-profile comparison (matching counts = inherent VFR → pass with
  note; unreadable source → REVIEW; unmatched → FAIL as before).
- **5d DONE** — CI matrix gained the 8.1.2 leg (mwader/static-ffmpeg:8.1.2
  verified to exist).
- **5f DONE** — array-expansion sweep: every remaining `"${arr[@]}"` site is
  provably behind a count guard; the suite itself runs under macOS bash 3.2.
- **5g DONE** — shellcheck (warning level): one finding, the intentional
  word-split in lib-paff.sh, now annotated.
- **Phase-0 gaps triage** — closed by probes: faststart order (gap 2, C45),
  ©-atom structure half (gap 3, C44), tmcd (gap 7, C52), AC-3 delay (gap 11,
  C12). Remaining open gaps: co64 >4 GiB (C46 — WAIVED until a real >4 GiB
  deliverable exists to dump), playability matrix on a real Mac (C53–C59),
  Mediabunny re-pin (C60), mov_text timescale overflow (C13 half), malformed-
  atom/wrong-handler doctrine (C47/C49 — WAIVED: validation doctrine, not
  plugin behavior), fragmented/DRM edges (C50/C51 — WAIVED: detection-only
  doctrine), two-pass alignment bound (gap 10 — queued with 3a/3c for the
  real-Mac session).
- **5e RESOLVED as documented divergence** — auto.sh is the single-track
  ladder driver, mov.sh the dual-track deliverable builder; the one seam where
  /mov rides auto's copy rung (full-TS reordered PAFF) now announces its
  single-track audio and points at dual-track.sh.
- **5h BLOCKED** — no original `.ts` survives on T9 (only the rebuilt `.mov`
  deliverables); cut the <10 s local fixture when the S34E12 source
  re-download lands, and keep it OUTSIDE the repo.

**2026-07-25 round 3 — the Mac GUI session (user-verified, QuickTime Player,
macOS Darwin 25.5; fixture kit at `~/Downloads/qtff-gui-checks/`): ALL PASS.**

- **3a CLOSED (C24)** — the field-coded (tt) T9 deliverables play smooth
  full-screen with no combing and no field-order shimmer despite carrying no
  `fiel`: AVFoundation deinterlaces from the bitstream. No fiel injector
  needed; note added to timeline-repair.md.
- **4a CLOSED (C41)** — discriminating dual-track fixture (PCM 440 Hz enabled
  / AC-3 880 Hz not-enabled, production flag pattern 3/3/2): only 440 Hz
  audible. No mixing.
- **3b CLOSED (C31)** — per-channel tones land on the right speakers; in24
  playback confirmed (C30 playback half).
- **Scrub sign-off (C04/C19/C21)** — both rebuilt S35E05 deliverables scrub
  clean under hard playhead dragging; combined with the incident record
  (mux-valid files that tore, thumbnails on unwatchable files) these rows are
  closed.
- **Playability matrix (C27, C32/C33 halves, C53–C56)** — hev1 fails/hvc1
  plays; MP2 silent; MP3 plays; E-AC-3 plays natively; AC-3 plays (modern);
  DTS silent; MPEG-2 4:2:2 refuses / 4:2:0 plays. All as the references
  claimed. Chapters menu (C37/C38), subtitle display (C34), and track
  language display (C42) also confirmed.
- Ledger: 27 of 62 rows remain UNVERIFIED — all either blocked on artifacts
  that don't exist here (real pair-timestamped source C01, gapped fixtures
  C09/C10, CC-bearing capture C35, >4 GiB C46, DV/HDR10/Atmos sources
  C26/C61/C62, legacy-codec and iOS-device checks C57/C58), waived doctrine
  rows (C47/C49/C50/C51), or low-stakes odds and ends (C07 make_zero, C13
  mov_text overflow, C14, C16/C17 spec-reading halves, C20, C25, C28, C36,
  C59/C60 re-pins). Nothing among them gates a shipping decision.

- Still open (needs artifacts, not eyes): 3c caption rendering (needs a
  CC-bearing capture), 5h real-PAFF fixture (needs the source re-download).

**2026-07-25 round 4 — MACRO review: pipeline/sequence common sense.** Walked
every end-to-end flow (mov, auto ladder, diagnose→repair→verify, batch,
dual-track incl. the two-pass cut, resync, metadata, cutting, verify's gate
train) against flow-level QTFF sense. Fixed:

- **Ship-what-you-verified (mov.sh PAFF path)** — the opt-in metadata pass
  REWRITES the container after auto's verify; that path now re-runs verify on
  the file actually shipped (the non-PAFF path already verified post-metadata).
- **--signaling always on in mov.sh** — it is demux-only, untagged fields
  compare clean, and the old color-gated trigger skipped the new SAR/pasp
  check exactly where it matters (anamorphic SD with untagged color).
- **--always-dual on the PAFF path now says it doesn't apply** (audio policy
  comes from the repair rung).
- **batch policy transparency** — batch.sh header + SKILL + README now state
  it ships the LADDER deliverable (single-track, no signaling check); mov.sh
  per file is the dual-track route.
- **Wording alignment** — resync.sh and lib-paff.sh gap-collapse comments now
  blame the writer, not the container (the C08 refinement), matching
  timeline-repair.md.

Reviewed and KEPT deliberately: verify's gate order (all gates always run,
verdict only downgrades — evidence-complete beats fail-fast); diagnose's
triage order (damage → missing TS → monotonicity → gaps); the dual-track
two-pass cut (the alignment rationale holds; the intermediate is regenerable);
resync/metadata muxing at `-v error` (confession lines invisible there, but
every shipped artifact now passes verify's gate (d) timeline scan, which
catches the same class from the output side); playable-check only after OK
(floor semantics); faststart/atomic-write/never-touch-source uniform across
all writers; parity/scrub measuring media durations and post-edit pts
(edit-list-aware). Suite 122/122.

**2026-07-26 round 5 — gap closure COMPLETE: Tahoe drift, audio-policy
classifier, Rung-4 attestation, verification calibration** (ffmpeg 8.1.2,
macOS 26.5.2/Darwin 25.5, bash 3.2.57, shellcheck 0.11.0; suite 122 → **176/176**;
ledger 62 → 71 rows; commits `af9f4e5`..`7120e0c` + release):

- **Gate decisions (operator, 2026-07-26):** ① Rung-4 attestation string;
  ② waiver attestation string; ③ `layouts` as mov.sh's default audio-keep
  policy; ④ pairfill slack = 1 pair with the 16-pair excursion clamp;
  ⑤ the combined probe.sh diff (5-2a manifest + 5-4e advisory + 5-5b gama +
  5-5e stsd) as a unit. All five approved and shipped.
- **5-2 DONE (audio policy)** — per-track manifest (`PR_AUD_*`),
  `--audio-keep=all|first|layouts|<indices>` + `--timescale` in remux.sh,
  mov.sh classifier consumes the full track set with `layouts` default
  (stereo+5.1 both survive; duplicate layouts curated lossless > lossy-high >
  lossy-low; every drop announced with its rule), dual-track.sh single-pair
  scope announced + not-copyable-a:0 refusal, policy fixtures pinned, SKILL
  policy rows. C64 CONFIRMED+REFINED (ffmpeg ALAC never rejects — silent
  NEAREST-layout negotiation: 5.1(side)→5.1(back), 7.1→6.1/7ch drop; any
  `--access-codec alac` must pin layouts); C66 structure half probed (tkhd
  enabled/group 1-1-0 over groups 0/1/1 — proper alternate-group semantics).
- **5-4 DONE (calibration)** — (a/b) source-baseline + line classification on
  gates (c)/(e) with deterministic `-threads 1` recounts; (c) waiver sidecar
  (`waiver.sh` + verify.sh consult: exact gate+counts+size+vhash+verbatim
  attestation → exit 0 with loud `WAIVED(<gate>)` + `VERIFY_SUMMARY`; any
  drift voids; essence gates never eligible); (d) pairfill C05 bound DERIVED —
  `PREROLL + min(pair-ramp excursion, 16 pairs) + 1 pair`, floored at the old
  limit (XLVI re-measured live: excursion +9009 = 3.00 pairs, deliverable
  36036 admitted at 39039; wrong-cadence still refused); (e) ms-timebase
  doctrine in timeline-repair.md with measured numbers (1/16000 inherited,
  alternation source-baked); (f) retroactive-waiver need DISSOLVED — both
  pre-protocol pairs (XLVI; the feed.mkv pair identified as Super Bowl
  XLVIII 2014) now REVIEW-with-evidence exit 0 under the calibrated gates,
  XLVIII reproducing the transcript's 152 muxer-stage lines mechanically at
  delta 0; (g) fixtures: waiver round-trip pinned, b-pyramid fixture
  (maxoff 54054 > old limit 36036, admitted at 57057, order preserved),
  ms-advisory pins. C67/C68/C69/C70 all CONFIRMED; C46 CONFIRMED earlier in
  the round on the first real >4 GiB deliverable (co64 ×3 traks).
- **5-3 DONE (attestation)** — rung4.sh is the only sanctioned re-encode path
  (verbatim attestation via lib-attest.sh, never echoed, near-miss refused;
  mdta provenance round-trip-verified; never overwrites); verify.sh
  master-purity check (video-scoped x264/x265/Lavc signatures; recognizes
  stamped derivatives; WARN on introduced signatures; dual-track audio can
  never trip it — pinned); SKILL.md doctrine (diagnostic obligation +
  evidence-block shape with the two July 2026 transcripts as exemplars;
  Rung-4 protocol with the audio exemption stated; honest tripwire limit);
  mov/SKILL.md sole-route line.
- **5-1 DONE (Tahoe drift)** — drift subsection + `mjpeg|icod` detection grep;
  C57 annotated (forum evidence annotates, never flips); playable-check
  self-dates its OS. **First-party 5-1e finding:** on 26.5.2 (post-drop),
  MJPEG-in-MOV **yuvj420p renders, yuvj422p renders NO frame and HANGS
  qlmanage ≥2 min** — the variant-scoped drop reproduced on the AVFoundation
  stack; playable-check can STALL rather than fail fast on dropped variants.
  C63 row recorded UNVERIFIED with the data point.
- **5-5 DONE (small closures)** — faststart second-pass cost documented ×3
  (muxer log line captured); gama "QT gamma era" subsection + C71 row with
  the detection half probed (mp4edit-injected `gama` beside `pasp`;
  `PR_GAMA=yes` + WARN; `-c copy` drops it — normalization verified); cmov
  note; avconvert doctor line + delivery-encode cross-check. **5-5e executed
  against C61, not C26** — the addendum's "C26" is a digit transposition
  (C26 = HDR10-SEI, untouched); recorded verbatim in the C61 row.
- **Plan defects found at execution:** the 5-5e C26/C61 transposition (above);
  no others. Session bugs caught by probe before commit: bash-3.2
  `$(awk "…\"…")`-in-quotes parse bug in the pairfill excursion echo (the
  round-1 5f class, precomputed); rung4 `.part` extension hiding the mux
  format; a `2>&1 >>` redirection-order slip in the C69 line-set capture.
- **Ledger census at close:** 71 rows — 36 CONFIRMED, 2 REFUTED,
  2 REFINED, 1 BUG-found-and-fixed, 30 UNVERIFIED (all blocked-with-reason:
  artifacts, GUI/listen sessions, or next-OS re-runs; nothing gating a
  shipping decision).
- **Carry-forwards (named):** C64/C65 ALAC `chan`+speaker-ident LISTEN session
  (still blocks the 5-2e `--access-codec alac` flag); C66 GUI half (is the
  alternate selectable?); C63 — re-run the MJPEG pair after the next macOS
  update, QuickTime-Player GUI check of the 422 file, AIC artifact leg, and
  consider a playable-check timeout guard against the qlmanage stall; C71 A/B
  rendering half (GUI); C61 DV sample-entry probes (needs real DV artifacts);
  XLVI + XLVIII archival sign-off (`--full` + MKV strict-mux — both currently
  REVIEW-with-evidence); 5h real-PAFF fixture (blocked on the S34E12
  re-download; the 5-4g b-pyramid fixture covers the frame-coded half only);
  3c captions (needs a CC-bearing capture); C25 range note (MKV `range=tv`
  cannot ride QTFF nclc — `--signaling` REVIEWs by design, pre-existing).

## Execution order & exit criteria

Run 0 → 1 → 4a/3b (the two suspected live bugs jump the queue after Phase 1)
→ 2 → 3 → 5. Each item lands as its own commit: probe evidence in the message,
reference updated, regression pinned where a behavior changed. The audit is
done when `references/qtff-claims.md` has zero unverified rows and the two ⚠
items are either fixed or disproven with recorded evidence.


---

## Round 5 — Gap closure: Tahoe drift, audio-policy classifier, Rung-4 attestation, verification calibration

**Sources feeding this round:** July 2026 external research sweep (Tahoe 26.4
codec removals, hvc1 family, faststart mechanics, gama/cmov legacy); two
production transcripts (feed.mkv MPEG-2 4:2:2 session; Super Bowl XLVI PAFF
session) — both citable as session evidence under the registry's user-verified
convention.

**Method:** unchanged — falsifiable sentence → spec anchor → probe a REAL
artifact → classify BUG / DOC-DRIFT / CONFIRMED. Every item its own commit,
probe evidence in the message, regression pinned where behavior changed. New
claims append at C63+ (5-0a confirms the true max before any row is written).

### 5-0. Baseline (read-only)

- **5-0a.** Confirm registry max ID (expected C62) and freeze the C63–C71
  assignments below; correct all cross-references if the max differs. Confirm
  no open ledger row already covers an item below (C26 explicitly reserved for
  amendment, not duplication).
- **5-0b.** Run the suite unmodified; require 122/122 (or current green count).
  Record `sw_vers`, ffmpeg, Bento4 versions for this round's verification
  stamps.
- **5-0c.** Collision check against open items: 2b (sdtp half), 3c (captions),
  5h (real-PAFF fixture), and the 27 UNVERIFIED rows. Note where a Round-5 item
  advances one (5-4d advances C05; 5-5e amends C26; 5-1b annotates C57).

### 5-1. macOS decode-set drift (Tahoe 26.4)

- **5-1a.** `references/ingest-compatibility.md`: new subsection "Decode
  support is a moving target — macOS version drift." Rows: Motion JPEG
  (certain MOV mux variants dropped in 26.4), Apple Intermediate Codec
  (`icod`, dropped 26.4; restorable via Apple ProApps legacy codec package —
  link the support article). Detection grep extended: `mjpeg|icod` beside the
  existing `cinepak|svq`.
- **5-1b.** C57 amendment — append the Tahoe 26.4 corroboration as a **note**,
  status stays UNVERIFIED: forum evidence does not meet the registry's probe
  bar, and no row flips without probe evidence recorded in the flipping commit.
- **5-1c.** `scripts/playable-check.sh`: print `sw_vers -productVersion` in the
  result line so every recorded check self-dates its OS. Output annotation
  only; no logic change.
- **5-1d.** SKILL.md Instant answers row: "Old MOV thumbnails vanished /
  stopped opening after a macOS update → Tahoe 26.4 codec drops → detection
  grep → Rung 4 for a playable copy, original stays master."
- **5-1e.** Probe: synthesize an MJPEG-in-MOV fixture (`-c:v mjpeg`);
  playable-check on this Mac. The forum claim is variant-scoped, so a PASS
  here is honest data, not a refutation — record whichever way it lands. AIC
  has no ffmpeg encoder: blocked-on-artifact, recorded like C57's own
  blockers.

| # | Claim | Stated in | Spec anchor | Probe | Status |
|---|-------|-----------|-------------|-------|--------|
| C63 | The set of codecs AVFoundation decodes is a function of macOS version; a playable-check result is valid only for the OS it ran on, and OS upgrades can revoke playability of previously-passing files (Tahoe 26.4: Motion JPEG variants, AIC). | references/ingest-compatibility.md; scripts/playable-check.sh | player behavior — empirical only | MJPEG-MOV fixture: playable-check on Darwin 25.x; re-run after next macOS update; AIC leg blocked on artifact | UNVERIFIED |

### 5-2. Audio-policy classifier: track-set aware (the transcript-1 defect)

**Root cause restated as engineering fact:** mov.sh's MODE classifier reads
`PR_ACODEC` — track a:0 only. A FLAC-5.1 + MP2-stereo source classifies `pcm`
off the FLAC; the classifier never sees track 2. remux.sh maps a:0 unless
`--all-audio`. The drop is a policy blind spot, not a forgotten flag.

**Policy (into SKILL.md house defaults):** distinct channel layouts are
distinct deliverables — never silently collapsed. Duplicate layouts are
curated (lossless > lossy-high > lossy-low within a layout). Every drop is
announced. Curation requires an audit: no silent mapping decisions anywhere.

- **5-2a.** `scripts/probe.sh --kv`: per-track audio manifest —
  `PR_AUD_COUNT`, and per track `PR_AUD_<n>_CODEC/CHANNELS/LAYOUT/LANG`. Keys
  must satisfy the existing `^(PR|PF)_[A-Z0-9_]+=` eval whitelist.
- **5-2b.** `scripts/remux.sh`: `--audio-keep=all|first|layouts|<indices>`
  (`--all-audio` kept as alias for `all`; `first` = current behavior);
  pre-flight KEEP/DROP manifest table printed before writing, each line
  stating the deciding rule, every DROP a WARN. Add `--timescale N`
  (`-video_track_timescale`).
- **5-2c.** `scripts/mov.sh`: classifier consumes the full manifest.
  Per-layout classification (native→copy, MOV-copyable-non-native→dual,
  non-copyable→access-track), `layouts` as the default keep policy —
  satisfying both original intents: mp2 feed clones die, stereo+5.1 pairs
  survive. `MOV_SUMMARY` gains `audio_kept=`/`audio_dropped=` fields.
  **Design-call at gate:** the `layouts` default.
- **5-2d.** `scripts/dual-track.sh`: audit for the same a:0 assumption; extend
  to build access+original pairs per kept track or announce its single-pair
  scope loudly — whichever the audit supports. pairfill's 5a warning stays
  as-is (already fixed).
- **5-2e.** ALAC as **opt-in** access-track codec (`--access-codec alac`) —
  not a silent change to the PCM house default (dual-track-quicktime.md owns
  that default and its QC). Blocked on C64/C65.
- **5-2f.** Fixtures: (i) 5.1+stereo → both survive under `layouts`;
  (ii) 5.1+stereo+duplicate-mp2 → exactly the clone drops, announced;
  (iii) `first` reproduces today's behavior bit-for-bit.
- **5-2g.** SKILL.md Instant answers: replace the bare "keeps a:0 — add
  --all-audio" row with the policy row + manifest pointer.

| # | Claim | Stated in | Spec anchor | Probe | Status |
|---|-------|-----------|-------------|-------|--------|
| C64 | ffmpeg's native ALAC encoder accepts 5.1 input (and which layouts it accepts/rejects is enumerable). | scripts/remux.sh (--access-codec) | player behavior — empirical only (encoder capability) | encode 5.1(side) + 5.1 test tones; record accepted layouts per CI ffmpeg version | UNVERIFIED |
| C65 | ALAC 5.1 in MOV carries a `chan` layout QuickTime maps to the correct speakers (the C31 bar: per-channel ident tones land on the right speakers). | scripts/remux.sh; references/dual-track-quicktime.md | markdown/sound_media/sound_sample_descriptions.md; audio_channel_layout_atom | `mp4dump` stsd+chan on an ALAC-5.1 build; speaker-ident listen on the target Mac | UNVERIFIED |
| C66 | In a MOV carrying stereo + 5.1 as separate enabled tracks (not the dual-track access pattern), QuickTime's default-track selection and alternate reachability follow tkhd enabled flags + alternate_group as written by ffmpeg for this case. | scripts/mov.sh (layouts policy) | markdown/track_atoms/track_header_atom.md; alternate groups | `mp4dump` tkhd/alternate_group on a layouts-policy output; GUI check which plays, whether the other is selectable | UNVERIFIED |

### 5-3. Rung-4 attestation + diagnostic obligation

**Corrected premise:** no transform path exists to gate — every writer
hard-guarantees `-c copy` video; Rung 4 today is hand-rolled ffmpeg from
delivery-encode.md. Enforcement requires building the sanctioned path.

- **5-3a.** New `scripts/rung4.sh` — the **only** sanctioned re-encode path.
  Wraps the delivery-encode.md recipes (ProRes, x264, x265 presets as named
  profiles). Refuses to run without `--attest="<exact string>"` (or
  `REMUX_ATTEST` env; exact match, no fuzzy accept). Consent string defined
  once in a shared constant; **wording decided at gate** — provisional:
  `I understand this re-encodes the video and the output is no longer true
  source material.` Atomic write, never targets the source, output naming can
  never collide with a master.
- **5-3b.** Provenance: rung4.sh stamps the derivative via metadata.sh
  conventions (`mdta` keys: source filename, date, profile,
  `reencoded-with-attestation`). A derivative must never masquerade as a
  master in a later audit.
- **5-3c.** `scripts/verify.sh`: master-purity WARN — encoder writing-library
  signatures (x264/x265/Lavc) **scoped to the video stream only** on files
  presented as copy-lineage (dual-track access audio legitimately carries
  Lavc tags; scoping prevents a false purity alarm on every default
  deliverable).
- **5-3d.** SKILL.md doctrine, two sections. *Diagnostic obligation:* before
  any failure is reported to the operator, doctor.sh + probe.sh must have run,
  every rung below the current one executed (not considered), and the report
  shaped as an evidence block — commands, outputs, rung reached, hypothesis.
  "It failed, want me to try X?" is a forbidden shape. *Rung-4 protocol:*
  proposing Rung 4 requires Rungs 1–3 evidence blocks in the same message; the
  attestation phrase must originate verbatim from the operator — no
  paraphrase, no "yes" substitutes, never supplied on the operator's behalf.
  Audio transforms (existing pcm/aac paths, ALAC per 5-2e) explicitly exempt,
  and the exemption stated so it can't be "clarified" away. Cite the two July
  2026 transcripts as the canonical evidence-block exemplars.
- **5-3e.** `skills/mov/SKILL.md`: point its existing "never re-encode to
  force a pass" line at rung4.sh as the sole route.
- **5-3f.** Regression: no-attest → nonzero; exact string → proceeds;
  near-miss (trailing-period delta) → refuses; provenance keys present in
  output (`mp4dump` the ilst).
- **5-3g.** Honest limit, recorded in the doctrine: the script gate is a
  tripwire, not a wall — direct ffmpeg invocation bypasses it. Depth comes
  from 5-3d's evidence-block bar and 5-3c's after-the-fact purity scan.

### 5-4. Verification calibration: baseline automation, waiver protocol, derived bounds

**Framing:** gate (c)'s note already states the baseline bar; gate (e)'s note
already names the three-proof set. This section mechanizes stated policy on
the 5c lazy-escalation template. Nothing here weakens a gate: classification
and baselining can only downgrade FAIL→REVIEW-with-explanation, never to
silent OK, and only with gate (d) clean.

- **5-4a.** Gates (c)/(e): automated source-baseline. On nonzero error counts,
  lazily run the identical stage against the source under identical seek
  conditions; report `source: N / output: N / delta: D`. Delta 0 with (d)
  clean → REVIEW with the inherited-noise note; delta > 0 → FAIL as before.
  (Mechanizes the manual moves in both transcripts: null-muxer lines
  identical on the untouched MKV; `mmco: unref short failure` at identical
  timestamps in the 2012 capture.)
- **5-4b.** Gate (e) message classification: count decoder-class lines and
  muxer-stage `[null @ …]` lines separately. Muxer-stage lines score toward
  FAIL only if the source baseline does **not** reproduce them or (d) is
  dirty — the post-mortem masking warning stays load-bearing.
- **5-4c.** Waiver sidecar. When a gate fails but its named independent proofs
  all pass, the session may propose `OUTPUT.mov.waiver.json`: failed gate,
  exact failure signature (class + count), proof results with hashes,
  coverage limits stated plainly (e.g. "frame order proven on 5 windows / 954
  frames, not full duration"), tool versions, date, operator attestation
  string (distinct from Rung-4's; **wording at gate** — provisional:
  `I accept this waiver; the recorded evidence proves this gate failure
  benign for this file.`). verify.sh consults the sidecar: signature matches
  exactly → exit **0** with a loud `WAIVED(<gate>)` line and a
  machine-readable summary field (house exit codes 0/10/1/2 untouched); any
  new signature or changed count → hard FAIL, waiver void. Scope: one file,
  one signature — never a class.
- **5-4d.** `scripts/pairfill-paff.sh`/`lib-paff.sh`: revise the C05 gate —
  bound derived from measured pyramid depth
  (`max(PTS−DTS) ≤ measured_depth × pair + slack`), floored at the current
  `preroll+pair` so simple streams get no looser. The XLVI refusal
  (36036 > 30030 on a legitimate 4-frame hierarchical-B pyramid, structurally
  unsatisfiable by any flag) is the motivating probe. C05's status row gains
  the revision note. **Slack margin at gate.**
- **5-4e.** `scripts/probe.sh`: ms-timebase advisory — detect 1/1000-quantized
  sources and alternating tick durations; print: recommend
  `--timescale <conventional base>`, state the ±0.5 ms alternation is
  source-baked and imperceptible, repeat diagnose.sh's prohibition on
  constant-rate restamps for reorder-pyramid streams.
- **5-4f.** Retroactive waivers: audit item — pre-protocol evidence-delivered
  files (Super Bowl XLVI at minimum) get sidecars so their permanent-FAIL
  status stops depending on human memory.
- **5-4g.** Fixtures: ms-timebase MKV (asserts 5-4a/b classification + 5-4e
  advisory); waiver round-trip (create → re-verify WAIVED/exit 0 → mutate
  signature → FAIL); synthesized frame-coded hierarchical-B via x264
  `b-pyramid` (accepts under derived bound; still refuses a genuinely
  wrong-cadence ramp — the C05 regression stays pinned). Field-coded pyramid
  remains blocked on 5h's real capture; note the linkage.

| # | Claim | Stated in | Spec anchor | Probe | Status |
|---|-------|-----------|-------------|-------|--------|
| C67 | Hierarchical-B streams legitimately carry max(PTS−DTS) = reorder_depth × frame_duration; a fixed one-frame lead bound structurally rejects valid ≥2-level pyramids. | scripts/pairfill-paff.sh; scripts/lib-paff.sh | markdown/sample_atoms/composition_offset_atom.md | measure offset cycle on the XLVI deliverable (read-only, T7) + synthesized b-pyramid fixture; assert derived bound admits both | UNVERIFIED (session evidence: XLVI transcript 2026-07) |
| C68 | MKV's 1/1000 timebase survives MKV→MOV as a coarse video timescale (e.g. 1/16000) with alternating sample durations; the alternation is source rounding (±0.5 ms), not judder, and `-video_track_timescale` is a conventionality fix that must not be escalated to a restamp on reorder streams. | references/timeline-repair.md (beside C02); scripts/probe.sh; scripts/remux.sh | markdown/media_atoms/media_header_atom.md; time-to-sample_atom | ms-timebase MKV fixture → remux with/without --timescale; stts histograms both sides; framemd5 identity | UNVERIFIED (session evidence: feed.mkv transcript 2026-07) |
| C69 | Null-muxer duplicate-DTS complaints in the scrub harness on ms-quantized sources are harness artifacts when gate (d) is clean and the identical lines reproduce on the untouched source — the timeline is then provable by the (d) + strict-mux + --full triple. | scripts/verify.sh (e); references/verification-safety.md | player behavior — empirical only (harness behavior) | ms-timebase fixture: identical line sets source vs output; (d) clean; --full framemd5 match | UNVERIFIED (session evidence: feed.mkv transcript — 152/152 lines muxer-stage, all three proofs passed) |
| C70 | Decoder complaints (e.g. `mmco: unref short failure`) present in the source at identical timestamps under identical accurate-seek conditions are capture-inherited, not remux-induced; only the source/output delta indicts the pipeline. | scripts/verify.sh (c)/(e); scripts/diagnose.sh | player behavior — empirical only | baseline-subtraction run on the XLVI pair (read-only): delta 0 | UNVERIFIED (session evidence: XLVI transcript) |

### 5-5. Small closures

- **5-5a.** faststart cost: container-internals.md note + house-defaults line
  + batch.sh header — moov still written last, then a full-file rewrite pass
  shifts everything; ~2× write I/O per file; on multi-GB masters over
  external SSDs this dominates batch throughput; consider whether the access
  copy, not the master, is where faststart belongs.
- **5-5b.** gama: color-hdr-subs.md subsection "Pre-2010 exports: the QT
  gamma era" (gama vs missing nclc, why old masters render dark/washed;
  modern colr supersedes); probe.sh WARN on gama presence (mp4dump grep when
  available). Note 3d's write-side half (never written alongside colr) stays
  separate — this is the ingest side.
- **5-5c.** cmov: two-line container-internals note — zlib-compressed moov in
  early-QT files; symptom is confusing/truncated mp4dump; ffmpeg reads
  transparently, so a stream-copy remux is the normalization.
- **5-5d.** avconvert: doctor.sh optional-tools report line when on PATH;
  delivery-encode.md cross-check note — AVFoundation ground truth for Rung-4
  comparisons; caveats: one video + one audio track survive, extension picks
  output type, no protected content.
- **5-5e.** C26 amendment (Dolby Vision): enumerate the sample-entry family
  (dvh1/dvhe/hvc2/hev2/hvc3/hev3) and the dvh1-plays/hev1-family-fails split
  as the claim's testable halves; still blocked on artifacts. probe.sh: report
  stsd sample entry (`hevc (dvh1)`) via mp4dump, ffprobe `codec_tag_string`
  fallback, degrading silently when neither adds signal. ingest-compatibility
  DV row.

| # | Claim | Stated in | Spec anchor | Probe | Status |
|---|-------|-----------|-------------|-------|--------|
| C71 | A legacy `gama` atom (absent nclc/colr) changes QuickTime's rendering of the same essence versus an nclc-tagged copy; ingest should surface it. | references/color-hdr-subs.md; scripts/probe.sh | markdown/video_media/video_sample_description_extensions.md (+ color_parameter_atom conflict note) | inject gama via mp4edit on a fixture; A/B in QuickTime Player | UNVERIFIED |

### 5-6. Close-out

Suite green including every new pin; ledger consistency pass (no orphan
cross-references, all Round-5 claims stamped or blocked-with-reason); README
changelog + plugin.json bump; findings-log entry in the house format;
carry-forwards named (C64/C65 listen session, C63 next-macOS re-run,
retroactive waivers, 5h linkage).

**Round-5 gate items (operator decisions):** ① Rung-4 attestation wording;
② waiver attestation wording; ③ `layouts` as mov.sh default; ④ pairfill slack
margin; ⑤ probe.sh additions ship as one combined diff (5-2a + 5-4e +
5-5b/e) — approve the diff as a unit.

**Execution order:** 5-0 → 5-4a/b (calibration first — it changes what every
later probe's FAIL means) → 5-2 → 5-4c–g → 5-3 → 5-1 → 5-5 → 5-6.

---

## Round 5 — /loop execution prompt (verbatim)

```
You are executing Round 5 of QTFF-AUDIT-PLAN.md for the remuxing-to-mov plugin.
Repo: /Users/salvatore/downloads/claude-plugins/plugins/remuxing-to-mov
Read QTFF-AUDIT-PLAN.md (Round 5 addendum) and references/qtff-claims.md FIRST,
fully, before touching anything. The addendum is the work order; this prompt is
the discipline.

INVARIANTS — violating any of these ends the session:
- Sources and masters are immutable. Never modify, move, or delete any media
  file. T7/T9 media is read-only. Never commit media to the repo.
- Video is always -c copy in every writer except the new rung4.sh, which never
  runs without the exact attestation string.
- No claim row flips status without probe evidence recorded in the flipping
  commit. Forum/secondhand evidence annotates; it never flips.
- Existing claim IDs and text are never renumbered or reworded except where the
  addendum names an amendment (C05 gate note, C26, C57).
- No new required dependencies. Every new check degrades to SKIP/report-only
  when tooling is absent, per playable-check.sh convention.
- probe.sh --kv output must satisfy the eval whitelist ^(PR|PF)_[A-Z0-9_]+=.
- Exit-code vocabulary stays 0/10/1/2. Waivered pass = exit 0 + loud WAIVED
  line + machine-readable summary field.
- All scripts run under macOS /bin/bash 3.2. shellcheck clean or annotated.
  Atomic writes (.part -> mv) everywhere. -nostdin on every ffmpeg call.
- Gate downgrades only ever go FAIL -> REVIEW-with-explanation, with gate (d)
  clean and the source baseline reproducing the lines. Never silent OK.
- tests/regression.sh must be green before the first edit and after every
  phase. A red suite halts the loop.

LOOP SHAPE — one addendum item per iteration, in the addendum's execution
order (5-0 -> 5-4a/b -> 5-2 -> 5-4c-g -> 5-3 -> 5-1 -> 5-5 -> 5-6):
1. Restate the item's claim or behavior as a falsifiable sentence.
2. Read every file the item touches IN FULL before editing.
3. Probe a REAL artifact (mp4dump/ffprobe on script-built output; synthesized
   fixtures via regression recipes) — never reason from the command that made it.
4. Implement the minimal diff. Pin behavior changes in regression.
5. Classify: BUG / DOC-DRIFT / CONFIRMED / blocked-on-artifact, and record in
   qtff-claims.md and the findings log in the house format.
6. Commit: one item, probe evidence in the message.
7. Report an evidence block (commands, outputs, classification) — never a
   symptom description — then STOP at any gate item.

GATES — halt and wait for the operator at: 1) Rung-4 attestation wording,
2) waiver attestation wording, 3) layouts-default for mov.sh, 4) pairfill slack
margin, 5) the combined probe.sh diff. Present the diff and the probe evidence;
do not proceed on silence.

RUNG-4 DOCTRINE (applies to you, now, in this session): a failure report
without doctor.sh + probe.sh output and every lower rung executed is an
incomplete task. Proposing any re-encode requires Rungs 1-3 evidence blocks in
the same message and the operator's verbatim attestation string. You never
supply that string. The two July 2026 transcripts cited in SKILL.md are the
required shape of your reports.

DONE = 5-6 close-out complete: suite green with all new pins, ledger
consistent, findings-log entry written, carry-forwards named, version bumped.
```
