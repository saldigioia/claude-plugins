#!/usr/bin/env bash
# rebuild-paff.sh — Rung 3: rebuild a broken timeline from the elementary stream.
# For field-coded (PAFF) H.264 whose container timing is too broken for genpts.
# Video stays BIT-IDENTICAL; only the access-unit structure + timestamps are re-derived.
#
# Usage: scripts/rebuild-paff.sh INPUT OUTPUT.mov FIELD_RATE [TIMESCALE]
#   FIELD_RATE examples (each field-picture is one AU at the field rate):
#     1080i59.94 -> 60000/1001     1080i50 -> 50
#     720p59.94  -> 60000/1001     29.97p  -> 30000/1001   23.976p -> 24000/1001
#   TIMESCALE defaults to a clean whole value derived from common rates.
#
# Safety: set -e gates every step; intermediates go in a temp dir and are kept on
# failure for inspection; output is written atomically. The SOURCE is never touched.
set -euo pipefail
IN="${1:?usage: rebuild-paff.sh INPUT OUTPUT.mov FIELD_RATE [TIMESCALE]}"
OUT="${2:?need OUTPUT.mov}"; RATE="${3:?need FIELD_RATE e.g. 60000/1001}"; TS="${4:-}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }

# default timescale from the rate if not given
if [ -z "$TS" ]; then case "$RATE" in
  60000/1001|60) TS=60000;; 50) TS=50000;; 30000/1001|30) TS=30000;;
  24000/1001|24) TS=24000;; 25) TS=25000;; *) TS=60000;; esac
fi

WORK="$(mktemp -d)"   # NOT auto-deleted, so a failed run leaves intermediates to inspect
echo "work dir (inspect on failure): $WORK"

# 1) video -> raw Annex-B H.264. TS/PS already Annex-B; AVCC (MKV/MOV) needs the bsf.
isavc=$(ffprobe -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
BSF=""; [ "$isavc" = true ] && BSF="-bsf:v h264_mp4toannexb"
# shellcheck disable=SC2086
ffmpeg -nostdin -y -i "$IN" -map 0:v:0 -c:v copy $BSF -f h264 "$WORK/v.h264"

# 2) audio -> PCM/WAV per track (starts at sample 0, stays aligned; a single-track
#    rebuild would silently drop SAP/secondary audio)
# sort -u: TS program duplication can list the same stream twice (see ingest-compatibility.md)
NA=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | grep . | sort -u | wc -l | tr -d ' ')
AIN=(); AMAP=(); AMETA=()
i=0
while [ "$i" -lt "$NA" ]; do
  ffmpeg -nostdin -y -i "$IN" -map "0:a:$i" -c:a pcm_s16le "$WORK/a$i.wav"
  AIN+=(-i "$WORK/a$i.wav"); AMAP+=(-map "$((i+1)):0")
  # PRESERVE the real per-track language; default to eng only if the source has
  # none (PS/.mpg carry none). Hard-coding eng would silently relabel FR/ES/commentary.
  lang=$(ffprobe -v error -select_streams "a:$i" -show_entries stream_tags=language -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  case "$lang" in ""|und|unknown) lang=eng;; esac
  AMETA+=("-metadata:s:a:$i" "language=$lang")
  i=$((i+1))
done
[ "$NA" -gt 0 ] || echo "note: no audio streams found; rebuilding video only"

# 3) rebuild from zero at the field rate
cp=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"
PART="${OUT}.part"
# ${arr[@]+...} expansions keep bash 3.2 (macOS default) happy under set -u with empty arrays
ffmpeg -nostdin -y -fflags +genpts -r "$RATE" -i "$WORK/v.h264" ${AIN[@]+"${AIN[@]}"} \
  -map 0:0 ${AMAP[@]+"${AMAP[@]}"} -c:v copy -c:a pcm_s16le \
  ${AMETA[@]+"${AMETA[@]}"} \
  -video_track_timescale "$TS" \
  -movflags "$MOVFLAGS" -f mov \
  "$PART"
mv -f "$PART" "$OUT"

echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""
echo "if verify passes, remove intermediates by hand: rm -rf \"$WORK\""
