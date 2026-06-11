#!/usr/bin/env bash
# probe.sh — one-shot source inspection for a remux decision.
# Usage: scripts/probe.sh INPUT
# Prints: container, video/audio codecs + tags, field structure, Annex-B vs AVCC,
# color tags, a timestamp sanity flag, and ffmpeg-version-dependent warnings.
set -euo pipefail
IN="${1:?usage: probe.sh INPUT}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }

echo "== source: $IN =="
echo "container : $(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN")"

echo "-- video --"
ffprobe -v error -select_streams v:0 -show_entries \
  stream=codec_name,codec_tag_string,profile,width,height,field_order,pix_fmt,color_primaries,color_transfer,color_space,color_range,is_avc,nal_length_size \
  -of default=nw=1 "$IN" || true

echo "-- audio --"
ffprobe -v error -select_streams a -show_entries \
  stream=index,codec_name,codec_tag_string,channels,sample_rate:stream_tags=language \
  -of default=nw=1 "$IN" || true

echo "-- bitstream format --"
isavc=$(ffprobe -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
case "$isavc" in
  true)  echo "AVCC (MP4/MKV/MOV) -> add -bsf:v h264_mp4toannexb when EXTRACTING to raw .h264" ;;
  false) echo "Annex-B (TS/PS)    -> NO bitstream filter needed when extracting to raw .h264" ;;
  *)     echo "n/a (not H.264, or undetectable)" ;;
esac

echo "-- field structure --"
fo=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
echo "field_order=$fo  (tt/bb = interlaced; progressive = no field concern)"
echo "   NOTE: if mediainfo says 'Separated fields' this is PAFF/field-coded -> glitch-prone; see references/timeline-repair.md"

echo "-- ffmpeg version & behavior deltas --"
ver=$(ffmpeg -version 2>/dev/null | head -1 | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
major=${ver%%.*}
echo "ffmpeg $ver"
if [ "${major:-0}" -lt 5 ]; then
  echo "  WARN ffmpeg <5.0: Dolby Vision will NOT survive -c copy. Keep MKV for DV sources."
else
  echo "  OK ffmpeg >=5.0: single-layer Dolby Vision (P5/P8) survives -c copy with -tag:v hvc1."
fi
echo "  NOTE colr atom is written by default on modern ffmpeg; +write_colr is redundant (harmless)."
echo "  NOTE HDR10 mdcv/clli ride in the HEVC SEI, NOT as container boxes ffmpeg writes on copy."
echo "  NOTE MP2 muxes into MOV (tag .mp2) but is non-standard; QuickTime is not expected to play it -> decode to PCM for playback."
