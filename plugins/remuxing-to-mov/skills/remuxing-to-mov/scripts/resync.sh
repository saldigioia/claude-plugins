#!/usr/bin/env bash
# resync.sh — fix a DISCONTINUOUS-source desync while keeping the VIDEO bit-identical.
# For captures whose source dropped frames (forward timestamp gaps): a blind `-c copy`
# preserves those gaps in the video timeline but COLLAPSES them in raw PCM audio
# (MOV/MP4 PCM is a contiguous sample array with no gap mechanism), sliding audio
# progressively out of sync — the remux-sync post-mortem. This re-times the audio to
# the picture by filling the gaps, and never re-encodes the video.
#
# Usage: scripts/resync.sh INPUT OUTPUT.mov [--all-audio] [--audio a:N] [--pcm 16|24|32]
#   --all-audio  re-time every audio track (default: a:0 only)
#   --audio a:N  re-time a specific track
#   --pcm        PCM bit depth for the re-timed audio (default 24)
#
# What it does (the corrected procedure from the post-mortem):
#   video : -c:v copy  -> BIT-IDENTICAL (HEVC tagged hvc1); never re-encoded
#   audio : -af aresample=async=1:first_pts=0 -> PCM; silence inserted at each gap
#           so the audio stays pinned to the picture timeline
#   +faststart; atomic .part -> mv; the SOURCE is never touched.
#
# TRADE-OFF (explicit, by design — this is why it is a separate, human-invoked tool
# and not part of the lossless ladder): the audio is RE-TIMED, not a bit-exact copy.
# Video stays lossless. If you also need the bit-exact ORIGINAL audio, the only
# frame-accurate fix is a re-mux from the still-existing source — see the post-mortem
# and references/timeline-repair.md. Lossy tracks (AC-3/DTS/MP2) are rendered to PCM.
#
# Exit: 0 = resynced + sync-verified; 10 = REVIEW; 1 = FAIL; 2 = usage.
set -euo pipefail
IN="${1:?usage: resync.sh INPUT OUTPUT.mov [--all-audio] [--audio a:N] [--pcm 16|24|32]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
AMAP="-map 0:a:0?"; PCM=pcm_s24le
while [ $# -gt 0 ]; do case "$1" in
  --all-audio) AMAP="-map 0:a?"; shift;;
  --audio)     AMAP="-map 0:${2:?--audio needs a:N}"; shift 2;;
  --pcm) case "${2:-}" in 16) PCM=pcm_s16le;; 24) PCM=pcm_s24le;; 32) PCM=pcm_s32le;; *) echo "bad --pcm: ${2:-}" >&2; exit 2;; esac; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"
cp=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

echo "== resync: $IN -> $OUT =="
echo "   video=$vcodec -> -c:v copy (bit-identical); audio -> $PCM, gaps filled (aresample async)"

PART="${OUT}.part"
# shellcheck disable=SC2086
ffmpeg -nostdin -v error -fflags +genpts -i "$IN" \
  -map 0:v:0 -c:v copy $VTAG \
  $AMAP -af "aresample=async=1:first_pts=0" -c:a "$PCM" \
  -movflags "$MOVFLAGS" -f mov "$PART"
mv -f "$PART" "$OUT"
echo "   wrote: $OUT"

echo "-- verify (sync + lossless video) --"
set +e
o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" 2>&1); set -e
printf '%s\n' "$o" | sed 's/^/   /'
case "$o" in
  *">> OK"*)     echo ">> DONE: $OUT — video bit-identical, audio re-timed to the picture."; exit 0 ;;
  *">> REVIEW"*) echo ">> REVIEW: $OUT written; see the sync/parity note above (a tail residual can remain — confirm against the source)."; exit 10 ;;
  *)             echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac
