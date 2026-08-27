#!/usr/bin/env bash
# metadata.sh — embed metadata into a .mov in PROPER QuickTime format, losslessly.
# OPT-IN ONLY: this never runs unless you invoke it with explicit fields. The remux
# path does not tag anything on its own.
#
# Writes the QuickTime `mdta` structure (udta/meta/keys/ilst via
# `-movflags use_metadata_tags` + `com.apple.quicktime.*` keys) that Apple tools and
# Finder read — NOT the bare ©nam atoms the naive `-metadata` one-liner emits. It also
# strips the generic chapter text-track that QuickTime renders as a second "menu", and
# suppresses the generic `encoder=Lavf…` tag. Video + audio are stream-copied
# bit-identical; the SOURCE is never touched.
#
# Usage: scripts/metadata.sh IN OUT.mov FIELD... (at least one field required)
#   --title T   --description D   --author A   --date YYYY-MM-DD
#   --copyright C   --comment C   --keywords "a,b,c"
#   --key NAME=VALUE   any com.apple.quicktime.NAME, or a full reverse-DNS key=value
#   --keep-chapters    keep the source chapter track (default: strip the "menu")
#
# Exit: 0 = embedded + round-trip confirmed; 1 = a key didn't round-trip; 2 = usage.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: metadata.sh IN OUT.mov --title ... [--description ...] ...}"
OUT="${2:?need OUT.mov}"; shift 2
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-mux.sh"    # rtm_part (extension-keeping atomics), mux_census (D5)

MD=(); KV=(); CHAP=(-map_chapters -1)   # default: strip chapters (the "menu")
add () { MD+=(-metadata "com.apple.quicktime.$1=$2"); KV+=("com.apple.quicktime.$1=$2"); }
while [ $# -gt 0 ]; do case "$1" in
  --title)        add title       "${2?--title needs a value}"; shift 2;;
  --description)  add description "${2?--description needs a value}"; shift 2;;
  --author)       add author      "${2?--author needs a value}"; shift 2;;
  --date|--creationdate) add creationdate "${2?--date needs a value}"; shift 2;;
  --copyright)    add copyright   "${2?--copyright needs a value}"; shift 2;;
  --comment)      add comment     "${2?--comment needs a value}"; shift 2;;
  --keywords)     add keywords    "${2?--keywords needs a value}"; shift 2;;
  --key)          case "${2?--key needs NAME=VALUE}" in
                    *.*.*=*) MD+=(-metadata "$2"); KV+=("$2");;                          # full reverse-DNS key
                    *=*)     MD+=(-metadata "com.apple.quicktime.$2"); KV+=("com.apple.quicktime.$2");;  # NAME=VALUE
                    *) echo "bad --key (need NAME=VALUE): $2" >&2; exit 2;;
                  esac; shift 2;;
  --keep-chapters) CHAP=(-map_chapters 0); shift;;   # keep QuickTime chapter metadata
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ "${#MD[@]}" -gt 0 ] || { echo "no metadata fields given — metadata.sh embeds nothing on its own" >&2; exit 2; }

vcodec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
VTAG=(); [ "$vcodec" = hevc ] && VTAG=(-tag:v hvc1)
PART="$(rtm_part "$OUT")"   # extension-keeping (D6)
# -map 0 -map -0:d? keeps every real stream (video, all audio, subtitles) but drops
# DATA tracks — the chapter/timecode text track QuickTime shows as a generic "menu".
# CHAP controls chapter metadata; +bitexact suppresses the generic encoder tag;
# use_metadata_tags writes the proper QuickTime mdta keys.
# ${arr[@]+...} keeps bash 3.2 (macOS default) happy under set -u with empty arrays
ffmpeg -nostdin -y -v error -fflags +bitexact "${FF_INPUT_OPTS[@]}" -i "$IN" \
  -map 0 -map -0:d? -map_metadata 0 ${CHAP[@]+"${CHAP[@]}"} \
  -c copy ${VTAG[@]+"${VTAG[@]}"} -movflags use_metadata_tags+faststart \
  ${MD[@]+"${MD[@]}"} -f mov "$PART"
# POST-MUX CENSUS (D5, 1.13): this pass REWRITES the container of a finished
# deliverable — losing a track HERE would silently narrow a file that already
# verified. `-map 0 -map -0:d?` keeps every non-data stream, so that is the plan.
# NOTE ffprobe csv orders fields by ITS canonical section order regardless of
# the request order: index,codec_name,codec_type — $2 is the NAME, $3 the TYPE
# (the same trap remux.sh's non-audio census documents).
MD_C=$(ffp -v error -show_entries stream=index,codec_type,codec_name -of csv=p=0 "$IN" 2>/dev/null | \
       awk -F, 'NF{ if(seen[$1]++) next; if($3=="data") next; printf "%s%s", s, $2; s="," }')
MD_N=$(printf '%s' "$MD_C" | awk -F, '{print ($0=="" ? 0 : NF)}')
census_rc=0
mux_census "$PART" "$MD_N" "$MD_C" metadata "$IN" || census_rc=$?
if [ "$census_rc" -ne 0 ] && [ "$census_rc" -ne 10 ]; then
  echo "   NOT blessing the tagged output; kept at $PART (the untagged input is untouched)." >&2
  exit 1
fi
mv -f "$PART" "$OUT"
echo "wrote: $OUT (proper QuickTime metadata; no chapter menu)"

# confirm each requested key round-tripped (proves the proper-format write took)
echo "-- metadata round-trip --"
tags=$(ffp -v error -show_entries format_tags -of default=noprint_wrappers=1 "$OUT" 2>/dev/null)
miss=0
for kv in "${KV[@]}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  got=$(printf '%s\n' "$tags" | sed -n "s/^TAG:${k}=//p" | head -1)
  if [ "$got" = "$v" ]; then echo "   ok  $k = $got"
  else echo "   !!  $k did not round-trip (got '${got:-<none>}', want '$v')"; miss=1; fi
done
[ "$miss" -eq 0 ] || { echo ">> REVIEW: some keys did not round-trip (see above)."; exit 1; }
# REVIEW propagation (1.14): an unexpected-surplus census still blesses the
# complete artifact and exits 10 ("look"), never 1.
if [ "${census_rc:-0}" -eq 10 ]; then
  echo ">> REVIEW: metadata embedded, but the census flagged an unexpected surplus stream (see RMX_CENSUS above)."
  exit 10
fi
echo ">> OK: metadata embedded in QuickTime format; source untouched."
