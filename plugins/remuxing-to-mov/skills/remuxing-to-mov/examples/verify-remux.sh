#!/usr/bin/env bash
# Verify a full remux: video (and copied audio) bit-identical, duration, layout, timeline.
set -uo pipefail
vhash () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null; }
ahash () { ffmpeg -nostdin -v error -i "$1" -map 0:a -c copy -f streamhash -hash md5 - 2>/dev/null; }
dur ()   { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1"; }
backdts () { ffprobe -v error -select_streams v:0 -read_intervals "%+#3000" -show_entries packet=dts -of csv=p=0 "$1" 2>/dev/null | awk -F, 'NR>1 && $1!="N/A" && p!="N/A" && $1<p {b++} {p=$1} END{print b+0}'; }

verify () {
  local SRC="$1" OUT="$2" AUDIO_COPIED="$3"
  echo "================================================================"
  echo "OUT: $OUT"
  # video lossless (packet-level, timestamp-immune)
  local sv ov; sv=$(vhash "$SRC"); ov=$(vhash "$OUT")
  [ "$sv" = "$ov" ] && echo "  video lossless: PASS  [$ov]" || echo "  video lossless: FAIL  src=$sv out=$ov"
  # audio lossless only when copied (not when DTS->PCM)
  if [ "$AUDIO_COPIED" = yes ]; then
    local sa oa; sa=$(ahash "$SRC"); oa=$(ahash "$OUT")
    [ "$sa" = "$oa" ] && echo "  audio lossless: PASS  (all tracks copied identical)" || echo "  audio lossless: FAIL
     src=$sa
     out=$oa"
  else
    echo "  audio: DTS decoded -> PCM (faithful render; bitstream intentionally not preserved)"
  fi
  # duration
  printf "  duration: out=%s  src=%s\n" "$(dur "$OUT")" "$(dur "$SRC")"
  # timeline
  echo "  backward-DTS(out): $(backdts "$OUT")  (want 0)"
  # output stream layout
  echo "  output streams:"
  ffprobe -v error -show_entries stream=index,codec_type,codec_name,codec_tag_string,channels:stream_tags=language \
    -of compact "$OUT" 2>/dev/null | sed 's/^/    /'
}

B=/Volumes/T7/SNL/episodes
verify "$B/[S44E01] Adam Driver + Kanye West [2018-09-29]/feed.mkv" "$B/[S44E01] Adam Driver + Kanye West [2018-09-29]/feed.mov" no
verify "$B/[S38E13] Justin Bieber [2013-02-09]/feed.ts" "$B/[S38E13] Justin Bieber [2013-02-09]/feed.mov" yes
verify "$B/[S38E12] Adam Levine + Kendrick Lamar [2013-01-26]/feed.ts" "$B/[S38E12] Adam Levine + Kendrick Lamar [2013-01-26]/feed.mov" yes
verify "$B/[S39E07] Josh Hutcherson + HAIM [2013-11-23]/feed.ts" "$B/[S39E07] Josh Hutcherson + HAIM [2013-11-23]/feed.mov" yes
echo "================================================================"
