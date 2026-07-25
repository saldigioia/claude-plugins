#!/usr/bin/env bash
# rebuild-paff.sh — Rung 3: rebuild a broken timeline from the elementary stream.
# For field-coded (PAFF) H.264 whose container timing is too broken for genpts.
# Video stays BIT-IDENTICAL; only the access-unit structure + timestamps are re-derived.
#
# SCOPE LIMIT (post-mortem 2026-07-25): re-stamping at a constant rate sets
# PTS = DTS, i.e. presentation order = DECODE order. On a stream that carries a
# reorder pyramid (B-fields / B-frames: PTS-DTS offsets vary, backward PTS steps)
# that plays the pictures shuffled — a different way of being broken, and one the
# default verify tier CANNOT see (bits identical, decode clean, scrub clean).
# So this script now REFUSES a source whose surviving timestamps show reordering:
#   * real PTS survives (e.g. on the first field of each pair) -> use
#     scripts/pairfill-paff.sh, which keeps it;
#   * no timestamps survive at all -> reordering is undetectable and this rebuild
#     is the least-bad option; it proceeds with a warning — eyeball motion after.
# Override with --force only when you have proven decode order == display order.
#
# Usage: scripts/rebuild-paff.sh INPUT OUTPUT.mov FIELD_RATE [TIMESCALE] [--force]
#   FIELD_RATE examples (each field-picture is one AU at the field rate):
#     1080i59.94 -> 60000/1001     1080i50 -> 50
#     720p59.94  -> 60000/1001     29.97p  -> 30000/1001   23.976p -> 24000/1001
#   TIMESCALE defaults to a clean whole value derived from common rates.
#
# Safety: set -e gates every step; intermediates go in a temp dir and are kept on
# failure for inspection; output is written atomically. The SOURCE is never touched.
# Exit: 0 ok; 2 usage; 3 refused (reordered stream — wrong repair for this class).
set -euo pipefail
IN="${1:?usage: rebuild-paff.sh INPUT OUTPUT.mov FIELD_RATE [TIMESCALE] [--force]}"
OUT="${2:?need OUTPUT.mov}"; RATE="${3:?need FIELD_RATE e.g. 60000/1001}"; shift 3
TS=""; FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --force) FORCE=1; shift;;
  *) [ -n "$TS" ] && { echo "unknown opt: $1" >&2; exit 2; }; TS="$1"; shift;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"

# --- pre-flight: does the source carry presentation reordering this restamp would flatten? ---
eval "$(pf_reorder_scan "$IN")"
if [ "$PF_REORDER" = yes ] && [ "$FORCE" -ne 1 ]; then
  eval "$(pf_detect "$IN")"
  echo ">> REFUSING: the source's surviving timestamps show a reorder pyramid" >&2
  echo "   (pts!=dts on $PF_PTSNEDTS pkt(s), $PF_BACKPTS backward PTS step(s), max offset $PF_MAXOFF_TICKS ticks)." >&2
  echo "   A constant-rate restamp sets PTS=DTS and would play pictures in DECODE" >&2
  echo "   order — motion shuffled, and invisible to the default verify tier." >&2
  if [ "${PF_HALF_TS:-no}" = yes ]; then
    echo "   This stream is the half-timestamped pair class. The correct repair keeps" >&2
    echo "   every real PTS and fills the pair-mates:" >&2
    echo "     scripts/pairfill-paff.sh \"$IN\" \"$OUT\"" >&2
  else
    echo "   Real PTS survives — keep it (plain copy, or pairfill-paff.sh to clean the" >&2
    echo "   DTS ramp) instead of flattening it. --force overrides ONLY if you have" >&2
    echo "   proven decode order == display order." >&2
  fi
  exit 3
fi
if [ "$PF_REORDER" = yes ]; then
  echo "** --force: restamping a REORDERED stream at a constant rate — presentation"
  echo "** order will equal decode order. Prove motion is correct before shipping."
elif [ "${PF_TS_BOTH:-0}" -eq 0 ]; then
  echo "** no packet carries both PTS and DTS — reordering is undetectable from the"
  echo "** container. Proceeding (least-bad option); check motion by eye afterwards."
fi

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
# grep -c + || true: a NO-audio source must yield 0, not a pipefail abort
NA=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -u | grep -c . || true)
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
PART="${OUT}.part"; MUXLOG="$WORK/mux.log"
# ${arr[@]+...} expansions keep bash 3.2 (macOS default) happy under set -u with empty arrays
if ! ffmpeg -nostdin -y -hide_banner -nostats -fflags +genpts -r "$RATE" -i "$WORK/v.h264" ${AIN[@]+"${AIN[@]}"} \
    -map 0:0 ${AMAP[@]+"${AMAP[@]}"} -c:v copy -c:a pcm_s16le \
    ${AMETA[@]+"${AMETA[@]}"} \
    -video_track_timescale "$TS" \
    -movflags "$MOVFLAGS" -f mov \
    "$PART" 2>"$MUXLOG"; then
  echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8
  exit 1
fi
[ -s "$MUXLOG" ] && sed 's/^/   mux: /' "$MUXLOG" | tail -6
# NOTE on mux warnings: "Timestamps are unset" is EXPECTED here — this rung
# deliberately discards the container timestamps and re-derives timing from the
# imposed constant rate (raw-elementary packets carry durations only). The
# confession hard-stop applies to COPY muxes (remux.sh/dual-track.sh), where
# preserving source timing is the contract. For a deliberate restamp the proof
# is the OUTPUT timeline itself — gate it before blessing (post-mortem 2026-07-25):
EXPDUR=$(awk "BEGIN{n=split(\"$RATE\",r,\"/\"); rd=(n>1)?r[2]:1; printf \"%d\", $TS*rd/r[1]}")
eval "$(ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 "$PART" 2>/dev/null | \
  awk -F, -v e="$EXPDUR" 'NF{
      n++
      if($1=="N/A"||$1=="") nap++
      if($2=="N/A"||$2==""){ nad++ } else { d=$2+0; if(hav){ if(d<pd) back++; else if(d==pd) dup++ } pd=d; hav=1 }
      if($3!="N/A" && $3!="" && $3+0!=e) od++
    }
    END{ printf "RG_N=%d RG_NAPTS=%d RG_NADTS=%d RG_BACK=%d RG_DUP=%d RG_OFFDUR=%d\n", n+0, nap+0, nad+0, back+0, dup+0, od+0 }')"
echo "   output timeline: packets=$RG_N N/A=$RG_NAPTS/$RG_NADTS backward=$RG_BACK dup=$RG_DUP off-cadence-durations=$RG_OFFDUR (want 0/0/0/0/<=1 @ ${EXPDUR} ticks)"
if [ "${RG_NAPTS:-1}" -ne 0 ] || [ "${RG_NADTS:-1}" -ne 0 ] || [ "${RG_BACK:-1}" -ne 0 ] || [ "${RG_DUP:-1}" -ne 0 ] || [ "${RG_OFFDUR:-9}" -gt 1 ]; then
  echo ">> HARD STOP: the rebuilt timeline is not the clean constant-rate ramp this"
  echo "   rung promises. NOT blessing the output; kept at $PART (log: $MUXLOG)."
  exit 1
fi
mv -f "$PART" "$OUT"

echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""
echo "if verify passes, remove intermediates by hand: rm -rf \"$WORK\""
