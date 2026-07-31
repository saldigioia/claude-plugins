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
- Field-coded (PAFF) input is auto-routed to the right timeline repair by its
  timestamp profile: pair-timestamped/reordered streams get the pair-mate PTS
  fill (real PTS kept, original audio preserved bit-exact in the dual-track);
  only a no-reorder stream gets the elementary rebuild (original audio not
  bit-exact preserved on that path — the script says so).
- A copy mux whose log confesses invented timing (`pts has no value` /
  `Timestamps are unset`) is a hard stop — the script refuses to bless the
  output and points at `diagnose.sh`. Relay that verbatim; never ship the file.
- **Backhaul refusal gate (exit 11)** — two source classes are refused *before*
  any build: MPEG-2 4:2:2 (`yuv422p`, the satellite-contribution mastering
  profile — QuickTime has **no decoder** for it, so even a bit-perfect MOV
  distorts), and mpegts/MPEG-2 sources with forward timestamp gaps **plus**
  non-monotonic DTS (timeline rot — no lossless MOV of that class survives
  verify). The refusal prints three honest routes: keep the source (it is the
  archival master), a lossless MKV playback copy (IINA/VLC/mpv), or the
  operator-attested `rung4.sh` re-encode. Gaps alone do **not** refuse.

## Report back

Use the exit code: `0` = DONE (verified lossless), `10` = REVIEW (written, wants a
closer look), `1` = FAIL (nothing trustworthy produced), `11` = REFUSED (backhaul
profile — nothing was built, by design). On REVIEW/FAIL, relay the
script's stated reason. On `11`, relay the refusal **and its three routes
verbatim**; never ship anyway, never hand-roll an ffmpeg workaround, and never
invoke `--force-backhaul` or `rung4.sh` unless the operator explicitly asks —
the override and the re-encode are human decisions. **Never** re-encode to force a pass — a scoped re-encode
(Rung 4) is a human decision, and its **sole sanctioned route** is
`skills/remuxing-to-mov/scripts/rung4.sh`, which refuses to run without the
operator's verbatim attestation. Never hand-roll a re-encode around it; the
attestation phrase must come from the operator, never from you.
