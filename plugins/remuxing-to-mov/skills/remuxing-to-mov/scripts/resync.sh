#!/usr/bin/env bash
# resync.sh — fix a DISCONTINUOUS-source desync while keeping the VIDEO bit-identical.
# For captures whose source dropped frames (forward timestamp gaps): a blind `-c copy`
# preserves those gaps in the video timeline but COLLAPSES them in raw PCM audio
# (ffmpeg's muxer writes no mid-stream empty edit per drop, so the PCM sample
# array packs end-to-end), sliding audio progressively out of sync — the
# remux-sync post-mortem. This re-times the audio to
# the picture by filling the gaps, and never re-encodes the video.
#
# Usage: scripts/resync.sh INPUT OUTPUT.mov [--all-audio] [--audio a:N] [--pcm 16|24|32]
#   --all-audio  re-time every audio track (default: a:0 only)
#   --audio a:N  re-time a specific track
#   --pcm        PCM bit depth for the re-timed audio (default 24)
#
# What it does (the corrected procedure from the post-mortem):
#   video : -c:v copy  -> BIT-IDENTICAL (HEVC tagged hvc1); never re-encoded
#   audio : -af aresample=async=1:first_pts=0 -> PCM; silence inserted at each gap
#           so the audio stays pinned to the picture timeline
#   +faststart; atomic .part -> mv; the SOURCE is never touched.
#
# TRADE-OFF (explicit, by design — this is why it is a separate, human-invoked tool
# and not part of the lossless ladder): the audio is RE-TIMED, not a bit-exact copy.
# Video stays lossless. If you also need the bit-exact ORIGINAL audio, the only
# frame-accurate fix is a re-mux from the still-existing source — see the post-mortem
# and references/timeline-repair.md. Lossy tracks (AC-3/DTS/MP2) are rendered to PCM.
#
# REFUSED CLASS (2026-07-30 incident): sources whose audio changes channel layout
# mid-stream (broadcast AC-3 flipping 5.1 -> stereo -> 5.1). Each change makes
# ffmpeg REBUILD the audio filter graph, and aresample=async=1:first_pts=0
# re-pads silence from t=0 on EVERY rebuild — the 2008 backhaul build injected
# ~17 minutes of silence and pushed all later audio out of sync while duration
# parity still passed. The scan below detects the class up front and refuses
# (exit 11) rather than ship it; verify.sh --silence is the downstream content
# gate for whatever does get built.
#
# Exit: 0 = resynced + sync-verified; 10 = REVIEW; 1 = FAIL; 2 = usage;
#       11 = REFUSED (mid-stream audio layout change — resync would inject silence).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: resync.sh INPUT OUTPUT.mov [--all-audio] [--audio a:N] [--pcm 16|24|32]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
AMAP="-map 0:a:0?"; PCM=pcm_s24le
while [ $# -gt 0 ]; do case "$1" in
  --all-audio) AMAP="-map 0:a?"; shift;;
  --audio)     AMAP="-map 0:${2:?--audio needs a:N}"; shift 2;;
  --pcm) case "${2:-}" in 16) PCM=pcm_s16le;; 24) PCM=pcm_s24le;; 32) PCM=pcm_s32le;; *) echo "bad --pcm: ${2:-}" >&2; exit 2;; esac; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open

vcodec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"
cp=$(ffp -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

echo "== resync: $IN -> $OUT =="
echo "   video=$vcodec -> -c:v copy (bit-identical); audio -> $PCM, gaps filled (aresample async)"

# --- mid-stream layout-change guard (frame-level, decodes the mapped audio) ---
# Test hook: RTM_LAYOUTS_FILE=<file of "channels,layout" lines> bypasses ffprobe.
lay_profile () {  # $1 = stream spec (a:N) -> distinct channels/layout combos seen
  { if [ -n "${RTM_LAYOUTS_FILE:-}" ]; then cat "$RTM_LAYOUTS_FILE"; else
      ffp -v error -select_streams "$1" -show_entries frame=channels,channel_layout \
        -of csv=p=0 "$IN" 2>/dev/null; fi; } | grep -v '^$' | sort -u
}
ASPECS=""
case "$AMAP" in
  "-map 0:a?")
    na=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -un | grep -c . || true)
    i=0; while [ "$i" -lt "${na:-0}" ]; do ASPECS="$ASPECS a:$i"; i=$((i+1)); done ;;
  *) ASPECS=$(printf '%s' "$AMAP" | sed 's/^-map 0://; s/?$//') ;;
esac
for spec in $ASPECS; do
  echo "   scanning $spec for mid-stream layout changes (audio decode; may take a minute)..."
  combos=$(lay_profile "$spec")
  ncombo=$(printf '%s\n' "$combos" | grep -c . || true)
  if [ "${ncombo:-0}" -gt 1 ]; then
    echo ">> REFUSED: mid-stream channel-layout change on $spec:"
    printf '%s\n' "$combos" | sed 's/^/     /'
    echo "   Each change makes ffmpeg rebuild the audio filter graph, and"
    echo "   aresample=async=1:first_pts=0 re-pads silence from t=0 on every rebuild —"
    echo "   the injected-silence incident class (~17 min of silence, all later audio"
    echo "   out of sync, duration parity blind to it). Refusing rather than shipping it."
    echo "   Honest routes:"
    echo "     mov.sh   the dual-track build has no resample filter in its path and is"
    echo "              the correct deliverable when the AUDIO itself is continuous"
    echo "              (a sub-frame video gap costs milliseconds — under sync tolerance)"
    echo "     keep     the source — it is already the archival master"
    echo "     playback lossless MKV mux (holds the discontinuous timeline honestly)"
    exit 11
  fi
done

PART="${OUT}.part"
# shellcheck disable=SC2086
ffmpeg -nostdin -v error -fflags +genpts "${FF_INPUT_OPTS[@]}" -i "$IN" \
  -map 0:v:0 -c:v copy $VTAG \
  $AMAP -af "aresample=async=1:first_pts=0" -c:a "$PCM" \
  -movflags "$MOVFLAGS" -f mov "$PART"
mv -f "$PART" "$OUT"
echo "   wrote: $OUT"

echo "-- verify (sync + lossless video + silence content-parity) --"
# --silence: duration parity cannot see injected silence (the 2008 build passed
# it with ~17 min inserted) — the content gate compares long-window silence
# source vs output against the legitimate gap-fill budget.
set +e
o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" --silence 2>&1); set -e
printf '%s\n' "$o" | sed 's/^/   /'
case "$o" in
  *">> OK"*)     echo ">> DONE: $OUT — video bit-identical, audio re-timed to the picture."; exit 0 ;;
  *">> REVIEW"*) echo ">> REVIEW: $OUT written; see the sync/parity note above (a tail residual can remain — confirm against the source)."; exit 10 ;;
  *)             echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac
