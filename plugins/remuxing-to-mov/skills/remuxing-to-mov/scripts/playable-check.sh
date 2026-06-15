#!/usr/bin/env bash
# playable-check.sh — OPTIONAL macOS-only probe of the "playable" half of
# "playable != valid": can QuickTime/AVFoundation actually open and DECODE this
# file? ffmpeg can't answer that. No-op on non-macOS so it's safe in any pipeline.
#
# Usage: scripts/playable-check.sh OUTPUT.mov
# Exit:  0 = AVFoundation rendered a frame (video is QuickTime-playable)
#        1 = it could not (e.g. 4:2:2 MPEG-2, untagged HEVC) -> Rung 4 territory
#        3 = skipped (not macOS, or no qlmanage) — confirm on the target Mac
#
# METHOD: ask QuickLook (which uses AVFoundation, the same stack QuickTime Player
# uses) to render a thumbnail. A produced image means the system decoded a real
# frame. NOTE: this proves VIDEO decode/open only; audio playability (AC-3/E-AC-3/
# DTS) is not covered — listen once if it matters.
#
# NOTE: the macOS path cannot be exercised on Linux/CI; validate on a real Mac.
set -euo pipefail
OUT="${1:?usage: playable-check.sh OUTPUT.mov}"
[ -f "$OUT" ] || { echo "no such file: $OUT" >&2; exit 2; }

if [ "$(uname -s)" != Darwin ]; then
  echo "playable-check: SKIP — not macOS; AVFoundation/QuickTime unavailable. Confirm on the target Mac."
  exit 3
fi
command -v qlmanage >/dev/null 2>&1 || { echo "playable-check: SKIP — qlmanage not found."; exit 3; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
qlmanage -t -s 480 -o "$TMP" "$OUT" >/dev/null 2>&1 || true
if ls "$TMP"/*.png >/dev/null 2>&1; then
  echo "playable-check: OK — AVFoundation rendered a frame; QuickTime can open the video."
  echo "  (audio playability for AC-3/E-AC-3/DTS is NOT proven by a thumbnail — listen if it matters.)"
  exit 0
else
  echo "playable-check: FAIL — AVFoundation produced no frame; QuickTime likely can't decode this"
  echo "  (e.g. 4:2:2 MPEG-2 or an untagged codec). A playable deliverable needs Rung 4 — see references/delivery-encode.md."
  exit 1
fi
