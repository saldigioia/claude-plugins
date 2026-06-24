#!/usr/bin/env bash
# probe.sh — one-shot source inspection for a remux decision.
# Usage: scripts/probe.sh INPUT [--kv|--json]
#   (default)  human-readable report
#   --kv       machine-readable KEY=VAL (PR_* + PF_* + a recommended FIRST rung)
#   --json     same facts as a flat JSON object
# Prints: container, video/audio codecs + tags, field structure, Annex-B vs AVCC,
# color tags, a timestamp sanity flag, and ffmpeg-version-dependent warnings.
set -euo pipefail
IN="${1:?usage: probe.sh INPUT [--kv|--json]}"; MODE="${2:-human}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"   # shared PAFF detection (coded-picture-rate test)

# Structured output for auto.sh / batch.sh. The recommended rung is a FIRST guess
# from codec/PAFF/audio only; timestamp-driven escalation (Rung 2/3 on non-PAFF)
# happens reactively in auto.sh from the verify verdict.
probe_struct () {
  local mode="$1" q="ffprobe -v error -select_streams"
  local container vcodec vtag isavc acodec aaction rung cmd cp ct cs cr
  container=$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  vcodec=$($q v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  vtag=$($q v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  isavc=$($q v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  acodec=$($q a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  cp=$($q v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  ct=$($q v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  cs=$($q v:0 -show_entries stream=color_space -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  cr=$($q v:0 -show_entries stream=color_range -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  eval "$(pf_detect "$IN")"
  case "$acodec" in                              # mirrors remux.sh --audio auto
    mp2|mp1|mp3|dts) aaction=pcm;;
    "")              aaction=none;;
    *)               aaction=copy;;
  esac
  if   [ "$PF_PAFF" = yes ]; then rung=3; cmd="rebuild-paff.sh IN OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"
  elif [ "$aaction" = pcm ]; then rung=1; cmd="remux.sh IN OUT.mov --audio pcm"
  else                            rung=0; cmd="remux.sh IN OUT.mov"; fi
  if [ "$mode" = "--json" ]; then
    printf '{"container":"%s","vcodec":"%s","vtag":"%s","is_avc":"%s","acodec":"%s","audio_action":"%s","paff":"%s","field_rate":"%s","timescale":"%s","coded_rate":"%s","nominal_fps":"%s","color_primaries":"%s","color_transfer":"%s","color_space":"%s","color_range":"%s","rec_rung":%s,"rec_cmd":"%s"}\n' \
      "$container" "$vcodec" "$vtag" "${isavc:-na}" "${acodec:-none}" "$aaction" "$PF_PAFF" "$PF_FIELD_RATE" "$PF_TIMESCALE" "$PF_CODED_RATE" "$PF_NOMINAL_FPS" "${cp:-unknown}" "${ct:-unknown}" "${cs:-unknown}" "${cr:-unknown}" "$rung" "$cmd"
  else
    # values are single tokens (eval-safe + greppable); PR_REC_CMD has spaces -> quote it
    printf 'PR_CONTAINER=%s\nPR_VCODEC=%s\nPR_VTAG=%s\nPR_IS_AVC=%s\nPR_ACODEC=%s\nPR_AUDIO_ACTION=%s\nPF_PAFF=%s\nPF_FIELD_RATE=%s\nPF_TIMESCALE=%s\nPF_CODED_RATE=%s\nPF_NOMINAL_FPS=%s\nPR_COLOR_PRIMARIES=%s\nPR_COLOR_TRANSFER=%s\nPR_COLOR_SPACE=%s\nPR_COLOR_RANGE=%s\nPR_REC_RUNG=%s\nPR_REC_CMD='"'"'%s'"'"'\n' \
      "$container" "$vcodec" "$vtag" "${isavc:-na}" "${acodec:-none}" "$aaction" "$PF_PAFF" "$PF_FIELD_RATE" "$PF_TIMESCALE" "$PF_CODED_RATE" "$PF_NOMINAL_FPS" "${cp:-unknown}" "${ct:-unknown}" "${cs:-unknown}" "${cr:-unknown}" "$rung" "$cmd"
  fi
}
case "$MODE" in --kv|--json) probe_struct "$MODE"; exit 0;; esac

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
eval "$(pf_detect "$IN")"
echo "field_order=$PF_FIELD  (tt/bb = interlaced; progressive/unknown = usually no field concern)"
echo "coded-picture rate=${PF_CODED_RATE}/s  vs  frame rate=${PF_NOMINAL_FPS}/s  (ratio=${PF_RATIO})"
if [ "$PF_PAFF" = yes ]; then
  echo "   >> FIELD-CODED (PAFF) H.264: coded-picture rate ~2x the frame rate."
  echo "      This is the fragile profile and the one that silently corrupts."
  echo "      genpts (Rung 2) is GUILTY-UNTIL-PROVEN here: it can pass the strict"
  echo "      MKV-mux test yet leave a timeline that tears when a player scrubs."
  echo "      Go straight to the field-rate rebuild (Rung 3):"
  if [ "$PF_FIELD_RATE" = unknown ]; then
    echo "         scripts/rebuild-paff.sh \"$IN\" OUT.mov <FIELD_RATE> <TIMESCALE>"
    echo "         (measured ~${PF_CODED_RATE}/s didn't map to a standard rate — pick"
    echo "          from the field-rate table in references/timeline-repair.md)"
  else
    echo "         scripts/rebuild-paff.sh \"$IN\" OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"
  fi
  echo "      Then verify with the scrub gate: scripts/verify.sh \"$IN\" OUT.mov"
else
  echo "   NOTE: not field-coded by the rate test (ratio ~1x). If mediainfo says"
  echo "   'Separated fields' or playback still tears on scrub, treat as PAFF anyway"
  echo "   and rebuild; see references/timeline-repair.md."
fi

echo "-- discontinuities (forward timestamp gaps) --"
eval "$(disc_scan "$IN")"
if [ "${DISC_COUNT:-0}" -gt 0 ]; then
  echo "   >> ${DISC_COUNT} forward gap(s), first @ ${DISC_FIRST}s (~${DISC_MISSING}s dropped)."
  echo "      Present + monotonic, so the mux 'succeeds' — but a blind -c copy COLLAPSES"
  echo "      these in raw PCM audio and desyncs it. Use scripts/resync.sh, then verify."
else
  echo "   none (video DTS gap-free on the timing axis; safe to plain-copy)."
fi

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
