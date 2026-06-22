#!/usr/bin/env bash
# mov.sh — the "/mov" shortcut: one call from any capture to a QuickTime-ready
# .mov, lossless-first. Probe -> build the right thing -> verify -> report.
# Video is ALWAYS stream-copied (bit-identical); this never re-encodes video and
# never touches or deletes the source.
#
# Usage: scripts/mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full]
#   OUTPUT         default: <input dir>/<input base>.mov
#                  (<base>.qt.mov if the input is itself a .mov, so the source is safe)
#   --always-dual  build the dual-track even when the source audio already plays in
#                  QuickTime (the plugin's "always dual-track" default deliverable)
#   --full         archival sign-off: pass --full to verify.sh (whole-file decode)
#
# AUDIO POLICY — dual-track only when needed (classified by QuickTime PLAYABILITY,
# not by whether the codec merely muxes into MOV):
#   QuickTime-native (AAC / ALAC / MP3 / PCM)        -> copied as-is, single track
#   not native but MOV-copyable (AC-3/E-AC-3/DTS/MP2)-> DUAL-TRACK: PCM "access"
#                                                       track 1 (always plays) +
#                                                       original copied bit-exact track 2
#   not native and not MOV-copyable (FLAC/Opus/TrueHD)-> single PCM access track;
#                                                       original CANNOT be preserved in
#                                                       MOV (keep MKV/MP4 if you need it)
#   none                                             -> video-only copy
#
# Field-coded (PAFF) H.264 is routed to the timeline rebuild via auto.sh. That path
# decodes audio to PCM, so the bit-exact ORIGINAL is not preserved there; for
# dual-track on a PAFF source use the manual route (references/timeline-repair.md +
# references/dual-track-quicktime.md).
#
# Exit: 0 = verified OK; 10 = REVIEW (written, look closer); 1 = FAIL; 2 = usage.
set -euo pipefail

IN="${1:?usage: mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full]}"; shift
OUT=""; ALWAYS=0; FULL=""
# optional positional OUTPUT (the next arg, only if it isn't a --flag)
if [ "${1:-}" != "" ] && [ "${1#--}" = "${1:-}" ]; then OUT="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in
  --always-dual) ALWAYS=1; shift;;
  --full)        FULL="--full"; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# default output beside the source; never collide with the source name
if [ -z "$OUT" ]; then
  d="$(cd "$(dirname "$IN")" && pwd)"; b="$(basename "$IN")"; stem="${b%.*}"
  OUT="$d/$stem.mov"
  [ "$OUT" = "$d/$b" ] && OUT="$d/$stem.qt.mov"   # input already .mov -> don't target the source
fi

# probe once; consume the structured KEY=VAL (single source of truth). The grep
# whitelists PR_/PF_ lines so a stray line can never become code via eval.
eval "$(bash "$SELF_DIR/probe.sh" "$IN" --kv | grep -E '^(PR|PF)_[A-Z0-9_]+=')"
echo "== mov: $IN -> $OUT =="
echo "   video=$PR_VCODEC  audio=$PR_ACODEC  paff=$PF_PAFF"

# --- field-coded: hand the timeline rebuild to the tested ladder driver ---
if [ "$PF_PAFF" = yes ]; then
  echo "   field-coded (PAFF) -> timeline rebuild via auto.sh"
  echo "   note: that path decodes audio; the bit-exact ORIGINAL is not preserved."
  set +e; bash "$SELF_DIR/auto.sh" "$IN" "$OUT" $FULL; rc=$?; set -e
  exit "$rc"
fi

# --- classify audio by QuickTime playability (not by mux compatibility) ---
# MODE: copy (native) | dual (preserve original as track 2) | pcm (can't preserve in MOV) | none
case "$PR_ACODEC" in
  none)                      MODE=none ;;
  aac|alac|mp3|pcm_*)        MODE=copy ;;                 # plays natively in QuickTime
  ac3|eac3|dts|dca|mp2|mp1)  MODE=dual ;;                 # not native, but copyable into MOV -> keep original
  *)                         MODE=pcm  ;;                 # flac/opus/truehd/...: original not MOV-copyable
esac
[ "$ALWAYS" -eq 1 ] && [ "$MODE" = copy ] && MODE=dual    # --always-dual upgrades native -> dual

AUDV=""
case "$MODE" in
  dual)
    echo "-- audio $PR_ACODEC not QuickTime-native -> dual-track (PCM access + original preserved) --"
    bash "$SELF_DIR/dual-track.sh" "$IN" "$OUT"; AUDV="--audio" ;;
  pcm)
    echo "-- audio $PR_ACODEC can't be preserved in MOV -> single PCM access track --"
    echo "   (to keep the original bitstream, deliver as MP4/MKV instead; see references/ingest-compatibility.md)"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio pcm ;;
  copy|none)
    echo "-- audio ${PR_ACODEC} is QuickTime-native or absent -> pure copy --"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio copy ;;
esac

# signaling check only when the source actually carries color/HDR tags
SIG=""; { [ -n "${PR_COLOR_PRIMARIES:-}" ] && [ "${PR_COLOR_PRIMARIES:-unknown}" != unknown ]; } && SIG="--signaling"

echo "-- verify --"
set +e
o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL $AUDV $SIG 2>&1); rc=$?
set -e
printf '%s\n' "$o" | sed 's/^/   /'

echo
echo "MOV_SUMMARY mode=$MODE out=$OUT"          # machine-readable
case "$o" in
  *">> OK"*)     echo ">> DONE: $OUT — QuickTime-ready, verified lossless${AUDV:+ + dual-track aligned}."; exit 0 ;;
  *">> REVIEW"*) echo ">> REVIEW: $OUT written; verify wants a closer look (above). Source untouched."; exit 10 ;;
  *)             echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac
