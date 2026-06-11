# remuxing-to-mov

Losslessly remux broadcast and web video (`.ts`, `.mpg`/`.vob`, `.mkv`, broken
`.mov`) into a QuickTime-ready `.mov` **without re-encoding**. Re-encoding is a
last resort, scoped as narrowly as possible (audio-only, or one GOP), never the
whole video.

## What it does

- **Five-rung escalation ladder** — stop at the first rung that produces a
  clean, verified file: pure copy → copy video + PCM audio → regenerate
  timestamps → rebuild the timeline from the elementary stream → scoped
  re-encode (the documented last resort).
- **Glitch diagnosis** — a decode-to-null / MKV strict-mux / DTS-monotonicity
  ladder that separates damaged captures from the timestamp defects behind
  scrub-tearing field-coded (PAFF) H.264 remuxes.
- **Dual-track default deliverable** — PCM "access" track that always plays in
  QuickTime + the original audio copied bit-exact as track 2 for provenance.
- **Verification of every output** — decoded-pixel identity (timestamp-agnostic
  MD5) plus backward-DTS scan; playable ≠ valid ≠ lossless, so all three are
  checked.
- **Safety rails** — atomic output (`.part` → `mv`), refusal to overwrite the
  source in place, intermediates never auto-deleted, `-nostdin` everywhere.

## Layout

```
skills/remuxing-to-mov/
  SKILL.md                 workflow, escalation ladder, instant-answer card
  scripts/                 probe, remux, diagnose, rebuild-paff, dual-track, verify
  references/              codec/container tables, timeline repair, color/HDR,
                           cutting/concat, dual-track QC, container internals
  examples/                worked driver scripts from a real broadcast job
```

Every codec/container compatibility claim in the references is verified
empirically against a named ffmpeg version (6.1.1 and 8.1.1), with the
verification date recorded.

## Requirements

`ffmpeg`/`ffprobe` on PATH. Optional: `mediainfo` (field-structure detail),
Bento4 `mp4dump` (atom dumps).
