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
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"   # mux_confessions

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

PART="${OUT}.part"; MUXLOG="$(mktemp)"
# shellcheck disable=SC2086
if ! ffmpeg -nostdin -y -hide_banner -nostats $GENPTS -i "$IN" -map 0:v:0 $AMAP \
    -c:v copy $VTAG $AOPT \
    -movflags "$MOVFLAGS" -f mov \
    "$PART" 2>"$MUXLOG"; then
  echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8
  exit 1
fi
[ -n "${RTM_MUX_LOG_APPEND:-}" ] && [ -f "$RTM_MUX_LOG_APPEND" ] && cat "$RTM_MUX_LOG_APPEND" >> "$MUXLOG"   # test hook
[ -s "$MUXLOG" ] && sed 's/^/   mux: /' "$MUXLOG" | tail -6
# HARD STOP (post-mortem 2026-07-25): "pts has no value" / "Timestamps are unset" /
# non-monotonic DTS in the mux log is the muxer announcing it INVENTED the
# timeline. The video bits can be perfect while the written timing is garbage —
# the shipped-broken files rendered thumbnails and passed the essence checks.
# Never bless such an output, regardless of what any later verify says.
conf=$(mux_confessions "$MUXLOG")
if [ "${conf:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the muxer logged $conf timeline confession(s):"
  grep -iE 'pts has no value|timestamps are unset|non-?monotonic dts' "$MUXLOG" | sort | uniq -c | sort -rn | head -4 | sed 's/^/   /'
  echo "   The muxer invented timing for packets the source never timestamped."
  echo "   NOT blessing the output (kept at $PART; log: $MUXLOG)."
  echo "   Run scripts/diagnose.sh \"$IN\" — half-timestamped PAFF routes to"
  echo "   scripts/pairfill-paff.sh; timestamp-free streams to scripts/rebuild-paff.sh."
  exit 1
fi
rm -f "$MUXLOG"
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""
