# remuxing-to-mov

Losslessly remux broadcast and web video (`.ts`, `.mpg`/`.vob`, `.mkv`, broken
`.mov`) into a QuickTime-ready `.mov` **without re-encoding**. Re-encoding is a
last resort, scoped as narrowly as possible (audio-only, or one GOP), never the
whole video.

## Quick start

```bash
scripts/doctor.sh                  # one-time: is this ffmpeg capable?
scripts/mov.sh IN.ts               # the everyday one: QuickTime-ready, dual-track only if needed, verified
scripts/auto.sh IN.ts OUT.mov      # the lossless ladder, hands-off (copy rungs keep every audio track; PAFF repair rungs build a:0)
scripts/batch.sh DIR --out OUTDIR  # a whole folder, with provenance + resume (ladder policy — no dual-track pair)
```

In Claude Code these are also a slash command — **`/remuxing-to-mov:mov FILE`**
(or just ask to "convert FILE to mov") runs `mov.sh`: proper QuickTime technique
(`hvc1`/faststart), plus a dual-track PCM-access + bit-exact-original build
automatically **only when** the source audio (AC-3/E-AC-3/DTS/MP2) won't play in
QuickTime. Output defaults to `<input>.mov` beside the source. Nothing here
re-encodes video or touches the source; exit codes `0` = verified, `10` = REVIEW,
`1` = FAIL, `11` = REFUSED with routes (codecs no `.mov` can carry — VC-1/VP9/AV1
video, Dolby E audio — or a child script's own refusal).

## What it does

- **Escalation ladder** — stop at the first rung that produces a clean,
  verified file: pure copy → copy video + PCM audio → regenerate timestamps →
  timeline repair (pair-mate PTS fill for pair-timestamped/reordered PAFF, or
  elementary-stream rebuild when no reorder survives) → scoped re-encode (the
  documented last resort).
- **Glitch diagnosis** — a decode-to-null / MKV strict-mux / DTS-monotonicity /
  forward-gap ladder that separates damaged captures from the timestamp defects
  behind scrub-tearing PAFF remuxes and gap-collapse audio desync, and routes
  the repair by the measured timestamp profile (untimestamped fraction +
  reorder scan).
- **Muxer-confession hard stop** — a copy mux whose log says `pts has no value`
  / `Timestamps are unset` / `Non-monotonic DTS` invented the timeline; the
  scripts refuse to bless that output no matter what the essence checks say.
- **Dual-track default deliverable** — PCM "access" track that always plays in
  QuickTime + the original audio copied bit-exact as track 2 for provenance.
- **Discontinuity resync** — a discontinuous source (dropped-frame gaps) desyncs
  raw PCM on a blind copy; `resync.sh` re-times the audio to the picture while the
  video stays bit-identical (an explicit, human-invoked fix).
- **Opt-in QuickTime metadata** — `metadata.sh` embeds title/description/etc. in the
  proper QuickTime `mdta` format and drops the generic chapter "menu"; never applied
  automatically (the default deliverable is metadata-free).
- **Verification of every output** — decoded-pixel identity (timestamp-agnostic
  MD5), a whole-file output-timeline gate (N/A timestamps, strict DTS,
  duration histogram), a scrub gate, an A/V duration-parity (sync) gate, and a
  presentation-ORDER check on `--full`; playable ≠ valid ≠ lossless ≠ in-sync ≠
  in-order, so all are checked.
- **Lossless container swap before any re-encode** — some MPEG-2 4:2:2 masters
  verify lossless, open in QuickTime, and render as garbage; no MOV sample-entry
  retag fixes them (ffmpeg writes one generic body for every MPEG-2 fourcc).
  `mp4-swap.sh` rebuilds the same bitstream as `.mp4` (`mp4v`+`esds`), verifies
  it, and re-runs the fidelity proof — measured to render correctly where the
  `.mov` of the identical bits does not. It sits between the retag and Rung 4,
  so a bad render never routes straight to a re-encode.
- **Post-mux census** — every builder reconciles the finished file against the
  plan it printed (stream count + per-stream codec identity) before blessing it;
  ffmpeg has been measured dropping a mapped stream with only a warning line.
- **Safety rails** — atomic output (`x.part.mov` → `mv`, extension kept so the
  kept artifact stays diagnosable), refusal to overwrite the
  source in place, intermediates never auto-deleted, `-nostdin` everywhere.
- **Attested re-encodes + recorded waivers** — `rung4.sh` is the only
  sanctioned re-encode path: it refuses without the operator's verbatim
  attestation and stamps QuickTime `mdta` provenance so a derivative can never
  masquerade as a master (`verify.sh` scans for exactly that). A gate failure
  whose independent proofs all pass can be recorded in an operator-attested
  `*.waiver.json` sidecar — one file, one exact signature; any drift voids it.

## Layout

```
skills/remuxing-to-mov/
  SKILL.md                 workflow, escalation ladder, instant-answer card
  scripts/                 doctor, probe, ts-health, diagnose, mov + auto (one-shot
                           drivers), remux, trim-to-idr, pairfill-paff, rebuild-paff,
                           resync, dual-track, mp4-swap (container-swap rung),
                           metadata, verify, batch, gop-probe,
                           seam-check, playable-check, qt-groups (opt-in post-pass),
                           rung4 (attested re-encode), waiver
  references/              codec/container tables, timeline repair, color/HDR,
                           cutting/concat, dual-track QC, container internals
  examples/                worked driver scripts from a real broadcast job
  tests/                   self-contained regression harness (run after edits)
```

Every codec/container compatibility claim in the references is verified
empirically against a named ffmpeg version (historically 6.1.1 and 8.1.1;
currently ffmpeg 9.0.1 on macOS 26.6.1, re-validated 2026-08-14), with the
verification date recorded.

## Requirements

`ffmpeg`/`ffprobe` on PATH. Optional: `mediainfo` (field-structure detail),
Bento4 `mp4dump` (atom dumps).
