# remuxing-to-mov

Losslessly remux broadcast and web video (`.ts`, `.mpg`/`.vob`, `.mkv`, broken
`.mov`) into a QuickTime-ready `.mov` **without re-encoding**. Re-encoding is a
last resort, scoped as narrowly as possible (audio-only, or one GOP), never the
whole video.

## Quick start

```bash
scripts/doctor.sh                  # one-time: is this ffmpeg capable?
scripts/mov.sh IN.ts               # the everyday one: QuickTime-ready, dual-track only if needed, verified
scripts/auto.sh IN.ts OUT.mov      # the lossless ladder, hands-off (single-track audio)
scripts/batch.sh DIR --out OUTDIR  # a whole folder, with provenance + resume
```

In Claude Code these are also a slash command — **`/remuxing-to-mov:mov FILE`**
(or just ask to "convert FILE to mov") runs `mov.sh`: proper QuickTime technique
(`hvc1`/faststart), plus a dual-track PCM-access + bit-exact-original build
automatically **only when** the source audio (AC-3/E-AC-3/DTS/MP2) won't play in
QuickTime. Output defaults to `<input>.mov` beside the source. Nothing here
re-encodes video or touches the source; exit codes `0` = verified, `10` = REVIEW,
`1` = FAIL.

## What it does

- **Five-rung escalation ladder** — stop at the first rung that produces a
  clean, verified file: pure copy → copy video + PCM audio → regenerate
  timestamps → rebuild the timeline from the elementary stream → scoped
  re-encode (the documented last resort).
- **Glitch diagnosis** — a decode-to-null / MKV strict-mux / DTS-monotonicity /
  forward-gap ladder that separates damaged captures from the timestamp defects
  behind scrub-tearing PAFF remuxes and gap-collapse audio desync.
- **Dual-track default deliverable** — PCM "access" track that always plays in
  QuickTime + the original audio copied bit-exact as track 2 for provenance.
- **Discontinuity resync** — a discontinuous source (dropped-frame gaps) desyncs
  raw PCM on a blind copy; `resync.sh` re-times the audio to the picture while the
  video stays bit-identical (an explicit, human-invoked fix).
- **Opt-in QuickTime metadata** — `metadata.sh` embeds title/description/etc. in the
  proper QuickTime `mdta` format and drops the generic chapter "menu"; never applied
  automatically (the default deliverable is metadata-free).
- **Verification of every output** — decoded-pixel identity (timestamp-agnostic
  MD5), a scrub gate, and an A/V duration-parity (sync) gate; playable ≠ valid ≠
  lossless ≠ in-sync, so all are checked.
- **Safety rails** — atomic output (`.part` → `mv`), refusal to overwrite the
  source in place, intermediates never auto-deleted, `-nostdin` everywhere.

## Layout

```
skills/remuxing-to-mov/
  SKILL.md                 workflow, escalation ladder, instant-answer card
  scripts/                 doctor, probe, diagnose, mov + auto (one-shot drivers),
                           remux, rebuild-paff, resync, dual-track, metadata, verify,
                           batch, gop-probe, seam-check, playable-check
  references/              codec/container tables, timeline repair, color/HDR,
                           cutting/concat, dual-track QC, container internals
  examples/                worked driver scripts from a real broadcast job
  tests/                   self-contained regression harness (run after edits)
```

Every codec/container compatibility claim in the references is verified
empirically against a named ffmpeg version (6.1.1 and 8.1.1), with the
verification date recorded.

## Requirements

`ffmpeg`/`ffprobe` on PATH. Optional: `mediainfo` (field-structure detail),
Bento4 `mp4dump` (atom dumps).
