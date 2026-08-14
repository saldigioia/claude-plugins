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
  QuickTime-native; `--full` runs the archival whole-file verification;
  `--no-idr-trim` keeps a mid-GOP capture head instead of the default announced
  auto-trim (see below); `--audio-keep` picks which audio tracks survive —
  default `all` (see below), `layouts` opt-in curation, `first` historical
  a:0-only, or explicit indices.
- **Metadata (opt-in — ONLY if the user explicitly asks to tag the file)**: pass
  `--title`, `--description`, `--author`, `--date`, `--copyright`, `--comment`,
  `--keywords`, or `--key NAME=VALUE`. These embed proper QuickTime (`mdta`) metadata
  and drop the generic chapter "menu". **Never add them on your own** — the default
  deliverable carries no metadata.

## What it decides for you

- Video is always stream-copied (bit-identical); HEVC is tagged `hvc1`, faststart on.
- Probing uses a raised window (`-probesize`/`-analyzeduration` 200M, sized for
  broadcast TS whose first SPS can sit many MB in — the stock 5 MB default
  misprobes those). Env-tunable via `RTM_PROBESIZE` / `RTM_ANALYZEDURATION`;
  you should never need to touch them. A mux that still fails probe-shaped
  retries once at 1G, announced first — never silently.
- Audio, by QuickTime **playability**: AAC/ALAC/MP3/**raw** PCM and **E-AC-3
  (Dolby Digital Plus)** are copied as-is (single track); AC-3/DTS/MP2 become a
  **dual-track** MOV — a PCM "access" track that always plays, plus the original
  copied bit-exact as track 2. Codecs that can't usefully be carried in MOV —
  FLAC/Opus/TrueHD, and **Blu-ray/DVD LPCM** (`pcm_bluray`/`pcm_dvd`:
  container-framed, NOT raw PCM — a MOV "copy" is a dead track no decoder
  claims) — land as a single PCM access track, stated plainly (keep the source
  container if the original bitstream matters).
- Every AC-3/E-AC-3 → PCM decode runs at **full dynamic range** (`-drc_scale 0`,
  the audiophile default shared by `remux.sh`/`dual-track.sh`; `--drc on` on
  those scripts keeps broadcast DRC — `mov.sh` itself takes no `--drc` flag).
  Note: pre-1.11 builds decoded at ffmpeg's default `drc_scale=1.0`, so default
  PCM output differs from 1.10 on DRC-carrying sources — that is the fix, not
  drift.
- A multi-track source keeps **every audio track by default** (`--audio-keep all`) —
  dropping tracks buys no playability, because the muxer enables exactly one
  audio track anyway (Apple TN3177); QT-native tracks copy bit-exact, the rest
  land as PCM access audio, and every decision prints in a pre-flight KEEP/DROP
  manifest. `--audio-keep layouts` is the opt-in curation (distinct
  layout+language pairs survive, duplicates ranked lossless > lossy-high >
  lossy-low, every drop a WARN); `first` reproduces the historical a:0-only pick.
- A capture that starts **mid-GOP** (video packets before the first IDR) is
  auto-trimmed to the first IDR before the build — announced on stdout, never
  silent (`trim-to-idr.sh` under the hood: boundary proven closed via
  gop-probe, both tracks cut together, kept region byte-identical, output
  gated at 0 pre-keyframe packets; the temp intermediate is deleted after a
  verified DONE and kept+named otherwise). The pre-roll is undecodable by any
  player, so the trim loses nothing. Pass `--no-idr-trim` to keep the head —
  expect an A/V-parity REVIEW then, because ffmpeg's streamcopy silently drops
  the video pre-roll while the audio pre-roll survives. The `MOV_SUMMARY`
  machine line records the outcome: `idr_trim=none|<N>|skipped|failed`.
- Field-coded (PAFF) input is auto-routed to the right timeline repair by its
  timestamp profile: pair-timestamped/reordered streams get the pair-mate PTS
  fill (real PTS kept, original audio preserved bit-exact in the dual-track);
  only a no-reorder stream gets the elementary rebuild (original audio not
  bit-exact preserved on that path — the script says so).
- A copy mux whose log confesses invented timing (`pts has no value` /
  `Timestamps are unset`) is a hard stop — the script refuses to bless the
  output and points at `diagnose.sh`. Relay that verbatim; never ship the file.
- **4:2:2 contribution profiles are built and PROVEN, not refused (1.11)** — a
  `yuv422p*` source (any bit depth: MPEG-2 4:2:2, H.264 Hi422/AVC-Intra, HEVC
  Rext) prints an advisory (`contribution profile <codec>/<pix_fmt> —
  playability will be verified post-build`), builds losslessly, then the
  finished output is tested with `playable-check.sh` and the machine line
  `MOV_PLAYABILITY os=… verdict=ok|fail|skip` is emitted. Verdict `fail` →
  exit 10 REVIEW naming the Rung-4 route (the file is still a verified
  lossless master); no macOS/qlmanage → exit 10 REVIEW, "playability
  unverified on this platform". (The old categorical refusal was falsified on
  macOS 26.6.1, 2026-08-13 — decode support drifts by macOS version, so the
  answer is per-file and empirical.)
- **Unroutable codecs are refused pre-flight with routes (1.11, WO 5.2)** —
  VC-1, VP9 or AV1 video (no MOV carriage exists — VP9 bench-verified
  un-muxable) and Dolby E audio (broadcast mezzanine; PCM-treating it yields
  full-scale noise) exit `11` with `MOV_REFUSED profile=unroutable-vcodec` /
  `profile=dolby-e-audio`, one honest message each, and nothing written. The
  gate holds at every scripted entry point (`mov.sh`, `auto.sh`, `remux.sh`;
  `batch.sh` records the class REFUSED, never FAIL — 1.11 fix round). Relay
  the routes verbatim: keep the source / lossless `-c copy` to MP4 (VP9/AV1)
  or MKV (VC-1) for playback / `rung4.sh` for QuickTime-native; for Dolby E
  the specialist decode (ffmpeg's `dolby_e` decoder → WAV) is an
  **operator-invoked** step — program/channel choice is editorial, never run
  it on your own — or exclude the track via `--audio-keep`.
- **Backhaul timeline rot is warned + built, not refused (1.11)** — mpegts/
  MPEG-2 sources with forward timestamp gaps **plus** non-monotonic DTS print
  a pre-build `** WARN: BACKHAUL TIMELINE ROT` (with the machine line
  `MOV_ROT_WARN`) carrying the same three honest routes the old refusal
  printed: keep the source (it is the archival master — prove its health with
  `ts-health.sh`), a lossless MKV playback copy (IINA/VLC/mpv; health-check
  the copy too), or the operator-attested `rung4.sh` re-encode. Then the
  build runs and the *measured* gates judge it: the mux-confession hard stop
  refuses invented timing, and `verify.sh` decides OK/REVIEW/FAIL with
  evidence. Gaps alone never warn. The warn holds at **every** entry point
  that writes a `.mov` (`mov.sh`, `auto.sh`, `batch.sh`, `remux.sh`,
  `dual-track.sh`, the PAFF builders) — since 1.11 no side door refuses
  *either* backhaul arm, and none skips the warning.

- **Named limitations** (33-bit PTS wrap past ~53 h, multi-program TS video
  winner, mid-stream resolution change, caption carriage, Dolby E hiding inside
  a "PCM" track) are written down, dated and command-backed, in
  `skills/remuxing-to-mov/references/known-limits.md` — check there before
  calling something a bug or improvising a workaround.

## Report back

Use the exit code: `0` = DONE (verified lossless), `10` = REVIEW (written, wants a
closer look — including a 4:2:2 build whose post-build playability check
FAILed or could not run on this platform), `1` = FAIL (nothing trustworthy
produced), `11` = REFUSED (since 1.11 neither backhaul arm refuses — the only
refusals `mov.sh` itself issues are the unroutable codecs above, `MOV_REFUSED
profile=unroutable-vcodec|dolby-e-audio`; an 11 can also propagate from a
child's own refusal, e.g. `resync.sh`'s mid-stream
layout guard). On REVIEW/FAIL, relay the
script's stated reason (for a playability-check REVIEW, relay the
`MOV_PLAYABILITY` verdict and that the file is still a verified lossless
master). When the timeline-rot warning fired (`MOV_ROT_WARN`), relay the
warning **and its three routes verbatim** alongside the build's verdict; on
any `11`, relay the child's refusal reason verbatim. Never ship past a FAIL,
never hand-roll an ffmpeg workaround, and never
invoke `--force-backhaul` or `rung4.sh` unless the operator explicitly asks —
the scan-skip and the re-encode are human decisions. **Never** re-encode to force a pass — a scoped re-encode
(Rung 4) is a human decision, and its **sole sanctioned route** is
`skills/remuxing-to-mov/scripts/rung4.sh`, which refuses to run without the
operator's verbatim attestation. Never hand-roll a re-encode around it; the
attestation phrase must come from the operator, never from you.
