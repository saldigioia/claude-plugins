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
# FLOOR, NOT SIGN-OFF (post-mortem 2026-07-25): a thumbnail proves ONE frame
# decodes; it says NOTHING about the presentation timeline. A file with a
# muxer-invented timeline renders a thumbnail and is unwatchable in real
# playback. Sign-off for a suspect timeline = verify.sh's full gate set
# (timeline scan, scrub gate, A/V parity) — this check is only the last-mile
# "QuickTime can open it" floor on top of that.
#
# NOTE: the macOS path cannot be exercised on Linux/CI; validate on a real Mac.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 3 10 11" # + this script's documented 3 (SKIP: not macOS / no qlmanage; suite-pinned)
OUT="${1:?usage: playable-check.sh OUTPUT.mov}"
[ -f "$OUT" ] || { echo "no such file: $OUT" >&2; exit 2; }

if [ "$(uname -s)" != Darwin ]; then
  echo "playable-check: SKIP — not macOS; AVFoundation/QuickTime unavailable. Confirm on the target Mac."
  exit 3
fi
command -v qlmanage >/dev/null 2>&1 || { echo "playable-check: SKIP — qlmanage not found."; exit 3; }
# QTFF audit 5-1c (C63): the verdict is a property of the OS it ran on — decode
# support drifts across macOS versions (Tahoe 26.4 dropped MJPEG variants/AIC),
# so every recorded check self-dates its OS. Annotation only; no logic change.
OSV=$(sw_vers -productVersion 2>/dev/null || echo '?')

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# BOUNDED probe (WO 1.4, measured): qlmanage -t can hang FOREVER on input the
# thumbnail extension cannot parse (a garbage payload stalled it indefinitely —
# no verdict, no exit code, a wedged pipeline). A hung probe is not a verdict,
# so the render gets a deadline (RTM_QL_TIMEOUT seconds, default 60 — a healthy
# file thumbnails in single-digit seconds). macOS ships no `timeout` binary:
# background the render and poll with the deadline; on expiry the kill leaves
# no PNG, and the normal no-frame path below reports FAIL honestly.
qlmanage -t -s 480 -o "$TMP" "$OUT" >/dev/null 2>&1 &
QLPID=$!
QLLIMIT="${RTM_QL_TIMEOUT:-60}"
QLDEADLINE=$(( $(date +%s) + QLLIMIT ))
while kill -0 "$QLPID" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$QLDEADLINE" ]; then
    kill -9 "$QLPID" 2>/dev/null || true
    echo "playable-check: qlmanage produced nothing in ${QLLIMIT}s — killed (a hang here means"
    echo "  the decode stack cannot handle this input; counted as no frame rendered)."
    break
  fi
  sleep 1
done
wait "$QLPID" 2>/dev/null || true
if ls "$TMP"/*.png >/dev/null 2>&1; then
  echo "playable-check: OK on macOS $OSV — AVFoundation rendered a frame; QuickTime can open the video."
  echo "  (audio playability for AC-3/E-AC-3/DTS is NOT proven by a thumbnail — listen if it matters.)"
  echo "  (FLOOR only: one frame decoding proves nothing about the timeline — a broken"
  echo "   timeline still thumbnails. Sign-off = verify.sh's gates, then a real scrub.)"
  exit 0
else
  echo "playable-check: FAIL on macOS $OSV — AVFoundation produced no frame; QuickTime likely can't decode this"
  echo "  (e.g. 4:2:2 MPEG-2, an untagged codec, or a macOS-version codec drop — see"
  echo "  ingest-compatibility.md 'Decode support is a moving target'). A playable"
  echo "  deliverable needs Rung 4 (scripts/rung4.sh) — recipes in references/delivery-encode.md."
  exit 1
fi
