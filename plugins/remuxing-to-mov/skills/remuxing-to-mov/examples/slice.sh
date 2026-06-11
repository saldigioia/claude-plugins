#!/usr/bin/env bash
# slice.sh — lossless keyframe-bound scene slices (remuxing-to-mov skill, Rung 0/1).
# Video: always -c:v copy (bit-identical). Audio per-task. Atomic .part -> mv.
set -euo pipefail

B="/Volumes/Extreme Pro/Saturday Night Live [Music]/Full Episode/Broadcast-FEED"

# slice IN OUT START END AUDIO_OPTS...
slice () {
  local IN="$1" OUT="$2" START="$3" END="$4"; shift 4
  local AOPT=("$@")
  [ -f "$IN" ] || { echo "no such input: $IN" >&2; exit 2; }
  local dur; dur=$(awk "BEGIN{printf \"%.3f\", $END-$START}")
  echo ">> $OUT  (START=$START END=$END dur=${dur}s)"
  local PART="${OUT}.part"
  ffmpeg -nostdin -y -ss "$START" -to "$END" -i "$IN" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy "${AOPT[@]}" \
    -avoid_negative_ts make_zero -movflags +faststart -f mov \
    "$PART"
  mv -f "$PART" "$OUT"
  echo "   wrote: $OUT"
}

# Task 1 — H.264 + DTS -> PCM
slice "$B/[S43E06] Chance The Rapper + Eminem [2017-11-18]/feed.mov" \
      "/Users/salvatore/downloads/[S43E06] Eminem [2017-11-18]/01.mov" \
      1683.148000 2225.423000 -c:a pcm_s16le

# Task 2 — H.264 + DTS -> PCM
slice "$B/[S41E20] Drake [2016-05-14]/feed.mov" \
      "/Users/salvatore/downloads/[S41E20] Drake [2016-05-14]/01.mov" \
      1792.490589 1993.257800 -c:a pcm_s16le
slice "$B/[S41E20] Drake [2016-05-14]/feed.mov" \
      "/Users/salvatore/downloads/[S41E20] Drake [2016-05-14]/02.mov" \
      3427.490533 3619.448967 -c:a pcm_s16le

# Task 3 — MPEG-2 + AC-3 (copy)
slice "$B/[S39E11] Drake [2014-01-18]/feed.mov" \
      "/Users/salvatore/downloads/[S39E11] Drake [2014-01-18]/01.mov" \
      1823.388233 2029.660967 -c:a copy
slice "$B/[S39E11] Drake [2014-01-18]/feed.mov" \
      "/Users/salvatore/downloads/[S39E11] Drake [2014-01-18]/02.mov" \
      3227.924700 3536.666467 -c:a copy

echo "ALL DONE"
