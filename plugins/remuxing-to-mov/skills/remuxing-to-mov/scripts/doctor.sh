#!/usr/bin/env bash
# doctor.sh — verify the local ffmpeg/ffprobe can run this skill's checks, and
# report which version-gated behaviors apply. Run this once on a new machine (or
# in CI) before trusting verify.sh / auto.sh.
# Usage: scripts/doctor.sh [--kv]
#   --kv : machine-readable KEY=VAL only (for auto.sh / batch.sh / CI)
# Exit: 0 if all REQUIRED capabilities are present, 1 otherwise. Missing
#       RECOMMENDED capabilities only degrade specific checks (never silently).
set -euo pipefail
KV=0; [ "${1:-}" = "--kv" ] && KV=1

have_bin () { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }
# Capture the lists ONCE, then match from a herestring. Piping ffmpeg into
# `grep -q` would let grep close the pipe early; under `set -o pipefail` the
# resulting SIGPIPE on ffmpeg reads back as a false "missing" (flaky by position).
FFMPEG=$(have_bin ffmpeg); FFPROBE=$(have_bin ffprobe)
MUXERS=""; BSFS=""
[ "$FFMPEG" = yes ] && { MUXERS=$(ffmpeg -hide_banner -muxers 2>/dev/null || true); BSFS=$(ffmpeg -hide_banner -bsfs 2>/dev/null || true); }
has_mux  () { grep -qw "$1" <<<"$MUXERS" && echo yes || echo no; }
has_bsf  () { grep -qw "$1" <<<"$BSFS"   && echo yes || echo no; }
VER=""; MAJOR=0; MINOR=0
if [ "$FFMPEG" = yes ]; then
  VER=$(ffmpeg -version 2>/dev/null | head -1 | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
  MAJOR=${VER%%.*}; MINOR=${VER#*.}; MAJOR=${MAJOR:-0}; MINOR=${MINOR:-0}
fi
MUX_MOV=no; MUX_NULL=no; MUX_SHASH=no; MUX_FMD5=no
BSF_FU=no; BSF_H264=no; BSF_HEVC=no
if [ "$FFMPEG" = yes ]; then
  MUX_MOV=$(has_mux mov);        MUX_NULL=$(has_mux null)
  MUX_SHASH=$(has_mux streamhash); MUX_FMD5=$(has_mux framemd5)
  BSF_FU=$(has_bsf filter_units); BSF_H264=$(has_bsf h264_mp4toannexb); BSF_HEVC=$(has_bsf hevc_mp4toannexb)
fi

# REQUIRED to do anything useful; RECOMMENDED degrades a specific check if absent.
required_ok=yes
for v in "$FFMPEG" "$FFPROBE" "$MUX_MOV" "$MUX_NULL"; do [ "$v" = yes ] || required_ok=no; done
# H.264 VCL lossless arbiter needs both of these; else verify.sh falls back.
vcl_ok=no; { [ "$BSF_FU" = yes ] && [ "$BSF_H264" = yes ]; } && vcl_ok=yes
dv_copy=no; [ "${MAJOR:-0}" -ge 5 ] && dv_copy=yes

status=READY; [ "$required_ok" = yes ] || status=BLOCKED
{ [ "$status" = READY ] && { [ "$vcl_ok" = no ] || [ "$MUX_SHASH" = no ]; }; } && status=DEGRADED

if [ "$KV" -eq 1 ]; then
  printf 'DOC_FFMPEG=%s\nDOC_FFPROBE=%s\nDOC_VERSION=%s\nDOC_MUX_MOV=%s\nDOC_MUX_NULL=%s\nDOC_MUX_STREAMHASH=%s\nDOC_MUX_FRAMEMD5=%s\nDOC_BSF_FILTER_UNITS=%s\nDOC_BSF_H264_ANNEXB=%s\nDOC_BSF_HEVC_ANNEXB=%s\nDOC_VCL_OK=%s\nDOC_DV_COPY=%s\nDOC_STATUS=%s\n' \
    "$FFMPEG" "$FFPROBE" "${VER:-na}" "$MUX_MOV" "$MUX_NULL" "$MUX_SHASH" "$MUX_FMD5" \
    "$BSF_FU" "$BSF_H264" "$BSF_HEVC" "$vcl_ok" "$dv_copy" "$status"
  [ "$required_ok" = yes ] || exit 1
  exit 0
fi

mark () { [ "$1" = yes ] && echo "present" || echo "MISSING"; }
echo "== remuxing-to-mov environment doctor =="
echo "ffmpeg  : $(mark "$FFMPEG")${VER:+ ($VER)}"
echo "ffprobe : $(mark "$FFPROBE")"
echo "-- muxers --"
echo "  mov        : $(mark "$MUX_MOV")   [required]"
echo "  null       : $(mark "$MUX_NULL")   [required: decode spot-checks / scrub gate]"
echo "  streamhash : $(mark "$MUX_SHASH")   [recommended: packet + VCL lossless proof]"
echo "  framemd5   : $(mark "$MUX_FMD5")   [recommended: non-H.264 lossless + --full]"
echo "-- bitstream filters --"
echo "  filter_units     : $(mark "$BSF_FU")   [recommended: H.264 VCL lossless arbiter]"
echo "  h264_mp4toannexb : $(mark "$BSF_H264")   [recommended: VCL / rebuild on AVCC sources]"
echo "  hevc_mp4toannexb : $(mark "$BSF_HEVC")   [optional: HEVC elementary handling]"
echo "-- version-gated behavior --"
if [ "$dv_copy" = yes ]; then
  echo "  Dolby Vision : ffmpeg $VER >= 5.0 -> single-layer DV (P5/P8) survives -c copy with -tag:v hvc1."
else
  echo "  Dolby Vision : ffmpeg ${VER:-?} < 5.0 -> DV will NOT survive -c copy; keep MKV for DV sources."
fi
echo "  (Confirm AC-3/E-AC-3 QuickTime playback on the target Mac; see playable-check.sh.)"
echo
case "$status" in
  READY)    echo ">> READY — all required and recommended capabilities present." ;;
  DEGRADED)
    echo ">> DEGRADED — required capabilities present, but:"
    [ "$vcl_ok" = no ]    && echo "   - filter_units/h264_mp4toannexb missing: H.264 lossless check falls back to the decoded multiset (verify.sh stays safe, just less cheap/sharp; PAFF sources -> REVIEW)."
    [ "$MUX_SHASH" = no ] && echo "   - streamhash missing: packet/VCL hashing unavailable; lossless proof leans on decoded compares."
    echo "   Upgrade ffmpeg for the full cheap-tier proof." ;;
  BLOCKED)
    echo ">> BLOCKED — a required capability is missing (see MISSING above). Install/upgrade ffmpeg." ;;
esac
[ "$required_ok" = yes ] || exit 1
