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

## Execution order & exit criteria

Run 0 → 1 → 4a/3b (the two suspected live bugs jump the queue after Phase 1)
→ 2 → 3 → 5. Each item lands as its own commit: probe evidence in the message,
reference updated, regression pinned where a behavior changed. The audit is
done when `references/qtff-claims.md` has zero unverified rows and the two ⚠
items are either fixed or disproven with recorded evidence.
