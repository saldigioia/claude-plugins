#!/usr/bin/env bash
# seam-check.sh — verify a concatenated/cut .mov at its JOIN(s) for the open-GOP
# seam glitch: a one-frame garbage flash manufactured when a segment that started
# on an OPEN-GOP boundary is decoded after another segment (see gop-probe.sh and
# references/cutting-concat.md). Run after any copy-cut concat.
#
# Usage: scripts/seam-check.sh JOINED.mov SEAM[,SEAM...] [--png DIR] [--win S] [--thresh F]
#   SEAM       seam time(s) in seconds (e.g. the duration of the first segment).
#              Comma- or space-separate multiple joins.
#   --png DIR  keep the seam-straddling frames as PNGs for the eyeball test.
#   --win S    half-window decoded each side of the seam (default 1.0).
#   --thresh F scene-change threshold 0..1 to consider a frame a candidate (default 0.40).
#
# Method (notes §3b + §3c): for each seam we decode CONTINUOUSLY from a keyframe
# BEFORE the seam through it — never seeking onto the seam, which hides the
# artifact — and:
#   (b) count decode errors in the window (broken refs / bad timestamps);
#   (c) find the biggest scene change; if that frame is an OUTLIER — the frames
#       just before and after it match each other far better than either matches
#       it (content resumed across a one-frame spike) — it's a FLASH. A legitimate
#       hard cut instead changes content and STAYS changed, so before!=after.
# A real player/eyeball is still the final arbiter (a glitch can be valid bitstream).
# Exit: 0 = clean; 1 = decode errors or a flash detected at a seam.
set -euo pipefail
JOINED="${1:?usage: seam-check.sh JOINED.mov SEAM[,SEAM...] [--png DIR] [--win S] [--thresh F]}"; shift
SEAMS=""; PNGDIR=""; WIN=1.0; THRESH=0.40; DELTA=5
while [ $# -gt 0 ]; do case "$1" in
  --png) PNGDIR="${2:?--png needs a dir}"; shift 2;;
  --win) WIN="${2:?}"; shift 2;;
  --thresh) THRESH="${2:?}"; shift 2;;
  -*) echo "unknown opt: $1" >&2; exit 2;;
  *) SEAMS="$SEAMS ${1//,/ }"; shift;;
esac; done
[ -f "$JOINED" ] || { echo "no such file: $JOINED" >&2; exit 2; }
[ -n "${SEAMS// /}" ] || { echo "need at least one SEAM time" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
psnr () { # average PSNR(dB) between two PNG frames; "inf" (identical) -> 99
  local v; v=$( { ffmpeg -nostdin -hide_banner -i "$1" -i "$2" -lavfi psnr -f null - 2>&1 \
        | sed -n 's/.*average:\([0-9a-z.]*\).*/\1/p' | head -1; } || true)
  case "$v" in inf|"") echo 99;; *) echo "$v";; esac; }

bad=0
echo "== seam-check: $JOINED =="
for S in $SEAMS; do
  start=$(awk "BEGIN{s=$S-$WIN; printf \"%.3f\", (s<0?0:s)}")
  span=$(awk "BEGIN{printf \"%.3f\", 2*$WIN}")
  dir="$WORK/seam"; [ -z "$PNGDIR" ] || { mkdir -p "$PNGDIR/seam_${S}"; dir="$PNGDIR/seam_${S}"; }
  rm -f "$dir"/*.png 2>/dev/null || true; mkdir -p "$dir"
  echo "-- seam @ ${S}s  (decoding ${start}s +${span}s continuously) --"

  # (b) decode-scan the window for broken references / timestamp errors
  errs=$(ffmpeg -nostdin -v error -ss "$start" -i "$JOINED" -t "$span" -map 0:v:0 -f null - 2>&1 | grep -c . || true)
  echo "   decode errors in window: $errs (want 0)"
  [ "${errs:-0}" -gt 0 ] && bad=1

  # one pass: extract straddling frames (eyeball test) + per-frame scene scores
  ffmpeg -nostdin -v error -ss "$start" -i "$JOINED" -t "$span" \
    -vf "select='gte(scene,0)',metadata=print:file=$WORK/sc.txt" -vsync passthrough "$dir/%04d.png" 2>/dev/null || true
  read -r pi pts ps < <(awk '/pts_time:/{for(i=1;i<=NF;i++) if($i ~ /^pts_time:/){split($i,a,":"); t=a[2]}}
                              /scene_score=/{n++; split($0,b,"="); s=b[2]+0; if(s>ms){ms=s;mi=n;mt=t}}
                              END{print mi+0, mt+0, ms+0}' "$WORK/sc.txt" 2>/dev/null)
  ptsabs=$(awk "BEGIN{printf \"%.2f\", $start + ${pts:-0}}")
  if [ "${ps:-0}" = 0 ] || awk "BEGIN{exit !((${ps:-0})<($THRESH))}"; then
    echo "   no significant frame change in window (peak scene score ${ps:-0} < $THRESH)."
  else
    A=$(printf '%s/%04d.png' "$dir" $((pi-1))); G=$(printf '%s/%04d.png' "$dir" "$pi"); C=$(printf '%s/%04d.png' "$dir" $((pi+1)))
    if [ -f "$A" ] && [ -f "$C" ]; then
      ba=$(psnr "$A" "$C"); bg=$(psnr "$A" "$G")
      echo "   peak change @ ~${ptsabs}s (scene=$ps): PSNR before~after=${ba}dB  before~peak=${bg}dB"
      if awk "BEGIN{exit !(($ba-$bg) > $DELTA)}"; then
        echo "   FLASH: that frame is an outlier — content resumes across it. Open-GOP"
        echo "          garbage frame at the seam. Re-cut on a CLOSED-GOP keyframe."
        bad=1
      else
        echo "   looks like an intended/sustained cut (content stays changed), not a flash."
      fi
    else
      echo "   peak change @ ~${pts}s (scene=$ps) — inspect the frames by eye."
    fi
  fi
  [ -z "$PNGDIR" ] || echo "   eyeball: PNGs in $PNGDIR/seam_${S}/ (last frame of A -> first of B)"
done

echo
if [ "$bad" -eq 0 ]; then
  echo ">> SEAMS CLEAN (decode-clean, no flash signature). For archival sign-off,"
  echo "   still eyeball the seam frames — a glitch can be valid bitstream."
  exit 0
else
  echo ">> SEAM PROBLEM: re-cut the segment to start on a CLOSED-GOP keyframe"
  echo "   (scripts/gop-probe.sh INPUT CUT_TIME), or smart-cut the boundary GOP."
  exit 1
fi
