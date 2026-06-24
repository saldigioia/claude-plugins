---
name: mov
description: One-shot, lossless-first remux of a file to a QuickTime-ready .mov. Use whenever the user wants to convert/remux a capture to .mov or QuickTime and have it "just work" — correct hvc1/faststart technique, and a dual-track build (PCM access + original preserved) automatically when, and only when, the source audio (AC-3/DTS/MP2) won't play in QuickTime (E-AC-3/Dolby Digital Plus plays natively, so it is copied single-track). Verifies the output; never re-encodes video; never touches the source. Can also embed proper QuickTime metadata, but only when the user explicitly asks to tag the file.
argument-hint: [input-file] [output.mov]
allowed-tools: Bash Read
---

# /mov — one-shot QuickTime-ready remux

Turn the file in `$ARGUMENTS` (or the file the user just referenced) into a
QuickTime-ready `.mov`, lossless-first. This is your saved-prompt shortcut for
"remux to MOV, proper QuickTime technique, dual-track PCM + source **only when
necessary**, verified." Run the bundled driver — do **not** hand-roll ffmpeg.

## Do this

Run the driver once per input. It's bundled in this plugin:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/scripts/mov.sh" <INPUT> [OUTPUT.mov]
```

(If `${CLAUDE_PLUGIN_ROOT}` isn't set, fall back to
`${CLAUDE_SKILL_DIR}/../remuxing-to-mov/scripts/mov.sh`, or the in-plugin path
`skills/remuxing-to-mov/scripts/mov.sh`.)

- **Output**: defaults to `<input>.mov` beside the source (the source is never
  overwritten). Pass a second argument to choose the path.
- **Flags**: `--always-dual` forces the dual-track even when the audio is already
  QuickTime-native; `--full` runs the archival whole-file verification.
- **Metadata (opt-in — ONLY if the user explicitly asks to tag the file)**: pass
  `--title`, `--description`, `--author`, `--date`, `--copyright`, `--comment`,
  `--keywords`, or `--key NAME=VALUE`. These embed proper QuickTime (`mdta`) metadata
  and drop the generic chapter "menu". **Never add them on your own** — the default
  deliverable carries no metadata.

## What it decides for you

- Video is always stream-copied (bit-identical); HEVC is tagged `hvc1`, faststart on.
- Audio, by QuickTime **playability**: AAC/ALAC/MP3/PCM and **E-AC-3 (Dolby Digital
  Plus)** are copied as-is (single track); AC-3/DTS/MP2 become a **dual-track** MOV —
  a PCM "access" track that always plays, plus the original copied bit-exact as track 2.
- Field-coded (PAFF) input is auto-routed to the timeline rebuild (the original
  audio isn't bit-exact preserved on that path — the script says so).

## Report back

Use the exit code: `0` = DONE (verified lossless), `10` = REVIEW (written, wants a
closer look), `1` = FAIL (nothing trustworthy produced). On REVIEW/FAIL, relay the
script's stated reason. **Never** re-encode to force a pass — a scoped re-encode
(Rung 4) is a human decision; point to `references/delivery-encode.md` instead.
