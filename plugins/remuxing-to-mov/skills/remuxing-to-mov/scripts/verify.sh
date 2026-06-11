#!/usr/bin/env bash
# verify.sh — prove a remux was lossless and the output timeline is clean,
# at the lowest cost that is actually conclusive.
# Usage: scripts/verify.sh SOURCE OUTPUT [--full]
#
# Default tier (NO full decode — I/O-bound, runs at many× realtime):
#   (a) packet-hash identity: -c copy -f streamhash on both files (demux only,
#       zero decode). A match PROVES the copied bitstream is identical — done.
#       A mismatch is INCONCLUSIVE, not a failure: TS sources get SPS/PPS
#       re-placed and Rung-3 rebuilds repacketize, so identical video can hash
#       differently at the packet level. Fall through to (b).
#   (b) decoded spot-identity: framemd5 of the first 300 frames (hash column
#       only — timestamp-agnostic, survives re-timing) + video packet-count
#       parity. Catches wrong-stream, corruption-at-head, truncation.
#   (c) decode spot-checks of the OUTPUT at middle + tail (10 s windows).
#   (d) backward-DTS recheck on the output (want 0).
#
# --full adds the whole-file decoded-pixel identity check (two complete
# decodes; costs roughly the video's runtime in CPU). Reserve it for archival
# sign-off, or to settle a REVIEW verdict from the default tier.
set -euo pipefail
SRC="${1:?usage: verify.sh SOURCE OUTPUT [--full]}"; OUT="${2:?need OUTPUT}"
FULL=0; [ "${3:-}" = "--full" ] && FULL=1
for f in "$SRC" "$OUT"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done

N=300            # frames in the decoded head sample (~10-12 s of video)
WIN=10           # seconds per output decode spot-check window
verdict=PASS     # PASS | REVIEW | FAIL — only ever downgraded
note=""

echo "== verify: $OUT vs $SRC =="

echo "-- (a) packet-hash identity (demux only, no decode) --"
phash () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true; }
sp=$(phash "$SRC"); op=$(phash "$OUT")
if [ -n "$sp" ] && [ "$sp" = "$op" ]; then
  echo "   PASS: video packets bit-identical — lossless proven, no decode needed."
  bitproven=1
else
  echo "   inconclusive (expected for TS sources / Rung-3 rebuilds: packets get"
  echo "   re-framed even when the video is identical) — checking decoded frames."
  bitproven=0
fi

if [ "$bitproven" -eq 0 ]; then
  echo "-- (b) decoded spot-identity: first $N frames + packet-count parity --"
  fhead () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -frames:v "$N" -f framemd5 - 2>/dev/null \
               | grep -v '^#' | awk -F', *' '{print $NF}' || true; }
  sh=$(fhead "$SRC"); oh=$(fhead "$OUT")
  if [ -n "$sh" ] && [ "$sh" = "$oh" ]; then
    echo "   head sample: MATCH ($N decoded frames identical)"
  else
    echo "   head sample: FAIL — decoded frames differ; output is NOT a lossless copy."
    verdict=FAIL
  fi
  # TS sources list the stream under its program AND top-level -> dedupe to one line
  pkts () { ffprobe -v error -select_streams v:0 -count_packets \
              -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1; }
  spk=$(pkts "$SRC"); opk=$(pkts "$OUT")
  echo "   video packets: source=$spk output=$opk"
  if [ "$spk" != "$opk" ] && [ "$verdict" = PASS ]; then
    verdict=REVIEW
    note="packet counts differ — fine after a Rung-3 rebuild (repacketization), otherwise possible truncation. Settle with --full."
  fi
fi

echo "-- (c) output decode spot-checks (${WIN}s windows) --"
dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null) || dur=0
case "$dur" in ''|N/A) dur=0;; esac
spot () { ffmpeg -nostdin -v error -ss "$1" -t "$WIN" -i "$OUT" -map 0:v:0 -map '0:a?' \
            -f null - 2>&1 | grep -c . || true; }
if awk "BEGIN{exit !($dur < 4*$WIN)}"; then
  errs=$(ffmpeg -nostdin -v error -i "$OUT" -map 0:v:0 -map '0:a?' -f null - 2>&1 | grep -c . || true)
  echo "   short file — full output decode: $errs errors (want 0)"
else
  mid=$(awk "BEGIN{printf \"%.2f\", $dur/2}")
  tail=$(awk "BEGIN{printf \"%.2f\", $dur-$WIN-2}")
  em=$(spot "$mid"); et=$(spot "$tail")
  echo "   middle @${mid}s: $em errors; tail @${tail}s: $et errors (want 0)"
  errs=$((em + et))
fi
[ "$errs" -eq 0 ] || { [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Output decode errors in spot windows."; }

echo "-- (d) backward-DTS on output --"
back=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#3000" \
  -show_entries packet=dts -of csv=p=0 "$OUT" 2>/dev/null | \
  awk -F, 'NR>1 && $1!="N/A" && p!="N/A" && $1<p {b++} {p=$1} END{print b+0}')
echo "   backward-DTS: ${back:-0} (want 0)"
[ "${back:-0}" -eq 0 ] || { [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Non-monotonic DTS on output."; }

if [ "$FULL" -eq 1 ]; then
  echo "-- (--full) whole-file decoded-pixel identity (two full decodes) --"
  fmd5 () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c:v rawvideo -f md5 - | sed 's/^MD5=//'; }
  s=$(fmd5 "$SRC"); d=$(fmd5 "$OUT")
  echo "   source=$s"
  echo "   output=$d"
  if [ "$s" = "$d" ]; then
    echo "   PASS: every decoded frame is bit-identical."
    [ "$verdict" = REVIEW ] && { verdict=PASS; note=""; }   # definitive check overrides sampled doubt
  else
    echo "   FAIL: decoded frames differ — output is NOT a lossless copy."
    verdict=FAIL
  fi
fi

case "$verdict" in
  PASS)
    if [ "$bitproven" -eq 1 ] || [ "$FULL" -eq 1 ]; then echo ">> OK (lossless proven)"
    else echo ">> OK (sampled checks; for archival sign-off run again with --full)"; fi ;;
  REVIEW) echo ">> REVIEW: $note" ;;
  FAIL)   echo ">> FAIL (see above)"; exit 1 ;;
esac
