#!/usr/bin/env bash
# remux.sh — Rung 0/1 lossless remux into MOV.
# Usage: scripts/remux.sh INPUT OUTPUT.mov [--audio auto|copy|pcm] [--genpts] [--all-audio]
#   --audio auto (default): copy AC-3/E-AC-3/AAC/ALAC/PCM; decode MP2/MP1/DTS to PCM
#                           (MOV-incompatible or QuickTime-unplayable -> faithful PCM decode)
#   --audio copy : force copy (mux-only; may not play in QuickTime)
#   --audio pcm  : force pcm_s16le
#   --genpts     : add -fflags +genpts (Rung 2, missing timestamps)
#   --all-audio  : map every audio track (default maps a:0 only)
# Video is ALWAYS copied (bit-identical). HEVC is tagged hvc1. Output is written
# atomically (.part -> mv) so a failure never leaves a half file under the real name.
set -euo pipefail
IN="${1:?usage: remux.sh INPUT OUTPUT.mov [opts]}"; OUT="${2:?need OUTPUT.mov}"; shift 2
AUDIO=auto; GENPTS=""; AMAP="-map 0:a:0?"
while [ $# -gt 0 ]; do case "$1" in
  --audio) AUDIO="$2"; shift 2;;
  --genpts) GENPTS="-fflags +genpts"; shift;;
  --all-audio) AMAP="-map 0:a?"; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }

# --- decide audio handling ---
acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
if [ "$AUDIO" = auto ]; then
  case "$acodec" in
    mp2|mp1|mp3|dts) AOPT="-c:a pcm_s16le"; echo "audio: $acodec -> PCM (MOV-incompatible or QuickTime-unplayable)";;
    "")              AOPT="";              echo "audio: none";;
    *)               AOPT="-c:a copy";     echo "audio: $acodec -> copy";;
  esac
elif [ "$AUDIO" = pcm ]; then AOPT="-c:a pcm_s16le"
else AOPT="-c:a copy"; fi

# --- video tag (HEVC needs hvc1 for QuickTime) ---
vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"

# --- color: +write_colr is redundant on modern ffmpeg but harmless; include only if tagged ---
cp=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

PART="${OUT}.part"
# shellcheck disable=SC2086
ffmpeg -nostdin -y $GENPTS -i "$IN" -map 0:v:0 $AMAP \
  -c:v copy $VTAG $AOPT \
  -movflags "$MOVFLAGS" -f mov \
  "$PART"
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""
