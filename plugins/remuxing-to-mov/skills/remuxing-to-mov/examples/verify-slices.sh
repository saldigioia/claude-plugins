#!/usr/bin/env bash
# Verify each slice: lossless video (framemd5 hashes), clean decode, kf start, duration.
set -uo pipefail
B="/Volumes/Extreme Pro/Saturday Night Live [Music]/Full Episode/Broadcast-FEED"

verify () {
  local SRC="$1" OUT="$2" START="$3" END="$4"
  local want; want=$(awk "BEGIN{printf \"%.3f\", $END-$START}")
  echo "================================================================"
  echo "OUT: $OUT"
  [ -f "$OUT" ] || { echo "  MISSING"; return; }

  # (a) lossless video: per-frame decoded-content hashes, source-range vs output
  local s d sc dc
  s=$(ffmpeg -nostdin -v error -ss "$START" -to "$END" -i "$SRC" -map 0:v:0 -f framemd5 - \
        | grep -v '^#' | awk -F, '{print $NF}')
  d=$(ffmpeg -nostdin -v error -i "$OUT" -map 0:v:0 -f framemd5 - \
        | grep -v '^#' | awk -F, '{print $NF}')
  sc=$(printf '%s\n' "$s" | grep -c .); dc=$(printf '%s\n' "$d" | grep -c .)
  local sh dh; sh=$(printf '%s' "$s" | md5sum | cut -d' ' -f1); dh=$(printf '%s' "$d" | md5sum | cut -d' ' -f1)
  if [ "$sh" = "$dh" ]; then echo "  (a) video lossless: PASS  (frames=$dc, hash match)"
  else echo "  (a) video lossless: FAIL  src_frames=$sc out_frames=$dc"; echo "      src=$sh out=$dh"; fi

  # (b) clean decode of output (both streams) -> count errors
  local errs
  errs=$(ffmpeg -nostdin -v error -xerror -i "$OUT" -map 0 -f null - 2>&1 | grep -ci error || true)
  echo "  (b) decode errors: $errs (want 0)"

  # (c) first video packet keyframe + pts
  local first
  first=$(ffprobe -v error -select_streams v:0 -read_intervals "%+2" \
            -show_entries packet=pts_time,flags -of csv=p=0 "$OUT" 2>/dev/null | head -1)
  echo "  (c) first video pkt: $first  (want pts≈0, flag K)"

  # (d) duration
  local dur
  dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
  echo "  (d) duration: $dur  (want ≈ $want)"
}

verify "$B/[S43E06] Chance The Rapper + Eminem [2017-11-18]/feed.mov" \
       "/Users/salvatore/downloads/[S43E06] Eminem [2017-11-18]/01.mov" 1683.148000 2225.423000
verify "$B/[S41E20] Drake [2016-05-14]/feed.mov" \
       "/Users/salvatore/downloads/[S41E20] Drake [2016-05-14]/01.mov" 1792.490589 1993.257800
verify "$B/[S41E20] Drake [2016-05-14]/feed.mov" \
       "/Users/salvatore/downloads/[S41E20] Drake [2016-05-14]/02.mov" 3427.490533 3619.448967
verify "$B/[S39E11] Drake [2014-01-18]/feed.mov" \
       "/Users/salvatore/downloads/[S39E11] Drake [2014-01-18]/01.mov" 1823.388233 2029.660967
verify "$B/[S39E11] Drake [2014-01-18]/feed.mov" \
       "/Users/salvatore/downloads/[S39E11] Drake [2014-01-18]/02.mov" 3227.924700 3536.666467
echo "================================================================"
