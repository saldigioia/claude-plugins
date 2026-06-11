#!/usr/bin/env bash
# dual-track.sh — build a QuickTime-ready, minimal-loss MOV with a PCM "access"
# track as the DEFAULT first audio track, and the ORIGINAL audio preserved
# bit-exact as a second track. Non-destructive: writes a NEW file, never the source.
#
# This is the recommended DEFAULT deliverable: it always plays in stock QuickTime
# (PCM track 1) while losing as little as possible (original bitstream kept as
# track 2 for provenance / re-derivation).
#
# Usage:
#   dual-track.sh INPUT OUTPUT.mov [--ss START] [--to END] \
#                 [--pcm auto|16|24|32] [--drc auto|off|on]
#
#   --ss/--to  : optional lossless cut (keyframe-bound). START/END accept seconds
#                or HH:MM:SS.mmm. Omit for a full-file build.
#   --pcm auto : pick PCM depth from the decoder's native sample format
#                (s16->16, flt/fltp->24, s32->32). Override with 16|24|32.
#   --drc auto : disable AC-3/E-AC-3 dynamic-range compression (full dynamic
#                range, audiophile default). Use --drc on to keep broadcast DRC.
#
# Video is ALWAYS -c:v copy (bit-identical); HEVC tagged hvc1. Output is atomic
# (.part -> mv) and faststart. ALWAYS verify after (see dual-track-quicktime.md).
#
# WHY TWO PASSES WHEN CUTTING: doing the cut and the decode in one pass with -ss
# before -i, while mapping the same audio twice (one decoded, one copied), trims
# the decoded PCM to the seek time but keeps whole frames on the copied track —
# leaving the two audio tracks offset by up to ~0.5 s. So when a cut is requested
# we (1) lossless-copy-cut first, then (2) decode+copy from that cut with NO -ss,
# which guarantees both audio tracks share identical frames and stay aligned.
set -euo pipefail

IN="${1:?usage: dual-track.sh INPUT OUTPUT.mov [--ss START] [--to END] [--pcm auto|16|24|32] [--drc auto|off|on]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
SS=""; TO=""; PCMOPT=auto; DRCOPT=auto
while [ $# -gt 0 ]; do case "$1" in
  --ss)  SS="$2";  shift 2;;
  --to)  TO="$2";  shift 2;;
  --pcm) PCMOPT="$2"; shift 2;;
  --drc) DRCOPT="$2"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }

# --- probe source (never guess) ---
acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name   -of default=nw=1:nk=1 "$IN" | head -1)
afmt=$(  ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt   -of default=nw=1:nk=1 "$IN" | head -1)
vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name   -of default=nw=1:nk=1 "$IN" | head -1)
cp=$(    ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" | head -1)
[ -n "$acodec" ] || { echo "no audio stream found in $IN" >&2; exit 2; }

# --- choose PCM depth (override or auto from decoder native fmt) ---
case "$PCMOPT" in
  16) PCMC=pcm_s16le; BITS=16;;
  24) PCMC=pcm_s24le; BITS=24;;
  32) PCMC=pcm_s32le; BITS=32;;
  auto) case "$afmt" in
          s16|s16p) PCMC=pcm_s16le; BITS=16;;   # e.g. 16-bit DTS-HD MA -> bit-exact
          s32|s32p) PCMC=pcm_s32le; BITS=32;;
          *)        PCMC=pcm_s24le; BITS=24;;   # flt/fltp/dbl (AC-3 etc.) -> 24-bit
        esac;;
  *) echo "bad --pcm: $PCMOPT" >&2; exit 2;;
esac

# --- DRC handling (AC-3 / E-AC-3 only) ---
DRC=""
case "$acodec" in
  ac3|eac3) case "$DRCOPT" in
              auto|off) DRC="-drc_scale 0";;   # full dynamic range (default)
              on) DRC="";;
              *) echo "bad --drc: $DRCOPT" >&2; exit 2;;
            esac;;
esac

VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"
PART="${OUT}.part"

# track titles, self-describing
T1="PCM ${BITS}-bit (access)"
T2="$(echo "$acodec" | tr a-z A-Z) (original)"

echo "source: video=$vcodec  audio=$acodec ($afmt)  -> track1=$PCMC  track2=copy  ${DRC:+[DRC disabled]}"

build_from () {  # build_from SRC  -- decode a:0 to PCM (track1, default) + copy a:0 (track2)
  local SRC="$1"
  # shellcheck disable=SC2086
  ffmpeg -nostdin -y $DRC -i "$SRC" \
    -map 0:v:0 -map 0:a:0 -map 0:a:0 \
    -c:v copy $VTAG -c:a:0 $PCMC -c:a:1 copy \
    -disposition:a:0 default -disposition:a:1 0 \
    -metadata:s:a:0 title="$T1" -metadata:s:a:0 language=eng \
    -metadata:s:a:1 title="$T2" -metadata:s:a:1 language=eng \
    -movflags "$MOVFLAGS" -f mov "$PART"
}

if [ -n "$SS" ] || [ -n "$TO" ]; then
  # TWO PASS: lossless copy-cut, then decode+copy from the cut (no -ss) => aligned tracks
  TMP="${OUT%.*}.dtcut.tmp.mov"
  echo "pass 1/2: lossless copy-cut${SS:+ from $SS}${TO:+ to $TO}"
  # shellcheck disable=SC2086
  ffmpeg -nostdin -y ${SS:+-ss "$SS"} ${TO:+-to "$TO"} -i "$IN" \
    -map 0:v:0 -map 0:a:0 -c copy \
    -avoid_negative_ts make_zero -movflags +faststart -f mov "$TMP"
  echo "pass 2/2: decode PCM access track + copy original"
  build_from "$TMP"
  rm -f "$TMP"
else
  echo "full-file build (no cut)"
  build_from "$IN"
fi

mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "VERIFY (alignment): decode track 2 with the SAME params and md5-compare to track 1, e.g."
echo "  a=\$(ffmpeg -v error ${DRC:+$DRC }-i \"$OUT\" -map 0:a:0 -f ${PCMC#pcm_} - | md5sum)"
echo "  b=\$(ffmpeg -v error ${DRC:+$DRC }-i \"$OUT\" -map 0:a:1 -c:a $PCMC -f ${PCMC#pcm_} - | md5sum); [ \"\$a\" = \"\$b\" ] && echo ALIGNED"
